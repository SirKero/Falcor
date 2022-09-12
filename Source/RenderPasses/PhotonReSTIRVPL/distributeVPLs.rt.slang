#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.Raytracing;
import Utils.Math.PackedFormats;
import Utils.Math.FormatConversion;
import Utils.Math.MathHelpers;
import Utils.Sampling.SampleGenerator;
import Rendering.Materials.StandardMaterial;
import Scene.Material.ShadingUtils;
import Rendering.Lights.LightHelpers;
import Utils.Color.ColorHelpers;
import Rendering.Lights.EmissiveLightSampler;
import Rendering.Lights.EmissiveLightSamplerHelpers;
import PhotonReStirFunctions;
import VPLs;
cbuffer PerFrame
{
    uint gFrameCount; // Frame count since scene was loaded.
    uint3 _pad1;
}

cbuffer CB
{
    bool gUseAlphaTest; //Max photon recursion depths
    bool gAdjustShadingNormals;
    uint2 gFrameDim;
    uint _pad1;
    uint gMaxNumberVPL; //max number of vpls
    uint _pad2;
};

RWStructuredBuffer<VPL> gVPLs;
RWBuffer<uint> gVPLCounter;
Texture2D<PackedHitInfo> gVBuffer;

/** Payload for scatter ray (16sB).
*/
struct RayData
{
    float  distance;            ///< Current path throughput. This is updated at each path vertex.
    uint   packedNormal;   ///< Face normal encoded in 16 bit polar coordinates
    bool diffuseHit;
    uint _pad;

    SampleGenerator sg;     ///< Per-ray state for the sample generator (up to 16B).
    
    /** Create ray payload with default parameters.
    */
    static RayData create()
    {
        RayData d;
        d._pad = 0;
        d.packedNormal = 0;
        d.distance = -1;
        d.diffuseHit = false;
        return d;
    }
};

[shader("miss")]
void miss(inout RayData rayData : SV_RayPayload)
{
    rayData.distance = -1;
}

[shader("closesthit")]
void closestHit(inout RayData rayData : SV_RayPayload, BuiltInTriangleIntersectionAttributes attribs : SV_IntersectionAttributes)
{
    const float3 incomingRayDir = -WorldRayDirection();
    // Evaluate Falcor's material parameters at the hit point.
    GeometryInstanceID instanceID = getGeometryInstanceID();
    VertexData v = getVertexData(instanceID, PrimitiveIndex(), attribs);
    const uint materialID = gScene.getMaterialID(instanceID);
    let lod = ExplicitLodTextureSampler(0.f);
    ShadingData sd = gScene.materials.prepareShadingData(v, materialID, incomingRayDir, lod);

    //Adjust shading normals if desired
    
    if (gAdjustShadingNormals)
    {
        adjustShadingNormal(sd, v);
    }
    
    BSDFSample bsdfSample;
    let bsdf = gScene.materials.getBSDF(sd, lod);
    let bsdfProperties = bsdf.getProperties(sd);

    bool valid = bsdf.sample(sd, rayData.sg, bsdfSample, true /*ImportanceSampling*/);    
    bool transmission = bsdfSample.isLobe(LobeType::Transmission);

    if(valid){
        rayData.distance = RayTCurrent();
        rayData.packedNormal = encodeNormal2x16(sd.N);
        rayData.diffuseHit = bsdfSample.isLobe(LobeType::Diffuse) && !transmission;
    }else{
        rayData.distance = -1.f;
    }
}

//Use anyhit for alpha test if activated
[shader("anyhit")]
void anyHit(inout RayData rayData : SV_RayPayload, BuiltInTriangleIntersectionAttributes attribs : SV_IntersectionAttributes)
{
    if (gUseAlphaTest)
    {
        // Alpha test for non-opaque geometry.
        GeometryInstanceID instanceID = getGeometryInstanceID();
        VertexData v = getVertexData(instanceID, PrimitiveIndex(), attribs);
        uint materialID = gScene.getMaterialID(instanceID);
        if (gScene.materials.alphaTest(v, materialID, 0.f))
            IgnoreHit();
    }
}

ShadingData loadShadingData(const HitInfo hit, const float3 rayDir, const ITextureSampler lod)
{
    const TriangleHit triangleHit = hit.getTriangleHit();
    VertexData v = gScene.getVertexData(triangleHit);
    uint materialID = gScene.getMaterialID(triangleHit.instanceID);
    ShadingData sd = gScene.materials.prepareShadingData(v, materialID, -rayDir, lod);
    adjustShadingNormal(sd, v);
    
    return sd;
}

[shader("raygeneration")]
void rayGen()
{
    uint2 launchIndex = DispatchRaysIndex().xy;
    uint2 launchDim = DispatchRaysDimensions().xy;

    RayData rd = RayData::create();
    rd.sg = SampleGenerator(launchIndex, gFrameCount + 2 * 13);    //TODO add seed offset

    //Get random shading data
    uint2 randomIndex = max(uint2(sampleNext2D(rd.sg) * float2(launchDim)),launchDim - 1);
    
    PackedHitInfo packedHitInfo = gVBuffer[randomIndex];
    HitInfo hitInfo = HitInfo(packedHitInfo);
          
    let lod = ExplicitLodTextureSampler(0.f);
    //Recreate the V-Buffer ray for direction
    Ray cameraRay = gScene.camera.computeRayPinhole(randomIndex, gFrameDim);
    //Get Material properties
    ShadingData sd = loadShadingData(hitInfo, cameraRay.dir, lod);
    BSDFSample bsdfSample;
    let bsdf = gScene.materials.getBSDF(sd, lod);
    let bsdfProperties = bsdf.getProperties(sd);

    bool valid = bsdf.sample(sd, rd.sg, bsdfSample, true /*ImportanceSampling*/);
    
    bool transmission = bsdfSample.isLobe(LobeType::Transmission);
    
    RayDesc ray;
    ray.Origin =  sd.computeNewRayOrigin(!transmission); //false is for transmissions
    ray.Direction = bsdfSample.wo;
    ray.TMin = 0.01f;
    ray.TMax = 10000.f;

    uint rayFlags = 0;

    TraceRay(gScene.rtAccel, rayFlags, 0xff /* instanceInclusionMask */, 0 /* hitIdx */, rayTypeCount, 0 /* missIdx */, ray, rd);

    //If hit is valid store
    if(rd.distance > 0 && rd.diffuseHit){
        VPL vpl = {};
        vpl.posW = ray.Origin + ray.Direction * rd.distance;
        vpl.packedNormal = rd.packedNormal;
        vpl.flux = float3(0);
        vpl.valid = 1;

        uint vplIndex = 0;
        InterlockedAdd(gVPLCounter[0], 1u, vplIndex);
        if(vplIndex < gMaxNumberVPL){
            gVPLs[vplIndex] = vpl;
        }
    }
}
