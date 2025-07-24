#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.RaytracingInline;
import Utils.Sampling.SampleGenerator;
import Utils.Color.ColorHelpers;
import Rendering.RTXDI.RTXDI;
import StructsAndHelpers;

cbuffer CB
{
    uint gFrameCount; // Current it for sample gen
    uint2 gFrameDim;  // Frame Dimensions
    uint gConfidenceLimit;  //Confidence Limit

    float gSpatialRadius;   //radius for spatial resampling
    float gNormalThreshold; // Normal Threshold
    float gJacobianDistanceThreshold; //Jacobian distance threshold
}

Texture2D<float2> gMVec;
StructuredBuffer<ReservoirFG> gFinalGatherReservoirPrev;

RWStructuredBuffer<ReservoirFG> gFinalGatherReservoir;

float generalizedBalanceHeuristic(ReservoirFG reservoir0, ShadingData sd0, BSDFProperties bsdf0, ShadingData sd1, BSDFProperties bsdf1, uint otherC) {
    float p0 = evaluateFinalGatherSampleApproximateUnbiased(reservoir0, sd0, bsdf0) * reservoir0.c;
    float p1 = evaluateFinalGatherSampleApproximateUnbiased(reservoir0, sd1, bsdf1) * otherC;

    float sum = (p0 + p1);

    if(sum > 0)
        return p0 / sum;
    else
        return 0;
}

ReservoirFG combineReservoirsFG(ReservoirFG reservoir0, ShadingData sd0, BSDFProperties bsdf0, ReservoirFG reservoir1, ShadingData sd1, BSDFProperties bsdf1, inout SampleGenerator sg)
{
    ReservoirFG r = reservoir0;
    // Balance heuristic reservoir0
    float m_0, m_1 = 0;
    float w_0, w_1 = 0;

    if (reservoir0.isValid()) {
        m_0 = generalizedBalanceHeuristic(reservoir0, sd0, bsdf0, sd1, bsdf1, reservoir1.c);
        w_0 = m_0 * evaluateFinalGatherSampleApproximateUnbiased(reservoir0, sd0, bsdf0) * reservoir0.wSum;
    }
    
    r.wSum = w_0;

    float3 toSurfaceR1 = sd0.posW - reservoir1.sampleData.posW;
    float distToSurfaceR1 = length(toSurfaceR1);
    bool jacobianThreshold = distToSurfaceR1 > gJacobianDistanceThreshold;
    if (reservoir1.isValid() && jacobianThreshold) {
        m_1 = generalizedBalanceHeuristic(reservoir1, sd1, bsdf1, sd0, bsdf0, reservoir0.c);
        w_1 = m_1 * evaluateFinalGatherSampleApproximateUnbiased(reservoir1, sd1, bsdf1) * reservoir1.wSum;
    }

    //Increase confidence weight only if jacobian threshold was fulfilled or if the sample is not valid
    if (jacobianThreshold || !reservoir1.isValid())
        r.c += reservoir1.c;

    r.wSum += w_1;

    bool selectOtherSample = (sampleNext1D(sg) * r.wSum) < w_1;
    if (selectOtherSample) {
        r.sampleData.posW = reservoir1.sampleData.posW;
        r.sampleData.normal = reservoir1.sampleData.normal;
        r.sampleData.radianceOut = reservoir1.sampleData.radianceOut;
        toSurfaceR1 /= distToSurfaceR1;
        r.jacobianDeterminant = dot(r.sampleData.normal, toSurfaceR1) / (distToSurfaceR1 * distToSurfaceR1);
    }

    float pHat = evaluateFinalGatherSampleApproximateUnbiased(r, sd0, bsdf0);
    if(pHat > 0)
        r.wSum /= pHat;
    else
        r.wSum = 0;

    r.c = min(r.c, gConfidenceLimit);
    return r;
}

[numthreads(16, 16, 1)]
void main(uint2 pixel: SV_DispatchThreadID)
{
    let lod = ExplicitLodTextureSampler(0.f);
    SampleGenerator sg = SampleGenerator(pixel, gFrameCount * 4 + 2);
    uint miHints = (uint)MaterialInstanceHints::AdjustShadingNormal;

    ReservoirFG current = gFinalGatherReservoir[index2Dto1D(pixel, gFrameDim.x)];
    HitInfo currentHit = HitInfo(current.sampleSurface);
   
    //TODO handle this case
    if (!currentHit.isValid())
        return;

    //Get Shading Data
    ShadingData currentSD = loadShadingData(currentHit, -current.sampleData.sampleView, lod);
    let currentMi = gScene.materials.getMaterialInstance(currentSD, lod, miHints);
    let currentBsdfProperties = currentMi.getProperties(currentSD);

    // Temporal Resampling

    // Reproject to the previous pixel using the motion vectors
    float2 motionOffset = gMVec[pixel] * float2(gFrameDim);
    float2 prevPixelF = motionOffset + float2(pixel);
    float2 rndOffset = sampleNext2D(sg) - 0.5f;
    prevPixelF += rndOffset;

    uint2 prevPixel = uint2(round(prevPixelF));
    
    // Fetch temporal reservoir
    ReservoirFG temporal = gFinalGatherReservoirPrev[index2Dto1D(prevPixel, gFrameDim.x)];
    HitInfo temporalHit = HitInfo(temporal.sampleSurface);

    // TODO for now
    if (!temporalHit.isValid()) {
        return;
    }

    ShadingData temporalSD = loadShadingData(temporalHit, -temporal.sampleData.sampleView, lod);
    let temporalMi = gScene.materials.getMaterialInstance(temporalSD, lod, miHints);
    let temporalBsdfProperties = temporalMi.getProperties(temporalSD);

    // Check if surfaces are similar
    bool combine = true;
    if ((dot(temporalSD.faceN, currentSD.faceN) < gNormalThreshold) || (temporal.pathLength != current.pathLength) )
        combine = false;

    // Reservoirs are valid, resample
    if (combine)
        current = combineReservoirsFG(current, currentSD, currentBsdfProperties, temporal, temporalSD, temporalBsdfProperties, sg);

    gFinalGatherReservoir[index2Dto1D(pixel, gFrameDim.x)] = current;
}
