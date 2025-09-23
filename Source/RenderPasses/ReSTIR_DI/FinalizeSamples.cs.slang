#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.RaytracingInline;
import Utils.Sampling.SampleGenerator;
import Utils.Color.ColorHelpers;
import Utils.Math.MathHelpers;
import Rendering.Lights.EmissiveLightSampler;
import Rendering.Lights.EmissiveLightSamplerHelpers;
import StructsAndHelpers;

Texture2D<PackedHitInfo> gVBuffer;
Texture2D<float4> gView;
StructuredBuffer<Reservoir> gReservoir;

RWTexture2D<float4> gColorOut;

cbuffer CB
{
    uint gFrameCount; // Frame count since scene was loaded.
    uint2 gFrameDims;
}

cbuffer Light {
    EmissiveLightSampler gEmissiveSampler;
}

static const bool kUseEnvBackground = USE_ENV_BACKROUND;
static const uint kMIHints = (uint)MaterialInstanceHints::AdjustShadingNormal;
static const float3 kDefaultBackgroundColor = float3(0);

[numthreads(16, 16, 1)]
void main(uint2 pixel: SV_DispatchThreadID)
{
    if (any(pixel >= gFrameDims))
        return;

    HitInfo hitInfo = HitInfo(gVBuffer[pixel]);
    float3 viewDir = -gView[pixel].xyz;

    float3 outColor = float3(0);
    if (hitInfo.isValid())
    {
        SampleGenerator sg = SampleGenerator(pixel, gFrameCount * 5 + 4);
        // Get Material properties
        let lod = ExplicitLodTextureSampler(0.f);
        ShadingData sd = loadShadingData(hitInfo, viewDir, lod);
        let mi = gScene.materials.getMaterialInstance(sd, lod, kMIHints);
        let bsdfProperties = mi.getProperties(sd);

        outColor += bsdfProperties.emission; // Add emissive
        outColor += bsdfProperties.diffuseReflectionAlbedo *  0.01; // Add Ambient

        // Load Reservoir
        Reservoir reservoir = gReservoir[index2Dto1D(pixel, gFrameDims.x)];
        if (reservoir.valid()) {
            float3 Le = reservoir.emission;
            float3 triPosW = reservoir.hitPos;
            float3 toLight = triPosW - sd.posW;
            float dist = length(toLight);
            toLight /= dist;

            outColor += Le * mi.eval(sd, toLight, sg) * reservoir.wSum;
        }
    } else {
        outColor += kUseEnvBackground ? gScene.envMap.eval(viewDir) : kDefaultBackgroundColor;
    }

    gColorOut[pixel] = float4(outColor, 1.0);
}
