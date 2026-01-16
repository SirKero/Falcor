#pragma once
#include "Utils/Math/MathConstants.slangh"

import Scene.RaytracingInline;
import Utils.Sampling.SampleGenerator;
import Utils.Color.ColorHelpers;
import StructsAndHelpers;
import SharedEnums;

RWTexture2D<uint> gGuidingCounter;
RWTexture2D<uint> gLightIndexGuidingCounter;

StructuredBuffer<PhotonData> gPhotonData[2];
StructuredBuffer<AABB> gPhotonAABB[2];
RaytracingAccelerationStructure gPhotonAS;

static const float kPhotonCollectTMax = 1e-7;
static const uint kGuidingMode = GUIDING_MODE;
static const uint kLightIndexGuidingMode = LIGHT_INDEX_GUIDING_MODE;
static const uint kDiscretizedEmissionFactor = GUIDING_DISCRETIZED_EMISSION_FACTOR;
static const uint kLightIndexGuidingResolution = GUIDING_LIGHT_INDEX_SIZE;
static const bool kNotReSTIRPass = NOT_RESTIR_PASS;


struct PhotonSample {
    float3 posW;
    float radius;

    float3 normal;
    float weight;

    float3 radiance;
    float approxRadiance;

    int lightIndex;
    int2 guidingPixels;
    float guidingPdf;

    __init() {
        posW = float3(0);
        radius = 0;
        normal = float3(0);
        weight = 0;
        radiance = float3(0);
        approxRadiance = 0;
        lightIndex = -1;
        guidingPixels = int2(-1);
        guidingPdf = 0;
    }
}

// Checks if the ray start point is inside the sphere.
/*
bool hitSphere(const float3 center, const float radius, const float3 p)
{
    float3 radiusTest = p - center;
    return dot(radiusTest, radiusTest) < radius * radius;
}
*/
void addToGuidingTexture(PhotonData photonData, float emission) {
    if (emission <= 0)
        return;
    // Add to the guiding texture
    if (kGuidingMode == (uint)GuidingMode::Emission || (kNotReSTIRPass && kGuidingMode == (uint)GuidingMode::ReSTIR)) {
        uint currentColor = 0;
        uint originalValue;
        [allow_uav_condition]
        do {
            InterlockedAdd(gGuidingCounter[photonData.guidingPixel], 0u, currentColor);
            float color = asfloat(currentColor);
            uint updatedColor = asuint(color + emission);
            InterlockedCompareExchange(gGuidingCounter[photonData.guidingPixel], currentColor, updatedColor, originalValue);
        } while (originalValue != currentColor);
    } else if (kGuidingMode == (uint)GuidingMode::Uniform) {
        InterlockedAdd(gGuidingCounter[photonData.guidingPixel], 1u);
    } else if (kGuidingMode == (uint)GuidingMode::EmissionDiscretized || (kNotReSTIRPass && kGuidingMode == (uint)GuidingMode::ReSTIRDiscretized))
    {
        uint discretizedEmission = max(uint(round(kDiscretizedEmissionFactor * emission)), 1);
        InterlockedAdd(gGuidingCounter[photonData.guidingPixel], discretizedEmission);
    }

    //Add light index to guiding

    if (kLightIndexGuidingMode == (uint)GuidingLightIndexMode::Uniform)
    {
        uint2 lightIndexTexturePixel = index1Dto2D(photonData.lightIndex, kLightIndexGuidingResolution);
        InterlockedAdd(gLightIndexGuidingCounter[lightIndexTexturePixel], 1u);
    } else if (kLightIndexGuidingMode == (uint)GuidingLightIndexMode::DiscretizedEmission || (kNotReSTIRPass && (kLightIndexGuidingMode == (uint)GuidingLightIndexMode::ReSTIR || kLightIndexGuidingMode == (uint)GuidingLightIndexMode::ReSTIRConf)))
    {
        uint2 lightIndexTexturePixel = index1Dto2D(photonData.lightIndex, kLightIndexGuidingResolution);
        uint discretizedEmission = max(uint(round(kDiscretizedEmissionFactor * emission)), 1);
        InterlockedAdd(gLightIndexGuidingCounter[lightIndexTexturePixel], discretizedEmission);
    }
}

void photonRIS(ShadingData sd, IMaterialInstance mi, float3 N, uint instanceMask, uint numLightPaths, inout SampleGenerator sg, out PhotonSample photonSample, bool collectOnlyDirectGlobal = false) {
    photonSample = PhotonSample();
    RayDesc ray;
    ray.Origin = sd.posW;
    ray.Direction = sd.faceN;
    ray.TMin = 0;
    ray.TMax = kPhotonCollectTMax;
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
        float3 photonPosW = photonAABB.center();
        float radius = (photonAABB.maxPoint.x - photonAABB.minPoint.x) / 2.0;
        if (!hitSphere(photonPosW, radius, sd.posW))
            continue;

        PhotonData photonData = gPhotonData[instanceIdx][primIdx];

        // If direct global photons should be collected and the photon is global, check the path length
        if (collectOnlyDirectGlobal)
        {
            if (((PhotonType)instanceIdx == PhotonType::Global) && (photonData.pathLenght > 0))
                continue;
        }

        float NdotL = dot(photonData.dir, N);
        // Check for diffent surfaces (e.g. corners)
        if ((dot(photonData.normalW, sd.faceN) < 0.6) || (NdotL <= 0))
            continue;

        float3 bsdf = mi.eval(sd, photonData.dir, sg);
        float3 F = max(0, (photonData.flux * bsdf) / (photonWeight * radius * radius * NdotL)); // NdotL needs to be taken out of the bsdf for Photon Mapping
        float approxF = luminance(F);
        addToGuidingTexture(photonData, approxF);
        photonSample.weight += approxF;
        bool selected = (sampleNext1D(sg) * photonSample.weight) < approxF;
        if (selected) {
            photonSample.posW = photonPosW;
            photonSample.radius = radius;
            photonSample.normal = photonData.normalW;
            photonSample.radiance = F;
            photonSample.approxRadiance = approxF;
            photonSample.lightIndex = photonData.lightIndex;
            photonSample.guidingPixels = photonData.guidingPixel;
        }
    }

    // Finalize RIS
    if (photonSample.approxRadiance > 0)
        photonSample.weight /= photonSample.approxRadiance;
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
            if (((PhotonType)instanceIdx == PhotonType::Global) && (photonData.pathLenght > 0))
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
            if (photonData.pathLenght > 0)
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
