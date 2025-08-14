#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.RaytracingInline;
import Utils.Sampling.SampleGenerator;
import Rendering.Lights.LightHelpers;
import Rendering.ShadowMaps.ShadowTestFunctions;

#ifndef NUM_SM
#define NUM_SM 1
#endif

#ifndef CASCADED_LEVELS
#define CASCADED_LEVELS 1
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

    uint gSMSize;           // Size of the SM
    uint gSATMaxSearchRadius; // Max Search radius for SAT
    float gSpotLightSize;
    float gSunSize;    //For directional soft shadows

    float gMinVariance;
}

cbuffer CB_SMVMP {
    float4x4 gSMView[NUM_SM];
    float4x4 gSMProjection[NUM_SM];
}

cbuffer CB_CascadedSlices
{
    float gCascadedZSlices[CASCADED_LEVELS];
    float gCascadedDepthRange[CASCADED_LEVELS]; // Depth range for cascaded
}

Texture2D<float> gSM[NUM_SM];
Texture2D<uint2> gSAT[NUM_SM];  //SummedAreaTable Variance Shadow Map
Texture2D<float2> gHSM[NUM_SM];  //Hierarchical Min-Max Shadow Map

Texture2D<PackedHitInfo> gVBuffer;
Texture2D<float4> gView;

RWTexture2D<float4> gColorOut;

SamplerState gSMSampler; //Point Sampler

static const float kMinIncidentAngle = 1e-3; // Min Incident angle for light
static const bool kUseEnvMap = USE_ENV_BACKROUND;
static const float3 kDefaultBackgroundColor = float3(0.01);
static const float kMantissaMax = MAX_MANTISSA;
static const uint kCascadedStartIndex = CASCADED_START_INDEX;
static const uint kCascadedLevelCount = CASCADED_LEVELS;

// Load in shading data from hit and direction
ShadingData loadShadingData(const HitInfo hit, const float3 rayDir, const ITextureSampler lod)
{
    const TriangleHit triangleHit = hit.getTriangleHit();
    VertexData v = gScene.getVertexData(triangleHit);
    uint materialID = gScene.getMaterialID(triangleHit.instanceID);
    ShadingData sd = gScene.materials.prepareShadingData(v, materialID, -rayDir, lod);

    return sd;
}

/** Gets the current cascaded level from the world position
    \param[in] world position.
    \return cascaded level between 0 and kCascadedLevels.
    */
uint getCascadedLevel(float3 posW)
{
    float linearZ = abs(mul(gScene.camera.data.viewMat, float4(posW, 1.f)).z);
    uint level = 0;
    for (uint i = 0; i < kCascadedLevelCount - 1; i++)
    {
        if (linearZ < gCascadedZSlices[i])
            break;
        level++;
    }
    return clamp(level, 0, kCascadedLevelCount);
}

float evalShadowMap(const ShadingData sd, uint lightIdx, bool isDirectional) {
    if (isDirectional)
        lightIdx += getCascadedLevel(sd.posW);

    float4x4 viewProjectMat = mul(gSMProjection[lightIdx] , gSMView[lightIdx]);
    float4 projPos = mul(viewProjectMat, float4(sd.posW, 1.f));
    projPos.xyz = (projPos.xyz / projPos.w);

    float lightDist = isDirectional ? projPos.z : (projPos.w - gSMNear) / (gSMFar - gSMNear);

    float2 shadowUV = projPos.xy;
    shadowUV.y *= -1;                // Flip
    shadowUV = shadowUV * 0.5 + 0.5; // UV from [-1,1] to [0,1]

    if (any(shadowUV.xy < 0.f) || any(shadowUV.xy > 1.f)) // Return if outside of the shadow map
        return 0.0;

    float depth = gSM[lightIdx].SampleLevel(gSMSampler, shadowUV, 0);

    float vis = 1.0;
    if (depth + 1e-3 < lightDist)
        return 0.0;

    return vis;
}

// Eval Summed Area Table Variance shadow maps. offsets is assumed positive and in the order (-x,-y,+x,+y)
float evalSATVarianceShadows(int2 centerPixel, int4 offsets, float lightDist, uint lightIdx, out float avrgDepth)
{
    // Get the SAT corners
    offsets = min(offsets, gSATMaxSearchRadius);
    uint2 sat0 = int2(gSAT[lightIdx][centerPixel - offsets.xy]);
    uint2 sat1 = int2(gSAT[lightIdx][centerPixel + int2(offsets.z, -offsets.y)]);
    uint2 sat2 = int2(gSAT[lightIdx][centerPixel + int2(-offsets.x, offsets.w)]);
    uint2 sat3 = int2(gSAT[lightIdx][centerPixel + offsets.zw]);

    uint2 s = sat3 - sat1 - sat2 + sat0;
    float2 varianceEstimation = float2(s) / kMantissaMax;
    varianceEstimation /= float((offsets.x + offsets.z) * (offsets.y + offsets.w)); // Average
    avrgDepth = varianceEstimation.x;

    return ChebyshevUpperBound(varianceEstimation, lightDist, gMinVariance);
}

int2 getSATPixel(float3 viewPos, float2 viewPosOffset, float4x4 projMatrix, int2 pixelOffset = int2(0)) {
    float3 satPosView = viewPos + float3(viewPosOffset, 0.0);
    float4 satPosProj = mul(projMatrix, float4(satPosView, 1.0));
    satPosProj.xyz /= satPosProj.w;
    float2 satUV = satPosProj.xy;
    satUV.y *= -1;             // Flip
    satUV = satUV * 0.5 + 0.5; // UV from [-1,1] to [0,1]
    int2 satPixel = int2(round(satUV * gSMSize));
    satPixel = clamp(satPixel + pixelOffset, 0, gSMSize - 1);
    return satPixel;
}

//Returns true if the hierarchical shadow map has a definite result
bool evalHierarchicalShadowMap(float2 uv, uint boxSize, uint lightIdx, float lightDist, inout float visibility) {
    // Get best mip level for the current box size
    float mipLevel = floor(log2(float(boxSize))) - 1;
    // Get uv coordinates for the other samples
    uint smSize = gSMSize / 2; // Size at mip0
    smSize /= 1 << uint(mipLevel);
    float2 pixelCoord = uv * smSize;
    float2 offsets = 1.0 / smSize; //Pixel Size
    if (pixelCoord.x < 0.5)
        offsets.x *= -1;
    if (pixelCoord.y < 0.5)
        offsets.y *= -1;

    // Get 4 samples in the mip level
    float2 minMax0 = gHSM[lightIdx].SampleLevel(gSMSampler, uv, mipLevel);
    float2 minMax1 = gHSM[lightIdx].SampleLevel(gSMSampler, uv + float2(offsets.x, 0), mipLevel);
    float2 minMax2 = gHSM[lightIdx].SampleLevel(gSMSampler, uv + float2(0, offsets.y), mipLevel);
    float2 minMax3 = gHSM[lightIdx].SampleLevel(gSMSampler, uv + offsets, mipLevel);

    float minDepth = min(min(min(minMax0.x, minMax1.x), minMax2.x), minMax3.x);
    float maxDepth = max(max(max(minMax0.y, minMax1.y), minMax2.y), minMax3.y);

    bool needsSAT = true;
    if (maxDepth + 1e-3 < lightDist) {
        visibility = 0;
        needsSAT = false;
    } else if (minDepth - 1e-3 > lightDist) {
        visibility = 1;
        needsSAT = false;
    }

    return needsSAT;
}

float evalSoftShadows(const ShadingData sd, uint lightIdx, bool isDirectional) {
    uint cascadedLevel = 0;
    if (isDirectional) {
        cascadedLevel = getCascadedLevel(sd.posW);
        lightIdx += cascadedLevel;
    }
        
    float4x4 projMatrix = gSMProjection[lightIdx];
    float4 viewPos = mul(gSMView[lightIdx], float4(sd.posW, 1.0));
    float4 projPos = mul(projMatrix, viewPos);
    projPos.xyz = (projPos.xyz / projPos.w);
    float lightDist = isDirectional ? projPos.z : (projPos.w - gSMNear) / (gSMFar - gSMNear);

    float2 shadowUV = projPos.xy;
    shadowUV.y *= -1;                // Flip
    shadowUV = shadowUV * 0.5 + 0.5; // UV from [-1,1] to [0,1]

    if (any(shadowUV.xy < 0.f) || any(shadowUV.xy > 1.f)) // Return if outside of the shadow map
        return 0.0;

    // Search for the average blocker depth using the SAT Variance Shadow Map with the maximum possible radius
    int2 centerPixel = int2(round(shadowUV * gSMSize));
    int4 usedRadiis = int4(0);
    //Get Radiis claped to screen border
    uint2 satPixel = clamp(centerPixel + int2(-gSATMaxSearchRadius), 0, gSMSize - 1);
    usedRadiis.xy = centerPixel - satPixel;
    satPixel = clamp(centerPixel + int2(gSATMaxSearchRadius), 0, gSMSize - 1);
    usedRadiis.zw = satPixel - centerPixel;
    float avrgDepth = lightDist;

    float percentVisible = evalSATVarianceShadows(centerPixel, usedRadiis, lightDist, lightIdx, avrgDepth);

    //Return if sample is visible
    if (percentVisible > 0.99)
        return 1.0;

    // Estimate average depth of occluder (see Variance Soft Shadow Mapping by Yang et al.,  Eq.4)
    float zOcc = abs(avrgDepth - (percentVisible * lightDist)) / ((1.0 - percentVisible));

    float lightWidthW = 0;
    if (isDirectional)
        lightWidthW = abs(lightDist - zOcc) * gCascadedDepthRange[cascadedLevel] * gSunSize;
    else
        lightWidthW = abs(lightDist - zOcc) * (gSpotLightSize / (zOcc)); // World filter width

    //Get the 4 SAT corners (info: y is flipped compared to uv's)
    //Get the pixel offset in pixel
    //-x, -y
    satPixel = getSATPixel(viewPos.xyz, float2(-lightWidthW, lightWidthW), projMatrix);
    usedRadiis.xy = centerPixel - satPixel;

    //+x , +y
    satPixel = getSATPixel(viewPos.xyz, float2(lightWidthW, -lightWidthW), projMatrix, int2(-1));
    usedRadiis.zw = satPixel - centerPixel;

    uint sampleBoxSize = (usedRadiis.x + usedRadiis.z) * (usedRadiis.y + usedRadiis.w);
    float visibility = 0.5;
    bool needsSAT = evalHierarchicalShadowMap(shadowUV, sampleBoxSize, lightIdx, lightDist, visibility);
    
    if (needsSAT)
        visibility = evalSATVarianceShadows(centerPixel, usedRadiis, lightDist, lightIdx, avrgDepth);

    return visibility;
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
        bool isDirectional = lightData.type == (uint)LightType::Directional;
        if (isDirectional)
            lightIdx = kCascadedStartIndex;

        // Shadow Ray for now
        /*
        SceneRayQuery<1> rayQuery;
        const Ray ray = Ray(sd.computeNewRayOrigin(), ls.dir, 0.f, ls.distance);
        if (rayQuery.traceVisibilityRay(ray, RAY_FLAG_NONE, 0xff))
            visibility = 1.0;
        */
        //visibility = evalShadowMap(sd, lightIdx, isDirectional);
        visibility = evalSoftShadows(sd, lightIdx, isDirectional);

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
