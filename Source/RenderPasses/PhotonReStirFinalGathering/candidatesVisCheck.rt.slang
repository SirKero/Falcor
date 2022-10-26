#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.Raytracing;

import Reservoir;
import SurfaceData;
import VPLs;

//Define for valid texture channels
#define is_valid(name) (is_valid_##name != 0)

StructuredBuffer<PackedVPL> gVPLs;
StructuredBuffer<PackedSurfaceData> gSurface;
RWTexture2D<uint4> gReservoir;
Texture2D<float4> gView;

/** Payload for scatter ray (16B).
*/
struct RayData
{
    bool hit;   //< Has the ray hit something

};

//Attribs struct that needs to exist for the intersection shader
struct SphereAttribs
{
    uint hitIdx;
};

static const float kRayEpsilon = 0.99f;

[shader("miss")]
void miss(inout RayData rayData : SV_RayPayload)
{
     rayData.hit = false;   
}

[shader("closesthit")]
void closestHit(inout RayData rayData : SV_RayPayload, BuiltInTriangleIntersectionAttributes attribs : SV_IntersectionAttributes)
{

}

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
        viewDir = gScene.camera.computeRayPinhole(idx, DispatchRaysDimensions().xy).dir * -1; //Flip ViewDir here 
    }
    PackedSurfaceData surfaceData = gSurface[index2Dto1D(idx, DispatchRaysDimensions().x)];
    
    return Surface(surfaceData, viewDir);
}

[shader("raygeneration")]
void rayGen()
{
    uint2 launchIndex = DispatchRaysIndex().xy;
    uint2 launchDim = DispatchRaysDimensions().xy;

    //Get Information for shadow ray
    Reservoir r = Reservoir(gReservoir[launchIndex]);
    Surface surface = getSurface(launchIndex);
    //When surface or reservoir is invalid return. If reservoir weight is already 0 it can be ignored too
    if(!surface.valid || r.weightSum <= 0 || isinf(r.weightSum) || isnan(r.weightSum)){
        return;
    }
    
    VPL vpl = VPL(gVPLs[r.lightIdx]);

    //Get
    RayData rayData = {};
    rayData.hit = true;

    float3 toLight = vpl.posW - surface.posW;
    float dist = length(toLight);
    
    RayDesc ray;
    ray.Origin = surface.posW;
    ray.Direction = toLight/dist;
    ray.TMin = 0.f;
    ray.TMax =  dist * kRayEpsilon;

    uint rayFlags = RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH | RAY_FLAG_SKIP_CLOSEST_HIT_SHADER;

    TraceRay(gScene.rtAccel, rayFlags, 0xff /* instanceInclusionMask */, 0 /* hitIdx */, rayTypeCount, 0 /* missIdx */, ray, rayData);

    //If hit is still true, we did not miss the geometry
    if(rayData.hit){
        //set visibility to zero
        r.weightSum = 0;
        gReservoir[launchIndex] = r.pack();        
    }
}
