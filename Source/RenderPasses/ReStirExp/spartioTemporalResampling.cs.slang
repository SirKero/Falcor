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

StructuredBuffer<Reservoir> gReservoirPrev;
RWStructuredBuffer<Reservoir> gReservoir;

Texture2D<PackedHitInfo> gVBuffer;
Texture2D<PackedHitInfo> gPrevVBuffer;
Texture2D<float2> gMVec;


cbuffer PerFrame
{
    uint gFrameCount;                   //Current it for sample gen
    uint2 gFrameDim;                //Frame Dimensions for camera dir
    uint gMaxAge;
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

bool isValidNeighbor(float3 currNormal, float currLinZ, float3 neighNormal, float neighLinZ){
    float normalCheck = dot(currNormal, neighNormal);
    float minLinZDiff = currLinZ * gDepthThreshold;
    float linZDiff = abs(currLinZ - neighLinZ);
    return ( (normalCheck >= gNormalThreshold) && (linZDiff <= minLinZDiff) );
}

bool getEmissiveTriangle(uint triangleIdx, float2 uv, in ShadingData sd, out LightSample ls){
    const uint activeTriangleCount = gScene.lightCollection.getActiveTriangleCount();
    ls.lightIdx = triangleIdx;
    ls.selectPdf = 1.f/activeTriangleCount;

    //get triangle data and sample uniformly
    const EmissiveTriangle tri = gScene.lightCollection.getTriangle(ls.lightIdx);
    const float3 barycentrics = sample_triangle(uv);
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

//gets the target pdf averaged to one channel
float getSurfacePdf(in BSDFProperties bsdfProperties, in ShadingData sd, in LightSample ls){

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

void combineReservoir(inout Reservoir r, in Reservoir prev,float targetPDF, float rnd){
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
}

[numthreads(16, 16, 1)]
void main(uint2 dTid : SV_DispatchThreadID)
{
    SampleGenerator sg = SampleGenerator(dTid, gFrameCount + 6 * 13);
    Reservoir r = Reservoir.create();
    
    //Check if surface is valid
    HitInfo hitInfo = HitInfo(gVBuffer[dTid]);
    if(!hitInfo.isValid())
        return;
    
    //Get Hit shading information
    let lod = ExplicitLodTextureSampler(0.f);
    Ray cameraRay = gScene.camera.computeRayPinhole(dTid, gFrameDim);
    ShadingData sd = loadShadingData(hitInfo, cameraRay.dir, lod);
    let bsdf = gScene.materials.getBSDF(sd, lod);
    let bsdfProperties = bsdf.getProperties(sd);
    float3 camPos = gScene.camera.getPosition();
    float currLinZ = distance(camPos, sd.posW); //for now it is approximated as the distance from the point to the camera 

    //Load reservoir from current iteration
    Reservoir current =  gReservoir[index2Dto1D(dTid, gFrameDim.x)];
    if(isinf(current.W) || isnan(current.W))
        current = Reservoir.create();
    
    uint historyLimit = uint(gMaxAge * current.M);
    
    combineReservoir(r, current, current.targetPdf , 0.5 /* random */);
    
    //
    //Temporal Sample
    //
    float2 motionOffset = gMVec[dTid] * float2(gFrameDim);
    //Check if motion vectors are inside of the frame
    float2 prevIdxF = motionOffset + float2(dTid);
    float2 rndOffset = sampleNext2D(sg) - 0.5f;
    prevIdxF += rndOffset;
    
    int2 prevIdx = int2(round(prevIdxF));

    //Get surface from last frame
    HitInfo temporalHitInfo;
    bool foundTemporalSurface = false;
    int2 temporalOffset = int2(0,0);
    const float temporalSearchRadius = 4.f;   //actual radius is 2 due to random value in [-0.5,0.5]
   
    //Try to find a matching surface in the neighborhood of the reprojected pixel
    for(uint i=0 ; i<9; i++){
        int2 offset = int2(0,0);
        if(i > 0){
            offset = int2( (sampleNext2D(sg) - 0.5f) * temporalSearchRadius);
        }

        int2 idx = prevIdx + offset;

        //index is outside of the frame
        if(idx.x < 0 && idx.y < 0 && idx.x > gFrameDim.x && idx.y > gFrameDim.y)
            continue;
        
        //Get Hit sample from last frame
        temporalHitInfo = HitInfo(gPrevVBuffer[idx]);
        if(!temporalHitInfo.isValid())
            continue;

        //Test surface similarity and discard if too different
        VertexData tempVertexData = gScene.getVertexData(temporalHitInfo.getTriangleHit());
        float tempLinZ = distance(camPos, tempVertexData.posW);
        if(!isValidNeighbor(sd.N, currLinZ, tempVertexData.normalW, tempLinZ))
            continue;

        //Valid hit was found
        temporalOffset = offset;
        foundTemporalSurface = true;
        break;
    }
    
    //
    //Spartio Temporal Resampling
    //
    uint numSamples = clamp(gSpartialSamples + 1,1,32); //Cap at 32 samples for the later bias correction
    //Go through all neighbors
    for(uint j=0 ; j<numSamples; j++){
        int2 spartialOffset = int2(0);
        int2 idx = int2(0);

        //Take temporal sample or generate a new neighbor sample
        if(j==0 && foundTemporalSurface){
           spartialOffset = temporalOffset;
           idx = prevIdx + temporalOffset;
        }
        else{
            //TODO do this with a sampling mask
            float2 randSamp = (sampleNext2D(sg) - 0.5f) * 2.f;
            spartialOffset = int2(round(randSamp * gSamplingRadius));
            idx = prevIdx + spartialOffset;

            //Check if index is valid
            if(idx.x < 0 && idx.y < 0 && idx.x > gFrameDim.x && idx.y > gFrameDim.y)
                continue;
            
             //Get surface and check if valid
            HitInfo neightHit = HitInfo(gPrevVBuffer[idx]);
            if(!neightHit.isValid())
                continue;
        
            VertexData neighVertexData = gScene.getVertexData(neightHit.getTriangleHit());
            float neighLinZ = distance(camPos, neighVertexData.posW);
            if(!isValidNeighbor(sd.N, currLinZ, neighVertexData.normalW, neighLinZ))
                continue;
        }
            
        //If neighbor surface has passed the tests get reservoir and compair them
        Reservoir sampledReservoir = gReservoirPrev[index2Dto1D(idx, gFrameDim.x)];
        if(isnan(sampledReservoir.W) || isinf(sampledReservoir.W))
            sampledReservoir = Reservoir.create();
        
        sampledReservoir.M = min(sampledReservoir.M, historyLimit);
        sampledReservoir.age += 1;

        
        //Get neightbor light target PDF for current surface
        float sampleTargetPdf = 0.f;
        if (sampledReservoir.M > 0)
        {
            LightSample ls = { };
            getEmissiveTriangle(sampledReservoir.lightIdx, sampledReservoir.getUV(), sd, ls);
            sampleTargetPdf = getSurfacePdf(bsdfProperties, sd, ls);
        }
        //Combine Reservoirs
        combineReservoir(r, sampledReservoir, sampleTargetPdf, sampleNext1D(sg));
    }

    //Store final reservoir
    if (r.targetPdf > 0 && r.M > 0)
    {
        float demodulator = r.targetPdf * r.M;
        r.W = r.weightSum / demodulator;
    }else{
        r = Reservoir.create();
    }
    
    gReservoir[index2Dto1D(dTid, gFrameDim.x)] = r;
}
