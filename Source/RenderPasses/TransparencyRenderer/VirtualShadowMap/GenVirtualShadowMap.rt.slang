#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.Raytracing;
import Scene.Intersection;
import Utils.Math.MathHelpers;
import Utils.Geometry.GeometryHelpers;

#ifndef NUM_MIPMAPS
#define NUM_MIPMAPS 1
#endif
//Shader Resources
/** Payload for shadow ray. (32B)
*/
struct RayData
{
    uint blubl;
};

cbuffer CB
{
    uint gDirectionalLightSourceIndex;
    float4x4 gLightMVPs[NUM_MIPMAPS];
}
RWTexture2D<float> gVirtualShadowMap;
RWTexture2D<float> gFeedbackTexture;

//Shaders
[shader("miss")]
void miss(inout RayData rayData)
{
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
    
}
//
// Shader entry point for ray generation shader.
//
[shader("raygeneration")]
void rayGen()
{
    gVirtualShadowMap[uint2(0,0)] = 1.f;
}
