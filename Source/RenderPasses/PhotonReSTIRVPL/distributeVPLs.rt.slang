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

RWTexture2D<float4> gDebug;

/** Payload for scatter ray (48sB).
*/
struct RayData
{
    float3 diffuseReflectionAlbedo;  //< Reflection albedo of the current hit point
    float  distance;            ///< Current path throughput. This is updated at each path vertex.
    uint   packedNormal;   ///< Face normal encoded in 16 bit polar coordinates
    bool diffuseHit;
    uint2 _pad;

    SampleGenerator sg;     ///< Per-ray state for the sample generator (up to 16B).
    
    /** Create ray payload with default parameters.
    */
    static RayData create()
    {
        RayData d;
        d._pad = 0;
        d.diffuseReflectionAlbedo = float3(0);
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

    //All properties are guaranteed to be combined <= 1. Norm it to 1 to get the real diffuse Reflection probability
    float3 norm = bsdfProperties.diffuseReflectionAlbedo + bsdfProperties.diffuseTransmissionAlbedo + bsdfProperties.specularReflectionAlbedo + bsdfProperties.specularTransmissionAlbedo;

    float pDiffuseRef = luminance(bsdfProperties.diffuseReflectionAlbedo)/luminance(norm);
    
    float rnd = sampleNext1D(rayData.sg);
    bool diffuseHit = rnd <= pDiffuseRef; //Check if diffuse

    if(diffuseHit){
        rayData.distance = RayTCurrent();
        rayData.packedNormal = encodeNormal2x16(sd.N);
        rayData.diffuseHit = diffuseHit;
        rayData.diffuseReflectionAlbedo = bsdfProperties.diffuseReflectionAlbedo;
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

//transforms direction from local to world space
void fromLocalToWorld(in float3 lightDirW, inout float3 dir)
{
    //transform from local space -> random dir vector in world space
    float3 tangent, bitangent;
    if (abs(lightDirW.x) < 0.99)
        tangent = cross(lightDirW, float3(1., 0., 0.));
    else
        tangent = cross(lightDirW, float3(0., 1., 0.));
    tangent = normalize(tangent);
    bitangent = cross(tangent, lightDirW);

    dir = dir.x * tangent + dir.y * bitangent + dir.z * lightDirW;
}

[shader("raygeneration")]
void rayGen()
{
    uint2 launchIndex = DispatchRaysIndex().xy;
    uint2 launchDim = DispatchRaysDimensions().xy;
  
    RayData rd = RayData::create();
    rd.sg = SampleGenerator(launchIndex, gFrameCount + 2 * 13);    //TODO add seed offset

    //Get random shading data
    uint2 randomIndex = min(uint2(sampleNext2D(rd.sg) * float2(gFrameDim)),gFrameDim - 1);
    //uint2 randomIndex = launchIndex;
    gDebug[randomIndex] = float4(1,0,0,1);
    
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

    //Only distribute on Reflections
    
    //All properties are guaranteed to be combined <= 1. Norm it to 1 to get the real diffuse Reflection probability
    float3 norm = bsdfProperties.diffuseReflectionAlbedo + bsdfProperties.diffuseTransmissionAlbedo + bsdfProperties.specularReflectionAlbedo + bsdfProperties.specularTransmissionAlbedo;

    float pReflection = luminance(bsdfProperties.diffuseReflectionAlbedo + bsdfProperties.specularReflectionAlbedo)/luminance(norm);

    float rnd = sampleNext1D(rd.sg);
    if(rnd > pReflection) return;
    
    //BSDF sampling
    sd.mtl.setActiveLobes((uint)LobeType::Reflection);
    bool valid = bsdf.sample(sd, rd.sg, bsdfSample, true);
        
    RayDesc ray;
    ray.Origin =  sd.computeNewRayOrigin(); //false is for transmissions
    ray.Direction = bsdfSample.wo;
    ray.TMin = 0.01f;
    ray.TMax = 10000.f;
    

    /*
    float3 dir = sample_cosine_hemisphere_polar(sampleNext2D(rd.sg));
    fromLocalToWorld(sd.faceN,dir);
    
    //Cosine Sampling
    RayDesc ray;
    ray.Origin =  sd.computeNewRayOrigin();
    ray.Direction = dir;   //Cosine sampling     
    ray.TMin = 0.01f;
    ray.TMax = 10000.f;
    */
    uint rayFlags = 0;
    
    TraceRay(gScene.rtAccel, rayFlags, 0xff /* instanceInclusionMask */, 0 /* hitIdx */, rayTypeCount, 0 /* missIdx */, ray, rd);

    //If hit is valid store
    if(rd.distance > 0 && rd.diffuseHit){
        VPL vpl = {};
        vpl.posW = ray.Origin + ray.Direction * rd.distance;
        vpl.packedNormal = rd.packedNormal;
        vpl.flux = float3(0);
        vpl.valid = 1;
        vpl.age = 0;

        uint vplIndex = 0;
        InterlockedAdd(gVPLCounter[0], 1u, vplIndex);

        /* IF full randomly choose an intervall
        if(vplIndex < gMaxNumberVPL){
          vplIndex = min(uint(sampleNext1D(rd.sg) * float(vplIndex)), vplIndex-1);  
        }
        */
        
        if(vplIndex < gMaxNumberVPL){
            gVPLs[vplIndex] = vpl;
            
        }
    }
}
