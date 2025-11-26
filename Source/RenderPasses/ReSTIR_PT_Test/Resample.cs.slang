#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.RaytracingInline;
import Utils.Sampling.SampleGenerator;
import Utils.Color.ColorHelpers;
import Utils.Math.MathHelpers;
import SharedStructsAndFunctions;

Texture2D<PackedHitInfo> gVBuffer;
Texture2D<PackedHitInfo> gVBufferPrev;
Texture2D<float4> gView;
Texture2D<float4> gViewPrev;
Texture2D<float2> gMVec;
StructuredBuffer<ReservoirPT> gReservoirPrev;
StructuredBuffer<RetracedSurface> gRetracedSurface;
StructuredBuffer<RetracedSurface> gRetracedSurfacePrev;

RWStructuredBuffer<ReservoirPT> gReservoir;

cbuffer CB
{
    uint gFrameCount;           // Current it for sample gen
    uint2 gFrameDim;            // Frame Dimensions for camera dir
    uint gConfidenceCap;
    uint gRNGNumPass;           // Identifier for the pass used to initialize the RNG
    float gSpatialSampleRadius; // Spatial resampling radius
}

static const uint kMIHints = (uint)MaterialInstanceHints::AdjustShadingNormal;
static const uint kRNGNumPasses = RNG_NUM_PASSES;
static const float kJacobianDistanceThreshold = JACOBIAN_DISTANCE_THRESHOLD;

bool loadRetraceSurface(uint index, inout RetracedSurface retracedSurface, bool isPrev) {
    if (isPrev)
        retracedSurface = gRetracedSurfacePrev[index];
    else
        retracedSurface = gRetracedSurface[index];
    return retracedSurface.isValid();
}

float reconnectSurface(ReservoirPT r, ShadingData sdOther, ShadingData sdSampleSurface ,float3 thp, uint otherConfidence, inout SampleGenerator sg)
{
    float p0 = luminance(r.F);

    // Calc p1
    let lod = ExplicitLodTextureSampler(0);
    let miOther = gScene.materials.getMaterialInstance(sdOther, lod, kMIHints);
    let miSampleSurface = gScene.materials.getMaterialInstance(sdSampleSurface, lod, kMIHints);
    float p1 = 0;
    float3 toSample = sdSampleSurface.posW - sdOther.posW;
    float distToSample = length(toSample);
    toSample /= distToSample;
    //Jacobian to Sample
    float jacobian = dot(sdSampleSurface.getOrientedFaceNormal(), -toSample) / (distToSample * distToSample);
    jacobian *= miOther.evalPdf(sdOther, toSample);
    jacobian /= r.jacobianDeterminant;
    // Add Jacobian from sample
    if(!r.flags.isNeeAfterReconnection)
        jacobian *= miSampleSurface.evalPdf(sdSampleSurface, r.sampleWo) / r.jacobianOutgoing;

    if (jacobian > 0 && (distToSample > kJacobianDistanceThreshold)) {
        if (dispatchShadowRay(sdOther, toSample, distToSample)) {
            p1 = luminance(miOther.eval(sdOther, toSample, sg) * jacobian * r.rcThp * thp);
        }
    }

    return evalMIS(r.c, p0, otherConfidence, p1);
}

bool resampleReservoir(int2 pixel, int2 reservoirPixel, HitInfo firstHit, inout ReservoirPT reservoir, inout SampleGenerator sg)
{
    // Check if reservoir is inside the screen.
    if (any(reservoirPixel < 0) || any(reservoirPixel >= gFrameDim))
        return false;

    ReservoirPT temporal = gReservoirPrev[index2Dto1D(reservoirPixel, gFrameDim.x)];
    HitInfo temporalHit = HitInfo(gVBufferPrev[reservoirPixel]);

    if (!temporalHit.isValid())
        return false;

    //TODO add jacobian check (maybe also to retracing)

    // Needed reservoir variables
    let lod = ExplicitLodTextureSampler(0);
    float w_0, w_1 = 0;
    float wSum = 0;
    const uint retraceSurfaceIndex = index2Dto1D(pixel, gFrameDim.x);

    // Reservoir will only contribute if weight > 0 and F > 0
    bool reservoirContributes = reservoir.isValid();
    RetracedSurface retracedSurface = RetracedSurface();
    bool retracedSurfaceValid = true; //If the surface is not valid MIS is skipped
    if (reservoirContributes && reservoir.pathLength > 0)
        retracedSurfaceValid = loadRetraceSurface(retraceSurfaceIndex, retracedSurface, false);

    if (reservoirContributes) {
        //Get MIS weight
        float mis = 1.0;
        if (reservoir.flags.hasNoReconnectionSurface) {
            if (retracedSurfaceValid) {
                float3 retracedF = retracedSurface.thp * (retracedSurface.jacobianDeterminant / reservoir.jacobianDeterminant);
                mis = evalMIS(reservoir.c, luminance(reservoir.F), temporal.c, luminance(retracedF));
            }
        } else //Reconnect Surface
        {
            ShadingData sdOther = {};
            float3 thpOther = float3(1);

            // Load retraced surface
            if (reservoir.pathLength == 0) {
                sdOther = loadShadingData(temporalHit, -gViewPrev[reservoirPixel].xyz, lod);
            } else if (retracedSurfaceValid) {
                sdOther = loadShadingData(HitInfo(retracedSurface.rcSurface), retracedSurface.rcViewDir, lod);
                thpOther = retracedSurface.thp;
            }

            if (retracedSurfaceValid) {
                ShadingData sdSampleSurface = loadShadingDataWithPrevHit(HitInfo(reservoir.packedSampleSurface), sdOther.posW, lod);
                mis = reconnectSurface(reservoir, sdOther, sdSampleSurface, thpOther, temporal.c, sg);
            }
        }
        w_0 = mis * luminance(reservoir.F) * reservoir.weight;
        wSum += w_0;
    }

    //Temporal Reservoir

    float3 thpTemporal = float3(1); // only needed for path lenght == 0
    float3 Ftemporal = float3(0);
    float jacobianTemporal = 1;
    float jacobianSampleOut = 1;
    bool temporalCanBeSelected = temporal.isValid();
    //Load retraced surface for temporal reservoir
    retracedSurface = RetracedSurface();
    retracedSurfaceValid = true; // If the surface is not valid MIS is skipped
    if (temporalCanBeSelected && temporal.pathLength > 0)
        retracedSurfaceValid = loadRetraceSurface(retraceSurfaceIndex, retracedSurface, true);

    if (temporalCanBeSelected) {
        float mis = 1.0;
        float jacobianDeterminant = 1.0;
        if (temporal.flags.hasNoReconnectionSurface) {
            if (retracedSurfaceValid) {
                jacobianTemporal = retracedSurface.jacobianDeterminant;
                jacobianDeterminant = jacobianTemporal / temporal.jacobianDeterminant;
                Ftemporal = retracedSurface.thp;
            }
        } else //Reconnect surface
        {
            ShadingData sdOther = {};
            float3 thpOther = float3(1);

            // Load retraced surface
            if (reservoir.pathLength == 0) {
                sdOther = loadShadingData(firstHit, -gView[pixel].xyz, lod);
            } else if (retracedSurfaceValid) {
                sdOther = loadShadingData(HitInfo(retracedSurface.rcSurface), retracedSurface.rcViewDir, lod);
                thpOther = retracedSurface.thp;
            }

            //Reconnect
            if (retracedSurfaceValid) {
                ShadingData sdSampleSurface = loadShadingDataWithPrevHit(HitInfo(temporal.packedSampleSurface), sdOther.posW, lod);
                let miOther = gScene.materials.getMaterialInstance(sdOther, lod, kMIHints);
                let miSampleSurface = gScene.materials.getMaterialInstance(sdSampleSurface, lod, kMIHints);
                float3 toSample = sdSampleSurface.posW - sdOther.posW;
                float distToSample = length(toSample);
                toSample /= distToSample;
                //Jacobian from reconnect surface to other sample
                jacobianTemporal = miOther.evalPdf(sdOther, toSample);
                jacobianTemporal *= dot(sdSampleSurface.getOrientedFaceNormal(), -toSample) / (distToSample * distToSample);
                jacobianDeterminant = jacobianTemporal / temporal.jacobianDeterminant;
                // Jacobian from sample outgoing
                if (!temporal.flags.isNeeAfterReconnection) {
                    jacobianSampleOut = miSampleSurface.evalPdf(sdSampleSurface, temporal.sampleWo) / temporal.jacobianOutgoing;
                    jacobianDeterminant *= jacobianSampleOut;
                }

                if (jacobianDeterminant > 0 && (distToSample > kJacobianDistanceThreshold)) {
                    if (dispatchShadowRay(sdOther, toSample, distToSample)) {
                        thpTemporal *= miOther.eval(sdOther, toSample, sg);
                    } else {
                        thpTemporal = float3(0);
                    }

                    Ftemporal = temporal.rcThp * thpTemporal;
                }
            }           
        }

        float estFTemporal = luminance(Ftemporal) * jacobianDeterminant;
        mis = evalMIS(temporal.c, luminance(temporal.F), reservoir.c, estFTemporal);
        w_1 = mis * estFTemporal * temporal.weight;
        wSum += w_1;
    }

    uint cSum = min(reservoir.c + temporal.c, gConfidenceCap);
    bool selectOtherSample = (sampleNext1D(sg) * wSum) <= w_1 && temporalCanBeSelected;
    if (selectOtherSample) {
        reservoir = temporal;
        reservoir.jacobianDeterminant = jacobianTemporal;
        reservoir.jacobianOutgoing = jacobianSampleOut;
        reservoir.thp = thpTemporal;
        reservoir.F = Ftemporal;
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

    HitInfo hitInfo = HitInfo(gVBuffer[pixel]);
    ReservoirPT reservoir = ReservoirPT();
    if (hitInfo.isValid())
    {
        SampleGenerator sg = SampleGenerator(pixel, gFrameCount * kRNGNumPasses + (2 + gRNGNumPass));
        reservoir = gReservoir[index2Dto1D(pixel, gFrameDim.x)];

        // Reproject to the previous pixel using the motion vectors
        // Get pixel for the reservoir. This is either the reprojected pixel (with motion vectors) or a random sample in a disc around it.
        bool isSpatial = gRNGNumPass > 0;
        float2 motionOffset = gMVec[pixel] * float2(gFrameDim);
        float2 prevPixelF = motionOffset + float2(pixel) + float2(0.5);
        float2 u = sampleNext2D(sg);
        if (isSpatial) {
            float2 spatialOffset = gSpatialSampleRadius * sample_disk_concentric(u);
            prevPixelF += spatialOffset;
        } else // Temporal; Add subpixel offset
        {
            prevPixelF += u - 0.5; // [-0.5, 0.5]
        }
        int2 prevPixel = int2(prevPixelF);

        resampleReservoir(pixel, prevPixel, hitInfo, reservoir, sg);
    }

    gReservoir[index2Dto1D(pixel, gFrameDim.x)] = reservoir;
}
