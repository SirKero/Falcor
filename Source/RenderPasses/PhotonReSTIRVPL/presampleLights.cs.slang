import Scene.Scene;
import Utils.Color.ColorHelpers;
import Utils.Sampling.SampleGenerator;

import VPLs;

Texture2D<float> gLightPdf;
RWStructuredBuffer<uint2> gPresampledLights;

cbuffer PerFrame
{
    uint gFrameCount;                   //Current it for sample gen
}

cbuffer Constant{
    uint2 gPdfTexSize;                
    uint2 gTileSizes;                   //ThreadDims
}

void samplePdfMip(inout SampleGenerator sg, out uint2 position, out float pdf){
    int lastMipLevel = max(0, int(floor(log2(max(gPdfTexSize.x, gPdfTexSize.y)))) - 1);
    position = uint2(0);
    pdf = 1.f;
    for(int mipLevel = lastMipLevel; mipLevel >= 0; mipLevel--){
        position *= 2;

        float4 samples;
        samples.x = max(0.f, gLightPdf.Load(int3(position.x + 0, position.y + 0, mipLevel)).x);
        samples.y = max(0.f, gLightPdf.Load(int3(position.x + 0, position.y + 1, mipLevel)).x);
        samples.z = max(0.f, gLightPdf.Load(int3(position.x + 1, position.y + 0, mipLevel)).x);
        samples.w = max(0.f, gLightPdf.Load(int3(position.x + 1, position.y + 1, mipLevel)).x);

        float weightSum = samples.x + samples.y + samples.z + samples.w;
        //Return if invalid
        if (weightSum <= 0){
            pdf = 0;
            return;
        }
        samples /= weightSum; //Normalize Samples

        float rnd = sampleNext1D(sg);

        //Choose one of 4 samples
        if(rnd < samples.x){
            pdf *= samples.x;
        }else{
            rnd -= samples.x;
            if(rnd < samples.y){
                position += uint2(0, 1);
                pdf *= samples.y;
            }else{
                rnd -= samples.y;
                if(rnd < samples.z){
                    pdf *= samples.z;
                    position += uint2(1, 0);
                }else{
                    pdf *= samples.w;
                    position += uint2(1, 1);
                }
            }
        }
    }
}

[numthreads(16, 16, 1)]
void main(uint2 dTid : SV_DispatchThreadID)
{
    SampleGenerator sg = SampleGenerator(dTid, gFrameCount + 2 * 13);
    uint2 texPos;
    float pdf;
    samplePdfMip(sg,texPos,pdf);

    uint lightIndex = ReSTIR_ZCurveToLinearIndex(texPos);

    uint preLightIdx = dTid.x + dTid.y * gTileSizes.x;
    float invSourcePdf = 0;
    if(pdf > 0){
        invSourcePdf = 1.f / pdf;    
    }

    gPresampledLights[preLightIdx] = uint2(lightIndex, asuint(invSourcePdf));
}
