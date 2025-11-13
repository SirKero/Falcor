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
#include "ReSTIR_PT_Test.h"
#include "RenderGraph/RenderPassHelpers.h"
#include "RenderGraph/RenderPassStandardFlags.h"

#include "Rendering/Lights/EmissiveUniformSampler.h"
#include "Rendering/Lights/EmissivePowerSampler.h"
namespace
{
    const std::string kShaderFolder = "RenderPasses/ReSTIR_PT_Test/";
    const std::string kShaderTracePath = kShaderFolder + "TracePath.rt.slang";
    const std::string kShaderEvalReseroir = kShaderFolder + "EvaluateReservoir.cs.slang";
    const std::string kShaderModel = "6_5";

    // Render Pass inputs and outputs
    const std::string kInputVBuffer = "vbuffer";
    const std::string kInputView = "view";
    const std::string kInputMotionVectors = "mvec";

    const Falcor::ChannelList kInputChannels{
        {kInputVBuffer, "gVBuffer", "Visibility buffer in packed format"},
        {kInputView, "gView", "View Vector"},
        {kInputMotionVectors, "gMotionVectors", "Motion vector buffer (float format)", false /* optional */},
    };

    // Outputs
    const std::string kOutputColor = "color";
    const std::string kOutputDebug = "debug";

    const Falcor::ChannelList kOutputChannels{
        {kOutputColor, "gOutColor", "HDR output color", false /*optional*/, ResourceFormat::RGBA32Float},
        {kOutputDebug, "gOutDebug", "Debug", false /*optional*/, ResourceFormat::RGBA32Float},
    };
}

extern "C" FALCOR_API_EXPORT void registerPlugin(Falcor::PluginRegistry& registry)
{
    registry.registerClass<RenderPass, ReSTIR_PT_Test>();
}

ReSTIR_PT_Test::ReSTIR_PT_Test(ref<Device> pDevice, const Properties& props)
    : RenderPass(pDevice)
{
    if (!mpDevice->isShaderModelSupported(Device::ShaderModel::SM6_5))
    {
        throw RuntimeError("ReSTIR_PT_Test: Shader Model 6.5 is not supported by the current device");
    }
    if (!mpDevice->isFeatureSupported(Device::SupportedFeatures::RaytracingTier1_1))
    {
        throw RuntimeError("ReSTIR_PT_Test: Raytracing Tier 1.1 is not supported by the current device");
    }

    // Create sample generator.
    mpSampleGenerator = SampleGenerator::create(mpDevice, SAMPLE_GENERATOR_UNIFORM);
}

Properties ReSTIR_PT_Test::getProperties() const
{
    return {};
}

RenderPassReflection ReSTIR_PT_Test::reflect(const CompileData& compileData)
{
    // In- and Output Textures
    RenderPassReflection reflector;
    addRenderPassInputs(reflector, kInputChannels);
    addRenderPassOutputs(reflector, kOutputChannels);
    return reflector;
}

void ReSTIR_PT_Test::setScene(RenderContext* pRenderContext, const ref<Scene>& pScene)
{
    // Reset Scene
    mpScene = pScene;

    //Reset RenderPasses
    resetRenderPasses();

    mpEmissiveLightSampler = nullptr;
    mpEnvMapSampler = nullptr;
}

void ReSTIR_PT_Test::renderUI(Gui::Widgets& widget)
{
    bool changed = false;
    if (auto group = widget.group("ReSTIR PT Options"))
    {
        changed |= group.var("Bounces", mPTBounces, 0u, 256u, 1u);
        mRebuildLightSampler |= group.dropdown("NEE Sampler", mEmissiveLightSamplerType);
        if (mEmissiveLightSamplerType == EmissiveLightSamplerType::LightBVH)
        {
            if (auto group2 = group.group("NEE Sampler Options"))
            {
                mpEmissiveLightSampler->renderUI(group2);
            }
        }
        changed |= group.var("Reuse Roughness Threshold", mRoughnessThreshold, 0.f, 1.f, 0.001f);
        
    }

    if (auto group = widget.group("RTXDI"))
    {
        if (mpRTXDI)
        {
            mpRTXDI->renderUI(group);
        }
        else
        {
            group.text("Load a scene for RTXDI options");
        }
    }

    mOptionsChanged = changed;
}

void ReSTIR_PT_Test::execute(RenderContext* pRenderContext, const RenderData& renderData)
{
    if (!mpScene)
        return;

    // Add refresh flag if options changed
    auto& dict = renderData.getDictionary();
    auto flags = dict.getValue(kRenderPassRefreshFlags, RenderPassRefreshFlags::None);
    if (mOptionsChanged)
    {
        dict[Falcor::kRenderPassRefreshFlags] = flags | Falcor::RenderPassRefreshFlags::RenderOptionsChanged;
        mOptionsChanged = false;
    }

    // Init ReSTIR DI
    const auto& pMotionVectors = renderData[kInputMotionVectors]->asTexture();
    if (!mpRTXDI)
        mpRTXDI = std::make_unique<RTXDI>(mpScene, mRTXDIOptions);

    prepareLightingStructure(pRenderContext);

    prepareResources(pRenderContext, renderData);
    auto& pLights = mpScene->getLightCollection(pRenderContext);

    mpRTXDI->beginFrame(pRenderContext, mScreenRes);

    tracePathPass(pRenderContext, renderData);

    // ReSTIR DI pass
    mpRTXDI->update(pRenderContext, pMotionVectors);

    evalReservoirPass(pRenderContext, renderData);

    mpRTXDI->endFrame(pRenderContext);

    mFrameCount++;
}

void ReSTIR_PT_Test::resetRenderPasses()
{
    mTracePathPass = RayTraceProgramHelper::create();
    mpEvalReservoirPass.reset();
}

void ReSTIR_PT_Test::prepareLightingStructure(RenderContext* pRenderContext)
{
    // Make sure that the emissive light is up to date
    auto& pLights = mpScene->getLightCollection(pRenderContext);

    bool emissiveUsed = mpScene->useEmissiveLights();

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

    //EnvMap sampler
    if (is_set(mpScene->getUpdates(), Scene::UpdateFlags::EnvMapChanged))
    {
        mpEnvMapSampler = nullptr;
    }

    if (mpScene->useEnvLight())
    {
        if (!mpEnvMapSampler)
        {
            mpEnvMapSampler = std::make_unique<EnvMapSampler>(mpDevice, mpScene->getEnvMap());
        }
    }
    else
    {
        if (mpEnvMapSampler)
        {
            mpEnvMapSampler = nullptr;
            resetRenderPasses();
        }
    }
}

void ReSTIR_PT_Test::prepareResources(RenderContext* pRenderContext, const RenderData& renderData)
{
    if (any(mScreenRes != renderData.getDefaultTextureDims()))
    {
        mpReservoirPT[0].reset();
        mpReservoirPT[1].reset();
        mScreenRes = renderData.getDefaultTextureDims();
    }

    for (uint i = 0; i < 2; i++)
    {
        if (!mpReservoirPT[i])
        {
            mpReservoirPT[i] = Buffer::createStructured(
                mpDevice, sizeof(uint) * 22, mScreenRes.x * mScreenRes.y,
                ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess, Buffer::CpuAccess::None, nullptr, false
            );
            mpReservoirPT[i]->setName("ReservoirPT_" + std::to_string(i));
        }
    }
}

void ReSTIR_PT_Test::tracePathPass(RenderContext* pRenderContext, const RenderData& renderData)
{
    FALCOR_PROFILE(pRenderContext, "TracePath");

    //Init Shader
    if (!mTracePathPass.pProgram)
    {
        RtProgram::Desc desc;
        desc.addShaderModules(mpScene->getShaderModules());
        desc.addShaderLibrary(kShaderTracePath);
        desc.setMaxPayloadSize(sizeof(float) * 4);
        desc.setMaxAttributeSize(mpScene->getRaytracingMaxAttributeSize());
        desc.setMaxTraceRecursionDepth(1);
        if (!mpScene->hasProceduralGeometry())
            desc.setPipelineFlags(RtPipelineFlags::SkipProceduralPrimitives);

        mTracePathPass.pBindingTable = RtBindingTable::create(1, 1, mpScene->getGeometryCount());
        auto& sbt = mTracePathPass.pBindingTable;
        sbt->setRayGen(desc.addRayGen("rayGen", mpScene->getTypeConformances()));
        sbt->setMiss(0, desc.addMiss("miss"));

        if (mpScene->hasGeometryType(Scene::GeometryType::TriangleMesh))
        {
            sbt->setHitGroup(0, mpScene->getGeometryIDs(Scene::GeometryType::TriangleMesh), desc.addHitGroup("closestHit", "anyHit"));
        }
        mTracePathPass.pProgram = RtProgram::create(mpDevice, desc, mpScene->getSceneDefines());
    }

    //Runtime defines
    mTracePathPass.pProgram->addDefine("USE_ANALYTIC_LIGHT", mpScene->useAnalyticLights() ? "1" : "0");
    mTracePathPass.pProgram->addDefine("USE_EMISSIVE_LIGHT", mpScene->useEmissiveLights() ? "1" : "0");
    mTracePathPass.pProgram->addDefine("USE_ENV_BACKROUND", mpScene->useEnvBackground() ? "1" : "0");
    mTracePathPass.pProgram->addDefine("ROUGHNESS_THRESHOLD", std::to_string(mRoughnessThreshold));
    mTracePathPass.pProgram->addDefines(mpRTXDI->getDefines());
    if (mpEmissiveLightSampler)
        mTracePathPass.pProgram->addDefines(mpEmissiveLightSampler->getDefines());

    // Program Vars
    if (!mTracePathPass.pVars)
        mTracePathPass.initProgramVars(mpDevice, mpScene, mpSampleGenerator);

    FALCOR_ASSERT(mTracePathPass.pVars);
    auto var = mTracePathPass.pVars->getRootVar();
    mpScene->setRaytracingShaderData(pRenderContext, var);
    mpRTXDI->setShaderData(var);
    if (mpEmissiveLightSampler)
        mpEmissiveLightSampler->setShaderData(var["Light"]["gEmissiveSampler"]);
    if (mpEnvMapSampler)
        mpEnvMapSampler->setShaderData(var["Light"]["gEnvMapSampler"]);

    //Calc nee light type select probability (currently equal probability)
    float3 neeLightSelectProb =
        float3(mpScene->useEmissiveLights() ? 1.f : 0.f, mpScene->useAnalyticLights() ? 1.f : 0.f, mpScene->useEnvLight() ? 1.f : 0.f);
    neeLightSelectProb /= neeLightSelectProb.x + neeLightSelectProb.y + neeLightSelectProb.z;

    //Constant Buffer
    var["CB"]["gFrameCount"] = mFrameCount;
    var["CB"]["gNeeLightTypeSelectProbability"] = neeLightSelectProb;
    var["CB"]["gMaxBounces"] = mPTBounces;

    // Input Resources
    var["gVBuffer"] = renderData[kInputVBuffer]->asTexture();
    var["gView"] = renderData[kInputView]->asTexture();

    var["gReservoir"] = mpReservoirPT[mFrameCount % 2];
    var["gColorOut"] = renderData[kOutputColor]->asTexture();

    // Dispatch Shader
    mpScene->raytrace(pRenderContext, mTracePathPass.pProgram.get(), mTracePathPass.pVars, uint3(mScreenRes, 1));

    pRenderContext->uavBarrier(renderData[kOutputColor]->asTexture().get());
}

void ReSTIR_PT_Test::evalReservoirPass(RenderContext* pRenderContext, const RenderData& renderData)
{
    FALCOR_PROFILE(pRenderContext, "EvaluateReservoir");

    // Initialize compute pass
    if (!mpEvalReservoirPass)
    {
        Program::Desc desc;
        desc.addShaderModules(mpScene->getShaderModules());
        desc.addShaderLibrary(kShaderEvalReseroir).csEntry("main").setShaderModel(kShaderModel);
        desc.addTypeConformances(mpScene->getTypeConformances());

        DefineList defines;
        defines.add(mpScene->getSceneDefines());
        defines.add(mpSampleGenerator->getDefines());
        defines.add("USE_ENV_BACKROUND", mpScene->useEnvBackground() ? "1" : "0");
        defines.add(mpRTXDI->getDefines());

        mpEvalReservoirPass = ComputePass::create(mpDevice, desc, defines, true);
    }
    FALCOR_ASSERT(mpEvalReservoirPass);

    mpEvalReservoirPass->getProgram()->addDefines(mpRTXDI->getDefines());
    mpEvalReservoirPass->getProgram()->addDefine("USE_ENV_BACKROUND", mpScene->useEnvBackground() ? "1" : "0");

    // Set variables
    auto var = mpEvalReservoirPass->getRootVar();
    mpScene->setRaytracingShaderData(pRenderContext, var); // Set scene data
    mpSampleGenerator->setShaderData(var);                 // Sample generator

    // Constant Buffer
    var["CB"]["gFrameCount"] = mFrameCount;
    var["CB"]["gFrameDim"] = mScreenRes;

    // RTXDI resources
    mpRTXDI->setShaderData(var);

    // Input
    var["gVBuffer"] = renderData[kInputVBuffer]->asTexture();
    var["gView"] = renderData[kInputView]->asTexture();
    var["gReservoir"] = mpReservoirPT[mFrameCount % 2];

    // Output
    var["gOutColor"] = renderData[kOutputColor]->asTexture();

    // Execute
    const uint2 targetDim = renderData.getDefaultTextureDims();
    FALCOR_ASSERT(targetDim.x > 0 && targetDim.y > 0);
    mpEvalReservoirPass->execute(pRenderContext, uint3(targetDim, 1));
}

void ReSTIR_PT_Test::RayTraceProgramHelper::initProgramVars(ref<Device> pDevice, ref<Scene> pScene, ref<SampleGenerator> pSampleGenerator)
{
    FALCOR_ASSERT(pProgram);

    // Configure program.
    pProgram->addDefines(pSampleGenerator->getDefines());
    pProgram->setTypeConformances(pScene->getTypeConformances());
    // Create program variables for the current program.
    // This may trigger shader compilation. If it fails, throw an exception to abort rendering.
    pVars = RtProgramVars::create(pDevice, pProgram, pBindingTable);

    // Bind utility classes into shared data.
    auto var = pVars->getRootVar();
    pSampleGenerator->setShaderData(var);
}
