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
    bool gUsePathThreshold; //Enables and disables path threshold
    uint2 _pad;
}

Texture2D<float2> gMVec;
StructuredBuffer<ReservoirFG> gFinalGatherReservoirPrev;

RWStructuredBuffer<ReservoirFG> gFinalGatherReservoir;

static const uint kMIHints = (uint)MaterialInstanceHints::AdjustShadingNormal;

float generalizedBalanceHeuristic(ReservoirFG reservoir0, ShadingData sd0, BSDFProperties bsdf0, ShadingData sd1, BSDFProperties bsdf1, uint otherC) {
    float p0 = reservoir0.targetFunction * reservoir0.c;
    float p1 = evaluateFinalGatherSampleApproximateUnbiased(reservoir0, sd1, bsdf1) * otherC;

    float sum = (p0 + p1);

    if(sum > 0)
        return p0 / sum;
    else
        return 0;
}

bool combineReservoirsFG(inout ReservoirFG current, ShadingData currentSD, BSDFProperties currentProps,
                                ReservoirFG other, ShadingData otherSD, BSDFProperties otherProps, inout SampleGenerator sg)
{
    //Check if surfaces are similar
    float3 toSurfaceOther = currentSD.posW - other.sampleData.posW;
    float distToSurfaceOther = length(toSurfaceOther);
    toSurfaceOther /= distToSurfaceOther; //Normalize
    bool jacobianThreshold = distToSurfaceOther <= gJacobianDistanceThreshold;
    bool normalThreshold = dot(otherSD.faceN, currentSD.faceN) < gNormalThreshold;
    bool pathThreshold = gUsePathThreshold ? (other.pathLength != current.pathLength) : false;
    if (normalThreshold || pathThreshold || jacobianThreshold)
        return false;

    //Needed reservoir variables
    float w_0, w_1 = 0;
    float wSum = 0;

    if (current.isValid()) {
        float mis = generalizedBalanceHeuristic(current, currentSD, currentProps, otherSD, otherProps, other.c);
        w_0 = mis * current.targetFunction * current.wSum;
        wSum += w_0;
    }
           
    bool otherReservoirValid = other.isValid();
    float targetFunctionOther = 0.0;
    if (otherReservoirValid) {
        float mis = generalizedBalanceHeuristic(other, otherSD, otherProps, currentSD, currentProps, current.c);
        //Check if sample can be shifted
        if (dispatchShadowRay(currentSD, -toSurfaceOther, distToSurfaceOther)) {
            targetFunctionOther = evalApproximateBRDF(currentSD, currentProps, -toSurfaceOther) * luminance(other.sampleData.radianceOut);
            float jacobianDeterminant = dot(other.sampleData.normal, toSurfaceOther) / (distToSurfaceOther * distToSurfaceOther);
            jacobianDeterminant /= other.jacobianDeterminant;
            w_1 = mis * targetFunctionOther * jacobianDeterminant * other.wSum;
        }
        wSum += w_1;
    }
    
    bool selectOtherSample = (sampleNext1D(sg) * wSum) < w_1 && otherReservoirValid;
    if (selectOtherSample) {
        current.sampleData.posW = other.sampleData.posW;
        current.sampleData.normal = other.sampleData.normal;
        current.sampleData.radianceOut = other.sampleData.radianceOut;
        current.targetFunction = targetFunctionOther;
        current.jacobianDeterminant = dot(current.sampleData.normal, toSurfaceOther) / (distToSurfaceOther * distToSurfaceOther);
    }

    //Increase confidence weights
    current.c += other.c;
    current.c = min(current.c, gConfidenceLimit);

    if (current.targetFunction > 0)
        current.wSum = wSum / current.targetFunction;
    else
        current.wSum = 0;

    if (isnan(current.wSum) || isinf(current.wSum))
        current.wSum = 0;

    return true;
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
    bool valid = combineReservoirsFG(current, currentSD, currentBsdfProperties, temporal, temporalSD, temporalBsdfProperties, sg);

    return valid;
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

    // Precalculate the targetFunction
    float3 toLight = normalize(current.sampleData.posW - currentSD.posW);
    current.targetFunction = evalApproximateBRDF(currentSD, currentBsdfProperties, toLight) * luminance(current.sampleData.radianceOut);

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
