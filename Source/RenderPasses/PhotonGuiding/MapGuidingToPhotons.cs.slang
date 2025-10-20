#ifndef COUNT_LIGHTS
#define COUNT_LIGHTS 1
#endif

Texture2D<float> gSrc;
RWTexture2D<float> gDst;

cbuffer CB {
    uint2 gDispatchDim;
    uint gDistributedPhotons;
    bool gIsLightIdxPass;

    uint gFixedPhotonsPerPixel;
    uint gGuidingTextureRes;
    uint gLightIdxRes;
}

/* Reduce using a Mip-Chain. Calculates the Total Importance for the Importance Map.
   gSrc is the lower Mip, gDst is one Mip higher.
   The dispatch dimensions are derived from gDst. 
*/

[numthreads(16, 16, 1)]
void main(uint3 thdID: SV_DispatchThreadID)
{
    const uint2 pixel = thdID.xy;
    if (any(pixel > gDispatchDim))
        return;

    float numberPhotons = gFixedPhotonsPerPixel;
    if (gIsLightIdxPass) {
        const uint lightIndex = pixel.x + pixel.y * gLightIdxRes;
        if (lightIndex >= COUNT_LIGHTS)
            numberPhotons = 0;
        else
            numberPhotons += floor(gDst[pixel] * gDistributedPhotons);
    }
    else {
        const uint2 lightIndexPixel = pixel / gGuidingTextureRes; // Pixel in light index texture
        const uint lightIndex = lightIndexPixel.x + lightIndexPixel.y * gLightIdxRes;
        if (lightIndex >= COUNT_LIGHTS)
            numberPhotons = 0;
        else {
            float photonsPerLight = gSrc[lightIndexPixel];
            numberPhotons += floor(gDst[pixel] * photonsPerLight);
        }
    }

    gDst[pixel] = numberPhotons;
}
