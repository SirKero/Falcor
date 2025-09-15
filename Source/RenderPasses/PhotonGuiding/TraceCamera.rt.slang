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

#ifndef NUM_GUIDING_TEXTURES
#define NUM_GUIDING_TEXTURES 1
#endif

Texture2D<PackedHitInfo> gVBuffer;
Texture2D<float4> gView;
RWTexture2D<uint> gGuidingCounter[NUM_GUIDING_TEXTURES];

StructuredBuffer<PhotonData> gPhotonData[2];
StructuredBuffer<AABB> gPhotonAABB[2];
RaytracingAccelerationStructure gPhotonAS;

RWTexture2D<float4> gOutColor;

cbuffer Light {
    EmissiveLightSampler gEmissiveSampler;
}

cbuffer CB
{
    uint gFrameCount; // Frame count since scene was loaded.
    uint gMaxBounces; // Max path length for a Final Gather sample
    float2 gPhotonRadius; // TODO remove temporary for MIS

    uint gNumLightPaths; // Number of light paths for MIS
}

static const float kPhotonCollectTMax = 1e-7;
static const bool kUseEnvMap = USE_ENV_MAP;
static const bool kAlphaTest = true;
static const float kRoughnessThreshold = ROUGHNESS_THRESHOLD;
static const float3 kDefaultBackgroundColor = float3(0.0);


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
    uint pathLength;
    bool isSpecularPath;

    __init() {
        pathLength = 0;
        isSpecularPath = true;
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

        float3 bsdf = mi.eval(sd, photonData.dir, sg);
        collectedRadiance += max(0, (photonData.flux * bsdf) / (NdotL *  radius * radius)); // NdotL needs to be taken out of the bsdf for Photon Mapping

        // Add to the guiding texture
        InterlockedAdd(gGuidingCounter[photonData.lightIndex][photonData.guidingPixel], 1u);
    }
    //Divide by the rest of the photon weight
    collectedRadiance /= M_PI * gNumLightPaths;
    return collectedRadiance;
}

bool sampleNewRay(ShadingData sd, IMaterialInstance mi, float roughness, inout SampleGenerator sg, inout float3 thp, inout CameraState camState, inout RayDesc ray)
{
    // Abort on diffuse surfaces
    bool isDiffuse = roughness > kRoughnessThreshold;
    if (isDiffuse)
        return false;

    BSDFSample bsdfSample;
    if (!mi.sample(sd, sg, bsdfSample, true /*ImportanceSampling*/))
        return false;

    bool transmission = bsdfSample.isLobe(LobeType::Transmission);
    ray.Origin = sd.computeNewRayOrigin(!transmission); // false is for transmissions
    ray.Direction = bsdfSample.wo;
    thp *= bsdfSample.weight;

    camState.pathLength++;
    camState.isSpecularPath &= !isDiffuse;

    return true;
}

float3 NextEventEstimation(ShadingData sd, IMaterialInstance mi ,CameraState camState, float continuationProb, inout SampleGenerator sg)
{
    TriangleLightSample tls = {};
    if (!gEmissiveSampler.sampleLight(sd.posW, sd.faceN, true, sg, tls))
        return float3(0);

    float3 bsdf = mi.eval(sd, tls.dir, sg);

    if (all(bsdf <= 0) || tls.pdf <= 0)
        return float3(0);

    //Shadow Ray
    SceneRayQuery<1> rayQuery;
    const Ray ray = Ray(sd.computeNewRayOrigin(), tls.dir, 0.f, tls.distance * 0.98);
    if (!rayQuery.traceVisibilityRay(ray, RAY_FLAG_NONE, 0xff))
        return float3(0);

    float3 radiance = bsdf * tls.Le / tls.pdf;
    return radiance;
}

float3 tracePath(RayDesc ray, ShadingData sd, inout CameraState camState,  inout SampleGenerator sg , inout float3 thp)
{
    float3 outColor = float3(0);
    RayPayload rayPayload = RayPayload();
    bool validRay = true;
    float3 prevPos = sd.posW;
    float3 prevFaceN = sd.faceN;

    for (uint i = 0; i < gMaxBounces && validRay; i++)
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

        bool hitEmissive = any(bsdfProperties.emission > 0);
        if (hitEmissive) {
            outColor += bsdfProperties.emission * thp;
            break;
        }

        // Evaluate Photons
        if (bsdfProperties.roughness > kRoughnessThreshold) {
            outColor += collectPhotons(sd, mi, bsdfProperties.guideNormal, 0xFF, sg) * thp;
        }

        validRay = sampleNewRay(sd, mi, bsdfProperties.roughness, sg, thp, camState, ray);
        prevPos = sd.posW;
        prevFaceN = sd.faceN;
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
        //Init Camera state with MIS
        CameraState camState = CameraState();
        
        //Get Material Properties
        let lod = ExplicitLodTextureSampler(0);
        SampleGenerator sg = SampleGenerator(pixel, gFrameCount * 2 + 1);

        ShadingData sd = loadShadingData(hitInfo, -viewDir, lod);
        uint hints = (uint)MaterialInstanceHints::AdjustShadingNormal;
        let mi = gScene.materials.getMaterialInstance(sd, lod, hints);
        let bsdfProperties = mi.getProperties(sd);

      
        outColor += bsdfProperties.emission; // On first hit, no MIS is necessary if emissive is hit
        bool hitEmissive = any(bsdfProperties.emission > 0);

        if (!hitEmissive) {
            // Evaluate Photons
            bool isDiffuse = bsdfProperties.roughness > kRoughnessThreshold;
            if (isDiffuse)
            {
                outColor += collectPhotons(sd, mi, bsdfProperties.guideNormal, 0xFF, sg);
            }
            // Calculate next ray
            float3 thp = float3(1.0);
            RayDesc ray;
            ray.TMin = 0.0;
            ray.TMax = FLT_MAX;
            if (sampleNewRay(sd, mi, bsdfProperties.roughness, sg, thp, camState, ray))
                outColor += tracePath(ray, sd, camState, sg, thp);
        }
    } else {
        outColor += kUseEnvMap ? gScene.envMap.eval(viewDir) : kDefaultBackgroundColor;
    }

    gOutColor[pixel] = float4(outColor, 1);
}
