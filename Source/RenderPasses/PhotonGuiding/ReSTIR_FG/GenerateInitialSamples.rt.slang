#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.Raytracing;
import Utils.Sampling.SampleGenerator;
import Utils.Color.ColorHelpers;
import Utils.Math.MathHelpers;
import Rendering.Lights.LightHelpers;
import Rendering.Lights.EmissiveLightSampler;
import Rendering.Lights.EmissiveLightSamplerHelpers;
import RenderPasses.PhotonGuiding.PhotonHelper;
import RenderPasses.PhotonGuiding.StructsAndHelpers;
import RenderPasses.PhotonGuiding.SharedEnums;
import RenderPasses.PhotonGuiding.NextEventEstimationHelper;
import Rendering.RTXDI.RTXDI;

Texture2D<PackedHitInfo> gVBuffer;

RWStructuredBuffer<ReservoirFG> gFinalGatherReservoir;
RWStructuredBuffer<PathReservoir> gPathReservoir;
RWStructuredBuffer<ReservoirCaustic> gCausticReservoir;
RWTexture2D<float4> gEmission;

RWTexture2D<int> gLightTraceHeadCounter;
StructuredBuffer<int> gLightTraceLinkedList; // next pointer
StructuredBuffer<PackedHitInfo> gCausticPhotonHitInfo;

cbuffer CB
{
    uint gFrameCount; // Frame count since scene was loaded.
    uint gFGRayMaxPathLength; // Max path length for a Final Gather sample
    uint gNumLightPaths;      // For photon weight
    float gNormalizedPixelArea; // Pixel area at distance 1 used in light trace

    float gJacobianDistanceThreshold; // Jacobian distance threshold for path ReSTIR FG
    float3 gNeeLightSelectProb;       // Light Selection probabilities for NEE
}

static const uint kMIHints = (uint)MaterialInstanceHints::AdjustShadingNormal;
static const bool kAlphaTest = true;
static const float kRoughnessThreshold = ROUGHNESS_THRESHOLD;
static const bool kEnableLightTraceSplatting = ENABLE_LIGHT_TRACE_SPATTING;
static const uint kEnableRandomReplay = ENABLE_RANDOM_REPLAY;
static const bool kUseEnvMap = USE_ENV_BACKGROUND;
static const bool kUseEnvLight = USE_ENV_LIGHT;
static const bool kEvalDeltaPdfs = EVAL_DELTA_PDFS;
static const uint kRNGNumPasses = RNG_NUM_PASSES;
static const bool kUseNEEForPathReservoirs = PATH_RESERVOIR_USE_NEE;
static const bool kStopPathAfterDiffuseSpecular = PATH_RESERVOIR_STOP_PATH_AFTER_DIFFUSE_SPECULAR;
static const bool kUseNeeAtFGHit = USE_NEE_AT_FG_HIT;

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

// Struct with all needed path data
struct PathData {
    float3 thp;       // Throughput
    float scatterPDF; // scatter pdf for last hit

    float3 F;        // Accumulated path radiance
    uint pathLength; // Current path length

    bool lastHitDiffuse;
    bool specularPath;    // True if the full path is specular
    bool firstHitIsDelta; // True if the first hit is delta (less roughness than threshold)

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

bool addSampleToPathReservoir(inout PathReservoir reservoir, float rand, float3 radiance, float3 thp)
{
    float3 F = radiance * thp;
    float w = luminance(F);
    reservoir.weight += w;
    bool selectOther = rand * reservoir.weight <= w;
    if (selectOther) {
        reservoir.F = F;
        reservoir.photonFlux = radiance;
    }
    return selectOther;
}

bool sampleNewDirection(ShadingData sd, IMaterialInstance mi, inout SampleGenerator sg, inout PathData pd, inout RayDesc ray) {
    // Photon Bounce for next iteration
    BSDFSample bsdfSample;
    bool validSample = mi.sample(sd, sg, bsdfSample, true /*ImportanceSampling*/);
    if (validSample) {
        bool transmission = bsdfSample.isLobe(LobeType::Transmission);
        bool disableDeltaPdf = bsdfSample.isLobe(LobeType::Delta) && !kEvalDeltaPdfs; // If true uses 1 for pdf
        ray.Origin = sd.computeNewRayOrigin(!transmission);                           // false is for transmissions
        ray.Direction = bsdfSample.wo;

        pd.thp *= bsdfSample.weight;
        pd.scatterPDF = disableDeltaPdf ? 1.0 : bsdfSample.pdf;
    }

    return validSample;
}

bool traceFGRay(RayDesc ray, inout SampleGenerator sg, inout PathData pd, inout ReservoirFG reservoirFG, inout ReservoirCaustic reservoirCaustic, inout float3 emission, inout float mVecDistance) {
    RayPayload rayPayload = RayPayload();
    uint pathLength = 0;
    bool collectCaustics = !pd.lastHitDiffuse;
    float3 prevThp = float3(1); //Needed for reservoir
    for (pathLength; pathLength < gFGRayMaxPathLength; pathLength++) {
        TraceRay(gScene.rtAccel, 0 /*Flags*/, 0xff /* instanceInclusionMask */, 0 /* hitIdx */, rayTypeCount, 0 /* missIdx */, ray, rayPayload);
        // Get surface hit info
        HitInfo hit = HitInfo(rayPayload.packedHitInfo);
        if (!hit.isValid()) {
            //TODO add valid reservoir if envMap was hit?
            return false;
        }

        // Get shading infos
        let lod = ExplicitLodTextureSampler(0);

        // Get Material properties
        uint hints = (uint)MaterialInstanceHints::AdjustShadingNormal;
        ShadingData sd = loadShadingData(hit, ray.Direction, lod);
        let mi = gScene.materials.getMaterialInstance(sd, lod, hints);
        let bsdfProperties = mi.getProperties(sd);
        bool hitIsDiffuse = bsdfProperties.roughness > kRoughnessThreshold;

        // Emissive hits are undefined for final gather rays
        if (any(bsdfProperties.emission > 0) || (pd.lastHitDiffuse && !hitIsDiffuse))
        {
            if (collectCaustics && pd.firstHitIsDelta) // Path is completely specular 
                emission += bsdfProperties.emission * pd.thp;
            break;
        }

        //Travel distance for mvec (collect Caustic flag can be reused)
        if (collectCaustics)
            mVecDistance += distance(sd.posW, ray.Origin);

        if (collectCaustics && hitIsDiffuse) {
            reservoirCaustic.sampleSurface = hit.getData();
            reservoirCaustic.sampleSurfaceView = ray.Direction;
            reservoirCaustic.pathLength = pathLength + 1;
            reservoirCaustic.thp = pd.thp;
            photonResampling(sd, bsdfProperties, true, gNumLightPaths ,reservoirCaustic, sg);
            collectCaustics = false;
        }

        // Check if this is a valid final gather surface
        if (hitIsDiffuse && pd.lastHitDiffuse) {
            // Collect photons and fill reservoir
            /* //(Old Method) collect over radiance estimate
            if (kGuidingMode == (uint)GuidingMode::Disabled && kLightIndexGuidingMode == (uint)GuidingMode::Disabled)
            {
                reservoirFG.sampleData.radianceOut = collectPhotons(sd, mi, bsdfProperties.guideNormal, 0xFF, sg);
                reservoirFG.thp = prevThp;
                reservoirFG.sampleData.posW = sd.posW;
                reservoirFG.sampleData.normal = sd.faceN;
                reservoirFG.wSum = 1.0 / pdf;
                reservoirFG.c = 1;
                float distanceToSample = distance(ray.Origin, sd.posW);
                reservoirFG.jacobianDeterminant = dot(reservoirFG.sampleData.normal, sd.V) / (distanceToSample * distanceToSample);
            } else
            */ //Select 1 respresentative photon
            {
                selectFGSample(reservoirFG, pd.scatterPDF, sd, mi, bsdfProperties.guideNormal, 0xFF, gNumLightPaths, sg);
                reservoirFG.thp = prevThp;
                reservoirFG.sampleData.posW = sd.posW;
                reservoirFG.sampleData.normal = sd.faceN; 
                reservoirFG.c = 1;
                float distanceToSample = distance(ray.Origin, sd.posW);
                reservoirFG.jacobianDeterminant = dot(reservoirFG.sampleData.normal, sd.V) / (distanceToSample * distanceToSample);
            }
           
            return true;
        }

        //Update reservoir
        reservoirFG.sampleSurface = hit.getData(); // Update surface
        reservoirFG.pathLength++;                  // Increase path length
        reservoirFG.sampleData.sampleView = -ray.Direction;
        prevThp = pd.thp;

        pd.lastHitDiffuse = hitIsDiffuse;

        //Next ray
        if (!sampleNewDirection(sd, mi, sg, pd, ray))
            break;
    }
    return false;
}

//Path for Path Reservoirs
void tracePath(RayDesc ray, float3 prevFaceN , inout SampleGenerator sg, inout SampleGenerator rayDirectionSG, inout PathData pd, inout PathReservoir pathReservoir)
{
    RayPayload rayPayload = RayPayload();
    bool firstHitDiffuse = pd.lastHitDiffuse;
    bool lastHitUseNEE = false;      //If NEE was used, Enviroment Map hits and Emissive hits needs to be evaluated for MIS
    bool isFirstCollectionSurface = true;
    float3 prevPosW = ray.Origin;

    for (pd.pathLength = 1; pd.pathLength <= gFGRayMaxPathLength; pd.pathLength++)
    {
        TraceRay(gScene.rtAccel, 0 /*Flags*/, 0xff /* instanceInclusionMask */, 0 /* hitIdx */, rayTypeCount, 0 /* missIdx */, ray, rayPayload);
        // Get surface hit info
        HitInfo hit = HitInfo(rayPayload.packedHitInfo);
        // Scene miss (evaluate enviroment map). Path Lengh == 1 is covered by ReSTIR DI except the primary hit is delta
        if (!hit.isValid()) {
            if ((pd.pathLength > 1) || (pd.pathLength == 1 && pd.firstHitIsDelta) || lastHitUseNEE) {
                float misWeight = 1.0;
                if (kUseEnvLight && pd.lastHitDiffuse) {
                    float lightPdf = gNeeLightSelectProb[kNeeLightTypeEnvMap] * gEnvMapSampler.evalPdf(ray.Direction);
                    misWeight = evalMIS(1, pd.scatterPDF, 1, lightPdf);
                }
                float3 envMapContribution = kUseEnvMap ? gScene.envMap.eval(ray.Direction) * misWeight : float3(0);
                if (addSampleToPathReservoir(pathReservoir, sampleNext1D(sg), envMapContribution, pd.thp))
                {
                    pathReservoir.jacobian = pd.scatterPDF;
                    uint flags = (uint)ReservoirPathFlags::hasNoReconnectionSurface | (uint)ReservoirPathFlags::isEnvMapHit;
                    flags |= firstHitDiffuse ? 0 : (uint)ReservoirPathFlags::firstHitIsDelta;
                    // flags |= isFirstCollectionSurface ? (uint)ReservoirPathFlags::hasTwoCollectionPoints : 0;
                    pathReservoir.flags.setReservoirPathFlags(flags);
                }
            }
            break;
        }

        // Get shading datas
        let lod = ExplicitLodTextureSampler(0);
        ShadingData sd = loadShadingData(hit, ray.Direction, lod);
        let mi = gScene.materials.getMaterialInstance(sd, lod, kMIHints);
        let bsdfProperties = mi.getProperties(sd);
        float rayDist = distance(ray.Origin, sd.posW);
        bool jacobianDistanceThreshold = rayDist > gJacobianDistanceThreshold;
        bool hitIsDiffuse = bsdfProperties.roughness > kRoughnessThreshold && jacobianDistanceThreshold;
        bool hitIsEmissive = any(bsdfProperties.emission > 0);
        float jacobian = pd.scatterPDF * abs(dot(ray.Direction, sd.faceN)) / (rayDist * rayDist); // Jacobian for this iteration

        // Specular Path -> Emissive. Path Length == 1 is covered by ReSTIR DI except the primary hit is delta
        if ((pd.pathLength > 1 && pd.specularPath) || (pd.pathLength == 1 && pd.firstHitIsDelta) || lastHitUseNEE) {
            float misWeight = 1.0;
            float neeEmissiveProbability = gNeeLightSelectProb[kNeeLightTypeEmissive];
            if(neeEmissiveProbability > 0 && pd.lastHitDiffuse)
            {
                // Get hit in light collection representation
                TriangleHit triangleHit = hit.getTriangleHit();
                TriangleLightHit lightHit;
                lightHit.triangleIndex = gScene.lightCollection.getTriangleIndex(triangleHit.instanceID, triangleHit.primitiveIndex);
                lightHit.posW = sd.posW;
                lightHit.normalW = sd.getOrientedFaceNormal();
                float neePDF = neeEmissiveProbability * gEmissiveSampler.evalPdf(prevPosW, prevFaceN, true, lightHit);
                misWeight = evalMIS(1.0, pd.scatterPDF, 1.0, neePDF);
            }

            float3 emissiveContribution = bsdfProperties.emission * misWeight;
            if (addSampleToPathReservoir(pathReservoir, sampleNext1D(sg), emissiveContribution, pd.thp))
            {
                pathReservoir.jacobian = jacobian; // Jacobian Path == 1, as all hits are delta/specular
                uint flags = (uint)ReservoirPathFlags::hasNoReconnectionSurface | (uint)ReservoirPathFlags::firstHitIsDelta | (uint)ReservoirPathFlags::isEmissiveHit;
                pathReservoir.flags.setReservoirPathFlags(flags);
                pathReservoir.pathLength = pd.pathLength;
            }
        }

        // Stop on emissive hits (reflections are undefined) or when first diffuse -> specular bounce if the setting is enabled
        if (hitIsEmissive || (kStopPathAfterDiffuseSpecular && !hitIsDiffuse && pd.lastHitDiffuse))
            break;

        // If surface is diffuse do radiance estimate (photon types are depended on the current path state)
        if (hitIsDiffuse) {
            const bool isFinalGather = pd.lastHitDiffuse; // If the last two hits are diffuse, the hit is a final gather surface
            PhotonSample photonSample;
            int photonHitType = -1;
            if (kUseNEEForPathReservoirs)
                photonHitType = photonRIS(sd, mi, bsdfProperties.guideNormal, isFinalGather ? 0xFF : 0x02, gNumLightPaths, sg, photonSample, false);
            else
                photonHitType = photonRIS(sd, mi, bsdfProperties.guideNormal, 0xFF, gNumLightPaths, sg, photonSample, !isFinalGather);

            float3 radianceEstimate = photonSample.radiance * photonSample.weight;
            if (addSampleToPathReservoir(pathReservoir, sampleNext1D(sg), radianceEstimate, pd.thp) && photonSample.approxRadiance > 0) {
                pathReservoir.pathLength = isFinalGather ? pd.pathLength - 1 : pd.pathLength;
                pathReservoir.jacobian = jacobian;
                pathReservoir.guidingPixels = photonSample.guidingPixels;
                pathReservoir.lightIndex = photonSample.lightIndex;
                pathReservoir.photonGuidingPdf = photonSample.weight / photonSample.guidingPdf; 
                uint flags = 0;
                if (photonHitType == kPhotonCausticBufferIndex)
                    flags |= (uint)ReservoirPathFlags::isCausticPhoton;
                #if ENABLE_PHOTON_RETRACING
                    PhotonRetraceData photonRetraceData = PhotonRetraceData();
                    photonRetraceData.startPixelPathLengthData = photonSample.packedStartPixelAndPathLength;
                    photonRetraceData.startSeed = getStartSeedPhotonDirSG(gFrameCount, kRNGNumPasses);
                    pathReservoir.photonRetraceData = photonRetraceData;
                #endif
                
                if (isFinalGather) {
                    flags |= (uint)ReservoirPathFlags::isFinalGather;
                    pathReservoir.samplePosW = sd.posW;
                    pathReservoir.sampleNormal = sd.faceN;
                    pathReservoir.sampleRadius = photonSample.radius;
                }
                else {
                    flags |= (uint)ReservoirPathFlags::hasNoReconnectionSurface | (uint)ReservoirPathFlags::isRadianceEstimate;
                    pathReservoir.samplePosW = photonSample.posW;
                    pathReservoir.sampleNormal = photonSample.normal;
                    pathReservoir.sampleRadius = photonSample.radius;
                }
                flags |= firstHitDiffuse ? 0 : (uint)ReservoirPathFlags::firstHitIsDelta;
                pathReservoir.flags.setReservoirPathFlags(flags);
            }

            // Next event estimation after specular hits used for direct light
            if ((kUseNEEForPathReservoirs && !isFinalGather) || kUseNeeAtFGHit) {
                SampleGenerator neeSgState = sg; // Cache sampleGenerator state
                LightSample ls;
                float3 nee = nextEventEstimation(sd, mi, gNeeLightSelectProb, ls, sg);
                if (addSampleToPathReservoir(pathReservoir, sampleNext1D(sg), nee, pd.thp))
                {
                    pathReservoir.sgNeeLightSelection = neeSgState; // Store cached sg state
                    pathReservoir.jacobian = ls.pdf;
                    if (!ls.isInfiniteDistance) {
                        pathReservoir.jacobian *= abs(dot(ls.faceN, ls.dir)) / (ls.distance * ls.distance);
                    }
                    pathReservoir.pathLength = pd.pathLength;
                    pathReservoir.lightIndex = -1; // Invalid sample for guiding TODO add nee to guiding?
                    uint flags = (uint)ReservoirPathFlags::hasNoReconnectionSurface | (uint)ReservoirPathFlags::isNEE;
                    flags |= firstHitDiffuse ? 0 : (uint)ReservoirPathFlags::firstHitIsDelta;
                    pathReservoir.flags.setReservoirPathFlags(flags);
                }
                lastHitUseNEE = true;
            } else
                lastHitUseNEE = false;

            //Tracing is always stopped after final gather
            if (isFinalGather)
                break;

            isFirstCollectionSurface = false;
        }

        pd.lastHitDiffuse = hitIsDiffuse;
        pd.specularPath &= !hitIsDiffuse;
        prevPosW = sd.posW;
        prevFaceN = sd.faceN;

        // Calc new ray direction
        if (!sampleNewDirection(sd, mi, rayDirectionSG, pd, ray)) {
            break;
        }
    }

    // Finalize Reservoir
    if (any(pathReservoir.F > 0))
        pathReservoir.weight /= luminance(pathReservoir.F);
}


void lightTraceResampling(uint2 pixel, inout ReservoirCaustic r, inout SampleGenerator sg)
{
    float3 outColor = float3(0);
    r.c = 1;
    // Get head buffer index
    int headIndex = gLightTraceHeadCounter[pixel];
    if (headIndex == -1)
        return;

    let lod = ExplicitLodTextureSampler(0);

    #if ENABLE_PHOTON_RETRACING
    uint selectedHeadIndex = 0; 
    #endif

    uint count = 0;
    while (headIndex != -1)
    {
        // Get Photon Data
        PhotonData photonData = gPhotonData[kPhotonCausticBufferIndex][headIndex];
        HitInfo photonHit = HitInfo(gCausticPhotonHitInfo[headIndex]);
        if (!photonHit.isValid())
            return;
        
        ShadingData sd = loadShadingData(photonHit, -photonData.dir, lod);
        let mi = gScene.materials.getMaterialInstance(sd, lod, kMIHints);

        float3 directionToCamera = gScene.camera.getPosition() - sd.posW;
        float distanceToCamera = length(directionToCamera);
        directionToCamera /= distanceToCamera;

        // Pdf conversion factor from image plane
        const float3 camForward = normalize(gScene.camera.data.cameraW);
        const float cameraPdf = getCameraBackprojectPDF(directionToCamera, distanceToCamera, camForward, gNormalizedPixelArea);

        const float3 bsdf = mi.eval(sd, directionToCamera, sg);

        float targetFunction = luminance(photonData.flux * bsdf) / gNumLightPaths;
        float w = targetFunction / (cameraPdf);

        r.wSum += w;
        bool selectNew = (sampleNext1D(sg) * r.wSum) < w;
        if (selectNew) {
            r.sampleSurface = photonHit.getData();
            r.sampleSurfaceView = -photonData.dir;
            r.photonPosW = sd.posW;
            r.photonDir = photonData.dir;
            r.photonRadiance = photonData.flux / gNumLightPaths;
            r.photonGuidingPdf = photonData.guidingPdf * gNumLightPaths;
            r.targetFunction = targetFunction;
            r.subPixelJacobian = getSubpixelLocationJacobian(distanceToCamera, directionToCamera, sd.faceN, camForward);
            r.lightIndex = photonData.lightIndex;
            r.guidingPixels = photonData.guidingPixel;
            #if ENABLE_PHOTON_RETRACING
            selectedHeadIndex = headIndex;
            #endif
        }

        addToGuidingTexture(photonData, w);

        // Update head index
        int newHeadIndex = gLightTraceLinkedList[headIndex];
        headIndex = newHeadIndex;
    }

    // Finalize Reservoir
    if (r.targetFunction > 0) {
        r.wSum /= r.targetFunction;
        #if ENABLE_PHOTON_RETRACING
        PhotonRetraceData photonRetraceData = PhotonRetraceData();
        photonRetraceData.startPixelPathLengthData = gPhotonDirSGPackedPixel[kPhotonCausticBufferIndex][selectedHeadIndex];
        photonRetraceData.startSeed = getStartSeedPhotonDirSG(gFrameCount, kRNGNumPasses);
        r.photonRetraceData = photonRetraceData;
        #endif
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
    float3 viewDir = -gScene.camera.computeRayPinhole(pixel, dispatchDims).dir;
    float3 outColor = float3(0);

    ReservoirCaustic causticReservoir = ReservoirCaustic();
   
    #if ENABLE_RANDOM_REPLAY
        PathReservoir pathReservoir = PathReservoir();
    #else
        ReservoirFG finalGatherReservoir = ReservoirFG();
        float3 emission = float3(0); // Emission on fully specular paths
    #endif

    uint reservoirIndex = index2Dto1D(pixel, dispatchDims.x);
    if (hitInfo.isValid()) {
        //Set RTXDI data
        let lod = ExplicitLodTextureSampler(0);
        SampleGenerator sg = SampleGenerator(pixel, gFrameCount * kRNGNumPasses + 1);

        ShadingData sd = loadShadingData(hitInfo, -viewDir, lod);
        uint hints = (uint)MaterialInstanceHints::AdjustShadingNormal;
        let mi = gScene.materials.getMaterialInstance(sd, lod, hints);
        let bsdfProperties = mi.getProperties(sd);
        float distanceToSurface = distance(sd.posW, gScene.camera.getPosition());
        PathData pd = PathData();

        gRTXDI.setSurfaceData(pixel, sd.computeNewRayOrigin(), bsdfProperties.guideNormal, bsdfProperties.diffuseReflectionAlbedo, bsdfProperties.specularReflectance, bsdfProperties.roughness, distanceToSurface);

        pd.lastHitDiffuse = bsdfProperties.roughness > kRoughnessThreshold;

        // Init Caustic reservoir if photons can be collected at the current surface
        if (pd.lastHitDiffuse) {
            causticReservoir.sampleSurface = hitInfo.getData();
            causticReservoir.sampleSurfaceView = -viewDir;
            if (kEnableLightTraceSplatting)
                lightTraceResampling(pixel, causticReservoir, sg);
            else
                photonResampling(sd, bsdfProperties, false, gNumLightPaths , causticReservoir, sg);
        }
        #if ENABLE_RANDOM_REPLAY
            gCausticReservoir[reservoirIndex] = causticReservoir;
        #endif

        pd.specularPath &= !pd.lastHitDiffuse;
        pd.firstHitIsDelta = bsdfProperties.roughness <= 0.08; // 0.08 is the delta threshold used in Falcor. Needed for emission after delta paths

        // Distribute a Final Gather ray
        RayDesc ray = {};
        ray.TMin = 0;
        ray.TMax = FLT_MAX;

#if ENABLE_RANDOM_REPLAY
        SampleGenerator pathDirSG = SampleGenerator(pixel, gFrameCount * kRNGNumPasses + 2); // Sample generator for sampling new directions
        pathReservoir.sgPathDirections = pathDirSG;
        if (sampleNewDirection(sd, mi, pathDirSG, pd, ray))
            tracePath(ray, sd.faceN , sg, pathDirSG, pd, pathReservoir);
    #else //"Old" ReSTIR FG
        // Store surface
        finalGatherReservoir.sampleSurface = hitInfo.getData();
        finalGatherReservoir.sampleData.sampleView = viewDir;
        float mVecDistance = 0;
        float3 mVecPosW = sd.posW;
        if (sampleNewDirection(sd, mi, sg, pd, ray))
            traceFGRay(ray, sg, pd, finalGatherReservoir, causticReservoir, emission, mVecDistance);
    #endif
    } else {
        // Set invalid RTXDI data
        gRTXDI.setInvalidSurfaceData(pixel);
        #if ENABLE_RANDOM_REPLAY
            gCausticReservoir[reservoirIndex] = causticReservoir;
        #endif
    }

#if ENABLE_RANDOM_REPLAY
    gPathReservoir[reservoirIndex] = pathReservoir;
#else
    gFinalGatherReservoir[reservoirIndex] = finalGatherReservoir;
    gEmission[pixel] = float4(emission, 1.0);
    gCausticReservoir[reservoirIndex] = causticReservoir;
#endif
   
    if (kEnableLightTraceSplatting)
        gLightTraceHeadCounter[pixel] = -1; // Set to invalid
}
