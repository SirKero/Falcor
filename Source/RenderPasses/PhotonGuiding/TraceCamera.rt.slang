#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.Raytracing;
import Utils.Sampling.SampleGenerator;
import Utils.Color.ColorHelpers;
import Rendering.RTXDI.RTXDI;
import StructsAndHelpers;

Texture2D<PackedHitInfo> gVBuffer;
Texture2D<float4> gView;

StructuredBuffer<PhotonData> gPhotonData[2];
StructuredBuffer<AABB> gPhotonAABB[2];
RaytracingAccelerationStructure gPhotonAS;

RWTexture2D<float4> gOutColor;

static const float kPhotonCollectTMax = 1e-7;

cbuffer CB
{
    uint gFrameCount; // Frame count since scene was loaded.
    uint gMaxBounces; //Max path length for a Final Gather sample
}

static const bool kUseEnvMap = USE_ENV_MAP;
static const bool kAlphaTest = true;
static const float kRoughnessThreshold = ROUGHNESS_THRESHOLD;
static const float3 kDefaultBackgroundColor = float3(0.01);

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

// Checks if the ray start point is inside the sphere.
bool hitSphere(const float3 center, const float radius, const float3 p)
{
    float3 radiusTest = p - center;
    radiusTest = radiusTest * radiusTest;
    float radiusTestF = radiusTest.x + radiusTest.y + radiusTest.z;
    if (radiusTestF < radius * radius)
        return true;
    return false;
}

float3 collectPhotons(ShadingData sd, IMaterialInstance mi, float3 N, uint instanceMask, inout SampleGenerator sg) {
    float3 collectedRadiance = float3(0);
    // Prepare ray
    RayDesc ray;
    ray.Origin = sd.posW;
    ray.Direction = sd.faceN;
    ray.TMin = 0;
    ray.TMax = kPhotonCollectTMax;

    RayQuery<RAY_FLAG_NONE> rayQuery;

    rayQuery.TraceRayInline(gPhotonAS, RAY_FLAG_NONE, instanceMask, ray);
    while (rayQuery.Proceed()) {

        if (rayQuery.CandidateType() != CANDIDATE_PROCEDURAL_PRIMITIVE)
            continue;
        const uint instanceIdx = rayQuery.CandidateInstanceIndex();
        const uint primIdx = rayQuery.CandidatePrimitiveIndex();

        // Check if ray is inside photon radius
        AABB photonAABB = gPhotonAABB[instanceIdx][primIdx];
        float radius = (photonAABB.maxPoint.x - photonAABB.minPoint.x) / 2.0;
        if (!hitSphere(photonAABB.center(), radius, sd.posW))
            continue;

        PhotonData photonData = gPhotonData[instanceIdx][primIdx];
        float NdotL = dot(photonData.dir, N);
        // Check for diffent surfaces (e.g. corners)
        if ((dot(photonData.normalW, sd.faceN) < 0.6) || (NdotL <= 0))
            continue;

        float3 bsdf = mi.eval(sd, photonData.dir, sg); //;
        collectedRadiance += max(0, (photonData.flux * bsdf) / (M_PI * radius * radius * NdotL)); // NdotL needs to be taken out of the bsdf for Photon Mapping
    }
    return collectedRadiance;
}

bool sampleNewRay(ShadingData sd, IMaterialInstance mi, inout SampleGenerator sg, inout float3 thp, inout float pdf, inout RayDesc ray)
{
    // Photon Bounce for next iteration
    BSDFSample bsdfSample;
    bool validSample = mi.sample(sd, sg, bsdfSample, true /*ImportanceSampling*/);
    bool transmission = bsdfSample.isLobe(LobeType::Transmission);
    ray.Origin = sd.computeNewRayOrigin(!transmission); // false is for transmissions
    ray.Direction = bsdfSample.wo;
    thp *= bsdfSample.weight;
    pdf = bsdfSample.pdf;

    return validSample;
}

float3 tracePath(RayDesc ray, inout SampleGenerator sg , inout float3 thp)
{
    float3 outColor = float3(0);
    RayPayload rayPayload = RayPayload();

    for (uint i = 0; i < gMaxBounces; i++)
    {
        // Trace new ray
        TraceRay(gScene.rtAccel, 0 , 0xff , 0, rayTypeCount, 0 , ray, rayPayload);
        HitInfo hit = HitInfo(rayPayload.packedHitInfo);
        //Miss
        if (!hit.isValid()) {
            float3 envColor = kUseEnvMap ? gScene.envMap.eval(ray.Direction) : kDefaultBackgroundColor;
            outColor += thp * envColor;
            break;
        }

        // Get shading data
        let lod = ExplicitLodTextureSampler(0);
        ShadingData sd = loadShadingData(hit, ray.Direction, lod);
        uint hints = (uint)MaterialInstanceHints::AdjustShadingNormal;
        let mi = gScene.materials.getMaterialInstance(sd, lod, hints);
        let bsdfProperties = mi.getProperties(sd);

        // Evaluate Photons
        if (bsdfProperties.roughness > kRoughnessThreshold) {
            outColor  += bsdfProperties.emission * thp;
            outColor += collectPhotons(sd, mi, bsdfProperties.guideNormal, 0xFF, sg) * thp;
            break; // Stop for now
        } else {
            float pdf = 1.0;
            if (!sampleNewRay(sd, mi, sg, thp, pdf, ray))
                break;
        }
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
    float3 viewDir = gView[pixel].xyz;

    float3 outColor = float3(0);

    if (hitInfo.isValid()) {
        let lod = ExplicitLodTextureSampler(0);
        SampleGenerator sg = SampleGenerator(pixel, gFrameCount * 2 + 1);

        ShadingData sd = loadShadingData(hitInfo, -viewDir, lod);
        uint hints = (uint)MaterialInstanceHints::AdjustShadingNormal;
        let mi = gScene.materials.getMaterialInstance(sd, lod, hints);
        let bsdfProperties = mi.getProperties(sd);
        outColor += bsdfProperties.emission;

        // Evaluate Photons
        if (bsdfProperties.roughness > kRoughnessThreshold)
        {
            outColor += collectPhotons(sd, mi, bsdfProperties.guideNormal, 0xFF, sg);
        } else {
            // Calculate next ray
            float3 thp = float3(1.0);
            float pdf = 1;
            RayDesc ray;
            ray.TMin = 0.0;
            ray.TMax = FLT_MAX;
            if (sampleNewRay(sd, mi, sg, thp, pdf, ray))
                outColor += tracePath(ray, sg, thp);
        }

    } else {
        outColor = kUseEnvMap ? gScene.envMap.eval(viewDir) : kDefaultBackgroundColor;
    }

    gOutColor[pixel] = float4(outColor, 1);
}
