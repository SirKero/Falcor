#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.Raytracing;
import Utils.Math.PackedFormats;
import Utils.Math.FormatConversion;
import Utils.Math.MathHelpers;
import Rendering.Materials.StandardMaterial;
import Scene.Material.ShadingUtils;
import Rendering.Lights.LightHelpers;
import Utils.Color.ColorHelpers;
import Rendering.Lights.EmissiveLightSampler;
import Rendering.Lights.EmissiveLightSamplerHelpers;
import VPLs;

cbuffer PerFrame
{
    uint gFrameCount; // Frame count since scene was loaded.
    uint3 _pad1;
}

cbuffer CB
{
    float gVplRadius;       //Radius for the VPLs
    uint2 gFrameDim;
    float gScalar;          //Scalar for the flux
}

StructuredBuffer<VPL> gVPLs;
StructuredBuffer<AABB> gAABBs;
Texture2D<PackedHitInfo> gVBuffer;

RWTexture2D<float4> gColor;

//Acceleration Structure
RaytracingAccelerationStructure gVplAS;

/** Payload for scatter ray (16B).
*/
struct RayData
{
    bool hit;   //< Has the ray hit something
    float distance;     //Hit distance
    uint hitIndex;      //Index of the hit VPL
    uint _pad; //Padding for alignment

};

//Attribs struct that needs to exist for the intersection shader
struct SphereAttribs
{
    uint hitIdx;
};

[shader("miss")]
void miss(inout RayData rayData : SV_RayPayload)
{
     rayData.hit = false;   
}

[shader("closesthit")]
void closestHit(inout RayData rayData : SV_RayPayload, SphereAttribs attribs : SV_IntersectionAttributes){
    rayData.distance = RayTCurrent();
    rayData.hitIndex = attribs.hitIdx;
}

//Intersection with the sphere
bool instersectSphere(const in float3 center, const in float radius, const in float3 origin, const in float3 dir , out float distance)
{
    float t0, t1;   //Possible intersection distances
    float radius2 = radius * radius;
    float3 L = center - origin;
    float tca = dot(L,dir);
    float d2 = dot(L,L) - tca * tca;
    if(d2 > radius2) return false;   //Check if sphere was hit
    float thc = sqrt(radius2 - d2);
    //Get both possible hit distances
    t0 = tca - thc;                 
    t1 = tca + thc;

    //Get the smaller of both
    distance = min(t0, t1);
    //if distance < 0 take the other one
    
    if(distance < 0){
        distance = max(t0,t1);
        return(distance >= 0);
    }
    
    return true;
}

[shader("intersection")]
void intersection()
{
    //Get start point and prim index
    const float3 origin = ObjectRayOrigin();
    const float3 dir = ObjectRayDirection();
    const uint primIndex = PrimitiveIndex();

    //Get Photon AABB. Instance Index 0 is caustic; 1 is global
    AABB photonAABB = gAABBs[primIndex];
    float radius = gVplRadius;
    
    //Check for Sphere intersection
    float distance = 0;
    bool tHit = instersectSphere(photonAABB.center(), radius, origin, dir, distance);

    //Attribs are needed by the api. Because we have no need for additional attributes it is empty
    SphereAttribs attribs;
    attribs.hitIdx = primIndex;

    //Report the hit if the point is in the sphere
    if (tHit)
    {
        ReportHit(distance, 0, attribs);
    }
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

[shader("raygeneration")]
void rayGen()
{
    uint2 launchIndex = DispatchRaysIndex().xy;
    uint2 launchDim = DispatchRaysDimensions().xy;

    //Get shading data
    PackedHitInfo packedHitInfo = gVBuffer[launchIndex];
    HitInfo hitInfo = HitInfo(packedHitInfo);
          
    let lod = ExplicitLodTextureSampler(0.f);
    //Recreate the V-Buffer ray for direction
    Ray cameraRay = gScene.camera.computeRayPinhole(launchIndex, gFrameDim);
    //Get Material properties
    ShadingData sd = loadShadingData(hitInfo, cameraRay.dir, lod);

    const float radius = gVplRadius * 5.f; //Add a little offset to the radius

    RayData rayData = {};
    rayData.hit = true;
    float3 dir = normalize(sd.V);
    RayDesc ray;
    ray.Origin = cameraRay.origin;
    ray.Direction = -dir;
    ray.TMin = 0.f;
    ray.TMax = 10000.f;

    TraceRay(gVplAS, 0, 0xff /* instanceInclusionMask */, 0 /* hitIdx */, 1, 0 /* missIdx */, ray, rayData);

    if(rayData.hit){
        //Check if it is visible
        float distHitPoint = distance(sd.posW, cameraRay.origin);
        float3 vplPosW = ray.Origin + ray.Direction * rayData.distance;
        float distVPL = distance(vplPosW, cameraRay.origin);
        if(distHitPoint < distVPL) return;
        
        //Get flux
        VPL vpl = gVPLs[rayData.hitIndex];
        gColor[launchIndex] = float4(vpl.flux * gScalar,1);
        //gColor[launchIndex] = float4(float3(gScalar),1);  //TODO: Currently flux is 0 so use Scalar value instead
    }
}
