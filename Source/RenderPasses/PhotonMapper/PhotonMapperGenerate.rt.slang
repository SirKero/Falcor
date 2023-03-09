#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.Raytracing;
import Utils.Math.PackedFormats;
import Utils.Math.FormatConversion;
import Utils.Math.MathHelpers;
import Utils.Sampling.SampleGenerator;
import Rendering.Materials.StandardMaterial;
import Scene.Material.ShadingUtils;
import Rendering.Lights.LightHelpers;
import Utils.Color.ColorHelpers;
import Rendering.Materials.Microfacet;
import Rendering.Lights.EmissiveLightSampler;
import Rendering.Lights.EmissiveLightSamplerHelpers;

import PhotonCullingHash;


cbuffer PerFrame
{
    uint gFrameCount; // Frame count since scene was loaded.
    float2 gPhotonRadius; //Radius for the vpl collection
    float gHashScaleFactor; //Hash scale factor. 1/Radius
}

cbuffer CB
{
    uint gMaxRecursion; //Max photon recursion depths
    float gRejection; //Probability that a photon is stored as a light
    uint gFlags; //Flags for the pass. See GenerationFlags enum
    uint gHashSize; //Size is always 2^x
    int gCausticsBounces; //Number of diffuse bounces allowed for caustic photons
    uint gCullingYExtent; //Y-Extend of the hash texture
    float gRayTMin; //TMin for photon ray
    uint _pad;
};

cbuffer Light
{
    EmissiveLightSampler gEmissiveSampler;
}

enum class GenerationFlags // : uint32_t
{
    None                = 0x00,
    AlphaTest           = 0x01,     //Enable Alpha test
    AdjShadingNormals   = 0x02,     //Adjust the shading normals
    EnableCaustics      = 0x04,     //Enable caustic photons.
    DeltaRejection      = 0x08,     //Accept every non delta material as diffuse
};

struct PhotonInfo {
        float3 flux;
        float faceNTheta;
        float3 dir;
        float faceNPhi;
};

struct PhotonLightSample
{
    float3 posW;
    float3 normal;
    float3 flux;
};


 //Internal Buffer Structs
RWTexture2D<float4> gPhotonFlux[2];
RWTexture2D<float4> gPhotonDir[2];
RWStructuredBuffer<AABB> gPhotonAABB[2];

RWStructuredBuffer<uint> gPhotonCounter; //idx 0 = caustic ; idx 1 = global

//Culling (optional)
Texture2D<uint> gCullingHashBuffer;

// Static configuration based on defines set from the host.
static const uint kInfoTexHeight = INFO_TEXTURE_HEIGHT;
static const uint2 kPhotonBufferSize = uint2(PHOTON_BUFFER_SIZE_GLOBAL, PHOTON_BUFFER_SIZE_CAUSTIC);
static const uint kUsePhotonCulling = USE_PHOTON_CULLING;
static const uint kRayFlagTerminatedMiss = 1;
static const uint kRayFlagTerminatedHit = 2;

static const float kRayTMinCulling = RAY_TMIN_CULLING;
static const float kRayTMaxCulling = RAY_TMAX_CULLING;


/** Payload for scatter ray (80B).
*/
struct RayData
{
    float3 thp; ///< Current path throughput. This is updated at each path vertex.
    uint packedNormal; ///< Face normal encoded in 16 bit polar coordinates
    float3 origin; ///< Next path segment origin.
    uint terminated; ///< Set to true when path is terminated.
    float3 direction; ///< Next path segment direction.
    bool diffuseHit; ///< saves if the his is diffuse
    float3 diffuseScalar;
    bool isEmissive; ///<If the hit is emissive

    SampleGenerator sg; ///< Per-ray state for the sample generator (up to 16B).

    /** Create ray payload with default parameters.
    */
    static RayData create()
    {
        RayData d;
        d.terminated = 0;
        d.packedNormal = 0;
        d.thp = float3(1);
        d.origin = float3(0);
        d.direction = float3(0);
        d.isEmissive = false;
        return d;
    }
};

bool createLightSample(inout SampleGenerator sg, out PhotonLightSample pls)
{
    if (gScene.lightCollection.isEmpty())
        return false;

    //Randomly pick a triangle out of the global list with uniform probability
    const uint triangleCount = gScene.lightCollection.triangleCount;
    // Safety precaution as the result of the multiplication may be rounded to triangleCount even if uLight < 1.0 when triangleCount is large.
    uint triangleIndex = min((uint) (sampleNext1D(sg) * triangleCount), triangleCount - 1);

    uint2 packed = gEmissiveSampler._emissivePower.triangleAliasTable[triangleIndex];
    float threshold = f16tof32(packed.x >> 16u);
    uint selectAbove = ((packed.x & 0xFFFFu) << 8u) | ((packed.y >> 24u) & 0xFFu);
    uint selectBelow = packed.y & 0xFFFFFFu;

    // Test the threshold in the current table entry; pick one of the two options
    triangleIndex = (sampleNext1D(sg) >= threshold) ? selectAbove : selectBelow;

    float triangleSelectionPdf = gScene.lightCollection.fluxData[triangleIndex].flux * gEmissiveSampler._emissivePower.invWeightsSum;
    
    const EmissiveTriangle tri = gScene.lightCollection.getTriangle(triangleIndex);
    const float3 barycentrics = sample_triangle(sampleNext2D(sg));
    pls.posW = tri.getPosition(barycentrics);
    pls.normal = tri.normal;

    //Get Flux
    float2 uv = tri.getTexCoord(barycentrics);
    pls.flux = gScene.materials.evalEmissive(tri.materialID, uv) * tri.area;
    pls.flux /= triangleSelectionPdf;

    //Check if the material is double sided (infinetly thin)
    MaterialHeader mltHeader = gScene.materials.getMaterialHeader(tri.materialID);
    //If the material is double sided, randomly flip the normal
    if (mltHeader.isDoubleSided())
    {
        if (sampleNext1D(sg) >= 0.5f)
            pls.normal = -tri.normal;
    }
    
    return true;
}

//cartesian to polar coodinate. Assumes p is normalized
float2 toSphericalCoordinate(float3 p)
{
    return float2(acos(p.y), atan2(p.z, p.x));
}

float3 fromWordlToLocal(const in float3 normal, float3 w)
{
    // reconstruct tangent frame based off worldspace normal
    // this is ok for isotropic BRDFs
    // for anisotropic BRDFs, we need a user defined tangent
    float3 bitangent = perp_stark(normal);
    float3 tangent = cross(bitangent, normal);

    return float3(dot(bitangent, w), dot(tangent, w), dot(normal, w));
}

//transforms direction from local to world space
float3 fromLocalToWorld(const in float3 normal, float3 w)
{
    //transform from local space -> random dir vector in world space
    float3 bitangent = perp_stark(normal);
    float3 tangent = cross(bitangent, normal);

    return w.x * tangent + w.y * bitangent + w.z * normal;
}

AABB calcPhotonAABB(in float3 center, in float radius)
{
    AABB aabb = AABB(center - radius, center + radius);
    return aabb;
}

bool cullingTest(float3 origin)
{
    //Check if hash cell is set
    int3 cell = int3(floor(origin * gHashScaleFactor));
    uint h = hash(cell) & (gHashSize - 1);
    uint2 hIdx = uint2(h % gCullingYExtent, h / gCullingYExtent);

    return gCullingHashBuffer[hIdx] == 1 ? true : false;
}

[shader("miss")]
void miss(inout RayData rayData : SV_RayPayload)
{
    rayData.terminated |= kRayFlagTerminatedMiss;
}

[shader("closesthit")]
void closestHit(inout RayData rayData : SV_RayPayload, BuiltInTriangleIntersectionAttributes attribs : SV_IntersectionAttributes)
{
    const float3 incomingRayDir = -WorldRayDirection();
    // Evaluate Falcor's material parameters at the hit point.
    GeometryInstanceID instanceID = getGeometryInstanceID();
    VertexData v = getVertexData(instanceID, PrimitiveIndex(), attribs);
    const uint materialID = gScene.getMaterialID(instanceID);
    let lod = ExplicitLodTextureSampler(0.f);
    ShadingData sd = gScene.materials.prepareShadingData(v, materialID, incomingRayDir, lod);

    //Adjust shading normals if desired
    
    if (gFlags & (uint) GenerationFlags::AdjShadingNormals)
    {
        adjustShadingNormal(sd, v);
    }
    
    BSDFSample bsdfSample;
    let bsdf = gScene.materials.getBSDF(sd, lod);
    uint lobes = bsdf.getLobes(sd);
    let bsdfProperties = bsdf.getProperties(sd);
    bool hasDiffuseParts = luminance(bsdfProperties.diffuseReflectionAlbedo) > 0;
    
    bool valid = bsdf.sample(sd, rayData.sg, bsdfSample, true /*ImportanceSampling*/);

    float3 thpStart = rayData.thp;
    
    bool transmission = bsdfSample.isLobe(LobeType::Transmission);
    float3 rayOrigin = sd.computeNewRayOrigin(!transmission); //false is for transmissions
    rayData.origin = rayOrigin;
    rayData.thp *= valid ? bsdfSample.weight : float3(0);
    rayData.packedNormal = encodeNormal2x16(sd.N);
    rayData.direction = bsdfSample.wo;
    rayData.isEmissive = luminance(bsdfProperties.emission) > 0;
    if (gFlags & (uint) GenerationFlags::DeltaRejection)
        rayData.diffuseHit = bsdfSample.isLobe(LobeType::Reflection) && (((lobes & (uint) LobeType::Delta) == 0) && hasDiffuseParts);
    else
        rayData.diffuseHit = bsdfSample.isLobe(LobeType::Diffuse) && !transmission;

    
    //if throughput is 0, return
    if (!valid || any(rayData.thp <= 0))
        rayData.terminated |= kRayFlagTerminatedHit;
}

//Use anyhit for alpha test if activated
[shader("anyhit")]
void anyHit(inout RayData rayData : SV_RayPayload, BuiltInTriangleIntersectionAttributes attribs : SV_IntersectionAttributes)
{
    if (gFlags & (uint) GenerationFlags::AlphaTest)
    {
        // Alpha test for non-opaque geometry.
        GeometryInstanceID instanceID = getGeometryInstanceID();
        VertexData v = getVertexData(instanceID, PrimitiveIndex(), attribs);
        uint materialID = gScene.getMaterialID(instanceID);
        if (gScene.materials.alphaTest(v, materialID, 0.f))
            IgnoreHit();
    }
}

[shader("raygeneration")]
void rayGen()
{
    uint2 launchIndex = DispatchRaysIndex().xy;
    uint2 launchDim = DispatchRaysDimensions().xy;

    const float invRejection = 1.f / gRejection;
    const float invInvRejection = 1.f / (1.f - gRejection);
     // Prepare ray payload.
    RayData rayData = RayData.create();
    rayData.sg = SampleGenerator(launchIndex, gFrameCount + 1 * 13);

    PhotonLightSample pls;
    if (!createLightSample(rayData.sg, pls))
        return;
    
    RayDesc ray;
    float lightDirPDF = 1.0;
    float3 woLocal = sample_cosine_hemisphere_concentric(sampleNext2D(rayData.sg), lightDirPDF);

    if ((woLocal.z < kMinCosTheta) || (lightDirPDF == 0.f))
        return;
    
    ray.Direction = fromLocalToWorld(pls.normal, woLocal);
    
    pls.flux /= lightDirPDF;
    pls.flux /= launchDim.x * launchDim.y; //Division through all photons

    ray.Origin = pls.posW;
    ray.TMin = gRayTMin; //TODO set as uniform
    ray.TMax = 10000.f;
    
    //create photon
    float3 photonPos = float3(0);
    PhotonInfo photon;
    photon.dir = float3(0);
    photon.faceNTheta = 1.f;
    photon.flux = float3(0);
    photon.faceNPhi = 1.f;
    
    uint rayFlags = 0;

    const uint maxCausticBounces = gCausticsBounces >= 0 ? gCausticsBounces : gMaxRecursion;
    uint currentCausticBounces = 0;
    bool storeAsCaustic = false;
    bool reflectedDiffuse = false;
        
    //recursion where the photons are shot
    for (uint i = 0; i < gMaxRecursion; i++)
    {
        photon.flux = pls.flux * rayData.thp;
        TraceRay(gScene.rtAccel, rayFlags, 0xff /* instanceInclusionMask */, 0 /* hitIdx */, rayTypeCount, 0 /* missIdx */, ray, rayData);

        //Stop if a light source was hit
        if (rayData.isEmissive || (rayData.terminated & kRayFlagTerminatedMiss > 0))
            break;
        
        photonPos = rayData.origin;
        photon.dir = ray.Direction;
        reflectedDiffuse = rayData.diffuseHit;

        //rejection
        float rndRoulette = sampleNext1D(rayData.sg);
        bool roulette = rndRoulette <= gRejection;

        //store photon light
        if (reflectedDiffuse && (roulette || storeAsCaustic))
        {
            uint photonType = storeAsCaustic ? 0 : 1; //Caustic = 0 or Global = 1
            bool storePhoton = true;
            if (kUsePhotonCulling)
                storePhoton = cullingTest(photonPos);
            if (storePhoton)
            {
                uint photonIndex = 0;
                if (photonType == 1)
                    photon.flux *= invRejection;
                InterlockedAdd(gPhotonCounter[photonType], 1u, photonIndex);
                //Only store photon if the buffer space allows it
                if (photonIndex <= kPhotonBufferSize[photonType])
                {
                    AABB photonAABB = AABB(photonPos - gPhotonRadius[photonType], photonPos + gPhotonRadius[photonType]);
                    gPhotonAABB[photonType][photonIndex] = photonAABB;
                    uint2 photonIndex2D = uint2(photonIndex / kInfoTexHeight, photonIndex % kInfoTexHeight);
                    gPhotonFlux[photonType][photonIndex2D] = float4(photon.flux, photon.faceNTheta);
                    gPhotonDir[photonType][photonIndex2D] = float4(photon.dir, photon.faceNPhi);
                }
            }
        }
           
        //If next sampled ray is invalid return here
        if (rayData.terminated > 0)
            break;
        
        //Russian Roulette
        const float rrVal = luminance(rayData.thp);
        const float prob = max(0.f, 1.f - rrVal);
        float rnd = sampleNext1D(rayData.sg);
        if (rnd < prob)
        {
            break; //Photon is absorbed
        }
        else
        {
            rayData.thp /= (1.f - prob);
        }

        //Caustics handling
        storeAsCaustic = !reflectedDiffuse;
        if (currentCausticBounces > maxCausticBounces)
            storeAsCaustic = false;
        if (reflectedDiffuse)
            currentCausticBounces++;
        
                        
        //update ray for next iteration
        ray.Origin = rayData.origin;
        ray.Direction = rayData.direction;
    }
    
}
