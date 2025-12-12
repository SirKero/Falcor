#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.RaytracingInline;
import Utils.Sampling.SampleGenerator;
import Utils.Color.ColorHelpers;
import Utils.Math.MathHelpers;
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
StructuredBuffer<RetracedPath> gRetracedPath;
StructuredBuffer<RetracedPath> gRetracedPathPrev;

RWStructuredBuffer<PathReservoir> gPathReservoir;

RWTexture2D<float4> gDebug;

static const uint kRNGNumPasses = RNG_NUM_PASSES;
static const uint kMIHints = (uint)MaterialInstanceHints::AdjustShadingNormal;

/* Evaluate MIS weight
   \param[in] n0 Number of samples taken from the first sampling strategy.
    \param[in] p0 Pdf for the first sampling strategy.
    \param[in] n1 Number of samples taken from the second sampling strategy.
    \param[in] p1 Pdf for the second sampling strategy.
    \return Weight for the contribution from the first strategy (p0).
*/
float evalMIS(float n0, float p0, float n1, float p1)
{
    // Currently only balance heuristic
    float q0 = n0 * p0;
    float q1 = n1 * p1;
    float sum = (q0 + q1);
    if (sum > 0)
        return q0 / (q0 + q1);
    else
        return 0;
}

bool resampleReservoir(inout PathReservoir reservoir, PathReservoir rCurr, int2 pixel, int2 reservoirPixel, HitInfo firstHit, inout SampleGenerator sg) {

    // Check if reservoir is inside the screen.
    if (any(reservoirPixel < 0) || any(reservoirPixel >= gFrameDim))
        return false;

    HitInfo prevHit = HitInfo(gVBufferPrev[reservoirPixel]);

    if (!prevHit.isValid())
        return false;

    // Check if primary surfaces are similar (only for spatial resampling)
    let lod = ExplicitLodTextureSampler(0);
    ShadingData sdCurrent = loadShadingData(firstHit, gView[pixel].xyz, lod);
    ShadingData sdPrev = loadShadingData(prevHit, gViewPrev[reservoirPixel].xyz, lod);

    // Needed reservoir variables
    float w_0 = 0;
    float w_1 = 0;
    float wSum = 0;
    const uint retracedPathIndex = index2Dto1D(pixel, gFrameDim.x);

    // Load reservoir
    PathReservoir rPrev = gPathReservoirPrev[index2Dto1D(reservoirPixel, gFrameDim.x)];

    bool reservoirContributes = rCurr.isValid();
    RetracedPath retracedPath = RetracedPath();
    bool retracedPathValid = true; // If the path is not valid, the path was not possible and MIS weight is 1
    if (reservoirContributes && rCurr.pathLength > 0) {
        retracedPath = gRetracedPath[retracedPathIndex];
        retracedPathValid &= retracedPath.flags > 0; //A valid path has flags set
    }

    if (reservoirContributes)
    {
        //Calc MIS weight
        float mis = 1;
        if (rCurr.flags.hasNoReconnectionSurface) {
            float3 retracedF = retracedPath.F * (retracedPath.jacobian / rCurr.jacobian);
            mis = evalMIS(rCurr.c, luminance(rCurr.F), rPrev.c, luminance(retracedF));
            
        }else
        {
            float3 thpOther = float3(1);

            // Load other reconnection surface if path length > 0
            if (rCurr.pathLength > 0 && retracedPathValid) {
                sdPrev = loadShadingData(HitInfo(retracedPath.rcSurface), retracedPath.rcViewDir, lod);
                thpOther = retracedPath.rcThp;
            }

            if (retracedPathValid) {
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
                        pathRadiance += bsdf * jacobian * rCurr.fgRadiance * thpOther;
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
    retracedPathValid = true; // If the surface is not valid MIS is skipped
    if (prevCanBeSelected && rPrev.pathLength > 0) {
        retracedPath = gRetracedPathPrev[retracedPathIndex];
        retracedPathValid &= retracedPath.flags > 0; // A valid path has flags set
    }

    if (prevCanBeSelected)
    {
        float jacobianDeterminant = 1.0;
        if (rPrev.flags.hasNoReconnectionSurface) {
            if (retracedPathValid) {
                jacobianPrev = retracedPath.jacobian;
                jacobianDeterminant = (jacobianPrev / rPrev.jacobian);
                Fprev = retracedPath.F;
            }
        } else
        {
            float3 thpPrev = float3(1);
            // Load retraced surface
            if (rPrev.pathLength > 0 && retracedPathValid) {
                sdCurrent = loadShadingData(HitInfo(retracedPath.rcSurface), retracedPath.rcViewDir, lod);
                thpPrev = retracedPath.rcThp;
            }

            // Reconnect
            if (retracedPathValid) {
                let miPrev = gScene.materials.getMaterialInstance(sdCurrent, lod, kMIHints);
                float3 toSample = rPrev.samplePosW - sdCurrent.posW;
                float distToSample = length(toSample);
                toSample /= distToSample;
                // Jacobian from reconnect surface to other sample
                float pdf = miPrev.evalPdf(sdCurrent, toSample);
                jacobianPrev = abs(dot(rPrev.sampleNormal, -toSample)) / (distToSample * distToSample);
                jacobianPrev *= pdf;
                jacobianDeterminant = jacobianPrev / rPrev.jacobian;

                gDebug[pixel] = float4(jacobianPrev, rPrev.jacobian, jacobianDeterminant , 1);
  
                float3 bsdf = float3(0);
                if (jacobianDeterminant > 0 && (distToSample > gJacobianDistanceThreshold)) {
                    if (dispatchShadowRay(sdCurrent, toSample, distToSample)) {
                        bsdf = miPrev.eval(sdCurrent, toSample, sg) / pdf;
                    }
                    Fprev = rPrev.fgRadiance * bsdf * thpPrev;
                }

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
