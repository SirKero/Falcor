#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.Raytracing;
import Scene.Intersection;
import Utils.Math.MathHelpers;
import Utils.Geometry.GeometryHelpers;
import VirtualShadowMapData; 

#define data gVirtualShadowMapData

//Shader Resources
/** Payload for shadow ray. (32B)
*/
struct RayData
{
    uint clipMapLevel;
    float dist;
    float3 posW;
    __init()
    {
        this.dist = -1;
        this.posW = float3(0);
    }
};

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
    // Alpha test for non-opaque geometry.
    GeometryInstanceID instanceID = getGeometryInstanceID();
    VertexData v = getVertexData(instanceID, PrimitiveIndex(), attribs);
    uint materialID = gScene.getMaterialID(instanceID);
    if (gScene.materials.alphaTest(v, materialID, 0.f))
        IgnoreHit();
}

[shader("closesthit")]
void closestHit(inout RayData rayData, BuiltInTriangleIntersectionAttributes attribs)
{
    rayData.posW = WorldRayOrigin() + WorldRayDirection() * RayTCurrent();
    rayData.dist = mul(data.gViewProjection[rayData.clipMapLevel], float4(rayData.posW, 1.0)).z;
}
//
// Shader entry point for ray generation shader.
//
[shader("raygeneration")]
void rayGen()
{
    uint dispatchIndex = DispatchRaysIndex().x;
    uint index = dispatchIndex / (data.gPageSize.x * data.gPageSize.y);
    uint status = data.getStatus(data.gRenderBuffer[index]);
    if (data.isInactive(status))
    {
        return;
    }
    uint packedData = data.getAddress(data.gRenderBuffer[index]);
    uint flatOffset = dispatchIndex % (data.gPageSize.x * data.gPageSize.y);
    uint2 offset = uint2(flatOffset % data.gPageSize.x, flatOffset / data.gPageSize.x); 
    uint2 dimensions = data.gClipMapSize;
    uint3 renderData = data.unpackRenderData(packedData);
    uint clipMapLevel = renderData.x;
    int2 clipMapPixel = (int2) renderData.yz;
    int2 shadowPixel = (clipMapPixel - data.gClipMapOriginOffsets[clipMapLevel * 2] - data.gClipMapOriginOffsets[clipMapLevel * 2 + 1] + 2 * data.gVirtualClipMapSize) % data.gVirtualClipMapSize; // Undo Origin Offset
    shadowPixel = shadowPixel * data.gPageSize + offset;

    float2 nearPlanePos = float2((shadowPixel + 0.5) / dimensions);
    nearPlanePos = nearPlanePos * 2.0 - 1.0;
    nearPlanePos.y *= -1;
    float4 posWPixelNear = mul(data.gInvViewProjection[clipMapLevel], float4(nearPlanePos, 0.0, 1.0));
    float4 posWPixelFar = mul(data.gInvViewProjection[clipMapLevel], float4(nearPlanePos, 1.0, 1.0));
    posWPixelNear.xyz /= posWPixelNear.w;
    float3 rayDirection = posWPixelFar.xyz - posWPixelNear.xyz;
    RayDesc ray;
    ray.TMin = 0;
    ray.TMax = length(rayDirection);
    ray.Origin = posWPixelNear.xyz;
    ray.Direction = rayDirection/ray.TMax;
    RayData rayData = RayData();
    rayData.clipMapLevel = clipMapLevel;
    //Trace ray
    TraceRay(gScene.rtAccel, kRayFlags, 0xFF /* kShadowRayInstanceMask instanceInclusionMask */, 0 /* hitIdx */, rayTypeCount, 0 /* missIdx */, ray, rayData);
    uint address = data.getAddress(data.gVirtualClipMapsRW[clipMapLevel][clipMapPixel]);
    uint2 texel = data.convertAddressToTexel(address);
    data.gPhysicalClipMapsRW[clipMapLevel][texel + offset] = rayData.dist;
}
