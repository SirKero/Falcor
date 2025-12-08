#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.Raytracing;
import Utils.Sampling.SampleGenerator;
import Utils.Color.ColorHelpers;
import StructsAndHelpers;

Texture2D<PackedHitInfo> gVBuffer;
Texture2D<float4> gView;
Texture2D<float2> gMVec;
Texture2D<PackedHitInfo> gVBufferPrev;
Texture2D<float4> gViewPrev;

StructuredBuffer<PhotonData> gPhotonData[2];
StructuredBuffer<AABB> gPhotonAABB[2];
RaytracingAccelerationStructure gPhotonAS;

StructuredBuffer<PathReservoir> gPathReservoir;
StructuredBuffer<PathReservoir> gPathReservoirPrev;

RWStructuredBuffer<RetracedPath> gRetraceReservoirPath;         //Retraced path for the current sample
RWStructuredBuffer<RetracedPath> gRetraceReservoirPathPrev;     //Retraced path for the temporal sample

RWTexture2D<float4> gDebug;

static const float kPhotonCollectTMax = 1e-7;
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
struct RetracePathData {
    float3 thp;             //Throughput
    float scatterPDF;       //scatter pdf for last hit

    float3 F;               //Accumulated path radiance
    uint pathLength;        //Current path length

    float jacobianPath;     //Jacobian for the path 
    bool lastHitDiffuse;
    bool specularPath;      //True if the full path is specular
    bool retraceSuccessful; // True if the retraced path matches the one used to generate the reservoir

    __init() {
        thp = float3(1);
        scatterPDF = 0;
        F = float3(0);
        pathLength = 0;
        jacobianPath = 1;
        lastHitDiffuse = true;
        specularPath = true;
        retraceSuccessful = false;
    }
}

// Checks if the ray start point is inside the sphere.
bool hitSphere(const float3 center, const float radius, const float3 p)
{
    float3 radiusTest = p - center;
    return dot(radiusTest, radiusTest) < radius * radius;
}

float3 collectPhotons(ShadingData sd, IMaterialInstance mi, float3 N, uint instanceMask, inout SampleGenerator sg, bool collectOnlyDirectGlobal = false) {
    float3 collectedRadiance = float3(0);
    //Prepare ray
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

        //Check if ray is inside photon radius
        AABB photonAABB = gPhotonAABB[instanceIdx][primIdx];
        float radius = (photonAABB.maxPoint.x - photonAABB.minPoint.x) / 2.0;
        if (!hitSphere(photonAABB.center(), radius, sd.posW))
            continue;

        PhotonData photonData = gPhotonData[instanceIdx][primIdx];

        // If direct global photons should be collected and the photon is global, check the path length
        if (collectOnlyDirectGlobal)
        {
            if (((PhotonType)instanceIdx == PhotonType::Global) && (photonData.pathLenght > 0))
                continue;
        }

        float NdotL = dot(photonData.dir, N);
        // Check for diffent surfaces (e.g. corners)
        if ((dot(photonData.normalW, sd.faceN) < 0.6) || (NdotL <= 0))
            continue;

        float3 bsdf = mi.eval(sd, photonData.dir, sg); 
        collectedRadiance += max(0, (photonData.flux * bsdf) / (M_PI * radius * radius * NdotL)); //NdotL needs to be taken out of the bsdf for Photon Mapping
    }
    return collectedRadiance;
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

bool randomReplay(ShadingData primSD, PathReservoir reservoir, inout SampleGenerator sg , inout RetracedPath retracedPath)
{
    let lod = ExplicitLodTextureSampler(0);
    const uint2 dispatchDims = DispatchRaysDimensions().xy;

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
                float3 envMapContribution = gScene.envMap.eval(ray.Direction) * rpd.thp;
                retracedPath.flags = (uint)ReservoirPathFlags::isEnvMapHit;
                retracedPath.rcViewDir = ray.Direction;
                retracedPath.jacobianPath = rpd.jacobianPath * rpd.scatterPDF;
                retracedPath.F += envMapContribution;
                rpd.retraceSuccessful = true;
            }
            break;
        }

        // Load shading structs
        ShadingData sd = loadShadingData(hit, -ray.Direction, lod);
        let mi = gScene.materials.getMaterialInstance(sd, lod, kMIHints);
        let bsdfProperties = mi.getProperties(sd);
        bool hitIsDiffuse = (bsdfProperties.roughness > kRoughnessThreshold); // Either diffuse surface or emissive hit
        bool hitIsEmissive = any(bsdfProperties.emission > 0);
        float rayDist = distance(ray.Origin, sd.posW);
        float jacobian = rpd.scatterPDF * abs(dot(ray.Direction, sd.faceN)) / (rayDist * rayDist); //Jacobian for this iteration

        // Delta -> Emissive case
        if (reservoir.flags.isEmissiveHit && pathLength == reservoir.pathLength && rpd.specularPath && hitIsEmissive)
        {
            retracedPath.F += bsdfProperties.emission * rpd.thp;
            retracedPath.jacobianPath = jacobian; // Jacobian Path == 1, as all hits are delta/specular
            retracedPath.flags = (uint)ReservoirPathFlags::isEmissiveHit;
            rpd.retraceSuccessful = true;
            break;
        }

        // If we hit an emissive surface the path is undefined
        if (hitIsEmissive)
            break;

        // Collect photons or set reconnection surface
        if (hitIsDiffuse) {
            //Jacobian and Radiance estimate
            retracedPath.jacobianPath = rpd.jacobianPath * jacobian;
            retracedPath.F += collectPhotons(sd, mi, bsdfProperties.guideNormal, 0xFF, sg, true) * rpd.thp;

            //Reconnection surface
            if (pathLength == reservoir.pathLength && reservoir.flags.isFinalGather) {
                if (reservoir.flags.hasTwoCollectionPoints != isFirstCollectionSurface) {
                    retracedPath.rcThp = rpd.thp;
                    retracedPath.rcSurface = hit.getData();
                    retracedPath.rcViewDir = -ray.Direction;
                    retracedPath.flags = (uint)ReservoirPathFlags::isFinalGather;
                    rpd.retraceSuccessful = true;
                }
                break;
            }

            //If the reservoir has only 1 sample point and that is not radiance estimat, the path is invalid
            if (!reservoir.flags.hasTwoCollectionPoints && !reservoir.flags.isRadianceEstimate)
                break;
                           
            isFirstCollectionSurface = false;
            if ((pathLength == reservoir.pathLength) && reservoir.flags.isRadianceEstimate) {
                retracedPath.flags = (uint)ReservoirPathFlags::isRadianceEstimate;
                rpd.retraceSuccessful = true;
                break;
            }
        }

        // Sample new ray
        triedToSetFGSurface |= rpd.lastHitDiffuse; // If 1 diffuse surface was encountered, it was tried to set the Final Gather surface
        rpd.lastHitDiffuse = hitIsDiffuse;
        rpd.specularPath &= !hitIsDiffuse;

        if (!isFirstCollectionSurface)
            rpd.jacobianPath *= jacobian;

        if (!sampleNewDirection(sd, mi, rayDirSg, rpd, ray))
            break;    
    }

    return rpd.retraceSuccessful;
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
    if (hitInfo.isValid()) {
        SampleGenerator sg = SampleGenerator(pixel, gFrameCount * 5 + 3); // Sample generator for sampling new directions

        //Reprojection with motion vectors
        float2 motionOffset = gMVec[pixel] * float2(dispatchDims);
        float2 prevPixelF = motionOffset + float2(pixel) + float2(0.5);
        float2 u = sampleNext2D(sg);
        prevPixelF += u - 0.5; // [-0.5, 0.5]

        int2 prevPixel = int2(prevPixelF);

        // Check if previous pixel is inside the screen, if not, reservoir cannot be selected
        if (any(prevPixel < 0) || any(prevPixel >= dispatchDims))
        {
            return;
        }

        // Get current reservoir
        let lod = ExplicitLodTextureSampler(0);
        const uint reservoirIndex = index2Dto1D(pixel, dispatchDims.x);
        PathReservoir reservoir = gPathReservoir[reservoirIndex];
        if (reservoir.pathLength > 0 && reservoir.isValid()) {
            RetracedPath retraceSurface = RetracedPath();
            // Get starting surface for temporal retrace
            HitInfo prevHit = HitInfo(gVBufferPrev[prevPixel]);
            float3 prevViewDir = gViewPrev[prevPixel].xyz;
            ShadingData sd = loadShadingData(prevHit, prevViewDir, lod);

            if (!randomReplay(sd, reservoir, sg, retraceSurface)) {
                retraceSurface.F = float3(0);
                retraceSurface.flags = 0;
            } 

            gRetraceReservoirPath[reservoirIndex] = retraceSurface;
        }

        PathReservoir resampleReservoir = gPathReservoirPrev[index2Dto1D(prevPixel, dispatchDims.x)];
        if (resampleReservoir.pathLength > 0) {
            RetracedPath retraceSurface = RetracedPath();
            float3 viewDir = gView[pixel].xyz;
            ShadingData sd = loadShadingData(hitInfo, viewDir, lod);

            if (!randomReplay(sd, resampleReservoir, sg, retraceSurface)) {
                retraceSurface.F = float3(0);
                retraceSurface.flags = 0;
            }

            gRetraceReservoirPathPrev[reservoirIndex] = retraceSurface;
        }
    }
}
