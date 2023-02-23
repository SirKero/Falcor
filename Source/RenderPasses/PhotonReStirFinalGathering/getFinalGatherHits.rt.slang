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
import Hash;

cbuffer PerFrame
{
    uint gFrameCount;       // Frame count since scene was loaded.
    float gCollectionRadius;
    float gHashScaleFactor; //Hash scale factor. 1/diameter
    bool gDiffuseOnly;    
}

cbuffer Constant{
    uint gHashSize;     //Size is always 2^x
    bool gUseAlphaTest; //Alpha test
}

// Inputs
Texture2D<PackedHitInfo> gVBuffer;
Texture2D<float4> gView;
Texture2D <float>gLinZ;

//Outputs
RWStructuredBuffer<PackedSurfaceData> gSurfaceData;
RWTexture2D<PackedHitInfo> gFinalGatherHit;
RWTexture2D<uint2> gFinalGatherExtraInfo;
RWTexture2D<uint> gPhotonCullingMask;
RWTexture2D<float> gValidNeighborsMask;

//Outputs
#if USE_REDUCED_RESERVOIR_FORMAT
    RWTexture2D<uint2> gReservoir;
#else
    RWTexture2D<uint4> gReservoir;
#endif

static const bool kUsePhotonCulling = USE_PHOTON_CULLING;
static const bool kAllowHitsInRadius = ALLOW_HITS_IN_RADIUS;    //Enables or disables hits inside of the collection radius
static const bool kFillMask = FILL_MASK;

struct TraceData{
    PackedHitInfo packedHitInfo;  //< Reflection albedo of the current hit point
    uint   packedNormal;   ///< Face normal encoded in 16 bit polar coordinates
    float pDiffuseRef;
    float  distance;            ///< 
    float NdotL;                ///< NdotL precalculated for targetPDF

    SampleGenerator sg;     ///< Per-ray state for the sample generator (up to 16B).
    
    /** Create ray payload with default parameters.
    */
    static TraceData create()
    {
        TraceData d;
        d.NdotL = 0.f;
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

void cullingGetArrayOfCells(float3 position, out int3 outCells[8]){
    float3 cell = (position.xyz * gHashScaleFactor);
    float3 cellFloor = floor(cell);
    cell = abs(cell - cellFloor);
    //Get offset direction
    int3 offsetCell;
    offsetCell.x = cell.x < 0.5 ? -1 : 1;
    offsetCell.y = cell.y < 0.5 ? -1 : 1;
    offsetCell.z = cell.z < 0.5 ? -1 : 1;

    //Fill the cell array
    outCells[0] = int3(cellFloor);
    outCells[1] = outCells[0] + int3(offsetCell.x, 0 ,0);
    outCells[2] = outCells[0] + int3(offsetCell.x, offsetCell.y ,0);
    outCells[3] = outCells[0] + int3(offsetCell.x, offsetCell.y ,offsetCell.z);
    outCells[4] = outCells[0] + int3(offsetCell.x, 0 ,offsetCell.z);
    outCells[5] = outCells[0] + int3(0, offsetCell.y ,0);
    outCells[6] = outCells[0] + int3(0, offsetCell.y ,offsetCell.z);
    outCells[7] = outCells[0] + int3(0, 0 ,offsetCell.z);
}

void photonCulling(float3 hitPos){
    //Get the 7 nearest neighbors (photon can still be in it)
    int3 cells[8];
    cullingGetArrayOfCells(hitPos, cells);

    //Insert them into the hash buffer
    [unroll]
    for(uint i=0; i<8; i++){
        uint h = hash(cells[i]) & (gHashSize - 1);    //calculateHash TODO: Test other hashes
        gPhotonCullingMask[ReSTIR_LinearIndexToZCurve(h)] = 1;
    }
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

    //Accept all hits but reject if the surface is only specular
    float pDiffuseRef = luminance(bsdfProperties.diffuseReflectionAlbedo + bsdfProperties.specularReflectionAlbedo) / luminance(norm);
    bool diffuseHit = luminance(bsdfProperties.diffuseReflectionAlbedo) > 0;    
    
    if(diffuseHit){
        rayData.distance = RayTCurrent();
        rayData.packedNormal = encodeNormal2x16(sd.N);
        rayData.pDiffuseRef = pDiffuseRef;
        rayData.packedHitInfo = HitInfo(triangleHit).getData();
        rayData.NdotL = saturate(dot(sd.N, incomingRayDir));
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
    if (!hitInfo.isValid())
    {
        gSurfaceData[index2Dto1D(launchIndex, launchDim.x)] = Surface().pack();
        if(kFillMask)
            gValidNeighborsMask[launchIndex] = 0.f;
    }
        

    float3 view = -gView[launchIndex].xyz;
    float linZ = gLinZ[launchIndex];
    let lod = ExplicitLodTextureSampler(0.f);
    ShadingData sd = loadShadingData(hitInfo, view, lod);
    let bsdf = gScene.materials.getBSDF(sd, lod);
    let bsdfProperties = bsdf.getProperties(sd);

    TraceData traceData = TraceData::create();
    traceData.sg = SampleGenerator(launchIndex, gFrameCount + 3 * 13);

    BSDFSample bsdfSample;
    //The final gather hit is considered diffuse as the V-Buffer only stops on diffuse surfaces
    sd.mtl.setActiveLobes((uint) LobeType::Reflection);
    bool valid = bsdf.sample(sd, traceData.sg, bsdfSample, true);
    
    //Fill Surface Buffer used for calculating the target PDF
    Surface surface = Surface::create(sd.computeNewRayOrigin(), sd.N, sd.V, linZ, bsdfProperties.roughness,
                                      luminance(bsdfProperties.diffuseReflectionAlbedo), luminance(bsdfProperties.specularReflectance));

    Reservoir reservoir = Reservoir();
    if (gDiffuseOnly)
        reservoir.targetPdf = surface.getDiffusePdf(bsdfSample.wo);
    else
        reservoir.targetPdf = surface.getPdf(bsdfSample.wo);
    
    reservoir.weightSum = 1.f / bsdfSample.pdf; // 1/selectPDF
    uint2 extraInfoPacked = uint2(0);

    RayDesc tRay;
    tRay.Origin = sd.computeNewRayOrigin();
    tRay.TMin = 0.0;
    tRay.TMax = 1000.f;
    tRay.Direction = bsdfSample.wo;
    
    if (valid)
    {
        TraceRay(gScene.rtAccel, 0, 0xff /* instanceInclusionMask */, 0 /* hitIdx */, rayTypeCount, 0 /* missIdx */, tRay, traceData);
        valid = traceData.distance >= 0;
    }
    
    if (valid)
    {
        reservoir.targetPdf *= traceData.NdotL;         //Precalculate NdotL
        reservoir.M = encodeNormal2x8(bsdfSample.wo);  //Store approximate direction in M temporarily to get the correct surface normal on double sided materials
        float3 hitPos = tRay.Origin + tRay.Direction * traceData.distance;
    
        if (kUsePhotonCulling)
        {
            photonCulling(hitPos);
        }

    //Reject hit points that are inside the collection radius
        if (!kAllowHitsInRadius)
        {
            float distDiff = distance(hitPos, sd.posW);
            //Invalidate hit data
            valid = distDiff > gCollectionRadius;
        }
    }

    
    if (!valid)
    {
        traceData.packedHitInfo = { };
        surface.viewDepth = -1.f; //Set to invalid depth
        reservoir.weightSum = 0.f;  //invalidate reseroir
    }
   
    //Store data in buffers
    gFinalGatherHit[launchIndex] = traceData.packedHitInfo;
    gSurfaceData[index2Dto1D(launchIndex, launchDim.x)] = surface.pack();
    #if USE_REDUCED_RESERVOIR_FORMAT
        gReservoir[launchIndex] = reservoir.packReduced();
    #else
        gReservoir[launchIndex] = reservoir.pack();
    #endif
}
