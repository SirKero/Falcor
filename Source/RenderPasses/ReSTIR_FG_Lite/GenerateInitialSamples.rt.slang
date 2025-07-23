#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.Raytracing;
import Utils.Sampling.SampleGenerator;
import Rendering.RTXDI.RTXDI;
import StructsAndHelpers;

Texture2D<PackedHitInfo> gVBuffer;

StructuredBuffer<PhotonData> gPhotonData[2];
StructuredBuffer<AABB> gPhotonAABB[2];
RaytracingAccelerationStructure gPhotonAS;

RWTexture2D<float4> gOutColor;

static const float kPhotonCollectTMax = 1e-7;

cbuffer CB
{
    uint gFrameCount; // Frame count since scene was loaded.
    uint gFGRayMaxPathLength; //Max path length for a Final Gather sample
}

static const bool kAlphaTest = true;
static const float kRoughnessThreshold = ROUGHNESS_THRESHOLD;

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
    //Prepare ray
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

        //Check if ray is inside photon radius
        AABB photonAABB = gPhotonAABB[instanceIdx][primIdx];
        float radius = (photonAABB.maxPoint.x - photonAABB.minPoint.x) / 2.0;
        if (!hitSphere(photonAABB.center(), radius, sd.posW))
            continue;

        PhotonData photonData = gPhotonData[instanceIdx][primIdx];
        float NdotL = dot(-photonData.dir, N);
        // Check for diffent surfaces (e.g. corners)
        if ((dot(photonData.normalW, sd.faceN) < 0.6) || (NdotL <= 0))
            continue;

        float3 bsdf = mi.eval(sd, -photonData.dir, sg); //;
        collectedRadiance += max(0, (photonData.flux * bsdf) / (radius * radius * NdotL)); //NdotL needs to be taken out of the bsdf for Photon Mapping
    }
    return collectedRadiance;
}

bool generateFGSampleRay(ShadingData sd, IMaterialInstance mi, inout SampleGenerator sg, inout float3 thp, inout RayDesc ray) {
    // Photon Bounce for next iteration
    BSDFSample bsdfSample;
    bool validSample = mi.sample(sd, sg, bsdfSample, true /*ImportanceSampling*/);
    bool transmission = bsdfSample.isLobe(LobeType::Transmission);
    ray.Origin = sd.computeNewRayOrigin(!transmission); // false is for transmissions
    ray.Direction = bsdfSample.wo;
    thp *= bsdfSample.weight;

    return validSample;
}

void traceFGRay(RayDesc ray, inout SampleGenerator sg, bool prevHitIsRough , inout float3 thp, inout bool valid, inout float3 FGLi, inout float3 causticLi) {
    RayPayload rayPayload = RayPayload();
    uint pathLength = 0;
    bool collectCaustics = !prevHitIsRough;
    for (pathLength; pathLength < gFGRayMaxPathLength && valid; pathLength++) {
        TraceRay(gScene.rtAccel, 0 /*Flags*/, 0xff /* instanceInclusionMask */, 0 /* hitIdx */, rayTypeCount, 0 /* missIdx */, ray, rayPayload);
        // Get surface hit info
        HitInfo hit = HitInfo(rayPayload.packedHitInfo);
        if (!hit.isValid()) {
            valid = false;
            return;
        }

        // Get shading infos
        let lod = ExplicitLodTextureSampler(0);

        // Get Material properties
        uint hints = (uint)MaterialInstanceHints::AdjustShadingNormal;
        ShadingData sd = loadShadingData(hit, ray.Direction, lod);
        let mi = gScene.materials.getMaterialInstance(sd, lod, hints);
        let bsdfProperties = mi.getProperties(sd);
        bool hitIsRough = bsdfProperties.roughness > kRoughnessThreshold;

        if (collectCaustics && hitIsRough) {
            causticLi = collectPhotons(sd, mi, bsdfProperties.guideNormal, 2, sg);
            causticLi *= thp;
            collectCaustics = false;
        }
        
        if (hitIsRough && prevHitIsRough) {
            float3 photonRad = collectPhotons(sd, mi, bsdfProperties.guideNormal, 0xFF, sg);
            FGLi = (photonRad + bsdfProperties.emission) * thp;
            return;
        }
        //Else
        valid = generateFGSampleRay(sd, mi, sg, thp, ray);
        prevHitIsRough = hitIsRough;
    }
    valid = false;
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
    float3 viewDir = -gScene.camera.computeRayPinhole(pixel, dispatchDims).dir;
    float3 outColor = float3(0);

    if (hitInfo.isValid()) {
        //Set RTXDI data
        let lod = ExplicitLodTextureSampler(0);
        SampleGenerator sg = SampleGenerator(pixel, gFrameCount * 4 + 1);

        ShadingData sd = loadShadingData(hitInfo, -viewDir, lod);
        uint hints = (uint)MaterialInstanceHints::AdjustShadingNormal;
        let mi = gScene.materials.getMaterialInstance(sd, lod, hints);
        let bsdfProperties = mi.getProperties(sd);
        float distanceToSurface = distance(sd.posW, gScene.camera.getPosition());

        gRTXDI.setSurfaceData(pixel, sd.computeNewRayOrigin(), bsdfProperties.guideNormal, bsdfProperties.diffuseReflectionAlbedo, bsdfProperties.specularReflectance, bsdfProperties.roughness, distanceToSurface);

        bool hitIsRough = bsdfProperties.roughness > kRoughnessThreshold;
        // Collect Caustic photons
        float3 causticRadiance = float3(0);
        if (hitIsRough)
            causticRadiance = collectPhotons(sd, mi, bsdfProperties.guideNormal, 2, sg);

        // Distribute a Final Gather ray
        RayDesc ray = {};
        ray.TMin = 0;
        ray.TMax = FLT_MAX;
        float3 fgThp = float3(1.0);
        bool validFGRay = generateFGSampleRay(sd, mi, sg, fgThp, ray);

        float3 fgOut = float3(0);
        traceFGRay(ray, sg, hitIsRough, fgThp, validFGRay, fgOut, causticRadiance);

        outColor += causticRadiance + fgOut;

    } else {
        // Set invalid RTXDI data
        gRTXDI.setInvalidSurfaceData(pixel);
    }

    gOutColor[pixel] += float4(outColor, 0.0);
}
