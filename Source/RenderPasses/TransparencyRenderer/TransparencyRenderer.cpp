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
#include "TransparencyRenderer.h"
#include "RenderGraph/RenderPassHelpers.h"
#include "RenderGraph/RenderPassStandardFlags.h"

#include "AccelShadow/AccelShadow.h"
#include "LinkedList/LinkedListShadow.h"
#include "AccelShadowKBuffer/AccelShadowKBuffer.h"
#include "AccelIrregularZ/AccelIrregularZ.h"
#include "LinkedListIrregularZ/LinkedListIrregularZ.h"

#include "Utils/SampleGenerators/DxSamplePattern.h"
#include "Utils/SampleGenerators/HaltonSamplePattern.h"
#include "Utils/SampleGenerators/StratifiedSamplePattern.h"

extern "C" FALCOR_API_EXPORT void registerPlugin(Falcor::PluginRegistry& registry)
{
    registry.registerClass<RenderPass, TransparencyRenderer>();
}

namespace
{
    // shader
    const std::string kShaderFolder = "RenderPasses/TransparencyRenderer/";
    const std::string kShaderEvalDirect = kShaderFolder + "EvalDirect.cs.slang";
    const std::string kShaderEvalTransparenciesDirect = kShaderFolder + "EvalTransparenciesDirect.rt.slang";
    const std::string kShaderReflections = kShaderFolder + "RayReflections.rt.slang";
    const std::string kShaderPathTracer = kShaderFolder + "PathTracer.rt.slang";

    const std::string kShaderModel = "6_6"; //Shader model for compute shader

    const std::string kOutputColor = "outColor";
    const std::string kOutputDebug = "outDebug";
    const std::string kOutputDepth = "outDepth";
    const std::string kOutputMV = "outMotion";

    const ChannelList kOutputChannels = {
        {kOutputColor, "gOutputColor", "Output color (sum of direct and indirect)", false, ResourceFormat::RGBA32Float},
        {kOutputDebug, "gDebugOut", "Output debug tex (sum of direct and indirect)", true, ResourceFormat::RGBA32Float},
    };

    const ChannelList kOutputGeometryInfoChannels = {
        {kOutputDepth, "gOutDepth", "Depth buffer (NDC) with transparencies", true, ResourceFormat::R32Float},
        {kOutputMV, "gOutMotion", "Motion Vector including transparencies", true, ResourceFormat::RG32Float},
    };

    const std::string kParticleMaterialBufferName = "gParticleMaterials";

    const Gui::DropdownList kMaskISMMultFactorDropdown{{1u, "1"}, {4u, "4"}, {9u, "9"}, {16u, "16"}};

    //Properties for render graph
    const std::string kPropsEnableRenderMode = "RenderMode";
    const std::string kPropsShadowMethod = "ShadowMethod";
    const std::string kPropsEnableMask = "EnableMask";
    const std::string kPropsShadowResolution = "ShadowResolution";

}; // namespace

TransparencyRenderer::TransparencyRenderer(ref<Device> pDevice, const Properties& props) : RenderPass(pDevice)
{
    mpSampleGenerator = SampleGenerator::create(mpDevice, SAMPLE_GENERATOR_UNIFORM);
    FALCOR_ASSERT(mpSampleGenerator);
    parseProperties(props);
}

void TransparencyRenderer::parseProperties(const Properties& props)
{
    for (const auto& [key, value] : props)
    {
        if (key == kPropsEnableRenderMode)
            mCameraRenderMode = value;
        else if (key == kPropsShadowMethod)
            mShadowRenderMethod = value;
        else if (key == kPropsEnableMask)
            mIrregularUseShadowMask = value;
        else if (key == kPropsShadowResolution)
            mShadowSettings.resolution = value;
        else
            logWarning("Unknown property '{}' in TransparencyRenderers properties.", key);
    }
}

Properties TransparencyRenderer::getProperties() const
{
    Properties props = Properties();

    props[kPropsEnableRenderMode] = mCameraRenderMode;
    props[kPropsShadowMethod] = mShadowRenderMethod;
    props[kPropsEnableMask] = mIrregularUseShadowMask;
    props[kPropsShadowResolution] = mShadowSettings.resolution;

    return props;
}

RenderPassReflection TransparencyRenderer::reflect(const CompileData& compileData)
{
    RenderPassReflection reflector;

    // Define our input/output channels.
    addRenderPassOutputs(reflector, kOutputChannels, ResourceBindFlags::UnorderedAccess | ResourceBindFlags::RenderTarget);
    addRenderPassOutputs(reflector, kOutputGeometryInfoChannels);

    return reflector;
}

void TransparencyRenderer::execute(RenderContext* pRenderContext, const RenderData& renderData)
{
    // Update refresh flag if options that affect the output have changed.
    auto& dict = renderData.getDictionary();
    if (mOptionsChanged)
    {
        auto flags = dict.getValue(kRenderPassRefreshFlags, RenderPassRefreshFlags::None);
        dict[Falcor::kRenderPassRefreshFlags] = flags | Falcor::RenderPassRefreshFlags::RenderOptionsChanged;
        mOptionsChanged = false;
    }

    // If we have no scene, just clear the outputs and return.
    if (!mpScene || mpScene->getLights().empty())
    {
        auto clearOut = [&](const ChannelList& channelList)
        {
            for (const auto& it : channelList)
            {
                Texture* pDst = renderData.getTexture(it.name).get();
                if (pDst)
                    pRenderContext->clearTexture(pDst);
            }
        };
        
        clearOut(kOutputChannels);
        clearOut(kOutputGeometryInfoChannels);
        return;
    }

    //Set render dimensions for LOD helper
    updateFrameDim(renderData.getDefaultTextureDims());

    if (mOpaqueShadowMapModeChanged)
    {
        mpEvalDirectPass.reset();
        mEvalTransparencyDirectRay.resetPip();
        mOpaqueShadowMapModeChanged = false;
    }
    
    // Request the light collection if emissive lights are enabled.
    if (mpScene->getRenderSettings().useEmissiveLights)
    {
        mpScene->getLightCollection(pRenderContext);
    }

    //Create Textures needed for the renderer
    prepareResources(pRenderContext, renderData);

    //Generate optional opaque shadow map
    if (mEnableOpaqueShadowMaps && !mpShadowMap)
    {
        mpShadowMap = std::make_shared<ShadowMap>(mpDevice, mpScene, ShadowMapType::Variance);
        mpShadowMap->setOpaqueCullModeNonOpaque();
    }

    if (mEnableOpaqueShadowMaps && mpShadowMap)
    {
        mpShadowMap->update(pRenderContext);
        for (auto& method : mShadowMethods)
            method->enableOpaqueShadowMap();
    }
    else if (!mEnableOpaqueShadowMaps && mpShadowMap)
    {
        for (auto& method : mShadowMethods)
            method->enableOpaqueShadowMap(false);
    }

    //Update LOD mode and Colored Transparency
    for (auto& method : mShadowMethods)
    {
        method->setShadowLODMode(mShadowLodMode);
        method->enableBlacklist(mUseShadowMaterialFlagAsBlacklist && mIrregularUseShadowMask);
    }        
    if (mpShadowMask)
    {
        mpShadowMask->setIDMMultFactor(mMaskISMMultFactor);
        mpShadowMask->enableBlacklist(mUseShadowMaterialFlagAsBlacklist && mIrregularUseShadowMask);
    }

    //Generate Shadow Structure
    if (mShadowRenderMethod != ShadowRenderMethod::RayTracing)
        mShadowMethods[mSelectedShadowMethod]->generate(pRenderContext, renderData);

    if (mIrregularUseShadowMask && (mShadowRenderMethod != ShadowRenderMethod::RayTracing))
    {
        TransparentShadowMask::MaskGenerateMode genMode = TransparentShadowMask::MaskGenerateMode::Mask_ISM;
        if (mShadowRenderMethod == ShadowRenderMethod::AccelShadow || mShadowRenderMethod == ShadowRenderMethod::LinkedList)
            genMode = TransparentShadowMask::MaskGenerateMode::Mask_SM;

        mpShadowMask->generate(pRenderContext, renderData, mShadowMethods[mSelectedShadowMethod].get(), mpSampleGenerator, genMode);
    }

    //Render
    switch (mCameraRenderMode)
    {
    case CameraRenderMode::DirectRT:
        {
            //FALCOR_PROFILE(pRenderContext, "CameraTrace");
            evalDirectTransparency(pRenderContext, renderData);
        }
        break;
    case CameraRenderMode::DirectRT_Reflections:
        {
            FALCOR_PROFILE(pRenderContext, "CameraTrace");
            evalDirectTransparency(pRenderContext, renderData);
            evalRayReflections(pRenderContext, renderData);
        }
        break;
    case CameraRenderMode::PathTracer:
        evalPathTracer(pRenderContext, renderData);
        break;
    }
     
    // Generate Shadow Structure
    if (mShadowRenderMethod != ShadowRenderMethod::RayTracing)
    {
        ref<Texture> pAdditionalTex = renderData.getTexture(kOutputColor);
        if (mShadowRenderMethod == ShadowRenderMethod::LinkedListIrregularZ && mpShadowMask)
            pAdditionalTex = mpShadowMask->getMask();
        mShadowMethods[mSelectedShadowMethod]->debugPass(
            pRenderContext, renderData, renderData.getTexture(kOutputDebug), pAdditionalTex
        );
    }
        

    mFrameCount++;
}

void TransparencyRenderer::renderUI(Gui::Widgets& widget)
{
    bool dirty = false;
    #if SIMPLE_UI
    bool useRayReflections = mCameraRenderMode == CameraRenderMode::DirectRT_Reflections;
    bool reflectionsChanged = widget.checkbox("Use Ray Reflections", useRayReflections);
    if (reflectionsChanged)
        mCameraRenderMode = useRayReflections ? CameraRenderMode::DirectRT_Reflections : CameraRenderMode::DirectRT;

    bool methodChanged = widget.dropdown("Shadow Method", mShadowRenderMethod);
    if (methodChanged)
    {
        mSelectedShadowMethod = mShadowRenderMethod == ShadowRenderMethod::RayTracing ? 0 : (uint)mShadowRenderMethod - 1u;
        if (mShadowRenderMethod == ShadowRenderMethod::LinkedListIrregularZ || mShadowRenderMethod == ShadowRenderMethod::AccelIrregularZ)
        {
            mShadowSettings.resolution = 512;
            mShadowSettings.cascadedPutCameraOnGrid = true;
        }
        else if (mShadowRenderMethod == ShadowRenderMethod::AccelShadow || mShadowRenderMethod == ShadowRenderMethod::LinkedList)
        {
            mShadowSettings.resolution = 2048;
            mShadowSettings.cascadedPutCameraOnGrid = false;
        }
            
    }
       

    if (mShadowRenderMethod != ShadowRenderMethod::RayTracing)
    {
        widget.checkbox("Enable Mask", mIrregularUseShadowMask);
        widget.tooltip("Enables the semi-transparent Object Mask for the shadow map methods ");
        if (mIrregularUseShadowMask &&
            (mShadowRenderMethod == ShadowRenderMethod::AccelIrregularZ || mShadowRenderMethod == ShadowRenderMethod::LinkedListIrregularZ))
        {
            widget.dropdown("ISM Multiplication Factor", kMaskISMMultFactorDropdown, mMaskISMMultFactor);
            widget.tooltip(
                "Multiplication factor for the (opaque) Importance Shadow Map used when the mask is active. The dispatch size and all samples in the Sample Distribution will be multiplied with this number."
            );
        }
    }

    if (mShadowRenderMethod == ShadowRenderMethod::AccelIrregularZ || mShadowRenderMethod == ShadowRenderMethod::LinkedListIrregularZ)
    {
        widget.dropdown("Importance Formula", mImportanceMode);
    }

    widget.checkbox("Enable Soft Shadows", mShadowSettings.enableSoftShadows);
    widget.tooltip("Approximate Soft Shadows.");

    if (mShadowRenderMethod != ShadowRenderMethod::RayTracing)
    {
        if (auto group = widget.group("General Shadow Map Settings"))
        {
            mShadowMethods[mSelectedShadowMethod]->globalSettingsRenderUI(group, mShadowSettings);
        }
    }

    if (mShadowRenderMethod != ShadowRenderMethod::RayTracing && !mShadowMethods.empty() && mShadowMethods[mSelectedShadowMethod])
    {
        mShadowMethods[mSelectedShadowMethod]->renderUI(widget);
    }

    if (auto group = widget.group("Renderer Settings"))
    {
        bool updatePattern = widget.dropdown("Camera Jitter", mCameraJitterSamplePattern);
        widget.tooltip(
            "Selects sample pattern for anti-aliasing over multiple frames.\n\n"
            "The camera jitter is set at the start of each frame based on the chosen pattern. All render passes should see the same "
            "jitter.\n"
            "'Center' disables anti-aliasing by always sampling at the center of the pixel.",
            true
        );
        if (mCameraJitterSamplePattern != CamJitterSamplePattern::Center)
        {
            updatePattern |= widget.var("Camera Jitter Sample count", mCameraJitterNumSamples, 1u);
            widget.tooltip("Number of samples in the anti-aliasing sample pattern.", true);
        }
        if (updatePattern)
        {
            updateSamplePattern();
            mOptionsChanged = true;
        }

        switch (mCameraRenderMode)
        {
        case CameraRenderMode::DirectRT:
            dirty |= widget.dropdown("Light Sample Mode", mLightSampleMode);
            dirty |= widget.var("Ambient Strength", mAmbientStrength, 0.f, FLT_MAX);
            dirty |= widget.var("Env Map Strength", mEnvMapStrength, 0.f, FLT_MAX);
            break;
        case CameraRenderMode::DirectRT_Reflections:
            dirty |= widget.dropdown("Light Sample Mode", mLightSampleMode);
            dirty |= widget.var("Ambient Strength", mAmbientStrength, 0.f, FLT_MAX);
            dirty |= widget.var("Env Map Strength", mEnvMapStrength, 0.f, FLT_MAX);
            dirty |= widget.var("Use RayReflections at spec percentage", mRayReflectionsRoughnessThreshold, 0.f, 1.f);
            break;
        }
    }
    #else
    dirty |= widget.dropdown("Render Method", mCameraRenderMode);

    if (auto group = widget.group("Render Settings"))
    {
        bool updatePattern = widget.dropdown("Camera Jitter", mCameraJitterSamplePattern);
        widget.tooltip(
            "Selects sample pattern for anti-aliasing over multiple frames.\n\n"
            "The camera jitter is set at the start of each frame based on the chosen pattern. All render passes should see the same "
            "jitter.\n"
            "'Center' disables anti-aliasing by always sampling at the center of the pixel.",
            true
        );
        if (mCameraJitterSamplePattern != CamJitterSamplePattern::Center)
        {
            updatePattern |= widget.var("Sample count", mCameraJitterNumSamples, 1u);
            widget.tooltip("Number of samples in the anti-aliasing sample pattern.", true);
        }
        if (updatePattern)
        {
            updateSamplePattern();
            mOptionsChanged = true;
        }

        switch (mCameraRenderMode)
        {
        case CameraRenderMode::DirectRT:
            dirty |= widget.dropdown("Light Sample Mode", mLightSampleMode);
            dirty |= widget.var("Ambient Strength", mAmbientStrength, 0.f, FLT_MAX);
            dirty |= widget.var("Env Map Strength", mEnvMapStrength, 0.f, FLT_MAX);
            dirty |= widget.dropdown("Ray LOD mode", mRayLodMode);
            dirty |= widget.checkbox("Enable LOD mode for Transparency Pass", mEnableTransparencyPassLODMode);
            dirty |= widget.dropdown("Shadow LOD mode", mShadowLodMode);
            break;
        case CameraRenderMode::DirectRT_Reflections:
            dirty |= widget.dropdown("Light Sample Mode", mLightSampleMode);
            dirty |= widget.var("Ambient Strength", mAmbientStrength, 0.f, FLT_MAX);
            dirty |= widget.var("Env Map Strength", mEnvMapStrength, 0.f, FLT_MAX);
            dirty |= widget.var("Use RayReflections at spec percentage", mRayReflectionsRoughnessThreshold, 0.f, 1.f);
            dirty |= widget.dropdown("Ray LOD mode", mRayLodMode);
            dirty |= widget.checkbox("Enable LOD mode for Transparency Pass", mEnableTransparencyPassLODMode);
            dirty |= widget.dropdown("Shadow LOD mode", mShadowLodMode);
            break;
        case CameraRenderMode::PathTracer:
            dirty |= widget.dropdown("Light Sample Mode", mLightSampleMode);
            dirty |= widget.var("Env Map Strength", mEnvMapStrength, 0.f, FLT_MAX);
            dirty |= widget.var("Max Bounces", mPTMaxBounces, 0u, UINT_MAX);
            widget.tooltip("Maximum number of Bounces. Also includes semi-transparent hits");
            dirty |= widget.checkbox("Use Russian Roulette", mPTUseRussianRoulette);
            break;
        }       
    }

    bool methodChanged = widget.dropdown("Shadow Method", mShadowRenderMethod);
    if (methodChanged)
    {
        mSelectedShadowMethod = mShadowRenderMethod == ShadowRenderMethod::RayTracing ? 0 : (uint)mShadowRenderMethod - 1u;
        if (mShadowRenderMethod == ShadowRenderMethod::LinkedListIrregularZ || mShadowRenderMethod == ShadowRenderMethod::AccelIrregularZ)
        {
            mShadowSettings.resolution = 512;
            mShadowSettings.cascadedPutCameraOnGrid = true;
        }
        else if (mShadowRenderMethod == ShadowRenderMethod::AccelShadow || mShadowRenderMethod == ShadowRenderMethod::LinkedList)
        {
            mShadowSettings.resolution = 2048;
            mShadowSettings.cascadedPutCameraOnGrid = false;
        }
    }
    dirty |= methodChanged;

    //mOpaqueShadowMapModeChanged |= widget.checkbox("Enable Opaque Shadow Maps", mEnableOpaqueShadowMaps);
    //widget.tooltip("Enables a extra opaque shadow map pass. Shadow Method should only evaluate non-opaque geometry in that case");

    widget.checkbox("Enable Fallback Shadows", mEnableFallbackRayTracedShadows);
    widget.tooltip("Some techniques allow for ray traced shadows as a fallback. They can be toggled on/off manually here");

    widget.checkbox("Enable Stochastic Shadow Ray", mShadowUseStochasticRayTracing);
    widget.tooltip("Toggle Stochastic Ray Tracing for the Visibility ray. Applies to all techniques that use stochastic ray tracing");

    if (mShadowRenderMethod != ShadowRenderMethod::RayTracing)
    {
        widget.checkbox("Enable Shadow Backproject Mask", mIrregularUseShadowMask);
        widget.tooltip(
            "Enables a backprojection mask (non-opaque objects rasterized), that is used to reject samples for only opaque on fully-lit "
            "samples in the backprojection process"
        );
        if (mIrregularUseShadowMask &&
            (mShadowRenderMethod != ShadowRenderMethod::AccelIrregularZ || mShadowRenderMethod != ShadowRenderMethod::LinkedListIrregularZ))
        {
            widget.dropdown("Mask ISM Multiplication Factor", kMaskISMMultFactorDropdown, mMaskISMMultFactor);
            widget.tooltip("Multiplication factor for the ISM used when the mask is active. The dispatch size and all samples in the Sample Distribution will be multiplied with this number.");
        }
        widget.checkbox("Enable shadow material flag as blacklist", mUseShadowMaterialFlagAsBlacklist);
        widget.tooltip("Uses the \"non-shadow throwable\" material flag as a blacklist.");
    }

    if (auto group = widget.group("Soft Shadow Options"))
    {
        group.text("Info");
        group.tooltip("Creates fake soft shadows by randomly offset the starting position or direction");
        group.checkbox("Enable", mShadowSettings.enableSoftShadows);
        if (mShadowSettings.enableSoftShadows)
        {
            group.var("Position offset radius (Spot/Point)", mShadowSettings.softShadowsPositionRadius, 0.f, FLT_MAX, 0.001f, false, "%.6f");
            group.var("Directional Spread (Dir)", mShadowSettings.softShadowsDirectionsSpread, 0.f, FLT_MAX, 0.001f, false, "%.6f");
        }
    } 

    if (mEnableOpaqueShadowMaps && mpShadowMap)
    {
        if (auto group = widget.group("Opaque Shadow Map Settings"))
            mpShadowMap->renderUI(group);
    }

    if (mShadowRenderMethod == ShadowRenderMethod::AccelIrregularZ || mShadowRenderMethod == ShadowRenderMethod::LinkedListIrregularZ)
    {
        widget.dropdown("Importance Mode", mImportanceMode);
    }

    if (mShadowRenderMethod != ShadowRenderMethod::RayTracing)
    {
        if (auto group = widget.group("Global Shadow Map Settings"))
        {
            mShadowMethods[mSelectedShadowMethod]->globalSettingsRenderUI(group, mShadowSettings);
        }
        mShadowMethods[mSelectedShadowMethod]->setGlobalShadowSettings(mShadowSettings);
    }

    if (mShadowRenderMethod != ShadowRenderMethod::RayTracing && !mShadowMethods.empty() && mShadowMethods[mSelectedShadowMethod])
    {
        mShadowMethods[mSelectedShadowMethod]->renderUI(widget);
    }
    #endif
}

void TransparencyRenderer::setScene(RenderContext* pRenderContext, const ref<Scene>& pScene)
{
    // Set new scene.
    mpScene = pScene;

    //Reset all passes
    mShadowMethods.clear();
    mpShadowMap.reset();
    mpEvalDirectPass.reset();
    mEvalTransparencyDirectRay.resetPip();
    mpParticleMaterials.reset();

    if (mpScene)
    {
        mpScene->setRtASAdditionalGeometryFlag(RtGeometryFlags::NoDuplicateAnyHitInvocation); // Add the NoDuplicateAnyHitInvocation flag to
        const auto lightCount = mpScene->getLightCount();
        if (lightCount == 0)
            logWarning("No analytic light sources in scene. The Transparancy Renderer will not render anything!");
        else
        {
            // Add the shadow methods
            mShadowMethods.push_back(std::make_shared<AccelShadow>(mpDevice, mpScene));          // Accel Shadow (0)
            mShadowMethods.push_back(std::make_shared<LinkedListShadow>(mpDevice, mpScene));     // LinkedList (1)
            mShadowMethods.push_back(std::make_shared<AccelShadowKBuffer>(mpDevice, mpScene));   // AccelShadow KBuffer (2)
            mShadowMethods.push_back(std::make_shared<AccelIrregularZ>(mpDevice, mpScene));      // Accel IrregularZ (3)
            mShadowMethods.push_back(std::make_shared<LinkedListIrregularZ>(mpDevice, mpScene)); // Linked List IrregularZ (4)

            if (lightCount == 1)
                mLightSampleMode = LightSampleMode::Uniform; // Cheapest light sample mode
        }

        switch (mShadowRenderMethod)
        {
        
        case TransparencyRenderer::ShadowRenderMethod::LinkedList:
            mSelectedShadowMethod = 1;
            break;
        case TransparencyRenderer::ShadowRenderMethod::AccelShadowKBuffer:
            mSelectedShadowMethod = 2;
            break;
        case TransparencyRenderer::ShadowRenderMethod::AccelIrregularZ:
            mSelectedShadowMethod = 3;
            break;
        case TransparencyRenderer::ShadowRenderMethod::LinkedListIrregularZ:
            mSelectedShadowMethod = 4;
            break;
        case TransparencyRenderer::ShadowRenderMethod::RayTracing:
        case TransparencyRenderer::ShadowRenderMethod::AccelShadow:
        default:
            mSelectedShadowMethod = 0;
            break;
        }

        mpShadowMask = std::make_shared<TransparentShadowMask>(mpDevice, mpScene);

        //Approximate Cascaded Size
        //TODO Set size with script and ignore this in this case
        auto& sceneAABB = mpScene->getSceneBounds();
        mShadowSettings.cascadedSize = math::max(sceneAABB.maxPoint.x - sceneAABB.minPoint.x, sceneAABB.maxPoint.y - sceneAABB.minPoint.y) * 0.4f;

        //Create and fill the particle material buffer
        
        uint materialCount = mpScene->getMaterialCount();
        materialCount = materialCount + (32u - (materialCount % 32u)); //Round up to next byte size
        std::vector<uint> particleMaterialsData(materialCount / 32u);
        auto& particleSystems = mpScene->getParticleSystem();
        for (auto& ps : particleSystems)
        {
            auto& mesh = mpScene->getMesh(ps.meshIDs[0]); //Get first mesh
            const uint materialID = mesh.materialID;
            //Mark Material ID
            uint bufferIdx = materialID / 32u;
            uint bitIdx = materialID % 32u;

            particleMaterialsData[bufferIdx] |= 1u << bitIdx;
        }

        mpParticleMaterials =
            Buffer::create(mpDevice, materialCount / 4u, ResourceBindFlags::ShaderResource, Buffer::CpuAccess::None, particleMaterialsData.data());
        mpParticleMaterials->setName("ParticleMaterialsBuffer");

        //Camera Jitter
        updateSamplePattern();

        // Apply settings for the first chosen method in case a setting is different from the defaults
        mShadowMethods[mSelectedShadowMethod]->setGlobalShadowSettings(mShadowSettings);
    }
}

DefineList TransparencyRenderer::getLightEvalDefines() {
    DefineList defines = {};
    defines.add("SHADOW_EVAL_MODE", std::to_string((uint)mShadowRenderMethod));
    defines.add(mShadowMethods[mSelectedShadowMethod]->getDefines());
    defines.add("LIGHT_SAMPLE_MODE", std::to_string((uint)mLightSampleMode));
    if (mpShadowMap && mEnableOpaqueShadowMaps)
        defines.add(mpShadowMap->getDefines());
    defines.add("EVAL_OPAQUE_SHADOW_MAP", mEnableOpaqueShadowMaps ? "1" : "0");
    RayFlags evalQueryRayFlags = mEnableOpaqueShadowMaps ? RayFlags::CullOpaque : RayFlags::ForceNonOpaque;
    evalQueryRayFlags = mIrregularUseShadowMask && mShadowRenderMethod != ShadowRenderMethod::RayTracing ? RayFlags::CullNonOpaque : evalQueryRayFlags; 
    evalQueryRayFlags =
        mUseShadowMaterialFlagAsBlacklist && mIrregularUseShadowMask && mShadowRenderMethod != ShadowRenderMethod::RayTracing
        ? RayFlags::None : evalQueryRayFlags;
    defines.add("TR_RAY_QUERY_FLAG", std::to_string((uint)evalQueryRayFlags));
    defines.add("ENABLE_FALLBACK_RAY_SHADOWS", mEnableFallbackRayTracedShadows ? "1" : "0");
    defines.add("AMBIENT_STRENGTH", std::to_string(mAmbientStrength));
    defines.add("ENV_MAP_STRENGTH", std::to_string(mEnvMapStrength));
    defines.add("USE_STOCHASTIC_RAY_TRACING", mShadowUseStochasticRayTracing ? "1" : "0");
    defines.add("TR_USE_COLORED_TRANSPARENCY", mShadowSettings.enableColoredTransparency ? "1" : "0");
    defines.add("IMPORTANCE_MODE", std::to_string((uint)mImportanceMode));

    //Mask
    defines.add("USE_IRRGEGULAR_SHADOW_MASK", mIrregularUseShadowMask ? "1" : "0");
    defines
        .add("SHADOW_MATERIAL_FLAG_AS_BLACKLIST", mUseShadowMaterialFlagAsBlacklist && mIrregularUseShadowMask ? "1" : "0");
    defines.add("MASK_ISM_MULT_FACTOR", std::to_string(mMaskISMMultFactor));

    //Soft Shadows
    defines.add("USE_SOFT_SHADOWS", mShadowSettings.enableSoftShadows ? "1" : "0");
    defines.add("SOFT_SHADOWS_POS_RADIUS", std::to_string(mShadowSettings.softShadowsPositionRadius));
    defines.add("SOFT_SHADOWS_DIR_SPREAD", std::to_string(mShadowSettings.softShadowsDirectionsSpread * 0.0001)); //TODO proper conversion

    //LOD
    defines.add("RAY_LOD_MODE", std::to_string((uint)mRayLodMode));
    defines.add("SHADOW_LOD_MODE", std::to_string((uint)mShadowLodMode));
    float2 invRenderDims = 1.f / float2(mRenderDims);
    defines.add("INV_FRAME_DIM_X", std::to_string(invRenderDims.x));
    defines.add("INV_FRAME_DIM_Y", std::to_string(invRenderDims.y));
    defines.add("SCREEN_SPACE_PIXEL_SPREAD_ANGLE", std::to_string(mpScene->getCamera()->computeScreenSpacePixelSpreadAngle(mRenderDims.y)));

    return defines;
}

void TransparencyRenderer::prepareResources(RenderContext* pRenderContext, const RenderData& renderData) {
    // Textures
    const auto& screenSize = renderData.getDefaultTextureDims();

    auto needRebuild = [](const ref<Texture>& pTex, const uint2& size) {
        bool rebuild = !pTex;
        if (!rebuild)
            rebuild |= pTex->getWidth() != size.x || pTex->getHeight() != size.y;
        return rebuild;
    };
    
    if (mCameraRenderMode != CameraRenderMode::PathTracer && needRebuild(mpTransparencyThp, screenSize))
    {
        mpTransparencyThp = Texture::create2D(
            mpDevice, screenSize.x, screenSize.y, ResourceFormat::RGBA32Float, 1u, 1u, nullptr,
            ResourceBindFlags::UnorderedAccess | ResourceBindFlags::ShaderResource
        );
        mpTransparencyThp->setName("TransparencyThp");
    }

    if (mCameraRenderMode == CameraRenderMode::DirectRT_Reflections &&
        needRebuild(mpReflectionsMask, screenSize))
    {
        mpReflectionsMask = Texture::create2D(
            mpDevice, screenSize.x, screenSize.y, ResourceFormat::R8Unorm, 1u, 1u, nullptr,
            ResourceBindFlags::UnorderedAccess | ResourceBindFlags::ShaderResource
        );
        mpReflectionsMask->setName("ReflectionsMask");
    }

     if (mCameraRenderMode == CameraRenderMode::DirectRT_Reflections && needRebuild(mpReflectionsHit, screenSize))
    {
         mpReflectionsHit = Texture::create2D(
            mpDevice, screenSize.x, screenSize.y, HitInfo::kDefaultFormat, 1u, 1u, nullptr,
            ResourceBindFlags::UnorderedAccess | ResourceBindFlags::ShaderResource
        );
        mpReflectionsHit->setName("ReflectionHitBuffer");
    }
}

void TransparencyRenderer::evalDirectTransparency(RenderContext* pRenderContext, const RenderData& renderData) {
    FALCOR_PROFILE(pRenderContext, "TraceCameraRay");

    // Create scene ray tracing program.
    if (!mEvalTransparencyDirectRay.pProgram)
    {
        //Shader setup
        RtProgram::Desc desc;
        desc.addShaderModules(mpScene->getShaderModules());
        desc.addShaderLibrary(kShaderEvalTransparenciesDirect);
        desc.setMaxAttributeSize(mpScene->getRaytracingMaxAttributeSize());
        desc.setMaxPayloadSize(36u);
        desc.setMaxTraceRecursionDepth(1u);
        
        mEvalTransparencyDirectRay.pBindingTable = RtBindingTable::create(1, 1, mpScene->getGeometryCount());
        auto& sbt = mEvalTransparencyDirectRay.pBindingTable;
        sbt->setRayGen(desc.addRayGen("rayGen"));
        sbt->setMiss(0, desc.addMiss("miss"));

        //Only Triangle meshes are supported
        if (mpScene->hasGeometryType(Scene::GeometryType::TriangleMesh))
        {
            sbt->setHitGroup(
                0, mpScene->getGeometryIDs(Scene::GeometryType::TriangleMesh), desc.addHitGroup("closestHit", "anyHit")
            );
        }

        //Initial defines and program
        DefineList defines;
        defines.add(mpSampleGenerator->getDefines());
        defines.add(mpScene->getSceneDefines());
       
        mEvalTransparencyDirectRay.pProgram = RtProgram::create(mpDevice, desc, defines);
    }
    FALCOR_ASSERT(mEvalTransparencyDirectRay.pProgram);

    bool useLodMode = mEnableTransparencyPassLODMode && ((mRayLodMode == TexLODMode::RayCones) || (mRayLodMode == TexLODMode::RayDiffs));
    // Update define that can change at runtime
    mEvalTransparencyDirectRay.pProgram->addDefines(getLightEvalDefines());
    mEvalTransparencyDirectRay.pProgram->addDefines(getValidResourceDefines(kOutputGeometryInfoChannels, renderData)); //For updating depth and motion
    mEvalTransparencyDirectRay.pProgram->addDefines(getValidResourceDefines(kOutputChannels, renderData)); //For NRD
    mEvalTransparencyDirectRay.pProgram->addDefine("ENABLE_TRANSPARENCY_LOD", useLodMode ? "1" : "0");
    mEvalTransparencyDirectRay.pProgram->addDefine("CALC_MVEC_AND_DEPTH_FOR_NON_OPAQUE", "1");
    mEvalTransparencyDirectRay.pProgram->addDefine("EVAL_OPAQUE_HIT", "1");
    mEvalTransparencyDirectRay.pProgram->addDefine(
        "RAY_REFLECTIONS_ENABLE", mCameraRenderMode == CameraRenderMode::DirectRT_Reflections ? "1" : "0"
    );
    mEvalTransparencyDirectRay.pProgram->addDefine("REFLECTIONS_ROUGHNESS_THRESHOLD", std::to_string(mRayReflectionsRoughnessThreshold));
    
    // Init Vars
    if (!mEvalTransparencyDirectRay.pVars)
    {
        mEvalTransparencyDirectRay.pProgram->setTypeConformances(mpScene->getTypeConformances());
        mEvalTransparencyDirectRay.pVars = RtProgramVars::create(mpDevice, mEvalTransparencyDirectRay.pProgram, mEvalTransparencyDirectRay.pBindingTable);
        auto var = mEvalTransparencyDirectRay.pVars->getRootVar();
        mpSampleGenerator->setShaderData(var);
        var[kParticleMaterialBufferName] = mpParticleMaterials;
    }

    FALCOR_ASSERT(mEvalTransparencyDirectRay.pVars);

    //Bind shader data
    const uint2 targetDim = renderData.getDefaultTextureDims();
    FALCOR_ASSERT(targetDim.x > 0 && targetDim.y > 0);

    auto var = mEvalTransparencyDirectRay.pVars->getRootVar();
    
    if (mShadowRenderMethod != ShadowRenderMethod::RayTracing)
        mShadowMethods[mSelectedShadowMethod]->setShaderData(var);

    // Set shadow mask and opaque shadow map
    if (mpShadowMask && (mShadowRenderMethod != ShadowRenderMethod::RayTracing))
    {
        if (mShadowRenderMethod == ShadowRenderMethod::AccelIrregularZ || mShadowRenderMethod == ShadowRenderMethod::LinkedListIrregularZ)
            mShadowMethods[mSelectedShadowMethod]->setShadowMask(
                var, mpShadowMask->getMask(), mpShadowMask->getMaskImportanceShadowMap(), mIrregularUseShadowMask
            );
        else // Non irregular modes
        {
            mShadowMethods[mSelectedShadowMethod]->setShadowMask(
                var, mpShadowMask->getMask(), mpShadowMask->getMaskShadowMap(), mIrregularUseShadowMask
            );
        }
    }

    if (mEnableOpaqueShadowMaps)
        mpShadowMap->setShaderDataAndBindBlock(var, renderData.getDefaultTextureDims());

    var["CB"]["gFrameCount"] = mFrameCount;

    // Bind I/O buffers. These needs to be done per-frame as the buffers may change anytime.
    auto bind = [&](const ChannelDesc& desc)
    {
        if (!desc.texname.empty())
        {
            var[desc.texname] = renderData.getTexture(desc.name);
        }
    };
    for (auto& channel : kOutputGeometryInfoChannels)
        bind(channel);
    var["gOutputColor"] = renderData.getTexture(kOutputColor);
    var["gThpOut"] = mpTransparencyThp;
    var["gRayReflectionMask"] = mpReflectionsMask;
    var["gRayReflectionVBuffer"] = mpReflectionsHit;

     // Execute
    mpScene->raytrace(pRenderContext, mEvalTransparencyDirectRay.pProgram.get(), mEvalTransparencyDirectRay.pVars, uint3(targetDim, 1));
}

void TransparencyRenderer::evalRayReflections(RenderContext* pRenderContext, const RenderData& renderData) {
    FALCOR_PROFILE(pRenderContext, "RayReflections");

    // Create Pipeline
    if (!mReflectionsPass.pProgram)
    {
        // Shader setup
        RtProgram::Desc desc;
        desc.addShaderModules(mpScene->getShaderModules());
        desc.addShaderLibrary(kShaderReflections);
        desc.setMaxAttributeSize(mpScene->getRaytracingMaxAttributeSize());
        desc.setMaxPayloadSize(36u);
        desc.setMaxTraceRecursionDepth(1u);

        mReflectionsPass.pBindingTable = RtBindingTable::create(1, 1, mpScene->getGeometryCount());
        auto& sbt = mReflectionsPass.pBindingTable;
        sbt->setRayGen(desc.addRayGen("rayGen"));
        sbt->setMiss(0, desc.addMiss("miss"));

        // Only Triangle meshes are supported
        if (mpScene->hasGeometryType(Scene::GeometryType::TriangleMesh))
        {
            sbt->setHitGroup(0, mpScene->getGeometryIDs(Scene::GeometryType::TriangleMesh), desc.addHitGroup("closestHit", "anyHit"));
        }

        // Initial defines and program
        DefineList defines;
        defines.add(mpSampleGenerator->getDefines());
        defines.add(mpScene->getSceneDefines());

        mReflectionsPass.pProgram = RtProgram::create(mpDevice, desc, defines);
    }

    FALCOR_ASSERT(mReflectionsPass.pProgram);

    bool useLodMode = mEnableTransparencyPassLODMode && ((mRayLodMode == TexLODMode::RayCones) || (mRayLodMode == TexLODMode::RayDiffs));
    // Update define that can change at runtime
    mReflectionsPass.pProgram->addDefines(getLightEvalDefines());

    // Init Vars
    if (!mReflectionsPass.pVars)
    {
        mReflectionsPass.pProgram->setTypeConformances(mpScene->getTypeConformances());
        mReflectionsPass.pVars = RtProgramVars::create(mpDevice, mReflectionsPass.pProgram, mReflectionsPass.pBindingTable);
        auto var = mReflectionsPass.pVars->getRootVar();
        mpSampleGenerator->setShaderData(var);
        var[kParticleMaterialBufferName] = mpParticleMaterials;
    }

    FALCOR_ASSERT(mReflectionsPass.pVars);

    // Bind shader data
    const uint2 targetDim = renderData.getDefaultTextureDims();
    FALCOR_ASSERT(targetDim.x > 0 && targetDim.y > 0);

    auto var = mReflectionsPass.pVars->getRootVar();

    if (mShadowRenderMethod != ShadowRenderMethod::RayTracing)
        mShadowMethods[mSelectedShadowMethod]->setShaderData(var);

    if (mEnableOpaqueShadowMaps)
        mpShadowMap->setShaderDataAndBindBlock(var, renderData.getDefaultTextureDims());

    // Set shadow mask and opaque shadow map
    if (mpShadowMask && (mShadowRenderMethod != ShadowRenderMethod::RayTracing))
    {
        if (mShadowRenderMethod == ShadowRenderMethod::AccelIrregularZ || mShadowRenderMethod == ShadowRenderMethod::LinkedListIrregularZ)
            mShadowMethods[mSelectedShadowMethod]->setShadowMask(
                var, mpShadowMask->getMask(), mpShadowMask->getMaskImportanceShadowMap(), mIrregularUseShadowMask
            );
        else // Non irregular modes
        {
            mShadowMethods[mSelectedShadowMethod]->setShadowMask(
                var, mpShadowMask->getMask(), mpShadowMask->getMaskShadowMap(), mIrregularUseShadowMask
            );
        }
    }

    var["CB"]["gFrameCount"] = mFrameCount;


    var["gVBuffer"] = mpReflectionsHit;
    var["gOutputColor"] = renderData.getTexture(kOutputColor);
    var["gThp"] = mpTransparencyThp;
    var["gReflectionMask"] = mpReflectionsMask;

    // Execute
    mpScene->raytrace(pRenderContext, mReflectionsPass.pProgram.get(), mReflectionsPass.pVars, uint3(targetDim, 1));
}

void TransparencyRenderer::evalPathTracer(RenderContext* pRenderContext, const RenderData& renderData) {
    FALCOR_PROFILE(pRenderContext, "TransparencyPathTracer");

    //Create Pipeline
    if (!mTransparencyPathTracer.pProgram)
    {
        // Shader setup
        RtProgram::Desc desc;
        desc.addShaderModules(mpScene->getShaderModules());
        desc.addShaderLibrary(kShaderPathTracer);
        desc.setMaxAttributeSize(mpScene->getRaytracingMaxAttributeSize());
        desc.setMaxPayloadSize(36u);
        desc.setMaxTraceRecursionDepth(1u);

        mTransparencyPathTracer.pBindingTable = RtBindingTable::create(1, 1, mpScene->getGeometryCount());
        auto& sbt = mTransparencyPathTracer.pBindingTable;
        sbt->setRayGen(desc.addRayGen("rayGen"));
        sbt->setMiss(0, desc.addMiss("miss"));

        // Only Triangle meshes are supported
        if (mpScene->hasGeometryType(Scene::GeometryType::TriangleMesh))
        {
            sbt->setHitGroup(0, mpScene->getGeometryIDs(Scene::GeometryType::TriangleMesh), desc.addHitGroup("closestHit", "anyHit"));
        }

        // Initial defines and program
        DefineList defines;
        defines.add(mpSampleGenerator->getDefines());
        defines.add(mpScene->getSceneDefines());

        mTransparencyPathTracer.pProgram = RtProgram::create(mpDevice, desc, defines);
    }
    FALCOR_ASSERT(mTransparencyPathTracer.pProgram);

    mTransparencyPathTracer.pProgram->addDefines(getLightEvalDefines());
    mTransparencyPathTracer.pProgram->addDefine("MAX_BOUNCES", std::to_string(mPTMaxBounces));
    mTransparencyPathTracer.pProgram->addDefine("USE_RUSSIAN_ROULETTE", mPTUseRussianRoulette ? "1" : "0");

    //TODO add support for LOD modes

    // Init Vars
    if (!mTransparencyPathTracer.pVars)
    {
        mTransparencyPathTracer.pProgram->setTypeConformances(mpScene->getTypeConformances());
        mTransparencyPathTracer.pVars =
            RtProgramVars::create(mpDevice, mTransparencyPathTracer.pProgram, mTransparencyPathTracer.pBindingTable);
        auto var = mTransparencyPathTracer.pVars->getRootVar();
        mpSampleGenerator->setShaderData(var);
        var[kParticleMaterialBufferName] = mpParticleMaterials;
    }

    FALCOR_ASSERT(mTransparencyPathTracer.pVars);

    // Bind shader data
    const uint2 targetDim = renderData.getDefaultTextureDims();
    FALCOR_ASSERT(targetDim.x > 0 && targetDim.y > 0);

    auto var = mTransparencyPathTracer.pVars->getRootVar();

    if (mShadowRenderMethod != ShadowRenderMethod::RayTracing)
        mShadowMethods[mSelectedShadowMethod]->setShaderData(var);

    if (mEnableOpaqueShadowMaps)
        mpShadowMap->setShaderDataAndBindBlock(var, renderData.getDefaultTextureDims());

    // Set shadow mask and opaque shadow map
    if (mpShadowMask && (mShadowRenderMethod != ShadowRenderMethod::RayTracing))
    {
        if (mShadowRenderMethod == ShadowRenderMethod::AccelIrregularZ || mShadowRenderMethod == ShadowRenderMethod::LinkedListIrregularZ)
            mShadowMethods[mSelectedShadowMethod]->setShadowMask(
                var, mpShadowMask->getMask(), mpShadowMask->getMaskImportanceShadowMap(), mIrregularUseShadowMask
            );
        else // Non irregular modes
        {
            mShadowMethods[mSelectedShadowMethod]->setShadowMask(
                var, mpShadowMask->getMask(), mpShadowMask->getMaskShadowMap(), mIrregularUseShadowMask
            );
        }
    }

    var["CB"]["gFrameCount"] = mFrameCount;

    // Bind I/O buffers. These needs to be done per-frame as the buffers may change anytime.
    auto bind = [&](const ChannelDesc& desc)
    {
        if (!desc.texname.empty())
        {
            var[desc.texname] = renderData.getTexture(desc.name);
        }
    };

    var["gOutputColor"] = renderData.getTexture(kOutputColor);

    // Execute
    mpScene->raytrace(pRenderContext, mTransparencyPathTracer.pProgram.get(), mTransparencyPathTracer.pVars, uint3(targetDim, 1));
}

static ref<CPUSampleGenerator> createSamplePattern(TransparencyRenderer::CamJitterSamplePattern type, uint32_t sampleCount)
{
    switch (type)
    {
    case TransparencyRenderer::CamJitterSamplePattern::Center:
        return nullptr;
    case TransparencyRenderer::CamJitterSamplePattern::DirectX:
        return DxSamplePattern::create(sampleCount);
    case TransparencyRenderer::CamJitterSamplePattern::Halton:
        return HaltonSamplePattern::create(sampleCount);
    case TransparencyRenderer::CamJitterSamplePattern::Stratified:
        return StratifiedSamplePattern::create(sampleCount);
    default:
        FALCOR_UNREACHABLE();
        return nullptr;
    }
}

void TransparencyRenderer::updateFrameDim(const uint2 frameDim)
{
    FALCOR_ASSERT(frameDim.x > 0 && frameDim.y > 0);
    mRenderDims = frameDim;
    float2 invFrameDim = 1.f / float2(frameDim);

    // Update sample generator for camera jitter.
    if (mpScene)
        mpScene->getCamera()->setPatternGenerator(mpCameraJitterGenerator, invFrameDim);
}

void TransparencyRenderer::updateSamplePattern()
{
    mpCameraJitterGenerator = createSamplePattern(mCameraJitterSamplePattern, mCameraJitterNumSamples);
    if (mpCameraJitterGenerator)
        mCameraJitterNumSamples = mpCameraJitterGenerator->getSampleCount();
}
