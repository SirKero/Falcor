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

enum ReservoirPathFlags : uint {
    endIsNee = 0x100,                   //1<<9
    isNee = 0x200,                      // 1<<10
    isScatter = 0x400,                  // 1<<11
    isEnvMapMiss = 0x800,               // 1<<12
    hasNoReconnectionSurface = 0x1000,  //1<<13
    isReconnectionPath = 0x2000,        //1<<14
}

struct ReservoirFlags {
    uint flags;

    __init() {
        flags = 0;
    }

    //Replaces path flag. Assumes that it is already or'ed
    [mutating]
    void setReservoirPathFlags(uint pathFlag) {
        flags &= ~0xFF00; // Clear all flag bits
        flags |= pathFlag;
    }

    property uint pathLength {
        get { return flags & 0xFF; }
        set {
            flags &= ~0xFF; // Clear lower bits
            flags |= (newValue & 0xFF);
        }
    }

    property bool endIsNee {
        get { return (flags & (uint)ReservoirPathFlags::endIsNee) > 0; }
        set {
            flags &= ~ (uint)ReservoirPathFlags::endIsNee; // Clear bit
            flags |= (newValue ? (uint)ReservoirPathFlags::endIsNee : 0);
        }
    }

    property bool isNee {
        get { return (flags & (uint)ReservoirPathFlags::isNee) > 0; }
        set {
            flags &= ~(uint)ReservoirPathFlags::isNee; // Clear bit
            flags |= (newValue ? (uint)ReservoirPathFlags::isNee : 0);
        }
    }

    property bool isScatter {
        get { return (flags & (uint)ReservoirPathFlags::isScatter) > 0; }
        set {
            flags &= ~(uint)ReservoirPathFlags::isScatter; // Clear bit
            flags |= (newValue ? (uint)ReservoirPathFlags::isScatter : 0);
        }
    }

    property bool isEnvMapMiss {
        get { return (flags & (uint)ReservoirPathFlags::isEnvMapMiss) > 0; }
        set {
            flags &= ~(uint)ReservoirPathFlags::isEnvMapMiss; // Clear bit
            flags |= (newValue ? (uint)ReservoirPathFlags::isEnvMapMiss : 0);
        }
    }

    property bool hasNoReconnectionSurface {
        get { return (flags & (uint)ReservoirPathFlags::hasNoReconnectionSurface) > 0; }
        set {
            flags &= ~(uint)ReservoirPathFlags::hasNoReconnectionSurface; // Clear bit
            flags |= (newValue ? (uint)ReservoirPathFlags::hasNoReconnectionSurface : 0);
        }
    }
}

// Reservoir; Size: 112 Byte (28 floats)
struct ReservoirPT
{
    SampleGenerator sgPathDirections; //Sample Generator for random direction (float4)

    SampleGenerator sgRCNee;    //For replaying NEE decisions

    float3 samplePosW;                 // Sample PosW
    float jacobianDeterminant;         //(stored) jacobian determinant

    float3 sampleFaceN;             // Sample Face Normal
    ReservoirFlags flags;           //path length and flags

    float3 F;                       //Complete radiance of the path
    uint c;                         //Confidence Weight

    float3 rcThp;                   //THP after reconnection
    float weight;                   //Unbiased contribution weight

    float3 thp;                     // Thp until the reconnection surface
    uint _pad;                      //Pading
        
    __init() {
        sgPathDirections = SampleGenerator(uint2(0), 0);
        sgRCNee = SampleGenerator(uint2(0), 0);
        samplePosW = float3(0);
        jacobianDeterminant = -1;
        sampleFaceN = float3(0);
        flags = ReservoirFlags();
        F = float3(0);
        c = 1;
        rcThp = float3(0);
        thp = float3(1);
        weight = 0.0;
        _pad = 0;
    }

    bool isValid() {
        return jacobianDeterminant > 0;
    }
       
    property uint pathLength {
        get { return flags.pathLength; }
        set { flags.pathLength = newValue;}
    }
}

// Retraced Surface Struct 48 Byte (12 floats)
struct RetracedSurface {
    PackedHitInfo rcSurface;    // Suface to reconnect to the reservoir sample
    float3 rcViewDir;           // View direction at the reconnection surface
    uint pathFlags;
    float3 thp; // Thp until the reconnection surface
    uint _pad;

    __init() {
        rcSurface = {};
        rcViewDir = float3(0);
        pathFlags = 0;
        thp = float3(1);
        _pad = 0;
    }

    bool isValid() {
        return pathFlags > 0;
    }
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

/* Evaluate MIS weight
   \param[in] n0 Number of samples taken from the first sampling strategy.
    \param[in] p0 Pdf for the first sampling strategy.
    \param[in] n1 Number of samples taken from the second sampling strategy.
    \param[in] p1 Pdf for the second sampling strategy.
    \return Weight for the contribution from the first strategy (p0).
*/
float evalMIS(float n0, float p0, float n1, float p1)
{
    // Currently only balance heuristic
    float q0 = n0 * p0;
    float q1 = n1 * p1;
    float sum = (q0 + q1);
    if(sum > 0)
        return q0 / (q0 + q1);
    else
        return 0;
}
