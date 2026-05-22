#pragma once
#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.Raytracing;
import Utils.Sampling.SampleGenerator;
import Utils.Color.ColorHelpers;
import Rendering.RTXDI.RTXDI;
import Rendering.Lights.EmissiveLightSampler;
import Rendering.Lights.EmissiveLightSamplerHelpers;
import StructsAndHelpers;
import PhotonHelper;
import NextEventEstimationHelper;

Texture2D<PackedHitInfo> gVBuffer;
Texture2D<float4> gView;

RWStructuredBuffer<PathReservoir> gPathReservoir;

RWTexture2D<float4> gDebug;

static const uint kMIHints = (uint)MaterialInstanceHints::AdjustShadingNormal;
static const bool kEvalDeltaPdfs = EVAL_DELTA_PDFS;
static const bool kUseEnvMap = USE_ENV_BACKGROUND;

cbuffer CB
{
    uint gFrameCount;           // Frame count since scene was loaded.
    uint gMaxPathLength; // Max path length for a Final Gather sample
    float gJacobianDistanceThreshold; // Jacobian distance threshold. Connection can only be performed if distance is greater
    float3 gNeeSelectProbabilites; //(Emissive/Analytic/EnvMap)Light selection probabilities for NEE samples.
}

static const bool kAlphaTest = ENABLE_ALPHA_TEST;
static const uint kRNGNumPasses = RNG_NUM_PASSES;
static const float kRoughnessThreshold = ROUGHNESS_THRESHOLD;
static const bool kUseEnvBackground = USE_ENV_BACKGROUND;

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

//PathFlags
enum PathFlags : uint {
    firstHitIsDelta = 0x100,          // 1<<8
    firstHitIsDiffuse = 0x200,        // 1<<9
    specularPath = 0x400,             // 1<<10
    lastHitDiffuse = 0x800,           // 1<<11
    lastHitNee = 0x1000,              // 1<<12
    unused0 = 0x2000,                 // 1<<13
    unused1 = 0x4000,                 // 1<<14
    unused2 = 0x8000,                 // 1<<15
}

//Struct with all needed path data
struct PathData {
    SampleGenerator dirSG;  // Sample Generator used for Random Replay
    SampleGenerator sg;     // Sample Generator used for everything else

    float3 thp;             //Throughput
    float scatterPDF;       //scatter pdf for last hit

    float3 F;               //Accumulated path radiance
    uint flags;             //Path Lenght and Flags

    float3 prevPosW;        //PosW from last frame
    float3 prevFaceN;       //Face Normal from last frame

    __init() {
        thp = float3(1);
        scatterPDF = 0;
        F = float3(0);
        flags = 0;
        prevPosW = float3(0);
        prevFaceN = float3(0);
    }

    property uint pathLength {
        get { return flags & 0xFF; }
        set {
            flags &= ~0xFF; // Clear lower bits
            flags |= (newValue & 0xFF);
        }
    }

    property bool firstHitIsDelta {
        get { return (flags & (uint)PathFlags::firstHitIsDelta) > 0; }
        set {
            flags &= ~(uint)PathFlags::firstHitIsDelta; // Clear bit
            flags |= (newValue ? (uint)PathFlags::firstHitIsDelta : 0);
        }
    }

    property bool firstHitIsDiffuse {
        get { return (flags & (uint)PathFlags::firstHitIsDiffuse) > 0; }
        set {
            flags &= ~(uint)PathFlags::firstHitIsDiffuse; // Clear bit
            flags |= (newValue ? (uint)PathFlags::firstHitIsDiffuse : 0);
        }
    }

    property bool specularPath {
        get { return (flags & (uint)PathFlags::specularPath) > 0; }
        set {
            flags &= ~(uint)PathFlags::specularPath; // Clear bit
            flags |= (newValue ? (uint)PathFlags::specularPath : 0);
        }
    }

    property bool lastHitDiffuse {
        get { return (flags & (uint)PathFlags::lastHitDiffuse) > 0; }
        set {
            flags &= ~(uint)PathFlags::lastHitDiffuse; // Clear bit
            flags |= (newValue ? (uint)PathFlags::lastHitDiffuse : 0);
        }
    }

    property bool lastHitNee {
        get { return (flags & (uint)PathFlags::lastHitNee) > 0; }
        set {
            flags &= ~(uint)PathFlags::lastHitNee; // Clear bit
            flags |= (newValue ? (uint)PathFlags::lastHitNee : 0);
        }
    }
}


bool sampleNewDirection(ShadingData sd, IMaterialInstance mi, inout PathData pd, inout RayDesc ray) {
    // Photon Bounce for next iteration
    BSDFSample bsdfSample;
    bool validSample = mi.sample(sd, pd.dirSG, bsdfSample, true /*ImportanceSampling*/);
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

/* Add sample to reservoir
    \param[inout] reservoir Reservoir to add the sample to.
    \param[in] rand Random number in [0,1).
    \param[in] rcThp Throughput after reconnection to light source.
    \param[in] thp Throughput until the reconnection surface.
*/
bool addSampleToReservoir(inout PathReservoir reservoir, float rand, float3 radiance, float3 thp)
{
    float3 F = radiance * thp;
    float w = luminance(F);
    reservoir.weight += w;
    bool selectOther = rand * reservoir.weight <= w;
    if (selectOther) {
        reservoir.F = F;
        reservoir.fgRadiance = radiance;
    }
    return selectOther;
}

void tracePath(RayDesc ray, inout PathData pd, inout PathReservoir pathReservoir)
{
    RayPayload rayPayload = RayPayload();
    for (pd.pathLength = 1; pd.pathLength <= gMaxPathLength; pd.pathLength = pd.pathLength + 1)
    {
        // Trace ray and get surface info
        TraceRay(gScene.rtAccel, 0 /*Flags*/, 0xff /* instanceInclusionMask */, 0 /* hitIdx */, rayTypeCount, 0 /* missIdx */, ray, rayPayload);
        HitInfo hit = HitInfo(rayPayload.packedHitInfo);

        // Scene miss (evaluate enviroment map). Path Lengh == 1 is covered by ReSTIR DI except the primary hit is delta
        if (!hit.isValid())
        {
            if ((pd.pathLength > 1) || (pd.pathLength == 1 && pd.firstHitIsDelta))
            {
                float misWeight = 1;
                // If last hit could have generated a Enviroment sample, calculate MIS weight
                if (gNeeSelectProbabilites[kNeeLightTypeEnvMap] > 0 && pd.lastHitNee)
                {
                    float lightPdf = gNeeSelectProbabilites[kNeeLightTypeEnvMap] * gEnvMapSampler.evalPdf(ray.Direction);
                    misWeight = evalMIS(1, pd.scatterPDF, 1, lightPdf);
                }
                float3 envMapContribution = kUseEnvMap ? gScene.envMap.eval(ray.Direction) * misWeight : float3(0);

                if (addSampleToReservoir(pathReservoir, sampleNext1D(pd.sg), envMapContribution, pd.thp))
                {
                    pathReservoir.jacobian = pd.scatterPDF;
                    uint flags = (uint)ReservoirPathFlags::hasNoReconnectionSurface | (uint)ReservoirPathFlags::isEnvMapHit;
                    flags |= pd.firstHitIsDelta ? 0 : (uint)ReservoirPathFlags::firstHitIsDelta;
                    // flags |= isFirstCollectionSurface ? (uint)ReservoirPathFlags::hasTwoCollectionPoints : 0;
                    pathReservoir.flags.setReservoirPathFlags(flags);
                }
            }
            break; //End Loop
        }

        // Load Material Information
        let lod = ExplicitLodTextureSampler(0);
        ShadingData sd = loadShadingData(hit, -ray.Direction, lod);
        let mi = gScene.materials.getMaterialInstance(sd, lod, kMIHints);
        let bsdfProperties = mi.getProperties(sd);
        float rayDist = distance(ray.Origin, sd.posW);
        bool jacobianDistanceThreshold = rayDist > gJacobianDistanceThreshold;
        bool hitIsDiffuse = bsdfProperties.roughness > kRoughnessThreshold && jacobianDistanceThreshold;
        bool hitIsEmissive = any(bsdfProperties.emission > 0);
        float jacobian = pd.scatterPDF * abs(dot(ray.Direction, sd.faceN)) / (rayDist * rayDist); // Jacobian for this iteration

        // Handle Emissive Hit. The sample is evaluated if the whole path is below the reconnection
        // threshold or if NEE was used in the last iteration.
        // Path length == 1 is covered by RTXDI, except when the first hit was delta
        if (pd.pathLength > 1 && pd.specularPath || (pd.pathLength == 1 && pd.firstHitIsDelta) || pd.lastHitNee)
        {
            float misWeight = 1.0;
            float neeEmissiveProbability = gNeeSelectProbabilites[kNeeLightTypeEmissive];
            if (neeEmissiveProbability > 0 && pd.lastHitNee)
            {
                // Get hit in light collection representation
                TriangleHit triangleHit = hit.getTriangleHit();
                TriangleLightHit lightHit;
                lightHit.triangleIndex = gScene.lightCollection.getTriangleIndex(triangleHit.instanceID, triangleHit.primitiveIndex);
                lightHit.posW = sd.posW;
                lightHit.normalW = sd.getOrientedFaceNormal();
                float neePDF = neeEmissiveProbability * gEmissiveSampler.evalPdf(pd.prevPosW, pd.prevFaceN, true, lightHit);
                misWeight = evalMIS(1.0, pd.scatterPDF, 1.0, neePDF);
            }
            float3 emissiveContribution = bsdfProperties.emission * misWeight;
            if (addSampleToReservoir(pathReservoir, sampleNext1D(pd.sg), emissiveContribution, pd.thp))
            {
                pathReservoir.jacobian = jacobian;
                uint flags = (uint)ReservoirPathFlags::hasNoReconnectionSurface | (uint)ReservoirPathFlags::isEmissiveHit;
                flags |= pd.firstHitIsDelta ? 0 : (uint)ReservoirPathFlags::firstHitIsDelta;
                pathReservoir.flags.setReservoirPathFlags(flags);
                pathReservoir.pathLength = pd.pathLength;
            }
        }

        //Stop on emissive hits, as reflection is undefined
        if (hitIsEmissive)
            break;

        // If the surface is diffuse, do radiance estimate and evaluate NEE
        pd.lastHitNee = false; //Reset flag
        if (hitIsDiffuse)
        {
            const bool isFinalGather = pd.lastHitDiffuse; // If the last two hits are diffuse, the hit is a final gather surface
            PhotonSample photonSample;
            photonRIS(sd, mi, bsdfProperties.guideNormal, !isFinalGather, pd.sg, photonSample);

            if (addSampleToReservoir(pathReservoir, sampleNext1D(pd.sg), photonSample.F, pd.thp))
            {
                pathReservoir.pathLength = isFinalGather ? pd.pathLength - 1 : pd.pathLength;
                pathReservoir.jacobian = jacobian;
                pathReservoir.sampleRadius = photonSample.radius;
                uint flags = 0;
                if (photonSample.photonType == kPhotonTypeIndexCaustic)
                    flags |= (uint)ReservoirPathFlags::isCaustic;
                //TODO Handle photon retracing

                if (isFinalGather)
                {
                    flags |= (uint)ReservoirPathFlags::isFinalGather;
                    pathReservoir.samplePosW = sd.posW;
                    pathReservoir.sampleNormal = sd.faceN;
                } else //Radiance Estimate
                {
                    flags |= (uint)ReservoirPathFlags::hasNoReconnectionSurface | (uint)ReservoirPathFlags::isRadianceEstimate;
                    pathReservoir.samplePosW = photonSample.posW;
                    pathReservoir.sampleNormal = photonSample.normal;
                    pathReservoir.sampleRadius = photonSample.radius;
                }
                flags |= pd.firstHitIsDelta ? 0 : (uint)ReservoirPathFlags::firstHitIsDelta;
                pathReservoir.flags.setReservoirPathFlags(flags);
            }

            // If only caustics where calculated, also do NEE
            if (!isFinalGather)
            {
                LightSample ls;
                float3 nee = nextEventEstimation(sd, mi, gNeeSelectProbabilites, ls, pd.sg);
                if (addSampleToReservoir(pathReservoir, sampleNext1D(pd.sg), nee, pd.thp))
                {
                    pathReservoir.jacobian = ls.pdf;
                    if (!ls.isInfiniteDistance) {
                        pathReservoir.jacobian *= abs(dot(ls.faceN, ls.dir)) / (ls.distance * ls.distance);
                    }
                    //TODO dir lights? 
                    pathReservoir.samplePosW = ls.position;
                    pathReservoir.sampleNormal = ls.faceN;
                    uint flags = (uint)ReservoirPathFlags::hasNoReconnectionSurface | (uint)ReservoirPathFlags::isNEE;
                    flags |= pd.firstHitIsDelta ? 0 : (uint)ReservoirPathFlags::firstHitIsDelta;
                    pathReservoir.flags.setReservoirPathFlags(flags);
                }
                pd.lastHitNee = true;
            }

            //Path is stopped after final gather
            if (isFinalGather)
                break;
        }

        //Update flags
        pd.lastHitDiffuse = hitIsDiffuse;
        pd.specularPath = pd.specularPath & !hitIsDiffuse;
        pd.prevPosW = sd.posW;
        pd.prevFaceN = sd.faceN;

        //Sample new ray direction
        if (!sampleNewDirection(sd, mi, pd, ray))
            break;
    }

    // Finalize Reservoir
    if (any(pathReservoir.F > 0))
        pathReservoir.weight /= luminance(pathReservoir.F);
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

[shader("raygeneration")]
void rayGen()
{
    uint2 pixel = DispatchRaysIndex().xy;
    uint2 dispatchDims = DispatchRaysDimensions().xy;

    HitInfo hitInfo = HitInfo(gVBuffer[pixel]);
    float3 viewDir = gView[pixel].xyz;
    float3 outColor = float3(0);
    PathReservoir pathReservoir = PathReservoir();

    //When first hit is valid
    if (hitInfo.isValid()) {
        // Init Materials and Sample Generators
        PathData pd = PathData();
        let lod = ExplicitLodTextureSampler(0);
        pd.sg = SampleGenerator(pixel, gFrameCount * kRNGNumPasses + 2);
        // Sample generator for sampling new directions, needed in Random Replay
        pd.dirSG = SampleGenerator(pixel, gFrameCount * kRNGNumPasses + 3);
        pathReservoir.sgPathDirections = pd.dirSG;

        ShadingData sd = loadShadingData(hitInfo, viewDir, lod);
        let mi = gScene.materials.getMaterialInstance(sd, lod, kMIHints);
        let bsdfProperties = mi.getProperties(sd);

        // Set RTXDI(ReSTIR DI) surface data
        float distanceToSurface = distance(sd.posW, gScene.camera.getPosition());
        gRTXDI.setSurfaceData(pixel, sd.computeNewRayOrigin(), bsdfProperties.guideNormal, bsdfProperties.diffuseReflectionAlbedo, bsdfProperties.specularReflectance, bsdfProperties.roughness, distanceToSurface);

        // Set Flags and data
        pd.firstHitIsDelta = bsdfProperties.roughness <= 0.08;
        pd.firstHitIsDiffuse = bsdfProperties.roughness > kRoughnessThreshold;
        pd.lastHitDiffuse = pd.firstHitIsDiffuse;
        pd.specularPath = !pd.firstHitIsDiffuse;
        pd.lastHitNee = false;
        pathReservoir.flags.firstHitIsDelta = pd.firstHitIsDelta;

        pd.prevPosW = sd.posW;
        pd.prevFaceN = sd.faceN;

        RayDesc ray = {};
        ray.TMin = 0;
        ray.TMax = FLT_MAX;
        if (sampleNewDirection(sd, mi, pd, ray))
            tracePath(ray, pd, pathReservoir);
    } else {
        // Set invalid RTXDI data
        gRTXDI.setInvalidSurfaceData(pixel);
    }

    gPathReservoir[index2Dto1D(pixel, dispatchDims.x)] = pathReservoir;
}
