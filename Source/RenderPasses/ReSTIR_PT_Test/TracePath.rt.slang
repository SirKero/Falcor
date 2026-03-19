#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.Raytracing;
import Scene.RaytracingInline;
import Utils.Sampling.SampleGenerator;
import Utils.Color.ColorHelpers;
import Utils.Math.MathHelpers;
import Rendering.Lights.LightHelpers;
import Rendering.Lights.EmissiveLightSampler;
import Rendering.RTXDI.RTXDI;
import SharedStructsAndFunctions;
import NextEventEstimationHelper;

cbuffer CB
{
    uint gFrameCount; // Current FrameCount for RNG
    float3 gNeeLightTypeSelectProbability; // Emissive, Analytic, EnvMap
    PackedPathLength gPackedPathLength;   //Path Length 

}

Texture2D<PackedHitInfo> gVBuffer;
Texture2D<float4> gView;

RWStructuredBuffer<ReservoirPT> gReservoir;
RWTexture2D<float4> gColorOut;

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

struct PathData {
    float3 thp;
    float outgoingJacobianPdf;  //Jacobian with scatter event after reconnection surface

    float3 reconThp;        //thp for reconnect
    float scatterPdf;       //Last pdf (used for MIS)

    bool reconnectIsSet;
    bool lastHitWasDiffuse;
    uint pathLength;
    uint rcPathLength;

    float2 packedSampleWo; // Packed sample Wo for jacobian after resampling surface
    float jacobianRc;   //Jacobian from rc to sample

    __init() {
        thp = float3(1.0);
        reconThp = float3(1.0);
        outgoingJacobianPdf = 1;
        scatterPdf = 0;
        lastHitWasDiffuse = false;
        pathLength = 0;
        reconnectIsSet = false;
        rcPathLength = UINT32_MAX;
        packedSampleWo = float2(0);
        jacobianRc = 1;
    }
}

bool sampleNewRay(ShadingData sd, IMaterialInstance mi, inout SampleGenerator sg, inout PathData pd, inout RayDesc ray, out int lobeType)
{
    lobeType = -1;
    BSDFSample bsdfSample;
    bool validSample = mi.sample(sd, sg, bsdfSample, true);
    if (validSample) {
        bool transmission = bsdfSample.isLobe(LobeType::Transmission);
        bool disableDeltaPdf = bsdfSample.isLobe(LobeType::Delta) && !kEvalDeltaPdfs; //If true uses 1 for pdf
        ray.Origin = sd.computeNewRayOrigin(!transmission); // false is for transmissions
        ray.Direction = bsdfSample.wo;

        lobeType = getLobeType(bsdfSample);

        if (pd.reconnectIsSet)
            pd.reconThp *= bsdfSample.weight;
        else
            pd.thp *= bsdfSample.weight; pd.scatterPdf = disableDeltaPdf ? 1.0 : bsdfSample.pdf;
        if (pd.pathLength == pd.rcPathLength) {
            pd.outgoingJacobianPdf = bsdfSample.pdf;
            pd.packedSampleWo = ndir_to_oct_snorm(bsdfSample.wo);
        }
            
    }

    return validSample && any((pd.thp * pd.reconThp) > 0);
}

/* Add sample to reservoir
    \param[inout] reservoir Reservoir to add the sample to.
    \param[in] rand Random number in [0,1).
    \param[in] rcThp Throughput after reconnection to light source.
    \param[in] thp Throughput until the reconnection surface.
*/
bool addSampleToReservoir(inout ReservoirPT reservoir, float rand, float3 rcThp, float3 thp)
{
    float3 F = rcThp * thp;
    float w = luminance(F);
    reservoir.weight += w;
    bool selectOther = rand * reservoir.weight <= w;
    if (selectOther) {
        reservoir.F = F;
        reservoir.rcThp = rcThp;
        reservoir.thp = thp;
    }
    return selectOther;
}

float3 tracePath(RayDesc ray, inout SampleGenerator sg, inout SampleGenerator rayDirSg, inout PathData pd, inout ReservoirPT reservoir, int firstHitReflectionLobe)
{
    float3 outColor = float3(0);
    RayPayload rayPayload = RayPayload();

    // Used for scatter MIS (at pathLength > 0)
    float3 lastOrigin = ray.Origin;
    float3 lastFaceNormal = float3(0, 1, 0);

    PackedPathLength currentPathLength = PackedPathLength();
    updatePathLength(currentPathLength, firstHitReflectionLobe);
    for (pd.pathLength = 1; pd.pathLength <= gPackedPathLength.pathLength; pd.pathLength++) {
        TraceRay(gScene.rtAccel, 0 /*Flags*/, 0xff /* instanceInclusionMask */, 0 /* hitIdx */, rayTypeCount, 0 /* missIdx */, ray, rayPayload);
        // Get surface hit info
        HitInfo hit = HitInfo(rayPayload.packedHitInfo);
        //Scene miss (eval env map)
        if (!hit.isValid()) {
            if (kUseEnvMap && pd.pathLength > 1) {
                // MIS
                float misWeight = 1.0;
                if (kUseEnvLight && pd.lastHitWasDiffuse) {
                    float lightPdf = gNeeLightTypeSelectProbability[kNeeLightTypeEnvMap] * gEnvMapSampler.evalPdf(ray.Direction);
                    misWeight = evalMIS(1, pd.scatterPdf, 1, lightPdf);
                }
                float3 envMapContribution = misWeight * gScene.envMap.eval(ray.Direction) * pd.reconThp;
                if (addSampleToReservoir(reservoir, sampleNext1D(sg), envMapContribution, pd.thp)) {
                    reservoir.pathLength = pd.pathLength;
                    uint pathFlags = (uint)ReservoirPathFlags::isEnvMapMiss;
                    if (!pd.reconnectIsSet) {
                        pd.jacobianRc = pd.scatterPdf;
                        pathFlags |= (uint)ReservoirPathFlags::hasNoReconnectionSurface;
                    }
                    reservoir.jacobianDeterminant = pd.jacobianRc;
                    reservoir.jacobianOutgoing = pd.outgoingJacobianPdf;
                    reservoir.flags.setReservoirPathFlags(pathFlags);
                      
                }
                
                outColor += envMapContribution * pd.thp;
            }
            break;
        }

        // Get shading infos
        let lod = ExplicitLodTextureSampler(0);

        // Get Material properties
        ShadingData sd = loadShadingData(hit, ray.Direction, lod);
        let mi = gScene.materials.getMaterialInstance(sd, lod, kMIHints);
        let bsdfProperties = mi.getProperties(sd);

        //Check if reuse or sample surface can be set
        bool hitIsDiffuse = bsdfProperties.roughness > kRoughnessThreshold;
        bool hitEmissive = any(bsdfProperties.emission > 0);
        if (!pd.reconnectIsSet && hitIsDiffuse && !hitEmissive) {
            // If last and current hit is diffuse it is a valid reservoir
            float rayDist = distance(ray.Origin, sd.posW);
            bool jacobianDistanceCheck = rayDist > kJacobianDistanceThreshold;
            if (pd.lastHitWasDiffuse && jacobianDistanceCheck) {
                reservoir.packedSampleSurface = rayPayload.packedHitInfo;

                pd.jacobianRc = pd.scatterPdf * abs(dot(sd.faceN, -ray.Direction)) / (rayDist * rayDist); // Reconnection jacobian determinant
                reservoir.packedSampleWo = pd.packedSampleWo;
                pd.reconnectIsSet = true;
                reservoir.rcPathLength = pd.pathLength;
                pd.rcPathLength = pd.pathLength; //used to set certain values for the reservoir
            }
        }

        // Ray hits emissive (only used after 2nd bounce, as RTXDI handles direct light)
        if (hitEmissive && pd.pathLength > 1) {
            //Get hit in light collection representation
            TriangleHit triangleHit = hit.getTriangleHit();
            TriangleLightHit lightHit;
            lightHit.triangleIndex = gScene.lightCollection.getTriangleIndex(triangleHit.instanceID, triangleHit.primitiveIndex);
            lightHit.posW = sd.posW;
            lightHit.normalW = sd.getOrientedFaceNormal();

            // MIS
            float misWeight = 1;
            if (pd.lastHitWasDiffuse) {
                float neePDF = gNeeLightTypeSelectProbability[kNeeLightTypeEmissive] * gEmissiveSampler.evalPdf(lastOrigin, lastFaceNormal, true, lightHit);
                misWeight = evalMIS(1.0, pd.scatterPdf, 1.0, neePDF);
            }

            float3 emissiveRadiance = misWeight * bsdfProperties.emission * pd.reconThp; // Is also w, as primary path space is used (pdf == 1)
            if (addSampleToReservoir(reservoir, sampleNext1D(sg), emissiveRadiance, pd.thp))
            {
                reservoir.pathLength = pd.pathLength;
                uint pathFlags = (uint)ReservoirPathFlags::isScatter;
                if (!pd.reconnectIsSet) {
                    float distToSample = distance(lastOrigin, sd.posW);
                    pd.jacobianRc = pd.scatterPdf * abs(dot(lastFaceNormal, ray.Direction)) / (distToSample * distToSample);
                    pathFlags |= (uint)ReservoirPathFlags::hasNoReconnectionSurface;
                }
                reservoir.jacobianDeterminant = pd.jacobianRc;
                reservoir.jacobianOutgoing = pd.outgoingJacobianPdf;
                reservoir.packedSampleWo = pd.packedSampleWo;
                reservoir.flags.setReservoirPathFlags(pathFlags);
            }

            outColor += emissiveRadiance;
        }

        // Scatter ray should be traced for the current iteration. Additionally, emissive reflections are undefined
        if (pd.pathLength >= gPackedPathLength.pathLength || hitEmissive)
            break;

        // Sample light (NEE)
        if (hitIsDiffuse) {
            LightSample ls;
            SampleGenerator neeSgState = sg; // Cache sampleGenerator state
            float3 nee = nextEventEstimation(sd, mi, gNeeLightTypeSelectProbability , ls, sg) * pd.reconThp;
            //TODO use endIsNEE case if sample is below the distance threshold? 
            if (addSampleToReservoir(reservoir, sampleNext1D(sg), nee, pd.thp) && any(nee > 0))
            {
                reservoir.pathLength = pd.pathLength;
                reservoir.sgRCNee = neeSgState;
                uint pathFlags = (uint)ReservoirPathFlags::isNee;
                if (!pd.reconnectIsSet) {
                    pd.jacobianRc = ls.pdf;
                    if (!ls.isInfiniteDistance) {
                        pd.jacobianRc *= abs(dot(sd.faceN, ls.dir)) / (ls.distance * ls.distance);
                    }
                    pathFlags |= (uint)ReservoirPathFlags::hasNoReconnectionSurface;
                    pathFlags |= (uint)ReservoirPathFlags::endIsNee;
                }
                if (pd.pathLength == pd.rcPathLength) {
                    pathFlags |= (uint)ReservoirPathFlags::isNeeAfterReconnection;
                    pd.outgoingJacobianPdf = 1; //ls.pdf; //TODO should be fine, as nee does not depend on wi
                    pd.packedSampleWo = ndir_to_oct_snorm(ls.dir);
                }

                reservoir.jacobianDeterminant = pd.jacobianRc;
                reservoir.jacobianOutgoing = pd.outgoingJacobianPdf; // This is set every time a sample is accepted
                reservoir.packedSampleWo = pd.packedSampleWo;
                reservoir.flags.setReservoirPathFlags(pathFlags);
            }
            outColor += nee;
        }
       
        lastOrigin = sd.posW;
        lastFaceNormal = sd.faceN;

        // New ray
        pd.lastHitWasDiffuse = hitIsDiffuse;
        int lobeType = -1;
        if (!sampleNewRay(sd, mi, rayDirSg, pd, ray, lobeType))
            break;

        updatePathLength(currentPathLength, lobeType);
        if (!currentPathLength.comparePathLengts(gPackedPathLength))
            break;
    }

    // Finalize Reservoir
    if (any(reservoir.F > 0)) {
        reservoir.weight /= luminance(reservoir.F);
    }

    return outColor;
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
    float3 viewDir = -gView[pixel].xyz;
    float3 outColor = float3(0);
    ReservoirPT reservoir = ReservoirPT();

    if (hitInfo.isValid()) {
        // Set RTXDI data
        let lod = ExplicitLodTextureSampler(0);
        SampleGenerator sg = SampleGenerator(pixel, gFrameCount * kRNGNumPasses);
        SampleGenerator rayDirSg = SampleGenerator(pixel, gFrameCount * kRNGNumPasses + 1); // Seperate sample generator for ray directions (used in random replay)
        reservoir.sgPathDirections = rayDirSg; //Store state of sample generator

        ShadingData sd = loadShadingData(hitInfo, viewDir, lod);
        let mi = gScene.materials.getMaterialInstance(sd, lod, kMIHints);
        let bsdfProperties = mi.getProperties(sd);
        float distanceToSurface = distance(sd.posW, gScene.camera.getPosition());

        gRTXDI.setSurfaceData(pixel, sd.computeNewRayOrigin(), bsdfProperties.guideNormal, bsdfProperties.diffuseReflectionAlbedo, bsdfProperties.specularReflectance, bsdfProperties.roughness, distanceToSurface);

        // Prepare for the first ray
        PathData pd = PathData();
        pd.lastHitWasDiffuse = bsdfProperties.roughness > kRoughnessThreshold;
        bool firstHitIsDelta = !pd.lastHitWasDiffuse;

        RayDesc ray = {};
        ray.TMin = 0;
        ray.TMax = FLT_MAX;
        float3 thp = float3(1.0);

        int firstHitReflectionLobe = -1;
        if (sampleNewRay(sd, mi, rayDirSg, pd, ray, firstHitReflectionLobe))
            outColor = tracePath(ray, sg, rayDirSg, pd, reservoir, firstHitReflectionLobe);
       
            

        //Set reservoir flag
        reservoir.flags.firstHitIsDelta = firstHitIsDelta;

    } else
    {
        // Set invalid RTXDI data
        gRTXDI.setInvalidSurfaceData(pixel);
    }

    gReservoir[index2Dto1D(pixel, dispatchDims.x)] = reservoir;
    gColorOut[pixel] = float4(outColor, 1);
}
