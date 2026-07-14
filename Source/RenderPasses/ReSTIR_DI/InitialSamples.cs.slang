#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.RaytracingInline;
import Utils.Sampling.SampleGenerator;
import Utils.Color.ColorHelpers;
import Rendering.Lights.EmissiveLightSampler;
import Rendering.Lights.EmissiveLightSamplerHelpers;
import StructsAndHelpers;

Texture2D<PackedHitInfo> gVBuffer;
Texture2D<float4> gView;

RWStructuredBuffer<Reservoir> gReservoir;

cbuffer CB
{
    uint gFrameCount; // Frame count since scene was loaded.
    uint2 gFrameDims;
    uint gNumEmissiveSamples;

    uint gNumBSDFSamples;
}

cbuffer Light {
    EmissiveLightSampler gEmissiveSampler;
}

static const bool kUseEnvBackground = USE_ENV_BACKROUND;
static const uint kMIHints = (uint)MaterialInstanceHints::AdjustShadingNormal;

bool addSampleToReservoir(inout Reservoir reservoir, float w, float targetFunction, uint triIndex, float3 hitPos, float3 emission, inout SampleGenerator sg)
{
    reservoir.wSum += w;
    bool selectSample = sampleNext1D(sg) * reservoir.wSum <= w;
    if (selectSample) {
        reservoir.emissiveTriIndex = triIndex;
        reservoir.hitPos = hitPos;
        reservoir.targetFuction = targetFunction;
        reservoir.emission = emission;
    }

    return selectSample;
}

void genEmissiveSamplesReference(ShadingData sd, IMaterialInstance mi, inout SampleGenerator sg, inout Reservoir reservoir)
{
    for (uint i = 0; i < gNumEmissiveSamples; i++)
    {
        TriangleLightSample tls = {};
        if (!gEmissiveSampler.sampleLight(sd.posW, sd.faceN, true, sg, tls))
            continue;

        float3 bsdf = mi.eval(sd, tls.dir, sg);
        if (all(bsdf <= 0) || tls.pdf <= 0)
            continue;

        // Test visibility for the selected sample
        SceneRayQuery<1> rayQuery;
        const Ray ray = Ray(sd.computeNewRayOrigin(), tls.dir, 0.f, tls.distance * 0.98);
        if (!rayQuery.traceVisibilityRay(ray, RAY_FLAG_NONE, 0xff))
            continue;

        // MIS
        float mis = 1.0 / gNumEmissiveSamples;
        if (gNumBSDFSamples > 0) {
            float bsdfPdf = mi.evalPdf(sd, tls.dir);
            mis = tls.pdf / (tls.pdf * gNumEmissiveSamples + bsdfPdf * gNumBSDFSamples);
        }

        // Add to reservoir
        float targetFunction = luminance(bsdf * tls.Le);
        float w = mis * targetFunction / tls.pdf;
        addSampleToReservoir(reservoir, w, targetFunction, tls.triangleIndex, tls.posW, tls.Le, sg);
    }
}

void genEmissiveSamplesWRS(ShadingData sd, IMaterialInstance mi, inout SampleGenerator sg, inout Reservoir reservoir)
{
    TriangleLightSample selectedTls = {};
    float weightSum = 0;
    float choosenWeight = 0;
    float choosenTargetFunc = 0;
    
    for (uint i = 0; i < gNumEmissiveSamples; i++)
    {
        TriangleLightSample tls = {};
        if (!gEmissiveSampler.sampleLight(sd.posW, sd.faceN, true, sg, tls))
            continue;

        float3 bsdf = mi.eval(sd, tls.dir, sg);
        if (all(bsdf <= 0) || tls.pdf <= 0)
            continue;

        // Add to reservoir
        float targetFunction = luminance(bsdf * tls.Le);
        float w = targetFunction / tls.pdf;

        weightSum += w;
        if((sampleNext1D(sg) * weightSum) < w)
        {
            selectedTls = tls;
            choosenWeight = w;
            choosenTargetFunc = targetFunction;
        }
    }

    // Check if a valid sample was found
    if (choosenWeight > 0)
    {
        // MIS
        float mis = 1.0 / gNumEmissiveSamples;
        if (gNumBSDFSamples > 0) {
            float bsdfPdf = mi.evalPdf(sd, selectedTls.dir);
            mis = selectedTls.pdf / (selectedTls.pdf * gNumEmissiveSamples + bsdfPdf * gNumBSDFSamples);
        }

        float risWeight = mis * choosenWeight / (choosenWeight / weightSum);
        //risWeight /= gNumEmissiveSamples;
        //risWeight /= selectedTls.pdf;
        // Test visibility for the selected sample
        SceneRayQuery<1> rayQuery;
        const Ray ray = Ray(sd.computeNewRayOrigin(), selectedTls.dir, 0.f, selectedTls.distance * 0.98);
        if (!rayQuery.traceVisibilityRay(ray, RAY_FLAG_NONE, 0xff))
            risWeight = 0;

        addSampleToReservoir(reservoir, risWeight, choosenTargetFunc, selectedTls.triangleIndex, selectedTls.posW, selectedTls.Le, sg);
    }    
}

void genBSDFSamples(ShadingData sd, IMaterialInstance mi, inout SampleGenerator sg, inout Reservoir reservoir)
{
    for (uint i = 0; i < gNumBSDFSamples; i++)
    {
        BSDFSample bsdfSample;
        if (!mi.sample(sd, sg, bsdfSample, true /*ImportanceSampling*/))
            continue;

        Ray ray;
        ray.tMin = 0;
        ray.tMax = FLT_MAX;
        bool transmission = bsdfSample.isLobe(LobeType::Transmission);
        ray.origin = sd.computeNewRayOrigin(!transmission); // false is for transmissions
        ray.dir = bsdfSample.wo;

        HitInfo hitInfo;
        float hitT = -1.0;
        if (!traceSceneRay<1>(ray, hitInfo, hitT, RAY_FLAG_NONE, 0xFF))
            continue;

        // Get Material properties
        let lod = ExplicitLodTextureSampler(0.f);
        ShadingData sdHit = loadShadingData(hitInfo, ray.dir, lod);
        let miHit = gScene.materials.getMaterialInstance(sdHit, lod, kMIHints);
        let bsdfPropertiesHit = miHit.getProperties(sdHit);

        if (all(bsdfPropertiesHit.emission <= 0))
            continue;

        //Emissive triangle info
        TriangleHit triangleHit = hitInfo.getTriangleHit();
        TriangleLightHit emissiveHit;
        emissiveHit.triangleIndex = gScene.lightCollection.getTriangleIndex(triangleHit.instanceID, triangleHit.primitiveIndex);
        emissiveHit.posW = sdHit.posW;
        emissiveHit.normalW = sdHit.getOrientedFaceNormal();

        float3 bsdf = mi.eval(sd, ray.dir, sg);
        if (all(bsdf <= 0) || bsdfSample.pdf <= 0)
            continue;

        // MIS
        const float pdf = bsdfSample.pdf;
        float mis = 1.0 / gNumBSDFSamples;
        if (gNumEmissiveSamples > 0) {
            float emissivePdf = gEmissiveSampler.evalPdf(sd.posW, sd.faceN, true, emissiveHit);
            mis = pdf / (emissivePdf * gNumEmissiveSamples + pdf * gNumBSDFSamples);
        }

        // Add to reservoir
        float targetFunction = luminance(bsdf * bsdfPropertiesHit.emission);
        float w = mis * targetFunction / pdf;
        addSampleToReservoir(reservoir, w, targetFunction, emissiveHit.triangleIndex, sdHit.posW, bsdfPropertiesHit.emission , sg);
    }
}

[numthreads(16, 16, 1)]
void main(uint2 pixel: SV_DispatchThreadID)
{
    if (any(pixel >= gFrameDims))
        return;

    HitInfo hitInfo = HitInfo(gVBuffer[pixel]);
    float3 viewDir = -gView[pixel].xyz;

    Reservoir reservoir = Reservoir();
    if (hitInfo.isValid())
    {
        SampleGenerator sg = SampleGenerator(pixel, gFrameCount + 4);
        let lod = ExplicitLodTextureSampler(0.f);

        // Get Material properties
        ShadingData sd = loadShadingData(hitInfo, viewDir, lod);
        let mi = gScene.materials.getMaterialInstance(sd, lod, kMIHints);
        let bsdfProperties = mi.getProperties(sd);

        //genEmissiveSamplesReference(sd, mi, sg, reservoir);
        genEmissiveSamplesWRS(sd, mi, sg, reservoir);

        genBSDFSamples(sd, mi, sg, reservoir);

        // Finalize reservoir
        if (reservoir.valid() && reservoir.targetFuction > 0)
            reservoir.wSum = reservoir.wSum / reservoir.targetFuction;
    }

    gReservoir[index2Dto1D(pixel, gFrameDims.x)] = reservoir;
}
