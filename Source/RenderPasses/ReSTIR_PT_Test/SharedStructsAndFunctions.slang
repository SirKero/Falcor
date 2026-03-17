#pragma once
#include "Utils/Math/MathConstants.slangh"

import Scene.RaytracingInline;
import Utils.Sampling.SampleGenerator;
import Utils.Color.ColorHelpers;
import Utils.Math.MathHelpers;
import Rendering.Materials.IsotropicGGX;
import Rendering.Materials.Fresnel;

static const float kShadowRayEpsilon = 0.98f;
static const float kDeltaRoughnessThreshold = 0.08; // see StandardBSDF.slang kMinGGXAlpha. Everything under this value is considered a delta event

static const int kLobeIsDelta = 0;
static const int kLobeIsDiffuse = 1;
static const int kLobeIsSpecular = 2;

//
// Structs
//

enum ReservoirPathFlags : uint {
    endIsNee = 0x10000,                 // 1<<16
    isNee = 0x20000,                    // 1<<17
    isScatter = 0x40000,                // 1<<18
    isEnvMapMiss = 0x80000,             // 1<<19
    hasNoReconnectionSurface = 0x100000, // 1<<20
    isReconnectionPath = 0x200000,       // 1<<21
    isNeeAfterReconnection = 0x400000,   // 1<<22
    firstHitIsDelta = 0x800000            // 1<<23
}

struct ReservoirFlags {
    uint flags;

    __init() {
        flags = 0;
    }

    //Replaces path flag. Assumes that it is already or'ed
    [mutating]
    void setReservoirPathFlags(uint pathFlag) {
        flags &= 0xFFFF; // Clear all flag bits
        flags |= pathFlag & (~0xFFFF);
    }

    property uint pathLength {
        get { return flags & 0xFF; }
        set {
            flags &= ~0xFF; // Clear lower bits
            flags |= (newValue & 0xFF);
        }
    }

    property uint rcPathLength {
        get { return (flags & 0xFF00)>>8; }
        set {
            flags &= ~0xFF00; // Clear bits
            flags |= (newValue << 8) & 0xFF00;
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

    property bool isNeeAfterReconnection {
        get { return (flags & (uint)ReservoirPathFlags::isNeeAfterReconnection) > 0; }
        set {
            flags &= ~(uint)ReservoirPathFlags::isNeeAfterReconnection; // Clear bit
            flags |= (newValue ? (uint)ReservoirPathFlags::isNeeAfterReconnection : 0);
        }
    }

    property bool firstHitIsDelta {
        get { return (flags & (uint)ReservoirPathFlags::firstHitIsDelta) > 0; }
        set {
            flags &= ~(uint)ReservoirPathFlags::firstHitIsDelta; // Clear bit
            flags |= (newValue ? (uint)ReservoirPathFlags::firstHitIsDelta : 0);
        }
    }
}

// Reservoir; Size: 112 Byte (28 floats)
struct ReservoirPT
{
    SampleGenerator sgPathDirections; //Sample Generator for random direction (float4)

    SampleGenerator sgRCNee;    //For replaying NEE decisions

    PackedHitInfo packedSampleSurface;      // (Packed) Sample Surface

    float jacobianDeterminant;       //(stored) jacobian determinant (at rc vertex)
    ReservoirFlags flags;            // path length and flags
    float2 packedSampleWo;                

    float3 F;                       //Complete radiance of the path
    uint c;                         //Confidence Weight

    float3 rcThp;                   //THP after reconnection
    float weight;                   //Unbiased contribution weight

    float3 thp;                     // Thp until the reconnection surface
    float jacobianOutgoing;         //Jacobian outgoing (next hit from sample)
        
    __init() {
        sgPathDirections = SampleGenerator(uint2(0), 0);
        sgRCNee = SampleGenerator(uint2(0), 0);
        packedSampleSurface = {};
        jacobianDeterminant = -1;
        packedSampleWo = float2(0);
        flags = ReservoirFlags();
        F = float3(0);
        c = 1;
        rcThp = float3(0);
        thp = float3(1);
        weight = 0.0;
        jacobianOutgoing = 1;
        rcPathLength = 0xFF;
    }

    bool isValid() {
        return weight > 0 &&jacobianDeterminant > 0 && jacobianDeterminant > 0;
    }
       
    property uint pathLength {
        get { return flags.pathLength; }
        set { flags.pathLength = newValue;}
    }

    property uint rcPathLength {
        get { return flags.rcPathLength; }
        set { flags.rcPathLength = newValue;}
    }

    property float3 sampleWo {
        get { return oct_to_ndir_snorm(packedSampleWo);}
        set { packedSampleWo = ndir_to_oct_snorm(newValue);}
    }
}

// Retraced Surface Struct 48 Byte (12 floats)
struct RetracedSurface {
    PackedHitInfo rcSurface;    // Suface to reconnect to the reservoir sample
    float3 rcViewDir;           // View direction at the reconnection surface
    uint pathFlags;
    float3 thp; // Thp until the reconnection surface
    float jacobianDeterminant;

    __init() {
        rcSurface = {};
        rcViewDir = float3(0);
        pathFlags = 0;
        thp = float3(1);
        jacobianDeterminant = 1;
    }

    bool isValid() {
        return pathFlags > 0;
    }
}

// Helper for packed path length
struct PackedPathLength
{
    uint data;

    property uint pathLength {
        get { return data & 0xFF; }
        set {
            data &= ~0xFF;
            data |= newValue & 0xFF;
        }
    }

    property uint deltaBounces {
        get { return (data >> 8) & 0xFF; }
        set {
            data &= ~0xFF00;
            data |= (newValue & 0xFF) << 8;
        }
    }

    property uint diffuseBounces {
        get { return (data >> 16) & 0xFF; }
        set {
            data &= ~0xFF0000;
            data |= (newValue & 0xFF) << 16;
        }
    }

    property uint specularBounces {
        get { return (data >> 24) & 0xFF; }
        set {
            data &= ~0xFF000000;
            data |= (newValue & 0xFF) << 24;
        }
    }

    __init() {
        data = 0;
    }

    // Compare path with max path length
    // Returns true if max path length was not reached
    bool comparePathLengts(PackedPathLength max) {
        bool valid = true;
        valid &= deltaBounces < max.deltaBounces;
        valid &= specularBounces < max.specularBounces;
        valid &= diffuseBounces < max.diffuseBounces;
        return valid;
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

inline void updatePathLength(inout PackedPathLength packedPathLength, int lobeType)
{
    if (lobeType == kLobeIsDelta)
        packedPathLength.deltaBounces = packedPathLength.deltaBounces + 1;
    else if (lobeType == kLobeIsDiffuse)
        packedPathLength.diffuseBounces = packedPathLength.diffuseBounces + 1;
    else // Specular
        packedPathLength.specularBounces = packedPathLength.specularBounces + 1;
}

inline int getLobeType(BSDFSample bsdfSample) {
    int lobeType = -1;
    if (bsdfSample.isLobe(LobeType::Delta))
        lobeType = kLobeIsDelta;
    else if (bsdfSample.isLobe(LobeType::Diffuse))
        lobeType = kLobeIsDiffuse;
    else // Specular
        lobeType = kLobeIsSpecular;
    return lobeType;
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

// Load in shading data from hit and previous hit position
ShadingData loadShadingDataWithPrevHit(const HitInfo hit, const float3 prevPosW, const ITextureSampler lod)
{
    const TriangleHit triangleHit = hit.getTriangleHit();
    VertexData v = gScene.getVertexData(triangleHit);
    uint materialID = gScene.getMaterialID(triangleHit.instanceID);
    float3 dir = normalize(prevPosW - v.posW);
    ShadingData sd = gScene.materials.prepareShadingData(v, materialID, dir, lod);

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
