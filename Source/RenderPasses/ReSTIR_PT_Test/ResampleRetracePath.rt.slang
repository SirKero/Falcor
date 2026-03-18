#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.Raytracing;
import Scene.RaytracingInline;
import Utils.Sampling.SampleGenerator;
import Utils.Color.ColorHelpers;
import Rendering.Lights.LightHelpers;
import Rendering.Lights.EmissiveLightSampler;
import Utils.Math.MathHelpers;
import SharedStructsAndFunctions;
import NextEventEstimationHelper;

cbuffer CB
{
    uint gFrameCount;                      // Current FrameCount for RNG
    float3 gNeeLightTypeSelectProbability; // Emissive, Analytic, EnvMap

    PackedPathLength gPackedPathLength; // Max indirections
    uint gRNGNumPass; // Identifier for the pass used to initialize the RNG
    float gSpatialSampleRadius; // Spatial resampling radius
    uint gPassIdentifier;    //0-Trace both, 1-current, 2-other
}

Texture2D<PackedHitInfo> gVBuffer;
Texture2D<PackedHitInfo> gVBufferPrev;
Texture2D<float4> gView;
Texture2D<float4> gViewPrev;
Texture2D<float2> gMVec;

StructuredBuffer<ReservoirPT> gReservoirPrev;
RWStructuredBuffer<RetracedSurface> gRetraceSurfacePrev;
StructuredBuffer<ReservoirPT> gReservoir;
RWStructuredBuffer<RetracedSurface> gRetraceSurface;

RWTexture2D<float4> gRetraceRCPathThp;
RWTexture2D<float4> gRetraceRCPathThpPrev;

static const bool kUseEmissive = USE_EMISSIVE_LIGHT;
static const bool kUseAnalytic = USE_ANALYTIC_LIGHT;
static const bool kUseEnvMap = USE_ENV_BACKROUND;
static const bool kUseEnvLight = USE_ENV_LIGHT;
static const bool kAlphaTest = true;
static const uint kMIHints = (uint)MaterialInstanceHints::AdjustShadingNormal;
static const float kRoughnessThreshold = ROUGHNESS_THRESHOLD;
static const float kJacobianDistanceThreshold = JACOBIAN_DISTANCE_THRESHOLD;
static const uint kRNGNumPasses = RNG_NUM_PASSES;
static const bool kEvalDeltaPdfs = EVAL_DELTA_PDFS;
static const bool kRetraceRCPath = RETRACE_RC_PATH;


struct RayPayload
{
    PackedHitInfo packedHitInfo; //< Hit Info

    /** Create ray payload with default parameters.
     */
    __init()
    {
        this.packedHitInfo = {};
    }
}

struct RetracePathData {
    float3 thp;
    float scatterPdf;

    float3 lastOrigin;
    bool updateRcThp;

    float3 lastFaceN;
    bool lastSurfaceIsDiffuse;

    float pathPdf;
    float3 rcThp;

    __init() {
        thp = float3(1);
        scatterPdf = 1;
        lastOrigin = float3(0);
        lastFaceN = float3(0);
        updateRcThp = false;
        lastSurfaceIsDiffuse = false;
        pathPdf = 1.0;
        rcThp = float3(1);
    }
}

bool sampleNewRay(ShadingData sd, IMaterialInstance mi, inout SampleGenerator sg, inout RetracePathData rpd, inout RayDesc ray, out int reflectionLobe)
{
    reflectionLobe = -1;
    BSDFSample bsdfSample;
    bool validSample = mi.sample(sd, sg, bsdfSample, true);
    if (validSample) {
        bool transmission = bsdfSample.isLobe(LobeType::Transmission);
        bool disableDeltaPdf = bsdfSample.isLobe(LobeType::Delta) && !kEvalDeltaPdfs; // If true uses 1 for pdf
        ray.Origin = sd.computeNewRayOrigin(!transmission); // false is for transmissions
        ray.Direction = bsdfSample.wo;
        if (rpd.updateRcThp)
            rpd.rcThp *= bsdfSample.weight;
        else
            rpd.thp *= bsdfSample.weight;
        rpd.scatterPdf = disableDeltaPdf ? 1.0 : bsdfSample.pdf;
        rpd.pathPdf *= rpd.scatterPdf;
        reflectionLobe = getLobeType(bsdfSample);
    }

    return validSample && any(rpd.thp > 0);
}

bool randomReplay(ShadingData primSD, ReservoirPT reservoir, inout RetracedSurface retracedSurface, out float3 rcRetraceRadiance)
{
    rcRetraceRadiance = float3(0);
    let lod = ExplicitLodTextureSampler(0);
    const uint2 dispatchDims = DispatchRaysDimensions().xy;

    //Init needed path data
    SampleGenerator rayDirSg = reservoir.sgPathDirections;
    RetracePathData rpd = RetracePathData();
    
    //Get starting ray
    RayDesc ray = {};
    ray.TMin = 0;
    ray.TMax = FLT_MAX;
    let primMI = gScene.materials.getMaterialInstance(primSD, lod, kMIHints);
    let primProperties = primMI.getProperties(primSD);
    RayPayload rayPayload = RayPayload();
    rpd.lastSurfaceIsDiffuse = primProperties.roughness > kRoughnessThreshold;

    if ((reservoir.flags.firstHitIsDelta && rpd.lastSurfaceIsDiffuse) || (!reservoir.flags.firstHitIsDelta && !rpd.lastSurfaceIsDiffuse))
        return false;

    int firstHitReflectionLobe = -1;
    if (!sampleNewRay(primSD, primMI, rayDirSg, rpd, ray, firstHitReflectionLobe))
        return false;

    PackedPathLength currentPathLength = PackedPathLength();
    updatePathLength(currentPathLength, firstHitReflectionLobe);
    bool useRcSurface = false;
    if (kRetraceRCPath)
    {
        if (reservoir.rcPathLength == 1 && !reservoir.flags.hasNoReconnectionSurface)
            useRcSurface = true;
    }
    for (uint pathLength = 1; pathLength <= reservoir.pathLength; pathLength++)
    {
        HitInfo hit = {};
        if (useRcSurface) {
            hit = HitInfo(reservoir.packedSampleSurface);
        } else {
            TraceRay(gScene.rtAccel, 0, 0xff, 0, rayTypeCount, 0, ray, rayPayload);
            hit = HitInfo(rayPayload.packedHitInfo);
        }

        if (!hit.isValid()) {
            bool validRetrace = false;
            if (reservoir.flags.isEnvMapMiss && pathLength == reservoir.pathLength) {
                float misWeight = 1.0;
                if (kUseEnvLight && rpd.lastSurfaceIsDiffuse) {
                    float lightPdf = gNeeLightTypeSelectProbability[kNeeLightTypeEnvMap] * gEnvMapSampler.evalPdf(ray.Direction);
                    misWeight = evalMIS(1, rpd.scatterPdf, 1, lightPdf);
                }
                float3 envMapContribution = misWeight * gScene.envMap.eval(ray.Direction) * rpd.thp;
                retracedSurface.pathFlags = (uint)ReservoirPathFlags::isEnvMapMiss;
                retracedSurface.rcViewDir = ray.Direction;
                retracedSurface.jacobianDeterminant = rpd.scatterPdf;
                retracedSurface.thp = envMapContribution;
                validRetrace = true;
            }
            return validRetrace;
        }

        // Load shading structs
        ShadingData sd = {};
        if (useRcSurface) {
            sd = loadShadingDataWithPrevHit(hit, ray.Origin, lod);
            rpd.updateRcThp = true;
            useRcSurface = false;
        } else {
            sd = loadShadingData(hit, ray.Direction, lod);
        }
        
        let mi = gScene.materials.getMaterialInstance(sd, lod, kMIHints);
        let bsdfProperties = mi.getProperties(sd);
        bool surfaceIsDiffuse = (bsdfProperties.roughness > kRoughnessThreshold); // Either diffuse surface or emissive hit
        bool surfaceIsEmissive = any(bsdfProperties.emission > 0);
        float rayDist = distance(ray.Origin, sd.posW);
        // Reconnection Surface
        if ((pathLength == reservoir.rcPathLength - 1) && surfaceIsDiffuse && !reservoir.flags.hasNoReconnectionSurface) {
            retracedSurface.pathFlags = (uint)ReservoirPathFlags::isReconnectionPath;
            retracedSurface.thp = rpd.thp;
            //Set surface
            retracedSurface.rcViewDir = sd.V;
            retracedSurface.rcSurface = hit.getData();
            if(!kRetraceRCPath)
                return true;
            useRcSurface = true;
        }

        //NEE or Scatter
        if (pathLength == reservoir.pathLength && (surfaceIsDiffuse || surfaceIsEmissive))
        {
            bool retraceValid = false;
            if (surfaceIsEmissive && reservoir.flags.isScatter) //Scatter Hit (Path hits emissive surface)
            {
                // MIS
                float misWeight = 1;
                if (rpd.lastSurfaceIsDiffuse) {
                    // Get hit in light collection representation
                    TriangleHit triangleHit = hit.getTriangleHit();
                    TriangleLightHit lightHit;
                    lightHit.triangleIndex = gScene.lightCollection.getTriangleIndex(triangleHit.instanceID, triangleHit.primitiveIndex);
                    lightHit.posW = sd.posW;
                    lightHit.normalW = sd.getOrientedFaceNormal();

                    float neePDF = gNeeLightTypeSelectProbability[kNeeLightTypeEmissive] * gEmissiveSampler.evalPdf(rpd.lastOrigin, rpd.lastFaceN, true, lightHit);
                    misWeight = evalMIS(1.0, rpd.scatterPdf, 1.0, neePDF);
                }

                float3 emissiveRadiance = misWeight * bsdfProperties.emission;
                if (rpd.updateRcThp)
                {
                    rcRetraceRadiance = emissiveRadiance * rpd.rcThp;
                } else
                {
                    retracedSurface.pathFlags = (uint)ReservoirPathFlags::isScatter;
                    float distToSample = distance(rpd.lastOrigin, sd.posW);
                    retracedSurface.jacobianDeterminant = rpd.scatterPdf * abs(dot(rpd.lastFaceN, ray.Direction)) / (distToSample * distToSample);
                    retracedSurface.thp = emissiveRadiance * rpd.thp;
                }
                retraceValid = true;
            } else if (surfaceIsDiffuse && (reservoir.flags.endIsNee || (kRetraceRCPath && reservoir.flags.isNee))) //NEE
            {
                // Replay Nee decisions
                SampleGenerator neeSG = reservoir.sgRCNee;
                LightSample ls;
                float3 nee = nextEventEstimation(sd, mi, gNeeLightTypeSelectProbability, ls, neeSG);
                if (any(nee > 0) && ls.pdf > 0 && ls.distance > kJacobianDistanceThreshold) {
                    if (rpd.updateRcThp)
                    {
                        rcRetraceRadiance = nee * rpd.rcThp;
                    } else
                    {
                        retracedSurface.pathFlags = (uint)ReservoirPathFlags::endIsNee;
                        retracedSurface.thp = nee * rpd.thp;
                        retracedSurface.jacobianDeterminant = ls.pdf;
                        if (!ls.isInfiniteDistance)
                            retracedSurface.jacobianDeterminant *= abs(dot(sd.faceN, ls.dir)) / (ls.distance * ls.distance);
                    }
                    retraceValid = true;
                }
            }
            return retraceValid;
        }

        // Surfaces from emissive surfaces are undefined and reconnection surfaces are not allowed on the way.
        bool isReconnectionSurface = surfaceIsDiffuse && rpd.lastSurfaceIsDiffuse && (rayDist > kJacobianDistanceThreshold) && reservoir.flags.hasNoReconnectionSurface;
        if (isReconnectionSurface || surfaceIsEmissive)
        {
            break;
        }

        //Update reconnect path data
        rpd.lastSurfaceIsDiffuse = surfaceIsDiffuse;
        rpd.lastOrigin = sd.posW;
        rpd.lastFaceN = sd.faceN;

        //Sample ray for next iteration
        if (pathLength < reservoir.pathLength) {
            int reflectionLobe;
            if (!sampleNewRay(sd, mi, rayDirSg, rpd, ray, reflectionLobe)) {
                break;
            }
            updatePathLength(currentPathLength, firstHitReflectionLobe);
            if (!currentPathLength.comparePathLengts(gPackedPathLength))
                break;
        }
        if (kRetraceRCPath)
        {
            if (!reservoir.flags.hasNoReconnectionSurface && reservoir.rcPathLength == pathLength)
                ray.Direction = reservoir.sampleWo; //Use stored outgoing direction
        }
    }

    return false;
}

[shader("miss")]
void miss(inout RayPayload rayData: SV_RayPayload)
{
    HitInfo hitInfo = {};
    rayData.packedHitInfo = hitInfo.getData(); // Invalid hit
}

// For alpha test
[shader("anyhit")]
void anyHit(inout RayPayload rayData: SV_RayPayload, BuiltInTriangleIntersectionAttributes attribs: SV_IntersectionAttributes)
{
    if (kAlphaTest)
    {
        // Alpha test for non-opaque geometry.
        GeometryInstanceID instanceID = getGeometryInstanceID();
        VertexData v = getVertexData(instanceID, PrimitiveIndex(), attribs);
        uint materialID = gScene.getMaterialID(instanceID);
        if (gScene.materials.alphaTest(v, materialID, 0.f))
            IgnoreHit();
    }
}

[shader("closesthit")]
void closestHit(inout RayPayload rayData: SV_RayPayload, BuiltInTriangleIntersectionAttributes attribs: SV_IntersectionAttributes) {
    TriangleHit triangleHit;
    triangleHit.instanceID = getGeometryInstanceID();
    triangleHit.primitiveIndex = PrimitiveIndex();
    triangleHit.barycentrics = attribs.barycentrics;

    rayData.packedHitInfo = HitInfo(triangleHit).getData();
}

[shader("raygeneration")]
void rayGen()
{
    uint2 pixel = DispatchRaysIndex().xy;
    uint2 dispatchDims = DispatchRaysDimensions().xy;

    HitInfo hitInfo = HitInfo(gVBuffer[pixel]);

    if (hitInfo.isValid()) {
        SampleGenerator sg = SampleGenerator(pixel, gFrameCount * kRNGNumPasses + (2 + gRNGNumPass));

        // Get pixel for the reservoir. This is either the reprojected pixel (with motion vectors) or a random sample in a disc around it.
        bool isSpatial = gRNGNumPass > 0;
        float2 motionOffset = gMVec[pixel] * float2(dispatchDims);
        float2 prevPixelF = motionOffset + float2(pixel) + float2(0.5);
        float2 u = sampleNext2D(sg);
        if (isSpatial) {
            float2 spatialOffset = gSpatialSampleRadius * sample_disk_concentric(u);
            prevPixelF += spatialOffset;
        } else // Temporal; Add subpixel offset
        {
            prevPixelF += u - 0.5; // [-0.5, 0.5]
        }
        
        int2 prevPixel = int2(prevPixelF);

        // Check if previous pixel is inside the screen, if not, reservoir cannot be selected
        if(any(prevPixel < 0) || any(prevPixel >= dispatchDims))
        {
            return;
        }

        let lod = ExplicitLodTextureSampler(0);
        const uint reservoirIndex = index2Dto1D(pixel, dispatchDims.x);

        // Random Replay for current reservoir
        if (gPassIdentifier == 0 || gPassIdentifier == 1){
            ReservoirPT reservoir = gReservoir[reservoirIndex];
            bool randomReplayNeeded = reservoir.rcPathLength != 1;
            if (kRetraceRCPath)
                randomReplayNeeded = true;
            if (randomReplayNeeded && reservoir.weight > 0 && any(reservoir.F > 0)) {
                RetracedSurface retraceSurface = RetracedSurface();
                // Get starting surface for temporal retrace
                HitInfo prevHit = HitInfo(gVBufferPrev[prevPixel]);
                float3 prevViewDir = gViewPrev[prevPixel].xyz;
                ShadingData sd = loadShadingData(prevHit, -prevViewDir, lod);

                float3 rcRetraceRadiance = float3(0);
                if (!randomReplay(sd, reservoir, retraceSurface, rcRetraceRadiance))
                {
                    retraceSurface = RetracedSurface();
                }

                gRetraceRCPathThp[pixel] = float4(rcRetraceRadiance,1);
                gRetraceSurface[reservoirIndex] = retraceSurface;
            }
        }

        // Random Replay for other reservoir
        if (gPassIdentifier == 0 || gPassIdentifier == 2){
            ReservoirPT resampleReservoir = gReservoirPrev[index2Dto1D(prevPixel, dispatchDims.x)];
            bool randomReplayNeeded = resampleReservoir.rcPathLength != 1;
            if (kRetraceRCPath)
                randomReplayNeeded = true;
            if (randomReplayNeeded && any(resampleReservoir.F > 0)) {
                RetracedSurface retraceSurface = RetracedSurface();
                float3 viewDir = gView[pixel].xyz;
                ShadingData sd = loadShadingData(hitInfo, -viewDir, lod);

                float3 rcRetraceRadiance = float3(0);
                if (!randomReplay(sd, resampleReservoir, retraceSurface, rcRetraceRadiance))
                {
                    retraceSurface = RetracedSurface();
                }

                gRetraceRCPathThpPrev[pixel] = float4(rcRetraceRadiance, 1);
                gRetraceSurfacePrev[reservoirIndex] = retraceSurface;
            }
        }
    }
}
