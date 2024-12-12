#include "RayLodHelper.slang"

import EvaluateAnalyticLight;

cbuffer CB
{
    uint gFrameCount; // Current it for sample gen
    float2 gInvFrameDim;
    float gScreenSpacePixelSpreadAngle;
}

// Inputs
Texture2D<PackedHitInfo> gVBuffer;
Texture2D<float4> gViewW; // Optional
Texture2D<float4> gTransparencyThp;

// Outputs
RWTexture2D<float4> gOutputColor;

static const bool kAdjustShadingNormals = true;
static const float kMinOpacity = 1e-7;
static const float kAmbientStrength = AMBIENT_STRENGTH;
static const float kEnvMapStrength = ENV_MAP_STRENGTH;

/** Setup ShadingData based on loaded vertex/material attributes for a hit point.
    \param[in] hit Hit information.
    \param[in] rayOrigin Ray origin.
    \param[in] rayDir Normalized ray direction.
    \param[in] lod Method for computing texture level-of-detail.
    \return ShadingData struct.
*/
ShadingData loadShadingData(const HitInfo hit, const float3 rayDir, const ITextureSampler lod)
{
    const TriangleHit triangleHit = hit.getTriangleHit();
    VertexData v = gScene.getVertexData(triangleHit);
    uint materialID = gScene.getMaterialID(triangleHit.instanceID);

    ShadingData sd = gScene.materials.prepareShadingData(v, materialID, -rayDir, lod);

    return sd;
}


[numthreads(16, 16, 1)]
void main(uint2 pixel: SV_DispatchThreadID)
{
    // Load color from transparency pass
    float3 colorOut = float3(0.0); 
    const HitInfo hit = HitInfo(gVBuffer[pixel]);
    float3 viewDir = -gViewW[pixel].xyz;
    float3 transparencyThp = gTransparencyThp[pixel].xyz;
    if (all(transparencyThp < kMinOpacity))
        return;

    if (hit.isValid())
    {
        SampleGenerator sg = SampleGenerator(pixel, gFrameCount);
        // Pixel represents a valid primary hit. Compute its contribution.
        ITextureSampler lod = ExplicitLodTextureSampler(0.f);

        const TriangleHit triangleHit = hit.getTriangleHit();
        VertexData v = gScene.getVertexData(triangleHit);
        uint materialID = gScene.getMaterialID(triangleHit.instanceID);
        float hitT = distance(gScene.camera.getPosition(), v.posW);
        // Use different texture sampler
        if (kLODMode == TexLODMode::RayCones)
        {
            float2 ddx, ddy;
            computeAnisotropicAxesRayCones(triangleHit, v, viewDir, hitT, gScreenSpacePixelSpreadAngle, ddx, ddy);
            lod = ExplicitGradientTextureSampler(ddx, ddy);
        }
        else if (kLODMode == TexLODMode::RayDiffs)
        {
            float2 ddx, ddy;
            computeRayDifferentials(triangleHit, viewDir, hitT, gScene.camera, gInvFrameDim, ddx, ddy);
            lod = ExplicitGradientTextureSampler(ddx, ddy);
        }
        // else kLODMode == TexLODMode::Mip0

        // Load shading data.
        ShadingData sd = gScene.materials.prepareShadingData(v, materialID, -viewDir, lod);

        uint hints = 0;
        if (kAdjustShadingNormals)
            hints |= (uint)MaterialInstanceHints::AdjustShadingNormal;
        let mi = gScene.materials.getMaterialInstance(sd, lod, hints);
        BSDFProperties bsdfProperties = mi.getProperties(sd);
        // Always output directly emitted light, independent of whether emissive materials are treated as light sources or not.
        colorOut += bsdfProperties.emission * sd.opacity;

        // Add contribution of direct light from analytic lights.
        // Light probe and mesh lights are handled by the scatter ray hit/miss shaders.
        colorOut += evalDirectAnalytic(sd, mi, sg);

        // Ambient
        colorOut += bsdfProperties.diffuseReflectionAlbedo * kAmbientStrength;
    }
    else //Enviroment map lookup
    {
        colorOut = gScene.envMap.eval(viewDir) * kEnvMapStrength;
    }
    float3 prevColor = gOutputColor[pixel].xyz;
    gOutputColor[pixel] = float4(colorOut * transparencyThp + prevColor, 1.0);
}
