#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.Raytracing;
import Scene.Material.ShadingUtils;
import Rendering.Materials.Microfacet;
import Rendering.Materials.Fresnel;
import Utils.Sampling.SampleGenerator;
import Utils.Math.MathHelpers;
import Utils.Color.ColorHelpers;

import Rendering.Lights.EmissiveLightSampler;
import Rendering.Lights.EmissiveLightSamplerHelpers;
import Reservoir;


RWStructuredBuffer<Reservoir> gReservoir;

Texture2D<PackedHitInfo> gVBuffer;
Texture2D<float2> gMVec;


cbuffer PerFrame
{
    uint gFrameCount;                   //Current it for sample gen
    uint gNumEmissiveSamples;       // Num emissive samples
    uint2 gFrameDim;                //Frame Dimensions for camera dir 
}


struct LightSample{
    uint lightIdx;
    float3 dir;
    float Li;
    float selectPdf;
    float2 uv;
    //Enum type later ? 
};

cbuffer Light
{
    EmissiveLightSampler gEmissiveSampler;
};


uint index2Dto1D(uint2 idx, uint width){
    return idx.x + width * idx.y;
}

uint float2toUint(float2 xy){
    uint u = f32tof16(xy.x);
    uint v = f32tof16(xy.y);
    return (u << 16u) | v;
}

ShadingData loadShadingData(const HitInfo hit, const float3 rayDir, const ITextureSampler lod)
{
    const TriangleHit triangleHit = hit.getTriangleHit();
    VertexData v = gScene.getVertexData(triangleHit);
    uint materialID = gScene.getMaterialID(triangleHit.instanceID);
    ShadingData sd = gScene.materials.prepareShadingData(v, materialID, -rayDir, lod);
    adjustShadingNormal(sd, v);
    
    return sd;
}

bool sampleEmissiveTriangle(float3 rnd, in ShadingData sd, out LightSample ls){
    const uint activeTriangleCount = gScene.lightCollection.getActiveTriangleCount();
    if(activeTriangleCount == 0) return false;
    //get random active triangle
    const uint rndTriangleIndex = min(uint(activeTriangleCount * rnd.x), activeTriangleCount-1);
    ls.lightIdx = gScene.lightCollection.activeTriangles[rndTriangleIndex];
    ls.selectPdf = 1.f/activeTriangleCount;

    //get triangle data and sample uniformly
    const EmissiveTriangle tri = gScene.lightCollection.getTriangle(ls.lightIdx);
    const float3 barycentrics = sample_triangle(rnd.yz);
    ls.uv = rnd.yz; //store uv for later
    float3 posW = tri.getPosition(barycentrics);
    float3 toLight = posW - sd.posW;
    float distSqr= max(FLT_MIN, dot(toLight, toLight)); // Clamp to avoid NaNs below
    ls.dir = toLight/ sqrt(distSqr);    //normalize

    //Reject sample if light is backfacing
    //TODO Set this an an define?
    float cosTheta = dot(tri.normal, -ls.dir);
    if(cosTheta < 0) return false;

    //TODO: Add define if pre integrated emission or texture should be used
    //Get emission
    float3 Le = gScene.lightCollection.getAverageRadiance(ls.lightIdx);

    //Calculate Li for later
    float denom = max(FLT_MIN, cosTheta * tri.area); //Clamp to avoid nans
    float pdf = distSqr / denom;
    //float LeF = (Le.x + Le.y + Le.z)/3;
    float LeF = luminance(Le);
    pdf *= ls.selectPdf;
    ls.Li = LeF / pdf;

    return true;
}

//Generates a light sample. Returns false if sample is invalid
bool generateSample(inout SampleGenerator sg, in ShadingData sd,out LightSample ls){
    if(!sampleEmissiveTriangle(sampleNext3D(sg), sd, ls)) return false;
        
    //If different lights are supported add MIS weight
    return (ls.Li > 0.f);    //return true if valid sample
}

//gets the target pdf averaged to one channel
float getSurfacePdf(in BSDFProperties bsdfProperties, in ShadingData sd, inout SampleGenerator sg, in LightSample ls){

    float3 H = normalize(sd.V + ls.dir);
    float NdotV = saturate(dot(sd.N, sd.V));
    float NdotL = saturate(dot(sd.N, ls.dir));
    float NdotH = saturate(dot(sd.N, H));
    float LdotH = saturate(dot(ls.dir, H));

    //BRDF terms for target function (DGF Microfaset BRDF)
    float D = evalNdfGGX(bsdfProperties.roughness * bsdfProperties.roughness, NdotH);
    float G = evalMaskingSmithGGXSeparable(bsdfProperties.roughness, NdotL, NdotV);

    float specular = luminance(bsdfProperties.specularReflectance);
    //float F = specular < 1e-8f ? 0.f :  evalFresnelSchlick(specular, 1.f, LdotH);     //Right way
    float F = specular < 1e-8f ? 0.f :  evalFresnelSchlick(specular, 1.f, LdotH)/specular; //Not "right" but less noisier

    //eval brdf terms
    float diffuseBRDF = NdotL * M_1_PI;
    float specularBRDF = D*G*F/(4.f * NdotV);

    //Mix diffuse and specular BRDF
    float diffuseProb = luminance(bsdfProperties.diffuseReflectionAlbedo);
    float brdf = max(0.f, lerp(specularBRDF, diffuseBRDF, diffuseProb));
    return brdf * ls.Li; 
}

void updateReservoir(inout Reservoir r, in LightSample ls,float targetPdf, float rnd){
    float weight = targetPdf / ls.selectPdf;
    r.weightSum += weight;
    r.M += 1;
    if(rnd < (weight / r.weightSum)){
        r.lightIdx = ls.lightIdx;
        r.setUV(ls.uv);
        r.targetPdf = targetPdf;
    }
}

[numthreads(16, 16, 1)]
void main(uint2 dTid : SV_DispatchThreadID)
{
    
    SampleGenerator sg = SampleGenerator(dTid, gFrameCount);
    Reservoir r = Reservoir.create();
    
    //Get shading data
    HitInfo hitInfo = HitInfo(gVBuffer[dTid]);    
    let lod = ExplicitLodTextureSampler(0.f);
    //Recreate the V-Buffer ray for direction
    Ray cameraRay = gScene.camera.computeRayPinhole(dTid, gFrameDim);
    ShadingData sd = loadShadingData(hitInfo, cameraRay.dir, lod);
    let bsdf = gScene.materials.getBSDF(sd, lod);
    let bsdfProperties = bsdf.getProperties(sd);
    
    for(uint i = 0; i< gNumEmissiveSamples; i++){
        LightSample ls;
        bool valid = generateSample(sg,sd, ls);
        if(!valid) continue;
        float targetPdf = getSurfacePdf(bsdfProperties, sd, sg, ls);
        updateReservoir(r,ls, targetPdf, sampleNext1D(sg));
    }
    if(r.targetPdf > 0){
        r.W = 1.f/r.targetPdf * (r.weightSum / gNumEmissiveSamples);  
    }
    
    gReservoir[index2Dto1D(dTid, gFrameDim.x)] = r;
}
