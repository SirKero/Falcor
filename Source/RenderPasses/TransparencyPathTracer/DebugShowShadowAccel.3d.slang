#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.Scene;
import Utils.Math.MathHelpers;
import Utils.Geometry.GeometryHelpers;
import Utils.Math.AABB;


cbuffer CB
{
    uint        gSMSize;       //Current frame count
    float       gNear;          //Near Plane
    float       gFar;           //Far Plane
    uint        gSelectedLight; //Selected light
    float3       gCullMin;       //XYZ culling min
    float3       gCullMax;       //XYZ culling max
    float       gBlendT;
    uint        gVisMode;       //Vizualization mode
    float4x4    gInvView;        // Inverse View
    float4x4    gInvProj;       //Inverse Projection
}

#define VIS_MODE_VISIBILITY 0
#define VIS_MODE_AABBINDEX 1
#define VIS_MODE_FRONTBACKBOX 2

// Accel Modes
#define ACCEL_MODE_SHADOW3D 0
#define ACCEL_MODE_NORMALOFFSET 1

#ifndef ACCEL_MODE
#define ACCEL_MODE ACCEL_MODE_SHADOW3D
#endif

//Inputs
StructuredBuffer<AABB> gShadowAABB;
Buffer<uint> gShadowCounter;
StructuredBuffer<float4> gShadowData;
Texture2D<float4> gOutputColor;

static const float kMinOpacity = 1e-7;

// Sampler
SamplerState gPointSampler;

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

struct GsOut
{
    float4 posH : SV_Position;
    float transparency : TRANSPARENCY;
    nointerpolation uint boxIdx : AABB_IDX;
};

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

/** Null vertex shader. We'll do all the work in the geometry shader.
 */
void vsMain()
{
}

bool cullAABB(inout AABB aabb) {
    if (any(aabb.minPoint > gCullMax) || any(aabb.maxPoint < gCullMin))
        return false;
    aabb.minPoint = max(gCullMin, aabb.minPoint);
    aabb.maxPoint = min(gCullMax, aabb.maxPoint);
    return true;
}

void getPointFromAABB(in AABB aabb, inout float3 points[8]) {
    points = {
        aabb.minPoint,
        float3(aabb.maxPoint.x, aabb.minPoint.y, aabb.minPoint.z),
        float3(aabb.maxPoint.x, aabb.maxPoint.y, aabb.minPoint.z),
        float3(aabb.minPoint.x, aabb.maxPoint.y, aabb.minPoint.z),
        float3(aabb.minPoint.x, aabb.minPoint.y, aabb.maxPoint.z),
        float3(aabb.maxPoint.x, aabb.minPoint.y, aabb.maxPoint.z),
        float3(aabb.maxPoint.x, aabb.maxPoint.y, aabb.maxPoint.z),
        float3(aabb.minPoint.x, aabb.maxPoint.y, aabb.maxPoint.z),
    };
}

//Converts the 8 vertices to a cube
void verticesToCube(const in GsOut[8] vert, inout TriangleStream<GsOut> outStream) {
    // Output all 6 faces of the Cube
    // Front
    outStream.Append(vert[0]);
    outStream.Append(vert[3]);
    outStream.Append(vert[1]);
    outStream.Append(vert[2]);
    outStream.RestartStrip();

    // Right
    outStream.Append(vert[1]);
    outStream.Append(vert[2]);
    outStream.Append(vert[5]);
    outStream.Append(vert[6]);
    outStream.RestartStrip();

    // Back
    outStream.Append(vert[5]);
    outStream.Append(vert[6]);
    outStream.Append(vert[4]);
    outStream.Append(vert[7]);
    outStream.RestartStrip();

    // Left
    outStream.Append(vert[4]);
    outStream.Append(vert[7]);
    outStream.Append(vert[0]);
    outStream.Append(vert[3]);
    outStream.RestartStrip();

    // Top
    outStream.Append(vert[3]);
    outStream.Append(vert[7]);
    outStream.Append(vert[2]);
    outStream.Append(vert[6]);
    outStream.RestartStrip();

    // Bottom
    outStream.Append(vert[0]);
    outStream.Append(vert[4]);
    outStream.Append(vert[1]);
    outStream.Append(vert[5]);
    outStream.RestartStrip();
}

/** Geometry shader.
    We place textured emissive triangles in texture space scaled so that we get one
    pixel shader execution per texel. The vertex positions are passed on to the pixel shader.
    Non-textured emissives are culled.
*/
#if ACCEL_MODE == ACCEL_MODE_SHADOW3D
[maxvertexcount(24)]
#else
[maxvertexcount(48)]
#endif
void gsMain(uint aabbIdx: SV_PrimitiveID, inout TriangleStream<GsOut> outStream)
{
    const uint count = gShadowCounter[0]; // Get the valid number of aabbs
    if (aabbIdx == count) {
        float3 ndc[3];
        ndc[0] = float3(-1., -1., 1.0 - 1e-3);
        ndc[1] = float3(3., -1., 1.0 - 1e-3);
        ndc[2] = float3(-1., 3., 1.0 - 1e-3);
        GsOut screenQuad[3];
        for (uint i = 0; i < 3; i++) {

            screenQuad[i].posH = float4(ndc[i], 1.);
            screenQuad[i].transparency = -1.0;
            screenQuad[i].boxIdx = aabbIdx;
            outStream.Append(screenQuad[i]);

        }
        outStream.RestartStrip(); 
            
        return;
    }
    if (aabbIdx > count)
        return;

    // Get AABB and Data
    AABB aabb = gShadowAABB[aabbIdx];
    float4 data = gShadowData[aabbIdx];

    #if ACCEL_MODE == ACCEL_MODE_NORMALOFFSET
    AABB shadowAABB = aabb;
    for (uint box = 0; box < 2; box++) {
        if (box == 0) {
            aabb.maxPoint.z = shadowAABB.minPoint.z + data.x;
        } else {
            aabb = shadowAABB;
            aabb.minPoint.z = shadowAABB.minPoint.z + data.x + 1e-10;
        }
        // Cull AABB
        if (!cullAABB(aabb))
            break;
    #else
        // Cull AABB
        if (!cullAABB(aabb))
            return;
    #endif
       
        //float3 points[8];
        // getPointFromAABB(aabb, points);
        float3 points[8] = {
            aabb.minPoint,
            float3(aabb.maxPoint.x, aabb.minPoint.y, aabb.minPoint.z),
            float3(aabb.maxPoint.x, aabb.maxPoint.y, aabb.minPoint.z),
            float3(aabb.minPoint.x, aabb.maxPoint.y, aabb.minPoint.z),
            float3(aabb.minPoint.x, aabb.minPoint.y, aabb.maxPoint.z),
            float3(aabb.maxPoint.x, aabb.minPoint.y, aabb.maxPoint.z),
            float3(aabb.maxPoint.x, aabb.maxPoint.y, aabb.maxPoint.z),
            float3(aabb.minPoint.x, aabb.maxPoint.y, aabb.maxPoint.z),
        };

        // Transform all vertices into world space
        GsOut vert[8];
        for (uint i = 0; i < 8; i++) {
            float2 ndc = (2.0 * points[i].xy / gSMSize) - 1.0;
            ndc.y *= -1.0;
            float4 rayDir = mul(gInvProj, float4(ndc, 1.0, 1.0));
            rayDir.xyz /= rayDir.z; //Normalize z
            float3 posView = rayDir.xyz * (-points[i].z); //view is negative Z
            float4 worldPos = mul(gInvView, float4(posView, 1.0));
            vert[i].posH = mul(gScene.camera.getViewProj(), worldPos);
        #if ACCEL_MODE == ACCEL_MODE_SHADOW3D
            vert[i].transparency = i < 4 ? data.x : data.y;
            vert[i].boxIdx = aabbIdx;
        #else // ACCEL_MODE == ACCEL_MODE_NORMALOFFSET
            vert[i].transparency = box == 0 ? data.y : data.z; // TODO
            vert[i].boxIdx = gVisMode == VIS_MODE_FRONTBACKBOX ? box :  aabbIdx;
        #endif            
        }
        verticesToCube(vert, outStream);
    #if ACCEL_MODE == ACCEL_MODE_NORMALOFFSET
    }
    #endif
}

/** Pixel shader.
 */
float4 psMain(GsOut gsIn) : SV_Target {
    float3 boxColor;
    if (gVisMode == VIS_MODE_VISIBILITY) {
        boxColor = getColorHeatMap(saturate(gsIn.transparency));
    } else { //(gVisMode == VIS_MODE_AABBINDEX || VIS_MODE_FRONTBACKBOX)
        boxColor = kColorMap[gsIn.boxIdx % 21] / 255.0;
    }
    float3 inColor = gOutputColor[uint2(gsIn.posH.xy)].xyz;
    float3 outColor = lerp(boxColor, inColor, gBlendT);
    if (gsIn.transparency < 0)
        outColor = inColor;

    return (float4(outColor,1));
}
