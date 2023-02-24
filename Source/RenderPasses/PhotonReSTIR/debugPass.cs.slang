#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Utils.Math.PackedFormats;
import Utils.Math.FormatConversion;

import Scene.RaytracingInline;
import Scene.Material.ShadingUtils;
import Rendering.Materials.Microfacet;
import Utils.Sampling.SampleGenerator;
import Utils.Math.MathHelpers;
import Utils.Color.ColorHelpers;

import Rendering.Lights.EmissiveLightSampler;
import Rendering.Lights.EmissiveLightSamplerHelpers;
import Reservoir;

Texture2D<uint4> gReservoir;
Texture2D<float4> gPhotonReservoirPos;
Texture2D<float4> gPhotonReservoirNormal;
Texture2D<float4> gPhotonReservoirFlux;
Texture2D<uint4> gReservoirPrev;
Texture2D<float4> gPhotonReservoirPosPrev;
Texture2D<float4> gPhotonReservoirNormalPrev;
Texture2D<float4> gPhotonReservoirFluxPrev;

RWStructuredBuffer<uint4> gDebugData;
Texture2D<PackedHitInfo> gVBuffer;
Texture2D<PackedHitInfo> gOrigVBuffer;
Texture2D<float4> gOrigColor;
RWTexture2D<float4> gColor;

cbuffer PerFrame
{
    float gDebugPointRadius; //Current it for sample gen
    uint2 gCurrentClickedPixel;
    bool gCopyLastColor;        //Show the original color image
    bool gCopyPixelData;       //Copy data of the currently clicked pixel
    float gDistanceFalloff;     //Shading Falloff
    uint2 _pad;
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

bool sphereIntersection(float3 sphereCenter, float3 origin, float3 direction, out float distance)
{
    distance = -1.f;
    float3 L = sphereCenter - origin;
    float tca = dot(L, direction);
    float d2 = dot(L, L) - tca * tca;
    float rad2 = gDebugPointRadius * gDebugPointRadius;
    if (d2 > rad2)
        return false;
    float thc = sqrt(rad2 - d2);
    float t0 = tca - thc;
    distance = t0;
    return true;
}

[numthreads(16, 16, 1)]
void main(uint2 dTid : SV_DispatchThreadID)
{
    float3 outColor = float3(0);
    float3 viewDir = gScene.camera.computeRayPinhole(dTid, uint2(1920, 1080)).dir;
    float3 camPos = gScene.camera.getPosition();
    
    if (gCopyLastColor)
    {
        outColor = gOrigColor[dTid].xyz;
    }
    else    //Shader in diffuse colors
    {
       //Get shading data
        PackedHitInfo packedHitInfo = gVBuffer[dTid];
        HitInfo hitInfo = HitInfo(packedHitInfo);
        let lod = ExplicitLodTextureSampler(0.f);
        if (hitInfo.isValid())
        {
            //Get Material properties
            ShadingData sd = loadShadingData(hitInfo, viewDir, lod);
            let bsdf = gScene.materials.getBSDF(sd, lod);
            let bsdfProperties = bsdf.getProperties(sd);

            float dist = distance(camPos, sd.posW);
            dist = max(0, gDistanceFalloff - dist) / dist;
        
            outColor = bsdfProperties.diffuseReflectionAlbedo * dist; //Scale a bit down
        }

        //Draw debug spheres
        HitInfo origHitInfo = HitInfo(gOrigVBuffer[gCurrentClickedPixel]);
        float posDistance = 0;
        if (origHitInfo.isValid())
        {
            ShadingData sd2 = loadShadingData(origHitInfo, viewDir, lod);
            if (sphereIntersection(sd2.posW, camPos, viewDir, posDistance))
                outColor = float3(0.4, 0.4, 1);
        }
            
        float hitDistance = 0.f;
        float3 photonPos = gPhotonReservoirPos[gCurrentClickedPixel].xyz;
        bool validHit = false;
        if (sphereIntersection(photonPos, camPos, viewDir, hitDistance))
        {
            outColor = float3(1, 0.4, 0.4);
            validHit = true;
        }
        float hitDistancePrev = 0.f;
        photonPos = gPhotonReservoirPosPrev[gCurrentClickedPixel].xyz;
        if (sphereIntersection(photonPos, camPos, viewDir, hitDistancePrev))
        {
            outColor = float3(0.4, 1, 0.4);
            if (validHit && abs(hitDistance - hitDistancePrev) < (gDebugPointRadius * 0.1))
                outColor = float3(1, 1, 0.4);
        }
    }

    //Copy data (one thread only)
    if (gCopyPixelData && (dTid.x == 0 && dTid.y == 0))
    {
        gDebugData[0] = gReservoir[gCurrentClickedPixel];
        gDebugData[1] = uint4(asuint(gPhotonReservoirPos[gCurrentClickedPixel].xyz), 0);
        gDebugData[2] = uint4(asuint(gPhotonReservoirNormal[gCurrentClickedPixel].xyz), 0);
        gDebugData[3] = uint4(asuint(gPhotonReservoirFlux[gCurrentClickedPixel].xyz), 0);
        gDebugData[4] = gReservoirPrev[gCurrentClickedPixel];
        gDebugData[5] = uint4(asuint(gPhotonReservoirPosPrev[gCurrentClickedPixel].xyz), 0);
        gDebugData[6] = uint4(asuint(gPhotonReservoirNormalPrev[gCurrentClickedPixel].xyz), 0);
        gDebugData[7] = uint4(asuint(gPhotonReservoirFluxPrev[gCurrentClickedPixel].xyz), 0);
    }
    
    gColor[dTid] = float4(outColor, 1.0f);
}
