#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.Raytracing;
import Scene.RaytracingInline;
import Utils.Sampling.SampleGenerator;
import Rendering.Lights.LightHelpers;
import Rendering.Lights.EmissiveLightSampler;
import Rendering.Lights.EmissiveLightSamplerHelpers;
import Rendering.RTXDI.RTXDI;

cbuffer CB
{
    uint gFrameCount;   //Current FrameCount for RNG
    uint gMaxBounces;   //Max path length
}

cbuffer Light {
    EmissiveLightSampler gEmissiveSampler;
}

Texture2D<PackedHitInfo> gVBuffer;
Texture2D<float4> gView;

RWTexture2D<float4> gColorOut;

static const bool kUseEmissive = USE_EMISSIVE_LIGHT;
static const bool kUseAnalytic = USE_ANALYTIC_LIGHT;
static const bool kUseEnvMap = USE_ENV_BACKROUND;
static const bool kAlphaTest = true;
static const uint kMIHints = (uint)MaterialInstanceHints::AdjustShadingNormal;

struct RayPayload
{
    PackedHitInfo packedHitInfo; //< Hit Info

    /** Create ray payload with default parameters.
     */
    __init()
    {
        this.packedHitInfo = {};
    }
}

// Load in shading data from hit and direction
ShadingData loadShadingData(const HitInfo hit, const float3 rayDir, const ITextureSampler lod)
{
    const TriangleHit triangleHit = hit.getTriangleHit();
    VertexData v = gScene.getVertexData(triangleHit);
    uint materialID = gScene.getMaterialID(triangleHit.instanceID);
    ShadingData sd = gScene.materials.prepareShadingData(v, materialID, -rayDir, lod);

    return sd;
}

bool sampleNewRay(ShadingData sd, IMaterialInstance mi, inout SampleGenerator sg, inout float3 thp, inout float pdf, inout RayDesc ray)
{
    BSDFSample bsdfSample;
    bool validSample = mi.sample(sd, sg, bsdfSample, true);
    if (validSample) {
        bool transmission = bsdfSample.isLobe(LobeType::Transmission);
        ray.Origin = sd.computeNewRayOrigin(!transmission); // false is for transmissions
        ray.Direction = bsdfSample.wo;
        thp *= bsdfSample.weight;
        pdf = bsdfSample.pdf;
    }

    return validSample && any(thp > 0);
}

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
    return q0 / (q0 + q1);
}

float3 nextEventEstimation(ShadingData sd, IMaterialInstance mi, inout SampleGenerator sg)
{
    TriangleLightSample tls = {};
    if (!gEmissiveSampler.sampleLight(sd.posW, sd.faceN, true, sg, tls))
        return float3(0);

    float3 bsdf = mi.eval(sd, tls.dir, sg);

    if (all(bsdf <= 0) || tls.pdf <= 0)
        return float3(0);

    // Shadow Ray
    SceneRayQuery<1> rayQuery;
    const Ray ray = Ray(sd.computeNewRayOrigin(), tls.dir, 0.f, tls.distance * 0.98);
    if (!rayQuery.traceVisibilityRay(ray, RAY_FLAG_NONE, 0xff))
        return float3(0);

    float scatterPdf = mi.evalPdf(sd, tls.dir);
    float misWeight = evalMIS(1.0, tls.pdf, 1.0, scatterPdf);

    return misWeight * bsdf * tls.Le / tls.pdf;
}

float3 tracePath(RayDesc ray, inout SampleGenerator sg, inout float3 thp)
{
    float3 outColor = float3(0);
    RayPayload rayPayload = RayPayload();
    uint pathLength = 0;

    // Used for scatter MIS (at pathLength > 0)
    float3 lastOrigin = ray.Origin;      
    float3 lastFaceNormal = float3(0, 1, 0);
    float scatterPdf = 1.0;

    for (pathLength; pathLength <= gMaxBounces; pathLength++) {
        TraceRay(gScene.rtAccel, 0 /*Flags*/, 0xff /* instanceInclusionMask */, 0 /* hitIdx */, rayTypeCount, 0 /* missIdx */, ray, rayPayload);
        // Get surface hit info
        HitInfo hit = HitInfo(rayPayload.packedHitInfo);
        //Scene miss (eval env map)
        if (!hit.isValid()) {
            if (kUseEnvMap && pathLength > 0)
                outColor += gScene.envMap.eval(ray.Direction) * thp;
            return outColor;
        }

        // Get shading infos
        let lod = ExplicitLodTextureSampler(0);

        // Get Material properties
        ShadingData sd = loadShadingData(hit, ray.Direction, lod);
        let mi = gScene.materials.getMaterialInstance(sd, lod, kMIHints);
        let bsdfProperties = mi.getProperties(sd);

        //Ray hits emissive (only used after 2nd bounce, as RTXDI handles direct light)
        if (any(bsdfProperties.emission > 0) && pathLength > 0) {
            //Get hit in light collection representation
            TriangleHit triangleHit = hit.getTriangleHit();
            TriangleLightHit lightHit;
            lightHit.triangleIndex = gScene.lightCollection.getTriangleIndex(triangleHit.instanceID, triangleHit.primitiveIndex);
            lightHit.posW = sd.posW;
            lightHit.normalW = sd.getOrientedFaceNormal();

            // Evaluate nee pdf
            float neePDF = gEmissiveSampler.evalPdf(lastOrigin, lastFaceNormal, true, lightHit);
            float misWeight = 0;
            if(scatterPdf > 0)
                misWeight = evalMIS(1.0, scatterPdf, 1.0, neePDF);

            outColor += misWeight * bsdfProperties.emission * thp;
        }

        //Scatter ray should be traced for the current iteration
        if (pathLength >= gMaxBounces)
            break;

        //Sample light (NEE)
        float3 nee = nextEventEstimation(sd, mi, sg);
        outColor += nee * thp;

        lastOrigin = sd.posW;
        lastFaceNormal = sd.getOrientedFaceNormal();

        //New ray
        if (!sampleNewRay(sd, mi, sg, thp, scatterPdf, ray))
            break;
    }

    return outColor;
}

[shader("miss")]
void miss(inout RayPayload rayData: SV_RayPayload)
{
    HitInfo hitInfo = {};
    rayData.packedHitInfo = hitInfo.getData(); // Invalid hit
}

// For alpha test
[shader("anyhit")]
void anyHit(inout RayPayload rayData: SV_RayPayload, BuiltInTriangleIntersectionAttributes attribs: SV_IntersectionAttributes)
{
    if (kAlphaTest)
    {
        // Alpha test for non-opaque geometry.
        GeometryInstanceID instanceID = getGeometryInstanceID();
        VertexData v = getVertexData(instanceID, PrimitiveIndex(), attribs);
        uint materialID = gScene.getMaterialID(instanceID);
        if (gScene.materials.alphaTest(v, materialID, 0.f))
            IgnoreHit();
    }
}

[shader("closesthit")]
void closestHit(inout RayPayload rayData: SV_RayPayload, BuiltInTriangleIntersectionAttributes attribs: SV_IntersectionAttributes) {
    TriangleHit triangleHit;
    triangleHit.instanceID = getGeometryInstanceID();
    triangleHit.primitiveIndex = PrimitiveIndex();
    triangleHit.barycentrics = attribs.barycentrics;

    rayData.packedHitInfo = HitInfo(triangleHit).getData();
}

[shader("raygeneration")]
void rayGen()
{
    uint2 pixel = DispatchRaysIndex().xy;
    uint2 dispatchDims = DispatchRaysDimensions().xy;

    HitInfo hitInfo = HitInfo(gVBuffer[pixel]);
    float3 viewDir = -gView[pixel].xyz;
    float3 outColor = float3(0);

    if (hitInfo.isValid()) {
        // Set RTXDI data
        let lod = ExplicitLodTextureSampler(0);
        SampleGenerator sg = SampleGenerator(pixel, gFrameCount * 5 + 1);

        ShadingData sd = loadShadingData(hitInfo, viewDir, lod);
        let mi = gScene.materials.getMaterialInstance(sd, lod, kMIHints);
        let bsdfProperties = mi.getProperties(sd);
        float distanceToSurface = distance(sd.posW, gScene.camera.getPosition());

        gRTXDI.setSurfaceData(pixel, sd.computeNewRayOrigin(), bsdfProperties.guideNormal, bsdfProperties.diffuseReflectionAlbedo, bsdfProperties.specularReflectance, bsdfProperties.roughness, distanceToSurface);

        // Prepare for the first ray
        RayDesc ray = {};
        ray.TMin = 0;
        ray.TMax = FLT_MAX;
        float3 thp = float3(1.0);
        float pdf = 1.0;

        if (sampleNewRay(sd, mi, sg, thp, pdf, ray))
            outColor = tracePath(ray, sg, thp);

    } else
    {
        // Set invalid RTXDI data
        gRTXDI.setInvalidSurfaceData(pixel);
    }

    gColorOut[pixel] = float4(outColor, 1);
}
