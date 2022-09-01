#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"


import Scene.RaytracingInline;
import Scene.Material.ShadingUtils;
import Rendering.Materials.Microfacet;
import Rendering.Materials.Fresnel;
import Utils.Sampling.SampleGenerator;
import Utils.Math.MathHelpers;
import Utils.Color.ColorHelpers;

import Rendering.Lights.EmissiveLightSampler;
import Rendering.Lights.EmissiveLightSamplerHelpers;
import Reservoir;
import SurfaceData;


RWTexture2D<uint4> gReservoir;
RWTexture2D<uint> gReservoirUV;


StructuredBuffer<PackedSurfaceData>gSurface;


cbuffer PerFrame
{
    uint gFrameCount;                   //Current it for sample gen
}

cbuffer Constant
{
    uint gNumEmissiveSamples;       // Num emissive samples
    uint2 gFrameDim;                //Frame Dimensions for camera dir
    bool gTestVisibility;
}


struct LightSample{
    uint lightIdx;
    float3 dir;
    float Li;
    float selectPdf;
    float2 uv;
    //Enum type later ? 
};

static const float kRayEpsilon = 0.99f;

uint index2Dto1D(uint2 idx, uint width){
    return idx.x + width * idx.y;
}

Surface getSurface(uint2 idx){
    float3 viewDir = gScene.camera.computeRayPinhole(idx, gFrameDim).dir;
    PackedSurfaceData surfaceData = gSurface[index2Dto1D(idx, gFrameDim.x)];
    
    return Surface(surfaceData, -viewDir);
}

bool sampleEmissiveTriangle(float3 rnd, const float3 surfacePosition, out LightSample ls, out float sampleDistance){
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
    float3 toLight = posW - surfacePosition;
    float distSqr= max(FLT_MIN, dot(toLight, toLight)); // Clamp to avoid NaNs below
    sampleDistance = sqrt(distSqr);     //Distance is needed for optinal visibility ray
    ls.dir = toLight/ sampleDistance;    //normalize

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
    //pdf *= ls.selectPdf;
    ls.Li = LeF / pdf;

    return true;
}

//Generates a light sample. Returns false if sample is invalid
bool generateSample(inout SampleGenerator sg, const float3 surfacePosition,out LightSample ls, out float sampleDistance){
    if(!sampleEmissiveTriangle(sampleNext3D(sg), surfacePosition, ls, sampleDistance)) return false;
        
    //If different lights are supported add MIS weight
    return (ls.Li > 0.f);    //return true if valid sample
}

//gets the target pdf averaged to one channel
float getSurfacePdf(in Surface surface, in LightSample ls){

    const float3 N = surface.normal;
    const float3 H = normalize(surface.viewDir + ls.dir);
    const float NdotV = saturate(dot(N, surface.viewDir));
    const float NdotL = saturate(dot(N, ls.dir));
    const float NdotH = saturate(dot(N, H));
    const float LdotH = saturate(dot(ls.dir, H));

    //BRDF terms for target function (DGF Microfaset BRDF)
    const float roughness = surface.roughness;
    float D = evalNdfGGX(roughness * roughness, NdotH);
    float G = evalMaskingSmithGGXSeparable(roughness, NdotL, NdotV);

    float specular = surface.specular;
    //float F = specular < 1e-8f ? 0.f :  evalFresnelSchlick(specular, 1.f, LdotH);     //Right way
    float F = specular < 1e-8f ? 0.f :  evalFresnelSchlick(specular, 1.f, LdotH)/specular; //Not "right" but less noisier

    //eval brdf terms
    float diffuseBRDF = NdotL * M_1_PI;
    float specularBRDF = D*G*F/(4.f * NdotV);

    //Mix diffuse and specular BRDF
    float brdf = max(0.f, lerp(specularBRDF, diffuseBRDF, surface.diffuseProb));
    return brdf * ls.Li; 
}

bool updateReservoir(inout Reservoir r, in LightSample ls,float targetPdf, float rnd){
    float risWeight = targetPdf / ls.selectPdf;
    r.weightSum += risWeight;
    r.M += 1;
    bool selectSample = (rnd * r.weightSum < risWeight);
    
    if(selectSample){
        r.lightIdx = ls.lightIdx;
        r.uv = ls.uv;
        r.targetPdf = targetPdf;
    }
    return selectSample;
}

void finalizeSample(inout Reservoir r, float normalizationNumerator, float normalizationDenominator){
    float denominator = r.targetPdf * normalizationDenominator;

    r.weightSum = denominator > 0 ? (r.weightSum * normalizationNumerator) / denominator : 0.f;
}

[numthreads(16, 16, 1)]
void main(uint2 dTid : SV_DispatchThreadID)
{
    SampleGenerator sg = SampleGenerator(dTid, gFrameCount);
    Reservoir r = Reservoir();

    //Get shading data
    Surface surface = getSurface(dTid);
    if (!surface.valid)
    {
        return;
    }

    float selectedDistance = 0;
    float3 selectedDirection = float3(0,1,0);
    
    for(uint i = 0; i< gNumEmissiveSamples; i++){
        LightSample ls;
        float sampleDistance;
        bool valid = generateSample(sg,surface.posW, ls, sampleDistance);
        if(!valid) continue;
        float targetPdf = getSurfacePdf(surface, ls);
        if(updateReservoir(r,ls, targetPdf, sampleNext1D(sg))){
            selectedDistance = sampleDistance;
            selectedDirection = ls.dir;
        }
    }

    //Finalize sample
    r.M = 1;    //Every reservoir has the same amount of initial samples
    finalizeSample(r, 1.f, gNumEmissiveSamples);

    bool validSample = r.weightSum > 0 && !isnan(r.weightSum) && !isinf(r.weightSum);
    
    //Test visibility and shoot a shadow ray from the surface to the selected light
    if(validSample && gTestVisibility){
        
        selectedDistance *= kRayEpsilon;
        // Ray Query for shadow test; <0> means disabled alpha testing; TODO: Add static const for alpha test
        SceneRayQuery<0> rayQuery;
        const Ray ray = Ray(surface.posW, selectedDirection, VIS_RAY_OFFSET, selectedDistance);
        if (!rayQuery.traceVisibilityRay(ray, RAY_FLAG_CULL_NON_OPAQUE, 0xff))
        {
            r.weightSum = 0.f;  //Set weight to zero if light is not visible
        }
    }

    if(!validSample)
        r = Reservoir();
    
    gReservoir[dTid] = r.pack();
    gReservoirUV[dTid] = r.packedUV;
}
