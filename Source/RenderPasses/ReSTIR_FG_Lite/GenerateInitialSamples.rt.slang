#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.Raytracing;
import Utils.Sampling.SampleGenerator;
import Utils.Color.ColorHelpers;
import Rendering.RTXDI.RTXDI;
import StructsAndHelpers;

Texture2D<PackedHitInfo> gVBuffer;

StructuredBuffer<PhotonData> gPhotonData[2];
StructuredBuffer<AABB> gPhotonAABB[2];
RaytracingAccelerationStructure gPhotonAS;

RWStructuredBuffer<ReservoirFG> gFinalGatherReservoir;
RWStructuredBuffer<ReservoirCaustic> gCausticReservoir;

static const float kPhotonCollectTMax = 1e-7;

cbuffer CB
{
    uint gFrameCount; // Frame count since scene was loaded.
    uint gFGRayMaxPathLength; //Max path length for a Final Gather sample
    bool gUsePhotonForDirectLightAfterSpecular; //Direct light after specular reflections is either handled by photons or by including the emissive light into the fg sample
}

static const bool kAlphaTest = true;
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

float3 collectPhotons(ShadingData sd, IMaterialInstance mi, float3 N, uint instanceMask, inout SampleGenerator sg) {
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
        float NdotL = dot(photonData.dir, N);
        // Check for diffent surfaces (e.g. corners)
        if ((dot(photonData.normalW, sd.faceN) < 0.6) || (NdotL <= 0))
            continue;

        float3 bsdf = mi.eval(sd, photonData.dir, sg); //;
        collectedRadiance += max(0, (photonData.flux * bsdf) / (M_PI * radius * radius * NdotL)); //NdotL needs to be taken out of the bsdf for Photon Mapping
    }
    return collectedRadiance;
}

bool generateFGSampleRay(ShadingData sd, IMaterialInstance mi, inout SampleGenerator sg, inout float3 thp, inout float pdf, inout RayDesc ray) {
    // Photon Bounce for next iteration
    BSDFSample bsdfSample;
    bool validSample = mi.sample(sd, sg, bsdfSample, true /*ImportanceSampling*/);
    bool transmission = bsdfSample.isLobe(LobeType::Transmission);
    ray.Origin = sd.computeNewRayOrigin(!transmission); // false is for transmissions
    ray.Direction = bsdfSample.wo;
    thp *= bsdfSample.weight;
    pdf = bsdfSample.pdf;

    return validSample;
}

void photonResampling(ShadingData sd, BSDFProperties bsdfProperties, bool collectGlobalDirect, inout ReservoirCaustic causticReservoir , inout SampleGenerator sg) {
    // Prepare ray
    RayDesc ray;
    ray.Origin = sd.posW;
    ray.Direction = sd.faceN;
    ray.TMin = 0;
    ray.TMax = kPhotonCollectTMax;

    RayQuery<RAY_FLAG_NONE> rayQuery;
    uint instanceMask = collectGlobalDirect ? 0xFF : 2; //2 is caustic only

    rayQuery.TraceRayInline(gPhotonAS, RAY_FLAG_NONE, instanceMask , ray);
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
        float w =  targetFunction / photonDenom;

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

void traceFGRay(RayDesc ray, inout SampleGenerator sg, bool prevHitIsRough, inout float3 thp, inout float pdf, inout bool valid, inout ReservoirFG reservoirFG, inout ReservoirCaustic reservoirCaustic) {
    RayPayload rayPayload = RayPayload();
    uint pathLength = 0;
    bool collectCaustics = !prevHitIsRough;
    uint bouncesAfterCaustic = collectCaustics ? 0 : 1; //Used to check if emissive light should be collected (is only performed on special occasions)
    float3 prevThp = float3(1); //Needed for reservoir
    for (pathLength; pathLength < gFGRayMaxPathLength && valid; pathLength++) {
        TraceRay(gScene.rtAccel, 0 /*Flags*/, 0xff /* instanceInclusionMask */, 0 /* hitIdx */, rayTypeCount, 0 /* missIdx */, ray, rayPayload);
        // Get surface hit info
        HitInfo hit = HitInfo(rayPayload.packedHitInfo);
        if (!hit.isValid()) {
            valid = false;
            //TODO add valid reservoir if envMap was hit
            return;
        }

        // Get shading infos
        let lod = ExplicitLodTextureSampler(0);

        // Get Material properties
        uint hints = (uint)MaterialInstanceHints::AdjustShadingNormal;
        ShadingData sd = loadShadingData(hit, ray.Direction, lod);
        let mi = gScene.materials.getMaterialInstance(sd, lod, hints);
        let bsdfProperties = mi.getProperties(sd);
        bool hitIsRough = bsdfProperties.roughness > kRoughnessThreshold;

        if (collectCaustics && hitIsRough) {
            reservoirCaustic.sampleSurface = hit.getData();
            reservoirCaustic.sampleSurfaceView = ray.Direction;
            reservoirCaustic.pathLength = pathLength + 1;
            reservoirCaustic.thp = thp;
            photonResampling(sd, bsdfProperties, true, reservoirCaustic, sg);
            collectCaustics = false;
        }

        //Check if this is a valid final gather surface
        if (hitIsRough && prevHitIsRough) {
            //Collect photons and fill reservoir
            reservoirFG.sampleData.radianceOut = collectPhotons(sd, mi, bsdfProperties.guideNormal, 0xFF, sg);
            if (pathLength > 0 && (bouncesAfterCaustic > 1)) //Path length == 0 is covered by ReSTIR DI
                reservoirFG.sampleData.radianceOut += bsdfProperties.emission;
            reservoirFG.thp = prevThp;
            reservoirFG.sampleData.posW = sd.posW;
            reservoirFG.sampleData.normal = sd.faceN; // Face normal?
            reservoirFG.wSum = 1.0 / pdf;
            reservoirFG.c = 1;
            float distanceToSample = distance(ray.Origin, sd.posW);
            reservoirFG.jacobianDeterminant = dot(reservoirFG.sampleData.normal, sd.V) / (distanceToSample * distanceToSample);

            return;
        }
        // Else

        //Update reservoir
        reservoirFG.sampleSurface = hit.getData(); // Update surface
        reservoirFG.pathLength++;                  // Increase path length
        reservoirFG.sampleData.sampleView = -ray.Direction;
        prevThp = thp;
        if(!collectCaustics)
            bouncesAfterCaustic++;

        //Next ray
        valid = generateFGSampleRay(sd, mi, sg, thp, pdf, ray);
        prevHitIsRough = hitIsRough;
    }
    valid = false;
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
    ReservoirFG finalGatherReservoir = ReservoirFG();
    ReservoirCaustic causticReservoir = ReservoirCaustic();

    if (hitInfo.isValid()) {
        //Set RTXDI data
        let lod = ExplicitLodTextureSampler(0);
        SampleGenerator sg = SampleGenerator(pixel, gFrameCount * 5 + 1);

        ShadingData sd = loadShadingData(hitInfo, -viewDir, lod);
        uint hints = (uint)MaterialInstanceHints::AdjustShadingNormal;
        let mi = gScene.materials.getMaterialInstance(sd, lod, hints);
        let bsdfProperties = mi.getProperties(sd);
        float distanceToSurface = distance(sd.posW, gScene.camera.getPosition());

        gRTXDI.setSurfaceData(pixel, sd.computeNewRayOrigin(), bsdfProperties.guideNormal, bsdfProperties.diffuseReflectionAlbedo, bsdfProperties.specularReflectance, bsdfProperties.roughness, distanceToSurface);

        bool hitIsRough = bsdfProperties.roughness > kRoughnessThreshold;

        //Init Caustic reservoir if photons can be collected at the current surface
        if (hitIsRough) {
            causticReservoir.sampleSurface = hitInfo.getData();
            causticReservoir.sampleSurfaceView = -viewDir;
            photonResampling(sd, bsdfProperties, false, causticReservoir, sg);
        }
            
        //Store surface
        finalGatherReservoir.sampleSurface = hitInfo.getData();
        finalGatherReservoir.sampleData.sampleView = viewDir;

        // Distribute a Final Gather ray
        RayDesc ray = {};
        ray.TMin = 0;
        ray.TMax = FLT_MAX;
        float3 fgThp = float3(1.0);
        float fgPdf = 0;
        bool validFGRay = generateFGSampleRay(sd, mi, sg, fgThp, fgPdf, ray);

        traceFGRay(ray, sg, hitIsRough, fgThp, fgPdf, validFGRay, finalGatherReservoir, causticReservoir);
    } else {
        // Set invalid RTXDI data
        gRTXDI.setInvalidSurfaceData(pixel);
    }

    gFinalGatherReservoir[index2Dto1D(pixel, dispatchDims.x)] = finalGatherReservoir;
    gCausticReservoir[index2Dto1D(pixel, dispatchDims.x)] = causticReservoir;
}
