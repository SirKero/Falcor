#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.Raytracing;
import Utils.Sampling.SampleGenerator;
import Utils.Color.ColorHelpers;
import Utils.Math.MathHelpers;
import Utils.Geometry.GeometryHelpers;
import Rendering.Lights.LightHelpers;
import Rendering.Lights.EmissiveLightSampler;
import Rendering.Lights.EmissiveLightSamplerHelpers;
import RenderPasses.PhotonGuiding.StructsAndHelpers;
import RenderPasses.PhotonGuiding.SharedEnums;
import RenderPasses.PhotonGuiding.NextEventEstimationHelper;

#ifndef USE_LIGHT_PATH_RETRACING
#define USE_LIGHT_PATH_RETRACING 0
#endif

Texture2D<PackedHitInfo> gVBuffer;
Texture2D<float4> gView;
Texture2D<float2> gMVec;
Texture2D<PackedHitInfo> gVBufferPrev;
Texture2D<float4> gViewPrev;

StructuredBuffer<PathReservoir> gPathReservoir;
RWStructuredBuffer<PathReservoir> gPathReservoirPrev;

RWTexture2D<float4> gRetraceReservoirPath;     // Retraced path for the current sample
RWTexture2D<float4> gRetraceReservoirPathPrev;     //Retraced path for the temporal sample

static const uint kRNGNumPasses = RNG_NUM_PASSES;
static const uint kMIHints = (uint)MaterialInstanceHints::AdjustShadingNormal;
static const uint kCausticInstanceMask = 2;
static const uint kAllPhotonInstanceMask = 0xFF;
static const bool kEvalDeltaPdfs = EVAL_DELTA_PDFS;
static const bool kUseEnvMap = USE_ENV_BACKGROUND;
static const bool kAlphaTest = true;
static const float kRoughnessThreshold = ROUGHNESS_THRESHOLD;
static const bool kUseEnvLight = USE_ENV_LIGHT;
static const bool kPhotonRussianRoulette = PHOTON_RUSSIAN_ROULETTE;

cbuffer CB
{
    uint gFrameCount; // Frame count since scene was loaded.
    uint gFGRayMaxPathLength;   // Max path length for a Final Gather sample
    float gSpatialSampleRadius; // Pixel area at distance 1 used in light trace
    uint gNumResamplingPass;

    float gJacobianDistanceThreshold; // Depth threshold for jacobian
    float3 gNeeLightSelectProb;       // Light selection probabilities for NEE

    uint gGuidingTextureResolution; // Resolution of all guiding textures. xy is the same
    int gSeperatePasses; // -1 - Trace both camera passes in the same pass; 0 - Retrace current; 1- Retrace other; 2 - Photon retrace current; 3- Photon retrace prev
}

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

//Struct with all needed path data
struct RetracePathData {
    float3 thp;             //Throughput
    float scatterPDF;       //scatter pdf for last hit

    float3 F;               //Accumulated path radiance
    uint pathLength;        //Current path length

    bool lastHitDiffuse;
    bool specularPath;      //True if the full path is specular
    bool retraceSuccessful; // True if the retraced path matches the one used to generate the reservoir
    uint flags;             // debug flags

    __init() {
        thp = float3(1);
        scatterPDF = 0;
        F = float3(0);
        pathLength = 0;
        lastHitDiffuse = true;
        specularPath = true;
        retraceSuccessful = false;
        flags = 0;
    }
}

//Data for visibility test if needed
struct VisibilityTestData {
    float3 rayOrigin;
    bool useVisTest;
    float3 rayDirection;
    float distanceToLight;

    __init() {
        rayOrigin = float3(0);
        useVisTest = false;
        rayDirection = float3(0);
        distanceToLight = -1;
    }
}

bool sampleNewDirection(ShadingData sd, IMaterialInstance mi, inout SampleGenerator sg, inout RetracePathData pd, inout RayDesc ray) {
    // Photon Bounce for next iteration
    BSDFSample bsdfSample;
    bool validSample = mi.sample(sd, sg, bsdfSample, true /*ImportanceSampling*/);
    if (validSample) {
        bool transmission = bsdfSample.isLobe(LobeType::Transmission);
        bool disableDeltaPdf = bsdfSample.isLobe(LobeType::Delta) && !kEvalDeltaPdfs; // If true uses 1 for pdf
        ray.Origin = sd.computeNewRayOrigin(!transmission); // false is for transmissions
        ray.Direction = bsdfSample.wo;

        pd.thp *= bsdfSample.weight;
        pd.scatterPDF = disableDeltaPdf ? 1.0 : bsdfSample.pdf;
    }
  
    return validSample;
}

bool randomReplayPhotonPath(PathReservoir reservoirs, out float3 samplePosW, out float3 sampleFlux)
{
    samplePosW = float3(0);
    sampleFlux = float3(0);
    //Recreate Light Dir Sample generator
    SampleGenerator sg = SampleGenerator(reservoirs.photonRetraceData.startPixel, reservoirs.photonRetraceData.startSeed);

    //Create pls to get start position for the path
    PhotonLightSample pls = PhotonLightSample();
    pls.lightIdx = reservoirs.lightIndex;
    pls.guidingPixels = reservoirs.guidingPixels;
    pls.useRandomLightDirection = reservoirs.photonRetraceData.usedRandomDirection;
    photonRetraceRecreateDirectionsRandomValues(pls, sampleNext2D(sg), gGuidingTextureResolution);

    RayDesc ray = {};
    if(!photonSampleLight(pls, ray, sg))
        return false;

    const uint targetPathLength = reservoirs.photonRetraceData.pathLength;
    RayPayload rayPayload = RayPayload();
    bool validPhoton = false;
    bool lastHitSpecular = false;
    float3 thp = float3(1);
    sampleFlux = pls.flux;

    for (uint i = 0; i <= targetPathLength; i++) {
        TraceRay(gScene.rtAccel, 0 /*Flags*/, 0xff /* instanceInclusionMask */, 0 /* hitIdx */, rayTypeCount, 0 /* missIdx */, ray, rayPayload);

        HitInfo hit = HitInfo(rayPayload.packedHitInfo);
        if (!hit.isValid())
            break;

        // Get shading infos
        let lod = ExplicitLodTextureSampler(0);
        // Get Material properties
        ShadingData sd = loadShadingData(hit, ray.Direction, lod);

        // Check if hit is valid for final gather
        if (i == targetPathLength) {
            validPhoton = true;
            samplePosW = sd.posW;
            sampleFlux *= thp;
            if (reservoirs.flags.isFinalGather)
                validPhoton &= distance(reservoirs.samplePosW, sd.posW) <= reservoirs.sampleRadius;
            //Check if caustic photon is still caustic
            if(reservoirs.flags.isCausticPhoton)
                validPhoton &= lastHitSpecular;
            break;
        }

        // Photon Bounce for next iteration
        uint hints = (uint)MaterialInstanceHints::AdjustShadingNormal;
        let mi = gScene.materials.getMaterialInstance(sd, lod, hints);
        let bsdfProperties = mi.getProperties(sd);
        BSDFSample bsdfSample;
        bool validSample = mi.sample(sd, sg, bsdfSample, true /*ImportanceSampling*/);
        if (!validSample || any(bsdfProperties.emission > 0))
            break;
        bool transmission = bsdfSample.isLobe(LobeType::Transmission);
        ray.Origin = sd.computeNewRayOrigin(!transmission); // false is for transmissions
        ray.Direction = bsdfSample.wo;
        lastHitSpecular = bsdfProperties.roughness < kRoughnessThreshold;

        thp *= bsdfSample.weight;
        // Russian roulette
        if (kPhotonRussianRoulette) {
            float rrRand = sampleNext1D(sg);
            const float rrVal = luminance(thp);
            if ((rrRand > rrVal))
            {
                break; // Photon is absorbed
            }
            thp /= rrVal;
        }

    }

    return validPhoton;
}

bool randomReplay(ShadingData primSD, PathReservoir reservoir, inout SampleGenerator sg , inout RetracedPath retracedPath)
{
    let lod = ExplicitLodTextureSampler(0);
    const uint2 dispatchDims = DispatchRaysDimensions().xy;

    // Init needed path data
    SampleGenerator rayDirSg = reservoir.sgPathDirections;
    RetracePathData rpd = RetracePathData();

    // Get starting ray
    RayDesc ray = {};
    ray.TMin = 0;
    ray.TMax = FLT_MAX;
    let primMI = gScene.materials.getMaterialInstance(primSD, lod, kMIHints);
    let primProperties = primMI.getProperties(primSD);
    RayPayload rayPayload = RayPayload();
    rpd.lastHitDiffuse = primProperties.roughness > kRoughnessThreshold;
    rpd.specularPath &= !rpd.lastHitDiffuse;
    bool firstHitIsDelta = primProperties.roughness < 0.08;

    if ((reservoir.flags.firstHitIsDelta && rpd.lastHitDiffuse) || (!reservoir.flags.firstHitIsDelta && !rpd.lastHitDiffuse))
        return false;

    if (!sampleNewDirection(primSD, primMI, rayDirSg, rpd, ray))
        return false;

    bool triedToSetFGSurface = false;
    bool isFirstCollectionSurface = true;
    float3 prevPosW = primSD.posW;
    float3 prevFaceN = primSD.faceN;
    // Trace Loop
    for (uint pathLength = 1; pathLength <= reservoir.pathLength; pathLength++)
    {
        TraceRay(gScene.rtAccel, 0, 0xff, 0, rayTypeCount, 0, ray, rayPayload);
        HitInfo hit = HitInfo(rayPayload.packedHitInfo);

        //Scene Miss
        if (!hit.isValid()) {
            bool validEnvSample = reservoir.flags.isEnvMapHit && pathLength == reservoir.pathLength;
            validEnvSample &= reservoir.pathLength > 1 || (pathLength == 1 && firstHitIsDelta);
            if (validEnvSample) {
                float misWeight = 1.0;
                if (kUseEnvLight && rpd.lastHitDiffuse) {
                    float lightPdf = gNeeLightSelectProb[kNeeLightTypeEnvMap] * gEnvMapSampler.evalPdf(ray.Direction);
                    misWeight = evalMIS(1, rpd.scatterPDF, 1, lightPdf);
                }
                float3 envMapContribution = gScene.envMap.eval(ray.Direction) * rpd.thp * misWeight;
                rpd.flags = (uint)ReservoirPathFlags::isEnvMapHit;
                retracedPath.jacobian = rpd.scatterPDF;
                retracedPath.F = envMapContribution;
                rpd.retraceSuccessful = true;
            }
            break;
        }

        // Load shading structs
        ShadingData sd = loadShadingData(hit, ray.Direction, lod);
        let mi = gScene.materials.getMaterialInstance(sd, lod, kMIHints);
        let bsdfProperties = mi.getProperties(sd);
        float rayDist = distance(ray.Origin, sd.posW);
        bool jacobianDistanceThreshold = rayDist > gJacobianDistanceThreshold;
        bool hitIsDiffuse = (bsdfProperties.roughness > kRoughnessThreshold) && jacobianDistanceThreshold; // Either diffuse surface or emissive hit
        bool hitIsEmissive = any(bsdfProperties.emission > 0);
        float jacobian = rpd.scatterPDF * abs(dot(ray.Direction, sd.faceN)) / (rayDist * rayDist); //Jacobian for this iteration

        // Delta -> Emissive case
        if (reservoir.flags.isEmissiveHit && pathLength == reservoir.pathLength && (rpd.specularPath || reservoir.flags.firstHitIsDelta) && hitIsEmissive)
        {
            float misWeight = 1.0;
            float neeEmissiveProbability = gNeeLightSelectProb[kNeeLightTypeEmissive];
            if (neeEmissiveProbability > 0 && rpd.lastHitDiffuse)
            {
                // Get hit in light collection representation
                TriangleHit triangleHit = hit.getTriangleHit();
                TriangleLightHit lightHit;
                lightHit.triangleIndex = gScene.lightCollection.getTriangleIndex(triangleHit.instanceID, triangleHit.primitiveIndex);
                lightHit.posW = sd.posW;
                lightHit.normalW = sd.getOrientedFaceNormal();
                float neePDF = neeEmissiveProbability * gEmissiveSampler.evalPdf(prevPosW, prevFaceN, true, lightHit);
                misWeight = evalMIS(1.0, rpd.scatterPDF, 1.0, neePDF);
            }
            retracedPath.F = bsdfProperties.emission * rpd.thp * misWeight;
            retracedPath.jacobian = jacobian; // Jacobian Path == 1, as all hits are delta/specular
            rpd.flags = (uint)ReservoirPathFlags::isEmissiveHit;
            rpd.retraceSuccessful = true;
            break;
        }

        // If we hit an emissive surface the path is undefined
        if (hitIsEmissive)
            break;

        // Collect photons or set reconnection surface
        if (hitIsDiffuse && pathLength == reservoir.pathLength) {
            retracedPath.jacobian = jacobian;
            float3 toSample = float3(0);
            float distToSample = -1;
            if (reservoir.flags.isFinalGather)
            {
                toSample = reservoir.samplePosW - sd.posW;
                distToSample = length(toSample);
                toSample /= distToSample;
                // Jacobian to Sample
                float pdf = mi.evalPdf(sd, toSample);
                retracedPath.jacobian = abs(dot(reservoir.sampleNormal, -toSample)) / (distToSample * distToSample);
                retracedPath.jacobian *= pdf;
               
                retracedPath.F = reservoir.photonFlux / pdf; //BSDF and thp is added later
                rpd.flags = (uint)ReservoirPathFlags::isFinalGather;
            } else if (reservoir.flags.isRadianceEstimate)
            {
                bool isReconnectable = distance(reservoir.samplePosW, sd.posW) < reservoir.sampleRadius;
                retracedPath.F = reservoir.photonFlux * rpd.thp;
                rpd.flags = isReconnectable ? (uint)ReservoirPathFlags::isRadianceEstimate : 0;
                rpd.retraceSuccessful = isReconnectable;
            } else if (reservoir.flags.isNEE)
            {
                sg = reservoir.sgNeeLightSelection;
                LightSample ls;
                bool validLight = generateAndSelectLightSample(sd, gNeeLightSelectProb, ls, sg);
                if (validLight && ls.pdf > 0 && ls.distance > gJacobianDistanceThreshold) {
                    rpd.flags = (uint)ReservoirPathFlags::isNEE;
                    retracedPath.jacobian = ls.pdf;
                    float misWeight = 1.0;
                    if (ls.type != kNeeLightTypeAnalytic) {
                        float scatterPdf = mi.evalPdf(sd, ls.dir);
                        misWeight = evalMIS(1.0, ls.pdf, 1.0, scatterPdf);
                    }
                    retracedPath.F = ls.Li * misWeight; // BSDF and thp is added later
                    if (!ls.isInfiniteDistance)
                        retracedPath.jacobian *= abs(dot(ls.faceN, ls.dir)) / (ls.distance * ls.distance);
                    toSample = ls.dir;
                    distToSample = ls.distance;
                }
            }

            if ((rpd.flags == (uint)ReservoirPathFlags::isNEE) || (rpd.flags == (uint)ReservoirPathFlags::isFinalGather))
            {
                float3 bsdf = mi.eval(sd, toSample, sg);
                retracedPath.F *= bsdf * rpd.thp;
                if (!dispatchShadowRay(sd, toSample, distToSample))
                    retracedPath.F = float3(0);

                rpd.retraceSuccessful = any(retracedPath.F > 0);
            }

            break;
        }

        // Sample new ray
        triedToSetFGSurface |= rpd.lastHitDiffuse; // If 1 diffuse surface was encountered, it was tried to set the Final Gather surface
        rpd.lastHitDiffuse = hitIsDiffuse;
        rpd.specularPath &= !hitIsDiffuse;
        prevPosW = sd.posW;
        prevFaceN = sd.faceN;

        if (!sampleNewDirection(sd, mi, rayDirSg, rpd, ray))
            break;    
    }

    return rpd.retraceSuccessful;
}



[shader("miss")]
void miss(inout RayPayload rayData: SV_RayPayload)
{
    HitInfo hitInfo = {};
    rayData.packedHitInfo = hitInfo.getData(); // Invalid hit
}

//For alpha test
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

//TODO update photon radiance
void retracePhotonPath(uint2 pixel, uint2 dispatchDims)
{
    const uint reservoirIndex = index2Dto1D(pixel, dispatchDims.x); //The reservoir index is used by both retraced paths

    // Retrace photon path for the sample of the currently generated reservoir
    // As we do not have the previous Acceleration Structure available, this will always be true/the same path, however, it is performed for consitency
    //if (gSeperatePasses == 2) 
    {
        PathReservoir reservoir = gPathReservoir[reservoirIndex];
        RetracedPath retracedPath = RetracedPath(); // This is used as a proxy to temporally store data
        retracedPath.jacobian = 0; //set invalid
        bool isLightPath = reservoir.flags.isFinalGather || reservoir.flags.isRadianceEstimate;
        if (reservoir.isValid() && isLightPath) {
            float3 photonSamplePosW, photonSampleFlux;
            if (randomReplayPhotonPath(reservoir, photonSamplePosW, photonSampleFlux)) {
                photonSampleFlux *= reservoir.photonGuidingPdf;
                retracedPath.F = photonSamplePosW;
                retracedPath.jacobian = 1;
            }
        }
        gRetraceReservoirPath[pixel] = retracedPath.pack();
    }

    //Retrace photon path for the reservoirs from the previous frame. Updates the Reservoir
    //if (gSeperatePasses == 3) //It seems 1 pass is faster
    {
        PathReservoir resampleReservoir = gPathReservoirPrev[reservoirIndex];
        bool isLightPath = resampleReservoir.flags.isFinalGather || resampleReservoir.flags.isRadianceEstimate;
        if (resampleReservoir.isValid() && isLightPath) {
            float3 photonSamplePosW, photonSampleFlux;
            if (randomReplayPhotonPath(resampleReservoir, photonSamplePosW, photonSampleFlux)) {
                photonSampleFlux *= resampleReservoir.photonGuidingPdf;
                if (resampleReservoir.flags.isRadianceEstimate)
                    resampleReservoir.samplePosW = photonSamplePosW; //For caustics update samplePosW. Is checked on camera retrace
                // resampleReservoir.photonFlux = photonSampleFlux; //TODO
            } else {
                resampleReservoir.F = float3(0);
            }
            gPathReservoirPrev[reservoirIndex] = resampleReservoir;
        }
    }
}

void retraceCameraPath(uint2 pixel, uint2 dispatchDims)
{
    HitInfo hitInfo = HitInfo(gVBuffer[pixel]);
    if (hitInfo.isValid()) {
        SampleGenerator sgPixelOffset = SampleGenerator( pixel, gFrameCount * kRNGNumPasses + 4 + (gNumResamplingPass * 3)); // Sampe generator for the pixel offset (search region)
        SampleGenerator sg = SampleGenerator(pixel, gFrameCount * kRNGNumPasses + 4 + (gNumResamplingPass * 3) + 1); // Sample generator for bsdf evaluation

        // Reprojection with motion vectors
        bool isSpatial = gNumResamplingPass > 0;
        float2 motionOffset = gMVec[pixel] * float2(dispatchDims);
        float2 prevPixelF = motionOffset + float2(pixel) + float2(0.5);
        float2 u = sampleNext2D(sgPixelOffset);
        if (isSpatial) {
            float2 spatialOffset = gSpatialSampleRadius * sample_disk_concentric(u);
            prevPixelF += spatialOffset;
        } else // Temporal; Add subpixel offset
        {
            prevPixelF += u - 0.5; // [-0.5, 0.5]
        }
        int2 prevPixel = int2(prevPixelF);

        // Check if previous pixel is inside the screen, if not, reservoir is not selected during resampling
        if (any(prevPixel < 0) || any(prevPixel >= dispatchDims))
        {
            return;
        }

        let lod = ExplicitLodTextureSampler(0);
        const uint reservoirIndex = index2Dto1D(pixel, dispatchDims.x);

        // Random Replay for the reservoir generated this frame
        if (gSeperatePasses == -1 || gSeperatePasses == 0) {
            PathReservoir reservoir = gPathReservoir[reservoirIndex];
            RetracedPath retraceSurface = RetracedPath();
            bool lightPathValid = true;
            #if USE_LIGHT_PATH_RETRACING
            if (!isSpatial && (reservoir.flags.isFinalGather || reservoir.flags.isRadianceEstimate))
            {
                retraceSurface = RetracedPath(gRetraceReservoirPath[pixel]);
                if (retraceSurface.jacobian < 1)
                    lightPathValid = false;
                else if (reservoir.flags.isRadianceEstimate)
                    reservoir.samplePosW = retraceSurface.F;
                retraceSurface.F = float3(0);
            }
            #endif
            // Only retrace if the reservoir is valid and path length > 0. Path length == 0 can only be Final Gather, which is checked during resampling
            if (reservoir.isValid() && reservoir.pathLength > 0 && lightPathValid) {
                // Get starting surface for temporal retrace
                HitInfo prevHit = HitInfo(gVBufferPrev[prevPixel]);
                float3 prevViewDir = gViewPrev[prevPixel].xyz;              
                ShadingData sd = loadShadingData(prevHit, -prevViewDir, lod);

                // Retrace camera path
                if(!randomReplay(sd, reservoir, sg, retraceSurface))
                    retraceSurface.F = float3(0);
            }
            gRetraceReservoirPath[pixel] = retraceSurface.pack();
        }

        //Random Replay for resampled reservoir
        if (gSeperatePasses == -1 || gSeperatePasses == 1) {
            const uint resampleReservoirIndex = index2Dto1D(prevPixel, dispatchDims.x);
            PathReservoir resampleReservoir = gPathReservoirPrev[resampleReservoirIndex];

            RetracedPath retraceSurface = RetracedPath();
            if (resampleReservoir.isValid() && resampleReservoir.pathLength > 0) {
                float3 viewDir = gView[pixel].xyz;
                ShadingData sd = loadShadingData(hitInfo, -viewDir, lod);

                if(!randomReplay(sd, resampleReservoir, sg, retraceSurface))
                    retraceSurface.F = float3(0);
            }
            gRetraceReservoirPathPrev[pixel] = retraceSurface.pack();
        }
    }
}

[shader("raygeneration")]
void rayGen()
{
    uint2 pixel = DispatchRaysIndex().xy;
    uint2 dispatchDims = DispatchRaysDimensions().xy;

    if (gSeperatePasses == 2) // || gSeperatePasses == 3)
        retracePhotonPath(pixel, dispatchDims);
    else
        retraceCameraPath(pixel, dispatchDims);
}
