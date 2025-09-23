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
#include "ReSTIR_DI.h"
#include "Utils/Math/FalcorMath.h"
#include "RenderGraph/RenderPassHelpers.h"
#include "RenderGraph/RenderPassStandardFlags.h"

#include "Rendering/Lights/EmissiveUniformSampler.h"
#include "Rendering/Lights/EmissivePowerSampler.h"

namespace
{
    // Shader
    const std::string kShaderFolder = "RenderPasses/ReSTIR_DI/";
    const std::string kShaderInitialSamples = kShaderFolder + "InitialSamples.cs.slang";
    const std::string kShaderResample = kShaderFolder + "Resample.cs.slang";
    const std::string kShaderFinalizeSample = kShaderFolder + "FinalizeSamples.cs.slang";

    // Input Textures
    const std::string kInputVBuffer = "VBuffer";
    const std::string kInputView = "View";

    const Falcor::ChannelList kInputChannels{
        {kInputVBuffer, "gVBuffer", "Visibility buffer in packed format"},
        {kInputView, "gView", "View Vector"},
    };

    // Output textures
    const std::string kOutputColor = "ColorOut";
    const Falcor::ChannelList kOutputChannels{
        {kOutputColor, "gOutColor", "HDR output color", false /*optional*/, ResourceFormat::RGBA32Float}
    };
}


extern "C" FALCOR_API_EXPORT void registerPlugin(Falcor::PluginRegistry& registry)
{
    registry.registerClass<RenderPass, ReSTIR_DI>();
}

ReSTIR_DI::ReSTIR_DI(ref<Device> pDevice, const Properties& props)
    : RenderPass(pDevice)
{
    // Create sample generator.
    mpSampleGenerator = SampleGenerator::create(mpDevice, SAMPLE_GENERATOR_UNIFORM);
    FALCOR_ASSERT(mpSampleGenerator);

     mLightBVHOptions = {};
}

Properties ReSTIR_DI::getProperties() const
{
    return {};
}

RenderPassReflection ReSTIR_DI::reflect(const CompileData& compileData)
{
    // Render Pass In and Output textures
    RenderPassReflection reflector;
    addRenderPassInputs(reflector, kInputChannels);
    addRenderPassOutputs(reflector, kOutputChannels);
    return reflector;
}

void ReSTIR_DI::setScene(RenderContext* pRenderContext, const ref<Scene>& pScene)
{
    // Reset scene
    mpScene.reset();
    resetRenderPasses();
    mpEmissiveLightSampler.reset();

    if (pScene)
    {
        mpScene = pScene;
    }
}

void ReSTIR_DI::execute(RenderContext* pRenderContext, const RenderData& renderData)
{
    if (!mpScene)
        return;

    prepareLightingStructure(pRenderContext);

    if (!mpEmissiveLightSampler)
        return;

    prepareResources(pRenderContext, renderData);

    generateInitialSamplesPass(pRenderContext, renderData);

    resamplePass(pRenderContext, renderData);

    finalizeSamplePass(pRenderContext, renderData);

    mFrameCount++;
}

void ReSTIR_DI::renderUI(Gui::Widgets& widget)
{

    widget.var("Emissive Samples", mNumEmissiveSamples, 0u, 256u, 1u);
    widget.var("BSDF Samples", mNumBSDFSamples, 0u, 256u, 1u);

    mRebuildLightSampler |= widget.dropdown("NEE Sampler", mEmissiveLightSamplerType);
    if (mEmissiveLightSamplerType == EmissiveLightSamplerType::LightBVH)
    {
        if (auto group = widget.group("NEE Sampler Options"))
        {
            mpEmissiveLightSampler->renderUI(group);
        }
    }
}

void ReSTIR_DI::prepareLightingStructure(RenderContext* pRenderContext)
{
    // Make sure that the emissive light is up to date
    auto& pLights = mpScene->getLightCollection(pRenderContext);

    bool emissiveUsed = mpScene->useEmissiveLights();
    bool analyticUsed = mpScene->useAnalyticLights();

    if (emissiveUsed)
    {
        if (!mpEmissiveLightSampler || mRebuildLightSampler)
        {
            resetRenderPasses();
            FALCOR_ASSERT(pLights && pLights->getActiveLightCount(pRenderContext) > 0);
            switch (mEmissiveLightSamplerType)
            {
            case Falcor::EmissiveLightSamplerType::Uniform:
                mpEmissiveLightSampler = std::make_unique<EmissiveUniformSampler>(pRenderContext, mpScene);
                break;
            case Falcor::EmissiveLightSamplerType::LightBVH:
                mpEmissiveLightSampler = std::make_unique<LightBVHSampler>(pRenderContext, mpScene, mLightBVHOptions);
                break;
            case Falcor::EmissiveLightSamplerType::Power:
                mpEmissiveLightSampler = std::make_unique<EmissivePowerSampler>(pRenderContext, mpScene);
                break;
            case Falcor::EmissiveLightSamplerType::Null:
            default:
                FALCOR_UNREACHABLE();
                break;
            }

            mRebuildLightSampler = false;
        }
    }
    else
    {
        if (mpEmissiveLightSampler)
        {
            if (auto lightBVHSampler = dynamic_cast<LightBVHSampler*>(mpEmissiveLightSampler.get()))
            {
                mLightBVHOptions = lightBVHSampler->getOptions();
            }
            mpEmissiveLightSampler = nullptr;
            resetRenderPasses();
        }
    }

    if (mpEmissiveLightSampler)
        mpEmissiveLightSampler->update(pRenderContext);
}

void ReSTIR_DI::prepareResources(RenderContext* pRenderContext, const RenderData& renderData)
{
    //Reset screen dims
    if (any(mScreenRes != renderData.getDefaultTextureDims()))
    {
        mScreenRes = renderData.getDefaultTextureDims();
        mpReservoir[0].reset();
        mpReservoir[1].reset();
    }

    for (uint i = 0; i < 2; i++)
    {
        if (!mpReservoir[i])
        {
            mpReservoir[i] = Buffer::createStructured(
                mpDevice, sizeof(uint) * 12, mScreenRes.x * mScreenRes.y,
                ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess, Buffer::CpuAccess::None, nullptr, false
            );
            mpReservoir[i]->setName("Reservoir" + std::to_string(i));
        }
    }
}

void ReSTIR_DI::generateInitialSamplesPass(RenderContext* pRenderContext, const RenderData& renderData)
{
    FALCOR_PROFILE(pRenderContext, "InitialSamples");

     // Create compute pass
    if (!mpInitialSamplesPass)
    {
        Program::Desc desc;
        desc.addShaderModules(mpScene->getShaderModules());
        desc.addShaderLibrary(kShaderInitialSamples).csEntry("main").setShaderModel("6_6");
        desc.addTypeConformances(mpScene->getTypeConformances());

        DefineList defines;
        defines.add(mpScene->getSceneDefines());
        defines.add(mpSampleGenerator->getDefines());
        defines.add("USE_ENV_BACKROUND", mpScene->useEnvBackground() ? "1" : "0");
        defines.add(mpEmissiveLightSampler->getDefines());

        mpInitialSamplesPass = ComputePass::create(mpDevice, desc, defines, true);
    }
    FALCOR_ASSERT(mpInitialSamplesPass);

    mpInitialSamplesPass->getProgram()->addDefine("USE_ENV_BACKROUND", mpScene->useEnvBackground() ? "1" : "0");

      // Set variables
    auto var = mpInitialSamplesPass->getRootVar();
    mpScene->setRaytracingShaderData(pRenderContext, var); // Set scene data
    mpSampleGenerator->setShaderData(var);                 // Sample generator
    mpEmissiveLightSampler->setShaderData(var["Light"]["gEmissiveSampler"]);

    // Constant Buffer
    var["CB"]["gFrameCount"] = mFrameCount;
    var["CB"]["gFrameDims"] = mScreenRes;
    var["CB"]["gNumEmissiveSamples"] = mNumEmissiveSamples;
    var["CB"]["gNumBSDFSamples"] = mNumBSDFSamples;

    // Input
    var["gVBuffer"] = renderData[kInputVBuffer]->asTexture();
    var["gView"] = renderData[kInputView]->asTexture();

    //Output
    var["gReservoir"] = mpReservoir[mFrameCount % 2];

    // Execute
    const uint2 targetDim = mScreenRes;
    FALCOR_ASSERT(targetDim.x > 0 && targetDim.y > 0);
    mpInitialSamplesPass->execute(pRenderContext, uint3(targetDim, 1));
}

void ReSTIR_DI::resamplePass(RenderContext* pRenderContext, const RenderData& renderData)
{
    
}

void ReSTIR_DI::finalizeSamplePass(RenderContext* pRenderContext, const RenderData& renderData)
{
    FALCOR_PROFILE(pRenderContext, "FinalShading");

    // Create compute pass
    if (!mpEvaluateReservoirsPass)
    {
        Program::Desc desc;
        desc.addShaderModules(mpScene->getShaderModules());
        desc.addShaderLibrary(kShaderFinalizeSample).csEntry("main").setShaderModel("6_6");
        desc.addTypeConformances(mpScene->getTypeConformances());

        DefineList defines;
        defines.add(mpScene->getSceneDefines());
        defines.add(mpSampleGenerator->getDefines());
        defines.add("USE_ENV_BACKROUND", mpScene->useEnvBackground() ? "1" : "0");
        defines.add(mpEmissiveLightSampler->getDefines());

        mpEvaluateReservoirsPass = ComputePass::create(mpDevice, desc, defines, true);
    }
    FALCOR_ASSERT(mpEvaluateReservoirsPass);

    mpEvaluateReservoirsPass->getProgram()->addDefine("USE_ENV_BACKROUND", mpScene->useEnvBackground() ? "1" : "0");

    // Set variables
    auto var = mpEvaluateReservoirsPass->getRootVar();
    mpScene->setRaytracingShaderData(pRenderContext, var); // Set scene data
    mpSampleGenerator->setShaderData(var);                 // Sample generator
    mpEmissiveLightSampler->setShaderData(var["Light"]["gEmissiveSampler"]);

    // Constant Buffer
    var["CB"]["gFrameCount"] = mFrameCount;
    var["CB"]["gFrameDims"] = mScreenRes;

    // Input
    var["gVBuffer"] = renderData[kInputVBuffer]->asTexture();
    var["gView"] = renderData[kInputView]->asTexture();
    var["gReservoir"] = mpReservoir[mFrameCount % 2];

    // Output
    var["gColorOut"] = renderData[kOutputColor]->asTexture();

    // Execute
    const uint2 targetDim = mScreenRes;
    FALCOR_ASSERT(targetDim.x > 0 && targetDim.y > 0);
    mpEvaluateReservoirsPass->execute(pRenderContext, uint3(targetDim, 1));
}


void ReSTIR_DI::resetRenderPasses()
{
    mpInitialSamplesPass.reset();
    mpResamplePass.reset();
    mpEvaluateReservoirsPass.reset();
}
