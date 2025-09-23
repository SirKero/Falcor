#include "Utils/Math/MathConstants.slangh"

import Scene.RaytracingInline;
import Utils.Sampling.SampleGenerator;
import Utils.Color.ColorHelpers;
import Rendering.Materials.IsotropicGGX;
import Rendering.Materials.Fresnel;

struct Reservoir
{
    int emissiveTriIndex;
    float3 hitPos;

    float3 emission;
    float targetFuction;

    float wSum;
    uint confidenceWeight;
    uint2 _pad;

    __init()
    {
        emissiveTriIndex = -1;
        hitPos = float3(0);
        emission = float3(0);
        targetFuction = 0;
        wSum = 0;
        confidenceWeight = 1;
        _pad = uint2(0);
    }

    bool valid() {
        return emissiveTriIndex >= 0;
    }
}

uint index2Dto1D(uint2 index, uint frameDimX) {
    return index.x + index.y * frameDimX;
}

// Load in shading data from hit and direction
ShadingData loadShadingData(const HitInfo hit, const float3 rayDir, const ITextureSampler lod)
{
    const TriangleHit triangleHit = hit.getTriangleHit();
    VertexData v = gScene.getVertexData(triangleHit);
    uint materialID = gScene.getMaterialID(triangleHit.instanceID);
    ShadingData sd = gScene.materials.prepareShadingData(v, materialID, -rayDir, lod);

    return sd;
}
