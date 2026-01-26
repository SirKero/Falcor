#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.Raytracing;
import Utils.Sampling.SampleGenerator;
import Utils.Color.ColorHelpers;
import Utils.Math.MathHelpers;
import Utils.Geometry.GeometryHelpers;
import Rendering.Lights.LightHelpers;
import Rendering.Lights.EmissiveLightSampler;
import Rendering.Lights.EmissiveLightSamplerHelpers;
import RenderPasses.PhotonGuiding.StructsAndHelpers;
import RenderPasses.PhotonGuiding.SharedEnums;
import RenderPasses.PhotonGuiding.NextEventEstimationHelper;

#ifndef USE_LIGHT_PATH_RETRACING
#define USE_LIGHT_PATH_RETRACING 0
#endif

Texture2D<PackedHitInfo> gVBuffer;
Texture2D<PackedHitInfo> gVBufferPrev;
Texture2D<float4> gView;
Texture2D<float4> gViewPrev;
Texture2D<float2> gMVec;

RWStructuredBuffer<PathReservoir> gPathReservoir;
StructuredBuffer<PathReservoir> gPathReservoirPrev;

static const uint kRNGNumPasses = RNG_NUM_PASSES;
static const uint kMIHints = (uint)MaterialInstanceHints::AdjustShadingNormal;
static const uint kCausticInstanceMask = 2;
static const uint kAllPhotonInstanceMask = 0xFF;
static const bool kEvalDeltaPdfs = EVAL_DELTA_PDFS;
static const bool kUseEnvMap = USE_ENV_BACKGROUND;
static const bool kAlphaTest = true;
static const float kRoughnessThreshold = ROUGHNESS_THRESHOLD;
static const bool kUseEnvLight = USE_ENV_LIGHT;
static const bool kPhotonRussianRoulette = PHOTON_RUSSIAN_ROULETTE;

cbuffer CB
{
    uint gFrameCount; // Frame count since scene was loaded.
    uint gFGRayMaxPathLength;   // Max path length for a Final Gather sample
    float gJacobianDistanceThreshold; // Depth threshold for jacobian
    uint gConfidenceLimit;            // Confidence Limit

    uint gSpatialSamples;          // Number of spatial samples
    float gSpatialRadius;          // radius for spatial resampling
    float gNormalThreshold;        // Normal Threshold
    float gRelativeDepthThreshold; // Relative depth threshold

    bool gUsePathThreshold; // Enables and disables path threshold
    float3 gNeeLightSelectProb;       // Light selection probabilities for NEE

    uint gGuidingTextureResolution; // Resolution of all guiding textures. xy is the same
}

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
struct RetracePathData {
    float3 thp;             //Throughput
    float scatterPDF;       //scatter pdf for last hit

    float3 F;               //Accumulated path radiance
    uint pathLength;        //Current path length

    bool lastHitDiffuse;
    bool specularPath;      //True if the full path is specular
    bool retraceSuccessful; // True if the retraced path matches the one used to generate the reservoir

    __init() {
        thp = float3(1);
        scatterPDF = 0;
        F = float3(0);
        pathLength = 0;
        lastHitDiffuse = true;
        specularPath = true;
        retraceSuccessful = false;
    }
}

bool sampleNewDirection(ShadingData sd, IMaterialInstance mi, inout SampleGenerator sg, inout RetracePathData pd, inout RayDesc ray) {
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

bool randomReplayPhotonPath(PathReservoir reservoirs, float3 photonCollectionPosW, out float3 samplePosW, out float3 sampleFlux)
{
    samplePosW = float3(0);
    sampleFlux = float3(0);
    //Recreate Light Dir Sample generator
    SampleGenerator sg = SampleGenerator(reservoirs.photonRetraceData.startPixel, reservoirs.photonRetraceData.startSeed);

    //Create pls to get start position for the path
    PhotonLightSample pls = PhotonLightSample();
    pls.lightIdx = reservoirs.lightIndex;
    pls.guidingPixels = reservoirs.guidingPixels;
    pls.useRandomLightDirection = reservoirs.photonRetraceData.usedRandomDirection;
    photonRetraceRecreateDirectionsRandomValues(pls, sampleNext2D(sg), gGuidingTextureResolution);

    RayDesc ray = {};
    if(!photonSampleLight(pls, ray, sg))
        return false;

    const uint targetPathLength = reservoirs.photonRetraceData.pathLength;
    RayPayload rayPayload = RayPayload();
    bool validPhoton = false;
    bool lastHitSpecular = false;
    float3 thp = float3(1);
    sampleFlux = pls.flux;

    for (uint i = 0; i <= targetPathLength; i++) {
        TraceRay(gScene.rtAccel, 0 /*Flags*/, 0xff /* instanceInclusionMask */, 0 /* hitIdx */, rayTypeCount, 0 /* missIdx */, ray, rayPayload);

        HitInfo hit = HitInfo(rayPayload.packedHitInfo);
        if (!hit.isValid())
            break;

        // Get shading infos
        let lod = ExplicitLodTextureSampler(0);
        // Get Material properties
        ShadingData sd = loadShadingData(hit, ray.Direction, lod);

        // Check if hit is valid for final gather
        if (i == targetPathLength) {
            samplePosW = sd.posW;
            validPhoton = distance(photonCollectionPosW, sd.posW) <= reservoirs.sampleRadius;
            //Check if caustic photon is still caustic
            if(reservoirs.flags.isCausticPhoton)
                validPhoton &= lastHitSpecular;
            break;
        }

        // Photon Bounce for next iteration
        uint hints = (uint)MaterialInstanceHints::AdjustShadingNormal;
        let mi = gScene.materials.getMaterialInstance(sd, lod, hints);
        let bsdfProperties = mi.getProperties(sd);
        BSDFSample bsdfSample;
        bool validSample = mi.sample(sd, sg, bsdfSample, true /*ImportanceSampling*/);
        if (!validSample || any(bsdfProperties.emission > 0))
            break;
        bool transmission = bsdfSample.isLobe(LobeType::Transmission);
        ray.Origin = sd.computeNewRayOrigin(!transmission); // false is for transmissions
        ray.Direction = bsdfSample.wo;
        lastHitSpecular = bsdfProperties.roughness < kRoughnessThreshold;

        thp *= bsdfSample.weight;
        // Russian roulette
        if (kPhotonRussianRoulette) {
            float rrRand = sampleNext1D(sg);
            const float rrVal = luminance(thp);
            if ((rrRand > rrVal))
            {
                break; // Photon is absorbed
            }
            thp /= rrVal;
        }

    }

    sampleFlux *= validPhoton ? thp : 0.0;

    return validPhoton;
}

bool randomReplay(ShadingData primSD, PathReservoir reservoir, inout SampleGenerator sg , inout RetracedPath retracedPath, out float3 collectionPosW)
{
    let lod = ExplicitLodTextureSampler(0);
    const uint2 dispatchDims = DispatchRaysDimensions().xy;
    collectionPosW = float3(0);

    // Init needed path data
    SampleGenerator rayDirSg = reservoir.sgPathDirections;
    RetracePathData rpd = RetracePathData();

    // Get starting ray
    RayDesc ray = {};
    ray.TMin = 0;
    ray.TMax = FLT_MAX;
    let primMI = gScene.materials.getMaterialInstance(primSD, lod, kMIHints);
    let primProperties = primMI.getProperties(primSD);
    RayPayload rayPayload = RayPayload();
    rpd.lastHitDiffuse = primProperties.roughness > kRoughnessThreshold;
    rpd.specularPath &= !rpd.lastHitDiffuse;
    bool firstHitIsDelta = primProperties.roughness < 0.08;

    if ((reservoir.flags.firstHitIsDelta && rpd.lastHitDiffuse) || (!reservoir.flags.firstHitIsDelta && !rpd.lastHitDiffuse))
        return false;

    if (!sampleNewDirection(primSD, primMI, rayDirSg, rpd, ray))
        return false;

    bool triedToSetFGSurface = false;
    bool isFirstCollectionSurface = true;
    float3 prevPosW = primSD.posW;
    float3 prevFaceN = primSD.faceN;
    // Trace Loop
    for (uint pathLength = 1; pathLength <= reservoir.pathLength; pathLength++)
    {
        TraceRay(gScene.rtAccel, 0, 0xff, 0, rayTypeCount, 0, ray, rayPayload);
        HitInfo hit = HitInfo(rayPayload.packedHitInfo);

        //Scene Miss
        if (!hit.isValid()) {
            bool validEnvSample = reservoir.flags.isEnvMapHit && pathLength == reservoir.pathLength;
            validEnvSample &= reservoir.pathLength > 1 || (pathLength == 1 && firstHitIsDelta);
            if (validEnvSample) {
                float misWeight = 1.0;
                if (kUseEnvLight && rpd.lastHitDiffuse) {
                    float lightPdf = gNeeLightSelectProb[kNeeLightTypeEnvMap] * gEnvMapSampler.evalPdf(ray.Direction);
                    misWeight = evalMIS(1, rpd.scatterPDF, 1, lightPdf);
                }
                float3 envMapContribution = gScene.envMap.eval(ray.Direction) * rpd.thp * misWeight;
                retracedPath.flags = (uint)ReservoirPathFlags::isEnvMapHit;
                retracedPath.rcViewDir = -ray.Direction;
                retracedPath.jacobian = rpd.scatterPDF;
                retracedPath.F = envMapContribution;
                rpd.retraceSuccessful = true;
            }
            break;
        }

        // Load shading structs
        ShadingData sd = loadShadingData(hit, ray.Direction, lod);
        let mi = gScene.materials.getMaterialInstance(sd, lod, kMIHints);
        let bsdfProperties = mi.getProperties(sd);
        float rayDist = distance(ray.Origin, sd.posW);
        bool jacobianDistanceThreshold = rayDist > gJacobianDistanceThreshold;
        bool hitIsDiffuse = (bsdfProperties.roughness > kRoughnessThreshold) && jacobianDistanceThreshold; // Either diffuse surface or emissive hit
        bool hitIsEmissive = any(bsdfProperties.emission > 0);
        float jacobian = rpd.scatterPDF * abs(dot(ray.Direction, sd.faceN)) / (rayDist * rayDist); //Jacobian for this iteration

        // Delta -> Emissive case
        if (reservoir.flags.isEmissiveHit && pathLength == reservoir.pathLength && rpd.specularPath && hitIsEmissive)
        {
            float misWeight = 1.0;
            float neeEmissiveProbability = gNeeLightSelectProb[kNeeLightTypeEmissive];
            if (neeEmissiveProbability > 0 && rpd.lastHitDiffuse)
            {
                // Get hit in light collection representation
                TriangleHit triangleHit = hit.getTriangleHit();
                TriangleLightHit lightHit;
                lightHit.triangleIndex = gScene.lightCollection.getTriangleIndex(triangleHit.instanceID, triangleHit.primitiveIndex);
                lightHit.posW = sd.posW;
                lightHit.normalW = sd.getOrientedFaceNormal();
                float neePDF = neeEmissiveProbability * gEmissiveSampler.evalPdf(prevPosW, prevFaceN, true, lightHit);
                misWeight = evalMIS(1.0, rpd.scatterPDF, 1.0, neePDF);
            }
            retracedPath.F = bsdfProperties.emission * rpd.thp * misWeight;
            retracedPath.jacobian = jacobian; // Jacobian Path == 1, as all hits are delta/specular
            retracedPath.flags = (uint)ReservoirPathFlags::isEmissiveHit;
            rpd.retraceSuccessful = true;
            break;
        }

        // If we hit an emissive surface the path is undefined
        if (hitIsEmissive)
            break;

        // Collect photons or set reconnection surface
        if (hitIsDiffuse && pathLength == reservoir.pathLength) {
            retracedPath.jacobian = jacobian;
            if (reservoir.flags.isFinalGather)
            {
                retracedPath.rcThp = rpd.thp;
                retracedPath.rcSurface = hit.getData();
                retracedPath.rcViewDir = -ray.Direction;
                retracedPath.flags = (uint)ReservoirPathFlags::isFinalGather;
                rpd.retraceSuccessful = true;
            } else if (reservoir.flags.isRadianceEstimate)
            {
                bool isReconnectable = distance(reservoir.samplePosW, sd.posW) < reservoir.sampleRadius;
                collectionPosW = sd.posW;
                retracedPath.F = reservoir.fgRadiance * rpd.thp;
                retracedPath.flags = isReconnectable ? (uint)ReservoirPathFlags::isRadianceEstimate : 0;
                rpd.retraceSuccessful = isReconnectable;
            } else if (reservoir.flags.isNEE)
            {
                SampleGenerator neeSG = reservoir.sgNeeLightSelection;
                LightSample ls;
                float3 nee = nextEventEstimation(sd, mi, gNeeLightSelectProb, ls, neeSG);
                if (any(nee > 0) && ls.pdf > 0 && ls.distance > gJacobianDistanceThreshold) {
                    retracedPath.flags = (uint)ReservoirPathFlags::isNEE;
                    retracedPath.F = nee * rpd.thp; 
                    retracedPath.jacobian = ls.pdf;
                    if (!ls.isInfiniteDistance)
                        retracedPath.jacobian *= abs(dot(sd.faceN, ls.dir)) / (ls.distance * ls.distance);
                    rpd.retraceSuccessful = true;
                }
            }

            break;
        }

        // Sample new ray
        triedToSetFGSurface |= rpd.lastHitDiffuse; // If 1 diffuse surface was encountered, it was tried to set the Final Gather surface
        rpd.lastHitDiffuse = hitIsDiffuse;
        rpd.specularPath &= !hitIsDiffuse;
        prevPosW = sd.posW;
        prevFaceN = sd.faceN;

        if (!sampleNewDirection(sd, mi, rayDirSg, rpd, ray))
            break;    
    }

    return rpd.retraceSuccessful;
}

/*
bool resampleReservoir(inout PathReservoir reservoir, PathReservoir rCurr, int2 pixel, int2 reservoirPixel, HitInfo firstHit, inout SampleGenerator sg) {

    // Check if reservoir is inside the screen.
    if (any(reservoirPixel < 0) || any(reservoirPixel >= gFrameDim))
        return false;

    HitInfo prevHit = HitInfo(gVBufferPrev[reservoirPixel]);

    if (!prevHit.isValid())
        return false;

    // Check if primary surfaces are similar (only for spatial resampling)
    let lod = ExplicitLodTextureSampler(0);
    ShadingData sdCurrent = loadShadingData(firstHit, -gView[pixel].xyz, lod);
    ShadingData sdPrev = loadShadingData(prevHit, -gViewPrev[reservoirPixel].xyz, lod);
    bool isSpatialResampling = gNumResamplingPass > 0;
    if (isSpatialResampling) {
        const float3 cameraPos = gScene.camera.getPosition();
        float currentDepth = distance(cameraPos, sdCurrent.posW);
        float temporalDepth = distance(cameraPos, sdPrev.posW);
        bool normalThreshold = abs(dot(sdCurrent.getOrientedFaceNormal(), sdPrev.getOrientedFaceNormal())) < gNormalThreshold;
        bool depthThreshold = abs(currentDepth - temporalDepth) > gRelativeDepthThreshold * currentDepth;

        if (normalThreshold || depthThreshold)
            return false;
    }


    // Needed reservoir variables
    float w_0 = 0;
    float w_1 = 0;
    float wSum = 0;
    const uint retracedPathIndex = index2Dto1D(pixel, gFrameDim.x);

    // Load reservoir
    PathReservoir rPrev = gPathReservoirPrev[index2Dto1D(reservoirPixel, gFrameDim.x)];

    bool reservoirContributes = rCurr.isValid();
    RetracedPath retracedPath = RetracedPath();
    bool retracedPathValid = true; // If the path is not valid, the path was not possible and MIS weight is 1
    if (reservoirContributes && rCurr.pathLength > 0) {
        retracedPath = gRetracedPath[retracedPathIndex];
        retracedPathValid &= retracedPath.flags > 0; // A valid path has flags set
    }

    if (reservoirContributes)
    {
        // Calc MIS weight
        float mis = 1;
        bool photonRetraceValid = true;
#if USE_LIGHT_PATH_RETRACING
        if ((rCurr.flags.isRadianceEstimate || rCurr.flags.isFinalGather) && !checkPhotonRetraceMask(photonRetraceMask, 0))
            photonRetraceValid = false;
#endif
        if (rCurr.flags.hasNoReconnectionSurface && photonRetraceValid) {
            float3 retracedF = retracedPath.F * (retracedPath.jacobian / rCurr.jacobian);
            mis = evalMIS(rCurr.c, luminance(rCurr.F), rPrev.c, luminance(retracedF));
        } else
        {
            float3 thpOther = float3(1);
            // Load other reconnection surface if path length > 0
            if (rCurr.pathLength > 0 && retracedPathValid && photonRetraceValid) {
                sdPrev = loadShadingData(HitInfo(retracedPath.rcSurface), -retracedPath.rcViewDir, lod);
                thpOther = retracedPath.rcThp;
            }

            if (retracedPathValid && photonRetraceValid) {
                float p0 = luminance(rCurr.F);

                let miPrev = gScene.materials.getMaterialInstance(sdPrev, lod, kMIHints);
                float p1 = 0;
                float3 toSample = rCurr.samplePosW - sdPrev.posW;
                float distToSample = length(toSample);
                toSample /= distToSample;
                // Jacobian to Sample
                float pdf = miPrev.evalPdf(sdPrev, toSample);
                float jacobianNew = abs(dot(rCurr.sampleNormal, -toSample)) / (distToSample * distToSample);
                jacobianNew *= pdf;
                float jacobian = jacobianNew / rCurr.jacobian;

                float3 pathRadiance = float3(0);
                if (jacobian > 0 && (distToSample > gJacobianDistanceThreshold)) {
                    if (dispatchShadowRay(sdPrev, toSample, distToSample)) {
                        float3 bsdf = miPrev.eval(sdPrev, toSample, sg) / pdf;
                        pathRadiance += bsdf * jacobian * rCurr.fgRadiance * thpOther;
                    }
                }

                p1 = luminance(pathRadiance);
                mis = evalMIS(rCurr.c, p0, rPrev.c, p1);
            }
        }

        w_0 = mis * luminance(rCurr.F) * rCurr.weight;
        wSum += w_0;
    }

    if (reservoirContributes && (w_0 > 0) && !isinf(w_0) && !isnan(w_0))
        reservoir = rCurr;

    // Temporal Reservoir
    float3 Fprev = float3(0);
    float jacobianPrev = 1;
    bool prevCanBeSelected = rPrev.isValid();
    prevCanBeSelected &= !isnan(rPrev.weight) && !isinf(rPrev.weight);
#if USE_LIGHT_PATH_RETRACING
    if ((rPrev.flags.isRadianceEstimate || rPrev.flags.isFinalGather) && !checkPhotonRetraceMask(photonRetraceMask, 1))
        prevCanBeSelected = false;
#endif

    // Load retraced surface for temporal reservoir
    retracedPath = RetracedPath();
    retracedPathValid = true; // If the surface is not valid MIS is skipped
    if (prevCanBeSelected && rPrev.pathLength > 0) {
        retracedPath = gRetracedPathPrev[retracedPathIndex];
        retracedPathValid &= retracedPath.flags > 0; // A valid path has flags set
    }

    if (prevCanBeSelected)
    {
        float jacobianDeterminant = 1.0;
        if (rPrev.flags.hasNoReconnectionSurface) {
            if (retracedPathValid) {
                jacobianPrev = retracedPath.jacobian;
                jacobianDeterminant = (jacobianPrev / rPrev.jacobian);
                Fprev = retracedPath.F;
            }
        } else
        {
            float3 thpPrev = float3(1);
            // Load retraced surface
            if (rPrev.pathLength > 0 && retracedPathValid) {
                sdCurrent = loadShadingData(HitInfo(retracedPath.rcSurface), -retracedPath.rcViewDir, lod);
                thpPrev = retracedPath.rcThp;
            }

            // Reconnect
            if (retracedPathValid) {
                let miCurrent = gScene.materials.getMaterialInstance(sdCurrent, lod, kMIHints);
                float3 toSample = rPrev.samplePosW - sdCurrent.posW;
                float distToSample = length(toSample);
                toSample /= distToSample;
                // Jacobian from reconnect surface to other sample
                float pdf = miCurrent.evalPdf(sdCurrent, toSample);
                jacobianPrev = abs(dot(rPrev.sampleNormal, -toSample)) / (distToSample * distToSample);
                jacobianPrev *= pdf;
                jacobianDeterminant = jacobianPrev / rPrev.jacobian;

                float3 bsdf = float3(0);
                if (jacobianDeterminant > 0 && (distToSample > gJacobianDistanceThreshold)) {
                    if (dispatchShadowRay(sdCurrent, toSample, distToSample)) {
                        bsdf = miCurrent.eval(sdCurrent, toSample, sg) / pdf;
                    }
                    Fprev = rPrev.fgRadiance * bsdf * thpPrev;
                }
            }
        }

        float estFprev = luminance(Fprev) * jacobianDeterminant;
        float mis = evalMIS(rPrev.c, luminance(rPrev.F), rCurr.c, estFprev);
        w_1 = mis * estFprev * rPrev.weight;

        wSum += w_1;
    }

    uint cSum = min(rCurr.c + rPrev.c, gConfidenceLimit);

    bool selectOtherSample = (sampleNext1D(sg) * wSum) < w_1 && prevCanBeSelected;
    if (selectOtherSample) {
        reservoir = rPrev;
        reservoir.jacobian = jacobianPrev;
        reservoir.F = Fprev;
    }

    reservoir.weight = wSum;
    reservoir.c = cSum;

    float sampleRad = luminance(reservoir.F);
    if (reservoir.weight > 0 && sampleRad > 0)
        reservoir.weight /= sampleRad;
    else
        reservoir.weight = 0;

    return true;
}
*/

float resampleReservoirCurrent(inout PathReservoir reservoir, inout PathReservoir reservoirOther, inout RetracedPath retracedPath, ShadingData sdOther, inout SampleGenerator sg)
{
    float w_0 = 0;
    bool reservoirContributes = reservoir.isValid();
    // If the path is not valid, the path was not possible and MIS weight is 1
    bool retracedPathValid = reservoirContributes && reservoir.pathLength > 0 && retracedPath.flags > 0; 
    if (reservoirContributes)
    {
        // Calc MIS weight
        let lod = ExplicitLodTextureSampler(0);
        float mis = 1;
        bool photonRetraceValid = true; //TODO add if photon retrace is implemented for previous paths
    
        if (reservoir.flags.hasNoReconnectionSurface && photonRetraceValid) {
            float3 retracedF = retracedPath.F * (retracedPath.jacobian / reservoir.jacobian);
            mis = evalMIS(reservoir.c, luminance(reservoir.F), reservoirOther.c, luminance(retracedF));
        } else
        {
            float3 thpOther = float3(1);
            // Load other reconnection surface if path length > 0
            if (reservoir.pathLength > 0 && retracedPathValid && photonRetraceValid) {
                sdOther = loadShadingData(HitInfo(retracedPath.rcSurface), -retracedPath.rcViewDir, lod); //TODO optimize
                thpOther = retracedPath.rcThp;
            }

            if (retracedPathValid && photonRetraceValid) {
                float p0 = luminance(reservoir.F);
                let miPrev = gScene.materials.getMaterialInstance(sdOther, lod, kMIHints);
                float p1 = 0;
                float3 toSample = reservoir.samplePosW - sdOther.posW;
                float distToSample = length(toSample);
                toSample /= distToSample;
                // Jacobian to Sample
                float pdf = miPrev.evalPdf(sdOther, toSample);
                float jacobianNew = abs(dot(reservoir.sampleNormal, -toSample)) / (distToSample * distToSample);
                jacobianNew *= pdf;
                float jacobian = jacobianNew / reservoir.jacobian;

                float3 pathRadiance = float3(0);
                if (jacobian > 0 && (distToSample > gJacobianDistanceThreshold)) {
                    if (dispatchShadowRay(sdOther, toSample, distToSample)) {
                        float3 bsdf = miPrev.eval(sdOther, toSample, sg) / pdf;
                        pathRadiance += bsdf * jacobian * reservoir.fgRadiance * thpOther;
                    }
                }

                p1 = luminance(pathRadiance);
                mis = evalMIS(reservoir.c, p0, reservoirOther.c, p1);
            }
        }

        w_0 += mis * luminance(reservoir.F) * reservoir.weight;
    }
    return w_0;
}

float resampleReservoirOther(inout PathReservoir reservoir, inout PathReservoir reservoirOther, inout RetracedPath retracedPath, ShadingData sd, inout SampleGenerator sg, out float jacobianPrev, out float3 Fprev)
{
    float w_1 = 0;
    Fprev = float3(0);
    jacobianPrev = 1;
    bool prevCanBeSelected = reservoirOther.isValid();
    prevCanBeSelected &= !isnan(reservoirOther.weight) && !isinf(reservoirOther.weight);

    // If the surface is not valid MIS is skipped
    bool retracedPathValid = prevCanBeSelected && reservoirOther.pathLength > 0 && retracedPath.flags > 0;
    let lod = ExplicitLodTextureSampler(0);

    if (prevCanBeSelected)
    {
        float jacobianDeterminant = 1.0;
        if (reservoirOther.flags.hasNoReconnectionSurface) {
            if (retracedPathValid) {
                jacobianPrev = retracedPath.jacobian;
                jacobianDeterminant = (jacobianPrev / reservoirOther.jacobian);
                Fprev = retracedPath.F;
            }
        } else
        {
            float3 thpPrev = float3(1);
            // Load retraced surface
            if (reservoirOther.pathLength > 0 && retracedPathValid) {
                sd = loadShadingData(HitInfo(retracedPath.rcSurface), -retracedPath.rcViewDir, lod);
                thpPrev = retracedPath.rcThp;
            }

            // Reconnect
            if (retracedPathValid) {
                let miCurrent = gScene.materials.getMaterialInstance(sd, lod, kMIHints);
                float3 toSample = reservoirOther.samplePosW - sd.posW;
                float distToSample = length(toSample);
                toSample /= distToSample;
                // Jacobian from reconnect surface to other sample
                float pdf = miCurrent.evalPdf(sd, toSample);
                jacobianPrev = abs(dot(reservoirOther.sampleNormal, -toSample)) / (distToSample * distToSample);
                jacobianPrev *= pdf;
                jacobianDeterminant = jacobianPrev / reservoirOther.jacobian;

                float3 bsdf = float3(0);
                if (jacobianDeterminant > 0 && (distToSample > gJacobianDistanceThreshold)) {
                    if (dispatchShadowRay(sd, toSample, distToSample)) {
                        bsdf = miCurrent.eval(sd, toSample, sg) / pdf;
                    }
                    Fprev = reservoirOther.fgRadiance * bsdf * thpPrev;
                }
            }
        }

        float estFprev = luminance(Fprev) * jacobianDeterminant;
        float mis = evalMIS(reservoirOther.c, luminance(reservoirOther.F), reservoir.c, estFprev);
        w_1 += mis * estFprev * reservoirOther.weight;
    }

    return w_1;
}

bool retraceAndResampleReservoir(inout PathReservoir reservoir, inout SampleGenerator sg, ShadingData sd , uint2 otherPixel) {
    const uint2 pixel = DispatchRaysIndex().xy;
    const uint2 dispatchDims = DispatchRaysDimensions().xy;

    HitInfo prevHit = HitInfo(gVBufferPrev[otherPixel]);

    if (!prevHit.isValid())
        return false;

    // Check if primary surfaces are similar (only for spatial resampling)
    let lod = ExplicitLodTextureSampler(0);
    ShadingData sdOther = loadShadingData(prevHit, -gViewPrev[otherPixel].xyz, lod);
    PathReservoir reservoirOther = gPathReservoirPrev[index2Dto1D(otherPixel, dispatchDims.x)];
    // Check if this should be performed for temporal resampling or only spatial
    if (true) {
        const float3 cameraPos = gScene.camera.getPosition();
        float currentDepth = distance(cameraPos, sd.posW);
        float temporalDepth = distance(cameraPos, sdOther.posW);
        bool normalThreshold = abs(dot(sd.getOrientedFaceNormal(), sdOther.getOrientedFaceNormal())) < gNormalThreshold;
        bool depthThreshold = abs(currentDepth - temporalDepth) > gRelativeDepthThreshold * currentDepth;

        if (normalThreshold || depthThreshold)
            return false;
    }

    // Random Replay for camera path
    let lod = ExplicitLodTextureSampler(0);
    bool validRandomReplayPath = true;
    float3 collectionPosW = float3(0);
    RetracedPath retracePath = RetracedPath();
    if (reservoir.pathLength > 0 && reservoir.isValid()) {
        // Retrace camera path
        validRandomReplayPath = randomReplay(sdOther, reservoir, sg, retracePath, collectionPosW);
        if (!validRandomReplayPath) {
            retracePath.F = float3(0);
            retracePath.flags = 0;
        }
    }

    bool photonRetraceValid = true;
    // Photon Path retracing
    /* TODO for this to make sense, the previous AS needs to be available. For now the previous path is always assumed to be visible
    #if USE_LIGHT_PATH_RETRACING
        if (validRandomReplayPath && reservoir.flags.isFinalGather || reservoir.flags.isRadianceEstimate) {
            if (reservoir.flags.isFinalGather)
                collectionPosW = reservoir.samplePosW;
            if (randomReplayPhotonPath(reservoir, collectionPosW)) {
                uint photonRetraceMask |= 1;
            }
        }
    #endif
    */

    // Resample current
    float wSum = 0;
    wSum += resampleReservoirCurrent(reservoir, reservoirOther, retracePath, sdOther, sg);

    // Temporal Retrace for previous frame
    validRandomReplayPath = true;
    collectionPosW = float3(0);
    retracePath = RetracedPath();
    if (reservoirOther.pathLength > 0) {
        validRandomReplayPath = randomReplay(sd, reservoirOther, sg, retracePath, collectionPosW);
        if (!validRandomReplayPath) {
            retracePath.F = float3(0);
            retracePath.flags = 0;
        }
    }

    photonRetraceValid = true;
#if USE_LIGHT_PATH_RETRACING
    if (validRandomReplayPath && reservoirOther.flags.isFinalGather || reservoirOther.flags.isRadianceEstimate) {
        if (reservoirOther.flags.isFinalGather)
            collectionPosW = reservoirOther.samplePosW;
            // TODO update reservoir radiance and sample position
        float3 photonSamplePosW, photonSampleFlux;
        photonRetraceValid = randomReplayPhotonPath(reservoirOther, collectionPosW, photonSamplePosW, photonSampleFlux);

        if (photonRetraceValid) {
            photonSampleFlux /= reservoirOther.photonGuidingPdf;
        }
    }
    #endif

    // Temporal Resampling only contributes if the photon path retrace was successful
    float w_1 = 0;
    float jacobianPrev = 1;
    float3 Fprev = float3(0);
    if (photonRetraceValid) {
        w_1 = resampleReservoirOther(reservoir, reservoirOther, retracePath, sd, sg, jacobianPrev, Fprev);
        wSum += w_1;
    }

    // Finalize Resrvoir
    uint cSum = min(reservoir.c + reservoirOther.c, gConfidenceLimit);

    bool selectOtherSample = (sampleNext1D(sg) * wSum) < w_1;
    if (selectOtherSample) {
        reservoir = reservoirOther;
        reservoir.jacobian = jacobianPrev;
        reservoir.F = Fprev;
    }

    reservoir.weight = wSum;
    reservoir.c = cSum;

    float sampleRad = luminance(reservoir.F);
    if (reservoir.weight > 0 && sampleRad > 0)
        reservoir.weight /= sampleRad;
    else
        reservoir.weight = 0;

    return reservoir.weight > 0;
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
    PathReservoir reservoir = PathReservoir();

    if (hitInfo.isValid()) {
        SampleGenerator sg = SampleGenerator(pixel, gFrameCount * kRNGNumPasses + 4); // Sample generator for whole pass
        reservoir = gPathReservoir[index2Dto1D(pixel, dispatchDims.x)];
        let lod = ExplicitLodTextureSampler(0);
        ShadingData sd = loadShadingData(hitInfo, -gView[pixel].xyz, lod);

        for (uint i = 0; i < gSpatialSamples + 1; i++) {
            // Reprojection with motion vectors
            bool isSpatial = i > 0;
            float2 motionOffset = gMVec[pixel] * float2(dispatchDims);
            float2 prevPixelF = motionOffset + float2(pixel) + float2(0.5);
            float2 u = sampleNext2D(sg);
            if (isSpatial) {
                float2 spatialOffset = gSpatialRadius * sample_disk_concentric(u);
                prevPixelF += spatialOffset;
            } else // Temporal; Add subpixel offset
            {
                prevPixelF += u - 0.5; // [-0.5, 0.5]
            }

            int2 prevPixel = int2(prevPixelF);

            // Check if previous pixel is inside the screen, if not, reservoir cannot be selected
            if (any(prevPixel < 0) || any(prevPixel >= dispatchDims))
                continue;

            retraceAndResampleReservoir(reservoir, sg, sd, uint2(prevPixel));
        }        
    }

    // Update reservoir
    gPathReservoir[index2Dto1D(pixel, dispatchDims.x)] = reservoir;
}
