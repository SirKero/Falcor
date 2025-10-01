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

    float2 gPhotonRadius;                  // Global / Caustic
    uint gSpatialSamples;                  // Number of spatial samples
    uint gDisocclusionBoostSpatialSamples; // How many extra spatial samples if temporal resampling fails

    float4x4 gPrevCamViewProjection; //Previous Camera view projection for splatting

    float3 gPrevCamPos;   // Previous camera position for splatting
    float gSpatialRadius; // radius for spatial resampling

    float3 gPrevCamForward; //Previous camera forward for splatting
    float gNormalThreshold; // Normal Threshold

    float gNormalizedPixelArea;
    uint3 _pad;
}

Texture2D<float2> gMVec;
StructuredBuffer<ReservoirCaustic> gCausticReservoirPrev;

RWStructuredBuffer<ReservoirCaustic> gCausticReservoir;

// Splatting
StructuredBuffer<uint> gCellCounters; // Number of reservoirs per pixel
StructuredBuffer<uint> gCellOffsets;  // Initial offset for the sorted reservoir buffer
StructuredBuffer<uint2> gSortedReservoirs;   // Buffer of splatted reservoirs

static const uint kMIHints = (uint)MaterialInstanceHints::AdjustShadingNormal;

inline float getPhotonRadius(ReservoirCaustic r) {
    return r.pathLength == 0 ? gPhotonRadius.y : gPhotonRadius.x;
}

// Generalized Balance Heuristic with two samples
float generalizedBalanceHeuristic(ReservoirCaustic r, ShadingData otherSD, BSDFProperties otherProps, uint otherC) {
    float p0 = r.targetFunction * r.c;
    float p1 = 0;
    if (length(otherSD.posW - r.photonPosW) < getPhotonRadius(r))
        p1 = evalApproximateBRDFPhoton(otherSD, otherProps, r.photonDir) * luminance(r.photonRadiance) * otherC;

    float sum = (p0 + p1);
    if (sum > 0)
        return p0 / sum;
    else
        return 0;
}

//Resampling with 2 reservoirs. Finalizes the reservoir afterwards.
bool combineReservoirsCaustic(inout ReservoirCaustic current, ShadingData currentSD, BSDFProperties currentProps,
                                ReservoirCaustic other, ShadingData otherSD, BSDFProperties otherProps, inout SampleGenerator sg)
{
    //Check if surfaces are similar and resampling can be performed
    bool normalThreshold = dot(otherSD.faceN, currentSD.faceN) < gNormalThreshold;
    bool pathThreshold = (other.pathLength != current.pathLength);
    bool surfacesPosThreshold = length(currentSD.posW - otherSD.posW) >= (2 * getPhotonRadius(current));
    if (normalThreshold || pathThreshold || surfacesPosThreshold)
        return false;

    //Needed reservoir variables
    float w_0, w_1 = 0;
    float wSum = 0;
   
    //Get ReSTIR weight of current reservoir
    if (current.isValid()) {
        float mis = generalizedBalanceHeuristic(current, otherSD, otherProps, other.c);
        w_0 = mis * current.targetFunction * current.wSum;
        wSum += w_0;
    }

    //Calculate ReSTIR weight for other reservoir sample
    float targetFunctionOther = 0.0;
    bool otherReservoirValid = other.isValid();
    if (otherReservoirValid) {
        // Check if sample is part of the domain
        if (length(currentSD.posW - other.photonPosW) < getPhotonRadius(other)) {
            float mis = generalizedBalanceHeuristic(other, currentSD, currentProps, current.c);
            targetFunctionOther = evalApproximateBRDFPhoton(currentSD, currentProps, other.photonDir) * luminance(other.photonRadiance);
            w_1 = mis * targetFunctionOther * other.wSum;
        }
        wSum += w_1;
    }

    //Check if other sample is selected and replace in reservoir if it was selected
    bool selectOtherSample = (sampleNext1D(sg) * wSum) < w_1 && otherReservoirValid;
    if (selectOtherSample) {
        current.photonPosW = other.photonPosW;
        current.photonDir = other.photonDir;
        current.photonRadiance = other.photonRadiance;
        current.targetFunction = targetFunctionOther;
    }

    //Increase confidence weights
    current.c += other.c;
    current.c = min(current.c, gConfidenceLimit);

    //Finalize reservoir (wSum -> W)
    if (current.targetFunction > 0)
        current.wSum = wSum / current.targetFunction;
    else
        current.wSum = 0;

    //If something went wrong, set reservoir to 0
    if (isnan(current.wSum) || isinf(current.wSum))
        current.wSum = 0;

    return true;
}

bool resampleReservoir(inout ReservoirCaustic current, ShadingData currentSD, BSDFProperties currentBsdfProperties, inout SampleGenerator sg , int2 resamplePixel) {

    //Check if reservoir is inside the screen. 
    if (any(resamplePixel < 0) || any(resamplePixel >= gFrameDim))
        return false;

    //Fetch the (spatio)temporal reservoir
    ReservoirCaustic temporal = gCausticReservoirPrev[index2Dto1D(resamplePixel, gFrameDim.x)];
    HitInfo temporalHit = HitInfo(temporal.sampleSurface);
    if (!temporalHit.isValid()) {
        return false;
    }

    //Get shading datas
    let lod = ExplicitLodTextureSampler(0.f);
    ShadingData temporalSD = loadShadingData(temporalHit, temporal.sampleSurfaceView, lod);
    let temporalMi = gScene.materials.getMaterialInstance(temporalSD, lod, kMIHints);
    let temporalBsdfProperties = temporalMi.getProperties(temporalSD);

    //Combine both reservoirs
    bool valid = combineReservoirsCaustic(current, currentSD, currentBsdfProperties, temporal, temporalSD, temporalBsdfProperties, sg);

    return valid;
}

void resampleReservoirReflectOrRefract(inout ReservoirCaustic current, uint2 pixel, ShadingData currentSD, BSDFProperties currentBsdfProperties, inout SampleGenerator sg)
{
    // Precalculate the targetFunction
    current.targetFunction = evalApproximateBRDFPhoton(currentSD, currentBsdfProperties, current.photonDir) * luminance(current.photonRadiance);

    //
    // Temporal Resampling
    //

    // Reproject to the previous pixel using the motion vectors
    float2 motionOffset = gMVec[pixel] * float2(gFrameDim);
    float2 prevPixelF = motionOffset + float2(pixel) + float2(0.5);
    float2 rndOffset = sampleNext2D(sg) - 0.5;
    prevPixelF += rndOffset;
    int2 prevPixel = int2(prevPixelF);

    bool resamplingSuccesfull = resampleReservoir(current, currentSD, currentBsdfProperties, sg, prevPixel);

    //
    // Spatiotemporal Resampling
    //
    uint spatialSamples = resamplingSuccesfull ? gSpatialSamples : gSpatialSamples + gDisocclusionBoostSpatialSamples;
    for (uint i = 0; i < spatialSamples; i++) {
        // Sample in a disc radius around the reprojected sample
        float2 spatialOffset = gSpatialRadius * sample_disk_concentric(sampleNext2D(sg));
        float2 spatialPixelF = prevPixelF + spatialOffset;
        int2 spatialPixel = int2(spatialPixelF);

        resampleReservoir(current, currentSD, currentBsdfProperties, sg, spatialPixel);
    }
}

void reservoirSplatting(inout ReservoirCaustic current, uint2 pixel, ShadingData currentSD, IMaterialInstance currentMi , BSDFProperties currentBsdfProperties, inout SampleGenerator sg)
{
    float currentMIS = 0.0;
    ReservoirCaustic dstR = current;
    // MIS for current reservoir
    if (current.isValid())
    {
        float p2 = 0.0;
        float p1 = current.targetFunction * current.c;
        // Get mis for temporal reprojection
        float3 toPrevCam = gPrevCamPos - currentSD.posW;
        float distToPrevCam = length(toPrevCam);
        toPrevCam /= distToPrevCam;

        // Visibility ray and camera view
        float3 prevScreenPos = getCameraProjection(gPrevCamViewProjection, currentSD.posW);
        bool isVisible = (all(prevScreenPos.xyz >= 0) && all(prevScreenPos.xyz < 1));

        if (isVisible)
        {
            SceneRayQuery<1> rayQuery;
            const Ray ray = Ray(currentSD.computeNewRayOrigin(), toPrevCam, 0.0, distToPrevCam);
            isVisible &= rayQuery.traceVisibilityRay(ray, RAY_FLAG_NONE, 0xff);
        }

        if (isVisible) {
            // Calc jacobians
            float jacobianShifted = getSubpixelLocationJacobian(distToPrevCam, toPrevCam, currentSD.faceN, gPrevCamForward);
            jacobianShifted /= current.subPixelJacobian;
            const float3 bsdf = currentMi.eval(currentSD, toPrevCam, sg);
            const float camPdf = getCameraBackprojectPDF(toPrevCam, distToPrevCam, gPrevCamForward, gNormalizedPixelArea);
            float prevTargetFunc = luminance(current.photonRadiance * bsdf) / camPdf;
            p2 = prevTargetFunc * jacobianShifted;
            p2 = isnan(p2) ? 0.0f : p2;
            // get confidence weight from backprojection
            uint2 prevPixel = uint2(floor(prevScreenPos.xy * gFrameDim));
            ReservoirCaustic prevR = gCausticReservoirPrev[index2Dto1D(prevPixel, gFrameDim.x)];
            p2 *= prevR.c;
            
        }
        float sum = (p1 + p2);
        if (sum > 0)
            currentMIS = p1 / sum;
        else
            currentMIS = 0.0;
    }
    float w0 = currentMIS * current.targetFunction * current.wSum;
    float wSum = w0;

    // Shift the other samples
    uint reservoirIdx = index2Dto1D(pixel, gFrameDim.x);
    uint numReservoirs = gCellCounters[reservoirIdx];
    uint cellOffset = gCellOffsets[reservoirIdx];
    let lod = ExplicitLodTextureSampler(0.0);
    const float3 currentCamPosW = gScene.camera.getPosition();
    const float3 currentCamForward = normalize(gScene.camera.data.cameraW);
    float newConfidence = current.c;
    for (uint i = 0; i < numReservoirs; i++)
    {
        uint2 splattedPixel = gSortedReservoirs[cellOffset + i];
        ReservoirCaustic prevR = gCausticReservoirPrev[index2Dto1D(splattedPixel, gFrameDim.x)];
        float prevMIS = 0.0;
        float targetFunc = 0.0;
        float jacobianToCurrent = 0.0;
        bool prevReservoirValid = prevR.isValid();
        if (prevReservoirValid)
        {
            //Load surface data
            ShadingData prevSD = loadShadingData(HitInfo(prevR.sampleSurface), prevR.sampleSurfaceView, lod);
            let prevMi = gScene.materials.getMaterialInstance(prevSD, lod, kMIHints);

            float p1 = prevR.targetFunction * prevR.c;
            float p2 = 0.0;

            // MIS weight for current (Visibility was already tested in a previous pass)
            float3 toCurrentCam = currentCamPosW - prevSD.posW;
            float distToCurrentCam = length(toCurrentCam);
            toCurrentCam /= distToCurrentCam;

            // Calc jacobians
            jacobianToCurrent = getSubpixelLocationJacobian(distToCurrentCam, toCurrentCam, prevSD.faceN, currentCamForward);
            float jacobianShifted = jacobianToCurrent / prevR.subPixelJacobian;
            const float3 bsdf = prevMi.eval(prevSD, toCurrentCam, sg);
            const float camPdf = getCameraBackprojectPDF(toCurrentCam, distToCurrentCam, currentCamForward, gNormalizedPixelArea);
            targetFunc = luminance(prevR.photonRadiance * bsdf) / camPdf;
            p2 = targetFunc * jacobianShifted * current.c;
            p2 = isnan(p2) ? 0.0f : p2;
                        
            float sum = (p1 + p2);
            if (sum > 0)
                prevMIS = p1 / sum;
            else
                prevMIS = 0.0;
        }
        float w1 = prevMIS * targetFunc * prevR.wSum;
        wSum += w1;
        // Check if other sample is selected and replace in reservoir if it was selected
        bool selectOtherSample = (sampleNext1D(sg) * wSum) < w1 && prevReservoirValid;
        if (selectOtherSample) {
            dstR = prevR;
            dstR.targetFunction = targetFunc;
            dstR.subPixelJacobian = jacobianToCurrent;
        }
        //newConfidence += prevR.c;
    }

    // Use motion vector and bilinear interpolation for new confidence weight
    
    float2 prevPixel = float2(pixel) + gMVec[pixel] * gFrameDim;
    int2 prevPixelTopLeft = int2(floor(prevPixel));
    float2 fractionalCoord = saturate(prevPixel - float2(prevPixelTopLeft));
    for (uint x = 0; x < 2; x++) {
        for (uint y = 0; y < 2; y++)
        {
            int2 prevPixel = prevPixelTopLeft + int2(x, y);
            if (any(prevPixel < 0) || any(prevPixel >= gFrameDim))
                continue;

            ReservoirCaustic prevReservoir = gCausticReservoirPrev[index2Dto1D(prevPixel, gFrameDim.x)];
            float bilinearWeight = lerp(1.0 - x, x, fractionalCoord.x) * lerp(1.0 - y, y, fractionalCoord.y);
            newConfidence += bilinearWeight * prevReservoir.c;
        }
    }

    current = dstR;
    current.c = clamp(uint(round(newConfidence)), 1, gConfidenceLimit);

    // Finalize reservoir (wSum -> W)
    if (current.targetFunction > 0)
        current.wSum = wSum / current.targetFunction;
    else
        current.wSum = 0;

    // If something went wrong, set reservoir to 0
    if (isnan(current.wSum) || isinf(current.wSum))
        current.wSum = 0;
}

[numthreads(16, 16, 1)]
void main(uint2 pixel: SV_DispatchThreadID)
{
    SampleGenerator sg = SampleGenerator(pixel, gFrameCount * 5 + 3);

    ReservoirCaustic current = gCausticReservoir[index2Dto1D(pixel, gFrameDim.x)];
    HitInfo currentHit = HitInfo(current.sampleSurface);

    //Hit background
    if (!currentHit.isValid())
        return;

    // Get Shading Data
    let lod = ExplicitLodTextureSampler(0.0);
    ShadingData currentSD = loadShadingData(currentHit, current.sampleSurfaceView, lod);
    let currentMi = gScene.materials.getMaterialInstance(currentSD, lod, kMIHints);
    let currentBsdfProperties = currentMi.getProperties(currentSD);

    // TODO handle light trace
    if (current.pathLength == 0) {
        reservoirSplatting(current, pixel, currentSD, currentMi, currentBsdfProperties, sg);
    }
    else
        resampleReservoirReflectOrRefract(current, pixel, currentSD, currentBsdfProperties, sg);

    //Store final reservoir
    gCausticReservoir[index2Dto1D(pixel, gFrameDim.x)] = current;
}
