#include "Scene/SceneDefines.slangh"
import Scene.RaytracingInline;

#ifndef LIGHT_COUNT
#define LIGHT_COUNT 1
#endif

cbuffer CB {
    float gMinDist;
    float gMaxDist;
    uint gMinPhotons;
    uint gMaxPhotons;

    uint gLightGMSize;
}

RWTexture2D<uint> gReservedPhotonsPerLight;
RWStructuredBuffer<uint> gResourceCounter;

static const uint kCounterIndex = 1;
static const uint kAnalyticLightIdxOffset = ANALYTIC_START_INDEX;

//Fetches light position from guiding structure
float3 getLightPosition(uint lightIndex)
{
    bool isAnalytic = lightIndex >= kAnalyticLightIdxOffset;
    float3 posW = float3(0);
    if (isAnalytic)
    {
        const uint analyticLightIndex = lightIndex - kAnalyticLightIdxOffset;
        LightData lightData = gScene.getLight(analyticLightIndex);
        posW = lightData.posW;
    } else
    {
        const EmissiveTriangle tri = gScene.lightCollection.getTriangle(lightIndex);
        posW = tri.getPosition(float3(1.0 / 3.0));
    }

    return posW;
}

[numthreads(16, 16, 1)]
void main(uint3 thdID: SV_DispatchThreadID)
{
    const uint2 pixel = thdID.xy;
    if (any(pixel > gLightGMSize))
        return;

    uint lightIdx = pixel.x + pixel.y * gLightGMSize;

    // Early Out
    if (lightIdx >= LIGHT_COUNT)
        return;

    //Get position of light and calculate distance to camera
    float3 lightPosW = getLightPosition(lightIdx);
    float distanceToCam = distance(gScene.camera.getPosition(), lightPosW);

    //Determine photons for cell with linear interpolation
    uint photonsPerLight = gMinPhotons;
    if (distanceToCam < gMaxDist)
    {
        float w = clamp((distanceToCam - gMinDist) / (gMaxDist - gMinDist), 0.0, 1.0);
        photonsPerLight = uint(lerp(float(gMaxPhotons), float(gMinPhotons), w));
    }

    //Write
    gReservedPhotonsPerLight[pixel] = photonsPerLight;
    uint tmp = 0;
    InterlockedAdd(gResourceCounter[kCounterIndex], photonsPerLight, tmp);
}
