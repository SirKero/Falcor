#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.RaytracingInline;
import Utils.Sampling.SampleGenerator;
import Utils.Color.ColorHelpers;
import Utils.Math.MathHelpers;
import StructsAndHelpers;

Texture2D<PackedHitInfo> gVBuffer;
Texture2D<float4> gView;
Texture2D<float2> gMVec;

Texture2D<PackedHitInfo> gVBufferPrev;
Texture2D<float4> gViewPrev;

StructuredBuffer<Reservoir> gReservoirPrev;
RWStructuredBuffer<Reservoir> gReservoir;

RWTexture2D<float4> gOutDebug; 

cbuffer CB
{
    uint gFrameCount; // Frame count since scene was loaded.
    uint2 gFrameDims;
    uint gConfidenceCap;

    float gNormalThreshold;
    float gRelativeDepthThreshold;
    uint gNumSpatialSamples;
    float gSpatialSampleRadius;
}

static const uint kMIHints = (uint)MaterialInstanceHints::AdjustShadingNormal;
static const float3 kDefaultBackgroundColor = float3(0);

float getPHat(Reservoir r, ShadingData sd, IMaterialInstance mi, inout SampleGenerator sg)
{
    //Get PHat without visibility
    float3 Le = r.emission;
    float3 triPosW = r.hitPos;
    float3 toLight = triPosW - sd.posW;
    float dist = length(toLight);
    toLight /= dist;

    float pHat = luminance(Le * mi.eval(sd, toLight, sg));

    // Visibility test
    if (pHat > 0) {
        SceneRayQuery<1> rayQuery;
        const Ray ray = Ray(sd.computeNewRayOrigin(), toLight, 0.f, dist * 0.98);
        if (!rayQuery.traceVisibilityRay(ray, RAY_FLAG_NONE, 0xff))
            return 0;
    }

    return max(pHat,0);
}

void resample(inout Reservoir r, ShadingData sd, IMaterialInstance mi, int2 resamplePixel, inout SampleGenerator sg)
{
    //Check if resample pixel is in frame
    if (any(resamplePixel < 0) || any(resamplePixel >= gFrameDims))
        return;

    // Load surfaces from last frame
    HitInfo hitInfoPrev = HitInfo(gVBufferPrev[resamplePixel]);
    float3 viewDirPrev = gViewPrev[resamplePixel].xyz;
    let lod = ExplicitLodTextureSampler(0.f);

    if (!hitInfoPrev.isValid())
        return;

    ShadingData sdPrev = loadShadingData(hitInfoPrev, -viewDirPrev, lod);
    let miPrev = gScene.materials.getMaterialInstance(sdPrev, lod, kMIHints);
    Reservoir rPrev = gReservoirPrev[index2Dto1D(resamplePixel, gFrameDims.x)];

    // Reject if surfaces are too different
    const float3 cameraPos = gScene.camera.getPosition();
    float currentDepth = distance(cameraPos, sd.posW);
    float temporalDepth = distance(cameraPos, sdPrev.posW);
    bool normalThreshold = abs(dot(sd.getOrientedFaceNormal(), sdPrev.getOrientedFaceNormal())) < gNormalThreshold;
    bool depthThreshold = abs(currentDepth - temporalDepth) > gRelativeDepthThreshold * currentDepth;

    if (normalThreshold || depthThreshold)
        return;

    //MIS for current reservoir
    if (r.wSum > 0)
    {
        float pHat = getPHat(r, sdPrev, miPrev, sg);

        float mis = evalMIS(r.c, r.targetFuction, rPrev.c, pHat);
        r.wSum = mis * r.targetFuction * r.wSum;
        
    }

    // Resample other reservoir
    if (rPrev.wSum > 0)
    {
        float pHat = getPHat(rPrev, sd, mi, sg);
        float mis = evalMIS(rPrev.c, rPrev.targetFuction, r.c, pHat);
        float weight = mis * pHat * rPrev.wSum;
        r.wSum += weight;

        // WRS
        if ((sampleNext1D(sg) * r.wSum) < weight)
        {
            r.emission = rPrev.emission;
            r.emissiveTriIndex = rPrev.emissiveTriIndex;
            r.hitPos = rPrev.hitPos;
            r.targetFuction = pHat;
        }
    }

    r.c = min(r.c + rPrev.c, gConfidenceCap);

    //Finalize reservoir
    if (r.wSum > 0 && r.targetFuction > 0)
        r.wSum /= r.targetFuction;
}

[numthreads(16, 16, 1)]
void main(uint2 pixel: SV_DispatchThreadID)
{
    if (any(pixel >= gFrameDims))
        return;

    HitInfo hitInfo = HitInfo(gVBuffer[pixel]);
    float3 viewDir = gView[pixel].xyz;
    Reservoir r = gReservoir[index2Dto1D(pixel, gFrameDims.x)];

    if (hitInfo.isValid())
    {
        SampleGenerator sg = SampleGenerator(pixel, gFrameCount * 5 + 2);
        // Get Material properties
        let lod = ExplicitLodTextureSampler(0.f);
        ShadingData sd = loadShadingData(hitInfo, -viewDir, lod);
        let mi = gScene.materials.getMaterialInstance(sd, lod, kMIHints);

        float2 prevPixel = float2(pixel) + 0.5 + gMVec[pixel] * float2(gFrameDims);

        // Resampling
        uint resamplingSamples = gNumSpatialSamples + 1;
        for (uint i = 0; i < resamplingSamples; i++)
        {
            float2 u = sampleNext2D(sg);
            float2 pixelOffset;
            if (i > 0) // Spatial
                pixelOffset = gSpatialSampleRadius * sample_disk_concentric(u);
            else //temporal, Subpixel offset
                pixelOffset = u - 0.5;

            int2 resamplePixel = int2(prevPixel + pixelOffset);
            resample(r, sd, mi, resamplePixel, sg);
        }
    }

    gReservoir[index2Dto1D(pixel, gFrameDims.x)] = r;
}
