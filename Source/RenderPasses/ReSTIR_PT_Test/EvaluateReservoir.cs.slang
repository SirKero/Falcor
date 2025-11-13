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

cbuffer CB
{
    uint gFrameCount;           // Current it for sample gen
    uint2 gFrameDim;            // Frame Dimensions for camera dir
}

static const bool kUseEnvBackground = USE_ENV_BACKROUND;
static const uint kMIHints = (uint)MaterialInstanceHints::AdjustShadingNormal;

[numthreads(16, 16, 1)]
void main(uint2 pixel: SV_DispatchThreadID)
{
    if (any(pixel >= gFrameDim))
        return;

    HitInfo hitInfo = HitInfo(gVBuffer[pixel]);
    float3 viewDir = -gView[pixel].xyz;

    float3 outColor = float3(0);
    if (hitInfo.isValid()) {
        SampleGenerator sg = SampleGenerator(pixel, gFrameCount * 5 + 4);
        let lod = ExplicitLodTextureSampler(0.f);

        // Get Material properties
        ShadingData sd = loadShadingData(hitInfo, viewDir, lod);
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
        outColor += ptReservoir.wSum * ptReservoir.sampleRadiance;

    } else {
        outColor = gScene.envMap.eval(viewDir);
    }

    gOutColor[pixel] = float4(outColor, 1.0);
}
