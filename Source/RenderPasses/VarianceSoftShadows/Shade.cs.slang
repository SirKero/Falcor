#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.RaytracingInline;
import Utils.Sampling.SampleGenerator;
import Rendering.Lights.LightHelpers;
import Rendering.ShadowMaps.ShadowTestFunctions;

#ifndef NUM_SM
#define NUM_SM 1
#endif

cbuffer CB
{
    uint gFrameCount;       //Frame count for sample gen
    uint2 gFrameDim;        //Dimensions
    float gAmbient;         //Ambient strength
    float gEnvMapFac;       //Env map strength
    float gEmissiveFac;     // Emissive stength
    float gSMNear;          //Shadow Map Near Palne
    float gSMFar;           // Shadow Map Far Plane
    uint gSMSize;           //Size of the SM
}

cbuffer CB_SMVMP {
    float4x4 gSMViewProjection[NUM_SM];
}

Texture2D<float> gSM[NUM_SM];
Texture2D<uint2> gSAT[NUM_SM];

Texture2D<PackedHitInfo> gVBuffer;
Texture2D<float4> gView;

RWTexture2D<float4> gColorOut;

SamplerState gSMSampler;

static const float kMinIncidentAngle = 1e-3; // Min Incident angle for light
static const bool kUseEnvMap = USE_ENV_BACKROUND;
static const float3 kDefaultBackgroundColor = float3(0.01);
static const float kMantissaMax = 8388608.0; // 2^23

// Load in shading data from hit and direction
ShadingData loadShadingData(const HitInfo hit, const float3 rayDir, const ITextureSampler lod)
{
    const TriangleHit triangleHit = hit.getTriangleHit();
    VertexData v = gScene.getVertexData(triangleHit);
    uint materialID = gScene.getMaterialID(triangleHit.instanceID);
    ShadingData sd = gScene.materials.prepareShadingData(v, materialID, -rayDir, lod);

    return sd;
}

float evalShadowMap(const ShadingData sd, uint lightIdx) {

    float4x4 viewProjectMat = gSMViewProjection[lightIdx];
    float4 projPos = mul(viewProjectMat, float4(sd.posW, 1.f));
    projPos.xyz = (projPos.xyz / projPos.w);

    float lightDist = (projPos.w - gSMNear) / (gSMFar - gSMNear);

    float2 shadowUV = projPos.xy;
    shadowUV.y *= -1;                // Flip
    shadowUV = shadowUV * 0.5 + 0.5; // UV from [-1,1] to [0,1]

    if (any(shadowUV.xy < 0.f) || any(shadowUV.xy > 1.f)) // Return if outside of the shadow map
        return 0.0;

    float sv = gSM[lightIdx].SampleLevel(gSMSampler, shadowUV, 0);

    float vis = 0;
    if (sv + 0.0001 > lightDist)
        vis = 1;

    return vis;
}

float evalSATShadowMap(const ShadingData sd, uint lightIdx) {

    float4x4 viewProjectMat = gSMViewProjection[lightIdx];
    float4 projPos = mul(viewProjectMat, float4(sd.posW, 1.f));
    projPos.xyz = (projPos.xyz / projPos.w);

    float lightDist = (projPos.w - gSMNear) / (gSMFar - gSMNear);

    float2 shadowUV = projPos.xy;
    shadowUV.y *= -1;                // Flip
    shadowUV = shadowUV * 0.5 + 0.5; // UV from [-1,1] to [0,1]

    if (any(shadowUV.xy < 0.f) || any(shadowUV.xy > 1.f)) // Return if outside of the shadow map
        return 0.0;

    // Get the SAT corners
    int2 pixel = shadowUV * gSMSize;
    int searchRadius = 12;
    int2 satPixel = clamp(pixel + int2(-searchRadius), 0, gSMSize - 1);
    uint2 sat0 = gSAT[lightIdx][satPixel];
    satPixel = clamp(pixel + int2(searchRadius, -searchRadius), 0, gSMSize - 1);
    uint2 sat1 = gSAT[lightIdx][satPixel];
    satPixel = clamp(pixel + int2(-searchRadius, searchRadius), 0, gSMSize - 1);
    uint2 sat2 = gSAT[lightIdx][satPixel];
    satPixel = clamp(pixel + int2(searchRadius), 0, gSMSize - 1);
    uint2 sat3 = gSAT[lightIdx][satPixel];

    uint2 s = sat3 - sat1 - sat2 + sat0;
    s /= 576;
    float2 moments = float2(s) / kMantissaMax;

    float vis = ChebyshevUpperBound(moments, lightDist, 1e-5);

    return vis;
}

float3 evalAnalyticLight(const ShadingData sd, const IMaterialInstance mi, inout SampleGenerator sg)
{
    float3 Li = float3(0);
    const uint lightCount = gScene.getLightCount();
    if (lightCount == 0) return float3(0.0);

    //Loop over all lights
    for (uint lightIdx = 0; lightIdx < lightCount; lightIdx++) {
        // Sample local light source.
        AnalyticLightSample ls = {};
        LightData lightData = gScene.getLight(lightIdx);
        uint type = lightData.type;
        sampleLight(sd.posW, lightData, sg, ls);

        float NdotL = dot(sd.getOrientedFaceNormal(), ls.dir);
        // Reject sample if invalid or has an too steep incident angle
        if (all(ls.Li <= 0.0) || (abs(NdotL) < kMinIncidentAngle)) {
            continue;
        }

        // Eval BSDF
        float3 bsdf = mi.eval(sd, ls.dir, sg);
        if (all(bsdf <= 0))
            continue;

        float visibility = 0;

        // Shadow Ray for now
        /*
        SceneRayQuery<1> rayQuery;
        const Ray ray = Ray(sd.computeNewRayOrigin(), ls.dir, 0.f, ls.distance);
        if (rayQuery.traceVisibilityRay(ray, RAY_FLAG_NONE, 0xff))
            visibility = 1.0;
        */
        //visibility = evalShadowMap(sd, lightIdx);
        visibility = evalSATShadowMap(sd, lightIdx);

        Li += bsdf * visibility * ls.Li;
    }
    return Li;
}

[numthreads(16, 16, 1)]
void main(uint2 pixel: SV_DispatchThreadID)
{
    if (any(pixel >= gFrameDim))
        return;

    float3 outColor = float3(0);
    HitInfo hit = HitInfo(gVBuffer[pixel]);
    float3 view = -gView[pixel].xyz;

    if (hit.isValid()) {
        SampleGenerator sg = SampleGenerator(pixel, gFrameCount);
        let lod = ExplicitLodTextureSampler(0.f);

        ShadingData sd = loadShadingData(hit, view, lod);
        uint hints = (uint)MaterialInstanceHints::AdjustShadingNormal;
        let mi = gScene.materials.getMaterialInstance(sd, lod, hints);
        let bsdfProperties = mi.getProperties(sd);

        // Ambient
        outColor += gAmbient * bsdfProperties.diffuseReflectionAlbedo;
        outColor += gEmissiveFac * bsdfProperties.emission;
        outColor += evalAnalyticLight(sd, mi, sg);
    }
    else {
        if(kUseEnvMap)
            outColor = gScene.envMap.eval(view) * gEnvMapFac;
        else
            outColor = kDefaultBackgroundColor;
    }

    gColorOut[pixel] = float4(outColor,1.0);
}
