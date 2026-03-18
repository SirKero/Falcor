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
Texture2D<float4> gRetraceRCPathThp;
Texture2D<float4> gRetraceRCPathThpPrev;

RWStructuredBuffer<ReservoirPT> gReservoir;

RWTexture2D<float4> gDebug;

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
static const bool kRetraceRCPath = RETRACE_RC_PATH;

bool loadRetraceSurface(uint index, inout RetracedSurface retracedSurface, bool isPrev) {
    if (isPrev)
        retracedSurface = gRetracedSurfacePrev[index];
    else
        retracedSurface = gRetracedSurface[index];
    return retracedSurface.isValid();
}

float reconnectSurface(ReservoirPT r, ShadingData sdOther, ShadingData sdSampleSurface ,float3 thp, float3 rcThp, uint otherConfidence, inout SampleGenerator sg)
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
    // Jacobian to Sample
    float pdf = miOther.evalPdf(sdOther, toSample);
    float jacobianNew = abs(dot(sdSampleSurface.faceN, -toSample)) / (distToSample * distToSample);
    jacobianNew *= pdf;
    float jacobian = jacobianNew / r.jacobianDeterminant;
    // Add Jacobian from sample
    
    if (!r.flags.isNeeAfterReconnection) {
        float samplePdf = miSampleSurface.evalPdf(sdSampleSurface, r.sampleWo);
        float jacobianOut = samplePdf / r.jacobianOutgoing;
        jacobian *= jacobianOut;
    }

    if (jacobian > 0 && (distToSample > kJacobianDistanceThreshold)) {
        if (dispatchShadowRay(sdOther, toSample, distToSample)) {
            float3 bsdf = miOther.eval(sdOther, toSample, sg) / pdf;
            p1 = luminance(bsdf * jacobian * rcThp * thp);
        }
    }

    return evalMIS(r.c, p0, otherConfidence, p1);
}

bool resampleReservoir(inout ReservoirPT current, int2 pixel, int2 reservoirPixel, HitInfo firstHit, inout SampleGenerator sg)
{
    // Check if reservoir is inside the screen.
    if (any(reservoirPixel < 0) || any(reservoirPixel >= gFrameDim))
        return false;

    ReservoirPT temporal = gReservoirPrev[index2Dto1D(reservoirPixel, gFrameDim.x)];
    HitInfo temporalHit = HitInfo(gVBufferPrev[reservoirPixel]);
     
    if (!temporalHit.isValid())
        return false;

    if (current.flags.firstHitIsDelta != temporal.flags.firstHitIsDelta)
        return false;

    // Check if reservoir start surface and other surface are similar
    let lod = ExplicitLodTextureSampler(0);
    ShadingData sdCurrent = loadShadingData(firstHit, -gView[pixel].xyz, lod);
    ShadingData sdTemporal = loadShadingData(temporalHit, -gViewPrev[reservoirPixel].xyz, lod);
    // For spatial resampling check if surfaces are similar
    bool isSpatialResampling = gRNGNumPass > 0;
    if (isSpatialResampling) {
        const float3 cameraPos = gScene.camera.getPosition();
        float currentDepth = distance(cameraPos, sdCurrent.posW);
        float temporalDepth = distance(cameraPos, sdTemporal.posW);
        bool normalThreshold = abs(dot(sdCurrent.getOrientedFaceNormal(), sdTemporal.getOrientedFaceNormal())) < 0.5; // TODO do not hardcode this
        bool depthThreshold = abs(currentDepth - temporalDepth) > 0.1 * currentDepth;

        if (normalThreshold || depthThreshold)
            return false;
    }
    
    // Needed reservoir variables

    float w_0 = 0;
    float w_1 = 0;
    float wSum = 0;
    const uint retraceSurfaceIndex = index2Dto1D(pixel, gFrameDim.x);

    // Reservoir will only contribute if weight > 0 and F > 0
    bool reservoirContributes = current.isValid();
    RetracedSurface retracedSurface = RetracedSurface();
    bool retracedSurfaceValid = true; // If the surface is not valid MIS is skipped
    if (reservoirContributes && current.rcPathLength != 1)
        retracedSurfaceValid = loadRetraceSurface(retraceSurfaceIndex, retracedSurface, false);

    if (reservoirContributes) {
        //Get MIS weight
        float mis = 1.0;
        if (current.flags.hasNoReconnectionSurface) {
            if (retracedSurfaceValid) {
                float3 retracedF = retracedSurface.thp * (retracedSurface.jacobianDeterminant / current.jacobianDeterminant);
                mis = evalMIS(current.c, luminance(current.F), temporal.c, luminance(retracedF));
            }
        } else //Reconnect Surface
        {
            float3 thpOther = float3(1);
            float3 rcThp = current.rcThp;
            if (kRetraceRCPath)
                rcThp = gRetraceRCPathThp[pixel].xyz;


            // Load retraced surface
            if (current.rcPathLength != 1 && retracedSurfaceValid) {
                sdTemporal = loadShadingData(HitInfo(retracedSurface.rcSurface), -retracedSurface.rcViewDir, lod);
                thpOther = retracedSurface.thp;
            }

            if (retracedSurfaceValid) {
                ShadingData sdSampleSurface = loadShadingDataWithPrevHit(HitInfo(current.packedSampleSurface), sdTemporal.posW, lod);
                mis = reconnectSurface(current, sdTemporal, sdSampleSurface, thpOther, rcThp, temporal.c, sg);
            }
        }

        w_0 = mis * luminance(current.F) * current.weight;
        wSum += w_0;
    }


    //Temporal Reservoir

    float3 thpTemporal = float3(1); // only needed for path lenght == 0
    float3 Ftemporal = float3(0);
    float jacobianTemporal = 1;
    float jacobianSampleOut = 1;
    bool temporalCanBeSelected = temporal.isValid();
    temporalCanBeSelected &= !isnan(temporal.weight) && !isinf(temporal.weight);
    //Load retraced surface for temporal reservoir
    retracedSurface = RetracedSurface();
    retracedSurfaceValid = true; // If the surface is not valid MIS is skipped
    if (temporalCanBeSelected && temporal.rcPathLength != 1)
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
            float3 thpOther = float3(1);
            float3 rcThp = temporal.rcThp;
            if (kRetraceRCPath)
                rcThp = gRetraceRCPathThpPrev[pixel].xyz;

            // Load retraced surface
            if (temporal.rcPathLength != 1 && retracedSurfaceValid) {
                sdCurrent = loadShadingData(HitInfo(retracedSurface.rcSurface), -retracedSurface.rcViewDir, lod);
                thpOther = retracedSurface.thp;
            }

            //Reconnect
            if (retracedSurfaceValid) {
                ShadingData sdSampleSurface = loadShadingDataWithPrevHit(HitInfo(temporal.packedSampleSurface), sdCurrent.posW, lod);
                let miOther = gScene.materials.getMaterialInstance(sdCurrent, lod, kMIHints);
                let miSampleSurface = gScene.materials.getMaterialInstance(sdSampleSurface, lod, kMIHints);
                float3 toSample = sdSampleSurface.posW - sdCurrent.posW;
                float distToSample = length(toSample);
                toSample /= distToSample;
                // Jacobian from reconnect surface to other sample
                float pdf = miOther.evalPdf(sdCurrent, toSample);
                jacobianTemporal = pdf;
                jacobianTemporal *= abs(dot(sdSampleSurface.faceN, -toSample)) / (distToSample * distToSample);
                jacobianDeterminant = jacobianTemporal / temporal.jacobianDeterminant;

                // Jacobian from sample outgoing
                if (!temporal.flags.isNeeAfterReconnection) {
                    jacobianSampleOut = miSampleSurface.evalPdf(sdSampleSurface, temporal.sampleWo);
                    jacobianDeterminant *= jacobianSampleOut / temporal.jacobianOutgoing;
                }

                if (jacobianDeterminant > 0 && (distToSample > kJacobianDistanceThreshold)) {
                    if (dispatchShadowRay(sdCurrent, toSample, distToSample)) {
                        thpTemporal *= miOther.eval(sdCurrent, toSample, sg) / pdf;
                    } else {
                        thpTemporal = float3(0);
                    }
                    Ftemporal = rcThp * thpTemporal * thpOther;
                }
            }
        }

        float estFTemporal = luminance(Ftemporal) * jacobianDeterminant;
        mis = evalMIS(temporal.c, luminance(temporal.F), current.c, estFTemporal);
        w_1 = mis * estFTemporal * temporal.weight;

       
        wSum += w_1;
    }

    uint cSum = min(current.c + temporal.c, gConfidenceCap);

    bool selectOtherSample = (sampleNext1D(sg) * wSum) < w_1 && temporalCanBeSelected;
    if (selectOtherSample) {
        current = temporal;
        current.jacobianDeterminant = jacobianTemporal;
        current.jacobianOutgoing = jacobianSampleOut;
        current.thp = thpTemporal;
        current.F = Ftemporal;
    }

    current.weight = wSum;
    current.c = cSum;

    float sampleRad = luminance(current.F);
    if (current.weight > 0 && sampleRad > 0)
        current.weight /= sampleRad;
    else
        current.weight = 0;

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

        ReservoirPT resampledR = ReservoirPT();
        resampledR.c = 0;
        bool valid = resampleReservoir(reservoir, pixel, prevPixel, hitInfo, sg);
    }

    gReservoir[index2Dto1D(pixel, gFrameDim.x)] = reservoir;
}
