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
    uint gMaxBounces; // Max indirections
    uint gConfidenceCap;
    uint gSpatialSamples;

    float gSpatialSampleRadius;
}

Texture2D<PackedHitInfo> gVBuffer;
Texture2D<float4> gView;
Texture2D<float2> gMVec;
StructuredBuffer<ReservoirPT> gReservoirPrev;
RWStructuredBuffer<ReservoirPT> gReservoir;
RWTexture2D<float4> gDebug;

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

bool resampleReservoir(int2 pixel, uint2 dispatchDims, inout ReservoirPT reservoir, HitInfo hit, float3 viewDir, inout SampleGenerator sg)
{
    // Check if reservoir is inside the screen.
    if (any(pixel < 0) || any(pixel >= dispatchDims))
        return false;

    // Fetch the (spatio)temporal reservoir
    ReservoirPT temporalR = gReservoirPrev[index2Dto1D(pixel, dispatchDims.x)];
    if (temporalR.wSum <= 0 || temporalR.pathLength >= gMaxBounces)
        return false;

    RayDesc ray = {};
    ray.TMin = 0;
    ray.TMax = FLT_MAX;
    ray.Origin = gScene.camera.getPosition();
    ray.Direction = viewDir;
    SampleGenerator pathSg = SampleGenerator(temporalR.rngPixel, temporalR.rngSeed);
    let lod = ExplicitLodTextureSampler(0);

    float3 thp = float3(1);
    bool validTemporalReservoir = false;
    // Retrace temporal path
    
    for (uint pathLength = 0; pathLength <= temporalR.pathLength; pathLength++)
    {
        //Trace ray
        if (pathLength > 0) {
            RayPayload rayPayload = RayPayload();
            TraceRay(gScene.rtAccel, 0 , 0xff , 0 , rayTypeCount, 0, ray, rayPayload);
            hit = HitInfo(rayPayload.packedHitInfo);
            
        }

        if (!hit.isValid()) {
            if (temporalR.jacobianDeterminant < 0 && pathLength == temporalR.pathLength) {
                temporalR.sampleRadiance = gScene.envMap.eval(ray.Direction);
                temporalR.wSum *= luminance(thp * temporalR.sampleRadiance);
                temporalR.reconnectionThp = thp;
                validTemporalReservoir = temporalR.wSum > 0;
            }
            break;
        }

        ShadingData sd = loadShadingData(hit, ray.Direction, lod);

        //Load shading structs
        let mi = gScene.materials.getMaterialInstance(sd, lod, kMIHints);
        let bsdfProperties = mi.getProperties(sd);
        bool surfaceIsDiffuse = (bsdfProperties.roughness > kRoughnessThreshold); // Either diffuse surface or emissive hit
        bool surfaceIsEmissive = any(bsdfProperties.emission > 0);
                
        // Reconnect surface
        if (pathLength == temporalR.pathLength && (surfaceIsDiffuse || surfaceIsEmissive))
        {
            float3 reconnectionThp = float3(0);
            float updatedJacobianDeterminant = -1;
            float jacobianDeterminant = 1;
            if (surfaceIsEmissive && temporalR.jacobianDeterminant < 0)
            {
                temporalR.sampleRadiance = bsdfProperties.emission;
                reconnectionThp = thp;
            } else if (surfaceIsDiffuse && temporalR.jacobianDeterminant > 0) {
                // TODO MIS?

                float3 toSample = temporalR.samplePosW - sd.posW;
                float distToSample = length(toSample);
                toSample /= distToSample;
                reconnectionThp = mi.eval(sd, toSample, sg) * thp;
                updatedJacobianDeterminant = dot(temporalR.sampleFaceN, -toSample) / (distToSample * distToSample);
                jacobianDeterminant = updatedJacobianDeterminant / temporalR.jacobianDeterminant;
                temporalR.reconnectionSurface = hit.getData();
                temporalR.reconnectionSurfaceIncomingDir = sd.V;
            }

            temporalR.wSum *= luminance(reconnectionThp * temporalR.sampleRadiance * jacobianDeterminant);
            temporalR.reconnectionThp = reconnectionThp;
            temporalR.jacobianDeterminant = updatedJacobianDeterminant;
            validTemporalReservoir = temporalR.wSum > 0;
        }
        else if (surfaceIsEmissive) {
            break;
        }            
        //Or sample ray for next iteration
        else if (pathLength < temporalR.pathLength) {
            sampleNewRay(sd, mi, pathSg, thp, ray);
        }
    }

    uint cSum = reservoir.c + temporalR.c;
    if (validTemporalReservoir) {
        // Prepare current reservoir for resampling (W -> w)
        float mis = float(reservoir.c) / float(cSum);
        reservoir.wSum *= mis * luminance(reservoir.sampleRadiance * reservoir.reconnectionThp);
        mis = float(temporalR.c) / float(cSum);
        temporalR.wSum *= mis;

        float wSum = reservoir.wSum + temporalR.wSum;
        bool selectOtherSample = (sampleNext1D(sg) * reservoir.wSum) <= temporalR.wSum;
        if (selectOtherSample) {
            reservoir = temporalR;
        }
        
        if(any(reservoir.sampleRadiance > 0))
            reservoir.wSum = wSum / luminance(reservoir.sampleRadiance * reservoir.reconnectionThp);
        else
            reservoir.wSum = 0;
            
    cSum = min(cSum, gConfidenceCap);
    reservoir.c = cSum;
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

        //
        // Temporal Resampling
        //

        // Reproject to the previous pixel using the motion vectors
        float2 motionOffset = gMVec[pixel] * float2(dispatchDims);
        float2 prevPixelF = motionOffset + float2(pixel) + float2(0.5);
        float2 rndOffset = sampleNext2D(sg) - 0.5;
        prevPixelF += rndOffset;
        int2 prevPixel = int2(prevPixelF);

        resampleReservoir(pixel, dispatchDims, reservoir, hitInfo, viewDir, sg);

        //TODO Spatial Resampling

    }

    gReservoir[index2Dto1D(pixel, dispatchDims.x)] = reservoir;
}
