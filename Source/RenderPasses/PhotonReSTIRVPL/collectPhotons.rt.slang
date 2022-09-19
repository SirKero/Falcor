#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.Raytracing;
import Scene.Intersection;
import Utils.Math.MathHelpers;
import Utils.Sampling.SampleGenerator;
import Scene.Material.ShadingUtils;
import Rendering.Materials.StandardMaterial;
import Rendering.Lights.LightHelpers;
import Utils.Math.PackedFormats;
import Utils.Math.FormatConversion;
import Utils.Color.ColorHelpers;

import VPLs;

cbuffer PerFrame
{
    uint gFrameCount;       // Frame count since scene was loaded.
}

cbuffer CB
{
    float gPhotonRadius; // Scale for the emissive part
    uint gMaxVPLs;
    uint2 _pad;
};

// Inputs
Buffer<uint> gVPLCounter;
Buffer<uint> gPhotonCounter;
StructuredBuffer<uint4> gPackedPhotonData;
StructuredBuffer<AABB> gPhotonAABB;

RaytracingAccelerationStructure gPhotonAS;

// Outputs
RWStructuredBuffer<VPL> gVPLs;
RWTexture2D<float> gLightPdf;


// Static configuration based on defines set from the host.
static const uint kPhotonBufferSize = PHOTON_BUFFER_SIZE;
static const bool kUsePdfSampling = USE_PDF_SAMPLING;

/** Payload for ray (48B).
*/
struct RayData
{
    float3 radiance;                ///< Accumulated outgoing radiance from path.
    uint packedNormal;                      ///< packed normal
    float3 diffuseReflectance;       //<Diffuse reflectance of the vpl
    uint _pad;         

    SampleGenerator sg;             ///< Per-ray state for the sample generator (up to 16B).
  
    __init(){
        radiance = float3(0);
        packedNormal = 0;
        diffuseReflectance = float3(0);
        _pad = 0;
    }

    //Shading world normal
    property float3 normal{
        get { return decodeNormal2x16(packedNormal); }
        set { packedNormal = encodeNormal2x16(newValue); }
    }
};

struct SphereAttribs
{
    float2 pad;
};

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
void miss(inout RayData rayData : SV_RayPayload)
{
    //Empty. Is needed for compilation
}


[shader("anyhit")]
void anyHit(inout RayData rayData : SV_RayPayload, SphereAttribs attribs : SV_IntersectionAttributes)
{    
    const uint primIndex = PrimitiveIndex();

    //Get Photon data
    PhotonData pd = PhotonData(gPackedPhotonData[primIndex]);
    
    //Evaluate diffuse BRDF
    /*
    const float NdotL = saturate(dot(rayData.normal, pd.dir));
    const float3 diffuseBrdf =  rayData.diffuseReflectance * NdotL * M_1_PI;
    
    rayData.radiance += diffuseBrdf * pd.flux;
    */
    rayData.radiance += pd.flux;
}

//Checks if the ray start point is inside the sphere.
bool hitSphere(const float3 center, const float radius, const float3 p)
{
    float3 radiusTest = p - center;
    radiusTest = radiusTest * radiusTest;
    float radiusTestF = radiusTest.x + radiusTest.y + radiusTest.z;
    if (radiusTestF < radius * radius)
        return true;
    return false;
}

[shader("intersection")]
void intersection()
{
    //Get start point and prim index
    const float3 origin = ObjectRayOrigin();
    const uint primIndex = PrimitiveIndex();

    //Get Photon AABB. Instance Index 0 is caustic; 1 is global
    AABB photonAABB = gPhotonAABB[primIndex];
    
    //Check for Sphere intersection
    bool tHit = hitSphere(photonAABB.center(), gPhotonRadius, origin);

    //Attribs are needed by the api. Because we have no need for additional attributes it is empty
    SphereAttribs attribs;
    attribs.pad = float2(0);

    //Report the hit if the point is in the sphere
    if (tHit)
    {
        ReportHit(RayTCurrent(), 0, attribs);
    }
}


[shader("raygeneration")]
void rayGen()
{
    uint2 launchIndex = DispatchRaysIndex().xy;
    uint2 launchDim = DispatchRaysDimensions().xy;
    uint index = launchIndex.x + launchDim.x * launchIndex.y;

    // Return for invalid vpl indices
    uint numberVPL = min(gVPLCounter[0], gMaxVPLs);
    if(index >= numberVPL)
        return;
    
    //Get current VPL
    VPL vpl = gVPLs[index];
    
    //Prepare payload
    RayData rayData = RayData();
    rayData.sg = SampleGenerator(launchIndex, gFrameCount + 9 * 13);
    rayData.diffuseReflectance = vpl.flux;          //Diffuse reflectance is stored in flux before collection
    rayData.packedNormal = vpl.packedNormal;
    
    //Ray description 
    RayDesc ray;
    ray.Origin = vpl.posW;
    ray.TMin = 0.0;
    ray.TMax = 0.0001;
    ray.Direction = float3(0,1,0);    //Dont care for direction

    //Closest hit shader can be skipped
    uint rayFlags = RAY_FLAG_SKIP_CLOSEST_HIT_SHADER | RAY_FLAG_SKIP_TRIANGLES;
    
    TraceRay(gPhotonAS, rayFlags, 0xFF /* instanceInclusionMask */, 0 /* hitIdx */, 0 /* rayType count */, 0 /* missIdx */, ray, rayData);
    float3 radiance = rayData.radiance / (M_PI * gPhotonRadius * gPhotonRadius);    //Get new flux
    radiance *= 0.008;   //TODO: Remove this factor
    
    if (vpl.age > 0 )
    {
        vpl.flux = vpl.flux * vpl.age;
    }
    vpl.age = vpl.age + 1;
    vpl.flux += radiance;
    vpl.flux /= vpl.age;
    
    
    //Write vpl back
    gVPLs[index] = vpl;
    if(kUsePdfSampling)
        gLightPdf[ReSTIR_LinearIndexToZCurve(index)] = luminance(vpl.flux);
}
