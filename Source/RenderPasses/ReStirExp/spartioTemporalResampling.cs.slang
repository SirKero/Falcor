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

StructuredBuffer<Reservoir> gReservoirPrev;
RWStructuredBuffer<Reservoir> gReservoir;

Texture1D<snorm float2> gNeighOffsetBuffer;
Texture2D<PackedHitInfo> gVBuffer;
Texture2D<PackedHitInfo> gPrevVBuffer;
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
    uint gFrameCount; //Current it for sample gen
    uint3 pad;
}

cbuffer Constant{
    uint2 gFrameDim;                //Frame Dimensions for camera dir
    uint gMaxAge;
    uint gSpartialSamples;
    float gSamplingRadius;
    float gDepthThreshold;          //Relative depth offset
    float gNormalThreshold;         //Maximum cosine between both Normals that is allowed
    uint gDisocclusionBoostSamples; //Number of spartial samples if no temporal surface was found
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

bool getEmissiveTriangle(uint triangleIdx, float2 uv, in ShadingData sd, out LightSample ls, out float distance){
    const uint activeTriangleCount = gScene.lightCollection.getActiveTriangleCount();
    ls.lightIdx = triangleIdx;
    ls.selectPdf = 1.f/activeTriangleCount;

    //get triangle data and sample uniformly
    const EmissiveTriangle tri = gScene.lightCollection.getTriangle(ls.lightIdx);
    const float3 barycentrics = sample_triangle(uv);
    float3 posW = tri.getPosition(barycentrics);
    float3 toLight = posW - sd.posW;
    float distSqr= max(FLT_MIN, dot(toLight, toLight)); // Clamp to avoid NaNs below
    distance = sqrt(distSqr);
    ls.dir = toLight/ distance;    //normalize

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

void finalizeSample(inout Reservoir r, float normalizationNumerator, float normalizationDenominator){
    float denominator = r.targetPdf * normalizationDenominator;

    r.W = denominator > 0 ? (r.weightSum * normalizationNumerator) / denominator : 0.f;
}

Reservoir getReservoir(int2 idx, bool prev){
    Reservoir r = Reservoir.create();
    if(prev){
        r = gReservoirPrev[index2Dto1D(idx, gFrameDim.x)];
    }else{
       r = gReservoir[index2Dto1D(idx, gFrameDim.x)]; 
    } 
    if(r.W <= 0||isinf(r.W) || isnan(r.W))
        r = Reservoir.create();
    return r;
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
    Reservoir current =  getReservoir(dTid, false);
    
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
    uint cachedResults = 0;  //Remember which sample was valid
    uint neighOffsetStartIdx = uint(sampleNext1D(sg) * float(kNeighOffsetMask-1));
    uint numSamples = clamp(gSpartialSamples + 1,1,32); //Cap at 32 samples for the later bias correction
    if(!foundTemporalSurface)
        numSamples = clamp(max(numSamples, gDisocclusionBoostSamples),1,32);

    int selectedSample = -1;
    bool validSample = true;
    
    //Go through all neighbors
    for(uint i=0 ; i<numSamples; i++){
        int2 spartialOffset = int2(0);
        int2 idx = int2(0);

        //Take temporal sample or generate a new neighbor sample
        if(i==0 && foundTemporalSurface){
           spartialOffset = temporalOffset;
           idx = prevIdx + temporalOffset;
        }
        else{
            //Get sample from sampling mask
            uint neighBufferIdx = (neighOffsetStartIdx + i) % (kNeighOffsetMask-1);
            float2 randSamp = float2(gNeighOffsetBuffer[neighBufferIdx]);
            spartialOffset = int2(randSamp * gSamplingRadius);
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
        Reservoir sampledReservoir = getReservoir(idx, true);
        
        sampledReservoir.M = min(sampledReservoir.M, historyLimit);
        sampledReservoir.age += 1;

        cachedResults |= (1u << i);
        
        //Get neightbor light target PDF for current surface
        float sampleTargetPdf = 0.f;
        bool valid = false;
        if (sampledReservoir.M > 0)
        {
            LightSample ls = { };
            float dis;
            valid = getEmissiveTriangle(sampledReservoir.lightIdx, sampledReservoir.getUV(), sd, ls, dis);
            sampleTargetPdf = valid ? getSurfacePdf(bsdfProperties, sd, ls): 0.0;
        }
        //Combine Reservoirs
        if(combineReservoir(r, sampledReservoir, sampleTargetPdf, sampleNext1D(sg))){
            selectedSample = i;
            validSample = valid;
        }
    }

    
    if(validSample && ( r.W > 0 || !isnan(r.W) || !isinf(r.W))){

        //Bias correction TODO: Possible reweighing error; a bit too bright; needs checking
        #if BIAS_CORRECTION_MODE >= BIAS_MODE_BASIC
    
        float pi = r.targetPdf;
        float piSum = r.targetPdf * current.M;
        
        //go through all neighbors again
        for (int i = 0; i < numSamples; i++)
        {
            //Skip if we skipped in last loop
            if ((cachedResults & (1u << i)) == 0)
                continue;
            //Get Index
            int2 offset = int2(0);
            if (i == 0 && foundTemporalSurface)
                offset = temporalOffset;
            else
            {
                uint neighBufferIdx = (neighOffsetStartIdx + i) % (kNeighOffsetMask - 1);
                float2 randSamp = float2(gNeighOffsetBuffer[neighBufferIdx]);
                offset = int2(randSamp * gSamplingRadius);
            }
            int2 idx = prevIdx + offset;

            //Get Surface
            HitInfo biasHit = HitInfo(gVBuffer[idx]);
            Ray biasCameraRay = gScene.camera.computeRayPinhole(idx, gFrameDim);
            ShadingData biasSD = loadShadingData(biasHit, biasCameraRay.dir, lod);
            let biasBsdf = gScene.materials.getBSDF(biasSD, lod);
            let biasBsdfProperties = biasBsdf.getProperties(biasSD);

            //getReservoir
            Reservoir biasRes = getReservoir(idx, true);
            biasRes.M = min(biasRes.M, historyLimit); //cap M
        
            //Get light pdf
            bool valid = true;
            float ps = 0;
            LightSample ls = { };
            float dist = 0;
            if (biasRes.M > 0)
            {
                valid |= getEmissiveTriangle(r.lightIdx, r.getUV(), biasSD, ls, dist);
                float ps = valid ? getSurfacePdf(biasBsdfProperties, biasSD, ls) : 0.0;
            }
        

            //Trace ray
            #if BIAS_CORRECTION_MODE >= BIAS_MODE_RAYTRACE
            if (ps > 0 && valid)
            {
                SceneRayQuery < 1 > rayQuery;
                dist *= 0.99;
                const Ray ray = Ray(biasSD.computeNewRayOrigin(), ls.dir, 0.f, dist);
                if (!rayQuery.traceVisibilityRay(ray, RAY_FLAG_NONE, 0xff))
                {
                    ps = 0;
                }
            }
            #endif // BIAS MODE RAYTRACE
        
            pi = selectedSample == i ? ps : pi;
            piSum += ps * biasRes.M;
        }
        finalizeSample(r, pi, piSum);
        
        #else //BIAS MODE BASIC
        finalizeSample(r, 1.0f, r.M);
        #endif //BIAS MODE BASIC
    }    
        
    gReservoir[index2Dto1D(dTid, gFrameDim.x)] = r;
}
