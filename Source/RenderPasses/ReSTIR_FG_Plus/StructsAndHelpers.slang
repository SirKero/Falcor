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

struct PhotonData {
    float3 flux;
    uint pathLenght;
    float3 dir;
    uint _pad2;
    float3 normalW;
    uint _pad3;

    __init() {
        this.dir = float3(0);
        this.normalW = float3(0,1,0);
        this.flux = float3(0);
        this.pathLenght = 0;
        this._pad2 = 0;
        this._pad3 = 0;
    }
}

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
    isNEE = 0x8000,       // 1<<15
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

    //SampleGenerator sgRCNee; // For replaying NEE decisions

    float3 samplePosW;      // Sample Position
    float sampleRadius;     //For radiance estimate

    float jacobian;    //(stored) jacobian determinant at the first hit
    ReservoirFlags flags;      // path length and flags
    float2 packedSampleNormal;

    float3 F; // Complete radiance of the path
    uint c;   // Confidence Weight

    float3 fgRadiance;      // Radiance estimate for the final gather point. Can be reused
    float weight;           // Unbiased contribution weight  

    __init() {
        sgPathDirections = SampleGenerator(uint2(0), 0);
        // sgRCNee = SampleGenerator(uint2(0), 0);
        samplePosW = float3(0);
        sampleRadius = 0;
        jacobian = 1;
        packedSampleNormal = float2(0);
        flags = ReservoirFlags();
        F = float3(0);
        c = 1;
        fgRadiance = float3(0);
        weight = 0.0;
    }

    bool isValid() {
        return weight > 0 && jacobian > 0 && any(F > 0);
    }

    property uint pathLength {
        get { return flags.pathLength; }
        set { flags.pathLength = newValue;}
    }

    property float3 sampleNormal {
        get { return oct_to_ndir_snorm(packedSampleNormal);}
        set { packedSampleNormal = ndir_to_oct_snorm(newValue);}
    }

}

//Infos on retraced path 64byte (16 floats)
struct RetracedPath
{
    float3 F;
    float jacobian;

    float3 rcThp;
    uint _pad;

    PackedHitInfo rcSurface;

    float3 rcViewDir;
    uint flags;

    __init()
    {
        F = float3(0);
        jacobian = 1;
        rcThp = float3(0);
        rcSurface = {};
        rcViewDir = float3(0);
        flags = 0;
        _pad = 0;
    }
}

//Data for the FG sample 64B
struct FGSampleData {
    float3 posW;        //Position
    float normalX;
    float3 radianceOut; //Radiance
    float normalY;
    float3 sampleView; //Incoming View
    float normalZ;

    __init() {
        posW = float3(0);
        normalX = 0;
        normalY = 1;
        normalZ = 0;
        radianceOut = float3(0);
        sampleView = float3(0);
    }

    //Normal helper
    property float3 normal {
        get { return float3(normalX, normalY, normalZ); }
        set {
            normalX = newValue.x;
            normalY = newValue.y;
            normalZ = newValue.z;
        }
    }
}

//Reservoir for a Final Gather Sample 112B
struct ReservoirFG {
    PackedHitInfo sampleSurface; // HitSample 16B
    float3 thp;                     // Throughput used at the end
    float targetFunction;           // Store target function
    FGSampleData sampleData;        // Data of the sample
    float wSum;                     // W and wSum
    uint c;                         // Confidence weight
    float jacobianDeterminant;      // Jacobian determinant to the current sample
    uint pathLength;                // Path Length

    __init() {
        sampleSurface = {};
        thp = float3(1);
        targetFunction = 0;
        sampleData = FGSampleData();
        wSum = 0;
        c = 1;
        pathLength = 0;
        jacobianDeterminant = -1.0;
    }

    //Valid check
    bool isValid() {
        return jacobianDeterminant >= 0;
    }
}

// Reservoir for a CausticSample 112B
struct ReservoirCaustic {
    PackedHitInfo sampleSurface;    // HitSample 16B
    float3 thp;                     // Throughput used at the end
    float targetFunction;           // Store target function
    float3 sampleSurfaceView;       // Incoming View
    float photonDirX;
    float3 photonPosW;              // Position
    float photonDirY;
    float3 photonRadiance;          // Radiance
    float photonDirZ;      
    float wSum;                     // W and wSum
    uint c;                         // Confidence weight
    uint pathLength;                // Path Length
    float subPixelJacobian;         // Sub pixel jacobian for reprojection

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
        c = 0;
        pathLength = 0;
        subPixelJacobian = 0;
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

    // Valid check
    bool isValid() {
        return any(photonRadiance > 0);
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

bool dispatchShadowRay(ShadingData sd, float3 toLight, float distanceToLight) {
    // Create a DXR 1.1 query object to trace a ray (the <1> means use alpha testing)
    SceneRayQuery<1> rayQuery;
    const Ray ray = Ray(sd.computeNewRayOrigin(), toLight, 0.f, distanceToLight * kShadowRayEpsilon);
    return rayQuery.traceVisibilityRay(ray, RAY_FLAG_NONE, 0xff);
}

//Unbiased f(x) without jacobian determinant TODO seems that jacobian and visibility is not needed, as this is handled by MIS during resampling
float3 evaluateFinalGatherSample(ReservoirFG r, ShadingData sd, IMaterialInstance mi, inout SampleGenerator sg) {
    float3 Li = float3(0);

    float3 toLight = r.sampleData.posW - sd.posW;
    float dist = length(toLight);
    toLight /= dist;
    //float jacobianDeterminant = dot(r.sampleData.normal, -toLight) / (dist * dist);
    //jacobianDeterminant /= r.jacobianDeterminant;
    Li = r.sampleData.radianceOut;
    //if (dispatchShadowRay(sd, toLight, dist)) {
        Li *= mi.eval(sd, toLight, sg);
    //} else
    //    Li = float3(0);

    return Li;
}

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
    if(diffuse > 0 || specular > 0)
        diffuseProb = diffuse / (diffuse + specular);
    float brdf = max(0.f, lerp(specularBRDF, diffuseBRDF, diffuseProb));

    return max(0.f, brdf);
}

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

// unbiased p_hat with visibility test
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
