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

static const float kRayEpsilon = 0.98f;
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
    let bsdfProperties = mi.getProperties(sd);

    float3 toSurface = sd.posW - fgReservoir.sampleData.posW;
    float distance = length(toSurface);
    toSurface /= distance;
    float jacobianDeterminant = dot(fgReservoir.sampleData.normal, toSurface) / (distance * distance);
    jacobianDeterminant /= fgReservoir.jacobianDeterminant;
    outColor = fgReservoir.sampleData.radianceOut * fgReservoir.thp * jacobianDeterminant;
    outColor *= fgReservoir.wSum;
    outColor *= mi.eval(sd, -toSurface, sg);

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
        float distance = 1.f;
        float3 dir = {};
        float3 Li = {};
        bool rtxdiValid = gRTXDI.getFinalSample(pixel, dir, distance, Li);
        
        if (rtxdiValid)
        {
            // Create a DXR 1.1 query object to trace a ray (the <1> means use alpha testing)
            SceneRayQuery<1> rayQuery;
            const Ray ray = Ray(sd.computeNewRayOrigin(), dir, 0.f, distance * kRayEpsilon);
            if (!rayQuery.traceVisibilityRay(ray, RAY_FLAG_NONE, 0xff))
                rtxdiValid = false;
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
