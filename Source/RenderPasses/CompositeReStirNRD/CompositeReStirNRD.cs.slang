/** Composite Pass that blends the ReStirVpl passes together
*/

cbuffer CB
{
    uint2 frameDim;
    bool gEnableReStir;
    bool gEnablePhotonReStir;
    bool gEnableThroughput;
};

//Inputs
Texture2D<float4> gPhotonReStirDiffuse;
Texture2D<float4> gPhotonReStirSpecular;
Texture2D<float4> gReStirDiffuse;
Texture2D<float4> gReStirSpecular;
Texture2D<float4> gThp;
Texture2D<uint> gNRDMask;

//Output
RWTexture2D<float4> gNRDDiffuseRadianceHitDistance;
RWTexture2D<float4> gNRDSpecularRadianceHitDistance;
RWTexture2D<float4> gNRDDeltaReflectionRadianceHitDistance;
RWTexture2D<float4> gNRDDeltaTransmissionRadianceHitDistance;

[numthreads(16, 16, 1)]
void main(uint2 dTid : SV_DispatchThreadID)
{
    if (any(dTid >= frameDim))
        return;

    float3 thp = float(1.f);
    if(gEnableThroughput)
        thp = gThp[dTid].xyz;
       
    float4 diffuse = float4(0);
    if (gEnablePhotonReStir)
        diffuse += gPhotonReStirDiffuse[dTid];
    if (gEnableReStir)
    {
        float4 reStir = gReStirDiffuse[dTid];
        diffuse.xyz += reStir.xyz;
        diffuse.w = max(diffuse.w, reStir.w); //Use ReStir hitDistance for now
    }
    diffuse.xyz *= thp;

    //Guard agains invalid 
    if (any(isnan(diffuse) | any(isinf(diffuse))))
        diffuse = float4(0);
    
    float4 specular = float4(0);
    if (gEnablePhotonReStir)
        specular += gPhotonReStirSpecular[dTid];
    if (gEnableReStir)
    {
        float4 reStir = gReStirSpecular[dTid];
        specular.xyz += reStir.xyz;
        specular.w = max(specular.w, reStir.w); //Use ReStir hitDistance for now
    }
    specular.xyz *= thp;

    //Guard agains invalid 
    if (any(isnan(specular) | any(isinf(specular))))
        specular = float4(0);
    
    uint mask = gNRDMask[dTid];

    if ((mask & 0x04) > 0)
    {
        specular = diffuse;
    }
        
    
    gNRDDiffuseRadianceHitDistance[dTid] = mask == 0 || ((mask & 0x04) > 0) ? diffuse: float4(0);
    gNRDSpecularRadianceHitDistance[dTid] = mask == 0 || ((mask & 0x04) > 0) ? specular : float4(0);

    

    float4 added = float4(diffuse.xyz, diffuse.w);  //NRD can only filter diffuse for reflections and transmissions
    if (mask & 0x01)    //Transmission
    {
        gNRDDeltaTransmissionRadianceHitDistance[dTid] = added;
        gNRDDeltaReflectionRadianceHitDistance[dTid] = float4(0);
    }
    else if (mask & 0x02)   //Delta Reflection
    {
        gNRDDeltaReflectionRadianceHitDistance[dTid] = added;
        gNRDDeltaTransmissionRadianceHitDistance[dTid] = float4(0);
    }
    else //No problems
    {
        gNRDDeltaReflectionRadianceHitDistance[dTid] = float4(0);
        gNRDDeltaTransmissionRadianceHitDistance[dTid] = float4(0);

    }
}
