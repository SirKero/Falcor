#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.Raytracing;
import Scene.Intersection;
import Utils.Math.MathHelpers;
import Utils.Geometry.GeometryHelpers;
import Utils.Sampling.SampleGenerator;


/** Payload for shadow ray.
*/
struct RayData
{
    float linZ;
    bool hit;

    __init() {
        linZ = 0;
        hit = false;
    }
};

struct Attribs {
    uint pad;
}

cbuffer CB
{
    uint        gSMSize;       //Current frame count
    float       gNear;          //Near Plane
    float       gFar;           //Far Plane
    uint        gSelectedLight; //Selected light
    uint        gStep;  //Number of steps
    float       gMinDist; //Tmin
    float       gMaxDist; //TMax
    float4x4    gViewProj; // View Projection for current light
}

RaytracingAccelerationStructure gShadowAS;
StructuredBuffer<AABB> gShadowAABB;
StructuredBuffer<float2> gShadowData;

// Outputs
RWTexture2D<float4> gOutputColor;
RWTexture2D<float4> gOutputDebug;

static const float kMinOpacity = 1e-7;


/** Setup ShadingData based on loaded vertex/material attributes for a hit point.
    \param[in] hit Hit information.
    \param[in] rayOrigin Ray origin.
    \param[in] rayDir Normalized ray direction.
    \param[in] lod Method for computing texture level-of-detail.
    \return ShadingData struct.
*/
ShadingData loadShadingData(const HitInfo hit, const float3 rayDir, const ITextureSampler lod)
{
    const TriangleHit triangleHit = hit.getTriangleHit();
    VertexData v = gScene.getVertexData(triangleHit);
    uint materialID = gScene.getMaterialID(triangleHit.instanceID);

    ShadingData sd = gScene.materials.prepareShadingData(v, materialID, -rayDir, lod);

    return sd;
}

//Shaders
[shader("miss")]
void miss(inout RayData rayData)
{

}

//
// Shader entry points for TriangleMesh hit groups.
//

[shader("anyhit")]
void anyHit(inout RayData rayData, Attribs attribs)
{
    // Get data
    AABB aabb = gShadowAABB[PrimitiveIndex()];
    float2 rangeZ = float2(aabb.minPoint.z, aabb.maxPoint.z);
    if (rayData.linZ > rangeZ.y || rayData.linZ < rangeZ.x || !aabb.contains(WorldRayOrigin()))
        IgnoreHit();

    rayData.hit = true;
    AcceptHitAndEndSearch();
}

//
// Shader entry points for TriangleMesh hit groups.
//

[shader("closesthit")]
void closestHit(inout RayData rayData, Attribs attribs)
{
    
}

/*
bool rayAABBIntersection(in float3 origin, in float3 dir, in AABB aabb, float tmin, float tmax, out float minDist) {
    float3 invD = rcp(dir);
    float3 t0s = (aabb.minPoint - origin) * invD;
    float3 t1s = (aabb.maxPoint - origin) * invD;

    float3 tsmaller = min(t0s, t1s);
    float3 tbigger = max(t0s, t1s);

    tmin = max(tmin, max(tsmaller[0], max(tsmaller[1], tsmaller[2])));
    tmax = min(tmax, min(tbigger[0], min(tbigger[1], tbigger[2])));

    minDist = tmin;
    return (tmin < tmax);
}
*/

[shader("intersection")]
void intersection()
{
    Attribs attribs = {};
    ReportHit(RayTCurrent(), 0, attribs);
}


//
// Shader entry point for ray generation shader.
//
[shader("raygeneration")]
void rayGen()
{
    uint2 pixel = DispatchRaysIndex().xy;
    uint2 frameDim = DispatchRaysDimensions().xy;

    // Get camera position and view vector
    Ray camRay = gScene.camera.computeRayPinhole(pixel, frameDim);
    camRay.tMin = gMinDist;
    camRay.tMax = gMaxDist;

    float3 color = float3(0);

    float3 posW = camRay.origin + camRay.dir * camRay.tMin;
    float stepSize = (camRay.tMax - camRay.tMin) / float(gStep);
    for (uint i = 0; i < gStep; i++) {
        float4 shadowPos = mul(gViewProj, float4(posW, 1));
        posW += camRay.dir * stepSize;   //Next step

        shadowPos.xyz /= shadowPos.w;

        shadowPos.y *= -1;                                    // Flip
        shadowPos.xy = shadowPos.xy * 0.5 + 0.5;              // UV from [-1,1] to [0,1]
        shadowPos.z = (shadowPos.w - gNear) / (gFar - gNear); // Linear distance

        // Check if inside
        if (any(shadowPos.xyz < 0.0) || any(shadowPos.xyz > 1.0))
            continue;

        float2 shadowPixel = floor(shadowPos.xy * gSMSize) + 0.5;
        float dist = shadowPos.w;

        RayData rayData = RayData();
        rayData.linZ = dist;
        RayDesc ray;
        ray.Origin = float3(shadowPixel.x, shadowPixel.y, dist);
        ray.Direction = float3(0, 0, -1);
        ray.TMin = 0;
        ray.TMax = 1e-10;

        uint rayFlags = 0;
        uint instanceMask = 1 << gSelectedLight;
        TraceRay(gShadowAS, rayFlags, instanceMask /* instanceInclusionMask */, 0 /* hitIdx */, 1, 0 /* missIdx */, ray, rayData);

        if (rayData.hit) {
            color = float3(1);
            break;
        }
    }

    gOutputDebug[pixel] = float4(color, 1.0);
    //gOutputColor[pixel] += float4(color, 0.0); 
}
