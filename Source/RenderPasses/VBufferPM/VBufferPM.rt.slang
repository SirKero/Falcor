#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.Raytracing;
import Scene.Intersection;
import Scene.Camera.CameraData;
import Utils.Math.MathHelpers;
import Rendering.Materials.Microfacet;
import Utils.Sampling.SampleGenerator;
import Utils.Geometry.GeometryHelpers;
import Scene.Material.ShadingUtils;
import Rendering.Lights.LightHelpers;
import Utils.Color.ColorHelpers;
import RenderPasses.Shared.Denoising.NRDHelpers;


cbuffer PerFrame
{
    uint gFrameCount; // Frame count since scene was loaded.
};

cbuffer CB
{
    uint gMaxRecursion;     //Maximum length a path can travel
    float gSpecularRougnessCutoff; //cutoff for when a hit counts as diffuse
    bool gAdjustShadingNormals; //Adjusts the shading normals if activated
    bool gUseAlphaTest;     //uses alpha test if activated
    
    bool gUseRandomPixelPosCamera;  //Uses a randomly generated pixel offset for camera direction sampeling instead of fixed jitter
    bool gUseDeltaRejection;        //Delta rejection
    bool gForceMostProbablePath;    //For delta reflections force the most probable path
    uint _pad;
};

// Outputs
RWTexture2D<PackedHitInfo> gVBuffer;
RWTexture2D<float4> gViewWorld;
RWTexture2D<float4> gThp;
RWTexture2D<float4> gEmissive;

//Optional
RWTexture2D<float2> gDepth;
RWTexture2D<float> gLinDepth;
RWTexture2D<float2> gMVec;
RWTexture2D<float4> gNormWRoughMat;
RWTexture2D<float2> gLinZFirstHit;

//NRD
RWTexture2D<float4> gNRDDiffuseReflectance;
RWTexture2D<float4> gNRDSpecularReflectance;
RWTexture2D<float4> gNRDDeltaReflectionReflectance;
RWTexture2D<float4> gNRDDeltaReflectionEmission;
RWTexture2D<float4> gNRDDeltaReflectionNormWRoughMat;
RWTexture2D<float> gNRDDeltaReflectionHitDistance;
RWTexture2D<float4> gNRDDeltaTransmissionReflectance;
RWTexture2D<float4> gNRDDeltaTransmissionEmission;
RWTexture2D<float4> gNRDDeltaTransmissionNormWRoughMat;
RWTexture2D<float4> gNRDFirstPosW;
RWTexture2D<float4> gNRDDeltaTransmissionPosW;
RWTexture2D<uint> gNRDMask;


#define is_valid(name) (is_valid_##name != 0)

static const bool kComputeDepthOfField = COMPUTE_DEPTH_OF_FIELD;
static const bool kUseNRD = USE_NRD; 
static const float kNRDMinReflectance = 0.04f;
static const float kDepthPathMiss = 650000.f;

/** Payload for scatter ray (64B).
*/
struct RayData
{
    float3 thp; ///< Current path throughput. This is updated at each path vertex.
    uint flags; ///< Set to true when path is terminated.Top 16 bits are used for first hit distance
    float3 origin; ///< Next path segment origin.
    uint pathLength; ///<Length of the path
    float3 direction; ///< Next path segment direction.
    float distance;
    
    SampleGenerator sg; ///< Per-ray state for the sample generator (up to 16B).

    /** Create ray payload with default parameters.
    */
    __init(SampleGenerator sg){
        this.thp = float3(1.0);
        this.flags = 0; 
        this.origin = float3(0); 
        this.distance = 0.f; 
        this.direction = float3(0); 
        this.pathLength = 0;
        this.sg = sg;
    }
};

enum
class Flags //:uint32_t
{
    Terminated = 0x01,
    Transmissive = 0x02,
    DeltaReflection = 0x04,
    NonDeltaReflection = 0x08,
    Reflection = 0x0C,
    NDR = 0x0E,
    Miss = 0x20,
};

/** Computes a camera ray for a given pixel assuming a thin-lens camera model with a random instead of a fixed jitter. Based on computeRandomRayThinlens()
        The camera jitter is taken into account to compute the sample position on the image plane.
        \param[in] pixel Pixel coordinates with origin in top-left.
        \param[in] frameDim Image plane dimensions in pixels.
        \param[in] u Uniform 2D sample. Used for pixel pos.
        \param[in] v Uniform 2D sample. Used for thin lens sample.
        \param[in] data Camera data.
        \return Returns the camera ray.
    */
Ray cameraComputeRandomRayThinlens(uint2 pixel, uint2 frameDim, float2 u , float2 v, in const CameraData data)
{
    Ray ray;

    // Sample position in screen space in [0,1] with origin at the top-left corner.
    // The camera jitter offsets the sample by +-0.5 pixels from the pixel center.
    float2 p = (pixel + u) / frameDim;
    float2 ndc = float2(2, -2) * p + float2(-1, 1);

    // Compute the normalized ray direction assuming a thin-lens camera.
    ray.origin = data.posW;
    ray.dir = ndc.x * data.cameraU + ndc.y * data.cameraV + data.cameraW;
    float2 apertureSample = sample_disk(v); // Sample lies in the unit disk [-1,1]^2
    float3 rayTarget = ray.origin + ray.dir;
    ray.origin += data.apertureRadius * (apertureSample.x * normalize(data.cameraU) + apertureSample.y * normalize(data.cameraV));
    ray.dir = normalize(rayTarget - ray.origin);

    float invCos = 1.f / dot(normalize(data.cameraW), ray.dir);
    ray.tMin = data.nearZ * invCos;
    ray.tMax = data.farZ * invCos;

    return ray;
}

void writeHit(const in uint2 pixel, const in float3 rayDir,const in float3 thp, const float3 emissive , const in HitInfo hit,const in float linZ )
{
    gVBuffer[pixel] = hit.getData();
    gViewWorld[pixel] = float4(rayDir, 1);
    gThp[pixel] = float4(thp, 1);
    gEmissive[pixel] = float4(emissive, 1);

    //If depth in valid write it
    if (is_valid(gLinDepth)) gLinDepth[pixel] = max(FLT_MIN, linZ);
}

void writeDirectMaterialInfo(const in uint2 pixel, const in float3 normal, const in float roughness)
{
    if (is_valid(gNormWRoughMat))
    {
        float2 octNormal = ndir_to_oct_unorm(normal);
        float materialID = 0.f;
        gNormWRoughMat[pixel] = float4(octNormal, roughness, materialID);
    }
}

void writeNRDDeltaReflectionHit(const in uint2 pixel, const in float hitDistance, const in float3 deltaReflectance, const float3 emission, const in float3 normal, const in float roughness)
{
    float3 reflectance = max(kNRDMinReflectance, deltaReflectance);
    float2 octNormal = ndir_to_oct_unorm(normal);
    float clampedRougness = roughness < 0.08f ? 0.0f : roughness;   //Clap roughness so it is representative of what is used in renderer
    float materialID = 0.f;

    gNRDDeltaTransmissionReflectance[pixel] = {};
    gNRDDeltaReflectionReflectance[pixel] = float4(reflectance, 0.f);
    gNRDDeltaReflectionEmission[pixel] = float4(emission, 0.f);
    gNRDDeltaReflectionNormWRoughMat[pixel] = float4(octNormal, clampedRougness, materialID);
    gNRDDeltaReflectionHitDistance[pixel] = hitDistance;
    gNRDMask[pixel] = 0x02;

    }

void writeNRDDeltaTransmissionHit(const in uint2 pixel, const in float3 posW, const in float3 deltaReflectance, const float3 emission, const in float3 normal, const in float roughness)
{
    float3 reflectance = max(kNRDMinReflectance, deltaReflectance);
    float2 octNormal = ndir_to_oct_unorm(normal);
    float clampedRougness = roughness < 0.08f ? 0.0f : roughness; //Clap roughness so it is representative of what is used in renderer
    float materialID = 0.f;

    gNRDDeltaReflectionReflectance[pixel] = {};
    gNRDDeltaTransmissionReflectance[pixel] = float4(reflectance, 0.f);
    gNRDDeltaTransmissionEmission[pixel] = float4(emission, 0.f);
    gNRDDeltaTransmissionNormWRoughMat[pixel] = float4(octNormal, clampedRougness, materialID);
    gNRDDeltaTransmissionPosW[pixel] = float4(posW, 0.f);
    gNRDMask[pixel] = 0x01;
}

void writeMiss(uint2 pixel, bool miss = false)
{
    gVBuffer[pixel] = { };
    gThp[pixel] = { };
    gEmissive[pixel] = { };
    if (is_valid(gLinDepth)) gLinDepth[pixel] = kDepthPathMiss;
    if (is_valid(gNormWRoughMat)) gNormWRoughMat[pixel] = { };

    if (miss)
    {
        if (is_valid(gLinZFirstHit)) gLinZFirstHit[pixel] = float2(kDepthPathMiss, 0.f);
        if (is_valid(gMVec)) gMVec[pixel] = { };
        if (is_valid(gNRDDiffuseReflectance)) gNRDDiffuseReflectance[pixel] = { };
        if (is_valid(gNRDSpecularReflectance)) gNRDSpecularReflectance[pixel] = { };
        if (is_valid(gNRDDeltaReflectionReflectance)) gNRDDeltaReflectionReflectance[pixel] = {   };
        if (is_valid(gNRDDeltaTransmissionReflectance))   gNRDDeltaTransmissionReflectance[pixel] = {   };
        if (is_valid(gNRDDeltaReflectionHitDistance)) gNRDDeltaReflectionHitDistance[pixel] = 1.f;
        if (is_valid(gNRDDeltaReflectionNormWRoughMat)) gNRDDeltaReflectionNormWRoughMat[pixel] = {  };
        
        
        if (is_valid(gNRDMask))  gNRDMask[pixel] = 0x00;
    }
}

//TODO: Add other miss colors, as throughput then has to be respected
[shader("miss")]
void miss(inout RayData rayData : SV_RayPayload)
{
    uint2 pixel = DispatchRaysIndex().xy;
    rayData.flags |= (uint) Flags::Terminated;
    rayData.flags |= (uint) Flags::Miss;
    rayData.distance = -1.f;
}

//add anyHit shader for alpha test
[shader("anyhit")]
void anyHit(inout RayData rayData : SV_RayPayload, BuiltInTriangleIntersectionAttributes attribs : SV_IntersectionAttributes)
{
    if (gUseAlphaTest)
    {
        // Alpha test for non-opaque geometry.
        GeometryInstanceID instanceID = getGeometryInstanceID();
        VertexData v = getVertexData(instanceID, PrimitiveIndex(), attribs);
        uint materialID = gScene.getMaterialID(instanceID);
        if (gScene.materials.alphaTest(v, materialID, 0.f))
            IgnoreHit();
    }
}

bool generateNewRay(const in ShadingData sd, const in IBSDF bsdf, float3 rayOrigin, inout BSDFSample bsdfSample, inout RayData rayData)
{
    // Sample material.
    if (bsdf.sample(sd, rayData.sg, bsdfSample, true /*Importance Sampeling*/))
    {
        rayData.origin = rayOrigin;
        rayData.direction = bsdfSample.wo;
        if (bsdfSample.isLobe(LobeType::Transmission))
        {
            rayData.origin = computeRayOrigin(sd.posW, dot(sd.faceN, bsdfSample.wo) <= 0.f ? -sd.faceN : sd.faceN);
        }
        
        rayData.thp *= bsdfSample.weight;
        return any(rayData.thp > 0.f);
    }

    return false;
}

float3 computeDdxPosW(float3 posW, float3 normW, float2 invFrameDim)
    {
        float3 projRight = normalize(cross(normW, cross(normW, gScene.camera.data.cameraV)));
        float distanceToHit = length(posW - gScene.camera.data.posW);
        float2 ddNdc = float2(2.f, -2.f) * invFrameDim;
        float distRight = distanceToHit * ddNdc.x / dot(normalize(gScene.camera.data.cameraV), projRight);
        return distRight * projRight;
    }

    float3 computeDdyPosW(float3 posW, float3 normW, float2 invFrameDim)
    {
        float3 projUp = normalize(cross(normW, cross(normW, gScene.camera.data.cameraU)));
        float distanceToHit = length(posW - gScene.camera.data.posW);
        float2 ddNdc = float2(2.f, -2.f) * invFrameDim;
        float distUp = distanceToHit * ddNdc.y / dot(normalize(gScene.camera.data.cameraU), projUp);
        return distUp * projUp;
    }

[shader("closesthit")]
void closestHit(inout RayData rayData : SV_RayPayload, BuiltInTriangleIntersectionAttributes attribs : SV_IntersectionAttributes)
{
    uint2 launchIndex = DispatchRaysIndex().xy;
    float2 invFrameDim = 1.f / DispatchRaysDimensions().xy;
   // Evaluate Falcor's material parameters at the hit point.
    TriangleHit triangleHit;
    triangleHit.instanceID = getGeometryInstanceID();
    triangleHit.primitiveIndex = PrimitiveIndex();
    triangleHit.barycentrics = attribs.barycentrics;
    VertexData v = gScene.getVertexData(triangleHit);
    uint materialID = gScene.getMaterialID(triangleHit.instanceID);
    
    let lod = ExplicitLodTextureSampler(0.f);
    ShadingData sd = gScene.materials.prepareShadingData(v, materialID, -rayData.direction, lod);

    if(rayData.pathLength > 0)
        rayData.distance += distance(ObjectRayOrigin(), sd.posW); //accumulate ray distance
    
    //Calc Motion Vector if it is valid on first valid hit
    if(is_valid(gMVec) && rayData.pathLength == 0 && !gUseRandomPixelPosCamera){
        float3 prevPosW = gScene.getPrevPosW(triangleHit);
        float2 pixelPos = float2(launchIndex) + float2(0.5f, 0.5f);
        float4 prevPosH = mul(float4(prevPosW, 1.f), gScene.camera.data.prevViewProjMatNoJitter);
        float2 motionVec = calcMotionVector(pixelPos, prevPosH, DispatchRaysDimensions().xy);
        // Remove camera jitter from motion vector 
        motionVec += float2(gScene.camera.data.jitterX, -gScene.camera.data.jitterY); //JitterX is subtracted, JitterY is added in Cam jitter calc
        
        gMVec[launchIndex] = motionVec;
    }

    
    if (rayData.pathLength == 0)
    {
        float4 curPosH = mul(float4(sd.posW, 1.f), gScene.camera.data.viewProjMatNoJitter);
        float curLinearZ = max(FLT_MIN, curPosH.w);
        rayData.distance = curLinearZ;
        //Calc linZ for the first hit
        rayData.flags |= f32tof16(rayData.distance) << 16;
        if (is_valid(gLinZFirstHit))
        {
            //Derevative
            float3 ddxPosW = computeDdxPosW(sd.posW, sd.faceN, invFrameDim);
            float3 ddyPosW = computeDdyPosW(sd.posW, sd.faceN, invFrameDim);
            float4 curPosH_dx = mul(float4(sd.posW + ddxPosW, 1.f), gScene.camera.data.viewProjMatNoJitter);
            float4 curPosH_dy = mul(float4(sd.posW + ddxPosW, 1.f), gScene.camera.data.viewProjMatNoJitter);
            float ddxLinearZ = abs(curPosH_dx.w - curLinearZ);
            float ddyLinearZ = abs(curPosH_dy.w - curLinearZ);
            float dLinearZ = max(ddxLinearZ, ddyLinearZ);
        
            gLinZFirstHit[launchIndex] = float2(curLinearZ, dLinearZ);
        }
        if (is_valid(gDepth))
        {
            gDepth[launchIndex] = curPosH.z / curPosH.w;

        }
    }
            
    if (gAdjustShadingNormals)
    {
        adjustShadingNormal(sd, v);
    }
    
    float3 thpStart = rayData.thp;
    
    
    BSDFSample bsdfSample;
    let bsdf = gScene.materials.getBSDF(sd, lod);

    uint lobes = bsdf.getLobes(sd);
    
    //get material properties
    let bsdfProperties = bsdf.getProperties(sd);

    //All properties are guaranteed to be combined <= 1. Norm it to 1 to get the real diffuse Reflection probability
    float norm = luminance(bsdfProperties.diffuseReflectionAlbedo + bsdfProperties.diffuseTransmissionAlbedo + bsdfProperties.specularReflectionAlbedo + bsdfProperties.specularTransmissionAlbedo);
    float pDiffuseRef = luminance(bsdfProperties.diffuseReflectionAlbedo) / norm;
    float pReflection = luminance(bsdfProperties.diffuseReflectionAlbedo + bsdfProperties.specularReflectionAlbedo) / norm;
    
    float rnd = sampleNext1D(rayData.sg);
    bool isDiffuse = true;
    
    if (gUseDeltaRejection){ //Reject everything that is not delta
        isDiffuse = (pDiffuseRef > 0) && ((lobes & (uint) LobeType::Delta) == 0);
    }else{ //Spec roughness rejection
        isDiffuse = rnd <= pDiffuseRef; //Check if diffuse
        isDiffuse |= (rnd <= pReflection) && (bsdfProperties.roughness >= gSpecularRougnessCutoff);
    }

   
    // For glass in reflections, force guide paths to always follow transmission/reflection based on albedos.
    // This is pretty hacky but works best our of the possible options.
    // Stable guide buffers are a necessity.
    bool isTracedFurther = !isDiffuse;
    if (rayData.pathLength == 0 && isTracedFurther && gForceMostProbablePath)
    {
        if (bsdfProperties.isTransmissive && all(bsdfProperties.specularReflectionAlbedo <= bsdfProperties.specularTransmissionAlbedo))
        {
            sd.mtl.setActiveLobes((uint) LobeType::Transmission);
        }
        else
        {
            sd.mtl.setActiveLobes((uint) LobeType::Reflection);
        }
    }
        
    //Stop if material is emissive
    isDiffuse |= luminance(bsdfProperties.emission) > 0;

    //Reflectance
    if (kUseNRD && rayData.pathLength == 0)
    {
        if (is_valid(gNRDDiffuseReflectance))
        {
            gNRDDiffuseReflectance[launchIndex] = float4(max(kNRDMinReflectance, bsdfProperties.diffuseReflectionAlbedo), 0);
        }
        if (is_valid(gNRDSpecularReflectance))
        {
            float NdotV = saturate(dot(sd.N, sd.V));
            float ggxAlpha = bsdfProperties.roughness * bsdfProperties.roughness;
            float3 specularReflectance = approxSpecularIntegralGGX(bsdfProperties.specularReflectance, ggxAlpha, NdotV);
            gNRDSpecularReflectance[launchIndex] = float4(max(kNRDMinReflectance, specularReflectance), 0);
        }
    }
    
    
    bool valid = generateNewRay(sd, bsdf, sd.computeNewRayOrigin(), bsdfSample, rayData);

    //Write to FirstposW if it is a transmissive sample
    if (is_valid(gNRDFirstPosW) && rayData.pathLength == 0 && bsdfSample.isLobe(LobeType::Transmission))
    {
        gNRDFirstPosW[launchIndex] = float4(sd.posW, 0.f);
    }
    
    if (rayData.pathLength == 0 && is_valid(gNormWRoughMat))
        writeDirectMaterialInfo(launchIndex, sd.N, bsdfProperties.roughness);
    
    //store hit if lobe is diffuse
    //if ((bsdfSample.isLobe(LobeType::DiffuseReflection) || (bsdfSample.isLobe(LobeType::Reflection) && isDiffuse)) && (!rayData.terminated || isDiffuse))
    if (isDiffuse)
    {
        bool ndrHit = (rayData.flags & (uint) Flags::NDR) && kUseNRD;
        writeHit(launchIndex, -WorldRayDirection(), thpStart, ndrHit ? float3(0) : bsdfProperties.emission, HitInfo(triangleHit), rayData.distance);

        if (kUseNRD && !ndrHit)
        {
            gNRDDeltaReflectionReflectance[launchIndex] = {  };
            gNRDDeltaTransmissionReflectance[launchIndex] = {  };
            gNRDDeltaReflectionEmission[launchIndex] = { };
            gNRDDeltaTransmissionEmission[launchIndex] = { };
            gNRDMask[launchIndex] = 0x00;
        }
        
        if (ndrHit)
        {
            const MaterialType materialType = sd.mtl.getMaterialType();
            bool hasDeltaLobes = (lobes & (uint) LobeType::Delta) > 0;
            float3 reflectance = getMaterialReflectanceForDeltaPaths(materialType, hasDeltaLobes, sd, bsdfProperties);
            
            if (rayData.flags & (uint) Flags::Transmissive)
            {
                writeNRDDeltaTransmissionHit(launchIndex, sd.posW, reflectance, bsdfProperties.emission * thpStart, sd.N, bsdfProperties.roughness);
            }
            else if (rayData.flags & (uint) Flags::DeltaReflection)
            {
                float firstHitDistance = f16tof32((rayData.flags >> 16) & 0xFFFF);
                float hitDistance = max(FLT_MIN, rayData.distance - firstHitDistance);
                writeNRDDeltaReflectionHit(launchIndex, hitDistance, reflectance, bsdfProperties.emission * thpStart, sd.N, bsdfProperties.roughness);
            }
            else
            {
                gNRDMask[launchIndex] = 0x04;
            }
        }
        
       
        rayData.flags |= (uint) Flags::Terminated;
    }
        
    //Set flags
    if (gUseDeltaRejection && rayData.pathLength == 0 && kUseNRD)
    {
        if (bsdfSample.isLobe(LobeType::Transmission))
            rayData.flags |= (uint) Flags::Transmissive;
        else if (bsdfSample.isLobe(LobeType::Reflection) && ((lobes & (uint) LobeType::Delta) > 0))
            rayData.flags |= (uint) Flags::DeltaReflection;
        else
            rayData.flags |= (uint) Flags::NonDeltaReflection;
    }

    rayData.pathLength++;
    
    if (!valid && !isDiffuse){
        rayData.distance = -1.f;
        rayData.flags |= (uint) Flags::Terminated;
    }
}

[shader("raygeneration")]
void rayGen()
{
    uint2 launchIndex = DispatchRaysIndex().xy;
    uint2 launchDim = DispatchRaysDimensions().xy;

    float3 outColor = float3(0);
    float3 throughput = float3(1);
    RayData rayData = RayData(SampleGenerator(launchIndex, gFrameCount)); //lazy init for now
    Ray camRay;
    if (gUseRandomPixelPosCamera)
    {
        float2 rndJitter = sampleNext2D(rayData.sg);
        camRay = cameraComputeRandomRayThinlens(launchIndex, launchDim, rndJitter, sampleNext2D(rayData.sg), gScene.camera.data);
    }
    else
    {
        camRay = gScene.camera.computeRayThinlens(launchIndex, launchDim, sampleNext2D(rayData.sg)); //get jittered ray
        //camRay = gScene.camera.computeRayPinhole(launchIndex, launchDim);
    }
   
    uint rayFlags = 0;
    RayDesc ray = camRay.toRayDesc();

    rayData.origin = ray.Origin;
    rayData.direction = ray.Direction;
    
    //Trace recursive
    for (uint i = 0; i < gMaxRecursion; i++)
    {
        TraceRay(gScene.rtAccel, 0, 0xff /* instanceInclusionMask */, 0 /* hitIdx */, rayTypeCount, 0 /* missIdx */, ray, rayData);

        //If ray is invalid return
        if (rayData.flags & (uint) Flags::Terminated){
            if(rayData.distance < 0)
                writeMiss(launchIndex, (rayData.flags & (uint) Flags::Miss) > 0);
            break;
        }
           
      
        //Update ray for next iteration
        ray.Origin = rayData.origin;
        ray.Direction = rayData.direction;
        if(i==0){
            ray.TMin = 0.001;    //Change tMin for transparent hits
        }
    }
}
