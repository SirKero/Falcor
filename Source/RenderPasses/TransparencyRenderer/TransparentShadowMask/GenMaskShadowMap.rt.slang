#include "../SharedShadowDefines.slang"
#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"


import Rendering.Materials.TexLODHelpers;
import Rendering.Materials.TexLODTypes;
import Scene.Raytracing;
import Scene.Intersection;
import Utils.Math.MathHelpers;
import Utils.Geometry.GeometryHelpers;

cbuffer CB
{
    uint gLightIdx; // Current light index
    float3 gLightPos;
    bool gIsDirectional; // is directional
    uint3 _pad;
    float4x4 gInvViewProjection; // Inverse view projection
    float4x4 gViewProjection;    // View Projection for current light
}

// Textures
Texture2DArray<float> gMask;      // Non-Opaque object mask
RWTexture2DArray<float> gShadowMap; //Shadow map

struct RayData
{
    float depth;

    __init() {
        this.depth = FLT_MAX;
    }
}


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

[shader("anyhit")]
void anyHit(inout RayData rayData, BuiltInTriangleIntersectionAttributes attribs)
{
    // Alpha test for non-opaque geometry.
    /*
    GeometryInstanceID instanceID = getGeometryInstanceID();
    VertexData v = getVertexData(instanceID, PrimitiveIndex(), attribs);
    const uint materialID = gScene.getMaterialID(instanceID);
    let lod = ExplicitLodTextureSampler(0.f);
    if (gScene.materials.alphaTest(v, materialID, lod, MIN_OPACITY)) 
        IgnoreHit();
    */
}

[shader("closesthit")]
void closestHit(inout RayData rayData, BuiltInTriangleIntersectionAttributes attribs)
{
    TriangleHit triangleHit;
    triangleHit.instanceID = getGeometryInstanceID();
    triangleHit.primitiveIndex = PrimitiveIndex();
    triangleHit.barycentrics = attribs.barycentrics;
    VertexData v = gScene.getVertexData(triangleHit);

    float4 posH = mul(gViewProjection, float4(v.posW, 1.0));
    rayData.depth = gIsDirectional ? posH.z : posH.w; // Linear depth
}

//
// Shader entry point for ray generation shader.
//
[shader("raygeneration")]
void rayGen()
{
    uint2 pixel = DispatchRaysIndex().xy;
    uint2 frameDim = DispatchRaysDimensions().xy;
    uint3 texel = uint3(pixel, gLightIdx);
    RayData rayData = RayData();

    bool valid = true;
    float maskVal = gMask[texel];                       // TODO Use linear sampler or gather?
    valid = maskVal > TRANSPARENCY_MASK_COMPAIRE_VALUE; // 1.0/255.0

    if(valid){
        float2 pixelSample = pixel + 0.5;

        float2 relFramePos = pixelSample / frameDim;
        relFramePos = relFramePos * 2.0 - 1.0; // From [0,1] to [-1,1]
        relFramePos.y *= -1.f;

        float4 posWPixelNear = mul(gInvViewProjection, float4(relFramePos, 0.0, 1.0));
        float4 posWPixelFar = mul(gInvViewProjection, float4(relFramePos, 1.0, 1.0));

        posWPixelNear.xyz /= posWPixelNear.w;
        posWPixelFar.xyz /= posWPixelFar.w;

        float3 rayDirection;
        if (gIsDirectional) {
            rayDirection = posWPixelFar.xyz - posWPixelNear.xyz;
        } else {
            rayDirection = posWPixelNear.xyz - gLightPos;
        }

        RayDesc ray;
        if (gIsDirectional) {
            ray.TMin = 0;
            ray.TMax = length(rayDirection);
            ray.Origin = posWPixelNear.xyz;
            ray.Direction = rayDirection / ray.TMax;
        } else {
            ray.TMin = length(rayDirection);                  // Always start at depth 0
            ray.TMax = distance(gLightPos, posWPixelFar.xyz); // Real far for the pixel
            ray.Origin = gLightPos;
            ray.Direction = rayDirection / ray.TMin; // World direction
        }

        // Trace ray
        uint rayFlags = RAY_FLAG_CULL_NON_OPAQUE;
        TraceRay(gScene.rtAccel, rayFlags, kShadowRayInstanceMask /* instanceInclusionMask */, 0 /* hitIdx */, rayTypeCount, 0 /* missIdx */, ray, rayData);
    }
    
    gShadowMap[texel] = rayData.depth;
}
