#ifndef COUNT_LIGHTS
#define COUNT_LIGHTS 1
#endif

Texture2D<float> gSrc;
RWTexture2D<float> gDst;

cbuffer CB {
    uint2 gDispatchDim;
    uint gDistributedPhotons;
    bool gIsLightIdxPass;

    uint gGuidingTextureRes;
    uint gLightIdxRes;
    uint gMinPhotonsPerLight; // Guranteed less than kMinPhotonsNeededForLightGuiding
}

static const uint kMinPhotonsNeededForLightGuiding = LIGHT_GUIDING_MIN_PHOTONS;

[numthreads(16, 16, 1)]
void main(uint3 thdID: SV_DispatchThreadID)
{
    const uint2 pixel = thdID.xy;
    if (any(pixel > gDispatchDim))
        return;

    float numberPhotons = 0;
    if (gIsLightIdxPass) {
        const uint lightIndex = pixel.x + pixel.y * gLightIdxRes;
        if (lightIndex >= COUNT_LIGHTS)
            numberPhotons = 0;
        else
            numberPhotons += floor(gDst[pixel] * gDistributedPhotons) + gMinPhotonsPerLight;
    }
    else {
        const uint2 lightIndexPixel = pixel / gGuidingTextureRes; // Pixel in light index texture
        const uint lightIndex = lightIndexPixel.x + lightIndexPixel.y * gLightIdxRes;
        if (lightIndex >= COUNT_LIGHTS)
            numberPhotons = 0;
        else {
            float photonsPerLight = gSrc[lightIndexPixel];
            if (photonsPerLight > kMinPhotonsNeededForLightGuiding)
            {
                photonsPerLight -= kMinPhotonsNeededForLightGuiding;
                float percentPhotons = gDst[pixel];
                numberPhotons += floor(percentPhotons * photonsPerLight) + 1;
            } else if (photonsPerLight == kMinPhotonsNeededForLightGuiding) {
                numberPhotons = 1;
            }
        }
    }

    gDst[pixel] = numberPhotons;
}
