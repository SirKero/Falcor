#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.RaytracingInline;
import Utils.Sampling.SampleGenerator;
import Utils.Color.ColorHelpers;
import Utils.Math.MathHelpers;
import StructsAndHelpers;

cbuffer CB
{
    uint gFrameCount;                   // Current iteration for sample gen
    uint2 gFrameDim;                    // Frame Dimensions
    uint gConfidenceCap;                //Confidence Cap

    float gSpatialRadius;               // Radius for spatial resampling
    float gNormalThreshold;             // Normal angle threshold
    float gJacobianDistanceThreshold;   // Jacobian distance threshold
    float gRelativeDepthThreshold;      // Relative depth treshold

    uint gNumResamplingPass;            // Resampling iteration. == 0 -> Temporal, else Spatial
}

//Inputs
Texture2D<PackedHitInfo> gVBuffer;
Texture2D<PackedHitInfo> gVBufferPrev;
Texture2D<float4> gView;
Texture2D<float4> gViewPrev;
Texture2D<float2> gMVec;
StructuredBuffer<PathReservoir> gPathReservoirOther;
Texture2D<float4> gShiftData;
Texture2D<float4> gShiftDataOther;

//Outputs
RWStructuredBuffer<PathReservoir> gPathReservoir;

static const uint kRNGNumPasses = RNG_NUM_PASSES;
static const uint kMIHints = (uint)MaterialInstanceHints::AdjustShadingNormal;

bool resampleReservoir(inout PathReservoir reservoir, PathReservoir rCurr, PathReservoir rOther, int2 pixel, ShadingData sdCurr, ShadingData sdOther, inout SampleGenerator sg) {

    // For spatial resampling, check if surfaces are similar
    const bool isSpatialResampling = gNumResamplingPass > 0;
    if (isSpatialResampling) {
        const float3 cameraPos = gScene.camera.getPosition();
        float currentDepth = distance(cameraPos, sdCurr.posW);
        float temporalDepth = distance(cameraPos, sdOther.posW);
        bool normalThreshold = abs(dot(sdCurr.getOrientedFaceNormal(), sdOther.getOrientedFaceNormal())) < gNormalThreshold;
        bool depthThreshold = abs(currentDepth - temporalDepth) > gRelativeDepthThreshold * currentDepth;

        if (normalThreshold || depthThreshold)
            return false;
    }

    // Init needed reservoir variables
    float w_0 = 0;
    float w_1 = 0;
    float wSum = 0;

    // Get w for current reservoir. This involves calculating the correct MIS weight with the shifted reservoir sample.
    bool reservoirContributes = rCurr.isValid();
    if (reservoirContributes)
    {
        //Calc MIS weight
        float mis = 1;
        // For path >0, shift is already calculated
        if (rCurr.pathLength > 0) {
            float4 shiftData = gShiftData[pixel]; // xyz = F, w = jacobian
            if (shiftData.w > 0) {
                float3 shiftedF = shiftData.xyz * (shiftData.w / rCurr.jacobian);
                mis = evalMIS(rCurr.c, luminance(rCurr.F), rOther.c, luminance(shiftedF));
            }
        }
        else //Reconnection for path lenght == 0
        {
            //Get Material Instance for the surface of the other reservoir
            let lod = ExplicitLodTextureSampler(0.f);
            let mi = gScene.materials.getMaterialInstance(sdOther, lod, kMIHints);

            // Calculate new jacobian
            float3 toSample = rCurr.samplePosW - sdOther.posW;
            float distToSample = length(toSample);
            toSample /= distToSample;
            float pdf = mi.evalPdf(sdOther, toSample);
            float jacobianNew = abs(dot(rCurr.sampleNormal, -toSample)) / (distToSample * distToSample);
            jacobianNew *= pdf;

            float jacobian = jacobianNew / rCurr.jacobian;
            float3 F = float3(0);

            //BSDF and Visibility test
            if (jacobian > 0 && (distToSample > gJacobianDistanceThreshold)) {
                if (dispatchShadowRay(sdOther, toSample, distToSample)) {
                    float3 bsdf = mi.eval(sdOther, toSample, sg) / pdf;
                    F += bsdf * jacobian * rCurr.fgRadiance;
                }
            }

            //Calc MIS weight
            mis = evalMIS(rCurr.c, luminance(rCurr.F), rOther.c, luminance(F));
        }

        //New w_0
        w_0 = mis * luminance(rCurr.F) * rCurr.weight;
        wSum += w_0;
    }

    if (w_0 > 0)
        reservoir = rCurr;

    //Calculate w for the resampled reservoir. Requires shifting the reservoir to current sample space
    float3 Fother = float3(0);
    float jacobianOther = 1;
    bool otherCanBeSelected = rOther.isValid();
    otherCanBeSelected &= !isnan(rOther.weight) && !isinf(rOther.weight);
    if (otherCanBeSelected)
    {
        float jacobian = 0.0;
        // For path >0, shift is already calculated
        if (rOther.pathLength > 0) {
            float4 shiftData = gShiftDataOther[pixel]; // xyz = F, w = jacobian

            if (shiftData.w > 0)
            {
                jacobianOther = shiftData.w;
                jacobian = jacobianOther / rOther.jacobian;
                Fother = shiftData.xyz;
            }
        }
        else // Reconnection for path lenght == 0
        {
            // Get Material Instance for current surface
            let lod = ExplicitLodTextureSampler(0.f);
            let mi = gScene.materials.getMaterialInstance(sdCurr, lod, kMIHints);

            // Calculate new jacobian
            float3 toSample = rOther.samplePosW - sdCurr.posW;
            float distToSample = length(toSample);
            toSample /= distToSample;
            float pdf = mi.evalPdf(sdCurr, toSample);
            jacobianOther = abs(dot(rOther.sampleNormal, -toSample)) / (distToSample * distToSample);
            jacobianOther *= pdf;
            jacobian = jacobianOther / rOther.jacobian;

            // BSDF and Visibility test
            if (jacobian > 0 && (distToSample > gJacobianDistanceThreshold)) {
                if (dispatchShadowRay(sdCurr, toSample, distToSample)) {
                    float3 bsdf = mi.eval(sdCurr, toSample, sg) / pdf;
                    Fother = rOther.fgRadiance * bsdf;
                }
            }            
        }
        float estFprev = luminance(Fother) * jacobian;
        float mis = evalMIS(rOther.c, luminance(rOther.F), rCurr.c, estFprev);
        w_1 = mis * estFprev * rOther.weight;

        wSum += w_1;
    }

    uint cSum = min(rCurr.c + rOther.c, gConfidenceCap);
    
    //Randomly select new reservoir depending on relative weight
    bool selectOtherSample = (sampleNext1D(sg) * wSum) < w_1 && otherCanBeSelected;
    if (selectOtherSample) {
        reservoir = rOther;
        reservoir.jacobian = jacobianOther;
        reservoir.F = Fother;
    }


    //Update c and weight
    reservoir.weight = wSum;
    reservoir.c = cSum;

    //Finalize Reservoir
    float sampleRadiance = luminance(reservoir.F);
    if (reservoir.weight > 0 && sampleRadiance > 0)
        reservoir.weight /= sampleRadiance;
    else
        reservoir.weight = 0;

    return true;
}

[numthreads(16, 16, 1)]
void main(uint2 pixel: SV_DispatchThreadID)
{
    if (any(pixel >= gFrameDim))
        return;

    //Get current pixels hit and initialize reservoir
    HitInfo hit = HitInfo(gVBuffer[pixel]);
    PathReservoir reservoir = PathReservoir();

    //If hit is valid, perform resampling
    if (hit.isValid()) {
        let lod = ExplicitLodTextureSampler(0.f);

        // Sample generator for the pixel offset (search region). Is the same as for the shift in the other shader (TraceCamera.slang)
        SampleGenerator sgPixelOffset = SampleGenerator(pixel, gFrameCount * kRNGNumPasses + 5 + (gNumResamplingPass * 3));
        // Sample generator for bsdf evaluation
        SampleGenerator sg = SampleGenerator(pixel, gFrameCount * kRNGNumPasses + 7 + (gNumResamplingPass * 3));

        //Determine pixel for other reservoir       
        bool isSpatial = gNumResamplingPass > 0;
        float2 otherPixelF = float2(pixel) + 0.5;
        //Add motion vectors for temporal resampling
        if (!isSpatial)
        {
            float2 motionOffset = gMVec[pixel] * float2(gFrameDim);
            otherPixelF += motionOffset;
        }
        float2 u = sampleNext2D(sgPixelOffset);
        if (isSpatial) // Spatial, sample in disc around current pixel
        {
            float2 spatialOffset = gSpatialRadius * sample_disk_concentric(u);
            otherPixelF += spatialOffset;
        } else // Temporal, add subpixel offset
        {
            otherPixelF += u - 0.5; // [-0.5, 0.5]
        }
        int2 otherPixel = int2(otherPixelF);

        //Check if reservoir is in screen
        bool resamplingValid = any(otherPixel >= 0) || any(otherPixel < gFrameDim);
        //Load Shading Data of other reservoir
        ShadingData sdOther;
        if (resamplingValid) {
            HitInfo hitOther;
            float3 viewOther;
            if (isSpatial)
            {
                hitOther = HitInfo(gVBuffer[otherPixel]);
                viewOther = gView[otherPixel].xyz;
            }
            else
            {
                hitOther = HitInfo(gVBufferPrev[otherPixel]);
                viewOther = gViewPrev[otherPixel].xyz;
            }

            if (hitOther.isValid())
                sdOther = loadShadingData(hitOther, viewOther, lod);
            else
                resamplingValid = false;
        }

        // Load current reservoir and begin resampling
        PathReservoir rCurr;
        if (isSpatial)
            rCurr = gPathReservoirOther[index2Dto1D(pixel, gFrameDim.x)];
        else
            rCurr = gPathReservoir[index2Dto1D(pixel, gFrameDim.x)];

        //Load other reservoir and current shading data and begin resampling
        if (resamplingValid)
        {
            ShadingData sdCurr = loadShadingData(hit, gView[pixel].xyz, lod);

            PathReservoir rOther = gPathReservoirOther[index2Dto1D(otherPixel, gFrameDim.x)];
            resamplingValid = resampleReservoir(reservoir, rCurr, rOther, pixel, sdCurr, sdOther, sg);
        }

        //If resampling was not valid, use the current reservoir
        if (!resamplingValid)
            reservoir = rCurr;
    }

    //Store reservoir
    gPathReservoir[index2Dto1D(pixel, gFrameDim.x)] = reservoir;   
}
