#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.Raytracing;
import Scene.RaytracingInline;
import Utils.Sampling.SampleGenerator;
import Utils.Color.ColorHelpers;
import Rendering.Lights.LightHelpers;
import Rendering.Lights.EmissiveLightSampler;
import Rendering.Lights.EmissiveLightSamplerHelpers;
import StructsAndHelpers;

Texture2D<PackedHitInfo> gVBuffer;
Texture2D<float4> gView;

StructuredBuffer<PhotonData> gPhotonData;
StructuredBuffer<AABB> gPhotonAABB;
RaytracingAccelerationStructure gPhotonAS;

RWTexture2D<uint> gLightTraceColor[3]; // Uint spinlock color texture for every channel

RWTexture2D<float4> gDebug[4];
RWTexture2D<float4> gOutColor;

cbuffer Light {
    EmissiveLightSampler gEmissiveSampler;
}

cbuffer CB
{
    uint gFrameCount; // Frame count since scene was loaded.
    uint gMaxBounces; // Max path length for a Final Gather sample
    uint gNumLightPaths; // Number of light paths for MIS
    float gImagePlaneDist; //Camera image plane distance
    float gPhotonRadius;   // TODO remove temporary for MIS
    float gNormalizedPixelArea;
    int gDebugBounce;
}

static const float kPhotonCollectTMax = 1e-7;
static const bool kUseEnvMap = USE_ENV_MAP;
static const bool kAlphaTest = true;
static const float kRoughnessThreshold = ROUGHNESS_THRESHOLD;
static const float3 kDefaultBackgroundColor = float3(0.0);

static const bool kUseVC = USE_VC;
static const bool kUseVM = USE_VM;
static const bool kLightTraceOnly = USE_LIGHT_TRACE_ONLY;

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

//Helper struct for MIS
struct CameraState {
    uint pathLength;
  
    float pdf;
    float lightTracePdf;
    float photonPdf;

    bool isSpecularPath;
    bool lastHitWasDelta;
    bool isDeltaPath;
    bool firstHitDiffuse;

    __init() {
        pathLength = 0;
        pdf = 1.0;
        lightTracePdf = 1.0;
        photonPdf = 0.0;
        isSpecularPath = true;
        lastHitWasDelta = false;
        isDeltaPath = true;
        firstHitDiffuse = false;
    }
}

// Checks if the ray start point is inside the sphere.
bool hitSphere(const float3 center, const float radius, const float3 p)
{
    float3 radiusTest = p - center;
    radiusTest = radiusTest * radiusTest;
    float radiusTestF = radiusTest.x + radiusTest.y + radiusTest.z;
    if (radiusTestF < radius * radius)
        return true;
    return false;
}

float3 collectPhotons(ShadingData sd, IMaterialInstance mi, float3 N, CameraState camState, float continuationProb, uint instanceMask, inout SampleGenerator sg) {
    float3 collectedRadiance = float3(0);
    // Prepare ray
    RayDesc ray;
    ray.Origin = sd.posW;
    ray.Direction = sd.faceN;
    ray.TMin = 0;
    ray.TMax = kPhotonCollectTMax;

    RayQuery<RAY_FLAG_NONE> rayQuery;

    rayQuery.TraceRayInline(gPhotonAS, RAY_FLAG_NONE, instanceMask, ray);
    while (rayQuery.Proceed()) {

        if (rayQuery.CandidateType() != CANDIDATE_PROCEDURAL_PRIMITIVE)
            continue;
        const uint instanceIdx = rayQuery.CandidateInstanceIndex();
        const uint primIdx = rayQuery.CandidatePrimitiveIndex();

        // Check if ray is inside photon radius
        AABB photonAABB = gPhotonAABB[primIdx];
        float radius = (photonAABB.maxPoint.x - photonAABB.minPoint.x) / 2.0;
        if (!hitSphere(photonAABB.center(), radius, sd.posW))
            continue;

        PhotonData photonData = gPhotonData[primIdx];
        float NdotL = dot(photonData.dir, N);
        // Check for diffent surfaces (e.g. corners)
        if ((dot(photonData.normalW, sd.faceN) < 0.6) || (NdotL <= 0) || (camState.pathLength + photonData.pathLenght) > (gMaxBounces + 1))
            continue;

        float pdf = mi.evalPdf(sd, photonData.dir);
        float reversePDF = mi.evalPdf(sd, photonData.dir, sd.V);
        pdf *= continuationProb;

        //TODO a bit to dark something not completely right
        const float cameraScatterPdf = camState.pdf * photonData.reversePdf;
        float neePdf = photonData.neeReversePdf * camState.pdf;
        float lightTracePdf = camState.lightTracePdf * photonData.pdf * gNumLightPaths; // Light Trace
        // Photon pdf for path seperate + full path for denominator
        float photonPdf = camState.pdf * photonData.pdf * (gNumLightPaths * M_PI * gPhotonRadius * gPhotonRadius);
        float photonPathPdf = photonData.pathLenght == 0 ? photonPdf : camState.photonPdf * photonData.pdf + photonData.photonReversePdf * camState.pdf;

        float denom = (neePdf + cameraScatterPdf + lightTracePdf + photonPathPdf);
        float misWeight = 0;
        if (denom > 0)
            misWeight = photonPdf / denom;

        misWeight = clamp(misWeight, 0, 1);
        float3 bsdf = mi.eval(sd, photonData.dir, sg);
        collectedRadiance += max(0, (photonData.flux * bsdf * misWeight) / NdotL);     // NdotL needs to be taken out of the bsdf for Photon Mapping
    }
    collectedRadiance /= M_PI * gPhotonRadius * gPhotonRadius * gNumLightPaths;
    //collectedRadiance = camState.pdf;
    return collectedRadiance;
}

bool sampleNewRay(ShadingData sd, IMaterialInstance mi, float roughness, float continuationProbability, inout SampleGenerator sg, inout float3 thp, inout CameraState camState, inout RayDesc ray)
{
    // Photon Bounce for next iteration
    BSDFSample bsdfSample;
    if (!mi.sample(sd, sg, bsdfSample, true /*ImportanceSampling*/))
        return false;

    bool transmission = bsdfSample.isLobe(LobeType::Transmission);
    ray.Origin = sd.computeNewRayOrigin(!transmission); // false is for transmissions
    ray.Direction = bsdfSample.wo;
    thp *= bsdfSample.weight;

    //Russian Roulette
    if (sampleNext1D(sg) > continuationProbability)
        return false;
    thp /= continuationProbability;

    float pdf = bsdfSample.pdf * continuationProbability;
    float reversePdf = mi.evalPdf(sd, ray.Direction, sd.V) * continuationProbability;
    float cosThetaOut = abs(dot(sd.faceN, ray.Direction));
    // Specular
    if (roughness < kRoughnessThreshold) {
        camState.pdf *= cosThetaOut;
        if (camState.pathLength == 0)
            camState.lightTracePdf *= 0;
        else
            camState.lightTracePdf *= cosThetaOut;
        if (camState.pathLength > 0)
            camState.photonPdf *= cosThetaOut;
        camState.lastHitWasDelta = true;
    } else {
        if (camState.pathLength > 0) {
            camState.photonPdf *= reversePdf;
            //camState.photonPdf += camState.pdf * (gNumLightPaths * M_PI * gPhotonRadius * gPhotonRadius);
        }
        camState.pdf *= pdf * cosThetaOut;
        camState.lightTracePdf *= reversePdf * cosThetaOut;
        camState.isSpecularPath = false;
        camState.lastHitWasDelta = false;
    }
    camState.pathLength++;

    return true;
}

float3 handleEmissiveHit(ShadingData sd, float3 prevPos, float3 prevNormal,CameraState camState, TriangleHit triangleHit, float3 emission, float3 incomingDir)
{
    float neePdf = 0;
    uint lightTriIndex = gScene.lightCollection.getTriangleIndex(triangleHit.instanceID, triangleHit.primitiveIndex);
    const EmissiveTriangle emissiveTri = gScene.lightCollection.getTriangle(lightTriIndex);

    if (!camState.lastHitWasDelta) {        
        TriangleLightHit hit;
        hit.triangleIndex = lightTriIndex;
        hit.posW = sd.posW;
        hit.normalW = sd.getOrientedFaceNormal();

        neePdf = gEmissiveSampler.evalPdf(prevPos, prevNormal, true, hit);
    }
    
    float cosAtLight = abs(dot(sd.faceN, -sd.V));
    float emissionPdf = (cosAtLight * M_1_PI) / (emissiveTri.area * gScene.lightCollection.getActiveTriangleCount());
    float lightTracePDF = camState.lightTracePdf * emissionPdf * gNumLightPaths; // Light Trace
    float photonPDF = camState.isSpecularPath ? 0.0 : camState.photonPdf * emissionPdf;

    const float misWeight = camState.pdf / (camState.pdf + lightTracePDF + neePdf + photonPDF);
    return misWeight * emission;
}

float3 NextEventEstimation(ShadingData sd, IMaterialInstance mi ,CameraState camState, float continuationProb, inout SampleGenerator sg)
{
    TriangleLightSample tls = {};
    if (!gEmissiveSampler.sampleLight(sd.posW, sd.faceN, true, sg, tls))
        return float3(0);

    // Get emission pdf
    const EmissiveTriangle emissiveTri = gScene.lightCollection.getTriangle(tls.triangleIndex);
    float cosAtLight = abs(dot(emissiveTri.normal, -tls.dir));
    const float emissionPdf = (cosAtLight * M_1_PI) / (emissiveTri.area * gScene.lightCollection.getActiveTriangleCount());
    const float directPdf = tls.pdf; // Multiplied with activeTriangle count
    const float reversePdf = mi.evalPdf(sd, tls.dir, sd.V) * continuationProb;
    float lightTracePdf = camState.lightTracePdf * emissionPdf * reversePdf * gNumLightPaths; // Light Trace

    float3 bsdf = mi.eval(sd, tls.dir, sg);

    if (all(bsdf <= 0) || directPdf <= 0 || cosAtLight <= 0)
        return float3(0);

    SceneRayQuery<1> rayQuery;
    const Ray ray = Ray(sd.computeNewRayOrigin(), tls.dir, 0.f, tls.distance * 0.98);
    if (!rayQuery.traceVisibilityRay(ray, RAY_FLAG_NONE, 0xff))
        return float3(0);

    float cosToLight = dot(sd.faceN, tls.dir);
    float G = cosToLight / (tls.distance * tls.distance);
    lightTracePdf *= G;
    const float pdf = camState.pdf * directPdf;
    const float scatterPdf = camState.pdf * mi.evalPdf(sd, tls.dir, true) * continuationProb * G;
    float photonPdf = 0;
    if (camState.pathLength > 0)
        photonPdf = camState.photonPdf * emissionPdf;

    const float misWeight = pdf / (pdf + lightTracePdf + scatterPdf + photonPdf);

    float3 radiance = misWeight * bsdf * tls.Le / directPdf;
    return radiance;
}

float3 tracePath(RayDesc ray, ShadingData sd, inout CameraState camState,  inout SampleGenerator sg , inout float3 thp)
{
    float3 outColor = float3(0);
    RayPayload rayPayload = RayPayload();
    bool validRay = true;
    float3 prevPos = sd.posW;
    float3 prevFaceN = sd.faceN;

    for (uint i = 0; i < gMaxBounces && validRay; i++)
    {
        // Trace new ray
        TraceRay(gScene.rtAccel, 0 , 0xff , 0, rayTypeCount, 0 , ray, rayPayload);
        HitInfo hit = HitInfo(rayPayload.packedHitInfo);
        //Miss
        if (!hit.isValid()) {
            float3 envColor = kUseEnvMap ? gScene.envMap.eval(ray.Direction) : kDefaultBackgroundColor;
            outColor += thp * envColor;
            break;
        }

        // Get shading data
        let lod = ExplicitLodTextureSampler(0);
        ShadingData sd = loadShadingData(hit, ray.Direction, lod);
        uint hints = (uint)MaterialInstanceHints::AdjustShadingNormal;
        let mi = gScene.materials.getMaterialInstance(sd, lod, hints);
        let bsdfProperties = mi.getProperties(sd);
        float continuationProb = getContinuationProbablity(bsdfProperties);

        // Update Geometry term
        bool isDiffuse = bsdfProperties.roughness > kRoughnessThreshold;
        float dist = distance(sd.posW, ray.Origin);
        float cosTheta = abs(dot(sd.faceN, sd.V));
        float G = cosTheta / (dist * dist);
        camState.pdf *= G;
        camState.lightTracePdf *= G;
        if (isDiffuse)
            camState.photonPdf += camState.pdf * gNumLightPaths * M_PI * gPhotonRadius * gPhotonRadius;

        bool hitEmissive = any(bsdfProperties.emission > 0);
        if (hitEmissive) {
            float3 emissive = handleEmissiveHit(sd, prevPos, prevFaceN, camState, hit.getTriangleHit(), bsdfProperties.emission, sd.V) * thp;
            outColor += emissive;
            #if ENABLE_DEBUG
                if (gDebugBounce < 0 || gDebugBounce == i)
                    gDebug[2][DispatchRaysIndex().xy] += float4(emissive, 1);
            #endif
            break;
        }
        // Evaluate Photons
        if (isDiffuse) {
            float3 nee = NextEventEstimation(sd, mi, camState, continuationProb, sg) * thp;
            float3 pm = collectPhotons(sd, mi, bsdfProperties.guideNormal, camState, continuationProb, 0xFF, sg) * thp;
            outColor += nee + pm;
            #if ENABLE_DEBUG
            if (gDebugBounce < 0 || gDebugBounce == (i+1))
            {
                gDebug[1][DispatchRaysIndex().xy] += float4(nee, 1);
                gDebug[3][DispatchRaysIndex().xy] += float4(pm, 1);
            }
            #endif
        }

        validRay = sampleNewRay(sd, mi, bsdfProperties.roughness, continuationProb, sg, thp, camState, ray);
        prevPos = sd.posW;
        prevFaceN = sd.faceN;
    }
   
    return outColor;
}

float3 getLightTraceColor(const uint2 pixel)
{
    //Get color
    float red = asfloat(gLightTraceColor[0][pixel]);
    float green = asfloat(gLightTraceColor[1][pixel]);
    float blue = asfloat(gLightTraceColor[2][pixel]);

    // Reset texture
    gLightTraceColor[0][pixel] = 0;
    gLightTraceColor[1][pixel] = 0;
    gLightTraceColor[2][pixel] = 0;

    return float3(red, green, blue);
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
    float3 viewDir = gView[pixel].xyz;

    float3 outColor = float3(0);
    outColor += getLightTraceColor(pixel);
#if ENABLE_DEBUG
    gDebug[0][pixel] = float4(outColor, 1);
    gDebug[1][pixel] = float4(0);
    gDebug[2][pixel] = float4(0);
    gDebug[3][pixel] = float4(0);
#endif

    if (hitInfo.isValid())
    {
        //Init Camera state with MIS
        CameraState camState = CameraState();
        const float3 camForward = normalize(gScene.camera.data.cameraW);
        const float cosAtCamera = dot(-viewDir, camForward);

        //Get Material Properties
        let lod = ExplicitLodTextureSampler(0);
        SampleGenerator sg = SampleGenerator(pixel, gFrameCount * 2 + 1);

        ShadingData sd = loadShadingData(hitInfo, -viewDir, lod);
        uint hints = (uint)MaterialInstanceHints::AdjustShadingNormal;
        let mi = gScene.materials.getMaterialInstance(sd, lod, hints);
        let bsdfProperties = mi.getProperties(sd);

        // Init MIS
        float3 directionToCamera = gScene.camera.getPosition() - sd.posW;
        float distanceToCamera = length(directionToCamera);
        directionToCamera /= distanceToCamera;
        const float cameraPdf = distanceToCamera * distanceToCamera * gNormalizedPixelArea * pow(cosAtCamera, 3); // Surface to image factor
        camState.lightTracePdf *= cameraPdf;
        float cosTheta = abs(dot(sd.faceN, sd.V));
        float G = cosTheta / (distanceToCamera * distanceToCamera);
        camState.pdf *= G;

        outColor += bsdfProperties.emission; // On first hit, no MIS is necessary if emissive is hit
        #if ENABLE_DEBUG
            if (gDebugBounce < 0 || gDebugBounce == 0)
                gDebug[2][pixel] = float4(bsdfProperties.emission, 1);
        #endif
        bool hitEmissive = any(bsdfProperties.emission > 0);

        if (!hitEmissive) {

            // Evaluate Photons
            float continuationProb = getContinuationProbablity(bsdfProperties);
            bool isDelta = bsdfProperties.roughness <= kRoughnessThreshold;
            camState.firstHitDiffuse = !isDelta;
            if (!isDelta)
            {
                float3 nee = NextEventEstimation(sd, mi, camState, continuationProb, sg);
                outColor += nee;
                #if ENABLE_DEBUG
                    if (gDebugBounce < 0 || gDebugBounce == 0)
                    {
                        gDebug[1][pixel] += float4(nee, 1);
                    }
                #endif
            }
            // Calculate next ray
            float3 thp = float3(1.0);
            RayDesc ray;
            ray.TMin = 0.0;
            ray.TMax = FLT_MAX;
            if (sampleNewRay(sd, mi, bsdfProperties.roughness, continuationProb, sg, thp, camState, ray))
                outColor += tracePath(ray, sd, camState, sg, thp);
        }
    } else {
        outColor += kUseEnvMap ? gScene.envMap.eval(viewDir) : kDefaultBackgroundColor;
    }

    gOutColor[pixel] = float4(outColor, 1);
}
