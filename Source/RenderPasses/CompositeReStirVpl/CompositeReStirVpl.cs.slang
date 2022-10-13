/** Composite Pass that blends the ReStirVpl passes together
*/

cbuffer CB
{
    uint2 frameDim;
    float scaleReStir;
    float scaleReStirVpl;
    float scaleThroughput;
    uint _pad;
};

//Inputs
Texture2D<float4> gInReStir;
Texture2D<float4> gInReStirVpl;
Texture2D<float4> gInThroughput;

//Output
RWTexture2D<float4> gOutput;

[numthreads(16, 16, 1)]
void main(uint2 dTid : SV_DispatchThreadID)
{
    if (any(dTid >= frameDim))
        return;

    float3 reStir = scaleReStir * gInReStir[dTid].xyz;
    float3 reStirVpl = scaleReStirVpl * gInReStirVpl[dTid].xyz;
    float3 thp = scaleThroughput * gInThroughput[dTid].xyz;
    gOutput[dTid] = float4((reStir + reStirVpl) * thp,1.f);
    
}
