/** Composite Pass that blends the ReStirVpl passes together
*/

cbuffer CB
{   
    uint2 gFrameDim;            //Frame Res
    float2 gInvFrameDim; //1.f/Res
    uint gTemporalFilterLength; //0 -> Disabled; (0<) -> Filter Length
    uint gBlurMode;             //0 -> Disable; 1 -> Blur2x2; 2 -> Blur3x3; 3 -> Blur5x5
    uint2 _pad;
   
};

#define is_valid(name) (is_valid_##name != 0)

//Inputs
Texture2D<float4> gAin;
Texture2D<float4> gBin;
Texture2D<float2> gMvecA;
Texture2D<float2> gMvecB;

//Internal
SamplerState gLinearSampler;
RWTexture2D<float4> gTempA;
RWTexture2D<float4> gTempB;

//Outputs
RWTexture2D<float4> gAout;
RWTexture2D<float4> gBout;


//2x2 Blur from SimplePostFX pass
float4 blurFilter2x2(Texture2D<float4> src, const float2 uv, float uscale, float vscale)
{
    // 2x2 bilinear-tap kernel, effective footprint 4x4, with offsets chosen to sample from the binomial 1 3 3 1
    uscale *= 0.75f;
    vscale *= 0.75f;
    return 0.25f * (
        src.SampleLevel(gLinearSampler, uv + float2(-uscale, -vscale), 0.f) + src.SampleLevel(gLinearSampler, uv + float2(uscale, -vscale), 0.f) +
        src.SampleLevel(gLinearSampler, uv + float2(-uscale, vscale), 0.f) + src.SampleLevel(gLinearSampler, uv + float2(uscale, vscale), 0.f));
}

//3x3 Blur from SimplePostFX pass
float4 blurFilter3x3(Texture2D<float4> src, const float2 uv, const float uscale, const float vscale)
{
    // 3x3 bilinear-tap kernel, effective footprint 6x6, with offsets chosen to sample from the binomial 1 5 10 10 5 1
    const float w0 = (10.f + 10.f) / 32.f;
    const float x1 = 1.5f + 1.f / (1.f + 5.f), w1 = (1.f + 5.f) / 32.f;
    const float x1u = x1 * uscale;
    const float x1v = x1 * vscale;
    return
        (src.SampleLevel(gLinearSampler, uv + float2(-x1u, -x1v), 0.f) + src.SampleLevel(gLinearSampler, uv + float2(x1u, -x1v), 0.f) + src.SampleLevel(gLinearSampler, uv + float2(-x1u, x1v), 0.f) + src.SampleLevel(gLinearSampler, uv + float2(x1u, x1v), 0.f)) * (w1 * w1) +
        (src.SampleLevel(gLinearSampler, uv + float2(0.f, -x1v), 0.f) + src.SampleLevel(gLinearSampler, uv + float2(0.f, x1v), 0.f) + src.SampleLevel(gLinearSampler, uv + float2(-x1u, 0.f), 0.f) + src.SampleLevel(gLinearSampler, uv + float2(x1u, 0.f), 0.f)) * (w1 * w0) +
        (src.SampleLevel(gLinearSampler, uv + float2(0.f, 0.f), 0.f)) * (w0 * w0);
}

//2x2 Blur from SimplePostFX pass
float4 blurFilter5x5(Texture2D<float4> src, const float2 uv, const float uscale, const float vscale)
{
    // 5x5 bilinear-tap kernel, effective footprint 10x10, with offsets chosen to sample from the binomial 1 9 36 84 126 126 84 32 9 1
    const float w0 = (126.f + 126.f) / 512.f;
    const float x1 = 1.5f + 36.f / (36.f + 84.f), w1 = (36.f + 84.f) / 512.f;
    const float x2 = 3.5f + 1.f / (1.f + 9.f), w2 = (1.f + 10.f) / 512.f;
    const float x1u = x1 * uscale, x2u = x2 * uscale;
    const float x1v = x1 * vscale, x2v = x2 * vscale;
    float4 s0 =
        (src.SampleLevel(gLinearSampler, uv + float2(-x2u, -x2v), 0.f) + src.SampleLevel(gLinearSampler, uv + float2(x2u, -x2v), 0.f) + src.SampleLevel(gLinearSampler, uv + float2(-x2u, x2v), 0.f) + src.SampleLevel(gLinearSampler, uv + float2(x2u, x2v), 0.f)) * (w2 * w2) +
        (src.SampleLevel(gLinearSampler, uv + float2(-x1u, -x2v), 0.f) + src.SampleLevel(gLinearSampler, uv + float2(x1u, -x2v), 0.f) + src.SampleLevel(gLinearSampler, uv + float2(-x1u, x2v), 0.f) + src.SampleLevel(gLinearSampler, uv + float2(x1u, x2v), 0.f)) * (w1 * w2) +
        (src.SampleLevel(gLinearSampler, uv + float2(0.f, -x2v), 0.f) + src.SampleLevel(gLinearSampler, uv + float2(0.f, x2v), 0.f)) * (w0 * w2);
    float4 s1 =
        (src.SampleLevel(gLinearSampler, uv + float2(-x2u, -x1v), 0.f) + src.SampleLevel(gLinearSampler, uv + float2(x2u, -x1v), 0.f) + src.SampleLevel(gLinearSampler, uv + float2(-x2u, x1v), 0.f) + src.SampleLevel(gLinearSampler, uv + float2(x2u, x1v), 0.f)) * (w2 * w1) +
        (src.SampleLevel(gLinearSampler, uv + float2(-x1u, -x1v), 0.f) + src.SampleLevel(gLinearSampler, uv + float2(x1u, -x1v), 0.f) + src.SampleLevel(gLinearSampler, uv + float2(-x1u, x1v), 0.f) + src.SampleLevel(gLinearSampler, uv + float2(x1u, x1v), 0.f)) * (w1 * w1) +
        (src.SampleLevel(gLinearSampler, uv + float2(0.f, -x1v), 0.f) + src.SampleLevel(gLinearSampler, uv + float2(0.f, x1v), 0.f)) * (w0 * w1);
    float4 s2 =
        (src.SampleLevel(gLinearSampler, uv + float2(-x2u, 0.f), 0.f) + src.SampleLevel(gLinearSampler, uv + float2(x2u, 0.f), 0.f)) * (w2 * w0) +
        (src.SampleLevel(gLinearSampler, uv + float2(-x1u, 0.f), 0.f) + src.SampleLevel(gLinearSampler, uv + float2(x1u, 0.f), 0.f)) * (w1 * w0) +
        (src.SampleLevel(gLinearSampler, uv + float2(0.f, 0.f), 0.f)) * (w0 * w0);
    return s0 + s1 + s2;
}

[numthreads(16, 16, 1)]
void mainTemporal(uint2 dTid : SV_DispatchThreadID)
{
    if (any(dTid >= gFrameDim))
        return;

    float4 colorImgA = float4(gAin[dTid].xyz, 1.f);
    float4 colorImgB = float4(gBin[dTid].xyz, 1.f);
    
    //Temporal Filter
    if (gTemporalFilterLength > 0)
    {
        //Input A
        float2 motionOffset = gMvecA[dTid] * float2(gFrameDim);
        float2 prevIdxF = motionOffset + float2(dTid);
        if (prevIdxF.x > 0 && prevIdxF.y > 0 && prevIdxF.x < gFrameDim.x && prevIdxF.y < gFrameDim.y)
        {
            uint2 tempIndex = uint2(round(prevIdxF));
            
            float4 prev = gTempA[tempIndex];
            uint history = min(gTemporalFilterLength, uint(round(prev.w + 0.1)) + 1); //History of this frame
            prev.xyz *= (history - 1);
            colorImgA.xyz += prev.xyz;
            colorImgA.xyz /= history;
            colorImgA.w = float(history);
        }
        //Input B
        if (is_valid(gBin))
        {
            //if (is_valid(gMvecB))
                motionOffset = gMvecB[dTid] * float2(gFrameDim);
            prevIdxF = motionOffset + float2(dTid);
            if (prevIdxF.x > 0 && prevIdxF.y > 0 && prevIdxF.x < gFrameDim.x && prevIdxF.y < gFrameDim.y)
            {
                uint2 tempIndex = uint2(round(prevIdxF));
            //Input B
                float4 prev = gTempB[tempIndex];
                uint history = min(gTemporalFilterLength, uint(round(prev.w + 0.1)) + 1); //History of this frame
                prev.xyz *= (history - 1);
                colorImgB.xyz += prev.xyz;
                colorImgB.xyz /= history;
                colorImgB.w = float(history);
            }
        }
        
        
        //Store Temporal Filter
        gTempA[dTid] = colorImgA;
        if (is_valid(gBin)) gTempB[dTid] = colorImgB;
    }
        
    //Blur (Not Temporally Filtered
    if (gBlurMode == 0)
    {
        gAout[dTid] = float4(colorImgA.xyz, 0);
        if (is_valid(gBin)) gBout[dTid] = float4(colorImgB.xyz, 0);
    }
}

[numthreads(16, 16, 1)]
void mainBlur(uint2 dTid : SV_DispatchThreadID)
{
    if (any(dTid >= gFrameDim))
        return;

    float4 colorImgA = { };
    float4 colorImgB = { };
    float2 uv = (dTid + 0.5f) * gInvFrameDim;

    //Do blur
    switch (gBlurMode)
    {
        case 1:
            colorImgA = blurFilter2x2(gAin, uv, gInvFrameDim.x, gInvFrameDim.y);
            break;
        case 2:
            colorImgA = blurFilter3x3(gAin, uv, gInvFrameDim.x, gInvFrameDim.y);
            break;
        case 3:
            colorImgA = blurFilter5x5(gAin, uv, gInvFrameDim.x, gInvFrameDim.y);
    }

    if (true)
    {
        switch (gBlurMode)
        {
            case 1:
                colorImgB = blurFilter2x2(gBin, uv, gInvFrameDim.x, gInvFrameDim.y);
                break;
            case 2:
                colorImgB = blurFilter3x3(gBin, uv, gInvFrameDim.x, gInvFrameDim.y);
                break;
            case 3:
                colorImgB = blurFilter5x5(gBin, uv, gInvFrameDim.x, gInvFrameDim.y);
        }
    }
    
    //Write out
    gAout[dTid] = colorImgA;
    if (true) gBout[dTid] = colorImgB;
}

