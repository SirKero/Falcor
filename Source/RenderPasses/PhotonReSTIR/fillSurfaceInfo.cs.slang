#include "Scene/SceneDefines.slangh"

import Scene.RaytracingInline;
import Scene.Material.ShadingUtils;
import Utils.Color.ColorHelpers;

import SurfaceData;

Texture2D<PackedHitInfo> gVBuffer;
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
        Ray cameraRay = gScene.camera.computeRayPinhole(dTid, gFrameDim);
        ShadingData sd = loadShadingData(hitInfo, cameraRay.dir, lod);
        let bsdf = gScene.materials.getBSDF(sd, lod);
        let bsdfProperties = bsdf.getProperties(sd);
        float3 camPos = gScene.camera.getPosition();
        float currLinZ = distance(camPos, sd.posW); //TODO use linZ

        surface.posW = sd.posW;
        surface.viewDepth = currLinZ;
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
