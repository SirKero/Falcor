#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.Raytracing;
import Scene.Intersection;
import Utils.Math.MathHelpers;
import Utils.Sampling.SampleGenerator;
import Scene.Material.ShadingUtils;
import Rendering.Materials.StandardMaterial;
import Rendering.Materials.Microfacet;
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
    uint gVplAgeCap;   // Maximum age the vpl is caped
    uint _pad;
};

// Inputs
Buffer<uint> gPhotonCounter;
Texture2D<PackedHitInfo> gVplSurface;
Texture2D<float> gVplPdf;
StructuredBuffer<uint4> gPackedPhotonData;
StructuredBuffer<AABB> gPhotonAABB;

RaytracingAccelerationStructure gPhotonAS;

// Outputs
RWStructuredBuffer<PackedVPL> gVPLs;
RWTexture2D<float> gLightPdf;


// Static configuration based on defines set from the host.
static const uint kPhotonBufferSize = PHOTON_BUFFER_SIZE;
static const bool kUsePdfSampling = USE_PDF_SAMPLING;

/** Payload for ray (48B).
*/
struct RayData
{
    float3 radiance;                ///< Accumulated outgoing radiance from path.
    float weightSum;                      ///< packed normal
    float3 diffuseReflectance;       //<Diffuse reflectance of the vpl
    uint _pad2;
      
    __init(){
        radiance = float3(0);
        weightSum = 0.f;
        diffuseReflectance = float3(0);
    }
};

struct SphereAttribs
{
    float distance;
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
    const float3 normal = WorldRayDirection();
    //Get Photon data
    PhotonData pd = PhotonData(gPackedPhotonData[primIndex]);
    //Evaluate diffuse BRDF
    //float weight = 1 - (attribs.distance * attribs.distance / (gPhotonRadius * gPhotonRadius));   //TODO:Weight total is needed in this case
    float weight = 1.f;
    if(dot(pd.normal, normal) < 0.6){
        weight = 0;
    }
    const float NdotL = saturate(dot(normal, pd.dir));
    const float3 diffuseBrdf =  rayData.diffuseReflectance *NdotL * M_1_PI;
   
    rayData.weightSum += weight;
    rayData.radiance += weight * diffuseBrdf * pd.flux;
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
    uint index = launchIndex.x + launchDim.x * launchIndex.y;

    // Return for invalid vpl indices
    uint numberVPL = gMaxVPLs;
    if(index >= numberVPL)
        return;
    
    //Get current VPL
    VPL vpl = VPL(gVPLs[index]);
    HitInfo hitInfo = HitInfo(gVplSurface[ReSTIR_LinearIndexToZCurve(index)]);
    if(!hitInfo.isValid() || !vpl.valid)
        return;

    float vplPdf = gVplPdf[ReSTIR_LinearIndexToZCurve(index)];
    
    let lod = ExplicitLodTextureSampler(0.f);
    ShadingData sd = loadShadingData(hitInfo, -vpl.normal, lod);
    let bsdf = gScene.materials.getBSDF(sd, lod);
    let bsdfProperties = bsdf.getProperties(sd);
    
    //Prepare payload
    RayData rayData = RayData();
    rayData.diffuseReflectance = bsdfProperties.diffuseReflectionAlbedo;          //Diffuse reflectance is stored in flux before collection
    rayData.radiance = float3(0.f);
    
    //Ray description 
    RayDesc ray;
    ray.Origin = vpl.posW;
    ray.TMin = 0.0;
    ray.TMax = 0.0001;
    ray.Direction = sd.N;    //Use as Normal

    //Closest hit shader can be skipped
    uint rayFlags = RAY_FLAG_SKIP_CLOSEST_HIT_SHADER | RAY_FLAG_SKIP_TRIANGLES;
    
    TraceRay(gPhotonAS, rayFlags, 0xFF /* instanceInclusionMask */, 0 /* hitIdx */, 0 /* rayType count */, 0 /* missIdx */, ray, rayData);
    //float3 radiance = rayData.weightSum > 0 ? rayData.radiance/ rayData.weightSum : 0;  //Normalize the weight
    float3 radiance = rayData.radiance;
    radiance /= (M_PI * gPhotonRadius * gPhotonRadius);//Le from normal. Solid angle is 1/(2PI) [hemisphere]
    radiance *= vplPdf;
    //Get diffuse probability as we ignore all specular parts
    //float diffProb = luminance(bsdfProperties.diffuseReflectionAlbedo);
    float NdotV = saturate(dot(sd.N, sd.V));
    float ggxAlpha = bsdfProperties.roughness * bsdfProperties.roughness;
    float3 specularReflectance = approxSpecularIntegralGGX(bsdfProperties.specularReflectance, ggxAlpha, NdotV);
    //float specProb = luminance(specularReflectance);

    float3 diffFactor = (bsdfProperties.diffuseReflectionAlbedo + specularReflectance) / bsdfProperties.diffuseReflectionAlbedo;
    radiance *= diffFactor;
    
    if (vpl.age > 0)
    {
        vpl.flux *= vpl.age;
    }
    //Reset the replaced flag automatically at age 1
    if(vpl.age == 1){
        vpl.replaced = false;    
    }
    
    vpl.age = min(vpl.age + 1, gVplAgeCap);
    vpl.flux += radiance;
    vpl.flux /= vpl.age;

    float flux = luminance(vpl.flux);
    if (isnan(flux) || isinf(flux))
    {
        flux = 0.f;
        vpl.valid = false;
    }
    
    
    //Write vpl back
    gVPLs[index] = vpl.pack();
    if(kUsePdfSampling){
        gLightPdf[ReSTIR_LinearIndexToZCurve(index)] = flux * M_PI;    //Le to flux (Le * area * solid angle) TODO: (M_PI * area instead of M_2PI * area)?
    }
        
}
