#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.RaytracingInline;
import Utils.Sampling.SampleGenerator;
import Rendering.Lights.LightHelpers;

import VirtualShadowMap.VirtualShadowMap;
cbuffer CB
{
    uint gFrameCount;       //Frame count for sample gen
    uint2 gFrameDim;        //Dimensions
    float gAmbient;         //Ambient strength
    float gEnvMapFac;       //Env map strength
    float gEmissiveFac;     // Emissve stength
    int gDirectionalLightIdx;   //Light index for directional light
}

Texture2D<PackedHitInfo> gVBuffer;
Texture2D<float4> gView;

RWTexture2D<float4> gColorOut;

static const float kMinIncidentAngle = 1e-3; // Min Incident angle for light

// Load in shading data from hit and direction
ShadingData loadShadingData(const HitInfo hit, const float3 rayDir, const ITextureSampler lod)
{
    const TriangleHit triangleHit = hit.getTriangleHit();
    VertexData v = gScene.getVertexData(triangleHit);
    uint materialID = gScene.getMaterialID(triangleHit.instanceID);
    ShadingData sd = gScene.materials.prepareShadingData(v, materialID, -rayDir, lod);

    return sd;
}

float3 evalAnalyticLight(const ShadingData sd, const IMaterialInstance mi, inout SampleGenerator sg)
{
    float3 Li = float3(0);
    const uint lightCount = gScene.getLightCount();
    if (lightCount == 0) return float3(0.0);

    //Loop over all lights
    for (uint lightIdx = 0; lightIdx < lightCount; lightIdx++) {
        // Sample local light source.
        AnalyticLightSample ls = {};
        LightData lightData = gScene.getLight(lightIdx);
        uint type = lightData.type;
        sampleLight(sd.posW, lightData, sg, ls);

        float NdotL = dot(sd.getOrientedFaceNormal(), ls.dir);
        // Reject sample if invalid or has an too steep incident angle
        if (all(ls.Li <= 0.0) || (abs(NdotL) < kMinIncidentAngle)) {
            continue;
        }

        // Eval BSDF
        float3 bsdf = mi.eval(sd, ls.dir, sg);
        if (all(bsdf <= 0))
            continue;

        float visibility = 0;
        //Check if virtual shadow map or shadow ray should be used
        if (lightIdx == gDirectionalLightIdx) {
            visibility = gVirtualShadowMapEval.eval(lightIdx, sd.posW);
        } else {
            // Shadow Ray
            SceneRayQuery<1> rayQuery;
            const Ray ray = Ray(sd.computeNewRayOrigin(), ls.dir, 0.f, ls.distance);
            if (rayQuery.traceVisibilityRay(ray, RAY_FLAG_NONE, 0xff))
                visibility = 1.0;
        }

        Li += bsdf * visibility * ls.Li;
    }
    return Li;
}

[numthreads(16, 16, 1)]
void main(uint2 pixel: SV_DispatchThreadID)
{
    if (any(pixel >= gFrameDim))
        return;

    float3 outColor = float3(0);
    HitInfo hit = HitInfo(gVBuffer[pixel]);
    float3 view = -gView[pixel].xyz;

    if (hit.isValid()) {
        SampleGenerator sg = SampleGenerator(pixel, gFrameCount);
        let lod = ExplicitLodTextureSampler(0.f);

        ShadingData sd = loadShadingData(hit, view, lod);
        uint hints = (uint)MaterialInstanceHints::AdjustShadingNormal;
        let mi = gScene.materials.getMaterialInstance(sd, lod, hints);
        let bsdfProperties = mi.getProperties(sd);

        // Ambient
        outColor += gAmbient * bsdfProperties.diffuseReflectionAlbedo;
        outColor += gEmissiveFac * bsdfProperties.emission;
        outColor += evalAnalyticLight(sd, mi, sg);
    }
    else {
        outColor = gScene.envMap.eval(view) * gEnvMapFac;
    }

    gColorOut[pixel] = float4(outColor,1.0);
}
