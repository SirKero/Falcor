#pragma once
#include "Utils/Math/MathConstants.slangh"

import Scene.RaytracingInline;
import Utils.Sampling.SampleGenerator;
import Utils.Color.ColorHelpers;
import Rendering.Materials.IsotropicGGX;
import Rendering.Materials.Fresnel;

static const float kShadowRayEpsilon = 0.98f;
static const float kDeltaRoughnessThreshold = 0.08; // see StandardBSDF.slang kMinGGXAlpha. Everything under this value is considered a delta event

//
// Structs
//

struct ReservoirPT
{
    PackedHitInfo sampleSurface;    //(Packed) Surface info for the sample
    float3 sampleRadiance;          //Radiance at the sample point
    uint rngSeed;                   //RNG seed used to create this sample
    float3 sampleIncomingDirection; //Incoming direction of the sample
    uint pathLength;                //Path length until the connectable surface is reached
    float wSum;                     //Unbiased contribution weight
    uint c;                         //Confidence weight
    float jacobianDeterminant;      //(stored) jacobian determinant
    float targetFunction;           //(stored) target Function

    __init() {
        sampleSurface = {};
        sampleRadiance = float3(0);
        uint rngSeed = 0;
        sampleIncomingDirection = float3(0);
        pathLength = 0;
        wSum = 0.0;
        c = 1;
        jacobianDeterminant = -1;
        targetFunction = 0;
    }

    bool isValid() {
        return jacobianDeterminant > 0;
    }
}

//
// Functions
//

// Load in shading data from hit and direction
ShadingData loadShadingData(const HitInfo hit, const float3 rayDir, const ITextureSampler lod)
{
    const TriangleHit triangleHit = hit.getTriangleHit();
    VertexData v = gScene.getVertexData(triangleHit);
    uint materialID = gScene.getMaterialID(triangleHit.instanceID);
    ShadingData sd = gScene.materials.prepareShadingData(v, materialID, -rayDir, lod);

    return sd;
}

// Visibility test helper
bool dispatchShadowRay(ShadingData sd, float3 toLight, float distanceToLight) {
    // Create a DXR 1.1 query object to trace a ray (the <1> means use alpha testing)
    SceneRayQuery<1> rayQuery;
    const Ray ray = Ray(sd.computeNewRayOrigin(), toLight, 0.f, distanceToLight * kShadowRayEpsilon);
    return rayQuery.traceVisibilityRay(ray, RAY_FLAG_NONE, 0xff);
}
