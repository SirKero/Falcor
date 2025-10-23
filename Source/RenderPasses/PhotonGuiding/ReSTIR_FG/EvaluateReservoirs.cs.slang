#include "../StructsAndHelpers.slang"
#include "../SharedEnums.slang"
#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.RaytracingInline;
import Utils.Sampling.SampleGenerator;
import Utils.Color.ColorHelpers;
import Rendering.RTXDI.RTXDI;

Texture2D<PackedHitInfo> gVBuffer;
StructuredBuffer<ReservoirFG> gFinalGatherReservoir;
StructuredBuffer<ReservoirCaustic> gCausticReservoir;
Texture2D<float4> gEmission;

RWTexture2D<uint> gGuidingCounter;
RWTexture2D<uint> gLightIndexGuidingCounter;

RWTexture2D<float4> gOutColor;

cbuffer CB
{
    uint gFrameCount;         // Current it for sample gen
    uint2 gFrameDim;          // Frame Dimensions for camera dir
    float gNormalizedPixelArea; // For backprojection
    uint gLightIndexGuidingResolution;
}

static const bool kUseEnvBackground = USE_ENV_BACKROUND;
static const uint kMIHints = (uint)MaterialInstanceHints::AdjustShadingNormal;
static const uint kGuidingMode = GUIDING_MODE;
static const uint kLightIndexGuidingMode = LIGHT_INDEX_GUIDING_MODE;
static const bool kEnableLightTraceSplatting = ENABLE_LIGHT_TRACE_SPATTING;
static const uint kDiscretizedEmissionFactor = GUIDING_DISCRETIZED_EMISSION_FACTOR;
static const bool kDisableDirectLight = DEBUG_DISABLE_DIRECT_LIGHT;
static const bool kDisableIndirectLight = DEBUG_DISABLE_INDIRECT_LIGHT;

void addToGuidingTexture(int lightIndex, int2 guidingPixel, float emission, uint reservoirConfidence)
{
    if (lightIndex < 0 || emission <= 0|| any(guidingPixel < 0))
        return;

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
        uint discretizedEmission = max(uint(round(kDiscretizedEmissionFactor * emission)), 1);
        InterlockedAdd(gGuidingCounter[guidingPixel], discretizedEmission);
    }

    if (kLightIndexGuidingMode == (uint)GuidingLightIndexMode::ReSTIR)
    {
        uint2 lightIndexTexturePixel = index1Dto2D(lightIndex, gLightIndexGuidingResolution);
        uint discretizedEmission = uint(round(kDiscretizedEmissionFactor * emission));
        InterlockedAdd(gLightIndexGuidingCounter[lightIndexTexturePixel], discretizedEmission);
    }
    else if (kLightIndexGuidingMode == (uint)GuidingLightIndexMode::ReSTIRConf)
    {
        uint2 lightIndexTexturePixel = index1Dto2D(lightIndex, gLightIndexGuidingResolution);
        uint discretizedEmission = uint(round(kDiscretizedEmissionFactor * emission * reservoirConfidence));
        InterlockedAdd(gLightIndexGuidingCounter[lightIndexTexturePixel], discretizedEmission);
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

    addToGuidingTexture(fgReservoir.lightIndex, fgReservoir.guidingPixels, luminance(outColor), fgReservoir.c);
    
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

    addToGuidingTexture(causticReservoir.lightIndex, causticReservoir.guidingPixels, luminance(outColor), causticReservoir.c);

    return outColor;
}

[numthreads(16, 16, 1)]
void main(uint2 pixel: SV_DispatchThreadID)
{
    if(any(pixel >= gFrameDim))
        return;

    HitInfo hitInfo = HitInfo(gVBuffer[pixel]);
    float3 viewDir = gScene.camera.computeRayPinhole(pixel, gFrameDim).dir;

    float3 outColor = float3(0);
    if(hitInfo.isValid()){
        SampleGenerator sg = SampleGenerator(pixel, gFrameCount * 5 + 4);
        let lod = ExplicitLodTextureSampler(0.f);

        // Get Material properties
        ShadingData sd = loadShadingData(hitInfo, viewDir, lod);
        let mi = gScene.materials.getMaterialInstance(sd, lod, kMIHints);
        let bsdfProperties = mi.getProperties(sd);

        // Add Emissive
        outColor += bsdfProperties.emission;
        //outColor += bsdfProperties.diffuseReflectionAlbedo;

        //Eval ReSTIR DI
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
        indirectLight += evaluateFinalGatherReservoir(pixel, sg);
        indirectLight += evaluateCausticReservoir(pixel, sg);
        indirectLight += gEmission[pixel].xyz;
        if (!kDisableIndirectLight)
            outColor += indirectLight;
       
    }else{
        outColor = gScene.envMap.eval(viewDir);
    }

    gOutColor[pixel] = float4(outColor, 1.0);
}
