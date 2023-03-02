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
    RWTexture2D<uint2> gReservoir;
    Texture2D<uint2> gReservoirPrev;
#else
    RWTexture2D<uint4> gReservoir;
    Texture2D<uint4> gReservoirPrev;
#endif

RWStructuredBuffer<PackedVPL> gPhotonLight;
StructuredBuffer<PackedVPL> gPhotonLightPrev;
StructuredBuffer<PackedSurfaceData>gSurfacePrev;
StructuredBuffer<PackedSurfaceData>gSurface;
Texture2D<float2> gMVec;
Texture2D<float4> gView;
Texture2D<float4> gPrevView;

#define BIAS_MODE_BASIC 1
#define BIAS_MODE_RAYTRACE 2
//This is for syntax highlighting
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
    uint gMaxAge;
    float gDepthThreshold;          //Relative depth offset
    float gNormalThreshold;         //Maximum cosine between both Normals that is allowed
    float gMatThreshold;            //Material threshold
    uint2 _pad;
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


Surface getSurface(uint2 idx, bool prev)
{
    float3 viewDir;
    if (is_valid(gView))
    {
        if (prev)
            viewDir = gPrevView[idx].xyz;
        else
            viewDir = gView[idx].xyz;
    }
    else
    {
        viewDir = gScene.camera.computeRayPinhole(idx, gFrameDim).dir * -1; //Flip ViewDir here 
    }
    PackedSurfaceData surfaceData;
    if (prev)
        surfaceData = gSurfacePrev[index2Dto1D(idx, gFrameDim.x)];
    else
        surfaceData = gSurface[index2Dto1D(idx, gFrameDim.x)];
    
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

    ls.Li *= saturate(dot(vpl.normal, -ls.dir));
    
    return ls.Li > 0;   //true if sample is valid
}

[numthreads(16, 16, 1)]
void main(uint2 dTid : SV_DispatchThreadID)
{
    SampleGenerator sg = SampleGenerator(dTid, gFrameCount + 5 * 13);
    Reservoir r = Reservoir();
    
    //Check if surface is valid
    Surface currentSurface = getSurface(dTid, false);
    if(!currentSurface.valid)
        return;
        
    //Load reservoir from current iteration
    VPL selectedVPL = VPL();
    Reservoir current = Reservoir(gReservoir[dTid]);
    if(current.weightSum > 0){
        selectedVPL = VPL(gPhotonLight[index2Dto1D(dTid, gFrameDim.x)]);
    }

    uint historyLimit = gMaxAge * current.M;
    r.combineReservoir(current, current.targetPdf, 0.5 /* random */);
    
    float2 motionOffset = gMVec[dTid] * float2(gFrameDim);
    //Check if motion vectors are inside of the frame
    float2 prevIdxF = motionOffset + float2(dTid);
    float2 rndOffset = sampleNext2D(sg) - 0.5f;
    prevIdxF += rndOffset;
    
    uint2 prevIdx = uint2(round(prevIdxF));
    
    //Check if a neighbor surface matches up
    //Try to find a matching surface in the neighborhood of the reprojected pixel
    Surface temporalSurface;
    bool selectPrevSample = false;
    uint previousM = 0;
    bool foundTemporalSurface = false;
    int2 idx = (0,0);
    float temporalSearchRadius = 4.f;
    
    for(uint i=0 ; i<9; i++){
        int2 offset = int2(0,0);
        if(i > 0){
            offset = int2( (sampleNext2D(sg) - 0.5f) * temporalSearchRadius);
        }

        idx = prevIdx + offset;

        //index is outside of the frame
        if(idx.x < 0 && idx.y < 0 && idx.x > gFrameDim.x && idx.y > gFrameDim.y)
            continue;
        
        //Get Hit sample from last frame
        temporalSurface = getSurface(idx, true); 
        if(!temporalSurface.valid)
            continue;

        //Test surface similarity and discard if too different
        if (!currentSurface.isValidNeighbor(temporalSurface, gDepthThreshold, gNormalThreshold, gMatThreshold))
            continue;

        //Valid hit was found
        foundTemporalSurface = true;
        break;
    }

    if(foundTemporalSurface){
        Reservoir prev = Reservoir(gReservoirPrev[idx]);
        prev.M = min(prev.M, historyLimit);
        previousM = prev.M;

        bool vplValid = true;
        VPL vpl = VPL(gPhotonLightPrev[index2Dto1D(idx, gFrameDim.x)]);
        //Kill the reservoir if the vpl is no longer valid or was replaced
        if(!vpl.valid | vpl.replaced){
            prev.weightSum = 0;
            prev.M = 0;
            vplValid = false;
        }

        //Get new target pdf if reservoir and vpl are valid
        float targetPdf = 0;
        if(prev.M > 0 && vplValid){
            LightSample ls = { };
            float dis = 0;
            bool validLS = getLightSample(vpl, currentSurface.posW, ls, dis);
        #ifndef DIFFUSE_SHADING_ONLY
            targetPdf = validLS ?  currentSurface.getPdf(ls.dir, ls.Li): 0.f;
        #else
            targetPdf = validLS ?  currentSurface.getDiffusePdf(ls.dir, ls.Li): 0.f;
        #endif
        }

        selectPrevSample = r.combineReservoir(prev, targetPdf, sampleNext1D(sg));
        if(selectPrevSample)
            selectedVPL = vpl;
    }

//Bias correction
#if BIAS_CORRECTION_MODE >= BIAS_MODE_BASIC
    float pi = r.targetPdf;
    float piSum = r.targetPdf * current.M;

    if (foundTemporalSurface)
    {
        LightSample ls = { };
        float distance = 0;
        bool valid = getLightSample(selectedVPL, temporalSurface.posW, ls, distance);
    #ifndef DIFFUSE_SHADING_ONLY
        float ps = valid ?  temporalSurface.getPdf(ls.dir, ls.Li): 0.f;
    #else
        float ps = valid ?  temporalSurface.getDiffusePdf(ls.dir, ls.Li): 0.f;
    #endif

        #if BIAS_CORRECTION_MODE >= BIAS_MODE_RAYTRACE
        if (ps > 0)
        {
            SceneRayQuery < 0 > rayQuery;
            distance *= kRayEpsilon;
            const Ray ray = Ray(temporalSurface.posW, ls.dir, 0.f, distance);
            if (!rayQuery.traceVisibilityRay(ray, RAY_FLAG_NONE, 0xff))
            {
                ps = 0;
            }
        }
        #endif // BIAS MODE RAYTRACE
        
        pi = selectPrevSample ? ps : pi;
        piSum += ps * previousM;
    }
    r.finalizeSample(pi, piSum);
    
#else    
    r.finalizeSample(1.0f, float(r.M));
#endif //BIAS_MODE_BASIC
        
#ifdef USE_REDUCED_RESERVOIR_FORMAT
    gReservoir[dTid] = r.packReduced();
#else
    gReservoir[dTid] = r.pack();
#endif
    gPhotonLight[index2Dto1D(dTid, gFrameDim.x)] = selectedVPL.pack();
}
