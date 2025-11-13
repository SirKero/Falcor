#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.Raytracing;
import Scene.RaytracingInline;
import Utils.Sampling.SampleGenerator;
import Utils.Color.ColorHelpers;
import Rendering.Lights.LightHelpers;
import Rendering.Lights.EmissiveLightSampler;
import Rendering.Lights.EmissiveLightSamplerHelpers;
import Rendering.RTXDI.RTXDI;
import SharedStructsAndFunctions;

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

RWStructuredBuffer<ReservoirPT> gReservoir;
RWTexture2D<float4> gColorOut;

static const bool kUseEmissive = USE_EMISSIVE_LIGHT;
static const bool kUseAnalytic = USE_ANALYTIC_LIGHT;
static const bool kUseEnvMap = USE_ENV_BACKROUND;
static const bool kAlphaTest = true;
static const uint kMIHints = (uint)MaterialInstanceHints::AdjustShadingNormal;
static const float kRoughnessThreshold = ROUGHNESS_THRESHOLD;

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

    float scatterPdf;
    bool isDiffuse;
    bool lastHitWasDiffuse;
    uint pathLength;

    __init() {
        thp = float3(1.0);
        pathPdf = 1.0;
        scatterPdf = 0;
        lastHitWasDiffuse = false;
        pathLength = 0;
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
        pd.thp *= bsdfSample.weight;
        pd.scatterPdf = bsdfSample.pdf;
        pd.pathPdf *= pd.scatterPdf;
    }

    return validSample && any(pd.thp > 0);
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

float3 nextEventEstimation(ShadingData sd, IMaterialInstance mi, out TriangleLightSample tls , inout SampleGenerator sg)
{
    tls = {};
    if (!gEmissiveSampler.sampleLight(sd.posW, sd.faceN, true, sg, tls))
        return float3(0);

    float3 bsdf = mi.eval(sd, tls.dir, sg);

    if (all(bsdf <= 0) || tls.pdf <= 0)
        return float3(0);

    // Shadow Ray
    if (!dispatchShadowRay(sd, tls.dir, tls.distance))
        return float3(0);

    float scatterPdf = mi.evalPdf(sd, tls.dir);
    float misWeight = evalMIS(1.0, tls.pdf, 1.0, scatterPdf);

    return misWeight * bsdf * tls.Le / tls.pdf;
}

bool addSampleToReservoir(inout ReservoirPT reservoir, float rand, float3 sampleRadiance)
{
    float w = luminance(sampleRadiance); 
    reservoir.wSum += w;
    bool selectOther = rand * reservoir.wSum <= w;
    if (selectOther) {
        reservoir.targetFunction = w;
        reservoir.sampleRadiance = sampleRadiance;
    }
    return selectOther;
}

//TODO add a separate sample generator for BSDF samples
//TODO Add more light types (analytic & envmaps)
float3 tracePath(RayDesc ray, inout SampleGenerator sg, inout SampleGenerator rayDirSg, inout PathData pd, inout ReservoirPT reservoir)
{
    float3 outColor = float3(0);
    RayPayload rayPayload = RayPayload();

    // Used for scatter MIS (at pathLength > 0)
    float3 lastOrigin = ray.Origin;
    float3 lastFaceNormal = float3(0, 1, 0);
    bool validReservoir = false; //If the reservoir is valid, the reuse surface does not need to be replaced

    // For special case first diffuse -> nee selected
    float3 neeSamplePosW = float3(0);
    bool sampleSurfaceIsNeeSample = false;
    float3 neeSampleFaceN = float3(0);
    float neeSampleJacobian = -1;

    for (pd.pathLength = 1 ; pd.pathLength <= gMaxBounces; pd.pathLength++) {
        TraceRay(gScene.rtAccel, 0 /*Flags*/, 0xff /* instanceInclusionMask */, 0 /* hitIdx */, rayTypeCount, 0 /* missIdx */, ray, rayPayload);
        // Get surface hit info
        HitInfo hit = HitInfo(rayPayload.packedHitInfo);
        //Scene miss (eval env map)
        if (!hit.isValid()) {
            if (kUseEnvMap && pd.pathLength > 1) {
                float3 envMapContribution = gScene.envMap.eval(ray.Direction) * pd.thp;
                sampleSurfaceIsNeeSample = !addSampleToReservoir(reservoir, sampleNext1D(sg), envMapContribution);
                outColor += envMapContribution;
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
        if (!validReservoir && hitIsDiffuse) {
            // If last and current hit is diffuse it is a valid reservoir
            if (pd.lastHitWasDiffuse) {
                reservoir.samplePosW = sd.posW;
                reservoir.sampleFaceN = sd.getOrientedFaceNormal();
                float rayDist = distance(ray.Origin, sd.posW);
                reservoir.jacobianDeterminant = dot(sd.faceN, -ray.Direction) / (rayDist * rayDist); // Reconnection jacobian determinant
                validReservoir = true;
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

            // Evaluate nee pdf
            float neePDF = gEmissiveSampler.evalPdf(lastOrigin, lastFaceNormal, true, lightHit);
            float misWeight = 1;
            if (pd.lastHitWasDiffuse)
                misWeight = evalMIS(1.0, pd.scatterPdf, 1.0, neePDF);

            float3 emissiveRadiance = misWeight * bsdfProperties.emission * pd.thp; // Is also w, as primary path space is used (pdf == 1)
            sampleSurfaceIsNeeSample = !addSampleToReservoir(reservoir, sampleNext1D(sg), emissiveRadiance);

            outColor += emissiveRadiance;
        }

        // Scatter ray should be traced for the current iteration. Additionally, emissive reflections are undefined
        if (pd.pathLength >= gMaxBounces || hitEmissive)
            break;

        // Sample light (NEE)
        bool currentIsDelta = bsdfProperties.roughness <= kDeltaRoughnessThreshold;
        if (!currentIsDelta) {
            TriangleLightSample tls;
            float3 nee = nextEventEstimation(sd, mi, tls, sg) * pd.thp;
            if (addSampleToReservoir(reservoir, sampleNext1D(sg), nee))
            {
                if (!validReservoir) {
                    neeSamplePosW = tls.posW;
                    sampleSurfaceIsNeeSample = true;
                    neeSampleFaceN = tls.normalW;
                    neeSampleJacobian = dot(neeSampleFaceN, -tls.dir) / (tls.distance * tls.distance); // Reconnection jacobian determinant
                } else {
                    sampleSurfaceIsNeeSample = false;
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

    if (sampleSurfaceIsNeeSample) {
        reservoir.samplePosW = neeSamplePosW;
        reservoir.sampleFaceN = neeSampleFaceN;
        reservoir.jacobianDeterminant = neeSampleJacobian;
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
