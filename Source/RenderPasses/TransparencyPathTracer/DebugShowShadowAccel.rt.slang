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
    float vis;
    uint primIndex;
    float normalizationFactor;

    __init() {
        linZ = 0;
        hit = false;
        vis = 0.0;
        primIndex = 0;
        normalizationFactor = 0.0;
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
    float       gMaxDist;       // TMax
    float       gBlendT;
    uint        gVisMode;       //Vizualization mode  
    float4x4    gViewProj; // View Projection for current light
}

#define VIS_MODE_VISIBILITY 0
#define VIS_MODE_AABBINDEX 1

// Accel Modes
#define ACCEL_MODE_SHADOW3D 0
#define ACCEL_MODE_NORMALOFFSET 1

#ifndef ACCEL_MODE
#define ACCEL_MODE ACCEL_MODE_SHADOW3D
#endif

RaytracingAccelerationStructure gShadowAS;
StructuredBuffer<AABB> gShadowAABB;
StructuredBuffer<float4> gShadowData;

// Outputs
Texture2D<float4> gOutputColor;
RWTexture2D<float4> gOutputDebug;

static const float kMinOpacity = 1e-7;

//Heatmap
static const float4 kHMInferno[8] = {
    float4(5, 3, 30, 0.0),
    float4(40, 11, 84, 0.14),
    float4(101, 21, 110, 0.29),
    float4(159, 42, 99, 0.43),
    float4(212, 72, 66, 0.57),
    float4(245, 125, 21, 0.71),
    float4(250, 193, 39, 0.86),
    float4(252, 255, 164, 1.0),
};

//Color map
static const float3 kColorMap[21] = {
        float3(230, 25, 75),   float3(60, 180, 75),   float3(255, 225, 25), float3(0, 130, 200),   float3(245, 130, 48),
        float3(145, 30, 180), float3(70, 240, 240),  float3(240, 50, 230),  float3(210, 245, 60), float3(250, 190, 212),
        float3(0, 128, 128),   float3(220, 190, 255), float3(170, 110, 40),  float3(255, 250, 200), float3(128, 0, 0),
        float3(170, 255, 195), float3(128, 128, 0),   float3(255, 215, 180), float3(0, 0, 128),     float3(128, 128, 128),
        float3(255, 255, 255),
};

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

float3 getColorHeatMap(float t) {
    float4 c1 = kHMInferno[0];
    float4 c2 = kHMInferno[1];
    [unroll]
    for (uint i = 1; i < 8; i++) {
        c2 = kHMInferno[i];
        if (t < c2.w)
            break;
        c1 = c2;
    }
    float3 c = lerp(c1.rgb / 255.0, c2.rgb / 255.0, (t - c1.w) / max(c2.w - c1.w, 0.0001));
    return c;
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

    float4 shadowData = gShadowData[PrimitiveIndex()];

    rayData.primIndex = PrimitiveIndex();
    rayData.hit |= true;

#if ACCEL_MODE == ACCEL_MODE_SHADOW3D
    // Shadow Data is x-> transparency before depth, y -> transparency after depth
    float t = saturate((rayData.linZ - rangeZ.x) / (rangeZ.y - rangeZ.x));
    float vis = lerp(shadowData.x, shadowData.y, t);
    rayData.vis = max(rayData.vis, vis);
#else
    rangeZ.y = min(rangeZ.y, rangeZ.x + shadowData.x);
    float vis = shadowData.z;
    float factor = 1.0;
    // in first box
    if (rayData.linZ < rangeZ.y) {
        factor = 1.0 - saturate((rayData.linZ - rangeZ.x) / (rangeZ.y - rangeZ.x));
        vis = shadowData.y;
    }
    rayData.vis += vis * factor;
    rayData.normalizationFactor += factor;
#endif
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

    float3 color = gVisMode == VIS_MODE_VISIBILITY ? float3(0, 0.2, 0) : float3(0);

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
        #if ACCEL_MODE == ACCEL_MODE_NORMALOFFSET
            rayData.vis /= rayData.normalizationFactor;
        #endif
            if(gVisMode == VIS_MODE_VISIBILITY)
                color = getColorHeatMap(rayData.vis);
            else
                color = kColorMap[rayData.primIndex % 21] / 255.0;
            break;
        }
    }

    float3 outColor = gOutputColor[pixel].xyz;

    color = lerp(color, outColor, gBlendT);
    gOutputDebug[pixel] = float4(color, 1.0);
}
