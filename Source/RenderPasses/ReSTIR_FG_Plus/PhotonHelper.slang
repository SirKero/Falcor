#pragma once
#include "Utils/Math/MathConstants.slangh"

import Scene.RaytracingInline;
import Utils.Sampling.SampleGenerator;
import Utils.Color.ColorHelpers;
import StructsAndHelpers;

StructuredBuffer<PhotonData> gPhotonData[2];
StructuredBuffer<AABB> gPhotonAABB[2];
RaytracingAccelerationStructure gPhotonAS;

static const float kPhotonCollectTMax = 1e-7;

struct PhotonSample {
    float3 posW;
    float radius;
    float3 normal;
    float weight;
    float3 radiance;
    float approxRadiance;

    __init() {
        posW = float3(0);
        radius = 0;
        normal = float3(0);
        weight = 0;
        radiance = float3(0);
        approxRadiance = 0;
    }
}

// Checks if the ray start point is inside the sphere.
bool hitSphere(const float3 center, const float radius, const float3 p)
{
    float3 radiusTest = p - center;
    return dot(radiusTest, radiusTest) < radius * radius;
}

void photonRIS(ShadingData sd, IMaterialInstance mi, float3 N, uint instanceMask, inout SampleGenerator sg, out PhotonSample photonSample, bool collectOnlyDirectGlobal = false) {
    photonSample = PhotonSample();
    RayDesc ray;
    ray.Origin = sd.posW;
    ray.Direction = sd.faceN;
    ray.TMin = 0;
    ray.TMax = kPhotonCollectTMax;

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
        float3 F = max(0, (photonData.flux * bsdf) / (M_PI * radius * radius * NdotL)); // NdotL needs to be taken out of the bsdf for Photon Mapping
        float approxF = luminance(F);
        photonSample.weight += approxF;
        bool selected = (sampleNext1D(sg) * photonSample.weight) < approxF;
        if (selected) {
            photonSample.posW = photonPosW;
            photonSample.radius = radius;
            photonSample.normal = photonData.normalW;
            photonSample.radiance = F;
            photonSample.approxRadiance = approxF;
        }
    }

    // Finalize RIS
    if (photonSample.approxRadiance > 0)
        photonSample.weight /= photonSample.approxRadiance;
}

float3 collectPhotons(ShadingData sd, IMaterialInstance mi, float3 N, uint instanceMask, inout SampleGenerator sg, bool collectOnlyDirectGlobal = false) {
    float3 collectedRadiance = float3(0);
    // Prepare ray
    RayDesc ray;
    ray.Origin = sd.posW;
    ray.Direction = sd.faceN;
    ray.TMin = 0;
    ray.TMax = kPhotonCollectTMax;

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
        collectedRadiance += max(0, (photonData.flux * bsdf) / (M_PI * radius * radius * NdotL)); // NdotL needs to be taken out of the bsdf for Photon Mapping
    }
    return collectedRadiance;
}
