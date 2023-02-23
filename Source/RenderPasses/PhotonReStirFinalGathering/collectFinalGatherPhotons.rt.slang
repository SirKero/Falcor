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
    float gPhotonRadius; // Scale for the emissive part
}

// Inputs
StructuredBuffer<uint4> gPackedPhotonData;
StructuredBuffer<AABB> gPhotonAABB;
Texture2D<PackedHitInfo> gFinalGatherHit;

RaytracingAccelerationStructure gPhotonAS;

//Outputs
#if USE_REDUCED_RESERVOIR_FORMAT
    RWTexture2D<uint2> gReservoir;
#else
    RWTexture2D<uint4> gReservoir;
#endif
RWStructuredBuffer<PackedVPL> gPhotonLights;

/** Payload for ray (48B).
*/
struct RayData
{
    float3 radiance;                ///< Accumulated outgoing radiance from path.
    uint _pad;                      ///< packed normal
    float3 diffuseReflectance;       //<Diffuse reflectance of the vpl
    uint _pad2;
      
    __init(){
        radiance = float3(0);
        diffuseReflectance = float3(0);
    }
};

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
void miss(inout RayData rayData : SV_RayPayload)
{
    //Empty. Is needed for compilation
}

[shader("anyhit")]
void anyHit(inout RayData rayData : SV_RayPayload, SphereAttribs attribs : SV_IntersectionAttributes)
{    
    const uint primIndex = PrimitiveIndex();
    const float3 normal = WorldRayDirection();
    //Get Photon data
    PhotonData pd = PhotonData(gPackedPhotonData[primIndex]);
    //Evaluate diffuse BRDF
    if(dot(pd.normal, normal) < 0.6){
        return;
    }
    const float NdotL = saturate(dot(normal, pd.dir));
    const float3 diffuseBrdf =  rayData.diffuseReflectance * NdotL * M_1_PI;
   
    rayData.radiance += diffuseBrdf * pd.flux;
}

//Checks if the ray start point is inside the sphere.
bool hitSphere(const float3 center, const float radius, const float3 p)
{
    float3 toCenter = p - center;
    return dot(toCenter, toCenter) < radius * radius;
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
    attribs.distance = distance(photonAABB.center(), origin)/gPhotonRadius;

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

    Reservoir r = Reservoir(gReservoir[launchIndex]);
    float3 approxViewDir = decodeNormal2x8(r.M);    //Approximate direction is stored in M
    r.M = 1;    //set M to the right value

    HitInfo hitInfo = HitInfo(gFinalGatherHit[launchIndex]);    

    VPL photonLight = { };
    
    if (hitInfo.isValid())
    {
        let lod = ExplicitLodTextureSampler(0.f);
        ShadingData sd = loadShadingData(hitInfo, approxViewDir, lod);
        let bsdf = gScene.materials.getBSDF(sd, lod);
        let bsdfProperties = bsdf.getProperties(sd);
            
        //Prepare payload
        RayData rayData = RayData();
        rayData.diffuseReflectance = bsdfProperties.diffuseReflectionAlbedo; //Diffuse reflectance is stored in flux before collection
        float diffProb = luminance(bsdfProperties.diffuseReflectionAlbedo);
        float3 specProb = bsdfProperties.specularReflectance;
        float3 diffFactor = float3(0.f);
        if (diffProb > 0.f)
            diffFactor = (rayData.diffuseReflectance + specProb) / rayData.diffuseReflectance;
        rayData.diffuseReflectance *= diffFactor; //Diffuse reflectance is stored in flux before collection
        rayData.radiance = float3(0.f);
    
        //Ray description 
        RayDesc ray;
        ray.Origin = sd.posW;
        ray.TMin = 0.0;
        ray.TMax = 0.0001;
        ray.Direction = sd.N; //Use as Normal

        //Closest hit shader can be skipped
        uint rayFlags = RAY_FLAG_SKIP_CLOSEST_HIT_SHADER | RAY_FLAG_SKIP_TRIANGLES;
    
        TraceRay(gPhotonAS, rayFlags, 1 /* instanceInclusionMask */, 0 /* hitIdx */, 0 /* rayType count */, 0 /* missIdx */, ray, rayData);
        float3 radiance = rayData.radiance / (M_PI * gPhotonRadius * gPhotonRadius); //Get new flux
  
        //ReSTIR Candidate
        uint lightIdx = index2Dto1D(launchIndex, launchDim.x);
        float Li = luminance(radiance);

        r.targetPdf *= Li;
    
        //Create the light
        bool vplValid = true;
        if (any(isnan(radiance)) || any(isinf(radiance)))
            vplValid = false;
        photonLight.posW = sd.computeNewRayOrigin();
        photonLight.normal = sd.N;
        photonLight.flux = radiance;
        photonLight.valid = vplValid;

    
        if (!vplValid || Li <= 0)
        {
            r.weightSum = 0.f;  //No contribution
        }
    }
   

#if USE_REDUCED_RESERVOIR_FORMAT
    gReservoir[launchIndex] = r.packReduced();
#else
    gReservoir[launchIndex] = r.pack();
#endif
    gPhotonLights[index2Dto1D(launchIndex, launchDim.x)] = photonLight.pack();        
}
