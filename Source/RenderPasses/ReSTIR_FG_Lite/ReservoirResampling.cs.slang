#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.RaytracingInline;
import Utils.Sampling.SampleGenerator;
import Utils.Color.ColorHelpers;
import Utils.Math.MathHelpers;
import Rendering.RTXDI.RTXDI;
import StructsAndHelpers;

cbuffer CB
{
    uint gFrameCount; // Current it for sample gen
    uint2 gFrameDim;  // Frame Dimensions
    uint gConfidenceLimit;  //Confidence Limit

    uint gSpatialSamples;                   //Number of spatial samples
    uint gDisocclusionBoostSpatialSamples;  //How many extra spatial samples if temporal resampling fails
    float gSpatialRadius;   //radius for spatial resampling
    float gNormalThreshold; // Normal Threshold

    float gJacobianDistanceThreshold; // Jacobian distance threshold
    uint3 _pad;
}

Texture2D<float2> gMVec;
StructuredBuffer<ReservoirFG> gFinalGatherReservoirPrev;

RWStructuredBuffer<ReservoirFG> gFinalGatherReservoir;

static const uint kMIHints = (uint)MaterialInstanceHints::AdjustShadingNormal;

float generalizedBalanceHeuristic(ReservoirFG reservoir0, ShadingData sd0, BSDFProperties bsdf0, ShadingData sd1, BSDFProperties bsdf1, uint otherC) {
    float p0 = evaluateFinalGatherSampleApproximateUnbiased(reservoir0, sd0, bsdf0) * reservoir0.c;
    float p1 = evaluateFinalGatherSampleApproximateUnbiased(reservoir0, sd1, bsdf1) * otherC;

    float sum = (p0 + p1);

    if(sum > 0)
        return p0 / sum;
    else
        return 0;
}

ReservoirFG combineReservoirsFG(ReservoirFG current, ShadingData currentSD, BSDFProperties currentProps,
                                ReservoirFG other, ShadingData otherSD, BSDFProperties otherProps, inout SampleGenerator sg)
{
    ReservoirFG r = current;
    // Balance heuristic current
    float m_0, m_1 = 0;
    float w_0, w_1 = 0;

    if (current.isValid()) {
        m_0 = generalizedBalanceHeuristic(current, currentSD, currentProps, otherSD, otherProps, other.c);
        w_0 = m_0 * evaluateFinalGatherSampleApproximateUnbiased(current, currentSD, currentProps) * current.wSum;
    }
    
    r.wSum = w_0;

    float3 toSurfaceR1 = currentSD.posW - other.sampleData.posW;
    float distToSurfaceR1 = length(toSurfaceR1);
    bool jacobianThreshold = distToSurfaceR1 > gJacobianDistanceThreshold;
    bool otherReservoirValid = other.isValid() && jacobianThreshold;
    if (otherReservoirValid) {
        m_1 = generalizedBalanceHeuristic(other, otherSD, otherProps, currentSD, currentProps, current.c);
        w_1 = m_1 * evaluateFinalGatherSampleApproximateUnbiased(other, currentSD, currentProps) * other.wSum;
    }

    // Increase confidence weight only if jacobian threshold was fulfilled or if the sample is not valid
    if (jacobianThreshold || !other.isValid())
        r.c += other.c;

    r.wSum += w_1;

    bool selectOtherSample = (sampleNext1D(sg) * r.wSum) < w_1 && otherReservoirValid;
    if (selectOtherSample) {
        r.sampleData.posW = other.sampleData.posW;
        r.sampleData.normal = other.sampleData.normal;
        r.sampleData.radianceOut = other.sampleData.radianceOut;
        toSurfaceR1 /= distToSurfaceR1;
        r.jacobianDeterminant = dot(r.sampleData.normal, toSurfaceR1) / (distToSurfaceR1 * distToSurfaceR1);
    }

    float pHat = evaluateFinalGatherSampleApproximateUnbiased(r, currentSD, currentProps);
    if(pHat > 0)
        r.wSum /= pHat;
    else
        r.wSum = 0;

    //TODO this should not happen
    if (isnan(r.wSum) | isinf(r.wSum))
        return ReservoirFG();

    r.c = min(r.c, gConfidenceLimit);
    return r;
}

bool resampleReservoir(inout ReservoirFG current, ShadingData currentSD, BSDFProperties currentBsdfProperties, inout SampleGenerator sg , int2 resamplePixel) {

    // Fetch temporal reservoir
    if (any(resamplePixel < 0) || any(resamplePixel >= gFrameDim))
        return false;

    ReservoirFG temporal = gFinalGatherReservoirPrev[index2Dto1D(resamplePixel, gFrameDim.x)];
    HitInfo temporalHit = HitInfo(temporal.sampleSurface);
    if (!temporalHit.isValid()) {
        return false;
    }
    
    let lod = ExplicitLodTextureSampler(0.f);
    ShadingData temporalSD = loadShadingData(temporalHit, -temporal.sampleData.sampleView, lod);
    let temporalMi = gScene.materials.getMaterialInstance(temporalSD, lod, kMIHints);
    let temporalBsdfProperties = temporalMi.getProperties(temporalSD);

    // Check if surfaces are similar
    bool combine = true;
    if ((dot(temporalSD.faceN, currentSD.faceN) < gNormalThreshold) || (temporal.pathLength != current.pathLength))
        combine = false;

    // Reservoirs are valid, resample
    if (combine)
        current = combineReservoirsFG(current, currentSD, currentBsdfProperties, temporal, temporalSD, temporalBsdfProperties, sg);

    return combine;
}

[numthreads(16, 16, 1)]
void main(uint2 pixel: SV_DispatchThreadID)
{
    let lod = ExplicitLodTextureSampler(0.f);
    SampleGenerator sg = SampleGenerator(pixel, gFrameCount * 4 + 2);

    ReservoirFG current = gFinalGatherReservoir[index2Dto1D(pixel, gFrameDim.x)];
    HitInfo currentHit = HitInfo(current.sampleSurface);

    if (!currentHit.isValid())
        return;

    //Get Shading Data
    ShadingData currentSD = loadShadingData(currentHit, -current.sampleData.sampleView, lod);
    let currentMi = gScene.materials.getMaterialInstance(currentSD, lod, kMIHints);
    let currentBsdfProperties = currentMi.getProperties(currentSD);

    // Temporal Resampling

    // Reproject to the previous pixel using the motion vectors
    float2 motionOffset = gMVec[pixel] * float2(gFrameDim);
    float2 prevPixelF = motionOffset + float2(pixel) + float2(0.5);
    float2 rndOffset = sampleNext2D(sg) - 0.5;
    prevPixelF += rndOffset;

    int2 prevPixel = int2(prevPixelF);

    bool resamplingSuccesfull = resampleReservoir(current, currentSD, currentBsdfProperties, sg, prevPixel);

    // Spatiotemporal Resampling
    uint spatialSamples = resamplingSuccesfull ? gSpatialSamples : gSpatialSamples + gDisocclusionBoostSpatialSamples;
    for (uint i = 0; i < spatialSamples; i++) {
        // Sample in a sperical radius around the reprojected sample
        float2 spatialOffset = gSpatialRadius * sample_disk_concentric(sampleNext2D(sg));
        float2 spatialPixelF = prevPixelF + spatialOffset;

        int2 spatialPixel = int2(spatialPixelF);
        resampleReservoir(current, currentSD, currentBsdfProperties, sg, spatialPixel);
    }

    gFinalGatherReservoir[index2Dto1D(pixel, gFrameDim.x)] = current;
}
