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
import VPLs;

#ifdef USE_REDUCED_RESERVOIR_FORMAT
    Texture2D<uint2> gReservoir;
    Texture2D<uint2> gReservoirPrev;
#else
    Texture2D<uint4> gReservoir;
    Texture2D<uint4> gReservoirPrev;
#endif

StructuredBuffer<PackedVPL> gPhotonLight;
StructuredBuffer<PackedVPL> gPhotonLightPrev;

RWStructuredBuffer<uint4> gDebugData;
Texture2D<PackedHitInfo> gVBuffer;
Texture2D<PackedHitInfo> gOrigVBuffer;
Texture2D<float4> gOrigColor;
RWTexture2D<float4> gColor;

cbuffer PerFrame
{
    float gDebugPointRadius; //Current it for sample gen
    uint2 gCurrentClickedPixel;
    bool gCopyLastColor; //Show the original color image
    bool gCopyPixelData; //Copy data of the currently clicked pixel
    float gDistanceFalloff; //Shading Falloff
    uint2 gFrameDim;
}

uint index2Dto1D(uint2 idx, uint width)
{
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
    VPL fgSample = VPL(gPhotonLight[index2Dto1D(gCurrentClickedPixel, gFrameDim.x)]);
    VPL fgSamplePrev = VPL(gPhotonLightPrev[index2Dto1D(gCurrentClickedPixel, gFrameDim.x)]);
    
    if (gCopyLastColor)
    {
        outColor = gOrigColor[dTid].xyz;
    }
    else //Shader in diffuse colors
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
        float3 photonPos = fgSample.posW;
        bool validHit = false;
        if (sphereIntersection(photonPos, camPos, viewDir, hitDistance))
        {
            outColor = float3(1, 0.4, 0.4);
            validHit = true;
        }
        float hitDistancePrev = 0.f;
        photonPos = fgSamplePrev.posW;
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
        Reservoir r = Reservoir(gReservoir[gCurrentClickedPixel]);
        gDebugData[0] = r.pack();
        gDebugData[1] = uint4(asuint(fgSample.posW), 0);
        gDebugData[2] = uint4(asuint(fgSample.normal), 0);
        gDebugData[3] = uint4(asuint(fgSample.flux), 0);
        r = Reservoir(gReservoirPrev[gCurrentClickedPixel]);
        gDebugData[4] = r.pack();
        gDebugData[5] = uint4(asuint(fgSamplePrev.posW), 0);
        gDebugData[6] = uint4(asuint(fgSamplePrev.normal), 0);
        gDebugData[7] = uint4(asuint(fgSamplePrev.flux), 0);
    }
    
    gColor[dTid] = float4(outColor, 1.0f);
}
