#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.Raytracing;
import Scene.Intersection;
import Utils.Math.MathHelpers;
import Utils.Sampling.SampleGenerator;
import Scene.Material.ShadingUtils;
import Rendering.Materials.StandardMaterial;
import Rendering.Materials.Microfacet;
import Rendering.Materials.Fresnel;
import Rendering.Lights.LightHelpers;
import Utils.Math.PackedFormats;
import Utils.Math.FormatConversion;
import Utils.Color.ColorHelpers;

import Reservoir;
import VPLs;
import SurfaceData;

cbuffer PerFrame
{
    uint gFrameCount;       // Frame count since scene was loaded.
}


// Inputs
Texture2D<PackedHitInfo> gVBuffer;
Texture2D<float4> gView;
Texture2D <float>gLinZ;

//Outputs
RWStructuredBuffer<PackedSurfaceData> gSurfaceData;
RWTexture2D<PackedHitInfo> gFinalGatherHit;
RWTexture2D<uint2> gFinalGatherExtraInfo;

struct TraceData{
    PackedHitInfo packedHitInfo;  //< Reflection albedo of the current hit point
    uint   packedNormal;   ///< Face normal encoded in 16 bit polar coordinates
    float pDiffuseRef;
    float  distance;            ///< 
    uint _pad;

    SampleGenerator sg;     ///< Per-ray state for the sample generator (up to 16B).
    
    /** Create ray payload with default parameters.
    */
    static TraceData create()
    {
        TraceData d;
        d._pad = 0;
        d.packedHitInfo = {};
        d.packedNormal = 0;
        d.distance = -1;
        d.pDiffuseRef = 0.f;
        return d;
    }
}

struct SphereAttribs
{
    float distance;
};

struct LightSample{
    uint lightIdx;
    float3 dir;
    float Li;
    float invSelectPdf;
    float2 uv;
    //Enum type later ? 
};

uint index2Dto1D(uint2 idx, uint width){
    return idx.x + width * idx.y;
}

//Load in shading data from hit and direction
ShadingData loadShadingData(const HitInfo hit, const float3 rayDir, const ITextureSampler lod)
{
    const TriangleHit triangleHit = hit.getTriangleHit();
    VertexData v = gScene.getVertexData(triangleHit);
    uint materialID = gScene.getMaterialID(triangleHit.instanceID);
    ShadingData sd = gScene.materials.prepareShadingData(v, materialID, -rayDir, lod);
    adjustShadingNormal(sd, v);
    
    return sd;
}

[shader("miss")]
void miss(inout TraceData rayData : SV_RayPayload)
{
    rayData.distance = -1.f;
}

//TODO: Enable
//Use anyhit for alpha test if activated
[shader("anyhit")]
void anyHit(inout TraceData rayData : SV_RayPayload, BuiltInTriangleIntersectionAttributes attribs : SV_IntersectionAttributes)
{
    /*
    if (gUseAlphaTest)
    {
        // Alpha test for non-opaque geometry.
        GeometryInstanceID instanceID = getGeometryInstanceID();
        VertexData v = getVertexData(instanceID, PrimitiveIndex(), attribs);
        uint materialID = gScene.getMaterialID(instanceID);
        if (gScene.materials.alphaTest(v, materialID, 0.f))
            IgnoreHit();
    }
    */
}

[shader("closesthit")]
void closestHit(inout TraceData rayData : SV_RayPayload, BuiltInTriangleIntersectionAttributes attribs : SV_IntersectionAttributes){
    const float3 incomingRayDir = -WorldRayDirection();
    // Evaluate Falcor's material parameters at the hit point.
    TriangleHit triangleHit;
    triangleHit.instanceID = getGeometryInstanceID();
    triangleHit.primitiveIndex = PrimitiveIndex();
    triangleHit.barycentrics = attribs.barycentrics;
    VertexData v = getVertexData(triangleHit.instanceID, PrimitiveIndex(), attribs);
    const uint materialID = gScene.getMaterialID(triangleHit.instanceID);
    let lod = ExplicitLodTextureSampler(0.f);
    ShadingData sd = gScene.materials.prepareShadingData(v, materialID, incomingRayDir, lod);
        
    BSDFSample bsdfSample;
    let bsdf = gScene.materials.getBSDF(sd, lod);
    let bsdfProperties = bsdf.getProperties(sd);

    //All properties are guaranteed to be combined <= 1. Norm it to 1 to get the real diffuse Reflection probability
    float3 norm = bsdfProperties.diffuseReflectionAlbedo + bsdfProperties.diffuseTransmissionAlbedo + bsdfProperties.specularReflectionAlbedo + bsdfProperties.specularTransmissionAlbedo;

    float pDiffuseRef = luminance(bsdfProperties.diffuseReflectionAlbedo)/luminance(norm);
    
    float rnd = sampleNext1D(rayData.sg);
    bool diffuseHit = rnd <= pDiffuseRef; //Check if diffuse

    if(diffuseHit){
        rayData.distance = RayTCurrent();
        rayData.packedNormal = encodeNormal2x16(sd.N);
        rayData.pDiffuseRef = pDiffuseRef;
        rayData.packedHitInfo = HitInfo(triangleHit).getData();
    }else{
        rayData.distance = -1.f;
    }
}

[shader("raygeneration")]
void rayGen()
{
    uint2 launchIndex = DispatchRaysIndex().xy;
    uint2 launchDim = DispatchRaysDimensions().xy;
    
    HitInfo hitInfo = HitInfo(gVBuffer[launchIndex]);
    if(!hitInfo.isValid())
        gSurfaceData[index2Dto1D(launchIndex, launchDim.x)] = Surface().pack();

    float3 view = -gView[launchIndex].xyz;
    float linZ = gLinZ[launchIndex];
    let lod = ExplicitLodTextureSampler(0.f);
    ShadingData sd = loadShadingData(hitInfo, view, lod);
    let bsdf = gScene.materials.getBSDF(sd, lod);
    let bsdfProperties = bsdf.getProperties(sd);

    TraceData traceData = TraceData::create();
    traceData.sg = SampleGenerator(launchIndex, gFrameCount + 15 * 13);    //TODO add seed offset

    BSDFSample bsdfSample;
    bool valid = bsdf.sample(sd, traceData.sg, bsdfSample, true);

    //Fill Surface Buffer used for calculating the target PDF
    Surface surface = Surface::create(sd.computeNewRayOrigin(), sd.N, sd.V, linZ, bsdfProperties.roughness,
                                      luminance(bsdfProperties.diffuseReflectionAlbedo), luminance(bsdfProperties.specularReflectance));


    float targetPdf = surface.getPdf(bsdfSample.wo);
    
    RayDesc tRay;
    tRay.Origin = sd.computeNewRayOrigin();
    tRay.TMin = 0.0;
    tRay.TMax = 1000.f;
    tRay.Direction = bsdfSample.wo;    //Use as Normal

    TraceRay(gScene.rtAccel, 0, 0xff /* instanceInclusionMask */, 0 /* hitIdx */, rayTypeCount, 0 /* missIdx */, tRay, traceData);

    
    float selectPdf = bsdfSample.pdf * traceData.pDiffuseRef;

    uint2 extraInfoPacked = uint2((f32tof16(targetPdf) << 16) | f32tof16(selectPdf), encodeNormal2x16(bsdfSample.wo));
    
    //Store data in buffers
    gFinalGatherHit[launchIndex] = traceData.packedHitInfo;
    gFinalGatherExtraInfo[launchIndex] = extraInfoPacked;
    gSurfaceData[index2Dto1D(launchIndex, launchDim.x)] = surface.pack();
}
