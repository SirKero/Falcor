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
import VPLs;

//Define for valid texture channels
#define is_valid(name) (is_valid_##name != 0)

#ifndef USE_BSDF_SAMPLING
#define USE_BSDF_SAMPLING 0
#endif

cbuffer PerFrame
{
    uint gFrameCount; // Frame count since scene was loaded.
}

cbuffer CB
{
    bool gUseAlphaTest;         //Alpha test
    uint2 gFrameDim;            //Size of the V-Buffer
    uint gMaxNumberVPL; //max number of vpls
};

RWTexture2D<PackedHitInfo> gVplSurface;
RWStructuredBuffer<PackedVPL> gVPLs;
RWTexture2D<uint> gVplUsageBuffer;
Texture2D<PackedHitInfo> gVBuffer;
Texture2D<float4> gView;

/** Payload for scatter ray (48sB).
*/
struct RayData
{
    PackedHitInfo packedHitInfo;  //< Reflection albedo of the current hit point
    uint   packedNormal;   ///< Face normal encoded in 16 bit polar coordinates
    bool diffuseHit;
    float  distance;            ///< Current path throughput. This is updated at each path vertex.
    uint _pad;

    SampleGenerator sg;     ///< Per-ray state for the sample generator (up to 16B).
    
    /** Create ray payload with default parameters.
    */
    static RayData create()
    {
        RayData d;
        d._pad = 0;
        d.packedHitInfo = {};
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
        rayData.diffuseHit = diffuseHit;
        rayData.packedHitInfo = HitInfo(triangleHit).getData();
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

//Trace a ray and write vpl if valid
void traceNewVPL(in RayData rd,const uint2 launchIndex,const uint vplIndex){
    //Get random shading data
    uint2 randomIndex = min(uint2(sampleNext2D(rd.sg) * float2(gFrameDim)),gFrameDim - 1);
    PackedHitInfo packedHitInfo = gVBuffer[randomIndex];
    HitInfo hitInfo = HitInfo(packedHitInfo);    
    let lod = ExplicitLodTextureSampler(0.f);

    //Get view dir
    float3 viewDir;
    if (is_valid(gView))
    {
        viewDir = -gView[launchIndex].xyz;
    }
    else
    {
        viewDir = gScene.camera.computeRayPinhole(randomIndex, gFrameDim).dir;
    }
    
    //Get Material properties
    ShadingData sd = loadShadingData(hitInfo, viewDir, lod);
    let bsdf = gScene.materials.getBSDF(sd, lod);
    let bsdfProperties = bsdf.getProperties(sd);

    //Only distribute on Reflections
    
    //All properties are guaranteed to be combined <= 1. Norm it to 1 to get the real diffuse Reflection probability
    float3 norm = bsdfProperties.diffuseReflectionAlbedo + bsdfProperties.diffuseTransmissionAlbedo + bsdfProperties.specularReflectionAlbedo + bsdfProperties.specularTransmissionAlbedo;

    float pReflection = luminance(bsdfProperties.diffuseReflectionAlbedo + bsdfProperties.specularReflectionAlbedo)/luminance(norm);

    float rnd = sampleNext1D(rd.sg);
    if(rnd > pReflection) return;
    
    //BSDF sampling
    
#if USE_BSDF_SAMPLING
    BSDFSample bsdfSample;
    sd.mtl.setActiveLobes((uint)LobeType::Reflection);
    bool valid = bsdf.sample(sd, rd.sg, bsdfSample, true);   
    float3 dir = bsdfSample.wo;
#else
    //Consine Sampling
    float3 dir = sample_cosine_hemisphere_polar(sampleNext2D(rd.sg));
    fromLocalToWorld(sd.faceN,dir);
#endif  
    
    RayDesc ray;
    ray.Origin =  sd.computeNewRayOrigin(); //false is for transmissions
    ray.Direction = dir;
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
        vpl.valid = true;
        vpl.age = 0;
              
        gVPLs[vplIndex] = vpl.pack();
        gVplSurface[ReSTIR_LinearIndexToZCurve(vplIndex)] = rd.packedHitInfo;
    }
}

static const uint kEliminationAge = 15;
static const float kEliminationAgePercantage = 0.3;

[shader("raygeneration")]
void rayGen()
{
    uint2 launchIndex = DispatchRaysIndex().xy;
    uint2 launchDim = DispatchRaysDimensions().xy;

    uint vplIndex = launchIndex.x + launchDim.x * launchIndex.y;

    if(vplIndex >= gMaxNumberVPL) return;   //Out of index

    //Random number generator
    RayData rd = RayData::create();
    rd.sg = SampleGenerator(launchIndex, gFrameCount + 0 * 13);    //TODO add seed offset

    //
    //VPL Feedback
    //
    
    //Get vpl infos
    VPL vpl = VPL(gVPLs[vplIndex]);
    const uint vplUsage = gVplUsageBuffer[ReSTIR_LinearIndexToZCurve(vplIndex)];

    //Get how often the vpl was used in the last 8 frames
    uint wasUsed = 0;
    uint vplUsageCopy = vplUsage;
    const uint checkedFrames = 4;
    for(uint i=0; i<checkedFrames; i++){
        wasUsed += vplUsageCopy & 1;
        vplUsageCopy >> 1;
    }
    //Different elemination strategies could be used. Random elimination based on not used percentage? Fixed eliminaton for not used
    bool replaceVPL = false;

    //is invalid or was not used
    if(!vpl.valid|| wasUsed == 0)
        replaceVPL = true;
    
    //Check if the vpl is too old
    /*
    if(vpl.age > kEliminationAge){
        if(sampleNext1D(rd.sg) < kEliminationAgePercantage)
            replaceVPL = true;
    }
*/
    //Write back usage shifted one to the left
    gVplUsageBuffer[ReSTIR_LinearIndexToZCurve(vplIndex)]  = (vplUsage << 1) & 0xFE;

    //Trace a new VPL if it should be replaced
    if(replaceVPL)
        traceNewVPL(rd, launchIndex, vplIndex);
}
