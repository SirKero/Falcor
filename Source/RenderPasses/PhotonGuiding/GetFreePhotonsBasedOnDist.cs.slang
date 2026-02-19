#include "Scene/SceneDefines.slangh"
import Scene.RaytracingInline;
import StructsAndHelpers;

#ifndef COUNT_LIGHTS
#define COUNT_LIGHTS 1
#endif

cbuffer CB {
    float gMinDist;
    float gMaxDist;
    uint gMinPhotons;
    uint gMaxPhotons;

    uint gLightGMSize;
}

RWTexture2D<uint> gReservedPhotonsPerLight;
RWStructuredBuffer<uint> gReservedPhotons;

[numthreads(16, 16, 1)]
void main(uint3 thdID: SV_DispatchThreadID)
{
    const uint2 pixel = thdID.xy;
    if (any(pixel > gLightGMSize))
        return;

    uint lightIdx = pixel.x + pixel.y * gLightGMSize;

    //Early Out
    if (lightIdx >= COUNT_LIGHTS)
        return;

    float3 lightPosW = getLightPosition(lightIdx);
    float distanceToCam = distance(gScene.camera.getPosition(), lightPosW);

    uint photonsPerLight = gMinPhotons;
    if (distanceToCam < gMaxDist)
    {
        float w = clamp((distanceToCam - gMinDist) / (gMaxDist - gMinDist), 0.0, 1.0);
        photonsPerLight = uint(lerp(float(gMaxPhotons), float(gMinPhotons), w));
    }

    gReservedPhotonsPerLight[pixel] = photonsPerLight;
    uint tmp = 0;
    InterlockedAdd(gReservedPhotons[0], photonsPerLight, tmp);
}
