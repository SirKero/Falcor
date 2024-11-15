#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

__exported import Scene.Raytracing;
__exported import Scene.Intersection;
__exported import Utils.Sampling.SampleGenerator;

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

// Shadow Eval Modes
#define SHADOW_EVAL_MODE_RAYTRACING 0
#define SHADOW_EVAL_MODE_Accel 1
#define SHADOW_EVAL_MODE_LinkedList 2
#define SHADOW_EVAL_MODE_AccelKBuffer 3
#define SHADOW_EVAL_MODE_AccelIrregularZ 4

#ifndef SHADOW_EVAL_MODE
#define SHADOW_EVAL_MODE SHADOW_EVAL_MODE_RAYTRACING
#endif

//LightSampleModes
#define LIGHT_SAMPLE_MODE_UNIFORM 0
#define LIGHT_SAMPLE_MODE_RIS 1

#ifndef TR_RAY_QUERY_FLAG
#define TR_RAY_QUERY_FLAG RAY_FLAG_FORCE_NON_OPAQUE
#endif

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
AnalyticLightSample sampleLightIndex(float3 posW, uint lightCount, inout SampleGenerator sg, out uint lightIndex, out float invPdf) {
    AnalyticLightSample ls = {};
    #if LIGHT_SAMPLE_MODE == LIGHT_SAMPLE_MODE_UNIFORM
        float lightSelect = 0.0;
        lightSelect = sampleNext1D(sg);

        // Pick one of the analytic light sources randomly with equal probability.
        lightIndex = min(uint(lightSelect * lightCount), lightCount - 1);
        invPdf = lightCount; // Light selection pdf = 1.0 / lightCount.

        // Sample local light source.
        LightData lightData = gScene.getLight(lightIndex);
        sampleLight(posW, lightData, sg, ls);
    #else //LIGHT_SAMPLE_MODE == LIGHT_SAMPLE_MODE_RIS
        RISReservoir r = RISReservoir();
        LightData selectedLightData = {};
        // Loop through all lights
        for (uint i = 0; i < lightCount; i++) {
            float randomNum = i == 0 ? 0.5 : sampleNext1D(sg); // Random number
            LightData lightData = gScene.getLight(i);
            AnalyticLightSample itLs;
            sampleLight(posW, lightData, sg, itLs);
            float w = luminance(itLs.Li); // Take the Light attenuation as weight
            if (r.update(i, w, randomNum)) {
                ls = itLs;
                selectedLightData = lightData;
            }
        }
        r.finalize(luminance(ls.Li)); // targetFunction
        // Out data
        lightIndex = r.lightIdx;
        invPdf = r.wSum; // W
    #endif

    return ls;
}

/** Traces a shadow ray towards a light source with ray queries
    \param[in] origin Ray origin for the shadow ray.
    \param[in] dir Direction from shading point towards the light source (normalized).
    \param[in] distance Distance to the light source.
    \return True if light is visible, false otherwise.
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
            let lod = ExplicitLodTextureSampler(0.f);
            ShadingData sd = gScene.materials.prepareShadingData(v, materialID, -ray.Direction, lod);

            visibility *= saturate(1.0 - sd.opacity);

            if (visibility <= 0.0)
                rayQuery.Abort();
        }
    }

    //No need to check comitted status, as no hit is accepted

    return visibility;
}

/** Evaluates the direct illumination from analytic lights.
    This function samples Falcor's light list uniformly with one shadow ray.
    \param[in] sd Shading data.
    \param[in] mi Material instance.
    \param[in,out] sg SampleGenerator object.
    \return Outgoing radiance in view direction.
*/
float3 evalDirectAnalytic(const ShadingData sd, const IMaterialInstance mi, inout SampleGenerator sg)
{
    const uint lightCount = gScene.getLightCount();
    if (lightCount == 0) return float3(0.0);

    // Pick one of the analytic light sources randomly with equal probability.
    uint lightIndex = 0;
    float invPdf = 1.0;

    // Sample local light source.
    AnalyticLightSample ls = sampleLightIndex(sd.posW, lightCount, sg, lightIndex, invPdf);

    if (all(ls.Li <= 0.0))
        return float3(0.0);

    // Reject sample if not in the hemisphere of a BSDF lobe.
    float NdotL = dot(sd.getOrientedFaceNormal(), ls.dir);
    bool flipLightDir = (NdotL < kMinCosTheta) && (sd.opacity < 1);
    float3 lightDirection = flipLightDir ? -ls.dir : ls.dir;

    // Test visibility by tracing a shadow ray.
    float shadow = 1.0;
#if SHADOW_EVAL_MODE == SHADOW_EVAL_MODE_RAYTRACING
    // Get origin with offset applied in direction of the geometry normal to avoid self-intersection.
    const float3 origin = computeRayOrigin(sd.posW, dot(sd.faceN, ls.dir) >= 0.f ? sd.faceN : -sd.faceN);
    shadow = traceShadowRay(origin, ls.dir, ls.distance);
#elif SHADOW_EVAL_MODE == SHADOW_EVAL_MODE_Accel
    shadow = gAccelShadow.eval(lightIndex, sd.posW, ls.posW);
#elif SHADOW_EVAL_MODE == SHADOW_EVAL_MODE_LinkedList
    shadow = gLinkedListShadow.eval(lightIndex, sd.posW);
#elif SHADOW_EVAL_MODE == SHADOW_EVAL_MODE_AccelKBuffer
    shadow = gAccelShadowKBuffer.eval(lightIndex, sd.posW, ls.posW);
#else // SHADOW_EVAL_MODE ==  SHADOW_EVAL_MODE_AccelIrregularZ
    shadow = gAccelIrregularZ.eval(lightIndex, sd.posW, ls.posW);
#endif

#if EVAL_OPAQUE_SHADOW_MAP
    LightData lightData = gScene.getLight(lightIndex);
    SMLightData smData = gShadowMap.getShadowMapLightData(lightData, lightIndex);
    float opaqueShadow = 1.f;
    bool isDynamic = false;
    gShadowMap.evalShadowMap(sd.posW, smData, float4(0.f) /*random (only x is used currently)*/, 0.f /*MipLevel*/, opaqueShadow, isDynamic);

    shadow = min(shadow, opaqueShadow);
#endif
    if (shadow <= 0) return float3(0.f);

    // Evaluate contribution.
    return mi.eval(sd, lightDirection, sg) * ls.Li * invPdf * shadow;
}
