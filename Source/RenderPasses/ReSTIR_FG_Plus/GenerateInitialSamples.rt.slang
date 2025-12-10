#pragma once
#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.Raytracing;
import Utils.Sampling.SampleGenerator;
import Utils.Color.ColorHelpers;
import Rendering.RTXDI.RTXDI;
import StructsAndHelpers;
import PhotonHelper;

Texture2D<PackedHitInfo> gVBuffer;
Texture2D<float4> gView;

RWStructuredBuffer<ReservoirCaustic> gCausticReservoir;
RWStructuredBuffer<PathReservoir> gPathReservoir;

RWTexture2D<int> gLightTraceHeadCounter;
StructuredBuffer<int> gLightTraceLinkedList; // next pointer

RWTexture2D<float4> gDebug;

static const uint kMIHints = (uint)MaterialInstanceHints::AdjustShadingNormal;
static const uint kCausticInstanceMask = 2;
static const uint kAllPhotonInstanceMask = 0xFF;
static const bool kEvalDeltaPdfs = EVAL_DELTA_PDFS;
static const bool kUseEnvMap = USE_ENV_BACKGROUND;

cbuffer CB
{
    uint gFrameCount; // Frame count since scene was loaded.
    uint gFGRayMaxPathLength; // Max path length for a Final Gather sample
    float gNormalizedPixelArea; //Pixel area at distance 1 used in light trace
}

static const bool kAlphaTest = true;
static const uint kRNGNumPasses = RNG_NUM_PASSES;
static const float kRoughnessThreshold = ROUGHNESS_THRESHOLD;
static const bool kEnableLightTrace = ENABLE_LIGHT_TRACE;

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

//Struct with all needed path data
struct PathData {
    float3 thp;             //Throughput
    float scatterPDF;       //scatter pdf for last hit

    float3 F;               //Accumulated path radiance
    uint pathLength;        //Current path length

    bool lastHitDiffuse;
    bool specularPath;      //True if the full path is specular
    bool firstHitIsDelta;     //True if the first hit is delta (less roughness than threshold)

    __init() {
        thp = float3(1);
        scatterPDF = 0;
        F = float3(0);
        pathLength = 0;
        lastHitDiffuse = true;
        specularPath = true;
        firstHitIsDelta = false;
    }
}


bool sampleNewDirection(ShadingData sd, IMaterialInstance mi, inout SampleGenerator sg, inout PathData pd, inout RayDesc ray) {
    // Photon Bounce for next iteration
    BSDFSample bsdfSample;
    bool validSample = mi.sample(sd, sg, bsdfSample, true /*ImportanceSampling*/);
    if (validSample) {
        bool transmission = bsdfSample.isLobe(LobeType::Transmission);
        bool disableDeltaPdf = bsdfSample.isLobe(LobeType::Delta) && !kEvalDeltaPdfs; // If true uses 1 for pdf
        ray.Origin = sd.computeNewRayOrigin(!transmission); // false is for transmissions
        ray.Direction = bsdfSample.wo;

        pd.thp *= bsdfSample.weight;
        pd.scatterPDF = disableDeltaPdf ? 1.0 : bsdfSample.pdf;
    }
  
    return validSample;
}

/* Add sample to reservoir
    \param[inout] reservoir Reservoir to add the sample to.
    \param[in] rand Random number in [0,1).
    \param[in] rcThp Throughput after reconnection to light source.
    \param[in] thp Throughput until the reconnection surface.
*/
bool addSampleToReservoir(inout PathReservoir reservoir, float rand, float3 radiance, float3 thp)
{
    float3 F = radiance * thp;
    float w = luminance(F);
    reservoir.weight += w;
    bool selectOther = rand * reservoir.weight <= w;
    if (selectOther) {
        reservoir.F = F;
        reservoir.fgRadiance = radiance;
    }
    return selectOther;
}

void tracePath(RayDesc ray, inout SampleGenerator sg, inout SampleGenerator rayDirectionSG, inout PathData pd, inout PathReservoir pathReservoir)
{
    RayPayload rayPayload = RayPayload();
    bool firstHitDiffuse = pd.lastHitDiffuse;
    bool triedToSetFGSurface = false;
    bool isFirstCollectionSurface = true;

    for (pd.pathLength = 1; pd.pathLength <= gFGRayMaxPathLength; pd.pathLength++)
    {
        TraceRay(gScene.rtAccel, 0 /*Flags*/, 0xff /* instanceInclusionMask */, 0 /* hitIdx */, rayTypeCount, 0 /* missIdx */, ray, rayPayload);
        // Get surface hit info
        HitInfo hit = HitInfo(rayPayload.packedHitInfo);
        // Scene miss (evaluate enviroment map). Path Lengh == 1 is covered by ReSTIR DI except the primary hit is delta
        if (!hit.isValid()) {
            if ((pd.pathLength > 1) || (pd.pathLength == 1 && pd.firstHitIsDelta)) {
                float3 envMapContribution = kUseEnvMap ? gScene.envMap.eval(ray.Direction) : float3(0);
                if (addSampleToReservoir(pathReservoir, sampleNext1D(sg), envMapContribution, pd.thp))
                {
                    pathReservoir.jacobian = pd.scatterPDF;
                    uint flags = (uint)ReservoirPathFlags::hasNoReconnectionSurface | (uint)ReservoirPathFlags::isEnvMapHit;
                    flags |= firstHitDiffuse ? 0 : (uint)ReservoirPathFlags::firstHitIsDelta;
                    //flags |= isFirstCollectionSurface ? (uint)ReservoirPathFlags::hasTwoCollectionPoints : 0;
                    pathReservoir.flags.setReservoirPathFlags(flags);
                }
            }
            break;
        }

        // Get shading datas
        let lod = ExplicitLodTextureSampler(0);
        ShadingData sd = loadShadingData(hit, -ray.Direction, lod);
        let mi = gScene.materials.getMaterialInstance(sd, lod, kMIHints);
        let bsdfProperties = mi.getProperties(sd);
        bool hitIsDiffuse = bsdfProperties.roughness > kRoughnessThreshold;
        bool hitIsEmissive = any(bsdfProperties.emission > 0);
        float rayDist = distance(ray.Origin, sd.posW);
        float jacobian = pd.scatterPDF * abs(dot(ray.Direction, sd.faceN)) / (rayDist * rayDist); //Jacobian for this iteration

        // Specular Path -> Emissive. Path Length == 1 is covered by ReSTIR DI except the primary hit is delta
        if ((pd.pathLength > 1 && pd.specularPath) || (pd.pathLength == 1 && pd.firstHitIsDelta)) {
            if (addSampleToReservoir(pathReservoir, sampleNext1D(sg), bsdfProperties.emission, pd.thp))
            {
                pathReservoir.jacobian = jacobian; // Jacobian Path == 1, as all hits are delta/specular
                uint flags = (uint)ReservoirPathFlags::hasNoReconnectionSurface | (uint)ReservoirPathFlags::firstHitIsDelta | (uint)ReservoirPathFlags::isEmissiveHit;
                pathReservoir.flags.setReservoirPathFlags(flags);
                pathReservoir.pathLength = pd.pathLength;
            }
        }

        //Bounces on emissive materials are undefined
        if (hitIsEmissive)
            break;

        // If surface is diffuse do radiance estimate (photon types are depended on the current path state)
        if (hitIsDiffuse) {
            bool isFinalGather = pd.lastHitDiffuse && !triedToSetFGSurface;
            PhotonSample photonSample;
            photonRIS(sd, mi, bsdfProperties.guideNormal, 0xFF, sg, photonSample, !isFinalGather && !triedToSetFGSurface);
            // float3 radianceEstimate = collectPhotons(sd, mi, bsdfProperties.guideNormal, 0xFF, sg, !isFinalGather && !triedToSetFGSurface);
            float3 radianceEstimate = photonSample.radiance * photonSample.weight;
            if (addSampleToReservoir(pathReservoir, sampleNext1D(sg), radianceEstimate, pd.thp) && photonSample.approxRadiance > 0) {
                pathReservoir.pathLength = isFinalGather ? pd.pathLength - 1 : pd.pathLength;
                pathReservoir.jacobian = jacobian;
                uint flags = 0;
                if (isFinalGather) {
                    flags |= (uint)ReservoirPathFlags::isFinalGather;
                    pathReservoir.fgRadiance = radianceEstimate;
                    pathReservoir.samplePosW = sd.posW;
                    pathReservoir.sampleNormal = sd.faceN;
                }
                else {
                    flags |= (uint)ReservoirPathFlags::hasNoReconnectionSurface | (uint)ReservoirPathFlags::isRadianceEstimate;
                    pathReservoir.fgRadiance = radianceEstimate;
                    pathReservoir.samplePosW = photonSample.posW;
                    pathReservoir.sampleNormal = photonSample.normal;
                    pathReservoir.sampleRadius = photonSample.radius;
                }
                flags |= firstHitDiffuse ? 0 : (uint)ReservoirPathFlags::firstHitIsDelta;
                pathReservoir.flags.setReservoirPathFlags(flags);
            }

            //We always stop at this point
            if (isFinalGather || triedToSetFGSurface)
                break;

            isFirstCollectionSurface = false;
        }

        triedToSetFGSurface |= pd.lastHitDiffuse;    //If 1 diffuse surface was encountered, it was tried to set the Final Gather surface
        pd.lastHitDiffuse = hitIsDiffuse;
        pd.specularPath &= !hitIsDiffuse;

        // Calc new ray direction
        if (!sampleNewDirection(sd, mi, rayDirectionSG, pd, ray)) {            
            break;
        }
    }

    //Finalize Reservoir
    if (any(pathReservoir.F > 0))
        pathReservoir.weight /= luminance(pathReservoir.F);
}

//
//Caustics
//

void photonResampling(ShadingData sd, BSDFProperties bsdfProperties, bool collectGlobalDirect, inout ReservoirCaustic causticReservoir, inout SampleGenerator sg) {
    // Prepare ray
    RayDesc ray;
    ray.Origin = sd.posW;
    ray.Direction = sd.faceN;
    ray.TMin = 0;
    ray.TMax = kPhotonCollectTMax;

    RayQuery<RAY_FLAG_NONE> rayQuery;
    uint instanceMask = collectGlobalDirect ? 0xFF : 2; // 2 is caustic only

    rayQuery.TraceRayInline(gPhotonAS, RAY_FLAG_NONE, instanceMask, ray);
    while (rayQuery.Proceed()) {

        if (rayQuery.CandidateType() != CANDIDATE_PROCEDURAL_PRIMITIVE)
            continue;
        const uint instanceIdx = rayQuery.CandidateInstanceIndex();
        const uint primIdx = rayQuery.CandidatePrimitiveIndex();
        PhotonType type = (PhotonType)instanceIdx;
        // Check if ray is inside photon radius
        AABB photonAABB = gPhotonAABB[instanceIdx][primIdx];
        float radius = (photonAABB.maxPoint.x - photonAABB.minPoint.x) / 2.0;
        float3 center = photonAABB.center();
        if (!hitSphere(center, radius, sd.posW))
            continue;

        PhotonData photonData = gPhotonData[instanceIdx][primIdx];

        // If direct global photons should be collected and the photon is global, check the path length
        if (collectGlobalDirect && (type == PhotonType::Global)) {
            if (photonData.pathLenght > 0)
                continue;
        }

        float NdotL = dot(photonData.dir, bsdfProperties.guideNormal);
        // Check for diffent surfaces (e.g. corners)
        if ((dot(photonData.normalW, sd.getOrientedFaceNormal()) < 0.6) || (NdotL <= 0))
            continue;

        float targetFunction = 0;
        if (NdotL > 0)
            targetFunction = evalApproximateBRDFPhoton(sd, bsdfProperties, photonData.dir) * luminance(photonData.flux);
        float photonDenom = M_PI * radius * radius;
        float w = targetFunction / photonDenom;

        causticReservoir.wSum += w;
        bool selectNew = (sampleNext1D(sg) * causticReservoir.wSum) < w;
        if (selectNew) {
            causticReservoir.photonPosW = center;
            causticReservoir.photonDir = photonData.dir;
            causticReservoir.photonRadiance = photonData.flux;
            causticReservoir.targetFunction = targetFunction;
        }
    }

    // Finalize Reservoir
    if (causticReservoir.targetFunction > 0) {
        causticReservoir.wSum /= causticReservoir.targetFunction;
    }
    else
        causticReservoir.wSum = 0;
    causticReservoir.c = 1;
}

void lightTraceResampling(uint2 pixel, inout ReservoirCaustic r , inout SampleGenerator sg)
{
    float3 outColor = float3(0);
    r.c = 1;
    // Get head buffer index
    int headIndex = gLightTraceHeadCounter[pixel];
    if (headIndex == -1)
        return;

    let lod = ExplicitLodTextureSampler(0);

    uint count = 0;
    while (headIndex != -1)
    {
        // Get Photon Data
        PhotonData photonData = gPhotonData[1][headIndex];
        HitInfo photonHit = HitInfo(photonData.hitInfo);

        ShadingData sd = loadShadingData(photonHit, photonData.dir, lod);
        let mi = gScene.materials.getMaterialInstance(sd, lod, kMIHints);

        float3 directionToCamera = gScene.camera.getPosition() - sd.posW;
        float distanceToCamera = length(directionToCamera);
        directionToCamera /= distanceToCamera;

        // Camera pdf
        const float3 camForward = normalize(gScene.camera.data.cameraW);
        const float cameraPdf = getCameraBackprojectPDF(directionToCamera, distanceToCamera, camForward, gNormalizedPixelArea);

        const float3 bsdf = mi.eval(sd, directionToCamera, sg);

        float targetFunction = luminance(photonData.flux * bsdf);
        float w = targetFunction / cameraPdf;

        r.wSum += w;
        bool selectNew = (sampleNext1D(sg) * r.wSum) < w;
        if (selectNew) {
            r.sampleSurface = photonData.hitInfo;
            r.sampleSurfaceView = photonData.dir;
            r.photonPosW = sd.posW;
            r.photonDir = photonData.dir;
            r.photonRadiance = photonData.flux;
            r.targetFunction = targetFunction;
            r.subPixelJacobian = getSubpixelLocationJacobian(distanceToCamera, directionToCamera, sd.faceN, camForward);
        }

        // Update head index
        int newHeadIndex = gLightTraceLinkedList[headIndex];
        headIndex = newHeadIndex;
    }

    // Finalize Reservoir
    if (r.targetFunction > 0) {
        r.wSum /= r.targetFunction;
    }
    else
        r.wSum = 0;

}

[shader("miss")]
void miss(inout RayPayload rayData: SV_RayPayload)
{
    HitInfo hitInfo = {};
    rayData.packedHitInfo = hitInfo.getData(); // Invalid hit
}

//For alpha test
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
    ReservoirCaustic causticReservoir = ReservoirCaustic();
    PathReservoir pathReservoir = PathReservoir();

    if (hitInfo.isValid()) {
        //Set RTXDI data
        let lod = ExplicitLodTextureSampler(0);
        SampleGenerator sg = SampleGenerator(pixel, gFrameCount * kRNGNumPasses + 2);
        SampleGenerator pathDirSG = SampleGenerator(pixel, gFrameCount * kRNGNumPasses + 3); // Sample generator for sampling new directions
        pathReservoir.sgPathDirections = pathDirSG;

        ShadingData sd = loadShadingData(hitInfo, viewDir, lod);
        let mi = gScene.materials.getMaterialInstance(sd, lod, kMIHints);
        let bsdfProperties = mi.getProperties(sd);
        float distanceToSurface = distance(sd.posW, gScene.camera.getPosition());
        PathData pd = PathData();

        //Set ReSTIR DI surface data
        gRTXDI.setSurfaceData(pixel, sd.computeNewRayOrigin(), bsdfProperties.guideNormal, bsdfProperties.diffuseReflectionAlbedo, bsdfProperties.specularReflectance, bsdfProperties.roughness, distanceToSurface);

        // Handle Caustics on direct hit
        pd.lastHitDiffuse = bsdfProperties.roughness > kRoughnessThreshold;
        // Init Caustic reservoir if photons can be collected at the current surface
        if (pd.lastHitDiffuse) {
            causticReservoir.sampleSurface = hitInfo.getData();
            causticReservoir.sampleSurfaceView = viewDir;
            if (kEnableLightTrace)
                lightTraceResampling(pixel, causticReservoir, sg);
            else
                photonResampling(sd, bsdfProperties, false, causticReservoir, sg);
        }

        pathReservoir.flags.firstHitIsDelta = !pd.lastHitDiffuse;
        pd.specularPath &= !pd.lastHitDiffuse;
        pd.firstHitIsDelta = bsdfProperties.roughness <= 0.08;

        RayDesc ray = {};
        ray.TMin = 0;
        ray.TMax = FLT_MAX;
        if (sampleNewDirection(sd, mi, pathDirSG, pd, ray))
            tracePath(ray, sg, pathDirSG, pd, pathReservoir);

    } else {
        // Set invalid RTXDI data
        gRTXDI.setInvalidSurfaceData(pixel);
    }

    gPathReservoir[index2Dto1D(pixel, dispatchDims.x)] = pathReservoir;
    gCausticReservoir[index2Dto1D(pixel, dispatchDims.x)] = causticReservoir;
    if (kEnableLightTrace)
        gLightTraceHeadCounter[pixel] = -1; //Set to invalid
}
