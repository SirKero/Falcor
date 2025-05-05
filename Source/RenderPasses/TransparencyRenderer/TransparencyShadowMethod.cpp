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
#include "TransparencyShadowMethod.h"
#include "Utils/Math/FalcorMath.h"
#include "Utils/SampleGenerators/DxSamplePattern.h"
#include "Utils/SampleGenerators/HaltonSamplePattern.h"
#include "Utils/SampleGenerators/StratifiedSamplePattern.h"


namespace
{
    const Gui::DropdownList kSMResolutionDropdown = {
        {256, "256x256"}, {512, "512x512"}, {1024, "1024x1024"}, {2048, "2048x2048"}, {4096, "4096x4096"},
    };
}

TransparencyShadowMethod::TransparencyShadowMethod(ref<Device> pDevice, ref<Scene> pScene) : mpDevice(pDevice), mpScene(pScene) {
    uint count = 0;
    for (auto& lights : mpScene->getLights())
        if (lights->getType() == LightType::Directional)
        {
            mHasDirectionalLight = true;
            count++;
        }
    FALCOR_ASSERT(count <= 1); //More than 1 directional light?
    updateSMMatrices(true);
}

DefineList TransparencyShadowMethod::getDefines()
{
    DefineList defines;
    defines.add("COUNT_LIGHTS", std::to_string(std::max(mpScene->getLightCount(), 1u)));
    return defines;
}

bool TransparencyShadowMethod::renderUI(Gui::Widgets& widget) {
    //Legacy
    return false;
}

void TransparencyShadowMethod::updateSMMatrices(bool rebuild)
{
    auto& lights = mpScene->getLights();
    // Check if resize is neccessary
    bool rebuildAll = mUpdateSMMatrices;
    if (mShadowMapMVP.size() != lights.size())
    {
        mShadowMapMVP.resize(lights.size());
        rebuildAll = true;
    }

    //Set Jitter
    if (mpCPUSampleGenerator)
    {
        mJitter = mpCPUSampleGenerator->next();
        rebuildAll = true;
    }
    else
    {
        mJitter = float2(0.5f); //Center
    }

    // Update view and projection matrices
    for (uint i = 0; i < lights.size(); i++)
    {
        auto changes = lights[i]->getChanges();
        rebuild |= is_set(changes, Light::Changes::Position) || is_set(changes, Light::Changes::Direction) ||
                       is_set(changes, Light::Changes::SurfaceArea);
        rebuild |= lights[i]->getType() == LightType::Directional && mUpdateDirectional;
        rebuild |= rebuildAll;
        if (rebuild)
        {
            updateViewProjection(mShadowMapMVP[i], lights[i]);
        }
    }

    //Update Jitter
    for (uint i = 0; i < lights.size(); i++)
    {
        updateMVPAndJitter(mShadowMapMVP[i]);
    }

    mUpdateSMMatrices = false;
}

void TransparencyShadowMethod::updateViewProjection(LightMVP& lightMVP, ref<Light> pLight) {
    auto& lightData = pLight->getData();
    switch (pLight->getType())
    {
    // Directional light. Create a prespective shadow map
    case LightType::Directional:
    {
        auto& cameraData = mpScene->getCamera()->getData();
        const AABB& sceneBounds = mpScene->getSceneBounds();
        float3 center = sceneBounds.center();
        const float3 upVec = float3(0, 1, 0);
        lightMVP.view = math::matrixFromLookAt(center, center + lightData.dirW, upVec); // Fixed point for view

        // Create a view space AABB to clamp cascaded values
        AABB smViewAABB = sceneBounds.transform(lightMVP.view);

        // Set the Z values to min and max for the scene so that all geometry in the way is rendered
        float distDifference = smViewAABB.maxPoint.z - smViewAABB.minPoint.z;
        float maxZ = math::ceil(smViewAABB.maxPoint.z + distDifference * 0.2f);
        float minZ = math::floor(smViewAABB.minPoint.z);

        // Get Camera Position on a grid
        float2 camPosLV = math::mul(lightMVP.view, float4(cameraData.posW, 1.f)).xy();
        float2 offset = float2(mCascadedSize/2.f);
        if (mCascadedPutCameraOnGrid)
        {
            const float2 resF = float2(mResolution);
            float2 sizePixel = (mCascadedSize / (resF / 2.f));
            float2 halfPixel = sizePixel * 0.5f;
            //Put Camera positon on grid
            camPosLV = (math::round(camPosLV / sizePixel) + halfPixel) * sizePixel;
        }

        float minX = camPosLV.x - offset.x;
        float maxX = camPosLV.x + offset.x;
        float minY = camPosLV.y - offset.y;
        float maxY = camPosLV.y + offset.y;
            
        lightMVP.projection = math::ortho(minX, maxX, minY, maxY, -1.f * maxZ, -1.f * minZ); // set projection
        lightMVP.spreadAngle = 1.0;
        break;
    }
    case LightType::Point:
    {
        lightMVP.pos = lightData.posW;
        float openingAngle = math::min(lightData.openingAngle, float(M_PI / 4.f)); // TODO support point lights
        float3 lightTarget = lightMVP.pos + lightData.dirW;
        const float3 up = abs(lightData.dirW.y) == 1 ? float3(0, 0, 1) : float3(0, 1, 0);
        lightMVP.view = math::matrixFromLookAt(lightData.posW, lightTarget, up);
        lightMVP.projection = math::perspective(openingAngle * 2, 1.f, mNearFar.x, mNearFar.y);
        lightMVP.spreadAngle = std::atan(2.0f * std::tan(openingAngle * 0.5f) / mResolution.y);
        break;
    }
    default:
        throw RuntimeError(
            "Scene contains unsupported Light Type (Distant, Rect, Disc, Sphere)\n Only Spot(+Point) and Directional are currently "
            "supported"
        );
        break;
    }

    //Set Jitter for projection
    float2 jitter = (mJitter * 2.f) / float2(mResolution);
    float4x4 jitterMat = math::matrixFromTranslation(float3(jitter.x, jitter.y, 0.0f));
    lightMVP.projection = math::mul(jitterMat, lightMVP.projection);
}

void TransparencyShadowMethod::updateMVPAndJitter(LightMVP& lightMVP) {
    lightMVP.viewProjection = math::mul(lightMVP.projection, lightMVP.view);
    lightMVP.invViewProjection = math::inverse(lightMVP.viewProjection);
    lightMVP.invProjection = math::inverse(lightMVP.projection);
    lightMVP.invView = math::inverse(lightMVP.view);
}

void TransparencyShadowMethod::setNearFar(const float2 nearFar) {
    if (mNearFar.x != nearFar.x || mNearFar.y != nearFar.y)
    {
        mNearFar = nearFar;
        mUpdateSMMatrices = true;
    }
}

void TransparencyShadowMethod::setGlobalShadowSettings(GlobalShadowSettings& settings) {
   
    if (mResolution.x != settings.resolution){
        mResolutionChanged = true;
        mResolution = uint2(settings.resolution);
    }

    mNearFar = settings.nearFar;
    mCascadedSize = settings.cascadedSize;
    mCascadedPutCameraOnGrid = settings.cascadedPutCameraOnGrid;
    mUseColoredTransparency = settings.enableColoredTransparency;

    mMidpointPercentage = settings.midpointPercentage;
    mMidpointDepthBias = settings.depthBias;

    mEnableRandomSoftShadows = settings.enableSoftShadows;
    mRandomSoftShadowsPositionRadius = settings.softShadowsPositionRadius;
    mRandomSoftShadowsDirSpread = settings.softShadowsDirectionsSpread;

    mSamplePattern = settings.samplePattern;
    mJitterSampleCount = settings.jitterSampleCount;
}

bool TransparencyShadowMethod::globalSettingsRenderUI(Gui::Widgets& widget, GlobalShadowSettings& settings)
{
    #if SIMPLE_UI
    widget.dropdown("Resolution", kSMResolutionDropdown, resolution);
    widget.var("Shadow Map Extend", cascadedSize, 0.f, FLT_MAX, 0.1f);
    widget.tooltip("Radius for the Shadow Map extends from Camera Origin. Ray Tracing is used for the area outside of the radius");
    widget.var("Midpoint Percentage (Dual Depth SM)", midpointPercentage, 0.f, 1.f, 0.001f);
    widget.tooltip("Sets where the midpoint of the midpoint depth is set. 0.0 first depth, 1.0 second depth");
    widget.var("Depth Bias", depthBias, 1e-9f, FLT_MAX, 0.00001f, false, "%.7f");
    widget.tooltip("Depth bias for Dual Depth Shadow Maps. Min(depth + depthBias, midpoint) is used.");
    #else
    widget.dropdown("ShadowResolution", kSMResolutionDropdown, settings.resolution);
    widget.var("Near/Far", settings.nearFar, 0.0f, FLT_MAX, 0.001f);
    widget.tooltip("Global Near/Far values for all lights spotlights");
    widget.var("Cascaded Size", settings.cascadedSize, 0.f, FLT_MAX, 0.1f);
    widget.tooltip("Radius for the cascade");
    widget.checkbox("Update Cascade On Grid", settings.cascadedPutCameraOnGrid);
    widget.tooltip("Fixates the cascaded on an grid with the size of the shadow map resolution");
    //SM jitter settings
    bool jitterChanged = widget.dropdown("Shadow Map Jitter Pattern", settings.samplePattern);
    widget.tooltip("Sets the jitter pattern for the shadow map");
    if (settings.samplePattern != SMSamplePattern::Center)
    {
        jitterChanged |= widget.var("Jitter Sample Count", settings.jitterSampleCount, 1u, 256u, 1u);
    }
    
    widget.checkbox("Enable Colored Transparency", settings.enableColoredTransparency);
    widget.tooltip("Enabled Colored transparency for all methods that support it");

    widget.var("Midpoint Percentage", settings.midpointPercentage, 0.f, 1.f, 0.001f);
    widget.tooltip("Sets where the midpoint of the midpoint depth is set. 0.0 first depth, 1.0 second depth");
    widget.var("Depth Bias", settings.depthBias, 1e-9f, FLT_MAX, 0.00001f, false, "%.7f");
    widget.tooltip("Depth bias for midpoint shadow maps. Min(depth + depthBias, midpoint) is used.");
    #endif

    setGlobalShadowSettings(settings);

    if (jitterChanged)
    {
        updateJitterSamplePattern();
    }

    return false;
}

static ref<CPUSampleGenerator> createSamplePattern(TransparencyShadowMethod::SMSamplePattern type, uint32_t sampleCount)
{
    switch (type)
    {
    case TransparencyShadowMethod::SMSamplePattern::Center:
    case TransparencyShadowMethod::SMSamplePattern::PerSampleHalton:
        return nullptr;
    case TransparencyShadowMethod::SMSamplePattern::MatrixDirectX:
        return DxSamplePattern::create(sampleCount);
    case TransparencyShadowMethod::SMSamplePattern::MatrixHalton:
        return HaltonSamplePattern::create(sampleCount);
    case TransparencyShadowMethod::SMSamplePattern::MatrixStratified:
        return StratifiedSamplePattern::create(sampleCount);
    default:
        FALCOR_UNREACHABLE();
        return nullptr;
    }
}

void TransparencyShadowMethod::updateJitterSamplePattern()
{
    mpCPUSampleGenerator = createSamplePattern(mSamplePattern, mJitterSampleCount);
    if (mpCPUSampleGenerator)
        mJitterSampleCount = mpCPUSampleGenerator->getSampleCount();
}
