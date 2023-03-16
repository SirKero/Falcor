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

#ifdef USE_REDUCED_RESERVOIR_FORMAT
    Texture2D<uint2> gReservoir;
    RWTexture2D<uint2> gReservoirWrite;
#else
    Texture2D<uint4> gReservoir;
    RWTexture2D<uint4> gReservoirWrite;
#endif

StructuredBuffer<PackedVPL> gPhotonLight;
RWStructuredBuffer<PackedVPL> gPhotonLightWrite;
StructuredBuffer<PackedSurfaceData>gSurface;
Texture2D<float2> gMVec;
Texture2D<float4> gView;

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
    bool gTestVisibility;               //Visibility test
}

cbuffer Constant
{
    uint2 gFrameDim;                //Frame Dimensions for camera dir
    uint gSpartialSamples;
    float gSamplingRadius;
    float gDepthThreshold;          //Relative depth offset
    float gNormalThreshold;         //Maximum cosine between both Normals that is allowed
    float gMatThreshold;               //Vpl radius
    uint _pad;
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

bool getLightSample(in VPL vpl,in float3 worldPos, out LightSample ls, out float sampleDistance){
    //Get light position

    if(any(vpl.flux < 0)) return false;
    
    ls.dir = vpl.posW - worldPos;
    float distSqr= max(FLT_MIN, dot(ls.dir, ls.dir)); // Clamp to avoid NaNs below
    sampleDistance = sqrt(distSqr);
    ls.dir = ls.dir/ sampleDistance;    //normalize
    
    ls.Li = luminance(vpl.flux);
    float pdf = distSqr / max(FLT_MIN, saturate(dot(normalize(vpl.normal), -ls.dir)));
    ls.Li /= pdf;

    return ls.Li > 0;   //true if sample is valid
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
        selectedVPL = VPL(gPhotonLight[index2Dto1D(dTid, gFrameDim.x)]);
    }
    
    r.combineReservoir(current, current.targetPdf, 0.5 /* random */);
    
    int2 currentIndex = dTid;
    uint numSpartialSamples = min(gSpartialSamples,8); //Cap at 8 samples for the later bias correction TODO: Set max sample as constant
    uint cachedIndices[8]; //Store all indeces. 32 Bits per 2D index (16 per element)
    uint cachedM[4];
    int selectedSample = -1;  //Index of the selected sample (-1 is the current one)
    int2 idx = int2(-1,-1);
    //Go through all neighbors
    for(uint i=0 ; i<numSpartialSamples; i++){
        cachedIndices[i] = 0xFFFFFFFF;  //Set to max int
        if (i % 2 == 0)
            cachedM[i / 2] = 0;
        //Get random sample
        
        float2 randSamp = (sampleNext2D(sg) * 2) - 1.f; //random sample in [-1,1]
        int2 spartialOffset = int2(round(randSamp * 10.f));
        idx = currentIndex + spartialOffset;

        if (spartialOffset.x == 0 && spartialOffset.y == 0)
            continue;
        
        //Check if index is valid TODO obsolete with MIP sample 
        if(idx.x < 0 && idx.y < 0 && idx.x >= gFrameDim.x && idx.y >= gFrameDim.y)
            continue;

        //Get surface and check if valid TODO: Valid test obsolete with MIP sample
        Surface neighSurface = getSurface(idx);
        if (!neighSurface.valid)
            continue;
        
        if (!currentSurface.isValidNeighbor(neighSurface, gDepthThreshold, gNormalThreshold, gMatThreshold))
            continue;

        //If neighbor has passed the tests the sample is valid. Combine the reservoirs
        Reservoir neigh = Reservoir(gReservoir[idx]);
        //Reservoir neigh = Reservoir();
        VPL vpl = VPL(gPhotonLight[index2Dto1D(idx, gFrameDim.x)]);

        bool vplValid = true;
        //If the light sample is invalid or 0, still add the 0 contribution
        if(!vpl.valid){
            neigh.weightSum = 0;
            vplValid = false;
        }
        
        cachedIndices[i] = (idx.x & 0xFFFF) << 16 | (idx.y & 0xFFFF);
        uint M = 0xFFFF & neigh.M;
        if(i % 2 != 0)
            M = M << 16;
        cachedM[i / 2] |= M;
        //Get neightbor light target PDF for current surface
        float targetPdf = 0;
        if(neigh.M > 0 && vplValid){
            LightSample ls = { };
            float distance = 0;
            bool valid = getLightSample(vpl, currentSurface.posW, ls, distance);
        #ifndef DIFFUSE_SHADING_ONLY
            targetPdf = valid ?  currentSurface.getPdf(ls.dir, ls.Li): 0.f;
        #else
            targetPdf = valid ?  currentSurface.getDiffusePdf(ls.dir, ls.Li): 0.f;
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
        float ps = valid ?  biasSurface.getDiffusePdf(ls.dir, ls.Li): 0.f;
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

        uint M = cachedM[i / 2];
        if (i % 2 == 0)
            M =  M & 0xFFFF;
        else
            M = M >> 16;
                
        pi = selectedSample == i ? ps : pi;
        piSum += ps * M;
    }
    r.finalizeSample(pi, piSum);
    
#else
    r.finalizeSample(1.0f, r.M);
#endif

//Test visibility of the sample
 #if BIAS_CORRECTION_MODE != BIAS_MODE_RAYTRACE
    if (gTestVisibility)
    {
        LightSample ls = { };
        float distance = 0;
        bool valid = getLightSample(selectedVPL, currentSurface.posW, ls, distance);
        distance *= kRayEpsilon;
        // Ray Query for shadow test; <0> means disabled alpha testing; TODO: Add static const for alpha test
        SceneRayQuery < 0 > rayQuery;
        const Ray ray = Ray(currentSurface.posW, ls.dir, 0.f, distance);
        if (!rayQuery.traceVisibilityRay(ray, RAY_FLAG_NONE, 0xff))
        {
            r.weightSum = 0.f; //Set weight to zero if light is not visible
        }
    }
#endif
        
#ifdef USE_REDUCED_RESERVOIR_FORMAT
    gReservoirWrite[dTid] = r.packReduced();
#else
    gReservoirWrite[dTid] = r.pack();
#endif
    
    gPhotonLightWrite[index2Dto1D(dTid, gFrameDim.x)] = selectedVPL.pack();
}
