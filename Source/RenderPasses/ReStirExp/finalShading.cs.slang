#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.RaytracingInline;
import Scene.Material.ShadingUtils;
import Rendering.Materials.Microfacet;
import Utils.Sampling.SampleGenerator;
import Utils.Math.MathHelpers;

import Rendering.Lights.EmissiveLightSampler;
import Rendering.Lights.EmissiveLightSamplerHelpers;
import Reservoir;
import Lights;

Texture2D<uint4> gReservoir;
Texture2D<uint> gReservoirUV;

StructuredBuffer<PackedReSTIRLight> gLights;
Texture2D<PackedHitInfo> gVBuffer;
Texture2D<float2> gMVec;
Texture2D<float4> gView;
RWTexture2D<float4> gColor;
RWTexture2D<float4> gDiffuseIllumination;
RWTexture2D<float4> gDiffuseReflectance;
RWTexture2D<float4> gSpecularIllumination;
RWTexture2D<float4> gSpecularReflectance;

#define is_valid(name) (is_valid_##name != 0)

cbuffer PerFrame
{
    uint gFrameCount;                   //Current it for sample gen
}

cbuffer Constant
{
    uint2 gFrameDim;                //Frame Dimensions for camera dir
    bool  gUseEmissiveTexture;      //Enables emissive texture for shading
    bool gEnableVisRay;             //Enables the final visibilty ray
}

static const float kRayEpsilon = 0.99f;

uint index2Dto1D(uint2 idx, uint width){
    return idx.x + width * idx.y;
}

Reservoir getReservoir(uint2 idx){
    Reservoir r =  Reservoir(gReservoir[idx], gReservoirUV[idx]);
    
    if (r.weightSum <= 0 || isinf(r.weightSum) || isnan(r.weightSum))
        r = Reservoir();
    
    return r;
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
    ReSTIRLight light = ReSTIRLight(gLights[r.lightIdx]);
    
    EmissiveTriangle tri = gScene.lightCollection.getTriangle(light.lightIdx);
    const float3 barycentrics = sample_triangle(r.uv);
    float3 lightPos = tri.getPosition(barycentrics);
    //Get light dir
    toLight = lightPos - worldPos;
    float distSqr= max(FLT_MIN, dot(toLight, toLight)); // Clamp to avoid NaNs below
    distance = sqrt(distSqr);
    toLight = toLight/ distance;    //normalize

    float cosTheta = dot(tri.normal, -toLight);
    
    //Eval emissive power
    float3 Le;
    if(gUseEmissiveTexture){
        float2 texCoord = tri.getTexCoord(barycentrics);
        Le = gScene.materials.evalEmissive(tri.materialID, texCoord);
    }else{
        Le = gScene.lightCollection.getAverageRadiance(light.lightIdx);
    }
    

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
    Reservoir r = getReservoir(dTid);
    SampleGenerator sg = SampleGenerator(dTid, gFrameCount + 7 * 13);    //TODO add seed offset

    //Get shading data
    PackedHitInfo packedHitInfo = gVBuffer[dTid];
    HitInfo hitInfo = HitInfo(packedHitInfo);
          
    let lod = ExplicitLodTextureSampler(0.f);
    //Recreate the V-Buffer ray for direction
    float3 viewDir;
    if (is_valid(gView))
    {
        viewDir = gView[dTid].xyz;
    }else{
        viewDir = gScene.camera.computeRayPinhole(dTid, gFrameDim).dir * -1;
    }
    
    //Get Material properties
    ShadingData sd = loadShadingData(hitInfo, -viewDir, lod);
    let bsdf = gScene.materials.getBSDF(sd, lod);
    let bsdfProperties = bsdf.getProperties(sd);

    if(r.weightSum < 0 || !hitInfo.isValid() || r.M == 0){
        valid = false;
    }
    
    //Get to light direction
    float distance = 0;
    float3 toLight = { };
    float3 Li = { };
    getEmissiveLight(r,sd.posW ,distance , toLight, Li);
    Li = max(0.f, Li * r.weightSum);

    //Check light visibility with a shadow ray
    if (valid && gEnableVisRay)
    {
        distance *= kRayEpsilon;
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
    

    float3 outColor = diffuse + specular + bsdfProperties.emission;

    //Debug
    float3 diffuseReflectance = bsdfProperties.diffuseReflectionAlbedo;
    float3 diffuseFactor = diffuseReflectance <= 0.f ? 0.f : 1.f / diffuseReflectance;
    float3 diffuseIllumination = diffuse * diffuseFactor;

    float NdotV = saturate(dot(sd.N, sd.V));
    float ggxAlpha = bsdfProperties.roughness * bsdfProperties.roughness;
    float3 specularReflectance = approxSpecularIntegralGGX(bsdfProperties.specularReflectance, ggxAlpha, NdotV);
    float3 specularFactor = specularReflectance <= 0.f ? 0.f : 1.f / specularReflectance;
    float3 specularIllumination = specular * specularFactor;

    //DEBUG
    //float4 debugReservoir = float4(float(r.lightIdx), float(r.M), r.weightSum, r.targetPdf);
    //gDiffuseReflectance[dTid] = debugReservoir;
    
    if (is_valid(gDiffuseReflectance)) gDiffuseReflectance[dTid] = float4(diffuseReflectance, 1.f);
    if (is_valid(gDiffuseIllumination)) gDiffuseIllumination[dTid] = float4(diffuseIllumination, distance);
    if (is_valid(gSpecularReflectance)) gSpecularReflectance[dTid] = float4(specularReflectance, 1.f);
    if (is_valid(gSpecularIllumination)) gSpecularIllumination[dTid] = float4(specularIllumination, distance);
        
    gColor[dTid] = float4(outColor, 1.0f);
}
