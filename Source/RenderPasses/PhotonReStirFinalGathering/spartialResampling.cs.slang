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
    RWTexture2D<uint2> gReservoirPrev;
#else
    Texture2D<uint4> gReservoir;
    RWTexture2D<uint4> gReservoirPrev;
#endif


StructuredBuffer<PackedVPL> gPhotonLight;
RWStructuredBuffer<PackedVPL> gPhotonLightPrev;
Texture1D<snorm float2> gNeighOffsetBuffer;
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
static const uint kNeighOffsetMask = OFFSET_BUFFER_SIZE;

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
    SampleGenerator sg = SampleGenerator(dTid, gFrameCount + 6 * 13);
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
    
    uint neighOffsetStartIdx = uint(sampleNext1D(sg) * float(kNeighOffsetMask-1));
    int2 currentIndex = dTid;
    uint numSpartialSamples = min(gSpartialSamples,32); //Cap at 32 samples for the later bias correction
    uint cachedResults = 0;  //Mask for valid neighbor samples
    int selectedSample = -1;  //Index of the selected sample

    //Go through all neighbors
    for(uint i=0 ; i<numSpartialSamples; i++){
        //Get sample from sampling mask
        uint neighBufferIdx = (neighOffsetStartIdx + i) % (kNeighOffsetMask-1);
        float2 randSamp = gNeighOffsetBuffer[neighBufferIdx];
        int2 spartialOffset = int2(round(randSamp * gSamplingRadius));
        int2 idx = currentIndex + spartialOffset;

        //Check if index is valid
        if(idx.x < 0 && idx.y < 0 && idx.x >= gFrameDim.x && idx.y >= gFrameDim.y)
            continue;

        //Get surface and check if valid
        Surface neighSurface = getSurface(idx);
        if (!neighSurface.valid)
            continue;
        
        if (!currentSurface.isValidNeighbor(neighSurface, gDepthThreshold, gNormalThreshold, gMatThreshold))
            continue;

        //If neighbor has passed the tests get reservoir and compair them
        Reservoir neigh = Reservoir(gReservoir[idx]);
        VPL vpl = VPL(gPhotonLight[index2Dto1D(idx, gFrameDim.x)]);
        if(!vpl.valid)
            continue;
        
        cachedResults |= (1u << i);
        //Get neightbor light target PDF for current surface
        float targetPdf = 0;
        if(neigh.M > 0){
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
        if ((cachedResults & (1u << i)) == 0)
            continue;

        //Get index
        uint neighBufferIdx = (neighOffsetStartIdx + i) % (kNeighOffsetMask - 1);
        float2 randSamp = gNeighOffsetBuffer[neighBufferIdx];
        int2 spartialOffset = int2(round(randSamp * gSamplingRadius));
        int2 idx = currentIndex + spartialOffset;

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
        
        //getReservoir
        Reservoir biasRes = Reservoir(gReservoir[idx]);
        
        pi = selectedSample == i ? ps : pi;
        piSum += ps * biasRes.M;
    }
    r.finalizeSample(pi, piSum);
    
#else
    r.finalizeSample(1.0f, r.M);
#endif

#ifdef USE_REDUCED_RESERVOIR_FORMAT
    gReservoirPrev[dTid] = r.packReduced();
#else
    gReservoirPrev[dTid] = r.pack();
#endif
    gPhotonLightPrev[index2Dto1D(dTid, gFrameDim.x)] = selectedVPL.pack();
}
