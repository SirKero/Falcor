#pragma once
#include "Utils/Math/MathConstants.slangh"

import Scene.RaytracingInline;
import Utils.Sampling.SampleGenerator;
import Utils.Color.ColorHelpers;
import StructsAndHelpers;
import SharedEnums;

RWTexture2D<uint> gGuidingCounter;
RWTexture2D<uint> gLightIndexGuidingCounter;
Texture2D<uint> gMapLightIndexToGuidingDirection;

StructuredBuffer<PhotonData> gPhotonData[2];
StructuredBuffer<AABB> gPhotonAABB[2];
StructuredBuffer<uint> gPhotonDirSGPackedPixel[2]; 
RaytracingAccelerationStructure gPhotonAS;

static const float kPhotonCollectTMax = 1e-7;
static const uint kPhotonGlobalBufferIndex = 0;
static const uint kPhotonCausticBufferIndex = 1;
static const uint kGuidingMode = GUIDING_MODE;
static const uint kDiscretizedEmissionFactor = GUIDING_DISCRETIZED_EMISSION_FACTOR;
static const uint kDiscretizedEmissionMax = GUIDING_DISCRETIZED_EMISSION_MAX;
static const uint kLightIndexGuidingResolution = GUIDING_LIGHT_INDEX_SIZE;
static const bool kNotReSTIRPass = NOT_RESTIR_PASS;
static const bool kEnablePhotonRetracing = ENABLE_PHOTON_RETRACING;
static const bool kUseOptimizedAtlas = USE_OPTIMIZED_ATLAS;

//TODO move these to defines? 
cbuffer PhotonHelperCB
{
    uint gLightIndexGuidingResolution;
    uint gGuidingTextureResolution;
    uint gMapTextureResolution;
}

struct PhotonSample {
    float3 posW;
    float radius;

    float3 normal;
    float weight;

    float3 radiance;
    float approxRadiance;

    int lightIndex;
    uint packedGuidingPixels;
    float guidingPdf;
    uint packedStartPixelAndPathLength;

    __init() {
        posW = float3(0);
        radius = 0;
        normal = float3(0);
        weight = 0;
        radiance = float3(0);
        approxRadiance = 0;
        lightIndex = -1;
        packedGuidingPixels = 0;
        packedStartPixelAndPathLength = 0;
    }

    property uint2 guidingPixels {
        get { return uint2(packedGuidingPixels & 0xFFFF, (packedGuidingPixels >> 16) & 0xFFFF); }
        set {
            packedGuidingPixels = newValue.x & 0xFFFF;
            packedGuidingPixels |= (newValue.y & 0xFFFF) << 16;
        }
    }
}

uint getDiscretizedEmission(float emission) {
    uint discretizedEmission = uint(round(kDiscretizedEmissionFactor * emission));
    return clamp(discretizedEmission, 1, kDiscretizedEmissionMax);
}

void addToGuidingTexture(PhotonData photonData, float emission) {
    if (emission <= 0)
        return;

    // Record light index guiding map
    if (kUseOptimizedAtlas)
    {
        if (kGuidingMode == (uint)GuidingMode::Uniform)
        {
            uint2 lightIndexTexturePixel = index1Dto2D(photonData.lightIndex, kLightIndexGuidingResolution);
            InterlockedAdd(gLightIndexGuidingCounter[lightIndexTexturePixel], 1u);
        } else if (kGuidingMode == (uint)GuidingMode::Emission || kGuidingMode == (uint)GuidingMode::EmissionDiscretized || (kNotReSTIRPass && (kGuidingMode >= (uint)GuidingMode::HigherIsReSTIR)))
        {
            uint2 lightIndexTexturePixel = index1Dto2D(photonData.lightIndex, kLightIndexGuidingResolution);
            InterlockedAdd(gLightIndexGuidingCounter[lightIndexTexturePixel], getDiscretizedEmission(emission));
        }
    }
    
    //Get corresponding atlas pixel
    uint2 guidingPixel = photonData.guidingPixel;
    if (kUseOptimizedAtlas) {
        uint2 lightPixel = uint2(photonData.lightIndex % gLightIndexGuidingResolution, photonData.lightIndex / gLightIndexGuidingResolution);
        uint mapIdx = gMapLightIndexToGuidingDirection[lightPixel];

        //If mapped index is invalid, return
        if(mapIdx >= kAtlasOptimizationMaxMapIndex)
            return;
        
        guidingPixel += uint2(mapIdx % gMapTextureResolution, mapIdx / gMapTextureResolution) * gGuidingTextureResolution;
    }

    // Add to directional guiding texture
    if (kGuidingMode == (uint)GuidingMode::Emission || (kNotReSTIRPass && kGuidingMode == (uint)GuidingMode::ReSTIR)) {
        uint currentColor = 0;
        uint originalValue;
        [allow_uav_condition]
        do {
            InterlockedAdd(gGuidingCounter[guidingPixel], 0u, currentColor);
            float color = asfloat(currentColor);
            uint updatedColor = asuint(color + emission);
            InterlockedCompareExchange(gGuidingCounter[guidingPixel], currentColor, updatedColor, originalValue);
        } while (originalValue != currentColor);
    } else if (kGuidingMode == (uint)GuidingMode::Uniform) {
        InterlockedAdd(gGuidingCounter[guidingPixel], 1u);
    } else if (kGuidingMode == (uint)GuidingMode::EmissionDiscretized || (kNotReSTIRPass && (kGuidingMode >= (uint)GuidingMode::HigherIsReSTIR)))
    {
        InterlockedAdd(gGuidingCounter[guidingPixel], getDiscretizedEmission(emission));
    }    
}

int photonRIS(ShadingData sd, IMaterialInstance mi, float3 N, uint instanceMask, uint numLightPaths, inout SampleGenerator sg, out PhotonSample photonSample, bool collectOnlyDirectGlobal = false) {
    int photonHitType = -1; // -1 = None, 0 = Global, 1 = Caustic
    photonSample = PhotonSample();
    RayDesc ray;
    ray.Origin = sd.posW;
    ray.Direction = sd.faceN;
    ray.TMin = 0;
    ray.TMax = kPhotonCollectTMax;
    const float photonWeight = M_PI * numLightPaths;
    #if ENABLE_PHOTON_RETRACING
        uint2 choosenPhotonInstanceAndPrimIndex = uint2(0);
    #endif

    RayQuery<RAY_FLAG_NONE> rayQuery;
    rayQuery.TraceRayInline(gPhotonAS, RAY_FLAG_NONE, instanceMask, ray);
    while (rayQuery.Proceed()) {

        if (rayQuery.CandidateType() != CANDIDATE_PROCEDURAL_PRIMITIVE)
            continue;
        const uint instanceIdx = rayQuery.CandidateInstanceIndex();
        const uint primIdx = rayQuery.CandidatePrimitiveIndex();

        // Check if ray is inside photon radius
        AABB photonAABB = gPhotonAABB[instanceIdx][primIdx];
        float3 photonPosW = photonAABB.center();
        float radius = (photonAABB.maxPoint.x - photonAABB.minPoint.x) / 2.0;
        if (!hitSphere(photonPosW, radius, sd.posW))
            continue;

        PhotonData photonData = gPhotonData[instanceIdx][primIdx];

        // If direct global photons should be collected and the photon is global, check the path length
        if (collectOnlyDirectGlobal)
        {
            if (((PhotonType)instanceIdx == PhotonType::Global) && (photonData.pathLength > 0))
                continue;
        }

        float NdotL = dot(photonData.dir, N);
        // Check for diffent surfaces (e.g. corners)
        if ((dot(photonData.normalW, sd.faceN) < 0.6) || (NdotL <= 0))
            continue;

        float3 bsdf = mi.eval(sd, photonData.dir, sg);
        float divident = (photonWeight * radius * radius * NdotL);
        float3 F = max(0, (photonData.flux * bsdf) / divident); // NdotL needs to be taken out of the bsdf for Photon Mapping
        float approxF = luminance(F);
        addToGuidingTexture(photonData, approxF);
        photonSample.weight += approxF;
        bool selected = (sampleNext1D(sg) * photonSample.weight) < approxF;
        if (selected) {
            photonHitType = instanceIdx;
            photonSample.posW = photonPosW;
            photonSample.radius = radius;
            photonSample.normal = photonData.normalW;
            photonSample.radiance = F;
            photonSample.approxRadiance = approxF;
            photonSample.lightIndex = photonData.lightIndex;
            photonSample.guidingPixels = photonData.guidingPixel;
            photonSample.guidingPdf = (photonData.guidingPdf * numLightPaths);
            #if ENABLE_PHOTON_RETRACING
                choosenPhotonInstanceAndPrimIndex = uint2(instanceIdx, primIdx);
            #endif
            
        }
    }

    // Finalize RIS
    if (photonSample.approxRadiance > 0){
        photonSample.weight /= photonSample.approxRadiance;

        //If photon retracing is enabled, prepare retrace data
        #if ENABLE_PHOTON_RETRACING
            photonSample.packedStartPixelAndPathLength = gPhotonDirSGPackedPixel[choosenPhotonInstanceAndPrimIndex.x][choosenPhotonInstanceAndPrimIndex.y];
        #endif
    }
    return photonHitType;
}

float3 collectPhotons(ShadingData sd, IMaterialInstance mi, float3 N, uint instanceMask, uint numLightPaths, inout SampleGenerator sg, bool collectOnlyDirectGlobal = false) {
    float3 collectedRadiance = float3(0);
    // Prepare ray
    RayDesc ray;
    ray.Origin = sd.posW;
    ray.Direction = sd.faceN;
    ray.TMin = 0;
    ray.TMax = kPhotonCollectTMax;

    RayQuery<RAY_FLAG_NONE> rayQuery;
    const float photonWeight = M_PI * numLightPaths;

    rayQuery.TraceRayInline(gPhotonAS, RAY_FLAG_NONE, instanceMask, ray);
    while (rayQuery.Proceed()) {

        if (rayQuery.CandidateType() != CANDIDATE_PROCEDURAL_PRIMITIVE)
            continue;
        const uint instanceIdx = rayQuery.CandidateInstanceIndex();
        const uint primIdx = rayQuery.CandidatePrimitiveIndex();

        // Check if ray is inside photon radius
        AABB photonAABB = gPhotonAABB[instanceIdx][primIdx];
        float radius = (photonAABB.maxPoint.x - photonAABB.minPoint.x) / 2.0;
        if (!hitSphere(photonAABB.center(), radius, sd.posW))
            continue;

        PhotonData photonData = gPhotonData[instanceIdx][primIdx];

        // If direct global photons should be collected and the photon is global, check the path length
        if (collectOnlyDirectGlobal)
        {
            if (((PhotonType)instanceIdx == PhotonType::Global) && (photonData.pathLength > 0))
                continue;
        }

        float NdotL = dot(photonData.dir, N);
        // Check for diffent surfaces (e.g. corners)
        if ((dot(photonData.normalW, sd.faceN) < 0.6) || (NdotL <= 0))
            continue;

        float3 bsdf = mi.eval(sd, photonData.dir, sg);
        float3 photonRadiance = max(0, (photonData.flux * bsdf) / (photonWeight * radius * radius * NdotL));
        collectedRadiance += photonRadiance; // NdotL needs to be taken out of the bsdf for Photon Mapping

        addToGuidingTexture(photonData, luminance(photonRadiance));
    }
    return collectedRadiance;
}

// Select one Final Gather sample representing all samples using RIS
void selectFGSample(inout ReservoirFG r, float pdf, ShadingData sd, IMaterialInstance mi, float3 N, uint instanceMask, uint numLightPaths, inout SampleGenerator sg) {
    float3 collectedRadiance = float3(0);
    // Prepare ray
    RayDesc ray;
    ray.Origin = sd.posW;
    ray.Direction = sd.faceN;
    ray.TMin = 0;
    ray.TMax = kPhotonCollectTMax;

    let bsdfProperties = mi.getProperties(sd);
    const float photonWeight = M_PI * numLightPaths;

    RayQuery<RAY_FLAG_NONE> rayQuery;

    rayQuery.TraceRayInline(gPhotonAS, RAY_FLAG_NONE, instanceMask, ray);
    while (rayQuery.Proceed()) {

        if (rayQuery.CandidateType() != CANDIDATE_PROCEDURAL_PRIMITIVE)
            continue;
        const uint instanceIdx = rayQuery.CandidateInstanceIndex();
        const uint primIdx = rayQuery.CandidatePrimitiveIndex();

        // Check if ray is inside photon radius
        AABB photonAABB = gPhotonAABB[instanceIdx][primIdx];
        float radius = (photonAABB.maxPoint.x - photonAABB.minPoint.x) / 2.0;
        if (!hitSphere(photonAABB.center(), radius, sd.posW))
            continue;

        PhotonData photonData = gPhotonData[instanceIdx][primIdx];
        float NdotL = dot(photonData.dir, N);
        // Check for diffent surfaces (e.g. corners)
        if ((dot(photonData.normalW, sd.faceN) < 0.6) || (NdotL <= 0))
            continue;

        float targetFunction = 0;
        float3 radianceOut = float3(0);
        if (NdotL > 0) {
            float3 bsdf = mi.eval(sd, photonData.dir, sg);
            radianceOut = (photonData.flux * bsdf) / NdotL;
            targetFunction = luminance(radianceOut);
        }
        float photonDenom = photonWeight * radius * radius * pdf;
        float w = targetFunction / photonDenom;

        r.wSum += w;
        bool selectNew = (sampleNext1D(sg) * r.wSum) < w;
        if (selectNew) {
            r.targetFunction = targetFunction;
            r.sampleData.radianceOut = radianceOut;
            // Guiding data
            r.lightIndex = photonData.lightIndex;
            r.guidingPixels = photonData.guidingPixel;
        }

        // Guiding
        addToGuidingTexture(photonData, w);
    }

    // Finalize Reservoir
    if (r.targetFunction > 0) {
        r.wSum /= r.targetFunction;
    }
    else
        r.wSum = 0;
}

void photonResampling(ShadingData sd, BSDFProperties bsdfProperties, bool collectGlobalDirect, uint numLightPaths, inout ReservoirCaustic causticReservoir, inout SampleGenerator sg) {
    // Prepare ray
    RayDesc ray;
    ray.Origin = sd.posW;
    ray.Direction = sd.faceN;
    ray.TMin = 0;
    ray.TMax = kPhotonCollectTMax;

    const float photonWeight = M_PI * numLightPaths;
    RayQuery<RAY_FLAG_NONE> rayQuery;
    uint instanceMask = collectGlobalDirect ? 0xFF : 2; // 2 is caustic only

    rayQuery.TraceRayInline(gPhotonAS, RAY_FLAG_NONE, instanceMask, ray);
    while (rayQuery.Proceed()) {

        if (rayQuery.CandidateType() != CANDIDATE_PROCEDURAL_PRIMITIVE)
            continue;
        const uint instanceIdx = rayQuery.CandidateInstanceIndex();
        const uint primIdx = rayQuery.CandidatePrimitiveIndex();
        PhotonType type = (PhotonType)instanceIdx;
        // Check if ray is inside photon radius
        AABB photonAABB = gPhotonAABB[instanceIdx][primIdx];
        float radius = (photonAABB.maxPoint.x - photonAABB.minPoint.x) / 2.0;
        float3 center = photonAABB.center();
        if (!hitSphere(center, radius, sd.posW))
            continue;

        PhotonData photonData = gPhotonData[instanceIdx][primIdx];

        // If direct global photons should be collected and the photon is global, check the path length
        if (collectGlobalDirect && (type == PhotonType::Global)) {
            if (photonData.pathLength > 0)
                continue;
        }

        float NdotL = dot(photonData.dir, bsdfProperties.guideNormal);
        // Check for diffent surfaces (e.g. corners)
        if ((dot(photonData.normalW, sd.getOrientedFaceNormal()) < 0.6) || (NdotL <= 0))
            continue;

        float targetFunction = 0;
        if (NdotL > 0)
            targetFunction = evalApproximateBRDFPhoton(sd, bsdfProperties, photonData.dir) * luminance(photonData.flux);
        float photonDenom = photonWeight * radius * radius;
        float w = targetFunction / photonDenom;

        causticReservoir.wSum += w;
        bool selectNew = (sampleNext1D(sg) * causticReservoir.wSum) < w;
        if (selectNew) {
            causticReservoir.photonPosW = center;
            causticReservoir.photonDir = photonData.dir;
            causticReservoir.photonRadiance = photonData.flux;
            causticReservoir.targetFunction = targetFunction;

            // Guiding data
            causticReservoir.lightIndex = photonData.lightIndex;
            causticReservoir.guidingPixels = photonData.guidingPixel;
        }

        // Add to guiding
        addToGuidingTexture(photonData, w);
    }

    // Finalize Reservoir
    if (causticReservoir.targetFunction > 0) {
        causticReservoir.wSum /= causticReservoir.targetFunction;
    }
    else
        causticReservoir.wSum = 0;
    causticReservoir.c = 1;
}
