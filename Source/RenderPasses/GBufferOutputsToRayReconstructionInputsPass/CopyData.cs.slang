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

    //TODO change specular
    /*
    float3 EnvBRDFApprox2(float3 SpecularColor, float alpha, float NoV)
    {
     NoV = abs(NoV);
     // [Ray Tracing Gems, Chapter 32]
     float4 X;
     X.x = 1.f;
     X.y = NoV;
     X.z = NoV * NoV;
     X.w = NoV * X.z;
     float4 Y;
     Y.x = 1.f;
     Y.y = alpha;
     Y.z = alpha * alpha;
     Y.w = alpha * Y.z;
     float2x2 M1 = float2x2(0.99044f, -1.28514f, 1.29678f, -0.755907f);
     float3x3 M2 = float3x3(1.f, 2.92338f, 59.4188f, 20.3225f, -27.0302f,
    222.592f, 121.563f, 626.13f, 316.627f);
     float2x2 M3 = float2x2(0.0365463f, 3.32707, 9.0632f, -9.04756);
     float3x3 M4 = float3x3(1.f, 3.59685f, -1.36772f, 9.04401f, -16.3174f,
    9.22949f, 5.56589f, 19.7886f, -20.2123f);
     float bias = dot(mul(M1, X.xy), Y.xy) * rcp(dot(mul(M2, X.xyw), Y.xyw));
     float scale = dot(mul(M3, X.xy), Y.xy) * rcp(dot(mul(M4, X.xzw), Y.xyw));
     // This is a hack for specular reflectance of 0
     bias *= saturate(SpecularColor.g * 50);
     return mad(SpecularColor, max(0, scale), max(0, bias));
    }
    outSpecularAlbedo = EnvBRDFApprox2( GBuffer.SpecularAlbedo, GBuffer.fRoughness
    * GBuffer.fRoughness, NdotV );
    */

}
