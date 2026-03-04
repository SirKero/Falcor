#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.RaytracingInline;
import Utils.Sampling.SampleGenerator;
import Utils.Color.ColorHelpers;
import Utils.Math.MathHelpers;
import RenderPasses.PhotonGuiding.StructsAndHelpers;

cbuffer CB
{
    uint gFrameCount; // Current it for sample gen
    uint2 gFrameDim;  // Frame Dimensions
    uint gConfidenceLimit;  //Confidence Limit

    uint gSpatialSamples;                   //Number of spatial samples
    uint gDisocclusionBoostSpatialSamples;  //How many extra spatial samples if temporal resampling fails
    float gSpatialRadius;   //radius for spatial resampling
    float gNormalThreshold; // Normal Threshold

    float2 gPhotonRadius;           // Global / Caustic fixed radius
    float2 gAdaptivePhotonRadius;   // Pixel scale for global/ caustic photons.

    float gNormalizedPixelDiagonal; // Pixel length at distance 1
    float3 gPrevCamPos;             // Previous camera position for splatting

    float4x4 gPrevCamViewProjection; // Previous Camera view projection for splatting

    float3 gPrevCamForward; // Previous camera forward for splatting
    float gNormalizedPixelArea;
}

Texture2D<float2> gMVec;
StructuredBuffer<ReservoirCaustic> gCausticReservoirPrev;

RWStructuredBuffer<ReservoirCaustic> gCausticReservoir;

// Splatting
RWStructuredBuffer<int> gCellCounters;      // Number of reservoirs per pixel
StructuredBuffer<int> gSplattingLinkedList;  //Linked List, gCell counters is the head buffer if the linked list is used
StructuredBuffer<uint> gCellOffsets;       // Initial offset for the sorted reservoir buffer
StructuredBuffer<uint2> gSortedReservoirs; // Buffer of splatted reservoirs

static const uint kMIHints = (uint)MaterialInstanceHints::AdjustShadingNormal;
static const bool kUseAdaptivePhotonRadius = USE_ADAPTIVE_PHOTON_RADIUS;
static const bool kEnableLightTraceSplatting = ENABLE_LIGHT_TRACE_SPATTING;
static const uint kRNGNumPasses = RNG_NUM_PASSES;
static const bool kUseBackupSample = USE_BACKUP_SAMPLE; // Caustic backup sample with motion vector if no other sample was found
static const bool kSplattingUseLinkedList = SPLATTING_USE_LINKED_LIST;

inline float getPhotonRadius(ReservoirCaustic r, bool isPrev = false)
{
    uint photonTypeIndex = r.pathLength == 0 ? 1 : 0; // Caustic : Global
    float3 cameraPos = isPrev ? gPrevCamPos : gScene.camera.getPosition();
    if (kUseAdaptivePhotonRadius) {

        float distToCamera = distance(r.photonPosW, cameraPos);
        return adaptiveRadius(distToCamera, gNormalizedPixelDiagonal, gAdaptivePhotonRadius[photonTypeIndex]);
    }
    else {
        return gPhotonRadius[photonTypeIndex];
    }
}

inline float evalMISBalanceHeuristic(float p0, float p1) {
    float sum = (p0 + p1);
    if (sum > 0)
        return p0 / sum;
    else
        return 0;
}

// Generalized Balance Heuristic with two samples
float generalizedBalanceHeuristic(ReservoirCaustic r, ShadingData otherSD, BSDFProperties otherProps, uint otherC, bool otherIsPrev) {
    float p0 = r.targetFunction * r.c;
    float p1 = 0;
    if (length(otherSD.posW - r.photonPosW) < getPhotonRadius(r, otherIsPrev))
        p1 = evalApproximateBRDFPhoton(otherSD, otherProps, r.photonDir) * luminance(r.photonRadiance) * otherC;

    return evalMISBalanceHeuristic(p0, p1);
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
        float mis = generalizedBalanceHeuristic(current, otherSD, otherProps, other.c, true);
        w_0 = mis * current.targetFunction * current.wSum;
        wSum += w_0;
    }

    //Calculate ReSTIR weight for other reservoir sample
    float targetFunctionOther = 0.0;
    bool otherReservoirValid = other.isValid();
    if (otherReservoirValid) {
        // Check if sample is part of the domain
        if (length(currentSD.posW - other.photonPosW) < getPhotonRadius(other)) {
            float mis = generalizedBalanceHeuristic(other, currentSD, currentProps, current.c, false);
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
        current.guidingPixels = other.guidingPixels;
        current.lightIndex = other.lightIndex;
    }

    // Increase confidence weights
    uint newC = min(current.c + other.c, 20);
    current.c = newC;

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

void resampleReservoirRadianceEstimate(inout ReservoirCaustic current, uint2 pixel, inout SampleGenerator sg)
{
    HitInfo currentHit = HitInfo(current.sampleSurface);
    if (!currentHit.isValid()) {
        current = ReservoirCaustic();
        return;
    }

    //Get Material Info
    let lod = ExplicitLodTextureSampler(0.0);

    ShadingData currentSD = loadShadingData(currentHit, current.sampleSurfaceView, lod);
    let currentMi = gScene.materials.getMaterialInstance(currentSD, lod, kMIHints);
    let currentBsdfProperties = currentMi.getProperties(currentSD);

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

float getSplattingMISWeight(float3 toCam, float distToCam, float3 camForward, ReservoirCaustic r, ShadingData sd, IMaterialInstance mi, inout SampleGenerator sg, out float jacobianWeight, out float targetFunction)
{
    jacobianWeight = getSubpixelLocationJacobian(distToCam, toCam, sd.faceN, camForward);
    float jacobianShifted = jacobianWeight / r.subPixelJacobian;
    const float3 bsdf = mi.eval(sd, toCam, sg);
    targetFunction = luminance(r.photonRadiance * bsdf);
    float misP = targetFunction * jacobianShifted;
    misP = isnan(misP) ? 0.0f : misP;
    return misP;
}

void resampleSplattedReservoir(inout ReservoirCaustic dstR, inout float wSum, inout SampleGenerator sg, uint reservoirIndex, uint currentConfidence, float3 currentCamPosW, float3 currentCamForward)
{
    ReservoirCaustic prevR = gCausticReservoirPrev[reservoirIndex];
    float prevMIS = 0.0;
    float targetFunc = 0.0;
    float jacobianToCurrent = 0.0;
    bool prevReservoirValid = prevR.isValid();

    if (prevReservoirValid)
    {
        let lod = ExplicitLodTextureSampler(0.0);
        // Load surface data
        ShadingData prevSD = loadShadingData(HitInfo(prevR.sampleSurface), prevR.sampleSurfaceView, lod);

        // MIS weight for current (Visibility was already tested in a previous pass)
        float3 toCurrentCam = currentCamPosW - prevSD.posW;
        float distToCurrentCam = length(toCurrentCam);
        toCurrentCam /= distToCurrentCam;

        float p0 = prevR.targetFunction * prevR.c;
        float p1 = 0.0;

        let prevMi = gScene.materials.getMaterialInstance(prevSD, lod, kMIHints);
        // Calc jacobians
        p1 = getSplattingMISWeight(toCurrentCam, distToCurrentCam, currentCamForward, prevR, prevSD, prevMi, sg, jacobianToCurrent, targetFunc);
        p1 *= currentConfidence;
        prevMIS = evalMISBalanceHeuristic(p0, p1);
    }
    float jacobianShift = jacobianToCurrent / prevR.subPixelJacobian;
    float w1 = prevMIS * targetFunc * prevR.wSum * jacobianShift;
    wSum += w1;
    // Check if other sample is selected and replace in reservoir if it was selected
    bool selectOtherSample = (sampleNext1D(sg) * wSum) < w1 && prevReservoirValid;
    if (selectOtherSample) {
        dstR = prevR;
        dstR.targetFunction = targetFunc;
        dstR.subPixelJacobian = jacobianToCurrent;
    }
}

void reservoirSplatting(inout ReservoirCaustic current, uint2 pixel, inout SampleGenerator sg)
{
    float currentMIS = 0.0;
    ReservoirCaustic dstR = ReservoirCaustic();
    dstR.c = 0;
    let lod = ExplicitLodTextureSampler(0.0);
    // MIS for current reservoir
    if (current.isValid())
    {
        dstR = current;
        float p1 = 0.0;
        float p0 = current.targetFunction * current.c;
        HitInfo currentHit = HitInfo(current.sampleSurface);
        ShadingData currentSD = loadShadingData(currentHit, current.sampleSurfaceView, lod);
        
        // Get mis for temporal reprojection
        float3 toPrevCam = gPrevCamPos - currentSD.posW;
        float distToPrevCam = length(toPrevCam);
        toPrevCam /= distToPrevCam;

        // Visibility ray and camera view
        float3 prevScreenPos = getCameraProjection(gPrevCamViewProjection, currentSD.posW);
        bool isVisible = (all(prevScreenPos.xyz >= 0) && all(prevScreenPos.xyz < 1));

        if (isVisible)
        {
            float visRayDist = distToPrevCam - gScene.camera.data.nearZ; // Remove near
            SceneRayQuery<1> rayQuery;
            const Ray ray = Ray(currentSD.computeNewRayOrigin(), toPrevCam, 0.0, visRayDist);
            isVisible &= rayQuery.traceVisibilityRay(ray, RAY_FLAG_NONE, 0xff);
        }

        if (isVisible) {
            let currentMi = gScene.materials.getMaterialInstance(currentSD, lod, kMIHints);
            // Calc jacobians
            float jacobianWeight, targetFunction;
            p1 = getSplattingMISWeight(toPrevCam, distToPrevCam, gPrevCamForward, current, currentSD, currentMi, sg, jacobianWeight, targetFunction);
            // get confidence weight from backprojection
            uint2 prevPixel = uint2(floor(prevScreenPos.xy * gFrameDim));
            ReservoirCaustic prevR = gCausticReservoirPrev[index2Dto1D(prevPixel, gFrameDim.x)];
            p1 *= prevR.c;
        }
        currentMIS = evalMISBalanceHeuristic(p0, p1);
    }
    float w0 = currentMIS * current.targetFunction * current.wSum;
    float wSum = w0;

    // Shift the other samples
    uint reservoirIdx = index2Dto1D(pixel, gFrameDim.x);
  
    const float3 currentCamPosW = gScene.camera.getPosition();
    const float3 currentCamForward = normalize(gScene.camera.data.cameraW);
    float newConfidence = current.c;

    if (kSplattingUseLinkedList) {
        int headIndex = gCellCounters[reservoirIdx];
        while (headIndex >= 0)
        {
            resampleSplattedReservoir(dstR, wSum, sg, uint(headIndex), current.c, currentCamPosW, currentCamForward);
            int newHeadIndex = gSplattingLinkedList[headIndex];
            headIndex = newHeadIndex;
        }
    }
    else {
        uint numReservoirs = gCellCounters[reservoirIdx];
        uint cellOffset = gCellOffsets[reservoirIdx];
        for (uint i = 0; i < numReservoirs; i++)
        {
            uint2 splattedPixel = gSortedReservoirs[cellOffset + i];
            resampleSplattedReservoir(dstR, wSum, sg, index2Dto1D(splattedPixel, gFrameDim.x), current.c, currentCamPosW, currentCamForward);
        }
    }

    /*
    bool isBackupSample = kUseBackupSample && numReservoirs == 0;
    if (isBackupSample)
        numReservoirs = max(1, numReservoirs);

    for (uint i = 0; i < numReservoirs; i++)
    {
        uint2 splattedPixel;
        if (isBackupSample)
            splattedPixel = float2(pixel) + 0.5 + gMVec[pixel] * gFrameDim;
        else
            splattedPixel = gSortedReservoirs[cellOffset + i];
        ReservoirCaustic prevR = gCausticReservoirPrev[index2Dto1D(splattedPixel, gFrameDim.x)];
        float prevMIS = 0.0;
        float targetFunc = 0.0;
        float jacobianToCurrent = 0.0;
        bool prevReservoirValid = prevR.isValid();
        
        if (prevReservoirValid)
        {
            // Load surface data
            ShadingData prevSD = loadShadingData(HitInfo(prevR.sampleSurface), prevR.sampleSurfaceView, lod);

            // MIS weight for current (Visibility was already tested in a previous pass)
            float3 toCurrentCam = currentCamPosW - prevSD.posW;
            float distToCurrentCam = length(toCurrentCam);
            toCurrentCam /= distToCurrentCam;

            // Perform visibility for backup reservoir check
            if (isBackupSample) {
                float4 backupScreenPos = mul(gScene.camera.data.viewProjMatNoJitter, float4(prevSD.posW, 1));
                backupScreenPos /= backupScreenPos.w;
                backupScreenPos.y *= -1;
                backupScreenPos.xy = backupScreenPos.xy * 0.5 + 0.5; // UV from [-1,1] to [0,1]
                int2 backupPixelPos = int2(floor(backupScreenPos.xy * gFrameDim));
                backupPixelPos = abs(backupPixelPos - int2(pixel));
                // Check if the position is outside of the screen or too far away from the current pixel
                if (any(backupScreenPos.xy < 0) || any(backupScreenPos.xy >= 1) || backupScreenPos.z < 0 || backupScreenPos.z > 1 || any(backupPixelPos > 1))
                    break;

                // Visibility test (from point to camera)
                SceneRayQuery<1> rayQuery;
                const Ray ray = Ray(prevSD.computeNewRayOrigin(), toCurrentCam, 0.f, distToCurrentCam);
                if (!rayQuery.traceVisibilityRay(ray, RAY_FLAG_NONE, 0xff))
                    break;
            }

            float p0 = prevR.targetFunction * prevR.c;
            float p1 = 0.0;

            let prevMi = gScene.materials.getMaterialInstance(prevSD, lod, kMIHints);
            // Calc jacobians
            p1 = getSplattingMISWeight(toCurrentCam, distToCurrentCam, currentCamForward, prevR, prevSD, prevMi, sg, jacobianToCurrent, targetFunc);
            p1 *= current.c;
            prevMIS = evalMISBalanceHeuristic(p0, p1);
        }
        float jacobianShift = jacobianToCurrent / prevR.subPixelJacobian;
        float w1 = prevMIS * targetFunc * prevR.wSum * jacobianShift;
        wSum += w1;
        // Check if other sample is selected and replace in reservoir if it was selected
        bool selectOtherSample = (sampleNext1D(sg) * wSum) < w1 && prevReservoirValid;
        if (selectOtherSample) {
            dstR = prevR;
            dstR.targetFunction = targetFunc;
            dstR.subPixelJacobian = jacobianToCurrent;
        }
        // newConfidence += prevR.c;
    }
    */

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
            // Exclude non contributing reservoirs
            if (prevReservoir.pathLength > 0)
                continue;
            float bilinearWeight = lerp(1.0 - x, x, fractionalCoord.x) * lerp(1.0 - y, y, fractionalCoord.y);
            newConfidence += bilinearWeight * prevReservoir.c;
        }
    }

    current = dstR;
    newConfidence = clamp(uint(round(newConfidence)), 1, gConfidenceLimit);
    current.c = newConfidence;

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
    SampleGenerator sg = SampleGenerator(pixel, gFrameCount * kRNGNumPasses + (kRNGNumPasses - 2));

    const uint reservoirIdx = index2Dto1D(pixel, gFrameDim.x);
    
    ReservoirCaustic current = gCausticReservoir[reservoirIdx];

    if (kEnableLightTraceSplatting && current.pathLength == 0)
        reservoirSplatting(current, pixel, sg);
    else
        resampleReservoirRadianceEstimate(current, pixel, sg);

    gCausticReservoir[reservoirIdx] = current;

    if (kSplattingUseLinkedList)
        gCellCounters[reservoirIdx] = -1;
    else
        gCellCounters[reservoirIdx] = 0;
}
