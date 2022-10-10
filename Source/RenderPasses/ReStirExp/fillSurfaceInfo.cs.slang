#include "Scene/SceneDefines.slangh"

import Scene.RaytracingInline;
import Scene.Material.ShadingUtils;
import Utils.Color.ColorHelpers;

import SurfaceData;


//Define for valid texture channels
#define is_valid(name) (is_valid_##name != 0)

Texture2D<PackedHitInfo> gVBuffer;
Texture2D<float4> gView;
Texture2D<float> gLinZ;
RWStructuredBuffer<PackedSurfaceData>gSurfaceData;

cbuffer Constant{
    uint2 gFrameDim;                //Frame Dimensions
}

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

[numthreads(16, 16, 1)]
void main(uint2 dTid : SV_DispatchThreadID){

    bool valid = true;
    HitInfo hitInfo = HitInfo(gVBuffer[dTid]);
    if(!hitInfo.isValid()) valid = false;

    Surface surface = Surface();
    
    //Get Hit shading information
    if(valid){
        let lod = ExplicitLodTextureSampler(0.f);
        float3 viewDir;
        float linZ;
        Ray cameraRay;
        //If one of both is not set, calculate camera ray
        if (!(is_valid(gView) && is_valid(gLinZ)))
            cameraRay = gScene.camera.computeRayPinhole(dTid, gFrameDim);
        
        if(is_valid(gView)){
            viewDir = -gView[dTid].xyz;
        }else{
            viewDir = cameraRay.dir;
        }
        
        ShadingData sd = loadShadingData(hitInfo, viewDir, lod);
        let bsdf = gScene.materials.getBSDF(sd, lod);
        let bsdfProperties = bsdf.getProperties(sd);

        if(is_valid(gLinZ)){
            linZ = gLinZ[dTid];
        }else{
            float3 camPos = gScene.camera.getPosition();
            linZ = distance(camPos, sd.posW); 
        }   
        
        surface.posW = sd.computeNewRayOrigin();
        surface.viewDepth = linZ;
        surface.normal = sd.N;
        surface.roughness = bsdfProperties.roughness;
        //Weights
        float diffuse = luminance(bsdfProperties.diffuseReflectionAlbedo);
        float specular = luminance(bsdfProperties.specularReflectance);
        float sumWeights = diffuse + specular;
        float diffuseProb = sumWeights < 1e-7f ? 1.0f : (diffuse/sumWeights);
        surface.diffuse = diffuse;
        surface.specular = specular;
        surface.diffuseProb = diffuseProb;
    }
    
    gSurfaceData[index2Dto1D(dTid, gFrameDim.x)] = surface.pack();
}
