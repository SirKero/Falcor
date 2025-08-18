/***************************************************************************
 # Copyright (c) 2015-23, NVIDIA CORPORATION. All rights reserved.
 #
 # Redistribution and use in source and binary forms, with or without
 # modification, are permitted provided that the following conditions
 # are met:
 #  * Redistributions of source code must retain the above copyright
 #    notice, this list of conditions and the following disclaimer.
 #  * Redistributions in binary form must reproduce the above copyright
 #    notice, this list of conditions and the following disclaimer in the
 #    documentation and/or other materials provided with the distribution.
 #  * Neither the name of NVIDIA CORPORATION nor the names of its
 #    contributors may be used to endorse or promote products derived
 #    from this software without specific prior written permission.
 #
 # THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS "AS IS" AND ANY
 # EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 # IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 # PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE COPYRIGHT OWNER OR
 # CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 # EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 # PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 # PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 # OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 # (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 # OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 **************************************************************************/

#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"
#define NRD_COMPILER_DXC
#define NRD_NORMAL_ENCODING 0
#define NRD_ROUGHNESS_ENCODING 0
#include "nrd/Shaders/Source/NRD.hlsli"

import Scene.Raytracing;
import Scene.Intersection;
import Utils.Math.MathHelpers;
import Utils.Sampling.SampleGenerator;
import Scene.Material.ShadingUtils;
import Rendering.Lights.EmissiveLightSampler;
import Rendering.Lights.EmissiveLightSamplerHelpers;
import Rendering.Lights.LightHelpers;
import Rendering.Materials.Microfacet;
import Rendering.Materials.Fresnel;
import Rendering.Lights.LightHelpers;
import Utils.Geometry.GeometryHelpers;
import Utils.Math.PackedFormats;
import Utils.Math.FormatConversion;
import Utils.Color.ColorHelpers;
import Rendering.Materials.IsotropicGGX;
import RenderPasses.Shared.Denoising.NRDConstants;

//Inputs
Texture2D<PackedHitInfo> gVBuffer;
Texture2D<float4> gView;
Texture2D<float> gBlueNoise;

//Outputs
RWTexture2D<float4> gOutColor;
RWTexture2D<float4> gOutEmission;
RWTexture2D<float4> gOutDiffuseRadiance;
RWTexture2D<float4> gOutSpecularRadiance;
RWTexture2D<float4> gOutDiffuseReflectance;
RWTexture2D<float4> gOutSpecularReflectance;
RWTexture2D<float4> gOutUnshadowed;
RWTexture2D<float> gOutPenumbra;

uniform EmissiveLightSampler gEmissiveSampler; ///< Emissive light sampler. Only valid when kUseEmissiveLights == true.

cbuffer CB
{
    uint gFrameCount;   //Current Frame Count for the sample generator
    uint gSPP;
    float gAmbientFactor;  //Tells if the LTT mask is valid
    float gEmissiveFactor;

    float gEnvMapFactor;
    float3 gDirLightT; // Tangent for light

    float3 gDirLightB; // Bitangent for light
    float gTanSunAngularRadius; //Tangenens of the suns angular radius for directional lights

    float gNRDLightSize; // Approximated light size
    float3 gSpotLightT;  // Tangent for spotlight 0

    float3 gSpotLightB;  // Bitangent for spotlight 1
    uint gMode;          // 0 - Standard, 1 - NRD Full, 2- NRD Sigma
    bool gUseSpatioTemporalBlueNoise;   //Enables STBN
}

// Static configuration based on defines set from the host.
#define is_valid(name) (is_valid_##name != 0)
static const bool kRayAlphaTest = ALPHA_TEST;
static const bool kUseEnvBackground = USE_ENV_MAP;
static const bool kHasAnalytic = HAS_ANALYTIC_LIGHTS;
static const bool kHasEmissive = HAS_EMISSIVE_LIGHTS;
static const float3 kDefaultBackgroundColor = float3(0.01);
static const uint kBlueNoiseDims = 64;
static const uint2 kBlueNoiseOffset = uint2(7, 5); //Blue noise offset for the 2nd sample

static const float kFP16Max = 65504.0; //NRD FP16 max

 /** Describes a light sample.
    */
struct LightSample
{
    float3 Li; ///< Incident radiance at the shading point (unshadowed). This is already divided by the pdf.
    float lightArea;    ///<Area of the light
    float3 origin; ///< Ray origin for visibility evaluation (offseted to avoid self-intersection).
    float distance; ///< Ray distance for visibility evaluation (shortened to avoid self-intersection).
    float3 dir; ///< Ray direction for visibility evaluation (normalized).
    uint lightType; ///< Light type this sample comes from (0 -> analytic spot/point; 1-> analytic directional 2 -> emissive).

    RayDesc getVisibilityRay()
    {
        return {origin, 0.f, dir, distance};
    }
};

/** Payload for shadow ray.
*/
struct ShadowRayData
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
    
    return sd;
}

/** Generates a light sample on the emissive geometry.
        \param[in] shading data.
        \param[in,out] sg Sample generator.
        \param[out] ls Struct describing valid samples.
        \return True if the sample is valid and has nonzero contribution, false otherwise.
    */
bool generateEmissiveSample(const in ShadingData sd, inout SampleGenerator sg, out LightSample ls)
{
    ls = {}; // Default initialization to avoid divergence at returns.
    TriangleLightSample tls;
    if (!gEmissiveSampler.sampleLight(sd.posW, sd.faceN, true, sg, tls))
        return false;

        // Setup returned sample.
    ls.Li = tls.pdf > 0.f ? (tls.Le * gEmissiveFactor) / tls.pdf : float3(0);
        // Offset shading and light position to avoid self-intersection.
    float3 lightPos = computeRayOrigin(tls.posW, tls.normalW);
    ls.origin = computeRayOrigin(sd.posW, dot(sd.faceN, lightPos - sd.posW) >= 0 ? sd.faceN : -sd.faceN);
    float3 toLight = lightPos - ls.origin;
    ls.distance = length(toLight);
    ls.dir = normalize(toLight);
    ls.lightType = 2;

    //Get (triangle)light area
    const EmissiveTriangle tri = gScene.lightCollection.getTriangle(tls.triangleIndex);
    ls.lightArea = tri.area;

    return any(ls.Li > 0.f);
}

float2 getSTBNSample() {
    const uint2 pixel = DispatchRaysIndex().xy;
    uint2 samplePixel = pixel % kBlueNoiseDims;
    float stbn0 = gBlueNoise[samplePixel];
    samplePixel = (pixel + kBlueNoiseOffset) % kBlueNoiseDims;
    float stbn1 = gBlueNoise[samplePixel];
    return float2(stbn0, stbn1);
}

/** Generates a light sample on the analytic lights.
       \param[in] vertex Path vertex.
       \param[in,out] sg Sample generator.
       \param[out] ls Struct describing valid samples.
       \return True if the sample is valid and has nonzero contribution, false otherwise.
   */
bool generateAnalyticLightSample(const ShadingData sd, inout SampleGenerator sg, out LightSample ls)
{
    ls = {}; // Default initialization to avoid divergence at returns.

    uint lightCount = gScene.getLightCount();
    if (!kHasAnalytic || lightCount == 0) return false;

    // Sample analytic light source selected uniformly from the light list.
    // TODO: Sample based on estimated contributions as pdf.
    uint lightIndex = min(uint(sampleNext1D(sg) * lightCount), lightCount - 1);
    const LightData lightData = gScene.getLight(lightIndex);

    // Sample local light source.
    AnalyticLightSample lightSample;
    if (!sampleLight(sd.posW, lightData , sg, lightSample)) return false;

    // Random offset
    float2 rnd = float2(0);
    if (gUseSpatioTemporalBlueNoise)
        rnd = getSTBNSample();
    else
        rnd = sampleNext2D(sg);

    //Check if point or spotlight
    if (lightSample.distance < kMaxLightDistance) {
        if (lightIndex == 0 && lightData.openingAngle < M_PI_2)
        {
            float2 discOffset = sample_disk(rnd) * gNRDLightSize;
            lightSample.posW += gSpotLightT * discOffset.x + gSpotLightB * discOffset.y;
        }else{
            float3 randomSphereOffset = sample_sphere(rnd) * gNRDLightSize;
            lightSample.posW += randomSphereOffset;
        }
        lightSample.dir = lightSample.posW - sd.posW;
        lightSample.distance = length(lightSample.dir);
        lightSample.dir /= lightSample.distance;
        ls.lightType = 0; // Point spot
    } else { 
        float2 cosRnd = sample_cosine_hemisphere_polar(rnd).xy * gTanSunAngularRadius;
        lightSample.dir = normalize(gDirLightT * cosRnd.x + gDirLightB * cosRnd.y + lightSample.dir);

        ls.lightType = 1; //Directional
    }
   
    // Setup returned sample.
    ls.Li = lightSample.Li * lightCount;
    // Offset shading position to avoid self-intersection.
    ls.origin = computeRayOrigin(sd.posW, dot(sd.faceN, lightSample.dir) >= 0 ? sd.faceN : -sd.faceN);
    // Analytic lights do not currently have a geometric representation in the scene.
    // Do not worry about adjusting the ray length to avoid self-intersections at the light.
    ls.distance = lightSample.distance;
    ls.dir = lightSample.dir;
    //sls.lightType = 1;

    return any(ls.Li > 0.f);
}

bool generateLightSample(const ShadingData sd, inout SampleGenerator sg, out LightSample ls) {
    ls = {};
    if (!kHasAnalytic && !kHasEmissive)
        return false;

    float analyticProb = kHasAnalytic ? 1.0 : 0.0;
    float emissiveProb = kHasEmissive ? 1.0 : 0.0;
    float selectAnalyticProb = analyticProb / (analyticProb + emissiveProb);
    float selectPdf = selectAnalyticProb;
    bool valid = false;
    if (sampleNext1D(sg) < selectAnalyticProb) {
        valid = generateAnalyticLightSample(sd, sg, ls);
        ls.lightArea = M_PI * gNRDLightSize * gNRDLightSize;
    } else {
        valid = generateEmissiveSample(sd, sg, ls);
        selectPdf = 1.0 - selectAnalyticProb;
    }
    ls.Li /= selectPdf;

    return valid;
}

void StandardPass(uint2 pixel, uint2 frameDim) {
    HitInfo hitInfo = HitInfo(gVBuffer[pixel]);
    const float3 view = -gView[pixel].xyz;
    SampleGenerator sg = SampleGenerator(pixel, gFrameCount);

    float3 outColor = float3(0);

    if (hitInfo.isValid())
    {
        let lod = ExplicitLodTextureSampler(0.f);
        ShadingData sd = loadShadingData(hitInfo, view, lod);

        // uint hints = (uint) MaterialInstanceHints::AdjustShadingNormal;
        let bsdf = gScene.materials.getMaterialInstance(sd, lod, 0u);
        let bsdfProperties = bsdf.getProperties(sd);

        // Emissive
        outColor += bsdfProperties.emission * gEmissiveFactor;
        // Ambient
        outColor += bsdfProperties.diffuseReflectionAlbedo * gAmbientFactor;

        const float weight = 1.0 / gSPP;
        // Sample Lights
        for (uint i = 0; i < gSPP; i++) {
            LightSample ls = {};
            if (generateLightSample(sd, sg, ls)) {
                // Shadow test
                if (any(ls.Li > 0.0))
                {
                    ShadowRayData shadowData;
                    shadowData.distance = -1.f;
                    RayDesc shadowRay = ls.getVisibilityRay();
                    uint flags = RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH;
                    TraceRay(gScene.rtAccel, flags, 0xff /* instanceInclusionMask */, 0 /* hitIdx */, rayTypeCount, 0 /* missIdx */, shadowRay, shadowData);

                    if (shadowData.distance < 0) {
                        outColor += bsdf.eval(sd, ls.dir, sg) * ls.Li * weight;
                    }
                }
            }
        }
    }
    else {
        // Sample Env Map
        outColor = kUseEnvBackground ? gScene.envMap.eval(view) * gEnvMapFactor : kDefaultBackgroundColor;
    }

    gOutColor[pixel] = float4(outColor, 1.0);
}

// Uses full NRD with demodulated diffuse and specular
void NRDFullPass(uint2 pixel, uint2 frameDim) {
    HitInfo hitInfo = HitInfo(gVBuffer[pixel]);
    const float3 view = -gView[pixel].xyz;
    SampleGenerator sg = SampleGenerator(pixel, gFrameCount);

    float3 ambient = float3(0); // If demodulated, ambient is added
    float3 emission = float3(0);
    float3 diffuse = float3(0);
    float3 specular = float3(0);

    // Demodulation variables
    float3 diffuseReflectance = {};
    float3 specularReflectance = {};
    float hitT = 0.0;

    if (hitInfo.isValid())
    {
        let lod = ExplicitLodTextureSampler(0.f);
        ShadingData sd = loadShadingData(hitInfo, view, lod);

        // uint hints = (uint) MaterialInstanceHints::AdjustShadingNormal;
        let bsdf = gScene.materials.getMaterialInstance(sd, lod, 0u);
        let bsdfProperties = bsdf.getProperties(sd);

        // Emissive
        emission = bsdfProperties.emission * gEmissiveFactor;
        // Ambient
        ambient += bsdfProperties.diffuseReflectionAlbedo * gAmbientFactor;

        const float weight = 1.0 / gSPP;
        // Sample Lights
        for (uint i = 0; i < gSPP; i++) {
            LightSample ls = {};
            if (generateLightSample(sd, sg, ls)) {
                sd.mtl.setActiveLobes((uint)LobeType::Diffuse);
                float3 LrDiffuse = bsdf.eval(sd, ls.dir, sg) * ls.Li;
                sd.mtl.setActiveLobes((uint)LobeType::Specular);
                float3 LrSpecular = bsdf.eval(sd, ls.dir, sg) * ls.Li;

                // Shadow test
                if (any(ls.Li > 0.0))
                {
                    ShadowRayData shadowData;
                    shadowData.distance = -1.f;
                    RayDesc shadowRay = ls.getVisibilityRay();
                    // uint flags = RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH;
                    uint flags = 0;
                    TraceRay(gScene.rtAccel, flags, 0xff /* instanceInclusionMask */, 0 /* hitIdx */, rayTypeCount, 0 /* missIdx */, shadowRay, shadowData);

                    if (shadowData.distance < 0) {
                        diffuse += LrDiffuse * weight;
                        specular += LrSpecular * weight;
                        hitT = ls.distance;
                    }
                    else {
                        hitT = shadowData.distance;
                    }
                }
            }
        }

        // Create NRD Guide Buffers
        // For diffuse use the sum of the Reflection and Transmission albedo
        diffuseReflectance = max(kNRDMinReflectance, bsdfProperties.diffuseReflectionAlbedo + bsdfProperties.diffuseTransmissionAlbedo);
        // For specular an approximate shading model with a single specular lobe is used
        const float NdotV = saturate(dot(bsdfProperties.guideNormal, sd.V));
        const float ggxAlpha = bsdfProperties.roughness * bsdfProperties.roughness;
        specularReflectance = approxSpecularIntegralGGX(bsdfProperties.specularReflectionAlbedo, ggxAlpha, NdotV);
        specularReflectance = max(kNRDMinReflectance, specularReflectance);

        // Demodulate specular and diffuse
        diffuse = diffuse / diffuseReflectance;
        specular = specular / specularReflectance;
    }
    else {
        // Sample Env Map
        ambient = kUseEnvBackground ? gScene.envMap.eval(view) * gEnvMapFactor : kDefaultBackgroundColor;
    }

    gOutColor[pixel] = float4(ambient, 1.0);
    if (is_valid(gOutEmission)) gOutEmission[pixel] = float4(emission, 1.0);
    if (is_valid(gOutDiffuseRadiance)) gOutDiffuseRadiance[pixel] = float4(diffuse, hitT);
    if (is_valid(gOutSpecularRadiance)) gOutSpecularRadiance[pixel] = float4(specular, hitT);
    if (is_valid(gOutDiffuseReflectance)) gOutDiffuseReflectance[pixel] = float4(diffuseReflectance, 1.0);
    if (is_valid(gOutSpecularReflectance)) gOutSpecularReflectance[pixel] = float4(specularReflectance, 1.0);
}

//Minimal sigma pass
void NRDSigmaPass(uint2 pixel, uint2 frameDim) {
    HitInfo hitInfo = HitInfo(gVBuffer[pixel]);
    const float3 view = -gView[pixel].xyz;
    SampleGenerator sg = SampleGenerator(pixel, gFrameCount);

    float penumbra = kFP16Max;
    float3 unshadowedLight = float3(0);
    float3 ambientColor = float3(0);

    if (hitInfo.isValid())
    {
        let lod = ExplicitLodTextureSampler(0.f);
        ShadingData sd = loadShadingData(hitInfo, view, lod);

        // uint hints = (uint) MaterialInstanceHints::AdjustShadingNormal;
        let bsdf = gScene.materials.getMaterialInstance(sd, lod, 0u);
        let bsdfProperties = bsdf.getProperties(sd);

        // Emissive
        ambientColor += bsdfProperties.emission * gEmissiveFactor;
        // Ambient
        ambientColor += bsdfProperties.diffuseReflectionAlbedo * gAmbientFactor;

        const float weight = 1.0 / gSPP;
        // Sample Lights
        for (uint i = 0; i < gSPP; i++) {
            LightSample ls = {};
            if (generateLightSample(sd, sg, ls)) {
                // Shadow test and BSDF
                unshadowedLight += bsdf.eval(sd, ls.dir, sg) * ls.Li * weight;
                if (any(ls.Li > 0.0))
                {
                    ShadowRayData shadowData;
                    shadowData.distance = -1.f;
                    RayDesc shadowRay = ls.getVisibilityRay();
                    uint flags = 0;
                    TraceRay(gScene.rtAccel, flags, 0xff /* instanceInclusionMask */, 0 /* hitIdx */, rayTypeCount, 0 /* missIdx */, shadowRay, shadowData);

                    if (shadowData.distance < 0) {
                        penumbra = kFP16Max;
                    }
                    else {
                        if (ls.lightType == 1) //Directional
                            penumbra = SIGMA_FrontEnd_PackPenumbra(shadowData.distance, gTanSunAngularRadius);
                        else
                            penumbra = SIGMA_FrontEnd_PackPenumbra(shadowData.distance, ls.distance, ls.lightArea);
                    }
                }
            } else {
                penumbra = 0;
            }
        }
    }
    else {
        // Sample Env Map
        ambientColor += kUseEnvBackground ? gScene.envMap.eval(view) * gEnvMapFactor : kDefaultBackgroundColor;
    }

    if (is_valid(gOutColor)) gOutColor[pixel] = float4(ambientColor, 1.0);
    if (is_valid(gOutUnshadowed)) gOutUnshadowed[pixel] = float4(unshadowedLight, 1.0);
    if (is_valid(gOutPenumbra)) gOutPenumbra[pixel] = penumbra;
}

[shader("miss")]
void miss(inout ShadowRayData rayData)
{
    rayData.distance = -1.f; 
}

[shader("closesthit")]
void closestHit(inout ShadowRayData rayData, BuiltInTriangleIntersectionAttributes attribs) {
    rayData.distance = RayTCurrent();
}

[shader("anyhit")]
void anyHit(inout ShadowRayData rayData, BuiltInTriangleIntersectionAttributes attribs)
{
    // Alpha test for non-opaque geometry.
    if (kRayAlphaTest)
    {
        GeometryInstanceID instanceID = getGeometryInstanceID();
        VertexData v = getVertexData(instanceID, PrimitiveIndex(), attribs);
        const uint materialID = gScene.getMaterialID(instanceID);
        if (gScene.materials.alphaTest(v, materialID, 0.f))
            IgnoreHit();
    }
}

[shader("raygeneration")]
void rayGen()
{
    const uint2 pixel = DispatchRaysIndex().xy;
    const uint2 frameDim = DispatchRaysDimensions().xy;

    if (gMode == 1) {
        NRDFullPass(pixel, frameDim);
    } else if (gMode == 2) {
        NRDSigmaPass(pixel, frameDim);
    } else{
        StandardPass(pixel, frameDim);
    }
}
