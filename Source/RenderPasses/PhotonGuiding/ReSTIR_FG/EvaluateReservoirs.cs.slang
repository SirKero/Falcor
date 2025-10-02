#include "../StructsAndHelpers.slang"
#include "../SharedEnums.slang"
#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.RaytracingInline;
import Utils.Sampling.SampleGenerator;
import Utils.Color.ColorHelpers;
import Rendering.RTXDI.RTXDI;

#ifndef NUM_GUIDING_TEXTURES
#define NUM_GUIDING_TEXTURES 1
#endif

Texture2D<PackedHitInfo> gVBuffer;
StructuredBuffer<ReservoirFG> gFinalGatherReservoir;
StructuredBuffer<ReservoirCaustic> gCausticReservoir;
Texture2D<float4> gEmission;

RWTexture2D<uint> gGuidingCounter[NUM_GUIDING_TEXTURES];
RWTexture2D<float4> gOutColor;

cbuffer CB
{
    uint gFrameCount;         // Current it for sample gen
    uint2 gFrameDim;          // Frame Dimensions for camera dir
    float gNormalizedPixelArea; //For backprojection
}

static const bool kUseEnvBackground = USE_ENV_BACKROUND;
static const uint kMIHints = (uint)MaterialInstanceHints::AdjustShadingNormal;
static const uint kGuidingMode = GUIDING_MODE;
static const bool kEnableLightTraceSplatting = ENABLE_LIGHT_TRACE_SPATTING;

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

    if (kGuidingMode == (uint)GuidingMode::ReSTIR)
    {
        if (fgReservoir.lightIndex < 0)
            return outColor;
        float histogramEmission = luminance(outColor);
        uint currentColor = 0;
        uint originalValue;
        [allow_uav_condition]
        do {
            InterlockedAdd(gGuidingCounter[fgReservoir.lightIndex][fgReservoir.guidingPixels], 0u, currentColor);
            float color = asfloat(currentColor);
            uint updatedColor = asuint(color + histogramEmission);
            InterlockedCompareExchange(gGuidingCounter[fgReservoir.lightIndex][fgReservoir.guidingPixels], currentColor, updatedColor, originalValue);
        } while (originalValue != currentColor);
    }
    
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
    if (kEnableLightTraceSplatting && causticReservoir.pathLength == 0) {
        float3 directionToCamera = gScene.camera.getPosition() - sd.posW;
        float distanceToCamera = length(directionToCamera);
        directionToCamera /= distanceToCamera;
        const float cameraPdf = getCameraBackprojectPDF(directionToCamera, distanceToCamera, normalize(gScene.camera.data.cameraW), gNormalizedPixelArea);
        outColor = causticReservoir.wSum * causticReservoir.photonRadiance * mi.eval(sd, directionToCamera, sg) / cameraPdf;
    } else {
        float NdotL = dot(bsdfProperties.guideNormal, causticReservoir.photonDir);
        if (NdotL > 0) {
            outColor = causticReservoir.wSum * causticReservoir.photonRadiance * mi.eval(sd, causticReservoir.photonDir, sg);
            outColor /= NdotL;
            outColor *= causticReservoir.thp;
        }
    }

    if (kGuidingMode == (uint)GuidingMode::ReSTIR)
    {
        if (causticReservoir.lightIndex < 0)
            return outColor;
        float histogramEmission = luminance(outColor);
        uint currentColor = 0;
        uint originalValue;
        [allow_uav_condition]
        do {
            InterlockedAdd(gGuidingCounter[causticReservoir.lightIndex][causticReservoir.guidingPixels], 0u, currentColor);
            float color = asfloat(currentColor);
            uint updatedColor = asuint(color + histogramEmission);
            InterlockedCompareExchange(gGuidingCounter[causticReservoir.lightIndex][causticReservoir.guidingPixels], currentColor, updatedColor, originalValue);
        } while (originalValue != currentColor);
    }

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
        if (rtxdiValid)
        {
            outColor += mi.eval(sd, dir, sg) * Li;
        }

        outColor += evaluateFinalGatherReservoir(pixel, sg);
        outColor += evaluateCausticReservoir(pixel, sg);
        outColor += gEmission[pixel].xyz;
    }else{
        outColor = gScene.envMap.eval(viewDir);
    }

    gOutColor[pixel] = float4(outColor, 1.0);
}
