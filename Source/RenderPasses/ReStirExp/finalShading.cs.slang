#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.RaytracingInline;
import Scene.Material.ShadingUtils;
import Utils.Sampling.SampleGenerator;
import Utils.Math.MathHelpers;

import Rendering.Lights.EmissiveLightSampler;
import Rendering.Lights.EmissiveLightSamplerHelpers;
import Reservoir;


StructuredBuffer<Reservoir> gReservoir;

Texture2D<PackedHitInfo> gVBuffer;
Texture2D<float2> gMVec;
RWTexture2D<float4> gColor;

cbuffer PerFrame
{
    uint gFrameCount;                   //Current it for sample gen
    uint2 gFrameDim;                //Frame Dimensions for camera dir 
}

static const float kRayEpsilon = 0.0001f;

uint index2Dto1D(uint2 idx, uint width){
    return idx.x + width * idx.y;
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

void getEmissiveLight(in Reservoir r, in float3 worldPos, out float distance ,out float3 toLight, out float3 Li){
    //Get triangle position
    EmissiveTriangle tri = gScene.lightCollection.getTriangle(r.lightIdx);
    const float3 barycentrics = sample_triangle(r.getUV());
    float3 lightPos = tri.getPosition(barycentrics);
    //Get light dir
    toLight = lightPos - worldPos;
    float distSqr= max(FLT_MIN, dot(toLight, toLight)); // Clamp to avoid NaNs below
    distance = sqrt(distSqr);
    toLight = toLight/ distance;    //normalize

    float cosTheta = dot(tri.normal, -toLight);
    
    //TODO: add a define if the precomputed radiance should be used instead
    //Eval emissive texture
    float2 texCoord = tri.getTexCoord(barycentrics);
    float3 Le = gScene.materials.evalEmissive(tri.materialID, texCoord);

    //Calculate Li
    float denom = max(FLT_MIN, cosTheta * tri.area); //Clamp to avoid nans
    float pdf = distSqr / denom;
    Li = Le / pdf;
}

[numthreads(16, 16, 1)]
void main(uint2 dTid : SV_DispatchThreadID)
{
    bool valid = true;
    //Get reservoir
    Reservoir r = gReservoir[index2Dto1D(dTid, gFrameDim.x)];
    SampleGenerator sg = SampleGenerator(dTid, gFrameCount);    //TODO add seed offset

    //Get shading data
    HitInfo hitInfo = HitInfo(gVBuffer[dTid]);

      
    let lod = ExplicitLodTextureSampler(0.f);
    //Recreate the V-Buffer ray for direction
    Ray cameraRay = gScene.camera.computeRayPinhole(dTid, gFrameDim);
    //Get Material properties
    ShadingData sd = loadShadingData(hitInfo, cameraRay.dir, lod);
    let bsdf = gScene.materials.getBSDF(sd, lod);
    let bsdfProperties = bsdf.getProperties(sd);

    if(r.W < 0 || !hitInfo.isValid() || r.M == 0){
        valid = false;
    }
    
    //Get to light direction
    float distance = 0;
    float3 toLight = { };
    float3 Li = { };
    getEmissiveLight(r,sd.posW ,distance , toLight, Li);
    Li = max(0.f, Li * r.W);

    //Check light visibility with a shadow ray
    if(valid){
        distance -= kRayEpsilon;
        // Ray Query for shadow test; <1> means enabled alpha testing; TODO: Add static const for alpha test
        SceneRayQuery<1> rayQuery;
        const Ray ray = Ray(sd.computeNewRayOrigin(), toLight, 0.f, distance);
        if (!rayQuery.traceVisibilityRay(ray, RAY_FLAG_NONE, 0xff))
        {
            valid = false;
        }
    }
    
    float3 diffuse = {};
    float3 specular = {};
    if(valid){
        //Seperate in diffuse and specular
        sd.mtl.setActiveLobes((uint)LobeType::DiffuseReflection);
        diffuse = bsdf.eval(sd, toLight, sg) * Li;

        sd.mtl.setActiveLobes((uint)LobeType::SpecularReflection);
        specular = bsdf.eval(sd, toLight, sg) * Li;
    }
    

    float3 outColor = diffuse + specular + bsdfProperties.emission; //Clamp diffuse and specular because light can be invalid
    
    gColor[dTid] = float4(outColor, 1.0f);
}
