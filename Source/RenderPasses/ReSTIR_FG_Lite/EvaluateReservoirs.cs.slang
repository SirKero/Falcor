#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.RaytracingInline;
import Utils.Sampling.SampleGenerator;
import Rendering.RTXDI.RTXDI;
import StructsAndHelpers;

Texture2D<PackedHitInfo> gVBuffer;
StructuredBuffer<ReservoirFG> gFinalGatherReservoir;

RWTexture2D<float4> gOutColor;

cbuffer CB
{
    uint gFrameCount;         // Current it for sample gen
    uint2 gFrameDim;          // Frame Dimensions for camera dir
}

static const bool kUseEnvBackground = USE_ENV_BACKROUND;

float3 evaluateFinalGatherReservoir(uint2 pixel, inout SampleGenerator sg) {
    float3 outColor = float3(0);
    ReservoirFG fgReservoir = gFinalGatherReservoir[index2Dto1D(pixel, gFrameDim.x)];
    if (!fgReservoir.isValid())
        return outColor;

    // Get surface
    HitInfo hitInfo = HitInfo(fgReservoir.sampleSurface);

    let lod = ExplicitLodTextureSampler(0.f);
    uint hints = (uint)MaterialInstanceHints::AdjustShadingNormal;
    ShadingData sd = loadShadingData(hitInfo, -fgReservoir.sampleData.sampleView, lod);
    let mi = gScene.materials.getMaterialInstance(sd, lod, hints);

    outColor = evaluateFinalGatherSample(fgReservoir, sd, mi, sg);
    outColor *= fgReservoir.thp * fgReservoir.wSum;

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
        SampleGenerator sg = SampleGenerator(pixel, gFrameCount * 4 + 3);
        let lod = ExplicitLodTextureSampler(0.f);

        // Get Material properties
        uint hints = (uint)MaterialInstanceHints::AdjustShadingNormal;
        ShadingData sd = loadShadingData(hitInfo, viewDir, lod);
        let mi = gScene.materials.getMaterialInstance(sd, lod, hints);
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

    }else{
        outColor = gScene.envMap.eval(viewDir);
    }

    gOutColor[pixel] += float4(outColor, 1.0);
}
