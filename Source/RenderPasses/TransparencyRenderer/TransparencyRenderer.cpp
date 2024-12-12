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

    const std::string kShaderModel = "6_6"; //Shader model for compute shader

    const std::string kInputVBuffer = "vbuffer";
    const std::string kInputDepth = "inDepth";
    const std::string kInputMV = "inMotion";
    const std::string kOutputColor = "outColor";
    const std::string kOutputDebug = "outDebug";
    const std::string kOutputDepth = "outDepth";
    const std::string kOutputMV = "outMotion";

    const ChannelList kInputChannels = {
        {kInputVBuffer, "gVBuffer", "Visibility buffer in packed format"},
        {"viewW", "gViewW", "World-space view direction (xyz float format)", true /* optional */},
    };

    const ChannelList kOutputChannels = {
        {kOutputColor, "gOutputColor", "Output color (sum of direct and indirect)", false, ResourceFormat::RGBA32Float},
        {kOutputDebug, "gDebugOut", "Output debug tex (sum of direct and indirect)", true, ResourceFormat::RGBA32Float},
    };

    //Additional Geometry information that may need info about the first transparent hit
    const ChannelList kInputGeometryInfoChannels = {
        {kInputDepth, "gInDepth", "Depth buffer (NDC)", true /* optional */},
        {kInputMV, "gInMotion", "Motion vector", true /* optional */},
    };

    const ChannelList kOutputGeometryInfoChannels = {
        {kOutputDepth, "gOutDepth", "Depth buffer (NDC) with transparencies", true, ResourceFormat::R32Float},
        {kOutputMV, "gOutMotion", "Motion Vector including transparencies", true, ResourceFormat::RG32Float},
    };

}; // namespace

TransparencyRenderer::TransparencyRenderer(ref<Device> pDevice, const Properties& props) : RenderPass(pDevice)
{
    mpSampleGenerator = SampleGenerator::create(mpDevice, SAMPLE_GENERATOR_UNIFORM);
    FALCOR_ASSERT(mpSampleGenerator);
}

Properties TransparencyRenderer::getProperties() const
{
    return {};
}

RenderPassReflection TransparencyRenderer::reflect(const CompileData& compileData)
{
    RenderPassReflection reflector;

    // Define our input/output channels.
    addRenderPassInputs(reflector, kInputChannels);
    addRenderPassInputs(reflector, kInputGeometryInfoChannels);
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
    if (!mpScene)
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

    if (mOpaqueShadowMapModeChanged)
    {
        mpEvalDirectPass.reset();
        mEvalTransparencyDirectRay.resetPip();
        mOpaqueShadowMapModeChanged = false;
    }

    bool sceneHasAnalyticLights = !mpScene->getLights().empty();

    // Request the light collection if emissive lights are enabled.
    if (mpScene->getRenderSettings().useEmissiveLights)
    {
        mpScene->getLightCollection(pRenderContext);
    }

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
        

    //Generate Shadow Structure
    if (mShadowRenderMethod != ShadowRenderMethod::RayTracing)
        mShadowMethods[mSelectedShadowMethod]->generate(pRenderContext, renderData);

    evalDirectTransparency(pRenderContext, renderData);

    evalDirect(pRenderContext, renderData);

    // Generate Shadow Structure
    if (mShadowRenderMethod != ShadowRenderMethod::RayTracing)
        mShadowMethods[mSelectedShadowMethod]->debugPass(pRenderContext, renderData, renderData.getTexture(kOutputDebug), renderData.getTexture(kOutputColor));

    mFrameCount++;
}

void TransparencyRenderer::renderUI(Gui::Widgets& widget)
{
    bool dirty = false;
    dirty |= widget.dropdown("Light Sample Mode", mLightSampleMode);
    bool methodChanged = widget.dropdown("Shadow Method", mShadowRenderMethod);
    if (methodChanged)
        mSelectedShadowMethod = mShadowRenderMethod == ShadowRenderMethod::RayTracing ? 0 : (uint)mShadowRenderMethod - 1u;
    dirty |= methodChanged;

    mOpaqueShadowMapModeChanged |= widget.checkbox("Enable Opaque Shadow Maps", mEnableOpaqueShadowMaps);
    widget.tooltip("Enables a extra opaque shadow map pass. Shadow Method should only evaluate non-opaque geometry in that case");

    widget.checkbox("Enable Fallback Shadows", mEnableFallbackRayTracedShadows);
    widget.tooltip("Some techniques allow for ray traced shadows as a fallback. They can be toggled on/off manually here");

    if (mEnableOpaqueShadowMaps && mpShadowMap)
    {
        if (auto group = widget.group("Opaque Shadow Map Settings"))
            mpShadowMap->renderUI(group);
    }

    if (mShadowRenderMethod != ShadowRenderMethod::RayTracing && !mShadowMethods.empty() && mShadowMethods[mSelectedShadowMethod])
    {
        mShadowMethods[mSelectedShadowMethod]->renderUI(widget);
    }
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

    if (mpScene)
    {
        mpScene->setRtASAdditionalGeometryFlag(RtGeometryFlags::NoDuplicateAnyHitInvocation); // Add the NoDublicateAnyHitInvocation flag to

        //Add the shadow methods
        mShadowMethods.push_back(std::make_shared<AccelShadow>(mpDevice, mpScene)); //Accel Shadow (0)
        mShadowMethods.push_back(std::make_shared<LinkedListShadow>(mpDevice, mpScene)); // LinkedList (1)
        mShadowMethods.push_back(std::make_shared<AccelShadowKBuffer>(mpDevice,mpScene)); //AccelShadow KBuffer (2)
        mShadowMethods.push_back(std::make_shared<AccelIrregularZ>(mpDevice, mpScene)); // Accel IrregularZ (3)
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
    defines.add("TR_RAY_QUERY_FLAG", std::to_string((uint)evalQueryRayFlags));
    defines.add("ENABLE_FALLBACK_RAY_SHADOWS", mEnableFallbackRayTracedShadows ? "1" : "0");

    return defines;
}

void TransparencyRenderer::evalDirect(RenderContext* pRenderContext, const RenderData& renderData)
{
    FALCOR_PROFILE(pRenderContext, "Shade Direct hit");

    if (!mpEvalDirectPass)
    {
        Program::Desc desc;
        desc.addShaderModules(mpScene->getShaderModules());
        desc.addShaderLibrary(kShaderEvalDirect).csEntry("main").setShaderModel(kShaderModel);
        desc.addTypeConformances(mpScene->getTypeConformances());

        DefineList defines;
        defines.add(mpScene->getSceneDefines());
        defines.add(mpSampleGenerator->getDefines());
        defines.add(getLightEvalDefines());
        

        mpEvalDirectPass = ComputePass::create(mpDevice, desc, defines, true);
    }

    FALCOR_ASSERT(mpEvalDirectPass);

    // If defines change, refresh the program
    mpEvalDirectPass->getProgram()->addDefines(getLightEvalDefines());

    // Set variables
    auto var = mpEvalDirectPass->getRootVar();

    mpScene->setRaytracingShaderData(pRenderContext, var, 1); // Set scene data
    mpSampleGenerator->setShaderData(var);                    // Sample generator
    if (mShadowRenderMethod != ShadowRenderMethod::RayTracing)
        mShadowMethods[mSelectedShadowMethod]->setShaderData(var);

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
    for (auto channel : kInputChannels)
        bind(channel);
    var["gOutputColor"] = renderData.getTexture(kOutputColor);
    var["gTransparencyThp"] = mpTransparencyThp;

    // Execute
    const uint2 targetDim = renderData.getDefaultTextureDims();
    FALCOR_ASSERT(targetDim.x > 0 && targetDim.y > 0);
    mpEvalDirectPass->execute(pRenderContext, uint3(targetDim, 1));
}

void TransparencyRenderer::evalDirectTransparency(RenderContext* pRenderContext, const RenderData& renderData) {
    FALCOR_PROFILE(pRenderContext, "Transparency on Primary Ray");

    const auto& screenSize = renderData.getDefaultTextureDims();
    //Textures
    if (!mpTransparencyThp || mpTransparencyThp->getWidth() != screenSize.x || mpTransparencyThp->getHeight() != screenSize.y)
    {
        mpTransparencyThp = Texture::create2D(
            mpDevice, screenSize.x, screenSize.y, ResourceFormat::RGBA32Float, 1u, 1u, nullptr,
            ResourceBindFlags::UnorderedAccess | ResourceBindFlags::ShaderResource
        );
        mpTransparencyThp->setName("TransparencyThp");
    }

    // Create scene ray tracing program.
    if (!mEvalTransparencyDirectRay.pProgram)
    {
        //Shader setup
        RtProgram::Desc desc;
        desc.addShaderModules(mpScene->getShaderModules());
        desc.addShaderLibrary(kShaderEvalTransparenciesDirect);
        desc.setMaxAttributeSize(mpScene->getRaytracingMaxAttributeSize());
        desc.setMaxPayloadSize(32u);
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

    // Update define that can change at runtime
    mEvalTransparencyDirectRay.pProgram->addDefines(getLightEvalDefines());
    mEvalTransparencyDirectRay.pProgram->addDefines(getValidResourceDefines(kInputChannels, renderData));
    mEvalTransparencyDirectRay.pProgram->addDefines(getValidResourceDefines(kInputGeometryInfoChannels, renderData));
    mEvalTransparencyDirectRay.pProgram->addDefines(getValidResourceDefines(kOutputGeometryInfoChannels, renderData)); //For updating depth and motion
    
    // Init Vars
    if (!mEvalTransparencyDirectRay.pVars)
    {
        mEvalTransparencyDirectRay.pProgram->setTypeConformances(mpScene->getTypeConformances());
        mEvalTransparencyDirectRay.pVars = RtProgramVars::create(mpDevice, mEvalTransparencyDirectRay.pProgram, mEvalTransparencyDirectRay.pBindingTable);
        auto var = mEvalTransparencyDirectRay.pVars->getRootVar();
        mpSampleGenerator->setShaderData(var);
    }

    FALCOR_ASSERT(mEvalTransparencyDirectRay.pVars);

    //Bind shader data
    auto var = mEvalTransparencyDirectRay.pVars->getRootVar();
    
    if (mShadowRenderMethod != ShadowRenderMethod::RayTracing)
        mShadowMethods[mSelectedShadowMethod]->setShaderData(var);

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
    for (auto& channel : kInputChannels)
        bind(channel);
    for (auto& channel : kInputGeometryInfoChannels)
        bind(channel);
    for (auto& channel : kOutputGeometryInfoChannels)
        bind(channel);
    var["gOutputColor"] = renderData.getTexture(kOutputColor);
    var["gThpOut"] = mpTransparencyThp;

     // Execute
    const uint2 targetDim = renderData.getDefaultTextureDims();
    FALCOR_ASSERT(targetDim.x > 0 && targetDim.y > 0);
    mpScene->raytrace(pRenderContext, mEvalTransparencyDirectRay.pProgram.get(), mEvalTransparencyDirectRay.pVars, uint3(targetDim, 1));
}
