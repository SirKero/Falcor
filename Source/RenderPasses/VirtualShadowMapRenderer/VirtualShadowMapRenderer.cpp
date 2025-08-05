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
#include "VirtualShadowMapRenderer.h"
#include "RenderGraph/RenderPassHelpers.h"
#include "RenderGraph/RenderPassStandardFlags.h"

namespace
{
    //Shaders
    const std::string kShaderShadeSurface = "RenderPasses/VirtualShadowMapRenderer/ShadeSurface.cs.slang";

    //In/out resources
    const std::string kInputVBufferName = "VBuffer";
    const std::string kInputViewName = "ViewW";
    const std::string kOutputColorName = "ColorOut";
    const std::string kOutputDebugName = "debug";

    const ChannelList kInputChannels = {
        {kInputVBufferName, "gVBuffer", "Vertex Buffer"},
        {kInputViewName, "gView", "Camera View"},
    };

    const ChannelList kOutputChannels = {
        {kOutputColorName, "gColor", "(Shadowed) Color for the direct light", false, ResourceFormat::RGBA32Float},
        {kOutputDebugName, "gDebut", "debug", false, ResourceFormat::RGBA32Float},
    };
}

extern "C" FALCOR_API_EXPORT void registerPlugin(Falcor::PluginRegistry& registry)
{
    registry.registerClass<RenderPass, VirtualShadowMapRenderer>();
}

VirtualShadowMapRenderer::VirtualShadowMapRenderer(ref<Device> pDevice, const Properties& props)
    : RenderPass(pDevice)
{
    mpSampleGenerator = SampleGenerator::create(mpDevice, SAMPLE_GENERATOR_UNIFORM);
}

Properties VirtualShadowMapRenderer::getProperties() const
{
    return {};
}

RenderPassReflection VirtualShadowMapRenderer::reflect(const CompileData& compileData)
{
    // Define the required resources here
    RenderPassReflection reflector;
    // Define our input/output channels.
    addRenderPassInputs(reflector, kInputChannels);
    addRenderPassOutputs(reflector, kOutputChannels, ResourceBindFlags::UnorderedAccess);
    return reflector;
}

void VirtualShadowMapRenderer::execute(RenderContext* pRenderContext, const RenderData& renderData)
{
    //Return if scene is empty
    if (!mpScene || !mpVirtualShadowMap)
    {
        auto pColorOut = renderData[kOutputColorName]->asTexture();
        if (pColorOut)
            pRenderContext->clearTexture(pColorOut.get(), float4(0, 0, 0, 1));
        return;
    }

    //Generate virtual shadow map for the frame
    mpVirtualShadowMap->generate(pRenderContext, renderData);

    if (mpVirtualShadowMap->debugIsEnabled())
    {
        auto pDebugOut = renderData[kOutputDebugName]->asTexture();
        mpVirtualShadowMap->debugPass(pRenderContext, renderData, pDebugOut);
    }

    //Shade Surface
    shadeSurfacePass(pRenderContext, renderData);

    mFrameCount++;
}

void VirtualShadowMapRenderer::renderUI(Gui::Widgets& widget)
{
    widget.var("Ambient Factor", mAmbientFactor, 0.f, FLT_MAX, 0.01f);
    widget.var("Enviroment Map Factor", mEnvMapFactor, 0.f, FLT_MAX, 0.01f);
    widget.var("Emissive Factor", mEmissiveFactor, 0.f, FLT_MAX, 0.01f);

    widget.checkbox("Use Virtual Shadow Map", mUseVirtualShadowMap);
    widget.tooltip("Enables Virtual Shadow Map, else a ray is used");

    if (mUseVirtualShadowMap && mpVirtualShadowMap)
    {
        mpVirtualShadowMap->renderUI(widget);
    }

    if (mpVirtualShadowMap->resetIsRequired())
    {
        mpShadeSurfacePass.reset();
    }
}


void VirtualShadowMapRenderer::setScene(RenderContext* pRenderContext, const ref<Scene>& pScene) {
    //Reset passes
    mpShadeSurfacePass.reset();
    mpVirtualShadowMap.reset();
    mDirectionalLightIndex = -1;

    mpScene = pScene;
    if (mpScene)
    {
        mpVirtualShadowMap = std::make_unique<VirtualShadowMap>(mpDevice, mpScene, kInputVBufferName);
        auto lights = mpScene->getLights();
        for (uint i = 0; i < lights.size(); i++)
        {
            if (lights[i]->getType() == LightType::Directional)
            {
                mDirectionalLightIndex = i;
                break;
            }
        }
    }
}

void VirtualShadowMapRenderer::shadeSurfacePass(RenderContext* pRenderContext, const RenderData& renderData) {
    FALCOR_PROFILE(pRenderContext, "Shader Surface");

    if (!mpShadeSurfacePass )
    {
        Program::Desc desc;
        desc.addShaderModules(mpScene->getShaderModules());
        desc.addShaderLibrary(kShaderShadeSurface).csEntry("main").setShaderModel("6_5");
        desc.addTypeConformances(mpScene->getTypeConformances());

        DefineList defines;
        defines.add(mpScene->getSceneDefines());
        defines.add(mpSampleGenerator->getDefines());
        defines.add("USE_ENV_BACKROUND", mpScene->useEnvBackground() ? "1" : "0");
        defines.add(mpVirtualShadowMap->getDefines());

        mpShadeSurfacePass = ComputePass::create(mpDevice, desc, defines, true);
    }
    FALCOR_ASSERT(mpShadeSurfacePass);

    //Update Defines
    mpShadeSurfacePass->getProgram()->addDefine("USE_ENV_BACKROUND", mpScene->useEnvBackground() ? "1" : "0");
    mpShadeSurfacePass->getProgram()->addDefines(mpScene->getSceneDefines());
    mpShadeSurfacePass->getProgram()->addDefines(mpVirtualShadowMap->getDefines());

    auto var = mpShadeSurfacePass->getRootVar();
    mpScene->setRaytracingShaderData(pRenderContext, var); // Set scene data
    mpSampleGenerator->setShaderData(var);                 // Sample generator
    mpVirtualShadowMap->setShaderData(var);

    //Constant Buffer
    var["CB"]["gFrameCount"] = mFrameCount;
    var["CB"]["gFrameDim"] = renderData.getDefaultTextureDims();
    var["CB"]["gAmbient"] = mAmbientFactor;
    var["CB"]["gEnvMapFac"] = mEnvMapFactor;
    var["CB"]["gEmissiveFac"] = mEmissiveFactor;
    var["CB"]["gDirectionalLightIdx"] = mUseVirtualShadowMap ? mDirectionalLightIndex : -1;

    var["gVBuffer"] = renderData[kInputVBufferName]->asTexture();
    var["gView"] = renderData[kInputViewName]->asTexture();

    var["gColorOut"] = renderData[kOutputColorName]->asTexture();

    // Execute
    const uint2 targetDim = renderData.getDefaultTextureDims();
    FALCOR_ASSERT(targetDim.x > 0 && targetDim.y > 0);
    mpShadeSurfacePass->execute(pRenderContext, uint3(targetDim, 1));
}
