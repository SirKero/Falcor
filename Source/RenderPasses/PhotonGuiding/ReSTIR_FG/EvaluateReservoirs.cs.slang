#include "../StructsAndHelpers.slang"
#include "../SharedEnums.slang"
#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.RaytracingInline;
import Utils.Sampling.SampleGenerator;
import Utils.Color.ColorHelpers;
import Rendering.RTXDI.RTXDI;
import Rendering.Materials.IsotropicGGX;

Texture2D<PackedHitInfo> gVBuffer;
StructuredBuffer<ReservoirCaustic> gCausticReservoir;
StructuredBuffer<PathReservoir> gPathReservoir;

StructuredBuffer<ReservoirFG> gFinalGatherReservoir;
Texture2D<float4> gEmission;

RWTexture2D<uint> gGuidingCounter;
RWTexture2D<uint> gLightIndexGuidingCounter;
Texture2D<uint> gMapLightIndexToGuidingDirection;

RWTexture2D<float4> gOutColor;
RWTexture2D<PackedHitInfo> gVBufferPrev;
RWTexture2D<float4> gViewPrev;

// NRD outputs (only valid if define is set)
RWTexture2D<float4> gDiffuseRadiance;
RWTexture2D<float4> gSpecularRadiance;
RWTexture2D<float4> gDiffuseReflectance;
RWTexture2D<float4> gSpecularReflectance;

cbuffer CB
{
    uint gFrameCount;         // Current it for sample gen
    uint2 gFrameDim;          // Frame Dimensions for camera dir
    float gNormalizedPixelArea; // For backprojection

    uint gLightIndexGuidingResolution;
    uint gGuidingTextureResolution;
    uint gMapTextureResolution;
    float gConfidenceCapPath;   //Maximal Confidence Value as float
    float gConfidenceCapCaustic;  //Maximal Confidence Value as float
}

static const bool kUseEnvBackground = USE_ENV_BACKROUND;
static const uint kMIHints = (uint)MaterialInstanceHints::AdjustShadingNormal;
static const uint kGuidingMode = GUIDING_MODE;
static const bool kEnableLightTraceSplatting = ENABLE_LIGHT_TRACE_SPATTING;
static const uint kDiscretizedEmissionFactor = GUIDING_DISCRETIZED_EMISSION_FACTOR;
static const uint kDiscretizedEmissionMax = GUIDING_DISCRETIZED_EMISSION_MAX;
static const bool kDisableDirectLight = DEBUG_DISABLE_DIRECT_LIGHT;
static const bool kDisableIndirectLight = DEBUG_DISABLE_INDIRECT_LIGHT;
static const uint kRNGNumPasses = RNG_NUM_PASSES;
static const bool kUseOptimizedAtlas = USE_OPTIMIZED_ATLAS;
static const float kDemodulateMinReflectance = 0.01f;

inline uint getDiscretizedEmission(float emission) {
    uint discretizedEmission = uint(round(kDiscretizedEmissionFactor * emission));
    return clamp(discretizedEmission, 1, kDiscretizedEmissionMax);
}

void addToGuidingTexture(int lightIndex, uint2 guidingPixel, float emission, uint reservoirConfidence, bool isCausticPass)
{
    if (lightIndex < 0 || emission <= 0)
        return;

    // Light Index guiding entry
    if (kUseOptimizedAtlas) {
        //For the optimized atlas we only use the discretized methods
        if (kGuidingMode == (uint)GuidingMode::ReSTIR || kGuidingMode == (uint)GuidingMode::ReSTIRDiscretized)
        {
            uint2 lightIndexTexturePixel = index1Dto2D(lightIndex, gLightIndexGuidingResolution);
            InterlockedAdd(gLightIndexGuidingCounter[lightIndexTexturePixel], getDiscretizedEmission(emission));
        }
        else if (kGuidingMode == (uint)GuidingMode::ReSTIRConfidence)
        {
            uint2 lightIndexTexturePixel = index1Dto2D(lightIndex, gLightIndexGuidingResolution);
            float confidenceCap = isCausticPass ? gConfidenceCapCaustic : gConfidenceCapPath;
            InterlockedAdd(gLightIndexGuidingCounter[lightIndexTexturePixel], getDiscretizedEmission((emission / confidenceCap) * reservoirConfidence));
        } else if (kGuidingMode == (uint)GuidingMode::ReSTIRReverseConfidence)
        {
            uint2 lightIndexTexturePixel = index1Dto2D(lightIndex, gLightIndexGuidingResolution);
            float confidenceCapMul = isCausticPass ? gConfidenceCapCaustic : gConfidenceCapPath;
            confidenceCapMul = max(1.f, confidenceCapMul - reservoirConfidence);
            InterlockedAdd(gLightIndexGuidingCounter[lightIndexTexturePixel], getDiscretizedEmission(emission * confidenceCapMul));
        }
    }

    // Update guiding pixel if mapping is enabled
    if (kUseOptimizedAtlas) {
        uint2 lightPixel = uint2(lightIndex % gLightIndexGuidingResolution, lightIndex / gLightIndexGuidingResolution);
        uint mapIdx = gMapLightIndexToGuidingDirection[lightPixel];

        //If mapped index is invalid, return
        if(mapIdx >= kAtlasOptimizationMaxMapIndex)
            return;
        
        guidingPixel += uint2(mapIdx % gMapTextureResolution, mapIdx / gMapTextureResolution) * gGuidingTextureResolution;
    }

    if (kGuidingMode == (uint)GuidingMode::ReSTIR)
    {
        uint currentColor = 0;
        uint originalValue;
        [allow_uav_condition]
        do {
            InterlockedAdd(gGuidingCounter[guidingPixel], 0u, currentColor);
            float color = asfloat(currentColor);
            uint updatedColor = asuint(color + emission);
            InterlockedCompareExchange(gGuidingCounter[guidingPixel], currentColor, updatedColor, originalValue);
        } while (originalValue != currentColor);
    } else if (kGuidingMode == (uint)GuidingMode::ReSTIRDiscretized)
    {
        uint discretizedEmission = uint(round(kDiscretizedEmissionFactor * emission));
        InterlockedAdd(gGuidingCounter[guidingPixel], getDiscretizedEmission(emission));
    } else if (kGuidingMode == (uint)GuidingMode::ReSTIRConfidence)
    {
        uint discretizedEmission = max(uint(round(kDiscretizedEmissionFactor * emission * reservoirConfidence)), 1);
        float confidenceCap = isCausticPass ? gConfidenceCapCaustic : gConfidenceCapPath;
        InterlockedAdd(gGuidingCounter[guidingPixel], getDiscretizedEmission((emission / confidenceCap) * reservoirConfidence));
    } else if (kGuidingMode == (uint)GuidingMode::ReSTIRReverseConfidence)
    {
        uint discretizedEmission = max(uint(round(kDiscretizedEmissionFactor * emission * reservoirConfidence)), 1);
        float confidenceCapMul = isCausticPass ? gConfidenceCapCaustic : gConfidenceCapPath;
        confidenceCapMul = max(1.f, confidenceCapMul - reservoirConfidence);
        InterlockedAdd(gGuidingCounter[guidingPixel], getDiscretizedEmission(emission * confidenceCapMul));
    }
}

float3 evaluateFinalGatherReservoir(uint2 pixel, inout SampleGenerator sg) {
    float3 outColor = float3(0);
    ReservoirFG fgReservoir = gFinalGatherReservoir[index2Dto1D(pixel, gFrameDim.x)];
    if (!fgReservoir.isValid() || fgReservoir.wSum <= 0)
        return outColor;

    // Get surface and shading data
    HitInfo hitInfo = HitInfo(fgReservoir.sampleSurface);
    let lod = ExplicitLodTextureSampler(0.f);
    ShadingData sd = loadShadingData(hitInfo, -fgReservoir.sampleData.sampleView, lod);
    let mi = gScene.materials.getMaterialInstance(sd, lod, kMIHints);

    outColor = evaluateFinalGatherSample(fgReservoir, sd, mi, sg);
    outColor *= fgReservoir.thp * fgReservoir.wSum;

    addToGuidingTexture(fgReservoir.lightIndex, fgReservoir.guidingPixels, luminance(outColor), fgReservoir.c, false);
    
    return outColor;
}

float3 evaluateCausticReservoir(uint2 pixel, inout SampleGenerator sg) {
    float3 outColor = float3(0);
    ReservoirCaustic causticReservoir = gCausticReservoir[index2Dto1D(pixel, gFrameDim.x)];
    if (!causticReservoir.isValid() || causticReservoir.wSum <= 0)
        return outColor;

    // Get surface and shading data
    HitInfo hitInfo = HitInfo(causticReservoir.sampleSurface);
    let lod = ExplicitLodTextureSampler(0.f);
    ShadingData sd = loadShadingData(hitInfo, causticReservoir.sampleSurfaceView, lod);
    let mi = gScene.materials.getMaterialInstance(sd, lod, kMIHints);
    let bsdfProperties = mi.getProperties(sd);
    
    // Light Trace
    if (kEnableLightTraceSplatting && causticReservoir.pathLength == 0)
    {
        float3 directionToCamera = normalize(gScene.camera.getPosition() - sd.posW);
        outColor = causticReservoir.wSum * causticReservoir.photonRadiance * mi.eval(sd, directionToCamera, sg);
    } else //Photon Mapping
    {
        float NdotL = dot(bsdfProperties.guideNormal, causticReservoir.photonDir);
        if (NdotL > 0) {
            outColor = causticReservoir.wSum * causticReservoir.photonRadiance * mi.eval(sd, causticReservoir.photonDir, sg);
            outColor /= NdotL;
            outColor *= causticReservoir.thp;
        }
    }

    addToGuidingTexture(causticReservoir.lightIndex, causticReservoir.guidingPixels, luminance(outColor), causticReservoir.c, true);

    return outColor;
}

void evalAllReservoirs(uint2 pixel, HitInfo hitInfo, float3 viewDir)
{
    float3 outColor = float3(0);
    if (hitInfo.isValid()) {
        SampleGenerator sg = SampleGenerator(pixel, gFrameCount * kRNGNumPasses + (kRNGNumPasses - 1));
        let lod = ExplicitLodTextureSampler(0.f);

        // Get Material properties
        ShadingData sd = loadShadingData(hitInfo, viewDir, lod);
        let mi = gScene.materials.getMaterialInstance(sd, lod, kMIHints);
        let bsdfProperties = mi.getProperties(sd);

        // Add Emissive
        outColor += bsdfProperties.emission;
        // outColor += bsdfProperties.diffuseReflectionAlbedo;

        // Eval ReSTIR DI
        float dist = 1.f;
        float3 dir = {};
        float3 Li = {};
        bool rtxdiValid = gRTXDI.getFinalSample(pixel, dir, dist, Li);

        if (rtxdiValid)
        {
            rtxdiValid = dispatchShadowRay(sd, dir, dist);
        }
        if (rtxdiValid && !kDisableDirectLight)
        {
            outColor += mi.eval(sd, dir, sg) * Li;
        }

        float3 indirectLight = float3(0);
    #if ENABLE_RANDOM_REPLAY
        PathReservoir pathReservoir = gPathReservoir[index2Dto1D(pixel, gFrameDim.x)];
        indirectLight += pathReservoir.F * pathReservoir.weight;
        addToGuidingTexture(pathReservoir.lightIndex, pathReservoir.guidingPixels, luminance(indirectLight), pathReservoir.c, false);

        // Debug Show Paths as color
    #if DEBUG_SHOW_PATHS
        float3 debugColor = float3(0);
        if (pathReservoir.flags.isFinalGather && pathReservoir.pathLength == 0)
            debugColor = float3(0, 1, 0); // Green
        else if (pathReservoir.flags.isFinalGather && pathReservoir.pathLength > 0)
            debugColor = float3(0, 1, 1); // Cyan
        else if (pathReservoir.flags.isRadianceEstimate)
            debugColor = float3(1, 0, 0); // Red
        else if (pathReservoir.flags.isNEE)
            debugColor = float3(1, 1, 0); // Yellow
        else if (pathReservoir.flags.isEmissiveHit)
            debugColor = float3(1, 0, 1); // Purple

        gDebug[pixel] = float4(debugColor, 1);
    #endif
    #else
        indirectLight += evaluateFinalGatherReservoir(pixel, sg);
        indirectLight += gEmission[pixel].xyz;
    #endif

        indirectLight += evaluateCausticReservoir(pixel, sg);

        // indirectLight = min(indirectLight, 1000.0); //TODO only for ref to avoid extreme fireflies
        if (!kDisableIndirectLight)
            outColor += indirectLight;
    } else {
        outColor = gScene.envMap.eval(viewDir);
    }

    gOutColor[pixel] = float4(outColor, 1.0);
}

void evalAllReservoirsNRD(uint2 pixel, HitInfo hitInfo, float3 viewDir)
{
    float diffHitT = 1; // TODO Proabilites of the hit 
    float specHitT = 1; // TODO
    float3 emission = float3(0);
    float3 diffuseRadiance = float3(0);
    float3 diffuseReflectance = float3(0);
    float3 specularRadiance = float3(0);
    float3 specularReflectance = float3(0);

    if (hitInfo.isValid()) {
        SampleGenerator sg = SampleGenerator(pixel, gFrameCount * kRNGNumPasses + (kRNGNumPasses - 1));
        let lod = ExplicitLodTextureSampler(0.f);

        // Get Material properties
        ShadingData sd = loadShadingData(hitInfo, viewDir, lod);
        let mi = gScene.materials.getMaterialInstance(sd, lod, kMIHints);
        let bsdfProperties = mi.getProperties(sd);

        // Add Emissive
        emission += bsdfProperties.emission;

        // Get diffuse and specular Reflectance
        diffuseReflectance = max(kDemodulateMinReflectance, bsdfProperties.diffuseReflectionAlbedo + bsdfProperties.diffuseTransmissionAlbedo);
        // For specular an approximate shading model with a single specular lobe is used.
        const float NdotV = saturate(dot(bsdfProperties.guideNormal, sd.V));
        const float ggxAlpha = bsdfProperties.roughness * bsdfProperties.roughness;
        if (bsdfProperties.roughness < 0.2) {
            specularReflectance = float3(1);
        }
        else {
            specularReflectance = approxSpecularIntegralGGX( bsdfProperties.specularReflectionAlbedo + bsdfProperties.specularTransmissionAlbedo, ggxAlpha, NdotV);
        }
        specularReflectance = max(kDemodulateMinReflectance, specularReflectance.xyz);

        // Hack for path and caustic ReSTIR, as we cannot demodulate here
        float diffLuminance = luminance(diffuseReflectance);
        float specLuminance = luminance(specularReflectance);
        float combined = diffLuminance + specLuminance;
        float diffuseProb = diffLuminance / combined;
        float specularProb = specLuminance / combined;

        // Eval ReSTIR DI
        float dist = 1.f;
        float3 dir = {};
        float3 Li = {};
        bool rtxdiValid = gRTXDI.getFinalSample(pixel, dir, dist, Li);

        if (rtxdiValid)
        {
            rtxdiValid = dispatchShadowRay(sd, dir, dist);
        }
        if (rtxdiValid && !kDisableDirectLight)
        {
            sd.mtl.setActiveLobes((uint)LobeType::Diffuse);
            diffuseRadiance += mi.eval(sd, dir, sg) * Li;
            sd.mtl.setActiveLobes((uint)LobeType::Specular);
            specularRadiance += mi.eval(sd, dir, sg) * Li;
        }

        float3 indirectLight = float3(0);
#if ENABLE_RANDOM_REPLAY
        PathReservoir pathReservoir = gPathReservoir[index2Dto1D(pixel, gFrameDim.x)];
        indirectLight += pathReservoir.F * pathReservoir.weight;
        addToGuidingTexture(pathReservoir.lightIndex, pathReservoir.guidingPixels, luminance(indirectLight), pathReservoir.c, false);
#else
        indirectLight += evaluateFinalGatherReservoir(pixel, sg);
        indirectLight += gEmission[pixel].xyz;
#endif

        indirectLight += evaluateCausticReservoir(pixel, sg);

        diffuseRadiance += diffuseProb * indirectLight;
        specularRadiance += specularProb * indirectLight;

        diffuseRadiance /= diffuseReflectance;
        specularRadiance /= specularReflectance;
    } else {
        emission = gScene.envMap.eval(viewDir);
    }

    gOutColor[pixel] = float4(emission, 1.0);
    gDiffuseRadiance[pixel] = float4(diffuseRadiance, diffHitT);
    gSpecularRadiance[pixel] = float4(specularRadiance, specHitT);
    gDiffuseReflectance[pixel] = float4(diffuseReflectance, 1);
    gSpecularReflectance[pixel] = float4(specularReflectance, 1);
}

[numthreads(16, 16, 1)]
void main(uint2 pixel: SV_DispatchThreadID)
{
    if(any(pixel >= gFrameDim))
        return;

    HitInfo hitInfo = HitInfo(gVBuffer[pixel]);
    float3 viewDir = gScene.camera.computeRayPinhole(pixel, gFrameDim).dir;

#if USE_NRD
    evalAllReservoirsNRD(pixel, hitInfo, viewDir);
#else
    evalAllReservoirs(pixel, hitInfo, viewDir);
#endif
    
#if ENABLE_RANDOM_REPLAY
    gVBufferPrev[pixel] = hitInfo.getData();
    gViewPrev[pixel] = float4(-viewDir, 1);
#endif
}
