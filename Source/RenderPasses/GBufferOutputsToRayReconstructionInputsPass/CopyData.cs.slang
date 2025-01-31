// Inputs
Texture2D<float4> gDiffuseOpacity;
Texture2D<float4> gSpecRoughness; // Optional
Texture2D<float2> gInLinearZ;

// Outputs
RWTexture2D<float4> gOutDiffuse;
RWTexture2D<float4> gOutSpecular;
RWTexture2D<float> gOutLinearZ;
RWTexture2D<float> gOutRoughness;

cbuffer CB {
    float gCameraNear;
    float gCameraFar;
}

[numthreads(16, 16, 1)]
void main(uint2 pixel: SV_DispatchThreadID)
{
    //Read
    float4 inDiffuseOpacity = gDiffuseOpacity[pixel];
    float4 inSpecRoughness = gSpecRoughness[pixel];
    float2 inLinZ = gInLinearZ[pixel];

    // Write
    gOutDiffuse[pixel] = float4(inDiffuseOpacity.xyz, 1.0);
    gOutSpecular[pixel] = float4(inSpecRoughness.xyz, 1.0);
    gOutLinearZ[pixel] = (inLinZ.x-gCameraNear)/(gCameraFar-gCameraNear); //Add toggle
    gOutRoughness[pixel] = inSpecRoughness.w;
}
