#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.RaytracingInline;
import Utils.Sampling.SampleGenerator;
import Utils.Color.ColorHelpers;
import Utils.Math.MathHelpers;
import RenderPasses.PhotonGuiding.StructsAndHelpers;
//import RenderPasses.PhotonGuiding.SharedEnums;

cbuffer CB
{
    uint gFrameCount; // Current it for sample gen
    uint2 gFrameDim;  // Frame Dimensions
    uint gConfidenceLimit;  //Confidence Limit

    uint gSpatialSamples;                   //Number of spatial samples
    float gSpatialRadius;   //radius for spatial resampling
    float gNormalThreshold; // Normal Threshold
    float gRelativeDepthThreshold; // Relative depth threshold

    float gJacobianDistanceThreshold;   
    bool gUsePathThreshold;           // Enables and disables path threshold
    uint gNumResamplingPass;
    uint _pad;
}

Texture2D<PackedHitInfo> gVBuffer;
Texture2D<PackedHitInfo> gVBufferPrev;
Texture2D<float4> gView;
Texture2D<float4> gViewPrev;
Texture2D<float2> gMVec;
StructuredBuffer<PathReservoir> gPathReservoirPrev;
Texture2D<float4> gRetracedPath;
Texture2D<float4> gRetracedPathPrev;

RWStructuredBuffer<PathReservoir> gPathReservoir;

static const uint kRNGNumPasses = RNG_NUM_PASSES;
static const uint kMIHints = (uint)MaterialInstanceHints::AdjustShadingNormal;
static const bool kRetraceLightPaths = RETRACE_LIGHT_PATHS;

bool resampleReservoir(inout PathReservoir reservoir, PathReservoir rCurr, int2 pixel, int2 reservoirPixel, HitInfo firstHit, inout SampleGenerator sg) {

    // Check if reservoir is inside the screen.
    if (any(reservoirPixel < 0) || any(reservoirPixel >= gFrameDim))
        return false;

    HitInfo prevHit = HitInfo(gVBufferPrev[reservoirPixel]);

    if (!prevHit.isValid())
        return false;

    // Check if primary surfaces are similar (only for spatial resampling)
    let lod = ExplicitLodTextureSampler(0);
    ShadingData sdCurrent = loadShadingData(firstHit, -gView[pixel].xyz, lod);
    ShadingData sdPrev = loadShadingData(prevHit, -gViewPrev[reservoirPixel].xyz, lod);
    bool isSpatialResampling = gNumResamplingPass > 0;
    if (isSpatialResampling) {
        const float3 cameraPos = gScene.camera.getPosition();
        float currentDepth = distance(cameraPos, sdCurrent.posW);
        float temporalDepth = distance(cameraPos, sdPrev.posW);
        bool normalThreshold = abs(dot(sdCurrent.getOrientedFaceNormal(), sdPrev.getOrientedFaceNormal())) < gNormalThreshold;
        bool depthThreshold = abs(currentDepth - temporalDepth) > gRelativeDepthThreshold * currentDepth;

        if (normalThreshold || depthThreshold)
            return false;
    }

    // Needed reservoir variables
    float w_0 = 0;
    float w_1 = 0;
    float wSum = 0;

    // Load reservoir
    PathReservoir rPrev = gPathReservoirPrev[index2Dto1D(reservoirPixel, gFrameDim.x)];

    bool reservoirContributes = rCurr.isValid();
    RetracedPath retracedPath = RetracedPath();
    const bool loadRetracedPath = (RETRACE_LIGHT_PATHS > 0 && !isSpatialResampling) ? true : rCurr.pathLength > 0; //When photon retracing is used, the result for pathLength == 0 is written in the surface
    if (reservoirContributes && loadRetracedPath) {
        retracedPath = RetracedPath(gRetracedPath[pixel]);
    }

    if (reservoirContributes)
    {
        // Calc MIS weight
        float mis = 1;
        bool photonRetraceValid = true;
#if RETRACE_LIGHT_PATHS
        bool isLightPath = rCurr.flags.isFinalGather || rCurr.flags.isRadianceEstimate;
        if (!isSpatialResampling && rCurr.pathLength == 0 && isLightPath) {
            photonRetraceValid = retracedPath.jacobian > 0;                
        }
#endif
        if (rCurr.pathLength > 0 && photonRetraceValid) {
            float3 retracedF = retracedPath.F * (retracedPath.jacobian / rCurr.jacobian);
            mis = evalMIS(rCurr.c, luminance(rCurr.F), rPrev.c, luminance(retracedF));
        } else
        {
            float3 thpOther = float3(1);

            if (photonRetraceValid) {
                float p0 = luminance(rCurr.F);

                let miPrev = gScene.materials.getMaterialInstance(sdPrev, lod, kMIHints);
                float p1 = 0;
                float3 toSample = rCurr.samplePosW - sdPrev.posW;
                float distToSample = length(toSample);
                toSample /= distToSample;
                // Jacobian to Sample
                float pdf = miPrev.evalPdf(sdPrev, toSample);
                float jacobianNew = abs(dot(rCurr.sampleNormal, -toSample)) / (distToSample * distToSample);
                jacobianNew *= pdf;
                float jacobian = jacobianNew / rCurr.jacobian;

                float3 pathRadiance = float3(0);
                if (jacobian > 0 && (distToSample > gJacobianDistanceThreshold)) {
                    if (dispatchShadowRay(sdPrev, toSample, distToSample)) {
                        float3 bsdf = miPrev.eval(sdPrev, toSample, sg) / pdf;
                        pathRadiance += bsdf * jacobian * rCurr.photonFlux * thpOther;
                    }
                }

                p1 = luminance(pathRadiance);
                mis = evalMIS(rCurr.c, p0, rPrev.c, p1);
            }
        }

        w_0 = mis * luminance(rCurr.F) * rCurr.weight;
        wSum += w_0;
    }

    if (reservoirContributes && (w_0 > 0) && !isinf(w_0) && !isnan(w_0))
        reservoir = rCurr;

    // Temporal Reservoir
    float3 Fprev = float3(0);
    float jacobianPrev = 1;
    bool prevCanBeSelected = rPrev.isValid();
    prevCanBeSelected &= !isnan(rPrev.weight) && !isinf(rPrev.weight);

    // Load retraced surface for temporal reservoir
    retracedPath = RetracedPath();
    if (prevCanBeSelected && rPrev.pathLength > 0) {
        retracedPath = RetracedPath(gRetracedPathPrev[pixel]);
    }

    if (prevCanBeSelected)
    {
        float jacobianDeterminant = 1.0;
        if (rPrev.pathLength > 0) {
            jacobianPrev = retracedPath.jacobian;
            jacobianDeterminant = (jacobianPrev / rPrev.jacobian);
            Fprev = retracedPath.F;
        } else
        {
            float3 thpPrev = float3(1);
            // Reconnect
            let miCurrent = gScene.materials.getMaterialInstance(sdCurrent, lod, kMIHints);
            float3 toSample = rPrev.samplePosW - sdCurrent.posW;
            float distToSample = length(toSample);
            toSample /= distToSample;
            // Jacobian from reconnect surface to other sample
            float pdf = miCurrent.evalPdf(sdCurrent, toSample);
            jacobianPrev = abs(dot(rPrev.sampleNormal, -toSample)) / (distToSample * distToSample);
            jacobianPrev *= pdf;
            jacobianDeterminant = jacobianPrev / rPrev.jacobian;

            float3 bsdf = float3(0);
            if (jacobianDeterminant > 0 && (distToSample > gJacobianDistanceThreshold)) {
                if (dispatchShadowRay(sdCurrent, toSample, distToSample)) {
                    bsdf = miCurrent.eval(sdCurrent, toSample, sg) / pdf;
                }
                Fprev = rPrev.photonFlux * bsdf * thpPrev;
            }
        }

        float estFprev = luminance(Fprev) * jacobianDeterminant;
        float mis = evalMIS(rPrev.c, luminance(rPrev.F), rCurr.c, estFprev);
        w_1 = mis * estFprev * rPrev.weight;

        wSum += w_1;
    }

    uint cSum = min(rCurr.c + rPrev.c, gConfidenceLimit);

    bool selectOtherSample = (sampleNext1D(sg) * wSum) < w_1 && prevCanBeSelected;
    if (selectOtherSample) {
        reservoir = rPrev;
        reservoir.jacobian = jacobianPrev;
        reservoir.F = Fprev;
    }

    reservoir.weight = wSum;
    reservoir.c = cSum;

    float sampleRad = luminance(reservoir.F);
    if (reservoir.weight > 0 && sampleRad > 0)
        reservoir.weight /= sampleRad;
    else
        reservoir.weight = 0;

    return true;
}

[numthreads(16, 16, 1)]
void main(uint2 pixel: SV_DispatchThreadID)
{
    if (any(pixel >= gFrameDim))
        return;

    HitInfo hit = HitInfo(gVBuffer[pixel]);
    PathReservoir reservoir = PathReservoir();
    if (hit.isValid()) {
        let lod = ExplicitLodTextureSampler(0.f);
        SampleGenerator sgPixelOffset = SampleGenerator( pixel, gFrameCount * kRNGNumPasses + 4 + (gNumResamplingPass * 3)); // Sample generator for the pixel offset (search region) same as RetraceReservoirs
        SampleGenerator sg = SampleGenerator(pixel, gFrameCount * kRNGNumPasses + 4 + (gNumResamplingPass * 3) + 2); // Sample generator for bsdf evaluation

        PathReservoir rCurr = gPathReservoir[index2Dto1D(pixel, gFrameDim.x)];

        bool isSpatial = gNumResamplingPass > 0;
        float2 motionOffset = gMVec[pixel] * float2(gFrameDim);
        float2 prevPixelF = motionOffset + float2(pixel) + 0.5;
        float2 u = sampleNext2D(sgPixelOffset);
        if (isSpatial) {
            float2 spatialOffset = gSpatialRadius * sample_disk_concentric(u);
            prevPixelF += spatialOffset;
        } else // Temporal; Add subpixel offset
        {
            prevPixelF += u - 0.5; // [-0.5, 0.5]
        }

        int2 prevPixel = int2(prevPixelF);

        if (!resampleReservoir(reservoir, rCurr, pixel, prevPixel, hit, sg))
            reservoir = rCurr;
    }
    
    gPathReservoir[index2Dto1D(pixel, gFrameDim.x)] = reservoir;   
}
