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
import PhotonLight;

RWTexture2D<uint4> gReservoir;
Texture2D<uint4> gReservoirPrev;

RWTexture2D<float4> gPhotonReservoirPos;
RWTexture2D<float4> gPhotonReservoirNormal;
RWTexture2D<float4> gPhotonReservoirFlux;
Texture2D<float4> gPhotonReservoirPosPrev;
Texture2D<float4> gPhotonReservoirNormalPrev;
Texture2D<float4> gPhotonReservoirFluxPrev;

StructuredBuffer<PackedSurfaceData>gSurfacePrev;
StructuredBuffer<PackedSurfaceData>gSurface;
Texture2D<float2> gMVec;
Texture2D<float4> gView;
Texture2D<float4> gPrevView;

#define BIAS_MODE_BASIC 1
#define BIAS_MODE_RAYTRACE 2
//This is for syntax highlightig
#ifndef BIAS_CORRECTION_MODE
    #define BIAS_CORRECTION_MODE 2
#endif

//Define for valid texture channels
#define is_valid(name) (is_valid_##name != 0)

cbuffer PerFrame
{
    uint gFrameCount;                   //Current it for sample gen
}

cbuffer Constant
{
    uint2 gFrameDim;                //Frame Dimensions for camera dir
    uint gMaxAge;
    float gDepthThreshold;          //Relative depth offset
    float gNormalThreshold;         //Maximum cosine between both Normals that is allowed
    float gAttenuationRadius; //Attenuation Radius
    uint2 _pad;
}

struct LightSample{
    float3 dir;
    float Li;
};


static const float kRayEpsilon = 0.99f;

uint index2Dto1D(uint2 idx, uint width){
    return idx.x + width * idx.y;
}

Reservoir getReservoir(int2 idx, bool prev)
{
    Reservoir r;
    if (prev)
    {
        r = Reservoir(gReservoirPrev[idx], 0);
    }
    else
    {
        r = Reservoir(gReservoir[idx], 0);
    }
    //Discard NaN Reservoirs
    if (isinf(r.weightSum) || isnan(r.weightSum))
        r = Reservoir();
    return r;
}

Surface getSurface(uint2 idx, bool prev)
{
    float3 viewDir;
    if (is_valid(gView))
    {
        if (prev)
            viewDir = gPrevView[idx].xyz;
        else
            viewDir = gView[idx].xyz;
    }
    else
    {
        viewDir = gScene.camera.computeRayPinhole(idx, gFrameDim).dir * -1; //Flip ViewDir here 
    }
    PackedSurfaceData surfaceData;
    if (prev)
        surfaceData = gSurfacePrev[index2Dto1D(idx, gFrameDim.x)];
    else
        surfaceData = gSurface[index2Dto1D(idx, gFrameDim.x)];
    
    return Surface(surfaceData, viewDir);
}

bool isValidNeighbor(float3 currNormal, float currLinZ, float3 neighNormal, float neighLinZ){
    float normalCheck = dot(currNormal, neighNormal);
    float minLinZDiff = currLinZ * gDepthThreshold;
    float linZDiff = abs(currLinZ - neighLinZ);
    return ( (normalCheck >= gNormalThreshold) && (linZDiff <= minLinZDiff) );
}

PhotonLight getPhotonLight(int2 idx, bool prev){
    PhotonLight pl;
    if(prev){
        pl.posW = gPhotonReservoirPosPrev[idx];
        pl.normal = gPhotonReservoirNormalPrev[idx].xyz;
        pl.flux = gPhotonReservoirFluxPrev[idx].xyz;
    }else{
        pl.posW = gPhotonReservoirPos[idx];
        pl.normal =gPhotonReservoirNormal[idx].xyz;
        pl.flux = gPhotonReservoirFlux[idx].xyz;
    }
    return pl;
}

bool getLightSample(in PhotonLight pl,in float3 worldPos, out LightSample ls, out float sampleDistance){
    if(any(pl.flux.xyz <= 0)) return false;
    
    ls.dir = pl.posW.xyz - worldPos;
    float distSqr= max(FLT_MIN, dot(ls.dir, ls.dir)); // Clamp to avoid NaNs below
    sampleDistance = sqrt(distSqr);
    ls.dir = ls.dir/ sampleDistance;    //normalize

    ls.Li = luminance(pl.flux);
    float distAttenuation = vplAttenuation(sampleDistance, gAttenuationRadius);
    float cosTheta = saturate(dot(normalize(pl.normal), -ls.dir));

    ls.Li *= cosTheta * distAttenuation;

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
    Surface currentSurface = getSurface(dTid, false);
    if(!currentSurface.valid)
        return;
        
    //Load reservoir from current iteration
    PhotonLight selectPL = { };
    Reservoir current = getReservoir(dTid, false);
    if(current.weightSum > 0){
        selectPL = getPhotonLight(dTid, false);
    }

    uint historyLimit = gMaxAge * current.M;
    combineReservoir(r, current, current.targetPdf, 0.5 /* random */);
    
    float2 motionOffset = gMVec[dTid] * float2(gFrameDim);
    //Check if motion vectors are inside of the frame
    float2 prevIdxF = motionOffset + float2(dTid);
    float2 rndOffset = sampleNext2D(sg) - 0.5f;
    prevIdxF += rndOffset;
    
    uint2 prevIdx = uint2(round(prevIdxF));
    
    //Check if a neighbor surface matches up
    //Try to find a matching surface in the neighborhood of the reprojected pixel
    Surface temporalSurface;
    bool selectPrevSample = false;
    uint previousM = 0;
    bool foundTemporalSurface = false;
    int2 idx = (0,0);
    float temporalSearchRadius = 4.f;
    
    for(uint i=0 ; i<9; i++){
        int2 offset = int2(0,0);
        if(i > 0){
            offset = int2( (sampleNext2D(sg) - 0.5f) * temporalSearchRadius);
        }

        idx = prevIdx + offset;

        //index is outside of the frame
        if(idx.x < 0 && idx.y < 0 && idx.x > gFrameDim.x && idx.y > gFrameDim.y)
            continue;
        
        //Get Hit sample from last frame
        temporalSurface = getSurface(idx, true); 
        if(!temporalSurface.valid)
            continue;

        //Test surface similarity and discard if too different
        if(!isValidNeighbor(currentSurface.normal, currentSurface.viewDepth, temporalSurface.normal, temporalSurface.viewDepth))
            continue;

        //Valid hit was found
        foundTemporalSurface = true;
        break;
    }

    if(foundTemporalSurface){
        Reservoir prev = getReservoir(idx, true);
        prev.M = min(prev.M, historyLimit);
        previousM = prev.M;
        
        PhotonLight pl = getPhotonLight(idx, true);
        //Get new target pdf if valid
        float targetPdf = 0;
        if(prev.M > 0){
            LightSample ls = { };
            float dis = 0;
            bool validLS = getLightSample(pl, currentSurface.posW, ls, dis);
            targetPdf = validLS ? getSurfacePdf(currentSurface, ls) : 0;
        }

        selectPrevSample = combineReservoir(r, prev, targetPdf, sampleNext1D(sg));
        if(selectPrevSample)
            selectPL = pl;
    }

//Bias correction
#if BIAS_CORRECTION_MODE >= BIAS_MODE_BASIC
    float pi = r.targetPdf;
    float piSum = r.targetPdf * current.M;

    if (foundTemporalSurface)
    {
        LightSample ls = { };
        float distance = 0;
        bool valid = getLightSample(selectPL, temporalSurface.posW, ls, distance);
        float ps = valid ? getSurfacePdf(temporalSurface, ls) : 0.0;

        #if BIAS_CORRECTION_MODE >= BIAS_MODE_RAYTRACE
        if (ps > 0)
        {
            SceneRayQuery < 0 > rayQuery;
            distance *= kRayEpsilon;
            const Ray ray = Ray(temporalSurface.posW, ls.dir, 0.f, distance);
            if (!rayQuery.traceVisibilityRay(ray, RAY_FLAG_NONE, 0xff))
            {
                ps = 0;
            }
        }
        #endif // BIAS MODE RAYTRACE
        
        pi = selectPrevSample ? ps : pi;
        piSum += ps * previousM;
    }
    finalizeSample(r, pi, piSum);
    
#else    
    finalizeSample(r, 1.0f, r.M);
#endif //BIAS_MODE_BASIC
        
    gReservoir[dTid] = r.pack();
    gPhotonReservoirPos[dTid] = selectPL.posW;
    gPhotonReservoirNormal[dTid] = float4(selectPL.normal,0);
    gPhotonReservoirFlux[dTid] = float4(selectPL.flux,1);
}
