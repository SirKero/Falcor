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
import Rendering.Lights.EmissiveLightSampler;
import Rendering.Lights.EmissiveLightSamplerHelpers;
import PhotonReStirFunctions;
import PhotonLight;

cbuffer PerFrame
{
    uint gFrameCount; // Frame count since scene was loaded.
    float gPhotonRadius;    //CausticRadius for the AABB
    uint2 _pad1;
}

cbuffer CB
{
    uint gMaxRecursion; //Max photon recursion depths
    float gRejection; //Probability that a photon is stored as a light
    bool gUseAlphaTest;
    bool gAdjustShadingNormals;
    bool gEnableCaustics; //Enable caustic photons
    int gCausticsBounces; //Number of diffuse bounces allowed for caustic photons
    uint2 _pad2;
};

cbuffer Light{
    EmissiveLightSampler gEmissiveSampler;
}


RWStructuredBuffer<PhotonLight> gPhotonLights;
RWStructuredBuffer<AABB> gCausticPhotonAABB;
RWStructuredBuffer<uint4> gCausticPackedPhotonData;
RWBuffer<uint> gPhotonCounter;
RWTexture2D<float> gPhotonPdfTexture;

static const uint2 kPhotonBufferSize = uint2(PHOTON_BUFFER_SIZE_GLOBAL, PHOTON_BUFFER_SIZE_CAUSTIC);
static const bool kUsePdfSampling = USE_PDF_SAMPLING;
static const uint kRayFlagTerminatedMiss = 1;
static const uint kRayFlagTerminatedHit = 2;

/** Payload for scatter ray (80B).
*/
struct RayData
{
    float3  thp;            ///< Current path throughput. This is updated at each path vertex.
    uint   packedNormal;   ///< Face normal encoded in 16 bit polar coordinates
    float3  origin;         ///< Next path segment origin.
    uint terminated; ///< Set to true when path is terminated.
    float3  direction;      ///< Next path segment direction.
    bool    diffuseHit;     ///< saves if the his is diffuse
    float3 diffuseScalar;
    uint _pad;
    float3 normal;
    uint _pad2;

    SampleGenerator sg;     ///< Per-ray state for the sample generator (up to 16B).

    /** Create ray payload with default parameters.
    */
    static RayData create()
    {
        RayData d;
        d.terminated = 0;
        d.packedNormal = 0;
        d.normal = float3(0,1,0);
        d.thp = float3(1);
        d.diffuseScalar = float3(1);
        d.origin = float3(0);
        d.direction = float3(0);
        d._pad = 0;
        return d;
    }
};

struct PhotonInfo {
        float3 flux;
        float faceNTheta;
        float3 dir;
        float faceNPhi;
};

struct PhotonLightSample{
    float3 posW;
    float3 normal;
    float3 flux;
};

bool createLightSample(inout SampleGenerator sg, out PhotonLightSample pls ){
    if (gScene.lightCollection.isEmpty()) return false;

    //Randomly pick a triangle out of the global list with uniform probability
    const uint triangleCount = gScene.lightCollection.triangleCount;
    // Safety precaution as the result of the multiplication may be rounded to triangleCount even if uLight < 1.0 when triangleCount is large.
    uint triangleIndex = min((uint)(sampleNext1D(sg) * triangleCount), triangleCount - 1);

    uint2 packed = gEmissiveSampler._emissivePower.triangleAliasTable[triangleIndex];
    float threshold = f16tof32(packed.x >> 16u);
    uint  selectAbove = ((packed.x & 0xFFFFu) << 8u) | ((packed.y >> 24u) & 0xFFu);
    uint  selectBelow = packed.y & 0xFFFFFFu;

    // Test the threshold in the current table entry; pick one of the two options
    triangleIndex = (sampleNext1D(sg) >= threshold) ? selectAbove : selectBelow;

    float triangleSelectionPdf = gScene.lightCollection.fluxData[triangleIndex].flux * gEmissiveSampler._emissivePower.invWeightsSum;
    
    const EmissiveTriangle tri = gScene.lightCollection.getTriangle(triangleIndex);
    const float3 barycentrics = sample_triangle(sampleNext2D(sg));
    pls.posW = tri.getPosition(barycentrics);
    pls.normal = tri.normal;

    //Get Flux
    float2 uv = tri.getTexCoord(barycentrics);
    pls.flux = gScene.materials.evalEmissive(tri.materialID, uv) * tri.area * M_PI;
    pls.flux /= triangleSelectionPdf;

    return true;
}

//transforms direction from local to world space
void fromLocalToWorld(in float3 lightDirW, inout float3 dir)
{
    //transform from local space -> random dir vector in world space
    float3 tangent, bitangent;
    if (abs(lightDirW.x) < 0.99)
        tangent = cross(lightDirW, float3(1., 0., 0.));
    else
        tangent = cross(lightDirW, float3(0., 1., 0.));
    tangent = normalize(tangent);
    bitangent = cross(tangent, lightDirW);

    dir = dir.x * tangent + dir.y * bitangent + dir.z * lightDirW;
}

[shader("miss")]
void miss(inout RayData rayData : SV_RayPayload)
{
    rayData.terminated |= kRayFlagTerminatedMiss;

    //TODO: Add enviroment map color if ray misses scene 
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
    
    if (gAdjustShadingNormals)
    {
        adjustShadingNormal(sd, v);
    }
    
    BSDFSample bsdfSample;
    let bsdf = gScene.materials.getBSDF(sd, lod);
    let bsdfProperties = bsdf.getProperties(sd);

    bool valid = bsdf.sample(sd, rayData.sg, bsdfSample, true /*ImportanceSampling*/);

    float3 thpStart = rayData.thp;
    
    bool transmission = bsdfSample.isLobe(LobeType::Transmission);
    float3 rayOrigin = sd.computeNewRayOrigin(!transmission); //false is for transmissions
    rayData.origin = rayOrigin;
    rayData.thp *= valid ? bsdfSample.weight : float3(0);
    rayData.packedNormal = encodeNormal2x16(sd.N);
    rayData.normal = sd.N;
    rayData.direction = bsdfSample.wo;
    rayData.diffuseHit = bsdfSample.isLobe(LobeType::Diffuse) && !transmission;

    //get diffuse power
    if(rayData.diffuseHit){
        //Slower
        //sd.mtl.setActiveLobes((uint)LobeType::DiffuseReflection);
        //rayData.diffuseScalar = bsdf.eval(sd, sd.N, rayData.sg);
        //Faster same result
        float3 diffProb = float3(0);
        for (uint i = 0; i < 3; i++)
        {
            if (bsdfProperties.diffuseReflectionAlbedo[i] > 0.f)
                diffProb[i] = (bsdfProperties.diffuseReflectionAlbedo[i] + bsdfProperties.specularReflectance[i]) / bsdfProperties.diffuseReflectionAlbedo[i];
        }
        
        const float NdotL = saturate(dot(sd.N, incomingRayDir));
        rayData.diffuseScalar = bsdfProperties.diffuseReflectionAlbedo * NdotL * M_1_PI * diffProb;
        
    }
    //if throughput is 0, return
    if (!valid || any(rayData.thp <= 0))
        rayData.terminated |= kRayFlagTerminatedHit;
    if (luminance(rayData.diffuseScalar) <= 0)
    {
        rayData.terminated |= kRayFlagTerminatedMiss;
    }

}

//Use anyhit for alpha test if activated
[shader("anyhit")]
void anyHit(inout RayData rayData : SV_RayPayload, BuiltInTriangleIntersectionAttributes attribs : SV_IntersectionAttributes)
{
    if (gUseAlphaTest)
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

    const float invRejection = 1.f/gRejection;
    const float invInvRejection = 1.f/(1.f-gRejection);
     // Prepare ray payload.
    RayData rayData = RayData.create();
    rayData.sg = SampleGenerator(launchIndex, gFrameCount +0 * 13 );

    PhotonLightSample pls;
    if(!createLightSample(rayData.sg, pls)) return;
    
    RayDesc ray;
    float lightDirPDF = 1.0;
    ray.Direction = sample_cosine_hemisphere_polar(sampleNext2D(rayData.sg), lightDirPDF);
    fromLocalToWorld(pls.normal, ray.Direction);
    //pls.flux /= lightDirPDF;
    pls.flux /= launchDim.x * launchDim.y;  //Division through all photons
    
    ray.Origin = pls.posW + 0.01 * pls.normal;
    ray.TMin = 0.01f;
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
    for (uint i = 0; i < gMaxRecursion && !rayData.terminated; i++)
    {
        photon.flux = pls.flux * rayData.thp;
        TraceRay(gScene.rtAccel, rayFlags, 0xff /* instanceInclusionMask */, 0 /* hitIdx */, rayTypeCount, 0 /* missIdx */, ray, rayData);

        //Ray Missed scene and photon cannot be stored
        if (rayData.terminated & kRayFlagTerminatedMiss > 0)
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
            uint photonType = storeAsCaustic ? 1 : 0; //Global = 0 or caustic = 1
            uint photonIndex = 0;
            if (photonType == 0) //Photon Light (Global)
                photon.flux *= rayData.diffuseScalar * invRejection;
            InterlockedAdd(gPhotonCounter[photonType], 1u, photonIndex);
            //Only store photon if the buffer space allows it
            if (photonIndex <= kPhotonBufferSize[photonType])
            {
                if (photonType == 1)    //Caustic
                {
                    AABB photonAABB = AABB(photonPos - gPhotonRadius, photonPos + gPhotonRadius);
                    gCausticPhotonAABB[photonIndex] = photonAABB;
                    PhotonData pd = PhotonData();
                    pd.flux = photon.flux;
                    pd.dir = -photon.dir;
                    pd.packedNormal = rayData.packedNormal;
                
                    gCausticPackedPhotonData[photonIndex] = pd.pack();
                }
                else    //Global
                {
                    PhotonLight pl = { };
                    pl.posW = float4(photonPos, 1);
                    pl.normal = rayData.normal;
                    pl.flux = photon.flux;
                    pl.valid = 1;
            
                    gPhotonLights[photonIndex] = pl;
                    if (kUsePdfSampling)
                        gPhotonPdfTexture[ReSTIR_LinearIndexToZCurve(photonIndex)] = luminance(photon.flux);
                }
            }
        }

        //If the ray is terminated
        if (rayData.terminated > 0)
            break;
        
        //Russian Roulette
        //if(reflectedDiffuse) rayData.thp * invInvRejection; //Scale global photon up if it was not stored
        
        const float rrVal = luminance(rayData.thp);
        const float prob = max(0.f, 1.f - rrVal);
        float rnd = sampleNext1D(rayData.sg);
        if (rnd < prob)
        {
            break;      //Photon is absorbed
        }
        else
        {
            rayData.thp /= (1.f - prob);
        }
        
        //Caustics handling
        if (gEnableCaustics)
        {
            storeAsCaustic = !reflectedDiffuse;
            if (currentCausticBounces > maxCausticBounces)
                storeAsCaustic = false;
            if (reflectedDiffuse)
                currentCausticBounces++;
        }
                
        //update ray for next iteration
        ray.Origin = rayData.origin;
        ray.Direction = rayData.direction;        
    }
    
}
