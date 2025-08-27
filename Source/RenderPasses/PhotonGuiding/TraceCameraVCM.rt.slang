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

StructuredBuffer<PhotonDataVCM> gPhotonData;
StructuredBuffer<AABB> gPhotonAABB;
RaytracingAccelerationStructure gPhotonAS;

RWTexture2D<uint> gLightTraceColor[3]; // Uint spinlock color texture for every channel

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
}

static const float kPhotonCollectTMax = 1e-7;
static const bool kUseEnvMap = USE_ENV_MAP;
static const bool kAlphaTest = true;
static const float kRoughnessThreshold = ROUGHNESS_THRESHOLD;
static const float3 kDefaultBackgroundColor = float3(0.01);

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
    float dVCM;
    float dVM;
    float dVC;
    float misVcWeightFactor;
    float misVmWeightFactor;
    bool isSpecularPath;

    __init() {
        pathLength = 0;
        dVCM = 0.0;
        dVC = 0.0;
        dVM = 0.0;
        misVcWeightFactor = 0.0;
        misVmWeightFactor = 0.0;
        isSpecularPath = true;
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
        const uint primIdx = rayQuery.CandidatePrimitiveIndex();

        // Check if ray is inside photon radius
        AABB photonAABB = gPhotonAABB[primIdx];

        if (!hitSphere(photonAABB.center(), gPhotonRadius, sd.posW))
            continue;

        PhotonDataVCM photonData = gPhotonData[primIdx];
        float NdotL = dot(photonData.dir, N);
        // Check for diffent surfaces (e.g. corners)
        if ((dot(photonData.normalW, sd.faceN) < 0.6) || (NdotL <= 0) || (camState.pathLength + photonData.pathLenght) > (gMaxBounces + 1))
            continue;

        float pdf = mi.evalPdf(sd, photonData.dir);
        float reversePDF = mi.evalPdf(sd, photonData.dir, sd.V);
        pdf *= continuationProb;
        reversePDF *= photonData.continationProb; // For the reverse pdf
        const float misVcWeightFactorCamera = camState.misVcWeightFactor; // camState.pathLength >= 1 ? 0 : camState.misVcWeightFactor;
        const float misVcWeightFactorLight = camState.misVcWeightFactor; //photonData.pathLenght >= 1 ? 0 : camState.misVcWeightFactor;

        const float wLight = photonData.dVCM * misVcWeightFactorLight + photonData.dVM * pdf;
        const float wCamera = camState.dVCM * misVcWeightFactorCamera + camState.dVM * reversePDF;
        const float misWeight = 1.0 / (wLight + 1.0 + wCamera);

        float3 bsdf = mi.eval(sd, photonData.dir, sg);
        collectedRadiance += max(0, (photonData.flux * bsdf * misWeight) / NdotL); // NdotL needs to be taken out of the bsdf for Photon Mapping
    }
    const float photonWeight = 1.0 / (gPhotonRadius * gPhotonRadius * M_PI * gNumLightPaths);
    collectedRadiance *= photonWeight;
    //if (camState.pathLength != 1)
    //    return float3(0);
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

    float pdf = bsdfSample.pdf;
    float reversePdf = mi.evalPdf(sd, ray.Direction, sd.V);

    //Russian Roulette
    if (sampleNext1D(sg) > continuationProbability)
        return false;

    thp /= continuationProbability;
    pdf *= continuationProbability;
    reversePdf *= continuationProbability;
    float cosThetaOut = abs(dot(sd.faceN, ray.Direction));
    //Specular
    if (roughness < kRoughnessThreshold) {
        camState.dVCM = 0;
        camState.dVC *= cosThetaOut;
        camState.dVM *= cosThetaOut;
    } else {
        camState.dVC = (cosThetaOut / pdf) * (camState.dVC * reversePdf) + (camState.dVCM + camState.misVmWeightFactor);
        camState.dVM = (cosThetaOut / pdf) * (camState.dVM * reversePdf) + (camState.dVCM * camState.misVcWeightFactor + 1.0);
        camState.dVCM = 1.0 / pdf;
        camState.isSpecularPath = false;
    }
    camState.pathLength++;

    return true;
}

float3 handleEmissiveHit(ShadingData sd, float3 prevPos, float3 prevNormal,CameraState camState, TriangleHit triangleHit, float3 emission, float3 incomingDir)
{
    if (!kUseVC && kUseVM)
        return emission;

    uint lightPickProb = 1.0 / gScene.lightCollection.getActiveTriangleCount();
    uint lightTriIndex = gScene.lightCollection.getTriangleIndex(triangleHit.instanceID, triangleHit.primitiveIndex);
    const EmissiveTriangle emissiveTri = gScene.lightCollection.getTriangle(lightTriIndex);

    TriangleLightHit hit;
    hit.triangleIndex = lightTriIndex;
    hit.posW = sd.posW;
    hit.normalW = sd.getOrientedFaceNormal();

    float directPdf = gEmissiveSampler.evalPdf(prevPos, prevNormal, true, hit);

    float emissionPdf = abs(dot(emissiveTri.normal, -incomingDir)) * M_1_PI;
    emissionPdf *= directPdf;

    const float wCamera = directPdf * camState.dVCM + emissionPdf * camState.dVC;
    const float misWeight = 1.0 / (1.0 + wCamera);
    return emission * misWeight;
}

float3 NextEventEstimation(ShadingData sd, IMaterialInstance mi ,CameraState camState, float continuationProb , inout SampleGenerator sg)
{
    TriangleLightSample tls = {};
    if (!gEmissiveSampler.sampleLight(sd.posW, sd.faceN, true, sg, tls))
        return float3(0);

    // Get emission pdf
    const EmissiveTriangle emissiveTri = gScene.lightCollection.getTriangle(tls.triangleIndex);
    float cosAtLight = dot(emissiveTri.normal, sd.V);
    const float emissionPdf = (cosAtLight * M_1_PI) / (emissiveTri.area * gScene.lightCollection.getActiveTriangleCount());
    const float directPdf = tls.pdf; //Multiplied with activeTriangle count 

    float3 bsdf = mi.eval(sd, tls.dir, sg);

    if (all(bsdf <= 0) || directPdf <= 0)
        return float3(0);

    SceneRayQuery<1> rayQuery;
    const Ray ray = Ray(sd.computeNewRayOrigin(), tls.dir, 0.f, tls.distance * 0.98);
    if (!rayQuery.traceVisibilityRay(ray, RAY_FLAG_NONE, 0xff))
        return float3(0);

    float cosToLight = dot(sd.faceN, tls.dir);
    float pdf = mi.evalPdf(sd, tls.dir) * continuationProb;
    float reversePDF = mi.evalPdf(sd, tls.dir, sd.V) * continuationProb;

    const float wLight = pdf / directPdf;
    const float wCamera = ((emissionPdf * cosToLight) / (directPdf * cosAtLight)) * (camState.misVmWeightFactor + camState.dVCM + camState.dVC * reversePDF);

    const float misWeight = 1.0 / (wLight + 1.0 + wCamera);

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

        // Update Mis
        float dist = distance(ray.Origin, sd.posW);
        float cosTheta = abs(dot(sd.faceN, sd.V));
        camState.dVCM *= dist*dist;
        camState.dVCM /= cosTheta;
        camState.dVC /= cosTheta;
        camState.dVM /= cosTheta;

        bool hitEmissive = any(bsdfProperties.emission > 0);
        if (hitEmissive) {
            if(kUseVC || (kUseVM && camState.isSpecularPath)) //TODO add emissive after specular hit for VM
                outColor += handleEmissiveHit(sd, prevPos, prevFaceN, camState, hit.getTriangleHit(), bsdfProperties.emission, sd.V) * thp;
            break;
        }
        // Evaluate Photons
        if (bsdfProperties.roughness > kRoughnessThreshold) {
            if(kUseVC)
                outColor += NextEventEstimation(sd, mi, camState, continuationProb, sg) * thp;
            if(kUseVM)
                outColor += collectPhotons(sd, mi, bsdfProperties.guideNormal, camState, continuationProb, 0xFF, sg) * thp;
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

    if (hitInfo.isValid()) {
        // Init camera state for MIS
        CameraState camState = CameraState();
        const float3 camForward = normalize(gScene.camera.data.cameraW);
        const float cosAtCamera = dot(-viewDir, camForward);
        const float imagePointToCameraDist = gImagePlaneDist / cosAtCamera;
        //const float imageToSolidAngleFactor = (imagePointToCameraDist * imagePointToCameraDist) / cosAtCamera;
        //const float cameraPdf = imageToSolidAngleFactor;
        //Camera pdf at distance 1
        const float surfaceToImageFactor = gNormalizedPixelArea * pow(cosAtCamera, 3);
        const float cameraPdf = 1.0 / surfaceToImageFactor; //technically 1/pdf
        camState.dVCM = float(gNumLightPaths) / cameraPdf;
        camState.dVC = 0;
        camState.dVM = 0;
        const float etaVCM = (M_PI * gPhotonRadius * gPhotonRadius) * gNumLightPaths;
        camState.misVmWeightFactor = kUseVM ?  etaVCM : 0.0;
        camState.misVcWeightFactor = kUseVC ? (1.0 / etaVCM) : 0.0; //Maybe this needs to be 0 if no light tracing is used

        //Get Material Properties
        let lod = ExplicitLodTextureSampler(0);
        SampleGenerator sg = SampleGenerator(pixel, gFrameCount * 2 + 1);

        ShadingData sd = loadShadingData(hitInfo, -viewDir, lod);
        uint hints = (uint)MaterialInstanceHints::AdjustShadingNormal;
        let mi = gScene.materials.getMaterialInstance(sd, lod, hints);
        let bsdfProperties = mi.getProperties(sd);

        // Finalize MIS factors (dVM and dVC are 0 for the first hit)
        float cosTheta = abs(dot(sd.faceN, viewDir));
        float dist = distance(gScene.camera.getPosition(), sd.posW);
        camState.dVCM *= dist * dist;
        camState.dVCM /= cosTheta;
        //camState.dVM /= cosTheta; //Are 0
        //camState.dVC /= cosTheta; //Are 0

        outColor += bsdfProperties.emission; //On first hit, no MIS is necessary if emissive is hit
        bool hitEmissive = any(bsdfProperties.emission > 0);

        if (!hitEmissive && !kLightTraceOnly) {

            // Evaluate Photons
            float continuationProb = getContinuationProbablity(bsdfProperties);
            if (bsdfProperties.roughness > kRoughnessThreshold)
            {
                if(kUseVC)
                    outColor += NextEventEstimation(sd, mi, camState, continuationProb, sg);
                if(kUseVM)
                    outColor += collectPhotons(sd, mi, bsdfProperties.guideNormal, camState, continuationProb,  0xFF, sg);
            }

            // Calculate next ray
            float3 thp = float3(1.0);
            RayDesc ray;
            ray.TMin = 0.0;
            ray.TMax = FLT_MAX;
            if (sampleNewRay(sd, mi, bsdfProperties.roughness, continuationProb, sg, thp, camState, ray))
                outColor += tracePath(ray, sd, camState, sg, thp);
        }
    } else
    {
        outColor += kUseEnvMap ? gScene.envMap.eval(viewDir) : kDefaultBackgroundColor;
    }

    gOutColor[pixel] = float4(outColor, 1);
}
