#pragma once
#include "Utils/Math/MathConstants.slangh"

#ifndef ANALYTIC_START_INDEX
#define ANALYTIC_START_INDEX 0
#endif

import Scene.RaytracingInline;
import Utils.Sampling.SampleGenerator;
import Utils.Color.ColorHelpers;
import Utils.Geometry.GeometryHelpers;
import Utils.Math.MathHelpers;
import Rendering.Materials.IsotropicGGX;
import Rendering.Materials.Fresnel;

static const uint kAnalyticLightIdxOffset = ANALYTIC_START_INDEX;
static const float kShadowRayEpsilon = 0.98f;
static const float kDeltaRoughnessThreshold = 0.08; // see StandardBSDF.slang kMinGGXAlpha. Everything under this value is considered a delta event

static const uint kSplattingGlobalCounterElement = 0; // Index for the platting global counter, that counts the total number of elements
static const uint kSplattingGlobalCounterPrefixSum = 1; // Index for the platting global counter, used for the prefix sum to determine the offsets

static const uint kAtlasOptimizationMaxMapIndex = 0xFFFF;

enum class PhotonType // : uint32_t
{
    Global = 0,
    Caustic = 1
};

//Flags for the Path Reservoir
enum ReservoirPathFlags : uint {
    firstHitIsDelta = 0x10000,          // 1<<16
    hasNoReconnectionSurface = 0x20000, // 1<<17
    isFinalGather = 0x40000,            // 1<<18
    isEmissiveHit = 0x80000,            // 1<<19
    isEnvMapHit = 0x100000,             // 1<<20
    isRadianceEstimate = 0x200000,      // 1<<21
    isNEE = 0x400000,                   // 1<<22
    isCausticPhoton = 0x800000          // 1<<23
}

//Reservoir flag struct
struct ReservoirFlags {
    uint flags;

    __init() {
        flags = 0;
    }

    // Replaces path flag. Assumes that it is already or'ed
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

    property uint confidence {
        get { return (flags & 0xFF00)>>8; }
        set {
            flags &= ~0xFF00; // Clear bits
            flags |= (newValue & 0xFF) << 8;
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

    property bool isNEE {
        get { return (flags & (uint)ReservoirPathFlags::isNEE) > 0; }
        set {
            flags &= ~(uint)ReservoirPathFlags::isNEE; // Clear bit
            flags |= (newValue ? (uint)ReservoirPathFlags::isNEE : 0);
        }
    }

    property bool isCausticPhoton {
        get { return (flags & (uint)ReservoirPathFlags::isCausticPhoton) > 0; }
        set {
            flags &= ~(uint)ReservoirPathFlags::isCausticPhoton; // Clear bit
            flags |= (newValue ? (uint)ReservoirPathFlags::isCausticPhoton : 0);
        }
    }
}

struct PhotonRetraceData{
    uint startPixelPathLengthData;
    uint startSeed;

    //Start pixel helper for SG
    property uint2 startPixel {
        get { return uint2(startPixelPathLengthData & 0xFFF, (startPixelPathLengthData >> 12) & 0xFFF); }
        set {
            startPixelPathLengthData &= ~0xFFFFFF; // Clear lower 24 bits
            startPixelPathLengthData |= newValue.x & 0xFFF;
            startPixelPathLengthData |= (newValue.y & 0xFFF) << 12;
        }
    }

    //Path length helper
    property uint pathLength {
        get { return (startPixelPathLengthData >> 24) & 0x7F; }
        set {
            startPixelPathLengthData &= ~0x7F000000; // Clear upper 8 bits
            startPixelPathLengthData |= (newValue.x & 0x7F) << 24;
        }
    }

    //Random direction flag helper
    property bool usedRandomDirection {
        get { return (startPixelPathLengthData >> 31) & 0x1; }
        set {
            startPixelPathLengthData &= 0x7FFFFFFF; // Clear upper bit
            if(newValue)
                startPixelPathLengthData |= 1 << 31;
        }
    }

    //Inits
    __init() {
        startPixelPathLengthData = 0;
        startSeed = 0;
    }

    __init(uint2 pixel, uint pathLength , uint seed) {
        this.startPixel = pixel;
        this.pathLength = pathLength;
        this.startSeed = seed;
    }
}

// Photon Data struct 48B (12 floats)
struct PhotonData {
    float3 flux;      // Photon flux
    float guidingPdf; // Guiding PDF used to generate the photon

    float3 dir;         // Photon direction
    int lightIndex;     //Light index used to generate the photon

    float3 normalW;           // Face Normal
    uint packedGuidingPixelsPathLength; // Pixel for the guiding texture

    //Guiding pixels helper
    property uint2 guidingPixel {
        get { return uint2(packedGuidingPixelsPathLength & 0xFFF, (packedGuidingPixelsPathLength >> 12) & 0xFFF); }
        set {
            packedGuidingPixelsPathLength &= ~0xFFFFFF; // Clear lower 24 bits
            packedGuidingPixelsPathLength |= newValue.x & 0xFFF;
            packedGuidingPixelsPathLength |= (newValue.y & 0xFFF) << 12;
        }
    }

    property uint pathLength {
        get { return (packedGuidingPixelsPathLength>>24) & 0xFF; }
        set {
            packedGuidingPixelsPathLength &= ~0xFF000000; // Clear upper bits
            packedGuidingPixelsPathLength |= (newValue & 0xFF)<<24;
        }
    }

    __init() {
        this.dir = float3(0);
        this.normalW = float3(0,1,0);
        this.flux = float3(0);
        this.guidingPdf = 1;
        this.lightIndex = -1;
        this.packedGuidingPixelsPathLength = 0;
    }
}

// Data for the FG sample 64B
struct FGSampleData {
    float3 posW; // Position
    float normalX;
    float3 radianceOut; // Radiance
    float normalY;
    float3 sampleView; // Incoming View
    float normalZ;

    __init() {
        posW = float3(0);
        normalX = 0;
        normalY = 1;
        normalZ = 0;
        radianceOut = float3(0);
        sampleView = float3(0);
    }

    // Normal helper
    property float3 normal {
        get { return float3(normalX, normalY, normalZ); }
        set {
            normalX = newValue.x;
            normalY = newValue.y;
            normalZ = newValue.z;
        }
    }
}

// Reservoir for a Final Gather Sample 128B
struct ReservoirFG {
    PackedHitInfo sampleSurface; // HitSample 16B

    float3 thp;                  // Throughput used at the end
    float targetFunction;        // Store target function

    FGSampleData sampleData;     // Data of the sample

    float wSum;                  // W and wSum
    uint c;                      // Confidence weight
    float jacobianDeterminant;   // Jacobian determinant to the current sample
    uint pathLength;             // Path Length

    int lightIndex;            // Guiding
    uint packedGuidingPixels;  // Pixel for the guiding texture
    uint2 _pad;                // Padding

    __init() {
        sampleSurface = {};
        thp = float3(1);
        targetFunction = 0;
        sampleData = FGSampleData();
        wSum = 0;
        c = 1;
        pathLength = 0;
        jacobianDeterminant = -1.0;
        lightIndex = -1;
        packedGuidingPixels = 0;
        _pad = uint2(0);
    }

    //Guiding pixels helper
    property uint2 guidingPixels {
        get { return uint2(packedGuidingPixels & 0xFFFF, (packedGuidingPixels >> 16) & 0xFFFF); }
        set {
            packedGuidingPixels = newValue.x & 0xFFFF;
            packedGuidingPixels |= (newValue.y & 0xFFFF) << 16;
        }
    }

    // Valid check
    bool isValid() {
        return jacobianDeterminant >= 0;
    }
}

// Reservoir for a CausticSample 128B
struct ReservoirCaustic {
    PackedHitInfo sampleSurface; // HitSample 16B

    float3 thp;                  // Throughput used at the end
    float targetFunction;        // Store target function

    float3 sampleSurfaceView;    // Incoming View
    float photonDirX;

    float3 photonPosW; // Position
    float photonDirY;

    float3 photonRadiance; // Radiance
    float photonDirZ;

    ReservoirFlags flags; // Flags, path length and confidence
    float wSum;           // W and wSum
    float subPixelJacobian; // Sub pixel jacobian for reprojection
    int lightIndex;           // Guiding

    uint packedGuidingPixels; //(Packed) Pixel for the guiding texture
    PhotonRetraceData photonRetraceData; // Photon data for retrace
    float photonGuidingPdf;                    // Guiding PDF for retracing

    __init() {
        sampleSurface = {};
        thp = float3(1);
        targetFunction = 0;
        sampleSurfaceView = float3(0);
        photonDirX = 0;
        photonPosW = float3(0);
        photonDirY = 0;
        photonRadiance = float3(0);
        photonDirZ = 0;
        wSum = 0;
        flags = ReservoirFlags();
        photonGuidingPdf = 0;
        subPixelJacobian = 0;
        lightIndex = -1;
        packedGuidingPixels = 0;
        photonRetraceData = PhotonRetraceData();
    }

    // Path length helper
    property uint pathLength {
        get { return flags.pathLength; }
        set { flags.pathLength = newValue;}
    }

    // Confidence helper
    property uint c {
        get { return flags.confidence; }
        set { flags.confidence = newValue;}
    }

    // Photon dir helper
    property float3 photonDir {
        get { return float3(photonDirX, photonDirY, photonDirZ); }
        set {
            photonDirX = newValue.x;
            photonDirY = newValue.y;
            photonDirZ = newValue.z;
        }
    }

    // Guiding pixels helper
    property uint2 guidingPixels {
        get { return uint2(packedGuidingPixels & 0xFFFF, (packedGuidingPixels >> 16) & 0xFFFF); }
        set {
            packedGuidingPixels = newValue.x & 0xFFFF;
            packedGuidingPixels |= (newValue.y & 0xFFFF) << 16;
        }
    }

    // Valid check
    bool isValid() {
        return any(photonRadiance > 0);
    }
}

// Path Reservoir
// Path Reservoir; Size: 112 Byte (28 floats)
struct PathReservoir {
    SampleGenerator sgPathDirections;    // Sample Generator for random direction (float4)
    SampleGenerator sgNeeLightSelection; // Sample Generator for light selection (float4), TODO optimize and fuse with samplePosW/Radius

    float3 samplePosW;  // Sample Position
    float sampleRadius; // For radiance estimate

    float jacobian;       //(stored) jacobian determinant at the first hit
    ReservoirFlags flags; // path length and flags
    float2 packedSampleNormal;

    float3 F;          // Complete radiance of the path
    float weight;      // Unbiased contribution weight

    float3 photonFlux;        // Flux of the selected photon
    int lightIndex;           // Guiding

    uint packedGuidingPixels;            //(Packed) Pixel for the guiding texture
    float photonGuidingPdf;                    // Guiding PDF for photon retracing
    PhotonRetraceData photonRetraceData; //Photon data for retrace

    property uint pathLength {
        get { return flags.pathLength; }
        set { flags.pathLength = newValue;}
    }

    property uint c {
        get { return flags.confidence; }
        set { flags.confidence = newValue;}
    }

    property float3 sampleNormal {
        get { return oct_to_ndir_snorm(packedSampleNormal);}
        set { packedSampleNormal = ndir_to_oct_snorm(newValue);}
    }

    // Guiding pixels helper
    property uint2 guidingPixels {
        get { return uint2(packedGuidingPixels & 0xFFFF, (packedGuidingPixels >> 16) & 0xFFFF); }
        set {
            packedGuidingPixels = newValue.x & 0xFFFF;
            packedGuidingPixels |= (newValue.y & 0xFFFF) << 16;
        }
    }

    __init() {
        sgPathDirections = SampleGenerator(uint2(0), 0);
        sgNeeLightSelection = SampleGenerator(uint2(0), 0);
        samplePosW = float3(0);
        sampleRadius = 0;
        jacobian = 1;
        packedSampleNormal = float2(0);
        flags = ReservoirFlags();
        c = 1;
        F = float3(0);
        photonGuidingPdf = 1;
        photonFlux = float3(0);
        weight = 0.0;
        lightIndex = -1;
        packedGuidingPixels = 0;
        photonRetraceData = PhotonRetraceData();
    }

    bool isValid() {
        return weight > 0 && jacobian > 0 && any(F > 0);
    }
}

// Infos on retraced path 16 byte (4 floats)
struct RetracedPath
{
    float3 F;
    float jacobian;

    __init()
    {
        F = float3(0);
        jacobian = 1;
    }

    __init(float4 data)
    {
        F = data.xyz;
        jacobian = data.w;
    }

    float4 pack()
    {
        return float4(F, jacobian);
    }
}

// Helper struct to generate a photon form the lightSources
struct PhotonLightSample {
    float3 posW;
    float rndX;

    float3 normal;
    float rndY;

    float3 flux;
    uint lightIdx;

    uint2 guidingPixels;
    float guidingPdf;
    bool useRandomLightDirection;

    __init() {
        posW = float3(0, 0, 0);
        normal = float3(0, 0, 0);
        flux = float3(0, 0, 0);
        lightIdx = 0;
        rndX = 0.0;
        rndY = 0.0;
        guidingPixels = uint2(0, 0);
        guidingPdf = 1.0;
        useRandomLightDirection = false;
    }
};

//Helper for packed path length
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

//Packing helper. S
uint packPhotonRetraceData(uint2 startPixel, uint pathLength, bool usedRandomDirection){
    uint newData = 0;
    newData |= startPixel.x & 0xFFF;
    newData |= (startPixel.y & 0xFFF) << 12;
    newData |= (pathLength & 0x7F) << 24;
    uint directionFlag = usedRandomDirection ? 1 : 0;
    newData |= directionFlag << 31;
    return newData;
}

//Start seed for photon direction sample generator
uint getStartSeedPhotonDirSG(uint frameCount, uint rngNumPasses){
    return frameCount * rngNumPasses + (rngNumPasses - 3);
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

float getContinuationProbablity(BSDFProperties props)
{
    //Delta events are not accurately captured by the reflection/transmission albedos. Delta has a probability of 1 anyway.
    if (props.roughness <= kDeltaRoughnessThreshold)
        return 1.0;

    float3 totalMaterialEnergie = props.diffuseReflectionAlbedo + props.diffuseTransmissionAlbedo + props.specularReflectionAlbedo + props.specularTransmissionAlbedo;
    return clamp(luminance(totalMaterialEnergie), 0.0, 1.0);
}

// Checks if the ray start point is inside the sphere.
bool hitSphere(const float3 center, const float radius, const float3 p)
{
    float3 radiusTest = p - center;
    return dot(radiusTest, radiusTest) < radius * radius;
}

// Adaptive Radius helper
float adaptiveRadius(float distanceToCamera, float normalizedPixelDiagonal, float radiusScale = 1.0)
{
    float adaptiveRadius = (normalizedPixelDiagonal * distanceToCamera) / 2.0;
    return adaptiveRadius * radiusScale;
}

//Helper for the ReSTIR screen size buffers
uint index2Dto1D(uint2 index, uint frameDimX) {
    return index.x + index.y * frameDimX;
}

// Helper for linearized indices to 2d
uint2 index1Dto2D(uint index, uint frameDimX) {
    return uint2(index % frameDimX, index / frameDimX);
}

//Backprojects to camera with viewProjection matrix
float3 getCameraProjection(float4x4 viewProjection, float3 posW) {
    float4 screenPos = mul(viewProjection, float4(posW, 1));
    screenPos /= screenPos.w;
    screenPos.y *= -1;
    screenPos.xy = screenPos.xy * 0.5 + 0.5; // UV from [-1,1] to [0,1]
    return screenPos.xyz;
}

//Returns the Camera backproject PDF
float getCameraBackprojectPDF(float3 directionToCamera, float distanceToCamera, float3 camForward, float normalizedPixelArea)
{
    const float cosAtCamera = dot(-directionToCamera, camForward);
    return distanceToCamera * distanceToCamera * normalizedPixelArea * pow(cosAtCamera, 3);
}

//Returns the Jacobian determinant for a subpixel location
float getSubpixelLocationJacobian(float dist, float3 toCamera, float3 surfaceN, float3 camForward)
{
    float distSquared = dist * dist;
    float cosNormal = dot(toCamera, surfaceN);
    float cosSensor = dot(-toCamera, camForward);
    return abs(cosNormal / (distSquared)) / abs(pow(cosSensor, 3));
}

//Visibility test helper
bool dispatchShadowRay(ShadingData sd, float3 toLight, float distanceToLight) {
    // Create a DXR 1.1 query object to trace a ray (the <1> means use alpha testing)
    SceneRayQuery<1> rayQuery;
    const Ray ray = Ray(sd.computeNewRayOrigin(), toLight, 0.f, distanceToLight * kShadowRayEpsilon);
    return rayQuery.traceVisibilityRay(ray, RAY_FLAG_NONE, 0xff);
}

// Visibility test helper
bool dispatchShadowRay(float3 rayOrigin, float3 toLight, float distanceToLight) {
    // Create a DXR 1.1 query object to trace a ray (the <1> means use alpha testing)
    SceneRayQuery<1> rayQuery;
    const Ray ray = Ray(rayOrigin, toLight, 0.f, distanceToLight * kShadowRayEpsilon);
    return rayQuery.traceVisibilityRay(ray, RAY_FLAG_NONE, 0xff);
}

//Used to evaluate the final gather reservoir at the end. Visibility ray and jacobian determinant
//are not needed due to MIS during resampling
float3 evaluateFinalGatherSample(ReservoirFG r, ShadingData sd, IMaterialInstance mi, inout SampleGenerator sg) {
    float3 Li = float3(0);

    float3 toLight = r.sampleData.posW - sd.posW;
    float dist = length(toLight);
    toLight /= dist;
    Li = r.sampleData.radianceOut;
    Li *= mi.eval(sd, toLight, sg);

    return Li;
}

//Approximate BRDF for final gather samples
float evalApproximateBRDF(ShadingData sd, BSDFProperties bsdfProperties, float3 toLight) {
    const float3 N = bsdfProperties.guideNormal;
    const float3 H = normalize(sd.V + toLight);
    const float NdotV = saturate(dot(N, sd.V));
    const float NdotL = saturate(dot(N, toLight));
    const float NdotH = saturate(dot(N, H));
    const float LdotH = saturate(dot(toLight, H));
    const float diffuse = luminance(bsdfProperties.diffuseReflectionAlbedo);
    const float specular = luminance(bsdfProperties.specularReflectionAlbedo);

    // BRDF terms for target function (DGF Microfaset BRDF)
    float D = evalNdfGGX(bsdfProperties.roughness * bsdfProperties.roughness, NdotH);
    float G = evalMaskingSmithGGXSeparable(bsdfProperties.roughness, NdotL, NdotV);

    // float F = specular < 1e-8f ? 0.f :  evalFresnelSchlick(specular, 1.f, LdotH);     //Right way
    float F = specular < 1e-8f ? 0.f : evalFresnelSchlick(specular, 1.f, LdotH) / specular; // Not "right" but less noisier

    // eval brdf terms
    float diffuseBRDF = NdotL * M_1_PI;
    float specularBRDF = D * G * F / (4.f * NdotV);

    // Mix diffuse and specular BRDF
    float diffuseProb = 0;
    if (diffuse > 0 || specular > 0)
        diffuseProb = diffuse / (diffuse + specular);
    float brdf = max(0.f, lerp(specularBRDF, diffuseBRDF, diffuseProb));

    return max(0.f, brdf);
}

//Approximate BRDF for caustic photons
float evalApproximateBRDFPhoton(ShadingData sd, BSDFProperties bsdfProperties, float3 toLight) {
    const float3 N = bsdfProperties.guideNormal;
    const float3 H = normalize(sd.V + toLight);
    const float NdotV = saturate(dot(N, sd.V));
    const float NdotL = saturate(dot(N, toLight));
    const float NdotH = saturate(dot(N, H));
    const float LdotH = saturate(dot(toLight, H));
    const float diffuse = luminance(bsdfProperties.diffuseReflectionAlbedo);
    const float specular = luminance(bsdfProperties.specularReflectionAlbedo);

    if (NdotL < 0)
        return 0;

    // BRDF terms for target function (DGF Microfaset BRDF)
    float D = evalNdfGGX(bsdfProperties.roughness * bsdfProperties.roughness, NdotH);
    float G = evalMaskingSmithGGXSeparable(bsdfProperties.roughness, NdotL, NdotV);

    // float F = specular < 1e-8f ? 0.f :  evalFresnelSchlick(specular, 1.f, LdotH);     //Right way
    float F = specular < 1e-8f ? 0.f : evalFresnelSchlick(specular, 1.f, LdotH) / specular; // Not "right" but less noisier

    // eval brdf terms
    float diffuseBRDF = M_1_PI;
    float specularBRDF = D * G * F / (4.f * NdotV * NdotL);

    // Mix diffuse and specular BRDF
    float diffuseProb = 0;
    if (diffuse > 0 || specular > 0)
        diffuseProb = diffuse / (diffuse + specular);
    float brdf = max(0.f, lerp(specularBRDF, diffuseBRDF, diffuseProb));

    return max(0.f, brdf);
}

// unbiased p_hat with visibility test and jacobian determinant used in MIS
float evaluateFinalGatherSampleApproximateUnbiased(ReservoirFG r, ShadingData sd, BSDFProperties bsdfProperties, bool assumeVisible = false)
{
    float Li = 0.0;
    float3 toSurface = sd.posW - r.sampleData.posW;
    float dist = length(toSurface);
    toSurface /= dist;
    float jacobianDeterminant = dot(r.sampleData.normal, toSurface) / (dist * dist);
    jacobianDeterminant /= r.jacobianDeterminant;

    if (jacobianDeterminant < 0 || isnan(jacobianDeterminant) || isinf(jacobianDeterminant))
        return 0.0;

    Li = luminance(r.sampleData.radianceOut) * jacobianDeterminant;
    if (!assumeVisible)
        if (!dispatchShadowRay(sd, -toSurface, dist))
            return 0.0;

    Li *= evalApproximateBRDF(sd, bsdfProperties, -toSurface);

    return Li;
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
    if (sum > 0)
        return q0 / (q0 + q1);
    else
        return 0;
}

// transforms direction from local to world space
float3 fromLocalToWorld(const in float3 normal, float3 w)
{
    // transform from local space -> random dir vector in world space
    float3 bitangent = perp_stark(normal);
    float3 tangent = cross(bitangent, normal);

    return w.x * tangent + w.y * bitangent + w.z * normal;
}

// Creates a photon sample from the light
bool photonSampleLight(inout PhotonLightSample pls, inout RayDesc ray, inout SampleGenerator sg)
{
    // Check if the light is emissive or analytic
    bool isAnalytic = pls.lightIdx >= kAnalyticLightIdxOffset;
    float2 randomValues = float2(pls.rndX, pls.rndY);
    // float2 randomValues = sampleNext2D(sg);

    float3 woLocal = float3(0);

    // Sample Light depending on type
    if (isAnalytic)
    {
        const uint analyticLightIndex = pls.lightIdx - kAnalyticLightIdxOffset;
        LightData lightData = gScene.getLight(analyticLightIndex);
        // For now only point (and spot) lights are supported
        if (lightData.type != uint(LightType::Point))
            return false;

        float spotAngle = lightData.cosOpeningAngle;

        if (lightData.openingAngle < M_2PI) // If the opening angle is smaller than 2PI it is a spotlight
        {
            // TODO support penumbra
            woLocal = sample_cone(randomValues.xy, spotAngle);
        } else // Pointlight
        {
            spotAngle = 0;
            woLocal = sample_sphere(randomValues.xy);
        }
        float invLightPdf = M_2PI * (1.0 - spotAngle);

        if (invLightPdf <= 0.f)
            return false;

        pls.posW = lightData.posW;
        pls.normal = lightData.dirW;
        pls.flux = lightData.intensity * invLightPdf;
    } else // Emissive
    {
        // Get light data
        const EmissiveTriangle tri = gScene.lightCollection.getTriangle(pls.lightIdx);
        const float3 barycentrics = sample_triangle(sampleNext2D(sg));
        pls.posW = tri.getPosition(barycentrics);
        pls.normal = tri.normal;

        // Get Flux
        float2 uv = tri.getTexCoord(barycentrics);
        pls.flux = gScene.materials.evalEmissive(tri.materialID, uv) * tri.area;

        pls.posW = computeRayOrigin(pls.posW, pls.normal); // Offset as this light is real geometry

        // Light direction
        float lightDirPDF = 1.0;

        woLocal = sample_cosine_hemisphere_concentric(randomValues, lightDirPDF);

        if (lightDirPDF <= 0.)
            return false;

        pls.flux *= M_PI; // Lambert Emitter
    }

    ray.Origin = pls.posW;
    ray.Direction = fromLocalToWorld(pls.normal, woLocal);
    ray.TMin = 0.0f;
    ray.TMax = FLT_MAX;

    return true;
}

float3 getLightPosition(uint lightIndex)
{
    bool isAnalytic = lightIndex >= kAnalyticLightIdxOffset;
    float3 posW = float3(0);
    if (isAnalytic)
    {
        const uint analyticLightIndex = lightIndex - kAnalyticLightIdxOffset;
        LightData lightData = gScene.getLight(analyticLightIndex);
        posW = lightData.posW;
    } else
    {
        const EmissiveTriangle tri = gScene.lightCollection.getTriangle(lightIndex);
        posW = tri.getPosition(float3(1.0 / 3.0));
    }

    return posW;
}

void photonRetraceRecreateDirectionsRandomValues(inout PhotonLightSample pls, float2 randomVal, uint guidingTextureResolution)
{
    if (pls.useRandomLightDirection) {
        pls.rndX = randomVal.x;
        pls.rndY = randomVal.y;
    }
    else {
        uint2 relIdx = pls.guidingPixels % guidingTextureResolution; // To local guiding pixels
        float2 relMinWeight = float2(relIdx) / guidingTextureResolution;
        float2 relMaxWeight = float2(relIdx + 1) / guidingTextureResolution;
        relMinWeight += (relMaxWeight - relMinWeight) * randomVal;
        pls.rndX = relMinWeight.x;
        pls.rndY = relMinWeight.y;
    }
}
