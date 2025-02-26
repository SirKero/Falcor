#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.Raytracing;
import Scene.Intersection;
import Utils.Math.MathHelpers;
import Utils.Geometry.GeometryHelpers;
import VirtualShadowMapData; 

//Shader Resources
/** Payload for shadow ray. (32B)
*/
struct RayData
{
    float dist;
    float3 posW;
    __init()
    {
        this.dist = -1;
        this.posW = float3(0);
    }
};

cbuffer CB
{
    float4x4 gViewProjection;
    float4x4 gInvViewProjection;
}

static const uint kRayFlags = 0; //TODO define ACCEL_RAY_FLAGS;

//Shaders
[shader("miss")]
void miss(inout RayData rayData)
{
    rayData.dist = 1;
}
//
// Shader entry points for TriangleMesh hit groups.
//
[shader("anyhit")]
void anyHit(inout RayData rayData, BuiltInTriangleIntersectionAttributes attribs)
{
}

[shader("closesthit")]
void closestHit(inout RayData rayData, BuiltInTriangleIntersectionAttributes attribs)
{
    rayData.posW = WorldRayOrigin() + WorldRayDirection() * RayTCurrent();
    rayData.dist = mul(gViewProjection, float4(rayData.posW,1.0)).z;
}
//
// Shader entry point for ray generation shader.
//
[shader("raygeneration")]
void rayGen()
{
    uint2 shadowPixel = DispatchRaysIndex().xy;
    uint2 dimensions = DispatchRaysDimensions().xy;
    float2 nearPlanePos = float2((shadowPixel + 0.5) / dimensions);
    nearPlanePos = nearPlanePos * 2.0 - 1.0;
    nearPlanePos.y *= -1;
    float4 posWPixelNear = mul(gInvViewProjection, float4(nearPlanePos, 0.0, 1.0));
    float4 posWPixelFar = mul(gInvViewProjection, float4(nearPlanePos, 1.0, 1.0));
    posWPixelNear.xyz /= posWPixelNear.w;
    float3 rayDirection;
    rayDirection = posWPixelFar.xyz - posWPixelNear.xyz;
    RayDesc ray;
    ray.TMin = 0;
    ray.TMax = length(rayDirection);
    ray.Origin = posWPixelNear.xyz;
    ray.Direction = rayDirection/ray.TMax;
    RayData rayData = RayData();
    //Trace ray
    TraceRay(gScene.rtAccel, kRayFlags, 0xFF /* kShadowRayInstanceMask instanceInclusionMask */, 0 /* hitIdx */, rayTypeCount, 0 /* missIdx */, ray, rayData);
    gVirtualShadowMapData.writeShadowValue(rayData.dist, rayData.posW);
}
