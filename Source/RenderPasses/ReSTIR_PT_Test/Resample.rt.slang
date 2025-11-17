#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.Raytracing;
import Scene.RaytracingInline;
import Utils.Sampling.SampleGenerator;
import Utils.Color.ColorHelpers;
import Rendering.Lights.LightHelpers;
import SharedStructsAndFunctions;

cbuffer CB
{
    uint gFrameCount; // Current FrameCount for RNG
    uint gMaxBounces; //Max indirections
}

Texture2D<PackedHitInfo> gVBuffer;
Texture2D<float4> gView;
Texture2D<float2> gMVec;
StructuredBuffer<ReservoirPT> gReservoirPrev;
RWStructuredBuffer<ReservoirPT> gReservoir;

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

bool sampleNewRay(ShadingData sd, IMaterialInstance mi, inout SampleGenerator sg, float3 thp, inout RayDesc ray)
{
    BSDFSample bsdfSample;
    bool validSample = mi.sample(sd, sg, bsdfSample, true);
    if (validSample) {
        bool transmission = bsdfSample.isLobe(LobeType::Transmission);
        ray.Origin = sd.computeNewRayOrigin(!transmission); // false is for transmissions
        ray.Direction = bsdfSample.wo;
        thp *= bsdfSample.weight;
    }

    return validSample && any(thp > 0);
}

bool resampleReservoir(int2 pixel, uint2 dispatchDims, inout ReservoirPT reservoir, ShadingData sd, inout SampleGenerator sg)
{
    // Check if reservoir is inside the screen.
    if (any(pixel < 0) || any(pixel >= dispatchDims))
        return false;

    // Fetch the (spatio)temporal reservoir
    ReservoirPT temporalR = gReservoirPrev[index2Dto1D(pixel, dispatchDims.x)];
    if (temporalR.wSum <= 0)
        return false;

    RayDesc ray = {};
    ray.TMin = 0;
    ray.TMax = FLT_MAX;
    ray.Origin = gScene.camera.getPosition();
    ray.Direction = sd.V;
    SampleGenerator pathSg = SampleGenerator(temporalR.rngPixel, temporalR.rngSeed);
    let lod = ExplicitLodTextureSampler(0);

    float3 thp = float3(0);
    bool validTemporalReservoir = false;
    // Retrace temporal path
    for (uint pathLength = 0; pathLength >= temporalR.pathLength; pathLength++)
    {
        //Trace ray
        if (pathLength > 0) {
            RayPayload rayPayload = RayPayload();
            TraceRay(gScene.rtAccel, 0 /*Flags*/, 0xff /* instanceInclusionMask */, 0 /* hitIdx */, rayTypeCount, 0 /* missIdx */, ray, rayPayload);
            HitInfo hit = HitInfo(rayPayload.packedHitInfo);
            if (!hit.isValid()) {
                // TODO handle properly, can be valid if the original hit was delta -> envMap
                break;
            }
            sd = loadShadingData(hit, ray.Direction, lod);
        }

        //Load shading structs
        let mi = gScene.materials.getMaterialInstance(sd, lod, kMIHints);
        let bsdfProperties = mi.getProperties(sd);
        bool surfaceIsDiffuse = (bsdfProperties.roughness > kRoughnessThreshold); // Either diffuse surface or emissive hit
        bool surfaceIsEmissive = any(bsdfProperties.emission > 0);
        // Reconnect surface
        if (pathLength == temporalR.pathLength && (surfaceIsDiffuse || surfaceIsEmissive))
        {
            if (surfaceIsEmissive || temporalR.jacobianDeterminant < 0)
                break; //TODO handle this case

            // Get original resampling surface
            //ShadingData temporalSd = loadShadingData(HitInfo(temporalR.reconnectionSurface), temporalR.reconnectionSurfaceIncomingDir, lod);

            // TODO MIS?
            float3 toSample = temporalR.samplePosW - sd.posW;
            float distToSample = length(toSample);
            toSample /= distToSample;
            float3 bsdf = mi.eval(sd, toSample, sg) * thp;
            float jacobianDeterminantFromNew = dot(temporalR.sampleFaceN, -toSample) / (distToSample * distToSample);
            float jacobianDeterminant = jacobianDeterminantFromNew / temporalR.jacobianDeterminant;

            temporalR.wSum *= luminance(bsdf * temporalR.sampleRadiance * jacobianDeterminant);
            temporalR.jacobianDeterminant = jacobianDeterminantFromNew;
            // temporalR.reconnectionSurface = //TODO
            temporalR.reconnectionSurfaceIncomingDir = sd.V;
            temporalR.reconnectionThp = bsdf;

            //validTemporalReservoir = true;
        }
        //Or sample ray for next iteration
        else if (pathLength < temporalR.pathLength) {
            sampleNewRay(sd, mi, pathSg, thp, ray);
        }
    }

    if (validTemporalReservoir) {
        // Prepare current reservoir for resampling (W -> w)
        reservoir.wSum *= luminance(reservoir.sampleRadiance * reservoir.reconnectionThp);
    }

    return true;
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
    ReservoirPT reservoir = ReservoirPT();

    if (hitInfo.isValid()) {
        SampleGenerator sg = SampleGenerator(pixel, gFrameCount * 5 + 3);
        reservoir = gReservoir[index2Dto1D(pixel, dispatchDims.x)];

        let lod = ExplicitLodTextureSampler(0);
        ShadingData sd = loadShadingData(hitInfo, viewDir, lod);

        //
        // Temporal Resampling
        //

        // Reproject to the previous pixel using the motion vectors
        float2 motionOffset = gMVec[pixel] * float2(dispatchDims);
        float2 prevPixelF = motionOffset + float2(pixel) + float2(0.5);
        float2 rndOffset = sampleNext2D(sg) - 0.5;
        prevPixelF += rndOffset;
        int2 prevPixel = int2(prevPixelF);


    }

    gReservoir[index2Dto1D(pixel, dispatchDims.x)] = reservoir;
}
