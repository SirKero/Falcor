#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Utils.Math.PackedFormats;
import Utils.Math.FormatConversion;

import Scene.RaytracingInline;
import Scene.Material.ShadingUtils;
import Rendering.Materials.Microfacet;
import Rendering.Materials.Fresnel;
import Utils.Sampling.SampleGenerator;
import Utils.Math.MathHelpers;
import Utils.Color.ColorHelpers;

import Rendering.Lights.EmissiveLightSampler;
import Rendering.Lights.EmissiveLightSamplerHelpers;
import Reservoir;
import SurfaceData;
import VPLs;

Texture2D<uint4> gReservoir;
RWTexture2D<uint4> gReservoirWrite;

StructuredBuffer<PackedVPL> gVpls;
RWStructuredBuffer<PackedVPL> gVplsWrite;
StructuredBuffer<PackedSurfaceData>gSurface;
Texture2D<float2> gMVec;
Texture2D<float4> gView;
Texture2D <float> gNeighborMask;

#define BIAS_MODE_BASIC 1
#define BIAS_MODE_RAYTRACE 2
//This is for syntax highlightig
#ifndef BIAS_CORRECTION_MODE
    #define BIAS_CORRECTION_MODE 2
#endif

//Define for valid texture channels
#define is_valid(name) (is_valid_##name != 0)

cbuffer PerFrame
{
    uint gFrameCount;                   //Current it for sample gen
}

cbuffer Constant
{
    uint2 gFrameDim;                //Frame Dimensions for camera dir
    uint gSpartialSamples;
    float gSamplingRadius;
    float gDepthThreshold;          //Relative depth offset
    float gNormalThreshold;         //Maximum cosine between both Normals that is allowed
    float gVplRadius;               //Vpl radius
    uint gMaskMipLevel;
}

struct LightSample{
    float3 dir;
    float Li;
};

struct PhotonLight{
    float4 pos;
    float4 flux;
};

static const float kRayEpsilon = 0.99f;

uint index2Dto1D(uint2 idx, uint width){
    return idx.x + width * idx.y;
}

Surface getSurface(uint2 idx)
{
    float3 viewDir;
    if (is_valid(gView))
    {
        viewDir = gView[idx].xyz;
    }
    else
    {
        viewDir = gScene.camera.computeRayPinhole(idx, gFrameDim).dir * -1; //Flip ViewDir here 
    }
    PackedSurfaceData surfaceData = gSurface[index2Dto1D(idx, gFrameDim.x)];
    
    return Surface(surfaceData, viewDir);
}

bool isValidNeighbor(float3 currNormal, float currLinZ, float3 neighNormal, float neighLinZ){
    float normalCheck = dot(currNormal, neighNormal);
    float minLinZDiff = currLinZ * gDepthThreshold;
    float linZDiff = abs(currLinZ - neighLinZ);
    return ( (normalCheck >= gNormalThreshold) && (linZDiff <= minLinZDiff) );
}

bool getLightSample(in VPL vpl,in float3 worldPos, out LightSample ls, out float sampleDistance){
    //Get light position

    if(any(vpl.flux < 0)) return false;
    
    ls.dir = vpl.posW - worldPos;
    float distSqr= max(FLT_MIN, dot(ls.dir, ls.dir)); // Clamp to avoid NaNs below
    sampleDistance = sqrt(distSqr);
    ls.dir = ls.dir/ sampleDistance;    //normalize
    
    ls.Li = luminance(vpl.flux);

    return ls.Li > 0;   //true if sample is valid
}

//Get a valid neighbor sample
bool sampleMaskMIP(inout SampleGenerator sg, uint2 currentPixel , out int2 position)
{
    int lastMipLevel = max(0, gMaskMipLevel - 1);
    //TODO: calc pos
    float2 dimF = float2(gFrameDim-1);
    float2 relPos = float2(currentPixel.x / dimF.x, currentPixel.y / dimF.y);
    dimF /= 1 << lastMipLevel;  //Convert to Mip level dim (div pow(2,MIPLevel))
    relPos *= dimF;     //Get MIP pixel
    relPos -= float2(0.5f); //Shift top left top pixel
    relPos = clamp(relPos, float2(0), float2(gFrameDim - 1));   //Clamp at edge
    position = uint2(floor(relPos));    //convert to pixel
    
    for (int mipLevel = lastMipLevel; mipLevel >= 0; mipLevel--)
    {
        position *= 2;

        float4 samples;
        samples.x = max(0.f, float(gNeighborMask.Load(int3(position.x + 0, position.y + 0, mipLevel))) );
        samples.y = max(0.f, float(gNeighborMask.Load(int3(position.x + 0, position.y + 1, mipLevel))));
        samples.z = max(0.f, float(gNeighborMask.Load(int3(position.x + 1, position.y + 0, mipLevel))));
        samples.w = max(0.f, float(gNeighborMask.Load(int3(position.x + 1, position.y + 1, mipLevel))));

        float weightSum = samples.x + samples.y + samples.z + samples.w;
        //Return if invalid
        if (weightSum <= 0)
        {
            return false;
        }
        samples /= weightSum; //Normalize Samples

        float rnd = sampleNext1D(sg);

        //Choose one of 4 samples
        if (rnd < samples.x)
        {
            position += int2(0, 0);
        }
        else
        {
            rnd -= samples.x;
            if (rnd < samples.y)
            {
                position += int2(0, 1);
            }
            else
            {
                rnd -= samples.y;
                if (rnd < samples.z)
                {
                    position += int2(1, 0);
                }
                else
                {
                    position += int2(1, 1);
                }
            }
        }
    }
    return true;
}

[numthreads(16, 16, 1)]
void main(uint2 dTid : SV_DispatchThreadID)
{
    SampleGenerator sg = SampleGenerator(dTid, gFrameCount + 4 * 13);
    Reservoir r = Reservoir();

    //Check if surface is valid
    Surface currentSurface = getSurface(dTid);
    if (!currentSurface.valid)
        return;
    
    //Load reservoir from current iteration
    VPL selectedVPL = VPL();
    Reservoir current = Reservoir(gReservoir[dTid]);
    if(current.weightSum > 0){
        selectedVPL = VPL(gVpls[index2Dto1D(dTid, gFrameDim.x)]);
    }
    
    r.combineReservoir(current, current.targetPdf, 0.5 /* random */);
    
    int2 currentIndex = dTid;
    uint numSpartialSamples = min(gSpartialSamples,8); //Cap at 8 samples for the later bias correction TODO: Set max sample as constant
    uint cachedIndices[8]; //Store all indeces. 32 Bits per 2D index (16 per element)
    int selectedSample = -1;  //Index of the selected sample (-1 is the current one)

    //Go through all neighbors
    for(uint i=0 ; i<numSpartialSamples; i++){
        cachedIndices[i] = 0xFFFFFFFF;  //Set to max int
        //Get random sample from sampling mask
        //float2 randSamp = (sampleNext2D(sg) * 2) - 1.f; //random sample in [-1,1]
        //int2 spartialOffset = int2(round(randSamp * gSamplingRadius));
        //int2 idx = currentIndex + spartialOffset;
        int2 idx;
        if (!sampleMaskMIP(sg, currentIndex, idx))
            continue;
        
        //Check if index is valid
        if(idx.x < 0 && idx.y < 0 && idx.x >= gFrameDim.x && idx.y >= gFrameDim.y)
            continue;

        //Get surface and check if valid
        Surface neighSurface = getSurface(idx);
        if (!neighSurface.valid)
            continue;
        
        if(!isValidNeighbor(currentSurface.normal, currentSurface.viewDepth, neighSurface.normal, neighSurface.viewDepth))
            continue;

        //If neighbor has passed the tests the sample is valid. Combine the reservoirs
        Reservoir neigh = Reservoir(gReservoir[idx]);
        VPL vpl = VPL(gVpls[index2Dto1D(idx, gFrameDim.x)]);

        bool vplValid = true;
        //If the light sample is invalid or 0, still add the 0 contribution
        if(!vpl.valid){
            neigh.weightSum = 0;
            vplValid = false;
        }
        
        cachedIndices[i] = (idx.x & 0xFFFF) << 16 | (idx.y & 0xFFFF);
        //Get neightbor light target PDF for current surface
        float targetPdf = 0;
        if(neigh.M > 0 && vplValid){
            LightSample ls = { };
            float distance = 0;
            bool valid = getLightSample(vpl, currentSurface.posW, ls, distance);
        #ifndef DIFFUSE_SHADING_ONLY
            targetPdf = valid ?  currentSurface.getPdf(ls.dir, ls.Li): 0.f;
        #else
            targetPdf = valid ?  currentSurface.getPdfDiffuse(ls.dir, ls.Li): 0.f;
        #endif
        }
        
        if (r.combineReservoir(neigh, targetPdf, sampleNext1D(sg)))
        {
            selectedSample = i;
            selectedVPL = vpl;
        }

    }

    //Bias Correction
#if BIAS_CORRECTION_MODE >= BIAS_MODE_BASIC

    float pi = r.targetPdf;
    float piSum = r.targetPdf * current.M;

    //go through all neighbors again
    for (int i = 0; i < numSpartialSamples; i++)
    {
        //Skip if we skipped in last loop
        if ((cachedIndices[i]) == 0xFFFFFFFF)
            continue;

        //Get index
        uint2 idx = uint2(cachedIndices[i]>>16, (cachedIndices[i] & 0xFFFF));

        //Get Surface
        Surface biasSurface = getSurface(idx);
        if (!biasSurface.valid)
            continue;

        //Get light pdf
        LightSample ls = { };
        float distance = 0;
        bool valid = getLightSample(selectedVPL, biasSurface.posW, ls, distance);
    #ifndef DIFFUSE_SHADING_ONLY
        float ps = valid ?  biasSurface.getPdf(ls.dir, ls.Li): 0.f;
    #else
        float ps = valid ?  biasSurface.getPdfDiffuse(ls.dir, ls.Li): 0.f;
    #endif

        //Trace ray
        #if BIAS_CORRECTION_MODE >= BIAS_MODE_RAYTRACE
        if (ps > 0)
        {
            SceneRayQuery < 0 > rayQuery;
            distance *= kRayEpsilon;
            const Ray ray = Ray(biasSurface.posW, ls.dir, 0.f, distance);
            if (!rayQuery.traceVisibilityRay(ray, RAY_FLAG_NONE, 0xff))
            {
                ps = 0;
            }
        }
        #endif // BIAS MODE RAYTRACE
        
        //getReservoir
        Reservoir biasRes = Reservoir(gReservoir[idx]);
        
        pi = selectedSample == i ? ps : pi;
        piSum += ps * biasRes.M;
    }
    r.finalizeSample(pi, piSum);
    
#else
    r.finalizeSample(1.0f, r.M);
#endif
        
    gReservoirWrite[dTid] = r.pack();
    gVplsWrite[index2Dto1D(dTid, gFrameDim.x)] = selectedVPL.pack();
}
