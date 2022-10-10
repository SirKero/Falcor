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
import Lights;

#ifndef USE_PRESAMPLED
#define USE_PRESAMPLED 1
#endif

//define a title size for Presampled light sampling
#ifndef PRESAMPLED_TITLE_SIZE
#define PRESAMPLED_TITLE_SIZE 16
#endif

#define is_valid(name) (is_valid_##name != 0)

RWTexture2D<uint4> gReservoir;
RWTexture2D<uint> gReservoirUV;

StructuredBuffer<PackedReSTIRLight> gLights;

StructuredBuffer<PackedSurfaceData>gSurface;

Texture2D<float4> gView;

#if USE_PRESAMPLED
StructuredBuffer<uint2> gPresampledLight;
#endif //USE_PRESAMPLED
static const bool kUsePdfSampling = USE_PRESAMPLED;

cbuffer PerFrame
{
    uint gFrameCount;                   //Current it for sample gen
}

cbuffer Constant
{
    uint gNumEmissiveSamples;       // Num emissive samples
    uint2 gFrameDim;                //Frame Dimensions for camera dir
    bool gTestVisibility;
    uint2 gLightBufferSize;         //Light buffer size vars. If UsePdf x = Title Count, y = Title Size. If !UsePdf x = lightBufferSize, y = empty
    uint2 _pad;
}


struct LightSample{
    uint lightIdx;
    float3 dir;
    float Li;
    float invSelectPdf;
    float2 uv;
    //Enum type later ? 
};

static const float kRayEpsilon = 0.99f;

uint index2Dto1D(uint2 idx, uint width){
    return idx.x + width * idx.y;
}

Surface getSurface(uint2 idx){
    float3 viewDir;
    if(is_valid(gView)){
       viewDir = gView[idx].xyz;
    }else{
       viewDir = gScene.camera.computeRayPinhole(idx, gFrameDim).dir * -1;  //Flip ViewDir here 
    }
    PackedSurfaceData surfaceData = gSurface[index2Dto1D(idx, gFrameDim.x)];
    
    return Surface(surfaceData, viewDir);
}

//Generates a light sample. Returns false if sample is invalid
bool sampleLight(float3 rnd, const float3 surfacePosition, 
#if USE_PRESAMPLED
                 uint titleIdx,  
#endif
                 out LightSample ls, out float sampleDistance){
#if USE_PRESAMPLED
    //Get light idx and invSelectPdf
    uint rndTitleSize = min(uint(rnd.x * gLightBufferSize.y), gLightBufferSize.y - 1);
    uint2 presampleData = gPresampledLight[titleIdx + rndTitleSize]; //x = idx, y = invSourcePdf
    ls.invSelectPdf = asfloat(presampleData.y);
    if(ls.invSelectPdf <= 0) return false;
    ls.lightIdx = presampleData.x;
#else//USE_PRESAMPLED || Random Uniform sampling
    ls.lightIdx = min(uint(floor(rnd.x * gLightBufferSize.x)), gLightBufferSize.x-1);
    ls.invSelectPdf = gLightBufferSize.x;
    if(ls.invSelectPdf <= 0) return false;
#endif //USE_PRESAMPLED

    //Get Light
    ReSTIRLight light = ReSTIRLight(gLights[ls.lightIdx]);
    
    // Uniformly sample the triangle's area by folding the random numbers such that u & v sum to less than 1.
    ls.uv = ((rnd.y + rnd.z) <= 1.f) ? rnd.yz : 1.f - rnd.yz;
    float3 normal = cross(light.edge0 , light.edge1);
    const float normalLength = length(normal);
    const float area = 0.5f * normalLength;
    normal /= normalLength;

    float3 pos = light.pos + ls.uv.x * light.edge0 + ls.uv.y * light.edge1;
    const float3 toLight = pos - surfacePosition;
    float distSqr= max(FLT_MIN, dot(toLight, toLight)); // Clamp to avoid NaNs below
    sampleDistance = sqrt(distSqr);     //Distance is needed for optinal visibility ray
    ls.dir = toLight/ sampleDistance;    //normalize

    //Reject sample if light is backfacing
    float cosTheta = dot(normal, -ls.dir);
    if(cosTheta <= 0) return false;

    //TODO add option for emissive texture evaluation here
    //Calculate Li for later
    float denom = max(FLT_MIN, cosTheta * area); //Clamp to avoid nans
    float pdf = distSqr / denom;
    ls.Li = light.avgRadiance / pdf;
    
    return ls.Li > 0;   //true if sample is valid
}

//gets the target pdf averaged to one channel
float getSurfacePdf(in Surface surface, in LightSample ls){
#ifndef DIFFUSE_SHADING_ONLY
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
#else //Diffuse shading only
    const float3 N = surface.normal;
    const float NdotL = saturate(dot(N, ls.dir));

    //Eval BSDF
    float diffuseBRDF = NdotL * M_1_PI;
    diffuseBRDF /= surface.diffuseProb;
    
    return diffuseBRDF * ls.Li; 
#endif   
}

bool updateReservoir(inout Reservoir r, in LightSample ls,float targetPdf, float rnd){
    float risWeight = targetPdf * ls.invSelectPdf;
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
    
#if USE_PRESAMPLED
    SampleGenerator titleRng = SampleGenerator(dTid / PRESAMPLED_TITLE_SIZE, gFrameCount + 1 * 13);
    uint rndTitle = min(uint(sampleNext1D(titleRng) * gLightBufferSize.x), gLightBufferSize.x-1);     //Get random title
    rndTitle *= gLightBufferSize.y;      //Move to start index
#endif
    
    for(uint i = 0; i< gNumEmissiveSamples; i++){
        LightSample ls;
        float sampleDistance;
        //Sample light (presampled takes an additional input)
        bool valid = sampleLight(sampleNext3D(sg),surface.posW,
        #if USE_PRESAMPLED
                                rndTitle, 
        #endif
                                ls, sampleDistance);
        
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
        const Ray ray = Ray(surface.posW, selectedDirection, 0.f, selectedDistance);
        if (!rayQuery.traceVisibilityRay(ray, RAY_FLAG_CULL_NON_OPAQUE, 0xff))
        {
            r.weightSum = 0.f;  //Set weight to zero if light is not visible
        }
    }
        
    gReservoir[dTid] = r.pack();
    gReservoirUV[dTid] = r.packedUV;
}
