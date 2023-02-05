#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.Raytracing;
import Scene.Intersection;
import Utils.Math.MathHelpers;
import Utils.Sampling.SampleGenerator;
import Scene.Material.ShadingUtils;
import Rendering.Materials.StandardMaterial;
//import Experimental.Scene.Material.MaterialHelpers;
import Rendering.Lights.LightHelpers;

import VPLs;

cbuffer PerFrame
{
    uint gFrameCount; // Frame count since scene was loaded.
    float gPhotonRadius; // Radius for the caustic photons
    bool gEnableTemporalFilter;         //Use the temporal filter
    uint gTemporalFilterHistoryLimit;   //Limit for pixel median
}

// Inputs
Texture2D<PackedHitInfo> gVBuffer;
Texture2D<float4> gView;
Texture2D<float2> gMVec;

Texture2D<float4> gCausticImagePrev;
// Outputs
RWTexture2D<float4> gCausticImage;

//Acceleration Structure
RaytracingAccelerationStructure gPhotonAS;

 //Photon Buffers
StructuredBuffer<uint4> gPackedPhotonData;
StructuredBuffer<AABB> gPhotonAABB;

/** Payload for ray (48B).
*/
struct RayData
{
    float3 radiance; ///< Accumulated outgoing radiance from path.
    uint pad; ///< free space.
    PackedHitInfo packedHitInfo; ///< Hit info from vBuffer; Up to 16B

    SampleGenerator sg; ///< Per-ray state for the sample generator (up to 16B).
  
    __init(){
        this.radiance = float3(0);
        this.pad = 0;
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
        
    //Get hit data from payload
    const HitInfo hit = HitInfo(rayData.packedHitInfo);
    let lod = ExplicitLodTextureSampler(0.f);
    //World Direction is set to the viewDir we get from the vBuffer
    ShadingData sd = loadShadingData(hit, WorldRayDirection(), lod);

    //Check for different surfaces
    /*
    if (dot(pd.normal, sd.faceN) < 0.6)
    {
        return;
    }
    */
    //Photon contribution
    let bsdf = gScene.materials.getBSDF(sd, lod);
    float3 f_r = bsdf.eval(sd, pd.dir, rayData.sg); //right sign? 
    rayData.radiance += f_r * pd.flux;
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

    //Prepare payload
    RayData rayData = RayData();
    rayData.packedHitInfo = gVBuffer[launchIndex];
    rayData.sg = SampleGenerator(launchIndex, gFrameCount + 3 * 12);
    
    const HitInfo hit = HitInfo(rayData.packedHitInfo);
    bool valid = hit.isValid(); //Check if the ray is valid 

    //Get vertex data for the world position
    const TriangleHit triangleHit = hit.getTriangleHit();
    VertexData v = gScene.getVertexData(triangleHit);

    //Ray description 
    RayDesc ray;
    ray.Origin = v.posW;
    ray.TMin = 0.;
    ray.TMax = 0.001;
    ray.Direction = -gView[launchIndex].xyz; //we take the view dir as direction to save payload space

    //Closest hit shader can be skipped
    uint rayFlags = RAY_FLAG_SKIP_CLOSEST_HIT_SHADER | RAY_FLAG_SKIP_TRIANGLES;
    float3 radiance = float3(0);
    
    if (valid)
    {
        TraceRay(gPhotonAS, rayFlags, 2 /* instanceInclusionMask */, 0 /* hitIdx */, 0 /* rayType count */, 0 /* missIdx */, ray, rayData);
        float w = 1 / (M_PI * gPhotonRadius * gPhotonRadius);
        radiance += w * rayData.radiance;
    }

    uint history = 1;
    
    if (gEnableTemporalFilter)
    {
        float2 motionOffset = gMVec[launchIndex] * float2(launchDim);
        float2 prevIdxF = motionOffset + float2(launchIndex);
        float2 rndOffset = sampleNext2D(rayData.sg) - 0.5f;
        prevIdxF += rndOffset;
        if (prevIdxF.x > 0 && prevIdxF.y > 0 && prevIdxF.x < launchDim.x && prevIdxF.y < launchDim.y)
        {
            uint2 tempIndex = uint2(round(prevIdxF));
                
            float4 prev = gCausticImagePrev[tempIndex];
            history = min(gTemporalFilterHistoryLimit, uint(round(prev.w)) + 1);
            prev.xyz *= (history - 1);
            radiance += prev.xyz;
            radiance /= history;
        }
    }
    
    gCausticImage[launchIndex] = float4(radiance, float(history));
}
