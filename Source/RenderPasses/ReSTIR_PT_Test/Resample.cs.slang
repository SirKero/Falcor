#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.RaytracingInline;
import Utils.Sampling.SampleGenerator;
import Utils.Color.ColorHelpers;
import SharedStructsAndFunctions;

Texture2D<PackedHitInfo> gVBuffer;
Texture2D<PackedHitInfo> gVBufferPrev;
Texture2D<float4> gView;
Texture2D<float4> gViewPrev;
Texture2D<float2> gMVec;
StructuredBuffer<ReservoirPT> gReservoirPrev;

RWStructuredBuffer<ReservoirPT> gReservoir;
RWTexture2D<float4> gDebug;

cbuffer CB
{
    uint gFrameCount;           // Current it for sample gen
    uint2 gFrameDim;            // Frame Dimensions for camera dir
    uint gConfidenceCap;
}

//static const bool kUseEnvBackground = USE_ENV_BACKROUND;
static const uint kMIHints = (uint)MaterialInstanceHints::AdjustShadingNormal;
//static const float kRoughnessThreshold = ROUGHNESS_THRESHOLD;

float generalizedBalanceHeuristic(ReservoirPT r, ShadingData sdOther, IMaterialInstance miOther, uint otherConfidence, inout SampleGenerator sg)
{
    // TODO currently path lengh == 0 can be assumed, else the proxy surface needs to be loaded
    float p0 = luminance(r.F) * r.c;

    // Calc p1
    float p1 = 0;
    float3 toSample = r.samplePosW - sdOther.posW;
    float distToSample = length(toSample);
    toSample /= distToSample;
    float jacobian = dot(r.sampleFaceN, -toSample) / (distToSample * distToSample);
    jacobian /= r.jacobianDeterminant;
    if (jacobian > 0) {
        if(dispatchShadowRay(sdOther, toSample, distToSample)){
            p1 = luminance(miOther.eval(sdOther, toSample, sg) * jacobian * r.F);
        }
    }
    p1 *= otherConfidence;

    float sum = (p0 + p1);
    if (sum > 0)
        return p0 / sum;
    else
        return 0;
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

    //TODO handle hybrid (random replay)
    if (temporal.pathLength > 0 || reservoir.pathLength > 0)
        return false;

    // Needed reservoir variables
    let lod = ExplicitLodTextureSampler(0);
    float w_0, w_1 = 0;
    float wSum = 0;

    //Reservoir will onyl contribute if weight > 0
    if (reservoir.weight > 0) {
        ShadingData sdOther = loadShadingData(temporalHit, -gViewPrev[reservoirPixel].xyz, lod);
        let miOther = gScene.materials.getMaterialInstance(sdOther, lod, kMIHints);
        float mis = generalizedBalanceHeuristic(reservoir, sdOther, miOther, temporal.c,sg);
        w_0 = mis * luminance(reservoir.F * reservoir.rcThp) * reservoir.weight;
        wSum += w_0;
    }

    float3 rcThpTemporal = float3(0); // only needed for path lenght == 0
    float jacobianTemporal = 0;
    if (temporal.weight > 0) {
        ShadingData sdOther = loadShadingData(firstHit, -gView[pixel].xyz, lod);
        let miOther = gScene.materials.getMaterialInstance(sdOther, lod, kMIHints);
        float mis = generalizedBalanceHeuristic(temporal, sdOther, miOther, reservoir.c, sg);

        float3 toSample = temporal.samplePosW - sdOther.posW;
        float distToSample = length(toSample);
        toSample /= distToSample;
        jacobianTemporal = dot(temporal.sampleFaceN, -toSample) / (distToSample * distToSample);
        float jacobian = jacobianTemporal / temporal.jacobianDeterminant;
        
        if (jacobian > 0) {
            if (dispatchShadowRay(sdOther, toSample, distToSample)) {
                rcThpTemporal = miOther.eval(sdOther, toSample, sg);
            }
        }

        gDebug[pixel] = float4(rcThpTemporal, 1.0);
        w_1 = mis * luminance(temporal.F * rcThpTemporal) * temporal.weight * jacobian;
        wSum += w_1;
    }

    uint cSum = min(reservoir.c + temporal.c, gConfidenceCap);
    bool selectOtherSample = (sampleNext1D(sg) * wSum) <= w_1;
    if (selectOtherSample) {
        reservoir = temporal;
        reservoir.jacobianDeterminant = jacobianTemporal;
        reservoir.rcThp = rcThpTemporal;
        reservoir.F *= jacobianTemporal;
    }

    reservoir.weight = wSum;
    reservoir.c = cSum;

    float sampleRad = luminance(reservoir.F * reservoir.rcThp);
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
        SampleGenerator sg = SampleGenerator(pixel, gFrameCount * 5 + 4);
        reservoir = gReservoir[index2Dto1D(pixel, gFrameDim.x)];

        //
        // Temporal Resampling
        //

        // Reproject to the previous pixel using the motion vectors
        float2 motionOffset = gMVec[pixel] * float2(gFrameDim);
        float2 prevPixelF = motionOffset + float2(pixel) + float2(0.5);
        float2 rndOffset = sampleNext2D(sg) - 0.5;
        prevPixelF += rndOffset;
        int2 prevPixel = int2(prevPixelF);

        resampleReservoir(pixel, prevPixel, hitInfo, reservoir, sg);
    }

    gReservoir[index2Dto1D(pixel, gFrameDim.x)] = reservoir;
}
