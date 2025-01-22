#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"
#include "RayLodHelper.slang"

import Scene.Raytracing;
import Scene.Intersection;
import Utils.Sampling.SampleGenerator;

import Utils.Math.MathHelpers;
import Utils.Geometry.GeometryHelpers;
import Rendering.Lights.LightHelpers;
import Utils.Color.ColorHelpers;
#if EVAL_OPAQUE_SHADOW_MAP
import Rendering.ShadowMaps.ShadowMap;
#endif

import AccelShadow.AccelShadow;
import LinkedList.LinkedListShadow;
import AccelShadowKBuffer.AccelShadowKBuffer;
import AccelIrregularZ.AccelIrregularZ;
import LinkedListIrregularZ.LinkedListIrregularZ;

// Shadow Eval Modes
#define SHADOW_EVAL_MODE_RAYTRACING 0
#define SHADOW_EVAL_MODE_Accel 1
#define SHADOW_EVAL_MODE_LinkedList 2
#define SHADOW_EVAL_MODE_AccelKBuffer 3
#define SHADOW_EVAL_MODE_AccelIrregularZ 4
#define SHADOW_EVAL_MODE_LinkedListIrregularZ 5

#ifndef SHADOW_EVAL_MODE
#define SHADOW_EVAL_MODE SHADOW_EVAL_MODE_RAYTRACING
#endif

//LightSampleModes
#define LIGHT_SAMPLE_MODE_UNIFORM 0
#define LIGHT_SAMPLE_MODE_RIS 1
#define LIGHT_SAMPLE_MODE_ALL 2

#ifndef TR_RAY_QUERY_FLAG
#define TR_RAY_QUERY_FLAG RAY_FLAG_FORCE_NON_OPAQUE
#endif

static const float kMinIncidentAngle = 1e-3; // Min Incident angle for light
static const bool kEnableFallbackRay = ENABLE_FALLBACK_RAY_SHADOWS; // Enable ray tracing for techniques that return a negative shadow value
static const bool kUseStochasticRayTracing = USE_STOCHASTIC_RAY_TRACING; //Uses the stochastic version of the shadow ray

// For RIS light sampling
struct RISReservoir {
    uint lightIdx; // Light Index
    float wSum;    // Weight and Weight sum
    // uint M;         //Unused, as all possible Samples are seen

    /** Initializes ray payload with default parameters.
     */
    __init() {
        lightIdx = 0;
        wSum = 0.0;
        // M = 0;
    }

    [mutating] bool update(uint index, float risWeight, float rnd) {
        wSum += risWeight;
        // M += 1;
        bool selectSample = (rnd * wSum < risWeight);
        if (selectSample) {
            lightIdx = index;
        }
        return selectSample;
    }

    [mutating] void finalize(float targetFunction) {
        /* //When not looping through all lights
        if(targetFunction > 0 && M > 0){
            wSum = (1.0 / targetFunction) * ((1.0/M) * wSum);
            r.M = 1;
        */
        if (targetFunction > 0) {
            wSum = wSum / targetFunction;
        } else {
            wSum = 0;
        }
    }
};

/** Samples a light index either uniform or with RIS (Good if a couple lights are used that dont overlap each other)
 */
AnalyticLightSample sampleLightIndex(float3 posW, uint lightCount, inout SampleGenerator sg, inout uint lightIndex, out float invPdf, out uint type) {
    AnalyticLightSample ls = {};
    #if LIGHT_SAMPLE_MODE == LIGHT_SAMPLE_MODE_UNIFORM //1SPP uniform
        float lightSelect = 0.0;
        lightSelect = sampleNext1D(sg);

        // Pick one of the analytic light sources randomly with equal probability.
        lightIndex = min(uint(lightSelect * lightCount), lightCount - 1);
        invPdf = lightCount; // Light selection pdf = 1.0 / lightCount.

        // Sample local light source.
        LightData lightData = gScene.getLight(lightIndex);
        type = lightData.type;
        sampleLight(posW, lightData, sg, ls);
    #elif LIGHT_SAMPLE_MODE == LIGHT_SAMPLE_MODE_RIS //RIS
        RISReservoir r = RISReservoir();
        // Loop through all lights
        for (uint i = 0; i < lightCount; i++) {
            float randomNum = i == 0 ? 0.5 : sampleNext1D(sg); // Random number
            LightData lightData = gScene.getLight(i);
            AnalyticLightSample itLs;
            sampleLight(posW, lightData, sg, itLs);
            float w = luminance(itLs.Li); // Take the Light attenuation as weight
            if (r.update(i, w, randomNum)) {
                ls = itLs;
                type = lightData.type;
            }
        }
        r.finalize(luminance(ls.Li)); // targetFunction
        // Out data
        lightIndex = r.lightIdx;
        invPdf = r.wSum; // W
    #else // LIGHT_SAMPLE_MODE == LIGHT_SAMPLE_MODE_ALL //All in loop
        invPdf = 1.0;
        // Sample local light source.
        LightData lightData = gScene.getLight(lightIndex);
        type = lightData.type;
        sampleLight(posW, lightData, sg, ls);
    #endif

    return ls;
}

/** Traces a shadow ray towards a light source with ray queries
    \param[in] origin Ray origin for the shadow ray.
    \param[in] dir Direction from shading point towards the light source (normalized).
    \param[in] distance Distance to the light source.
    \return Visibility in [0,1]
*/
float traceShadowRay(float3 origin, float3 dir, float distance)
{
    RayDesc ray;
    ray.Origin = origin;
    ray.Direction = dir;
    ray.TMin = 0.f;
    ray.TMax = distance;

    float visibility = 1.0;

    RayQuery<TR_RAY_QUERY_FLAG> rayQuery;
    rayQuery.TraceRayInline(gScene.rtAccel, 0, 0xff, ray);

    while (rayQuery.Proceed()) {
        if (rayQuery.CandidateType() == CANDIDATE_NON_OPAQUE_TRIANGLE) {
            // Get shading data
            TriangleHit triangleHit;
            triangleHit.instanceID = GeometryInstanceID(rayQuery.CandidateInstanceID(), rayQuery.CandidateGeometryIndex());
            triangleHit.primitiveIndex = rayQuery.CandidatePrimitiveIndex();
            triangleHit.barycentrics = rayQuery.CandidateTriangleBarycentrics();

            VertexData v = gScene.getVertexData(triangleHit);
            uint materialID = gScene.getMaterialID(triangleHit.instanceID);
            ITextureSampler lod = ExplicitLodTextureSampler(0.f);

            //LOD mode handling TODO this is incorrect as it assumes the pixel is the camera
            /*
            if (kShadowLODMode == TexLODMode::RayCones)
            {
                float2 ddx, ddy;
                computeAnisotropicAxesRayCones(triangleHit, v, ray.Direction, rayQuery.CandidateTriangleRayT(), kScreenSpacePixelSpreadAngle, ddx, ddy);
                lod = ExplicitGradientTextureSampler(ddx, ddy);
            }
            else if (kShadowLODMode == TexLODMode::RayDiffs)
            {
                float2 ddx, ddy;
                computeRayDifferentials(triangleHit, ray.Direction, rayQuery.CandidateTriangleRayT(), gScene.camera, kInvFrameDim, ddx, ddy);
                lod = ExplicitGradientTextureSampler(ddx, ddy);
            }
            */

            float opacity = gScene.materials.getMaterialOpacity(v, materialID, lod);

            visibility *= saturate(1.0 - opacity);

            if (visibility <= 0.0)
                rayQuery.Abort();
        }
    }

    //No need to check comitted status, as no hit is accepted

    return visibility;
}

/** Traces a shadow ray towards a light source with ray queries. Uses the sample generator to randomly abort the ray
    \param[in] origin Ray origin for the shadow ray.
    \param[in] dir Direction from shading point towards the light source (normalized).
    \param[in] distance Distance to the light source.
    \param[inout] Sample Generator
    \return Visbility that is either 0 or 1
*/
float traceShadowRayStochastic(float3 origin, float3 dir, float distance, inout SampleGenerator sg)
{
    RayDesc ray;
    ray.Origin = origin;
    ray.Direction = dir;
    ray.TMin = 0.f;
    ray.TMax = distance;

    float visibility = 1.0; //Visible

    RayQuery<TR_RAY_QUERY_FLAG> rayQuery;
    rayQuery.TraceRayInline(gScene.rtAccel, 0, 0xff, ray);

    while (rayQuery.Proceed()) {
        if (rayQuery.CandidateType() == CANDIDATE_NON_OPAQUE_TRIANGLE) {
            // Get shading data
            TriangleHit triangleHit;
            triangleHit.instanceID = GeometryInstanceID(rayQuery.CandidateInstanceID(), rayQuery.CandidateGeometryIndex());
            triangleHit.primitiveIndex = rayQuery.CandidatePrimitiveIndex();
            triangleHit.barycentrics = rayQuery.CandidateTriangleBarycentrics();

            VertexData v = gScene.getVertexData(triangleHit);
            uint materialID = gScene.getMaterialID(triangleHit.instanceID);
            // LOD mode handling TODO this is incorrect as it assumes the pixel is the camera
            ITextureSampler lod = ExplicitLodTextureSampler(0.f);

            float opacity = gScene.materials.getMaterialOpacity(v, materialID, lod);
            float roulett = sampleNext1D(sg);

            if (roulett <= opacity) {
                visibility = 0.0;
                rayQuery.Abort();
            }
        }
    }

    // No need to check comitted status, as no hit is accepted

    return visibility;
}

/** Evaluates the direct illumination from analytic lights.
    This function samples Falcor's light list uniformly with one shadow ray.
    \param[in] sd Shading data.
    \param[in] mi Material instance.
    \param[in,out] sg SampleGenerator object.
    \return Outgoing radiance in view direction.
*/
float3 evalDirectAnalytic(const ShadingData sd, const IMaterialInstance mi, inout SampleGenerator sg, const float3 thp = float3(1.0))
{
    const uint lightCount = gScene.getLightCount();
    if (lightCount == 0) return float3(0.0);

    // Pick one of the analytic light sources randomly with equal probability.
    uint lightIndex = 0;
    float invPdf = 1.0;
    uint lightType = 0;
    float3 Li = float3(0);

    #if LIGHT_SAMPLE_MODE == LIGHT_SAMPLE_MODE_ALL // For all loop over all lights, for other methods 1SPP is evaluated
    for (lightIndex; lightIndex < lightCount; lightIndex++)
    #endif
    {
        // Sample local light source.
        AnalyticLightSample ls = sampleLightIndex(sd.posW, lightCount, sg, lightIndex, invPdf, lightType);
        float NdotL = dot(sd.getOrientedFaceNormal(), ls.dir);

        // Reject sample if invalid or has an too steep incident angle
        if (all(ls.Li <= 0.0) || (abs(NdotL) < kMinIncidentAngle)) {
            #if LIGHT_SAMPLE_MODE == LIGHT_SAMPLE_MODE_ALL // Loop over all lights
                    continue;
            #else
                    return float3(0.0);
            #endif
        }

        // Flip light dir for non-opaque surfaces, so light shines through
        bool flipLightDir = (NdotL < 0) && (sd.opacity < 1);
        float3 lightDirection = flipLightDir ? -ls.dir : ls.dir;
        if (flipLightDir)
            ls.Li *= (1.0 - sd.opacity); // consider the opacity of the hit if light shined through

        // Eval BSDF
        float3 brdf = mi.eval(sd, lightDirection, sg) * thp;
        float brdf_lum = luminance(brdf);
        if (brdf_lum <= 0) {
            #if LIGHT_SAMPLE_MODE == LIGHT_SAMPLE_MODE_ALL // Loop over all lights
                        continue;
            #else
                        return float3(0.0);
            #endif
        }

        // Test visibility by tracing a shadow ray.
        bool isDirectional = lightType == (uint)LightType::Directional; // Slight different calculations for ortho
        float shadow = 1.0;

        // Shadow maps
        #if SHADOW_EVAL_MODE == SHADOW_EVAL_MODE_Accel
            shadow = gAccelShadow.eval(lightIndex, sd.posW, ls.posW);
        #elif SHADOW_EVAL_MODE == SHADOW_EVAL_MODE_LinkedList
            shadow = gLinkedListShadow.eval(lightIndex, sd.posW);
        #elif SHADOW_EVAL_MODE == SHADOW_EVAL_MODE_AccelKBuffer
            shadow = gAccelShadowKBuffer.eval(lightIndex, sd.posW, ls.posW);
        #elif SHADOW_EVAL_MODE ==  SHADOW_EVAL_MODE_AccelIrregularZ
            shadow = gAccelIrregularZ.eval(lightIndex, sd.posW, isDirectional, saturate(brdf_lum));
        #elif SHADOW_EVAL_MODE ==  SHADOW_EVAL_MODE_LinkedListIrregularZ
            shadow = gLinkedListIrregularZ.eval(lightIndex, sd.posW, isDirectional, saturate(brdf_lum));
        #endif

        // TODO add quality modes for fallback ray (eg. with fixed alpha values, as it is only in the distance?)

        // Get origin with offset applied in direction of the geometry normal to avoid self-intersection.
        if (SHADOW_EVAL_MODE == SHADOW_EVAL_MODE_RAYTRACING || (shadow < 0) && kEnableFallbackRay) {
            const float3 origin = computeRayOrigin(sd.posW, dot(sd.faceN, ls.dir) >= 0.f ? sd.faceN : -sd.faceN);
            if(kUseStochasticRayTracing)
                shadow = traceShadowRayStochastic(origin, ls.dir, ls.distance, sg);
            else
                shadow = traceShadowRay(origin, ls.dir, ls.distance);
        }

        // Clamp shadow in [0,1]
        shadow = clamp(shadow, 0.0, 1.0);

        #if EVAL_OPAQUE_SHADOW_MAP
            LightData lightData = gScene.getLight(lightIndex);
            SMLightData smData = gShadowMap.getShadowMapLightData(lightData, lightIndex);
            float opaqueShadow = 1.f;
            bool isDynamic = false;
            gShadowMap.evalShadowMap(sd.posW, smData, float4(0.f) /*random (only x is used currently)*/, 0.f /*MipLevel*/, opaqueShadow, isDynamic);

            shadow = min(shadow, opaqueShadow);
        #endif
        // Evaluate contribution.
        Li += brdf * shadow * ls.Li * invPdf;
    }

    return Li;
}
