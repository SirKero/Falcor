#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"


import Utils.Math.PackedFormats;
import Utils.Math.FormatConversion;

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
import VPLs;

#ifndef USE_VISIBILITY_CHECK_INLINE
#define USE_VISIBILITY_CHECK_INLINE 0
#endif

#ifndef USE_PRESAMPLING
#define USE_PRESAMPLING 1
#endif

//define a title size for Presampled light sampling
#ifndef PRESAMPLED_TITLE_SIZE
#define PRESAMPLED_TITLE_SIZE 16
#endif

RWTexture2D<uint4> gReservoir;

StructuredBuffer<uint2> gPresampledLights;
StructuredBuffer<PackedVPL> gVPLs;
Buffer<uint> gVPLCounter;

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
    float gGeometryTermBand;        //Invalidates samples with very small distances (Adds Bias)
    uint2 gNumLights;                //Light Buffer Size. If Presampling enabled, x = Title Count, y= Title Size. If !Presampling, then x = Size LightBuffer 
    float gRadius;
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
    float3 viewDir = gScene.camera.computeRayPinhole(idx, gFrameDim).dir;
    PackedSurfaceData surfaceData = gSurface[index2Dto1D(idx, gFrameDim.x)];
    
    return Surface(surfaceData, -viewDir);
}
//Generates a light sample. Returns false if sample is invalid
bool generateSample(float rnd, const float3 surfacePosition,
#if USE_PRESAMPLING
                    uint titleIdx,
#endif
                    out LightSample ls, out VPL vpl, out float sampleDistance){

#if USE_PRESAMPLING
        //Sample the presample texture
        uint rndTitle = min(uint(floor(rnd * float(gNumLights.y))), gNumLights.y - 1);
        uint2 presampleData = gPresampledLights[titleIdx + rndTitle]; //x = idx, y = invSourcePdf
        ls.invSelectPdf = asfloat(presampleData.y);
        if(ls.invSelectPdf <= 0) return false;
        ls.lightIdx = presampleData.x;
#else
        //Old random sample code 
        const uint lightCount = min(gVPLCounter[0], gNumLights.x);
        if(lightCount == 0) return false;
        //get random light
        const uint rndLightIndex = min(uint(lightCount * rnd), lightCount-1);
        ls.lightIdx = rndLightIndex;
        ls.invSelectPdf = float(lightCount);
#endif   //USE_PDF_SAMPLING   
    
    vpl = VPL(gVPLs[ls.lightIdx]);
    float3 toLight = vpl.posW - surfacePosition;
    float distSqr= max(FLT_MIN, dot(toLight, toLight)); // Clamp to avoid NaNs below
    sampleDistance = sqrt(distSqr);     //Distance is needed for optinal visibility ray
    ls.dir = toLight/ sampleDistance;    //normalize
    float cosTheta = dot(vpl.normal, -ls.dir);
    if(cosTheta <= 0 || sampleDistance < gRadius || vpl.valid == 0) return false;
    
    float pdf = distSqr / max(FLT_MIN,cosTheta);
    float Le = luminance(vpl.flux);
    
    ls.Li = Le / pdf;
        
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

[numthreads(16, 16, 1)]
void main(uint2 dTid : SV_DispatchThreadID)
{
    SampleGenerator sg = SampleGenerator(dTid, gFrameCount + 3 *13);
    Reservoir r = Reservoir();

    //Get shading data
    Surface surface = getSurface(dTid);
    if (!surface.valid)
    {
        return;
    }

    float selectedDistance = 0;
    float3 selectedDirection = float3(0,1,0);
    VPL selectedLight = {};

#if USE_PRESAMPLING
    SampleGenerator titleRng = SampleGenerator(dTid / PRESAMPLED_TITLE_SIZE, gFrameCount + 4 * 13);
    uint rndTitle = min(uint(sampleNext1D(titleRng) * gNumLights.x), gNumLights.x-1);     //Get random title
    rndTitle *= gNumLights.y;      //Move to start index
#endif
    
    for(uint i = 0; i< gNumEmissiveSamples; i++){
        LightSample ls;
        VPL vpl;
        float sampleDistance;
        
        bool valid = generateSample(sampleNext1D(sg),surface.posW,
#if USE_PRESAMPLING
                                    rndTitle,
#endif
                                    ls, vpl, sampleDistance);

        if(!valid) continue;
        float targetPdf = getSurfacePdf(surface, ls);
        if(updateReservoir(r,ls, targetPdf, sampleNext1D(sg))){
            selectedDistance = sampleDistance;
            selectedDirection = ls.dir;
            selectedLight = vpl;
        }
    }

    //Finalize sample
    r.M = 1;    //Every reservoir has the same amount of initial samples
    finalizeSample(r, 1.f, gNumEmissiveSamples);

    bool validSample = r.weightSum > 0 && !isnan(r.weightSum) && !isinf(r.weightSum);

#if USE_VISIBILITY_CHECK_INLINE
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
#endif
    
    gReservoir[dTid] = r.pack();
}
