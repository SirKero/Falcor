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

// Reservoir; Size: 104 Byte (26 floats)
struct ReservoirPT
{
    PackedHitInfo reconnectionSurface; //(Packed) Surface which reuses the sample

    float3 samplePosW;                 // Sample PosW
    float jacobianDeterminant;         //(stored) jacobian determinant

    float3 sampleFaceN;              // Sample Face Normal
    uint pathLength;             //rng generator start pixel

    float3 sampleRadiance;          //Radiance at the sample point
    uint rngSeed;                   //RNG seed used to create this sample

    float3 reconnectionSurfaceIncomingDir; // Incoming direction for the reconnection surface
    uint c;                //Path length until the connectable surface is reached

    float3 reconnectionThp;         //Thp until reconnection 
    float wSum;                     //Unbiased contribution weight

    uint2 rngPixel;

    __init() {
        reconnectionSurface = {};
        samplePosW = float3(0);
        sampleFaceN = float3(0);
        sampleRadiance = float3(0);
        rngSeed = 0;
        reconnectionSurfaceIncomingDir = float3(0);
        reconnectionThp = float3(1);
        c = 1;
        pathLength = 0;
        wSum = 0.0;
        jacobianDeterminant = -1;
        rngPixel = uint2(0);
    }

    bool isValid() {
        return jacobianDeterminant > 0;
    }

    /*
    property uint2 rngPixel {
        get { return uint2(rngPixelPacked & 0xFFFF, (rngPixelPacked >> 16) & 0xFFFF); }
        set {
            rngPixelPacked = newValue.x & 0xFFFF;
            rngPixelPacked |= (newValue.y & 0xFFFF) << 16;
        }
    }

    property uint c {
        get { return cAndPathLength & 0xFFFF; }
        set {
            cAndPathLength &= 0xFFFF0000; //Clear lower bits
            cAndPathLength |= (newValue & 0xFFFF);
        }
    }

    property uint pathLength {
        get { return (cAndPathLength >> 16) & 0xFFFF; }
        set {
            cAndPathLength &= 0xFFFF; // Clear upper bits
            cAndPathLength |= (newValue & 0xFFFF) << 16;
        }
    }
    */
}

//
// Functions
//

// Helper for the ReSTIR screen size buffers
uint index2Dto1D(uint2 index, uint frameDimX) {
    return index.x + index.y * frameDimX;
}

// Helper for linearized indices to 2d
uint2 index1Dto2D(uint index, uint frameDimX) {
    return uint2(index % frameDimX, index / frameDimX);
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

// Visibility test helper
bool dispatchShadowRay(ShadingData sd, float3 toLight, float distanceToLight) {
    // Create a DXR 1.1 query object to trace a ray (the <1> means use alpha testing)
    SceneRayQuery<1> rayQuery;
    const Ray ray = Ray(sd.computeNewRayOrigin(), toLight, 0.f, distanceToLight * kShadowRayEpsilon);
    return rayQuery.traceVisibilityRay(ray, RAY_FLAG_NONE, 0xff);
}
