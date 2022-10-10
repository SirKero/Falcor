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

#define BIAS_MODE_BASIC 1
#define BIAS_MODE_RAYTRACE 2
//This is for syntax highlightig
#ifndef BIAS_CORRECTION_MODE
    #define BIAS_CORRECTION_MODE 2
#endif

//Define for valid texture channels
#define is_valid(name) (is_valid_##name != 0)

Texture2D<uint4> gReservoir;
Texture2D<uint> gReservoirUV;
RWTexture2D<uint4> gOutReservoir;
RWTexture2D<uint> gOutReservoirUV;

Texture1D<snorm float2> gNeighOffsetBuffer;
StructuredBuffer<PackedReSTIRLight> gLights;
StructuredBuffer<PackedSurfaceData>gSurface;
Texture2D<float2> gMVec;
Texture2D<float4> gView;

static const uint kNeighOffsetMask = OFFSET_BUFFER_SIZE;

cbuffer PerFrame
{
    uint gFrameCount;                   //Current it for sample gen
}

cbuffer Constant
{
    uint2 gFrameDim;                //Frame Dimensions for camera dir
    uint gSpartialSamples;
    float gSamplingRadius;
    float gDepthThreshold;          //Relative depth offset
    float gNormalThreshold;         //Maximum cosine between both Normals that is allowed
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

Reservoir getReservoir(int2 idx)
{
    Reservoir r =  Reservoir(gReservoir[idx], gReservoirUV[idx]);

    //Discard invalid reservoirs
    if (isinf(r.weightSum) || isnan(r.weightSum))
        r = Reservoir();
    return r;
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

bool isValidNeighbor(float3 currNormal, float currLinZ, float3 neighNormal, float neighLinZ){
    float normalCheck = dot(currNormal, neighNormal);
    float minLinZDiff = currLinZ * gDepthThreshold;
    float linZDiff = abs(currLinZ - neighLinZ);
    return ( (normalCheck >= gNormalThreshold) && (linZDiff <= minLinZDiff) );
}

bool getEmissiveTriangle(in ReSTIRLight light, float2 uv, const float3 surfacePos, out LightSample ls, out float distance){
    if(!light.isValid()) return false;

    ls.uv = uv;
    
    float3 normal = cross(light.edge0 , light.edge1);
    const float normalLength = length(normal);
    const float area = 0.5f * normalLength;
    normal /= normalLength;

    float3 pos = light.pos + ls.uv.x * light.edge0 + ls.uv.y * light.edge1;
    const float3 toLight = pos - surfacePos;
    float distSqr= max(FLT_MIN, dot(toLight, toLight)); // Clamp to avoid NaNs below
    distance = sqrt(distSqr);     //Distance is needed for optinal visibility ray
    ls.dir = toLight/ distance;    //normalize

    //Reject sample if light is backfacing
    float cosTheta = dot(normal, -ls.dir);
    if(cosTheta <= 0) return false;

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

bool combineReservoir(inout Reservoir r, in Reservoir prev,float targetPDF, float rnd){
    float normalizationFactor = prev.weightSum * prev.M;

    float risWeight = targetPDF * normalizationFactor;
    
    r.M += prev.M;
    
    r.weightSum += risWeight;

    bool selectSample = (rnd * r.weightSum < risWeight);
    
    if(selectSample){
        r.lightIdx = prev.lightIdx;
        r.packedUV = prev.packedUV;
        r.targetPdf = targetPDF;
    }

    return selectSample;
}

void finalizeSample(inout Reservoir r, float normalizationNumerator, float normalizationDenominator)
{
    float denominator = r.targetPdf * normalizationDenominator;

    r.weightSum = denominator > 0 ? (r.weightSum * normalizationNumerator) / denominator : 0.f;
}

[numthreads(16, 16, 1)]
void main(uint2 dTid : SV_DispatchThreadID)
{
    SampleGenerator sg = SampleGenerator(dTid, gFrameCount + 5 * 13);
    Reservoir r = Reservoir();

    //Check if surface is valid
    Surface currentSurface = getSurface(dTid);
    if (!currentSurface.valid)
        return;

    ReSTIRLight selectedLight = ReSTIRLight();
    //Load reservoir from current iteration
    Reservoir current = getReservoir(dTid);
    if(current.weightSum > 0)
        selectedLight = ReSTIRLight(gLights[current.lightIdx]);
    
    combineReservoir(r, current, current.targetPdf, 0.5 /* random */);
    
    uint neighOffsetStartIdx = uint(sampleNext1D(sg) * float(kNeighOffsetMask-1));
    int2 currentIndex = dTid;
    uint numSpartialSamples = min(gSpartialSamples,32); //Cap at 32 samples for the later bias correction
    uint cachedResults = 0;  //Mask for valid neighbor samples
    int selectedSample = -1;  //Index of the selected sample

    //Go through all neighbors
    for(uint i=0 ; i<numSpartialSamples; i++){
        //Get sample from sampling mask
        uint neighBufferIdx = (neighOffsetStartIdx + i) % (kNeighOffsetMask-1);
        float2 randSamp = gNeighOffsetBuffer[neighBufferIdx];
        int2 spartialOffset = int2(round(randSamp * gSamplingRadius));
        int2 idx = currentIndex + spartialOffset;

        //Check if index is valid
        if(idx.x < 0 && idx.y < 0 && idx.x >= gFrameDim.x && idx.y >= gFrameDim.y)
            continue;

        //Get surface and check if valid
        Surface neighSurface = getSurface(idx);
        if (!neighSurface.valid)
            continue;
        
        if(!isValidNeighbor(currentSurface.normal, currentSurface.viewDepth, neighSurface.normal, neighSurface.viewDepth))
            continue;

        //If neighbor has passed the tests get reservoir and compair them
        Reservoir neigh = getReservoir(idx);
        ReSTIRLight neighLight = ReSTIRLight(gLights[neigh.lightIdx]);
        
        cachedResults |= (1u << i);
        //Get neightbor light target PDF for current surface
        float targetPdf = 0;
        if(neigh.M > 0){
            LightSample ls = { };
            float distance = 0;
            bool valid = getEmissiveTriangle(neighLight, neigh.uv, currentSurface.posW, ls, distance);
            targetPdf = valid ?  getSurfacePdf(currentSurface, ls): 0.f;
        }
        
        if (combineReservoir(r, neigh, targetPdf, sampleNext1D(sg)))
        {
            selectedSample = i;
            selectedLight = neighLight;
        }

    }

    //Bias Correction
#if BIAS_CORRECTION_MODE >= BIAS_MODE_BASIC

    float pi = r.targetPdf;
    float piSum = r.targetPdf * current.M;

    //go through all neighbors again
    for (int i = 0; i < numSpartialSamples; i++)
    {
        //Skip if we skipped in last loop
        if ((cachedResults & (1u << i)) == 0)
            continue;

        //Get index
        uint neighBufferIdx = (neighOffsetStartIdx + i) % (kNeighOffsetMask - 1);
        float2 randSamp = gNeighOffsetBuffer[neighBufferIdx];
        int2 spartialOffset = int2(round(randSamp * gSamplingRadius));
        int2 idx = currentIndex + spartialOffset;

        //Get Surface
        Surface biasSurface = getSurface(idx);
        if (!biasSurface.valid)
            continue;

        //Get light pdf
        LightSample ls = { };
        float distance = 0;
        bool valid = getEmissiveTriangle(selectedLight, r.uv, biasSurface.posW, ls, distance);
        float ps = valid ? getSurfacePdf(biasSurface, ls) : 0.0;

        //Trace ray
        #if BIAS_CORRECTION_MODE >= BIAS_MODE_RAYTRACE
        if (ps > 0)
        {
            SceneRayQuery < 0 > rayQuery;
            distance *= kRayEpsilon;
            const Ray ray = Ray(biasSurface.posW, ls.dir, 0.f, distance);
            if (!rayQuery.traceVisibilityRay(ray, RAY_FLAG_NONE, 0xff))
            {
                ps = 0;
            }
        }
        #endif // BIAS MODE RAYTRACE
        
        //getReservoir
        Reservoir biasRes = getReservoir(idx);
        
        pi = selectedSample == i ? ps : pi;
        piSum += ps * biasRes.M;
    }
    finalizeSample(r, pi, piSum);
    
#else
    finalizeSample(r, 1.0f, r.M);
#endif
            
    gOutReservoir[dTid] = r.pack();
    gOutReservoirUV[dTid] = r.packedUV;
}
