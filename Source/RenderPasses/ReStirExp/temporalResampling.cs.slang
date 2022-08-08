#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.Raytracing;
import Scene.Material.ShadingUtils;
import Rendering.Materials.Microfacet;
import Rendering.Materials.Fresnel;
import Utils.Sampling.SampleGenerator;
import Utils.Math.MathHelpers;
import Utils.Color.ColorHelpers;

import Rendering.Lights.EmissiveLightSampler;
import Rendering.Lights.EmissiveLightSamplerHelpers;
import Reservoir;

StructuredBuffer<Reservoir> gReservoirPrev;
RWStructuredBuffer<Reservoir> gReservoir;

Texture2D<PackedHitInfo> gVBuffer;
Texture2D<float2> gMVec;


cbuffer PerFrame
{
    uint gFrameCount;                   //Current it for sample gen
    uint2 gFrameDim;                //Frame Dimensions for camera dir
    uint gMaxAge;
}


struct LightSample{
    uint lightIdx;
    float3 dir;
    float Li;
    float selectPdf;
    float2 uv;
    //Enum type later ? 
};

uint index2Dto1D(uint2 idx, uint width){
    return idx.x + width * idx.y;
}

uint float2toUint(float2 xy){
    uint u = f32tof16(xy.x);
    uint v = f32tof16(xy.y);
    return (u << 16u) | v;
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

void combineReservoir(inout Reservoir r, in Reservoir prev,float weight, float rnd){
    r.weightSum += weight;
    if(rnd < (weight / r.weightSum)){
        r.lightIdx = prev.lightIdx;
        r.uv = prev.uv;
        r.targetPdf = prev.targetPdf;
        r.age = prev.age + 1;
    }
}

[numthreads(16, 16, 1)]
void main(uint2 dTid : SV_DispatchThreadID)
{
    SampleGenerator sg = SampleGenerator(dTid, gFrameCount + 4 * 13);
    bool valid = true;
    Reservoir r = Reservoir.create();
    //Check if surface is valid
    HitInfo hitInfo = HitInfo(gVBuffer[dTid]);
    if(!hitInfo.isValid())
        valid = false;

    //Load reservoir from current iteration
    Reservoir current =  gReservoir[index2Dto1D(dTid, gFrameDim.x)];
    if(current.W > 0 && current.M == 1){
        float currWeight = current.targetPdf * current.W * current.M;
        combineReservoir(r, current, currWeight, 0.5 /* random */);
        r.M = 1;
    }
    
    float2 motionOffset = gMVec[dTid] * float2(gFrameDim);
    //Check if motion vectors are inside of the frame
    float2 prevIdxF = motionOffset + float2(dTid);
    float2 rndOffset = sampleNext2D(sg) - 0.5f;
    prevIdxF += rndOffset;
    
    valid &= prevIdxF.x >= 0 && prevIdxF.y >= 0 && prevIdxF.x < gFrameDim.x && prevIdxF.y < gFrameDim.y;

    uint2 prevIdx = uint2(round(prevIdxF));
    
    Reservoir prev;
    //Load both reservoirs 
    if(valid){
        prev = gReservoirPrev[index2Dto1D(prevIdx, gFrameDim.x)];
    }

    valid &= prev.W > 0 && prev.M != 0 && prev.age <= gMaxAge;

    //TODO check if reprojected surface is valid or similar to current and use weight of reprojected area
    
    if(valid){
        float prevWeight = prev.targetPdf * prev.W * prev.M;
        combineReservoir(r, prev, prevWeight, sampleNext1D(sg));
        r.M += prev.M;
        r.W = 1.f/r.targetPdf * (r.weightSum / r.M);
        
        gReservoir[index2Dto1D(dTid, gFrameDim.x)] = r;
    }   
}
