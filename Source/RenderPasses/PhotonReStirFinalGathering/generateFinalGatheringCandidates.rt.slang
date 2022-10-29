#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.Raytracing;
import Scene.Intersection;
import Utils.Math.MathHelpers;
import Utils.Sampling.SampleGenerator;
import Scene.Material.ShadingUtils;
import Rendering.Materials.StandardMaterial;
import Rendering.Materials.Microfacet;
import Rendering.Materials.Fresnel;
import Rendering.Lights.LightHelpers;
import Utils.Math.PackedFormats;
import Utils.Math.FormatConversion;
import Utils.Color.ColorHelpers;

import Reservoir;
import VPLs;
import SurfaceData;

cbuffer PerFrame
{
    uint gFrameCount;       // Frame count since scene was loaded.
}

cbuffer CB
{
    float gPhotonRadius; // Scale for the emissive part
};

// Inputs
RWTexture2D<uint4> gReservoir;
RWStructuredBuffer<PackedVPL> gPhotonLights;
RWStructuredBuffer<PackedSurfaceData> gSurfaceData;
Buffer<uint> gPhotonCounter;
Texture2D<PackedHitInfo> gVBuffer;
Texture2D<float4> gView;
Texture2D <float>gLinZ;
StructuredBuffer<uint4> gPackedPhotonData;
StructuredBuffer<AABB> gPhotonAABB;

RaytracingAccelerationStructure gPhotonAS;


// Static configuration based on defines set from the host.
static const uint kPhotonBufferSize = PHOTON_BUFFER_SIZE;

/** Payload for ray (48B).
*/
struct RayData
{
    float3 radiance;                ///< Accumulated outgoing radiance from path.
    uint _pad;                      ///< packed normal
    float3 diffuseReflectance;       //<Diffuse reflectance of the vpl
    uint _pad2;
      
    __init(){
        radiance = float3(0);
        diffuseReflectance = float3(0);
    }
};

struct TraceData{
    PackedHitInfo packedHitInfo;  //< Reflection albedo of the current hit point
    uint   packedNormal;   ///< Face normal encoded in 16 bit polar coordinates
    bool diffuseHit;
    float  distance;            ///< 
    uint _pad;

    SampleGenerator sg;     ///< Per-ray state for the sample generator (up to 16B).
    
    /** Create ray payload with default parameters.
    */
    static TraceData create()
    {
        TraceData d;
        d._pad = 0;
        d.packedHitInfo = {};
        d.packedNormal = 0;
        d.distance = -1;
        d.diffuseHit = false;
        return d;
    }
}

struct SphereAttribs
{
    float distance;
};

struct LightSample{
    uint lightIdx;
    float3 dir;
    float Li;
    float invSelectPdf;
    float2 uv;
    //Enum type later ? 
};

uint index2Dto1D(uint2 idx, uint width){
    return idx.x + width * idx.y;
}

bool updateReservoir(inout Reservoir r, in LightSample ls,float targetPdf, float rnd){
    float risWeight = targetPdf * ls.invSelectPdf;
    r.weightSum += risWeight;
    r.M += 1;
    bool selectSample = (rnd * r.weightSum < risWeight);
    
    if(selectSample){
        r.lightIdx = ls.lightIdx;
        r.targetPdf = targetPdf;
    }
    return selectSample;
}

void finalizeSample(inout Reservoir r, float normalizationNumerator, float normalizationDenominator){
    float denominator = r.targetPdf * normalizationDenominator;

    r.weightSum = denominator > 0 ? (r.weightSum * normalizationNumerator) / denominator : 0.f;
}

//Load in shading data from hit and direction
ShadingData loadShadingData(const HitInfo hit, const float3 rayDir, const ITextureSampler lod)
{
    const TriangleHit triangleHit = hit.getTriangleHit();
    VertexData v = gScene.getVertexData(triangleHit);
    uint materialID = gScene.getMaterialID(triangleHit.instanceID);
    ShadingData sd = gScene.materials.prepareShadingData(v, materialID, -rayDir, lod);
    adjustShadingNormal(sd, v);
    
    return sd;
}

[shader("miss")]
void miss(inout RayData rayData : SV_RayPayload)
{
    //Empty. Is needed for compilation
}

[shader("miss")]
void missDebug(inout TraceData rayData : SV_RayPayload)
{
    rayData.distance = -1.f;
}

[shader("closesthit")]
void closestHitDebug(inout TraceData rayData : SV_RayPayload, BuiltInTriangleIntersectionAttributes attribs : SV_IntersectionAttributes){
    const float3 incomingRayDir = -WorldRayDirection();
    // Evaluate Falcor's material parameters at the hit point.
    TriangleHit triangleHit;
    triangleHit.instanceID = getGeometryInstanceID();
    triangleHit.primitiveIndex = PrimitiveIndex();
    triangleHit.barycentrics = attribs.barycentrics;
    VertexData v = getVertexData(triangleHit.instanceID, PrimitiveIndex(), attribs);
    const uint materialID = gScene.getMaterialID(triangleHit.instanceID);
    let lod = ExplicitLodTextureSampler(0.f);
    ShadingData sd = gScene.materials.prepareShadingData(v, materialID, incomingRayDir, lod);
        
    BSDFSample bsdfSample;
    let bsdf = gScene.materials.getBSDF(sd, lod);
    let bsdfProperties = bsdf.getProperties(sd);

    //All properties are guaranteed to be combined <= 1. Norm it to 1 to get the real diffuse Reflection probability
    float3 norm = bsdfProperties.diffuseReflectionAlbedo + bsdfProperties.diffuseTransmissionAlbedo + bsdfProperties.specularReflectionAlbedo + bsdfProperties.specularTransmissionAlbedo;

    float pDiffuseRef = luminance(bsdfProperties.diffuseReflectionAlbedo)/luminance(norm);
    
    float rnd = sampleNext1D(rayData.sg);
    bool diffuseHit = rnd <= pDiffuseRef; //Check if diffuse

    if(diffuseHit){
        rayData.distance = RayTCurrent();
        rayData.packedNormal = encodeNormal2x16(sd.N);
        rayData.diffuseHit = diffuseHit;
        rayData.packedHitInfo = HitInfo(triangleHit).getData();
    }else{
        rayData.distance = -1.f;
    }
}

[shader("anyhit")]
void anyHit(inout RayData rayData : SV_RayPayload, SphereAttribs attribs : SV_IntersectionAttributes)
{    
    const uint primIndex = PrimitiveIndex();
    const float3 normal = WorldRayDirection();
    //Get Photon data
    PhotonData pd = PhotonData(gPackedPhotonData[primIndex]);
    //Evaluate diffuse BRDF
    float weight = 1 - attribs.distance * attribs.distance;
    if(dot(pd.normal, normal) < 0.6){
        weight = 0;
    }
    const float NdotL = saturate(dot(normal, pd.dir));
    const float3 diffuseBrdf =  rayData.diffuseReflectance * NdotL * M_1_PI;
   
    //weight = 1.f;
    rayData.radiance += weight * diffuseBrdf * pd.flux;
}

//Checks if the ray start point is inside the sphere.
bool hitSphere(const float3 center, const float radius, const float3 p)
{
    float3 radiusTest = p - center;
    radiusTest = radiusTest * radiusTest;
    float radiusTestF = radiusTest.x + radiusTest.y + radiusTest.z;
    if (radiusTestF < radius * radius)
        return true;
    return false;
}

[shader("intersection")]
void intersection()
{
    //Get start point and prim index
    const float3 origin = ObjectRayOrigin();
    const uint primIndex = PrimitiveIndex();

    //Get Photon AABB. Instance Index 0 is caustic; 1 is global
    AABB photonAABB = gPhotonAABB[primIndex];
    
    //Check for Sphere intersection
    bool tHit = hitSphere(photonAABB.center(), gPhotonRadius, origin);

    //Attribs are needed by the api. Because we have no need for additional attributes it is empty
    SphereAttribs attribs;
    attribs.distance = distance(photonAABB.center(), origin)/gPhotonRadius;

    //Report the hit if the point is in the sphere
    if (tHit)
    {
        ReportHit(RayTCurrent(), 0, attribs);
    }
}

float evalWeight(in ShadingData sd, float pDiffuse, float specular, float surfaceRoughness,float3 toLight){
    const float3 N = sd.N;
    const float3 H = normalize(sd.V + toLight);
    const float NdotV = saturate(dot(N, sd.V));
    const float NdotL = saturate(dot(N, toLight));
    const float NdotH = saturate(dot(N, H));
    const float LdotH = saturate(dot(toLight, H));

    //BRDF terms for target function (DGF Microfaset BRDF)
    const float roughness = surfaceRoughness;
    float D = evalNdfGGX(roughness * roughness, NdotH);
    float G = evalMaskingSmithGGXSeparable(roughness, NdotL, NdotV);

    float F = specular < 1e-8f ? 0.f :  evalFresnelSchlick(specular, 1.f, LdotH);     //Right way
    //float F = any(specular < 1e-8f) ? 0.f :  evalFresnelSchlick(specular, 1.f, LdotH)/specular; //Not "right" but less noisier

    //eval brdf terms
    float diffuseBRDF = NdotL * M_1_PI;
    float specularBRDF = D*G*F/(4.f * NdotV);
    
    //Mix diffuse and specular BRDF
    float brdf = max(0.f, lerp(specularBRDF, diffuseBRDF, pDiffuse));
    return brdf; 
}

//gets the target pdf averaged to one channel
float getSurfacePdf(in Surface surface, float3 toLight)
{
#ifndef DIFFUSE_SHADING_ONLY
    const float3 N = surface.normal;
    const float3 H = normalize(surface.viewDir + toLight);
    const float NdotV = saturate(dot(N, surface.viewDir));
    const float NdotL = saturate(dot(N, toLight));
    const float NdotH = saturate(dot(N, H));
    const float LdotH = saturate(dot(toLight, H));

    //BRDF terms for target function (DGF Microfaset BRDF)
    const float roughness = surface.roughness;
    float D = evalNdfGGX(roughness * roughness, NdotH);
    float G = evalMaskingSmithGGXSeparable(roughness, NdotL, NdotV);

    float specular = surface.specular;
    float F = specular < 1e-8f ? 0.f :  evalFresnelSchlick(specular, 1.f, LdotH);     //Right way
    //float F = specular < 1e-8f ? 0.f : evalFresnelSchlick(specular, 1.f, LdotH) / specular; //Not "right" but less noisier

    //eval brdf terms
    float diffuseBRDF = NdotL * M_1_PI;
    float specularBRDF = D * G * F / (4.f * NdotV);

    //Mix diffuse and specular BRDF
    float brdf = max(0.f, lerp(specularBRDF, diffuseBRDF, surface.diffuseProb));
    return brdf * NdotL;
#else //Diffuse shading only
    const float3 N = surface.normal;
    const float NdotL = saturate(dot(N, ls.dir));

    //Eval BSDF
    float diffuseBRDF = NdotL * M_1_PI;
    diffuseBRDF /= surface.diffuseProb;
    
    return diffuseBRDF * ls.Li; 
#endif   
}

[shader("raygeneration")]
void rayGen()
{
    uint2 launchIndex = DispatchRaysIndex().xy;
    uint2 launchDim = DispatchRaysDimensions().xy;
    
    HitInfo hitInfo = HitInfo(gVBuffer[launchIndex]);
    if(!hitInfo.isValid())
        gSurfaceData[index2Dto1D(launchIndex, launchDim.x)] = Surface().pack();

    float3 view = -gView[launchIndex].xyz;
    float linZ = gLinZ[launchIndex];
    let lod = ExplicitLodTextureSampler(0.f);
    ShadingData sd = loadShadingData(hitInfo, view, lod);
    let bsdf = gScene.materials.getBSDF(sd, lod);
    let bsdfProperties = bsdf.getProperties(sd);

    TraceData traceData = TraceData::create();
    traceData.sg = SampleGenerator(launchIndex, gFrameCount + 15 * 13);    //TODO add seed offset

    BSDFSample bsdfSample;
    bool valid = bsdf.sample(sd, traceData.sg, bsdfSample, true);

    //Fill Surface Buffer used for calculating the target PDF
    Surface surface = Surface::create(sd.computeNewRayOrigin(), sd.N, sd.V, linZ, bsdfProperties.roughness,
                                      luminance(bsdfProperties.diffuseReflectionAlbedo), luminance(bsdfProperties.specularReflectance));


    
    float targetPdf = getSurfacePdf(surface, bsdfSample.wo);
    
    //float weight;
    
    //weight = evalWeight(sd, bsdfProperties.diffuseReflectionAlbedo, bsdfProperties.specularReflectionAlbedo, bsdfProperties.roughness, bsdfSample.wo);
    //const float NdotL = saturate(dot(sd.N, bsdfSample.wo));
    //pdf = bsdfProperties.diffuseReflectionAlbedo * NdotL * M_1_PI;
    //weight *= saturate(dot(sd.N, bsdfSample.wo));
    //weight /= bsdfSample.pdf;
    
    //This needs to be done in final shading, except the pdf
    //pdf = bsdf.eval(sd, bsdfSample.wo, traceData.sg);
    //pdf /= bsdfSample.pdf;
    
    RayDesc tRay;
    tRay.Origin = sd.computeNewRayOrigin();
    tRay.TMin = 0.0;
    tRay.TMax = 1000.f;
    tRay.Direction = bsdfSample.wo;    //Use as Normal

    TraceRay(gScene.rtAccel, 0, 0xff /* instanceInclusionMask */, 1 /* hitIdx */, rayTypeCount, 1 /* missIdx */, tRay, traceData);

    if(traceData.distance < 0)
        return;
    hitInfo = HitInfo(traceData.packedHitInfo);
    sd = loadShadingData(hitInfo, bsdfSample.wo, lod);
    
    let pmbsdf = gScene.materials.getBSDF(sd, lod);
    let pmbsdfProperties = pmbsdf.getProperties(sd);
    
    //PM
    
    //Prepare payload
    RayData rayData = RayData();
    rayData.diffuseReflectance = pmbsdfProperties.diffuseReflectionAlbedo;          //Diffuse reflectance is stored in flux before collection
    rayData.radiance = float3(0.f);
    
    //Ray description 
    RayDesc ray;
    ray.Origin = sd.posW;
    ray.TMin = 0.0;
    ray.TMax = 0.0001;
    ray.Direction = sd.N;    //Use as Normal

    //Closest hit shader can be skipped
    uint rayFlags = RAY_FLAG_SKIP_CLOSEST_HIT_SHADER | RAY_FLAG_SKIP_TRIANGLES;
    
    TraceRay(gPhotonAS, rayFlags, 0xFF /* instanceInclusionMask */, 0 /* hitIdx */, 0 /* rayType count */, 0 /* missIdx */, ray, rayData);
    float3 radiance = rayData.radiance / (M_PI * gPhotonRadius * gPhotonRadius);    //Get new flux
    //radiance *= 0.008;   //TODO: Remove this factor
    //Get diffuse probability as we ignore all specular parts
    float diffProb = luminance(pmbsdfProperties.diffuseReflectionAlbedo);
    float NdotV = saturate(dot(sd.N, sd.V));
    float ggxAlpha = pmbsdfProperties.roughness * pmbsdfProperties.roughness;
    float3 specularReflectance = approxSpecularIntegralGGX(pmbsdfProperties.specularReflectance, ggxAlpha, NdotV);
    float specProb = luminance(specularReflectance);

    float diffFactor = (diffProb + specProb) / diffProb;
    radiance *= diffFactor;

    //ReSTIR Candidate
    LightSample ls = {};
    ls.lightIdx = index2Dto1D(launchIndex, launchDim.x);
    ls.Li = luminance(radiance);
    ls.invSelectPdf = 1.f/bsdfSample.pdf;

    targetPdf *= ls.Li;

    Reservoir r = Reservoir();

    if (valid)
    {
        updateReservoir(r, ls, targetPdf, sampleNext1D(traceData.sg)); //Add the candidate
        finalizeSample(r, 1.f, 1.f);
    }
    
    //Create the light
    VPL photonLight = {};
    if (valid)
    {
        bool vplValid = true;
        if (any(isnan(radiance)) || any(isinf(radiance)) || any(radiance < 0))
            vplValid = false;
        photonLight.posW = sd.computeNewRayOrigin();
        photonLight.normal = sd.N;
        photonLight.flux = radiance;
        photonLight.valid = vplValid;
    }
    
    gReservoir[launchIndex] = r.pack();
    gPhotonLights[index2Dto1D(launchIndex, launchDim.x)] = photonLight.pack();
    gSurfaceData[index2Dto1D(launchIndex, launchDim.x)] = surface.pack();
}
