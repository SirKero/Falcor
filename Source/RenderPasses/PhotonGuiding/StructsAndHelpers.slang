#pragma once
#include "Utils/Math/MathConstants.slangh"

import Scene.RaytracingInline;
import Utils.Sampling.SampleGenerator;
import Utils.Color.ColorHelpers;
import Rendering.Materials.IsotropicGGX;
import Rendering.Materials.Fresnel;

static const float kShadowRayEpsilon = 0.98f;
static const float kDeltaRoughnessThreshold = 0.08; //see StandardBSDF.slang kMinGGXAlpha. Everything under this value is considered a delta event

enum class PhotonType // : uint32_t
{
    Global = 0,
    Caustic = 1
};

/* Struct describing a Photon used with VCM MIS
flux - the energy of the photon
pathLength - Which bounce the photon is on the light path. 0 is the first surface hit (direct light from camera)
dir - incoming direction
lightIndex - index of the light that generated this photon
normalW - world face normal for the photon, used for surface rejections
*/
struct PhotonData {
    float3 flux;
    uint pathLenght;

    float3 dir;
    uint lightIndex;

    float3 normalW;
    uint _pad;

    uint2 guidingPixel;
    float2 guidingRandomVal; //Not used? 

    // Normal helper
    /*
    property uint2 guidingPixels {
        get { return uint2(packedGuidingPixels & 0xFFFF, (packedGuidingPixels >> 16) & 0xFFFF); }
        set {
            packedGuidingPixels = newValue.x & 0xFFFF;
            packedGuidingPixels |= (newValue.y & 0xFFFF) << 16;
        }
    }
    */

    __init() {
        this.dir = float3(0);
        this.normalW = float3(0,1,0);
        this.flux = float3(0);
        this.pathLenght = 0;
        this.lightIndex = 0;
        this.guidingPixel = uint2(0);
        this._pad = 0;
        this.guidingRandomVal = float2(0);
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

    int lightIndex;            //Guiding
    uint2 guidingPixels;   // Pixel for the guiding texture
    uint _pad;

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
        guidingPixels = uint2(0);
        _pad = 0;
    }

    //Guiding pixels helper
    /*
    property uint2 guidingPixels {
        get { return uint2(packedGuidingPixels & 0xFFFF, (packedGuidingPixels >> 16) & 0xFFFF); }
        set {
            packedGuidingPixels = newValue.x & 0xFFFF;
            packedGuidingPixels |= (newValue.y & 0xFFFF) << 16;
        }
    }
    */

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

    float wSum;      // W and wSum
    uint c;          // Confidence weight
    uint pathLength; // Path Length
    uint _pad;

    int lightIndex;          // Guiding
    uint2 guidingPixels;      // Pixel for the guiding texture
    uint _pad2;
    //float2 guidingRandomVal;  // Random vals for guiding

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
        _pad = 0;
        lightIndex = 0-1;
        guidingPixels = uint2(0);
        _pad2 = 0;
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
    /*
    property uint2 guidingPixels {
        get { return uint2(packedGuidingPixels & 0xFFFF, (packedGuidingPixels >> 16) & 0xFFFF); }
        set {
            packedGuidingPixels = newValue.x & 0xFFFF;
            packedGuidingPixels |= (newValue.y & 0xFFFF) << 16;
        }
    }
    */

    // Valid check
    bool isValid() {
        return any(photonRadiance > 0);
    }
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

//Visibility test helper
bool dispatchShadowRay(ShadingData sd, float3 toLight, float distanceToLight) {
    // Create a DXR 1.1 query object to trace a ray (the <1> means use alpha testing)
    SceneRayQuery<1> rayQuery;
    const Ray ray = Ray(sd.computeNewRayOrigin(), toLight, 0.f, distanceToLight * kShadowRayEpsilon);
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

