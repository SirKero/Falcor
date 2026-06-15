#include "Utils/Math/MathConstants.slangh"

import Scene.RaytracingInline;
import Utils.Sampling.SampleGenerator;
import Utils.Color.ColorHelpers;
import Utils.Math.MathHelpers;
import Rendering.Materials.IsotropicGGX;
import Rendering.Materials.Fresnel;

static const float kShadowRayEpsilon = 0.98;
static const uint kSplattingGlobalCounterElement = 0; //Index for the platting global counter, that counts the total number of elements
static const uint kSplattingGlobalCounterPrefixSum = 1; //Index for the platting global counter, used for the prefix sum to determine the offsets

//
//Enums
//

enum class PhotonType // : uint32_t
{
    Global = 0,
    Caustic = 1
};

enum ReservoirPathFlags : uint {
    firstHitIsDelta = 0x100,               // 1<<8
    hasNoReconnectionSurface = 0x200,      // 1<<9
    isFinalGather = 0x400,                 // 1<<10
    isEmissiveHit = 0x800,                 // 1<<11
    isEnvMapHit = 0x1000,                  // 1<<12
    isRadianceEstimate = 0x2000,           // 1<<13
    isCaustic = 0x4000,                    // 1<<14
    isNEE = 0x8000,                        // 1<<15
}

//
// Structs
//

//Photon representation
struct PhotonData {
    float3 flux;                          // Energy of the photon
    uint packedSGStartPixelAndPathLength; // Packed path lenght (upper 8 bits) and sample generator initial pixel (for photon shift)
    float3 dir;                           // Incoming direction
    uint sgSeed;                          // Seed used to initialize the sample generator (for photon shift)
    float3 faceN;                         // World face normal of the hit surface
    uint _pad;

    __init() {
        this.dir = float3(0);
        this.faceN = float3(0, 1, 0);
        this.flux = float3(0);
        this.packedSGStartPixelAndPathLength = 0;
        this.sgSeed = 0;
        this._pad = 0;
    }

    //Helper to get path length
    property uint pathLenght
    {
        get { return (packedSGStartPixelAndPathLength >> 24) & 0xFF;}
        set {
            packedSGStartPixelAndPathLength &= 0xFFFFFF; // Clear upper 8 bits
            packedSGStartPixelAndPathLength |= (newValue.x & 0xFF) << 24;
        }
    }

    // Helper to get the start pixel for recreating the sample generator (for photon shift)
    property uint2 sgStartPixel
    {
        get { return uint2(packedSGStartPixelAndPathLength & 0xFFF, (packedSGStartPixelAndPathLength >> 12) & 0xFFF);}
        set {
            packedSGStartPixelAndPathLength &= 0xFF000000; //Clear lower 24 bits
            packedSGStartPixelAndPathLength |= (newValue.x & 0xFFF) | ((newValue.y & 0xFFF) << 12);
        }
    }

    //Packs data for retracing photon paths
    uint2 packPhotonRetraceData()
    {
        return uint2(packedSGStartPixelAndPathLength, sgSeed);
    }
}

struct ReservoirFlags {
    uint flags;

    __init() {
        flags = 0;
    }

    // Replaces path flag. Assumes that it is already or'ed
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

    property bool firstHitIsDelta {
        get { return (flags & (uint)ReservoirPathFlags::firstHitIsDelta) > 0; }
        set {
            flags &= ~(uint)ReservoirPathFlags::firstHitIsDelta; // Clear bit
            flags |= (newValue ? (uint)ReservoirPathFlags::firstHitIsDelta : 0);
        }
    }

    property bool hasNoReconnectionSurface {
        get { return (flags & (uint)ReservoirPathFlags::hasNoReconnectionSurface) > 0; }
        set {
            flags &= ~(uint)ReservoirPathFlags::hasNoReconnectionSurface; // Clear bit
            flags |= (newValue ? (uint)ReservoirPathFlags::hasNoReconnectionSurface : 0);
        }
    }

    property bool isFinalGather {
        get { return (flags & (uint)ReservoirPathFlags::isFinalGather) > 0; }
        set {
            flags &= ~(uint)ReservoirPathFlags::isFinalGather; // Clear bit
            flags |= (newValue ? (uint)ReservoirPathFlags::isFinalGather : 0);
        }
    }

    property bool isEmissiveHit {
        get { return (flags & (uint)ReservoirPathFlags::isEmissiveHit) > 0; }
        set {
            flags &= ~(uint)ReservoirPathFlags::isEmissiveHit; // Clear bit
            flags |= (newValue ? (uint)ReservoirPathFlags::isEmissiveHit : 0);
        }
    }

    property bool isEnvMapHit {
        get { return (flags & (uint)ReservoirPathFlags::isEnvMapHit) > 0; }
        set {
            flags &= ~(uint)ReservoirPathFlags::isEnvMapHit; // Clear bit
            flags |= (newValue ? (uint)ReservoirPathFlags::isEnvMapHit : 0);
        }
    }

    property bool isRadianceEstimate {
        get { return (flags & (uint)ReservoirPathFlags::isRadianceEstimate) > 0; }
        set {
            flags &= ~(uint)ReservoirPathFlags::isRadianceEstimate; // Clear bit
            flags |= (newValue ? (uint)ReservoirPathFlags::isRadianceEstimate : 0);
        }
    }

    property bool isCaustic {
        get { return (flags & (uint)ReservoirPathFlags::isCaustic) > 0; }
        set {
            flags &= ~(uint)ReservoirPathFlags::isCaustic; // Clear bit
            flags |= (newValue ? (uint)ReservoirPathFlags::isCaustic : 0);
        }
    }

    property bool isNEE {
        get { return (flags & (uint)ReservoirPathFlags::isNEE) > 0; }
        set {
            flags &= ~(uint)ReservoirPathFlags::isNEE; // Clear bit
            flags |= (newValue ? (uint)ReservoirPathFlags::isNEE : 0);
        }
    }
}

//Path Reservoir; Size: 96 Byte (24 floats)
struct PathReservoir {
    SampleGenerator sgPathDirections; // Sample Generator for random direction (float4)

    uint4 sampleData;           // Sample date used for sample position,radius or RNG seed in NEE

    float jacobian;            //(stored) jacobian determinant at the first hit
    ReservoirFlags flags;      // path length and flags
    float2 packedSampleNormal;

    float3 F;                  // Complete radiance of the path
    uint c;                    // Confidence Weight

    float3 fgRadiance;         // Radiance estimate for the final gather point. Can be reused
    float weight;              // Unbiased contribution weight

    uint2 packedPhotonRetraceData;   // Packed sample generator and path length for photon retrace (uint2(PackedPixel,Seed); see PhotonData)
    uint2 packedGuidingData;   // Packed data needed for guiding. Unused if guiding is disabled 

    __init() {
        sgPathDirections = SampleGenerator(uint2(0), 0);
        sampleData = 0;
        jacobian = 1;
        packedSampleNormal = float2(0);
        flags = ReservoirFlags();
        F = float3(0);
        c = 1;
        fgRadiance = float3(0);
        weight = 0.0;
        packedPhotonRetraceData = uint2(0);
        packedGuidingData = uint2(0);
    }

    //Packed properties helpers

    property uint pathLength {
        get { return flags.pathLength; }
        set { flags.pathLength = newValue;}
    }

    property float3 samplePosW {
        get { return float3(asfloat(sampleData.x), asfloat(sampleData.y), asfloat(sampleData.z));}
        set { sampleData.xyz = uint3(asuint(newValue.x), asuint(newValue.y), asuint(newValue.z));}
    }

    property float sampleRadius {
        get { return asfloat(sampleData.w);}
        set { sampleData.w = asuint(newValue);}
    }

    property float3 sampleNormal {
        get { return oct_to_ndir_snorm(packedSampleNormal);}
        set { packedSampleNormal = ndir_to_oct_snorm(newValue);}
    }

    //Functions
    bool isValid() {
        return weight > 0 && jacobian > 0 && any(F > 0);
    }
}

// Reservoir for a CausticSample 112B
struct CausticReservoir {
    PackedHitInfo sampleSurface;    // HitSample 16B

    float3 sampleSurfaceView;       // Incoming View
    float wSum;                     // W and wSum

    float3 photonRadiance;          // Radiance
    float subPixelJacobian;         // Sub pixel jacobian for reprojection

    uint2 packedPhotonRetraceData;  // Packed sample generator and path length for photon retrace (uint2(PackedPixel,Seed); see PhotonData)
    uint c;                         // Confidence weight
    float targetFunction;           // Target Function for the current reservoir

    __init() {
        sampleSurface = {};
        sampleSurfaceView = float3(0);
        photonRadiance = float3(0);
        wSum = 0;
        c = 0;
        packedPhotonRetraceData = uint2(0);
        subPixelJacobian = 0;
        targetFunction = 0;
    }

    // Valid check
    bool isValid() {
        return any(photonRadiance > 0) && wSum > 0 && subPixelJacobian > 0;
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

    property uint diffuseBounces {
        get { return (data >> 8) & 0xFF; }
        set {
            data &= ~0xFF00;
            data |= (newValue & 0xFF) << 8;
        }
    }

    property uint specularBounces {
        get { return (data >> 16) & 0xFF; }
        set {
            data &= ~0xFF0000;
            data |= (newValue & 0xFF) << 16;
        }
    }

    property uint deltaBounces {
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

/** Creates a sample generator from packed photon sg data (see PhotonData struct)
  * \param[in] Packed photon retrace data
  * \return the sample generator that was used to create this photon path
*/
SampleGenerator createPhotonSGFromPacked(uint2 packedPhotonRetraceData)
{
    uint2 pixel = uint2(packedPhotonRetraceData.x & 0xFFF, (packedPhotonRetraceData.x >> 12) & 0xFFF); // See PhotonData->sgStartPixel
    return SampleGenerator(pixel, packedPhotonRetraceData.y);
}

/** Extracts the path lenght from the packed retrace data
 * \param[in] Packed photon retrace data
 * \return photon path length
 */
uint getPhotonPathLengthFromPacked(uint2 packedPhotonRetraceData)
{
    return (packedPhotonRetraceData.x >> 24) & 0xFF;
}

//Load in shading data from hit and direction
ShadingData loadShadingData(const HitInfo hit, const float3 rayDir, const ITextureSampler lod)
{
    const TriangleHit triangleHit = hit.getTriangleHit();
    VertexData v = gScene.getVertexData(triangleHit);
    uint materialID = gScene.getMaterialID(triangleHit.instanceID);
    ShadingData sd = gScene.materials.prepareShadingData(v, materialID, rayDir, lod);
    
    return sd;
}

ShadingData loadShadingDataWithPrevHit(const HitInfo hit, const float3 prevPosW, const ITextureSampler lod)
{
    const TriangleHit triangleHit = hit.getTriangleHit();
    VertexData v = gScene.getVertexData(triangleHit);
    uint materialID = gScene.getMaterialID(triangleHit.instanceID);
    float3 dir = normalize(v.posW - prevPosW);
    ShadingData sd = gScene.materials.prepareShadingData(v, materialID, dir, lod);

    return sd;
}


uint index2Dto1D(uint2 index, uint frameDimX) {
    return index.x + index.y * frameDimX;
}

/* Evaluate MIS weight with balance heuristic
   \param[in] n0 Number of samples taken from the first sampling strategy.
    \param[in] p0 Pdf for the first sampling strategy.
    \param[in] n1 Number of samples taken from the second sampling strategy.
    \param[in] p1 Pdf for the second sampling strategy.
    \return Weight for the contribution from the first strategy (p0).
*/
float evalMIS(float n0, float p0, float n1, float p1)
{
    float q0 = n0 * p0;
    float q1 = n1 * p1;
    float sum = (q0 + q1);
    if (sum > 0)
        return q0 / (q0 + q1);
    else
        return 0;
}

// Backprojects to camera with viewProjection matrix
float3 getCameraProjection(float4x4 viewProjection, float3 posW) {
    float4 screenPos = mul(viewProjection, float4(posW, 1));
    screenPos /= screenPos.w;
    screenPos.y *= -1;
    screenPos.xy = screenPos.xy * 0.5 + 0.5; // UV from [-1,1] to [0,1]
    return screenPos.xyz;
}

// Returns the Camera backproject PDF
float getCameraBackprojectPDF(float3 directionToCamera, float distanceToCamera, float3 camForward, float normalizedPixelArea)
{
    const float cosAtCamera = dot(-directionToCamera, camForward);
    return distanceToCamera * distanceToCamera * normalizedPixelArea * pow(cosAtCamera, 3);
}

// Returns the Jacobian determinant for a subpixel location
float getSubpixelLocationJacobian(float dist, float3 toCamera, float3 surfaceN, float3 camForward)
{
    float distSquared = dist * dist;
    float cosNormal = dot(toCamera, surfaceN);
    float cosSensor = dot(-toCamera, camForward);
    return abs(cosNormal / (distSquared)) / abs(pow(cosSensor, 3));
}

bool dispatchShadowRay(ShadingData sd, float3 toLight, float distanceToLight, bool applyEpsilon = true) {
    // Create a DXR 1.1 query object to trace a ray (the <1> means use alpha testing)
    SceneRayQuery<1> rayQuery;
    float distance = applyEpsilon ? distanceToLight * kShadowRayEpsilon : distanceToLight ;
    const Ray ray = Ray(sd.computeNewRayOrigin(), toLight, 0.0, distance);
    return rayQuery.traceVisibilityRay(ray, RAY_FLAG_NONE, 0xff);
}
