#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.Raytracing;
import Scene.RaytracingInline;
import Utils.Sampling.SampleGenerator;
import Utils.Color.ColorHelpers;
import Rendering.Lights.LightHelpers;
import Rendering.Lights.EmissiveLightSampler;
import Rendering.Lights.EmissiveLightSamplerHelpers;
import StructsAndHelpers;
import SharedEnums;
import NextEventEstimationHelper;
import PhotonHelper;

Texture2D<PackedHitInfo> gVBuffer;
Texture2D<float4> gView;

RWTexture2D<float4> gOutColor;

cbuffer CB
{
    uint gFrameCount; // Frame count since scene was loaded.
    uint gMaxBounces; // Max path length for a Final Gather sample

    uint gNumLightPaths;               // Number of light paths for MIS
    uint gLightIndexGuidingResolution; // Resolution of "gLightIndexGuidingCounter"

    float3 gLightTypeSelectProbability; // Probability of selecting each light type in NEE
}

static const float kPhotonCollectTMax = 1e-7;
static const bool kUseEnvMap = USE_ENV_MAP;
static const bool kAlphaTest = true;
static const float kRoughnessThreshold = ROUGHNESS_THRESHOLD;
static const float3 kDefaultBackgroundColor = float3(0.0);
static const uint kRenderMode = RENDER_TECHNIQUE;
static const uint kRNGNumPasses = RNG_NUM_PASSES;
static const bool kUseEnvLight = USE_ENV_LIGHT;

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

//Helper struct for MIS
struct CameraState {
    float3 thp;
    uint pathLength;

    float3 prevPosW;
    uint diffuseHitCount;

    float3 prevFaceN;
    bool isSpecularPath;

    float scatterPDF;

    __init() {
        pathLength = 0;
        isSpecularPath = true;
        diffuseHitCount = 0;
        thp = float3(1);
        prevPosW = float3(0);
        prevFaceN = float3(0, 1, 0);
        scatterPDF = 0.0;
    }
}

bool sampleNewRay(ShadingData sd, IMaterialInstance mi, float roughness, inout SampleGenerator sg, inout CameraState camState, inout RayDesc ray)
{
    // Abort on diffuse surfaces
    bool isDiffuse = roughness > kRoughnessThreshold;
    bool abortPath = false;
    if (kRenderMode == (uint)PhotonRenderMode::PhotonMapping)
        abortPath = isDiffuse;
    else if (kRenderMode == (uint)PhotonRenderMode::FinalGathering)
        abortPath = camState.diffuseHitCount > 0;

    if (abortPath)
        return false;

    BSDFSample bsdfSample;
    if (!mi.sample(sd, sg, bsdfSample, true /*ImportanceSampling*/))
        return false;

    bool transmission = bsdfSample.isLobe(LobeType::Transmission);
    ray.Origin = sd.computeNewRayOrigin(!transmission); // false is for transmissions
    ray.Direction = bsdfSample.wo;
    camState.thp *= bsdfSample.weight;
    camState.scatterPDF = bsdfSample.pdf;

    camState.pathLength++;
    camState.isSpecularPath &= !isDiffuse;
    camState.diffuseHitCount += isDiffuse ? 1 : 0;
    camState.prevPosW = sd.posW;
    camState.prevFaceN = sd.faceN;

    return true;
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

    float3 outColor = float3(0);
    CameraState camState = CameraState();
    let lod = ExplicitLodTextureSampler(0);
    SampleGenerator sg = SampleGenerator(pixel, gFrameCount * kRNGNumPasses + 1);
    RayPayload rayPayload = RayPayload();
    RayDesc ray;
    ray.TMin = 0.0;
    ray.TMax = FLT_MAX;

    rayPayload.packedHitInfo = gVBuffer[pixel];
    ray.Direction = -gView[pixel].xyz;

    //Camera Tracing loop
    for (uint i = 0; i < gMaxBounces; i++)
    {
        // Primary hit is given by VBuffer
        if(i>0)
            TraceRay(gScene.rtAccel, 0, 0xff, 0, rayTypeCount, 0, ray, rayPayload);
        HitInfo hit = HitInfo(rayPayload.packedHitInfo);

        // Miss
        if (!hit.isValid()) {
            float3 envColor = kUseEnvMap ? gScene.envMap.eval(ray.Direction) : kDefaultBackgroundColor;
            // MIS
            float misWeight = 1.0;
            if (kUseEnvLight && camState.diffuseHitCount > 0) {
                float lightPdf = gLightTypeSelectProbability[kNeeLightTypeEnvMap] * gEnvMapSampler.evalPdf(ray.Direction);
                misWeight = evalMIS(1, camState.scatterPDF, 1, lightPdf);
            }
            outColor += misWeight * camState.thp * envColor;
            break;
        }

        // Get shading data
        ShadingData sd = loadShadingData(hit, ray.Direction, lod);
        uint hints = (uint)MaterialInstanceHints::AdjustShadingNormal;
        let mi = gScene.materials.getMaterialInstance(sd, lod, hints);
        let bsdfProperties = mi.getProperties(sd);

        bool hitEmissive = any(bsdfProperties.emission > 0);
        bool hitDiffuse = bsdfProperties.roughness > kRoughnessThreshold;

        // Stop if diffuse -> specular bounce in final gathering, as those paths are already covered by caustic photons.
        if ((kRenderMode == (uint)PhotonRenderMode::FinalGathering) && (camState.diffuseHitCount > 0) && !hitDiffuse)
            break;

        if (hitEmissive) {
            // MIS (only for final gather on the second hit)
            float emissiveProb = gLightTypeSelectProbability[kNeeLightTypeEmissive];
            float misWeight = 1.0;
            if (camState.diffuseHitCount > 0 && (kRenderMode == (uint)PhotonRenderMode::FinalGathering) && emissiveProb > 0)
            {
                // Get hit in light collection representation
                TriangleHit triangleHit = hit.getTriangleHit();
                TriangleLightHit lightHit;
                lightHit.triangleIndex = gScene.lightCollection.getTriangleIndex(triangleHit.instanceID, triangleHit.primitiveIndex);
                lightHit.posW = sd.posW;
                lightHit.normalW = sd.getOrientedFaceNormal();
                float neePDF = emissiveProb * gEmissiveSampler.evalPdf(camState.prevPosW, camState.prevFaceN, true, lightHit);
                misWeight = evalMIS(1.0, camState.scatterPDF, 1.0, neePDF);
            }

            outColor += bsdfProperties.emission * camState.thp * misWeight;
            break;
        }

        // Evaluate Photons
        if (hitDiffuse) {
            bool finalGatherFirstHit = (kRenderMode == (uint)PhotonRenderMode::FinalGathering) && (camState.diffuseHitCount == 0);
            uint instanceMask = finalGatherFirstHit ? 2 : 0xFF; // Collect only caustics on final gather first hit
            outColor += collectPhotons(sd, mi, bsdfProperties.guideNormal, instanceMask, gNumLightPaths, sg) * camState.thp;
            // Next event estimation for first hit in final gathering
            if (finalGatherFirstHit) {
                LightSample ls = {};
                outColor += nextEventEstimation(sd, mi, gLightTypeSelectProbability, ls, sg) * camState.thp;
            }
        }

        if (!sampleNewRay(sd, mi, bsdfProperties.roughness, sg, camState, ray))
            break;
    }

    gOutColor[pixel] = float4(outColor, 1);
}
