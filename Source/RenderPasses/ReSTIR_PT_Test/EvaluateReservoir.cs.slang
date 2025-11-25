#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.RaytracingInline;
import Utils.Sampling.SampleGenerator;
import Utils.Color.ColorHelpers;
import Rendering.RTXDI.RTXDI;
import SharedStructsAndFunctions;

Texture2D<PackedHitInfo> gVBuffer;
Texture2D<float4> gView;
StructuredBuffer<ReservoirPT> gReservoir;

RWTexture2D<float4> gOutColor;
RWTexture2D<PackedHitInfo> gVBufferPrev;
RWTexture2D<float4> gViewPrev;

cbuffer CB
{
    uint gFrameCount;           // Current it for sample gen
    uint2 gFrameDim;            // Frame Dimensions for camera dir
}

static const bool kUseEnvBackground = USE_ENV_BACKROUND;
static const uint kMIHints = (uint)MaterialInstanceHints::AdjustShadingNormal;
static const uint kRNGNumPasses = RNG_NUM_PASSES;

[numthreads(16, 16, 1)]
void main(uint2 pixel: SV_DispatchThreadID)
{
    if (any(pixel >= gFrameDim))
        return;

    PackedHitInfo packedHit = gVBuffer[pixel];
    HitInfo hitInfo = HitInfo(packedHit);
    float3 viewDir = gView[pixel].xyz;

    // Copy VBuffer and View data
    gVBufferPrev[pixel] = packedHit;
    gViewPrev[pixel] = float4(viewDir, 1.0);

    float3 outColor = float3(0);
    if (hitInfo.isValid()) {
        SampleGenerator sg = SampleGenerator(pixel, gFrameCount * kRNGNumPasses + (kRNGNumPasses - 1));
        let lod = ExplicitLodTextureSampler(0.f);

        // Get Material properties
        ShadingData sd = loadShadingData(hitInfo, -viewDir, lod);
        let mi = gScene.materials.getMaterialInstance(sd, lod, kMIHints);
        let bsdfProperties = mi.getProperties(sd);

        // Add Emissive
        outColor += bsdfProperties.emission;

        // Eval ReSTIR DI
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

        ReservoirPT ptReservoir = gReservoir[index2Dto1D(pixel, gFrameDim.x)];
        outColor += ptReservoir.weight * ptReservoir.F;

    } else {
        outColor = gScene.envMap.eval(viewDir);
    }

    gOutColor[pixel] = float4(outColor, 1.0);
}
