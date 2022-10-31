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

RWTexture2D<uint4> gReservoir;
Texture2D<uint4> gReservoirPrev;

RWStructuredBuffer<PackedVPL> gVPLs;
StructuredBuffer<PackedVPL> gVplPrev;
Texture1D<snorm float2> gNeighOffsetBuffer;
StructuredBuffer<PackedSurfaceData>gSurfacePrev;
StructuredBuffer<PackedSurfaceData>gSurface;
Texture2D<float2> gMVec;
Texture2D<float4> gView;
Texture2D<float4> gPrevView;

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
    uint gFrameCount; //Current it for sample gen
    uint3 pad;
}

cbuffer Constant{
    uint2 gFrameDim;                //Frame Dimensions for camera dir
    uint gMaxAge;
    uint gSpartialSamples;
    float gSamplingRadius;
    float gDepthThreshold;          //Relative depth offset
    float gNormalThreshold;         //Maximum cosine between both Normals that is allowed
    uint gDisocclusionBoostSamples; //Number of spartial samples if no temporal surface was found
    float gVplRadius;               //Vpl radius
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


ShadingData loadShadingData(const HitInfo hit, const float3 rayDir, const ITextureSampler lod)
{
    const TriangleHit triangleHit = hit.getTriangleHit();
    VertexData v = gScene.getVertexData(triangleHit);
    uint materialID = gScene.getMaterialID(triangleHit.instanceID);
    ShadingData sd = gScene.materials.prepareShadingData(v, materialID, -rayDir, lod);
    adjustShadingNormal(sd, v);
    
    return sd;
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


[numthreads(16, 16, 1)]
void main(uint2 dTid : SV_DispatchThreadID)
{
    SampleGenerator sg = SampleGenerator(dTid, gFrameCount + 7 * 13);
    Reservoir r = Reservoir();
    
    //Check if surface is valid
    Surface currentSurface = getSurface(dTid, false);
    if(!currentSurface.valid)
        return;

    //Load reservoir from current iteration
    VPL selectedVPL = VPL();
    Reservoir current =  Reservoir(gReservoir[dTid]);
    if(current.weightSum > 0){
        selectedVPL = VPL(gVPLs[index2Dto1D(dTid, gFrameDim.x)]);
    }
    
    uint historyLimit = uint(gMaxAge * current.M);
    
    r.combineReservoir(current, current.targetPdf , 0.5 /* random */);
    
    //
    //Temporal Sample
    //
    float2 motionOffset = gMVec[dTid] * float2(gFrameDim);
    //Check if motion vectors are inside of the frame
    float2 prevIdxF = motionOffset + float2(dTid);
    float2 rndOffset = sampleNext2D(sg) - 0.5f;
    prevIdxF += rndOffset;
    
    int2 prevIdx = int2(round(prevIdxF));

    //Get surface from last frame
    bool foundTemporalSurface = false;
    int2 temporalOffset = int2(0,0);
    const float temporalSearchRadius = 4.f;   //actual radius is 2 due to random value in [-0.5,0.5]
   
    //Try to find a matching surface in the neighborhood of the reprojected pixel
    for(uint i=0 ; i<9; i++){
        int2 offset = int2(0,0);
        if(i > 0){
            offset = int2( (sampleNext2D(sg) - 0.5f) * temporalSearchRadius);
        }

        int2 idx = prevIdx + offset;

        //index is outside of the frame
        if(idx.x < 0 && idx.y < 0 && idx.x > gFrameDim.x && idx.y > gFrameDim.y)
            continue;
        
        //Get Hit sample from last frame
        Surface temporalSurface = getSurface(idx, true); 
        if(!temporalSurface.valid)
            continue;

        //Test surface similarity and discard if too different
        if(!isValidNeighbor(currentSurface.normal, currentSurface.viewDepth, temporalSurface.normal, temporalSurface.viewDepth))
            continue;

        //Valid hit was found
        temporalOffset = offset;
        foundTemporalSurface = true;
        break;
    }
    
    //
    //Spartio Temporal Resampling
    //
    
    uint numSamples = clamp(gSpartialSamples + 1,1,32); //Cap at 32 samples for the later bias correction
    const uint maxNeighStartIndex = kNeighOffsetMask - (numSamples + 1);
    const uint neighOffsetStartIdx = min(uint(sampleNext1D(sg) * float(maxNeighStartIndex)), maxNeighStartIndex);
    uint cachedResults = 0; //Remember which sample was valid
    
    if(!foundTemporalSurface)
        numSamples = clamp(max(numSamples, gDisocclusionBoostSamples),1,32);

    int selectedSample = -1;
    bool validSample = true;
    
    //Go through all neighbors
    for(uint i=0 ; i<numSamples; i++){
        int2 idx = int2(0);

        //Take temporal sample or generate a new neighbor sample
        if(i==0 && foundTemporalSurface){
           idx = prevIdx + temporalOffset;
        }
        else{
            //Get sample from sampling mask
            uint neighBufferIdx = neighOffsetStartIdx + i;
            float2 randSamp = float2(gNeighOffsetBuffer[neighBufferIdx]);
            int2 spartialOffset = int2(randSamp * gSamplingRadius);
            idx = prevIdx + spartialOffset;

            //Check if index is valid
            if(idx.x < 0 && idx.y < 0 && idx.x > gFrameDim.x && idx.y > gFrameDim.y)
                continue;
            
             //Get surface and check if valid
            Surface neighSurface = getSurface(idx, true); 
            if(!neighSurface.valid)
                continue;
        
            if(!isValidNeighbor(currentSurface.normal, currentSurface.viewDepth, neighSurface.normal, neighSurface.viewDepth))
                continue;
        }
            
        //If neighbor surface has passed the tests get reservoir and compair them
        Reservoir sampledReservoir = Reservoir(gReservoirPrev[idx]);
        sampledReservoir.M = min(sampledReservoir.M, historyLimit);

        bool vplValid = true;
        VPL vpl = VPL(gVplPrev[index2Dto1D(idx,gFrameDim.x)]);
        if(!vpl.valid || vpl.replaced){
            sampledReservoir.weightSum = 0;
            sampledReservoir.M = 0;
            vplValid = false;
        }
                
        //Get neightbor light target PDF for current surface
        float sampleTargetPdf = 0.f;
        if (sampledReservoir.M > 0 && vplValid)
        {
            cachedResults |= (1u << i);
            LightSample ls = { };
            float dis;
            bool valid = getLightSample(vpl, currentSurface.posW, ls, dis);
        #ifndef DIFFUSE_SHADING_ONLY
            sampleTargetPdf = valid ?  currentSurface.getPdf(ls.dir, ls.Li): 0.f;
        #else
            sampleTargetPdf = valid ?  currentSurface.getPdfDiffuse(ls.dir, ls.Li): 0.f;
        #endif
        }
        //Combine Reservoirs
        if(r.combineReservoir(sampledReservoir, sampleTargetPdf, sampleNext1D(sg))){
            selectedSample = i;
            selectedVPL = vpl;
        }
    }

//Bias correction TODO: Possible reweighing error; a bit too bright; needs checking
#if BIAS_CORRECTION_MODE >= BIAS_MODE_BASIC
        
    float pi = r.targetPdf;
    float piSum = r.targetPdf * current.M;
        
    //go through all neighbors again
    for (int i = 0; i < numSamples; i++){
        //Skip if we skipped in last loop
        if ((cachedResults & (1u << i)) == 0)
            continue;
        //Get Index
        int2 offset = int2(0);
        if (i == 0 && foundTemporalSurface)
            offset = temporalOffset;
        else
        {
            uint neighBufferIdx = neighOffsetStartIdx + i;
            float2 randSamp = float2(gNeighOffsetBuffer[neighBufferIdx]);
            offset = int2(randSamp * gSamplingRadius);
        }
        int2 idx = prevIdx + offset;

        //Get Surface
        Surface biasSurface = getSurface(idx, true);
            
        //getReservoir
        Reservoir biasRes = Reservoir(gReservoirPrev[idx]);
        biasRes.M = min(biasRes.M, historyLimit); //cap M
        
        //Get light pdf
        float ps = 0.0f;
        LightSample ls = { };
        float dist = 0;
            
        bool valid = getLightSample(selectedVPL, biasSurface.posW, ls, dist);
        #ifndef DIFFUSE_SHADING_ONLY
            ps = valid ?  biasSurface.getPdf(ls.dir, ls.Li): 0.f;
        #else
            ps = valid ?  biasSurface.getPdfDiffuse(ls.dir, ls.Li): 0.f;
        #endif

        bool rayHit = false;
        //Trace ray
        #if BIAS_CORRECTION_MODE >= BIAS_MODE_RAYTRACE
        if (ps > 0.0 && valid)
        {
            SceneRayQuery < 0 > rayQuery;
            dist *= kRayEpsilon;
            const Ray ray = Ray(biasSurface.posW, normalize(ls.dir), 0.f, dist);
            if (!rayQuery.traceVisibilityRay(ray, RAY_FLAG_CULL_NON_OPAQUE, 0xff))
            {
                ps = 0;
            }
        }
        #endif // BIAS MODE RAYTRACE
        
        pi = selectedSample == i ? ps : pi;
        piSum += ps * biasRes.M;
    }
    r.finalizeSample(pi, piSum);
        
#else //BIAS MODE BASIC
    r.finalizeSample(1.0f, r.M);
#endif //BIAS MODE BASIC
    
    gReservoir[dTid] = r.pack();
    gVPLs[index2Dto1D(dTid, gFrameDim.x)] = selectedVPL.pack();
}
