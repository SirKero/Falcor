#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.Raytracing;
import Scene.RaytracingInline;
import Utils.Sampling.SampleGenerator;
import Utils.Color.ColorHelpers;
import Rendering.Lights.LightHelpers;
import Rendering.Lights.EmissiveLightSampler;
import Rendering.Lights.EmissiveLightSamplerHelpers;
import Rendering.Lights.EnvMapSampler;
import Rendering.RTXDI.RTXDI;
import SharedStructsAndFunctions;

cbuffer CB
{
    uint gFrameCount; // Current FrameCount for RNG
    float3 gNeeLightTypeSelectProbability; //Emissive, Analytic, EnvMap
    uint gMaxBounces;   //Max path length

}

cbuffer Light {
    EmissiveLightSampler gEmissiveSampler;
    EnvMapSampler gEnvMapSampler;
}

Texture2D<PackedHitInfo> gVBuffer;
Texture2D<float4> gView;

RWStructuredBuffer<ReservoirPT> gReservoir;
RWTexture2D<float4> gColorOut;

static const bool kUseEmissive = USE_EMISSIVE_LIGHT;
static const bool kUseAnalytic = USE_ANALYTIC_LIGHT;
static const bool kUseEnvMap = USE_ENV_BACKROUND;
static const bool kUseEnvLight = USE_ENV_LIGHT;
static const bool kAlphaTest = true;
static const uint kMIHints = (uint)MaterialInstanceHints::AdjustShadingNormal;
static const float kRoughnessThreshold = ROUGHNESS_THRESHOLD;

static const uint kNeeLightTypeEmissive = 0;
static const uint kNeeLightTypeAnalytic = 1;
static const uint kNeeLightTypeEnvMap = 2;

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

struct PathData {
    float3 thp;
    float pathPdf;

    float3 reconThp;        //thp for reconnect
    float scatterPdf;       //Last pdf (used for MIS)

    bool reconnectIsSet;
    bool isDiffuse;
    bool lastHitWasDiffuse;
    uint pathLength;

    __init() {
        thp = float3(1.0);
        reconThp = float3(1.0);
        pathPdf = 1.0;
        scatterPdf = 0;
        lastHitWasDiffuse = false;
        pathLength = 0;
        reconnectIsSet = false;
    }
}

// Nee light sample
struct LightSample {
    uint type;
    float3 Li;
    float pdf;
    float3 position;
    float3 dir;
    float distance;
    float3 faceN;
    uint _pad;
}

struct NeeSampleSurface {
    float3 posW;
    bool isValid;
    float3 faceN;
    float jacobianDeterminant;

    __init() {
        posW = float3(0);
        isValid = false;
        faceN = float3(0);
        jacobianDeterminant = -1;
    }
}

bool sampleNewRay(ShadingData sd, IMaterialInstance mi, inout SampleGenerator sg, inout PathData pd, inout RayDesc ray)
{
    BSDFSample bsdfSample;
    bool validSample = mi.sample(sd, sg, bsdfSample, true);
    if (validSample) {
        bool transmission = bsdfSample.isLobe(LobeType::Transmission);
        ray.Origin = sd.computeNewRayOrigin(!transmission); // false is for transmissions
        ray.Direction = bsdfSample.wo;
        if (pd.reconnectIsSet)
            pd.reconThp *= bsdfSample.weight;
        else
            pd.thp *= bsdfSample.weight;
        pd.scatterPdf = bsdfSample.pdf;
        pd.pathPdf *= pd.scatterPdf;
    }

    return validSample && any((pd.thp * pd.reconThp) > 0);
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

bool generateEmissiveSample(ShadingData sd, inout SampleGenerator sg, inout LightSample ls)
{
    TriangleLightSample tls = {};
    if (!gEmissiveSampler.sampleLight(sd.posW, sd.faceN, true, sg, tls))
        return false;

    ls.pdf *= tls.pdf;
    ls.Li = ls.pdf > 0.f ? tls.Le / ls.pdf : float3(0);
    ls.position = tls.posW;
    ls.faceN = tls.normalW;
    ls.distance = tls.distance;
    ls.dir = tls.dir;

    return any(ls.Li > 0);
}

bool generateAnalyticSample(ShadingData sd, inout SampleGenerator sg, inout LightSample ls) {
    uint lightCount = gScene.getLightCount();
    if (lightCount == 0) return false;

    uint lightIndex = min(uint(sampleNext1D(sg) * lightCount), lightCount - 1);
    // Sample local light source.
    AnalyticLightSample analyticSample;
    if (!sampleLight(sd.posW, gScene.getLight(lightIndex), sg, analyticSample)) return false;

    ls.Li = ls.pdf > 0 ? (analyticSample.Li * lightCount) / ls.pdf : float3(0); // analytic sample is already divided by the pdf
    ls.distance = analyticSample.distance;
    ls.dir = analyticSample.dir;
    //analytic pdf not needed, as no MIS is performed with analytic lights anyway

    return any(ls.Li > 0);
}

bool generateEnvMapSample(ShadingData sd, inout SampleGenerator sg, inout LightSample ls) {
    // Sample environment map.
    EnvMapSample envSample;
    if (!gEnvMapSampler.sample(sampleNext2D(sg), envSample)) return false;

    ls.pdf *= envSample.pdf;
    ls.Li = ls.pdf > 0.f ? envSample.Le / ls.pdf : float3(0);
    ls.distance = FLT_MAX;
    ls.dir = envSample.dir;

    return any(ls.Li > 0);
}

bool selectLightType(out uint lightType, out float pdf, float u)
{
    float3 p = gNeeLightTypeSelectProbability;
    //[unroll]
    for (lightType = 0; lightType < 3; ++lightType)
    {
        if (u < p[lightType])
        {
            pdf = p[lightType];
            return true;
        }
        u -= p[lightType];
    }

    lightType = {};
    pdf = {};

    return false;
}

float3 nextEventEstimation(ShadingData sd, IMaterialInstance mi, out LightSample ls , inout SampleGenerator sg)
{
    ls = {};
    if (!selectLightType(ls.type, ls.pdf, sampleNext1D(sg)))
        return float3(0);

    bool valid = false;
    if (ls.type == kNeeLightTypeEmissive)
        valid = generateEmissiveSample(sd, sg, ls);
    if (ls.type == kNeeLightTypeAnalytic)
        valid = generateAnalyticSample(sd, sg, ls);
    if (ls.type == kNeeLightTypeEnvMap)
        valid = generateEnvMapSample(sd, sg, ls);

    if (!valid)
        return float3(0);

    float3 bsdf = mi.eval(sd, ls.dir, sg);

    if (all(bsdf <= 0) || ls.pdf <= 0)
        return float3(0);

    // Shadow Ray
    if (!dispatchShadowRay(sd, ls.dir, ls.distance))
        return float3(0);

    float misWeight = 1.0;
    if (ls.type != kNeeLightTypeAnalytic) {
        float scatterPdf = mi.evalPdf(sd, ls.dir);
        misWeight = evalMIS(1.0, ls.pdf, 1.0, scatterPdf);
    }
  
    return misWeight * bsdf * ls.Li;
}

bool addSampleToReservoir(inout ReservoirPT reservoir, float rand, float3 sampleRadiance, float3 reconnectThp)
{
    float w = luminance(sampleRadiance * reconnectThp);
    reservoir.wSum += w;
    bool selectOther = rand * reservoir.wSum <= w;
    if (selectOther) {
        reservoir.targetFunction = w;
        reservoir.sampleRadiance = sampleRadiance;
        reservoir.reconnectionThp = reconnectThp;
    }
    return selectOther;
}

float3 tracePath(RayDesc ray, inout SampleGenerator sg, inout SampleGenerator rayDirSg, inout PathData pd, inout ReservoirPT reservoir)
{
    float3 outColor = float3(0);
    RayPayload rayPayload = RayPayload();

    // Used for scatter MIS (at pathLength > 0)
    float3 lastOrigin = ray.Origin;
    float3 lastFaceNormal = float3(0, 1, 0);

    // For special case first diffuse -> nee selected
    NeeSampleSurface neeSampleSurface = NeeSampleSurface();

    for (pd.pathLength = 1 ; pd.pathLength <= gMaxBounces; pd.pathLength++) {
        TraceRay(gScene.rtAccel, 0 /*Flags*/, 0xff /* instanceInclusionMask */, 0 /* hitIdx */, rayTypeCount, 0 /* missIdx */, ray, rayPayload);
        // Get surface hit info
        HitInfo hit = HitInfo(rayPayload.packedHitInfo);
        //Scene miss (eval env map)
        if (!hit.isValid()) {
            if (kUseEnvMap && pd.pathLength > 1) {
                // MIS
                float misWeight = 1.0;
                if (kUseEnvLight && pd.lastHitWasDiffuse) {
                    float lightPdf = gNeeLightTypeSelectProbability[kNeeLightTypeEnvMap] * gEnvMapSampler.evalPdf(ray.Direction);
                    misWeight = evalMIS(1, pd.scatterPdf, 1, lightPdf);
                }
                float3 envMapContribution = misWeight * gScene.envMap.eval(ray.Direction) * pd.reconThp;
                neeSampleSurface.isValid = !addSampleToReservoir( reservoir, sampleNext1D(sg), envMapContribution, pd.thp);
                outColor += envMapContribution * pd.thp;
            }
            break;
        }

        // Get shading infos
        let lod = ExplicitLodTextureSampler(0);

        // Get Material properties
        ShadingData sd = loadShadingData(hit, ray.Direction, lod);
        let mi = gScene.materials.getMaterialInstance(sd, lod, kMIHints);
        let bsdfProperties = mi.getProperties(sd);

        //Check if reuse or sample surface can be set
        bool hitIsDiffuse = bsdfProperties.roughness > kRoughnessThreshold;
        if (!pd.reconnectIsSet && hitIsDiffuse) {
            // If last and current hit is diffuse it is a valid reservoir
            if (pd.lastHitWasDiffuse) {
                reservoir.samplePosW = sd.posW;
                reservoir.sampleFaceN = sd.getOrientedFaceNormal();
                float rayDist = distance(ray.Origin, sd.posW);
                reservoir.jacobianDeterminant = dot(sd.faceN, -ray.Direction) / (rayDist * rayDist); // Reconnection jacobian determinant
                pd.reconnectIsSet = true;
            }
            else // Set new reconnection surface if last hit was specular
            {
                reservoir.reconnectionSurface = hit.getData();
                reservoir.reconnectionSurfaceIncomingDir = sd.V;
                reservoir.pathLength = pd.pathLength;
            }
        }

        // Ray hits emissive (only used after 2nd bounce, as RTXDI handles direct light)
        bool hitEmissive = any(bsdfProperties.emission > 0);
        if (hitEmissive && pd.pathLength > 1) {
            //Get hit in light collection representation
            TriangleHit triangleHit = hit.getTriangleHit();
            TriangleLightHit lightHit;
            lightHit.triangleIndex = gScene.lightCollection.getTriangleIndex(triangleHit.instanceID, triangleHit.primitiveIndex);
            lightHit.posW = sd.posW;
            lightHit.normalW = sd.getOrientedFaceNormal();

            // MIS
            float misWeight = 1;
            if (pd.lastHitWasDiffuse) {
                float neePDF = gNeeLightTypeSelectProbability[kNeeLightTypeEmissive] * gEmissiveSampler.evalPdf(lastOrigin, lastFaceNormal, true, lightHit);
                misWeight = evalMIS(1.0, pd.scatterPdf, 1.0, neePDF);
            }

            float3 emissiveRadiance = misWeight * bsdfProperties.emission * pd.reconThp; // Is also w, as primary path space is used (pdf == 1)
            neeSampleSurface.isValid = !addSampleToReservoir(reservoir, sampleNext1D(sg), emissiveRadiance, pd.thp);

            outColor += emissiveRadiance;
        }

        // Scatter ray should be traced for the current iteration. Additionally, emissive reflections are undefined
        if (pd.pathLength >= gMaxBounces || hitEmissive)
            break;

        // Sample light (NEE)
        bool currentIsDelta = bsdfProperties.roughness <= kDeltaRoughnessThreshold;
        if (!currentIsDelta) {
            LightSample ls;
            float3 nee = nextEventEstimation(sd, mi, ls, sg) * pd.reconThp;
            if (addSampleToReservoir(reservoir, sampleNext1D(sg), nee, pd.thp))
            {
                if (ls.type == kNeeLightTypeEmissive && !pd.reconnectIsSet) {
                    neeSampleSurface.posW = ls.position;
                    neeSampleSurface.isValid = true;
                    neeSampleSurface.faceN = ls.faceN;
                    neeSampleSurface.jacobianDeterminant = dot(neeSampleSurface.faceN, -ls.dir) / (ls.distance * ls.distance); // Reconnection jacobian determinant
                } else {
                    neeSampleSurface.isValid = false;
                }
            }
            outColor += nee;
        }
       
        lastOrigin = sd.posW;
        lastFaceNormal = sd.getOrientedFaceNormal();

        // New ray
        pd.lastHitWasDiffuse = !currentIsDelta;
        if (!sampleNewRay(sd, mi, rayDirSg, pd, ray))
            break;
    }

    if (neeSampleSurface.isValid) {
        reservoir.samplePosW = neeSampleSurface.posW;
        reservoir.sampleFaceN = neeSampleSurface.faceN;
        reservoir.jacobianDeterminant = neeSampleSurface.jacobianDeterminant;
    }

    // Finalize Reservoir
    if (reservoir.targetFunction > 0) {
        reservoir.wSum /= reservoir.targetFunction;
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
    ReservoirPT reservoir = ReservoirPT();

    if (hitInfo.isValid()) {
        // Set RTXDI data
        let lod = ExplicitLodTextureSampler(0);
        SampleGenerator sg = SampleGenerator(pixel, gFrameCount * 5 + 1);
        reservoir.rngSeed = gFrameCount * 5 + 2;
        SampleGenerator rayDirSg = SampleGenerator(pixel, reservoir.rngSeed); //Seperate sample generator for ray directions (used in random replay)

        ShadingData sd = loadShadingData(hitInfo, viewDir, lod);
        let mi = gScene.materials.getMaterialInstance(sd, lod, kMIHints);
        let bsdfProperties = mi.getProperties(sd);
        float distanceToSurface = distance(sd.posW, gScene.camera.getPosition());

        gRTXDI.setSurfaceData(pixel, sd.computeNewRayOrigin(), bsdfProperties.guideNormal, bsdfProperties.diffuseReflectionAlbedo, bsdfProperties.specularReflectance, bsdfProperties.roughness, distanceToSurface);

        // Prepare for the first ray
        PathData pd = PathData();
        pd.lastHitWasDiffuse = bsdfProperties.roughness > kRoughnessThreshold;
        if (pd.lastHitWasDiffuse) {
            reservoir.reconnectionSurface = hitInfo.getData();
            reservoir.reconnectionSurfaceIncomingDir = sd.V;
        }
            
        RayDesc ray = {};
        ray.TMin = 0;
        ray.TMax = FLT_MAX;
        float3 thp = float3(1.0);

        if (sampleNewRay(sd, mi, rayDirSg, pd, ray))
            outColor = tracePath(ray, sg, rayDirSg, pd, reservoir);

    } else
    {
        // Set invalid RTXDI data
        gRTXDI.setInvalidSurfaceData(pixel);
    }

    gReservoir[index2Dto1D(pixel, dispatchDims.x)] = reservoir;
    gColorOut[pixel] = float4(outColor, 1);
}
