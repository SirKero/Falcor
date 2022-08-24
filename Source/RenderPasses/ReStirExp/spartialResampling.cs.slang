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

StructuredBuffer<Reservoir> gReservoir;
RWStructuredBuffer<Reservoir> gOutReservoir;

Texture1D<snorm float2> gNeighOffsetBuffer;
StructuredBuffer<PackedSurfaceData>gSurface;
Texture2D<float2> gMVec;

#define BIAS_MODE_BASIC 1
#define BIAS_MODE_RAYTRACE 2
//This is for syntax highlightig
#ifndef BIAS_CORRECTION_MODE
    #define BIAS_CORRECTION_MODE 2
#endif
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

uint index2Dto1D(uint2 idx, uint width){
    return idx.x + width * idx.y;
}

Surface getSurface(uint2 idx){
    float3 viewDir = gScene.camera.computeRayPinhole(idx, gFrameDim).dir;//TODO: Use prev view dir for last frame
    PackedSurfaceData surfaceData = gSurface[index2Dto1D(idx, gFrameDim.x)];
    
    return Surface(surfaceData, -viewDir);
}

bool isValidNeighbor(float3 currNormal, float currLinZ, float3 neighNormal, float neighLinZ){
    float normalCheck = dot(currNormal, neighNormal);
    float minLinZDiff = currLinZ * gDepthThreshold;
    float linZDiff = abs(currLinZ - neighLinZ);
    return ( (normalCheck >= gNormalThreshold) && (linZDiff <= minLinZDiff) );
}

bool getEmissiveTriangle(uint triangleIdx, float2 uv, const float3 surfacePos, out LightSample ls, out float distance){
    const uint activeTriangleCount = gScene.lightCollection.getActiveTriangleCount();
    ls.lightIdx = triangleIdx;
    ls.selectPdf = 1.f/activeTriangleCount;

    //get triangle data and sample uniformly
    const EmissiveTriangle tri = gScene.lightCollection.getTriangle(ls.lightIdx);
    const float3 barycentrics = sample_triangle(uv);
    float3 posW = tri.getPosition(barycentrics);
    float3 toLight = posW - surfacePos;
    float distSqr= max(FLT_MIN, dot(toLight, toLight)); // Clamp to avoid NaNs below
    distance = sqrt(distSqr);
    ls.dir = toLight / distance; //normalize

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

bool combineReservoir(inout Reservoir r, in Reservoir prev,float targetPDF, float rnd){
    float normalizationFactor = prev.W * prev.M;

    float risWeight = targetPDF * normalizationFactor;
    
    r.M += prev.M;
    
    r.weightSum += risWeight;

    bool selectSample = (rnd * r.weightSum < risWeight);
    
    if(selectSample){
        r.lightIdx = prev.lightIdx;
        r.uv = prev.uv;
        r.targetPdf = targetPDF;
    }

    return selectSample;
}

void finalizeSample(inout Reservoir r, float normalizationNumerator, float normalizationDenominator)
{
    float denominator = r.targetPdf * normalizationDenominator;

    r.W = denominator > 0 ? (r.weightSum * normalizationNumerator) / denominator : 0.f;
}

Reservoir getReservoir(int2 idx)
{
    Reservoir r = gReservoir[index2Dto1D(idx, gFrameDim.x)];
    
    if (r.W <= 0 || isinf(r.W) || isnan(r.W))
        r = Reservoir.create();
    return r;
}

[numthreads(16, 16, 1)]
void main(uint2 dTid : SV_DispatchThreadID)
{
    SampleGenerator sg = SampleGenerator(dTid, gFrameCount + 5 * 13);
    Reservoir r = Reservoir.create();

    //Check if surface is valid
    Surface currentSurface = getSurface(dTid);
    if (!currentSurface.valid)
        return;
    
    //Load reservoir from current iteration
    Reservoir current = getReservoir(dTid);
    
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

        cachedResults |= (1u << i);
        //Get neightbor light target PDF for current surface
        float targetPdf = 0;
        if(neigh.M > 0){
            LightSample ls = { };
            float distance = 0;
            bool valid = getEmissiveTriangle(neigh.lightIdx, neigh.getUV(), currentSurface.posW, ls, distance);
            targetPdf = valid ?  getSurfacePdf(currentSurface, ls): 0.f;
        }
        
        if (combineReservoir(r, neigh, targetPdf, sampleNext1D(sg)))
        {
            selectedSample = i;
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
        bool valid = getEmissiveTriangle(r.lightIdx, r.getUV(), biasSurface.posW, ls, distance);
        float ps = valid ? getSurfacePdf(biasSurface, ls) : 0.0;

        //Trace ray
        #if BIAS_CORRECTION_MODE >= BIAS_MODE_RAYTRACE
        if (ps > 0)
        {
            SceneRayQuery < 0 > rayQuery;
            distance *= 0.99;
            float3 rayPos = biasSurface.posW + biasSurface.normal * 0.01;
            const Ray ray = Ray(rayPos, ls.dir, 0.f, distance);
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
    
        if (r.W <= 0 || isnan(r.W) || isinf(r.W))
        {
            r = current; //If resampled is invalid use the current reservoir instead
        }
    
    gOutReservoir[index2Dto1D(dTid, gFrameDim.x)] = r;
}
