#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.RaytracingInline;
import Utils.Sampling.SampleGenerator;
import Rendering.Lights.LightHelpers;
import Rendering.Lights.EmissiveLightSampler;
import Rendering.Lights.EmissiveLightSamplerHelpers;
import StructsAndFunctions;

RaytracingAccelerationStructure gPhotonAS;

Texture2D<PackedHitInfo> gVBuffer;
Texture2D<float4> gView;

RWTexture2D<int> gCausticHead;
StructuredBuffer<CausticData> gCausticData;
StructuredBuffer<AABB> gCausticAABB;

RWTexture2D<float4> gOutColor;

cbuffer CB
{
    uint gFrameCount;   // Current frame for sample generator
    uint2 gFrameDim;    // Current frame dimensions
    float gAmbient;     // Ambient Strengt

    float gEmissiveStrength;     //Brightnes factor for emissive materials
    float gEnvMapStrength;       // Brightnes factor for emissive materials
    float gImagePlaneDist;       // Precomputed image plane distance for the backproject pdf
    float gFovY;                 //FovY
}

cbuffer Light {
    EmissiveLightSampler gEmissiveSampler;
}

static const bool kUseEnvBackground = USE_ENV_BACKROUND;
static const float3 kDefaultBackgroundColor = float3(0);
static const uint kMIHints = (uint)MaterialInstanceHints::AdjustShadingNormal;
static const bool kEvalAllAnalytic = EVAL_ALL_ANALYTIC;
static const bool kUseEmissiveLights = USE_EMISSIVE_LIGHT;

//Samples 1 or all analytic lights
float3 evaluateAnalyticLights(ShadingData sd, IMaterialInstance mi, inout SampleGenerator sg)
{
    float3 color = float3(0);
    const uint lightCount = gScene.getLightCount();
    if (lightCount <= 0)
        return color;

    uint loopCount = kEvalAllAnalytic ? lightCount : 1;
    //Loop over all lights
    for(uint i=0; i<loopCount; i++)
    {
        //Select random light
        uint selectedIndex = i;
        if (!kEvalAllAnalytic)
            selectedIndex = min(uint(floor(lightCount * sampleNext1D(sg))), lightCount - 1);
        float invPDF = kEvalAllAnalytic ? 1 : lightCount; // selection pdf 1/lightCount for random

        //Sample light
        AnalyticLightSample ls;
        if (!sampleLight(sd.posW, gScene.getLight(selectedIndex), sg, ls))
            continue;

        // Shadow Ray
        if (!dispatchShadowRay(sd, ls.dir, ls.distance))
            continue;

        color += mi.eval(sd, ls.dir, sg) * ls.Li * invPDF;
    }
    return color;
}

//Samples a random emissive light sample with the light sampler
float3 evaluateEmissiveLight(ShadingData sd, IMaterialInstance mi, inout SampleGenerator sg)
{
    //Early out
    if (!kUseEmissiveLights)
        return float3(0);

    //Sample a triangle light
    TriangleLightSample tls = {};
    if (!gEmissiveSampler.sampleLight(sd.posW, sd.faceN, true, sg, tls))
        return float3(0);

    // Shadow Ray
    if (!dispatchShadowRay(sd, tls.dir, tls.distance))
        return float3(0);

    //BRDF
    float3 Li = tls.pdf > 0.f ? tls.Le / tls.pdf : float3(0);
    return mi.eval(sd, tls.dir, sg) * Li;
}

float3 collectBackprojectedCaustics(uint2 pixel, inout SampleGenerator sg)
{
    int headIndex = gCausticHead[pixel];
    if (headIndex < 0)
        return float3(0);

    let lod = ExplicitLodTextureSampler(0);
    float3 outColor = float3(0);
    uint count = 0;
    // Loop through the linked list
    while (headIndex >= 0)
    {
        // Get Caustic data
        CausticData cd = gCausticData[headIndex];
        HitInfo causticHit = HitInfo(cd.packedHit);
        if (!causticHit.isValid()) //This should not trigger
            break;

        ShadingData sd = loadShadingData(causticHit, -cd.wi, lod);
        let mi = gScene.materials.getMaterialInstance(sd, lod, kMIHints);

        float3 directionToCamera = gScene.camera.getPosition() - sd.posW;
        float distanceToCamera = length(directionToCamera);
        directionToCamera /= distanceToCamera;

        
        // Photon Guiding
        const float aspect = float(gFrameDim.x) / gFrameDim.y;
        float h = tan(gFovY / 2.0) * 2.0;
        float w = h * aspect;
        float wPix = w / gFrameDim.x;
        float hPix = h / gFrameDim.y;
        float pixelExtend = wPix * hPix;
        const float3 camForward = normalize(gScene.camera.data.cameraW);
        const float cosAtCamera = abs(dot(-directionToCamera, camForward));
        float cameraPDF = distanceToCamera * distanceToCamera * gImagePlaneDist * pow(cosAtCamera, 3);

        /*
        // VCM style (Brighter than photon guiding)
        const float tanHalfAngle = tan(gFovY / 2.0);
        const float imagePlaneDist = gFrameDim.x / (2.0 *tanHalfAngle);
        const float cosToCamera = dot(sd.faceN, directionToCamera);
        const float3 camForward = normalize(gScene.camera.data.cameraW);
        const float cosAtCamera = dot(camForward, -directionToCamera);
        const float imagePointToCameraDist = imagePlaneDist / cosAtCamera;
        const float imageToSolidAngleFactor = (imagePointToCameraDist * imagePointToCameraDist) / cosAtCamera;
        const float imageToSurfaceFactor = imageToSolidAngleFactor * abs(cosToCamera) / (distanceToCamera * distanceToCamera);
        const float cameraPDF = 1.0 / imageToSurfaceFactor;
        */

        const float3 bsdf = mi.eval(sd, directionToCamera, sg);
        outColor += (bsdf * cd.flux) / cameraPDF;

        // Update head index
        headIndex = cd.next;
    }

    return outColor;
}

// Checks if the ray start point is inside the sphere.
bool hitSphere(const float3 center, const float radius, const float3 p)
{
    float3 radiusTest = p - center;
    return dot(radiusTest, radiusTest) < radius * radius;
}

float3 photonRadianceEstimate(ShadingData sd, IMaterialInstance mi, float3 N, inout SampleGenerator sg)
{
    float3 outColor = float3(0);

    // Prepare ray
    RayDesc ray;
    ray.Origin = sd.posW;
    ray.Direction = sd.faceN;
    ray.TMin = 0;
    ray.TMax = 1e-10;    //Small constant

    RayQuery<RAY_FLAG_NONE> rayQuery;
    rayQuery.TraceRayInline(gPhotonAS, RAY_FLAG_NONE, 0xFF, ray);
    while (rayQuery.Proceed()) {

        if (rayQuery.CandidateType() != CANDIDATE_PROCEDURAL_PRIMITIVE)
            continue;
        const uint primIdx = rayQuery.CandidatePrimitiveIndex();

        // Check if ray is inside photon radius
        AABB photonAABB = gCausticAABB[primIdx];
        float radius = (photonAABB.maxPoint.x - photonAABB.minPoint.x) / 2.0;
        if (!hitSphere(photonAABB.center(), radius, sd.posW))
            continue;

        CausticData cd = gCausticData[primIdx];
        float NdotL = dot(-cd.wi, N);

        float3 bsdf = mi.eval(sd, -cd.wi, sg);
        float3 photonRadiance = max(0, (cd.flux * bsdf) / (M_PI * radius * radius * NdotL)); // NdotL needs to be taken out of the bsdf for Photon Mapping
        outColor += photonRadiance; 
    }

    return outColor;
}

[numthreads(16, 16, 1)]
void main(uint2 pixel: SV_DispatchThreadID)
{
    if (any(pixel >= gFrameDim))
        return;

    HitInfo hitInfo = HitInfo(gVBuffer[pixel]);
    float3 viewDir = gView[pixel].xyz;

    float3 outColor = float3(0);

    if (hitInfo.isValid())
    {
        SampleGenerator sg = SampleGenerator(pixel, gFrameCount * 2 + 13); //Random starting offset
        let lod = ExplicitLodTextureSampler(0.f);

        // Get Material properties
        ShadingData sd = loadShadingData(hitInfo, viewDir, lod);
        let mi = gScene.materials.getMaterialInstance(sd, lod, kMIHints);
        let bsdfProperties = mi.getProperties(sd);

        // Add Ambient and Emissive
        outColor += bsdfProperties.diffuseReflectionAlbedo * gAmbient;
        outColor += bsdfProperties.emission * gEmissiveStrength;

        // Lighting
        outColor += evaluateAnalyticLights(sd, mi, sg);
        outColor += evaluateEmissiveLight(sd, mi, sg);

        // Caustics
        // outColor = float3(0);
        // outColor += collectBackprojectedCaustics(pixel, sg);
        outColor += photonRadianceEstimate(sd, mi, bsdfProperties.guideNormal, sg);

    }else //Miss
    {
        if (kUseEnvBackground)
            outColor = gScene.envMap.eval(viewDir) * gEnvMapStrength;
        else
            outColor = kDefaultBackgroundColor;
    }

    gOutColor[pixel] = float4(outColor,1);
    // Clear head buffer
    gCausticHead[pixel] = -1;
}
