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
    const std::string kShaderEvalReservoir = kShaderFolder + "EvaluateReservoir.cs.slang";
    const std::string kShaderResamplingRetracePath = kShaderFolder + "ResampleRetracePath.rt.slang";
    const std::string kShaderResampling = kShaderFolder + "Resample.cs.slang";
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
        changed |= mPathLengthSettings.renderUI(group);
        mRebuildLightSampler |= group.dropdown("NEE Sampler", mEmissiveLightSamplerType);
        if (mEmissiveLightSamplerType == EmissiveLightSamplerType::LightBVH)
        {
            if (auto group2 = group.group("NEE Sampler Options"))
            {
                mpEmissiveLightSampler->renderUI(group2);
            }
        }
        changed |= group.var("Reuse Roughness Threshold", mRoughnessThreshold, 0.f, 1.f, 0.001f);
        changed |= group.var("Jacobian Distance Threshold", mJacobianDistanceThreshold, 0.f, FLT_MAX, 0.000001f, false, "%.6f");
        changed |= group.checkbox("Eval Delta Pdf", mEvalDeltaPDFs);
        group.tooltip("If disabled set pdfs of delta reflections (roughness < 0.07) to 1. Else, resampling of some paths will be impossible");

        changed |= group.checkbox("Enable Resampling", mEnableResampling);
        changed |= group.var("ConfidenceCap", mConfidenceCap, 1u, UINT_MAX, 1u);
        changed |= group.var("SpatialSamples", mSpatialSamples, 0u, 32u, 1u);
        changed |= group.var("SpatialRadius", mSpatialSampleRadius, 1.f, FLT_MAX, 0.1f);

        changed |= group.checkbox("Enable RC Path Retracing", mRetraceRCPath);
        group.tooltip("Also retraces the path stored in the RC surface. Is needed to stay unbiased on animated scenes");
        changed |= group.checkbox("Random Replay pass per reservoir", mSeperateRetracePass);
        group.tooltip("Else, both random replay retrace operations are performed in one shader pass");
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

    if (auto group = widget.group("Debug"))
    {
        widget.checkbox("Clear Debug", mClearDebug);
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

    //Debug clear
    if (mClearDebug)
        pRenderContext->clearTexture(renderData[kOutputDebug]->asTexture().get(), float4(0,0,0,1));

    //Update RNG start index
    mRNGGenNumberRenderPasses = 4 + mSpatialSamples;

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

    if (mResamplingValid && mEnableResampling)
    {
        const uint numResamplingPasses = 1 + mSpatialSamples;
        for (uint i = 0; i < numResamplingPasses; i++)
        {
            resamplingRetracePathPass(pRenderContext, renderData, i);

            resamplingPass(pRenderContext, renderData, i);
        }        
    }
        
    evalReservoirPass(pRenderContext, renderData);

    mpRTXDI->endFrame(pRenderContext);

    mFrameCount++;
    mResamplingValid = true;
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
        mpReservoirPT[0] = nullptr;
        mpReservoirPT[1] = nullptr;
        mpRetraceSurfaceBuffer[0] = nullptr;
        mpRetraceSurfaceBuffer[1] = nullptr;
        mpViewPrev = nullptr;
        mpVBufferPrev = nullptr;
        mScreenRes = renderData.getDefaultTextureDims();
        mResamplingValid = false;
    }

    for (uint i = 0; i < 2; i++)
    {
        if (!mpReservoirPT[i])
        {
            mpReservoirPT[i] = Buffer::createStructured(
                mpDevice, sizeof(uint) * 28, mScreenRes.x * mScreenRes.y,
                ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess, Buffer::CpuAccess::None, nullptr, false
            );
            mpReservoirPT[i]->setName("ReservoirPT_" + std::to_string(i));
        }

        if (!mpRetraceSurfaceBuffer[i])
        {
            mpRetraceSurfaceBuffer[i] = Buffer::createStructured(
                mpDevice, sizeof(uint) * 12, mScreenRes.x * mScreenRes.y,
                ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess, Buffer::CpuAccess::None, nullptr, false
            );
            mpRetraceSurfaceBuffer[i]->setName("RetraceSurfaceBuffer_" + std::to_string(i));
        }

        if (!mpRetraceRCSurfaceThpTexture[i])
        {
            mpRetraceRCSurfaceThpTexture[i] = Texture::create2D(mpDevice, mScreenRes.x, mScreenRes.y, ResourceFormat::RGBA32Float,
                1u, 1u, nullptr, ResourceBindFlags::UnorderedAccess | ResourceBindFlags::ShaderResource);
            mpRetraceRCSurfaceThpTexture[i]->setName("RetraceRCThroughput" + std::to_string(i));
        }
    }

    if (!mpViewPrev)
    {
        auto viewTex = renderData[kInputView]->asTexture();
        mpViewPrev = Texture::create2D(
            mpDevice, mScreenRes.x, mScreenRes.y, viewTex->getFormat(), 1u, 1u, nullptr,
            ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess
        );
        mpViewPrev->setName("ViewPrevious");
    }

    if (!mpVBufferPrev)
    {
        auto vbufferTex = renderData[kInputVBuffer]->asTexture();
        mpVBufferPrev = Texture::create2D(
            mpDevice, mScreenRes.x, mScreenRes.y, vbufferTex->getFormat(), 1u, 1u, nullptr,
            ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess
        );
        mpVBufferPrev->setName("VBufferPrevious");
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
    mTracePathPass.pProgram->addDefine("USE_ENV_LIGHT", mpScene->useEnvLight() ? "1" : "0");
    mTracePathPass.pProgram->addDefine("RNG_NUM_PASSES", std::to_string(mRNGGenNumberRenderPasses));
    mTracePathPass.pProgram->addDefine("ROUGHNESS_THRESHOLD", std::to_string(mRoughnessThreshold));
    mTracePathPass.pProgram->addDefine("JACOBIAN_DISTANCE_THRESHOLD", std::to_string(mJacobianDistanceThreshold));
    mTracePathPass.pProgram->addDefines(mpRTXDI->getDefines());
    mTracePathPass.pProgram->addDefine("EVAL_DELTA_PDFS", mEvalDeltaPDFs ? "1" : "0");
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
    mNeeLightSelectProb =
        float3(mpScene->useEmissiveLights() ? 1.f : 0.f, mpScene->useAnalyticLights() ? 1.f : 0.f, mpScene->useEnvLight() ? 1.f : 0.f);
    mNeeLightSelectProb /= mNeeLightSelectProb.x + mNeeLightSelectProb.y + mNeeLightSelectProb.z;

    //Constant Buffer
    var["CB"]["gFrameCount"] = mFrameCount;
    var["CB"]["gNeeLightTypeSelectProbability"] = mNeeLightSelectProb;
    var["CB"]["gPackedPathLength"] = mPathLengthSettings.pack();

    // Input Resources
    var["gVBuffer"] = renderData[kInputVBuffer]->asTexture();
    var["gView"] = renderData[kInputView]->asTexture();

    var["gReservoir"] = mpReservoirPT[mFrameCount % 2];
    var["gColorOut"] = renderData[kOutputColor]->asTexture();

    // Dispatch Shader
    mpScene->raytrace(pRenderContext, mTracePathPass.pProgram.get(), mTracePathPass.pVars, uint3(mScreenRes, 1));

    pRenderContext->uavBarrier(renderData[kOutputColor]->asTexture().get());
}

 void ReSTIR_PT_Test::resamplingRetracePathPass(RenderContext* pRenderContext, const RenderData& renderData, uint numResamplingIndex)
 {
     std::string profilerName = "ResamplingRetrace";
     if (numResamplingIndex > 0)
         profilerName += "_Spatial_" + std::to_string(numResamplingIndex);
     else
         profilerName  += "_Temporal";
     FALCOR_PROFILE(pRenderContext, profilerName.c_str());
     // Init Shader
     if (!mResampleRetracePathPass.pProgram)
     {
         RtProgram::Desc desc;
         desc.addShaderModules(mpScene->getShaderModules());
         desc.addShaderLibrary(kShaderResamplingRetracePath);
         desc.setMaxPayloadSize(sizeof(float) * 4);
         desc.setMaxAttributeSize(mpScene->getRaytracingMaxAttributeSize());
         desc.setMaxTraceRecursionDepth(1);
         if (!mpScene->hasProceduralGeometry())
             desc.setPipelineFlags(RtPipelineFlags::SkipProceduralPrimitives);

         mResampleRetracePathPass.pBindingTable = RtBindingTable::create(1, 1, mpScene->getGeometryCount());
         auto& sbt = mResampleRetracePathPass.pBindingTable;
         sbt->setRayGen(desc.addRayGen("rayGen", mpScene->getTypeConformances()));
         sbt->setMiss(0, desc.addMiss("miss"));

         if (mpScene->hasGeometryType(Scene::GeometryType::TriangleMesh))
         {
             sbt->setHitGroup(0, mpScene->getGeometryIDs(Scene::GeometryType::TriangleMesh), desc.addHitGroup("closestHit", "anyHit"));
         }
         mResampleRetracePathPass.pProgram = RtProgram::create(mpDevice, desc, mpScene->getSceneDefines());
     }

     // Runtime defines
     mResampleRetracePathPass.pProgram->addDefine("USE_ANALYTIC_LIGHT", mpScene->useAnalyticLights() ? "1" : "0");
     mResampleRetracePathPass.pProgram->addDefine("USE_EMISSIVE_LIGHT", mpScene->useEmissiveLights() ? "1" : "0");
     mResampleRetracePathPass.pProgram->addDefine("USE_ENV_BACKROUND", mpScene->useEnvBackground() ? "1" : "0");
     mResampleRetracePathPass.pProgram->addDefine("USE_ENV_LIGHT", mpScene->useEnvLight() ? "1" : "0");
     mResampleRetracePathPass.pProgram->addDefine("ROUGHNESS_THRESHOLD", std::to_string(mRoughnessThreshold));
     mResampleRetracePathPass.pProgram->addDefine("JACOBIAN_DISTANCE_THRESHOLD", std::to_string(mJacobianDistanceThreshold));
     mResampleRetracePathPass.pProgram->addDefine("RNG_NUM_PASSES", std::to_string(mRNGGenNumberRenderPasses));
     mResampleRetracePathPass.pProgram->addDefine("EVAL_DELTA_PDFS", mEvalDeltaPDFs ? "1" : "0");
     mResampleRetracePathPass.pProgram->addDefine("RETRACE_RC_PATH", mRetraceRCPath ? "1" : "0");
     if (mpEmissiveLightSampler)
         mResampleRetracePathPass.pProgram->addDefines(mpEmissiveLightSampler->getDefines());

     // Program Vars
     if (!mResampleRetracePathPass.pVars)
         mResampleRetracePathPass.initProgramVars(mpDevice, mpScene, mpSampleGenerator);

     FALCOR_ASSERT(mResampleRetracePathPass.pVars);
     auto var = mResampleRetracePathPass.pVars->getRootVar();
     mpScene->setRaytracingShaderData(pRenderContext, var);
     if (mpEmissiveLightSampler)
         mpEmissiveLightSampler->setShaderData(var["Light"]["gEmissiveSampler"]);
     if (mpEnvMapSampler)
         mpEnvMapSampler->setShaderData(var["Light"]["gEnvMapSampler"]);

     //Constant Buffer
     var["CB"]["gFrameCount"] = mFrameCount;
     var["CB"]["gPackedPathLength"] = mPathLengthSettings.pack();
     var["CB"]["gNeeLightTypeSelectProbability"] = mNeeLightSelectProb;
     var["CB"]["gRNGNumPass"] = numResamplingIndex; 
     var["CB"]["gSpatialSampleRadius"] = mSpatialSampleRadius;
     var["CB"]["gPassIdentifier"] = mSeperateRetracePass ? 1u : 0u;

     // Input Resources
     var["gVBuffer"] = renderData[kInputVBuffer]->asTexture();
     var["gView"] = renderData[kInputView]->asTexture();
     var["gVBufferPrev"] = mpVBufferPrev;
     var["gViewPrev"] = mpViewPrev;

     var["gMVec"] = renderData[kInputMotionVectors]->asTexture();
     var["gReservoirPrev"] = mpReservoirPT[(mFrameCount + 1) % 2];
     var["gRetraceSurfacePrev"] = mpRetraceSurfaceBuffer[1]; //For other sample

     var["gReservoir"] = mpReservoirPT[mFrameCount % 2];
     var["gRetraceSurface"] = mpRetraceSurfaceBuffer[0]; //For current sample
     var["gRetraceRCPathThp"] = mpRetraceRCSurfaceThpTexture[0];
     var["gRetraceRCPathThpPrev"] = mpRetraceRCSurfaceThpTexture[1];

     // Dispatch Shader
     mpScene->raytrace(pRenderContext, mResampleRetracePathPass.pProgram.get(), mResampleRetracePathPass.pVars, uint3(mScreenRes, 1));

     // Dispatch second pass if the shader was split
     if (mSeperateRetracePass) {
        var["CB"]["gPassIdentifier"] = 2u;
        mpScene->raytrace(pRenderContext, mResampleRetracePathPass.pProgram.get(), mResampleRetracePathPass.pVars, uint3(mScreenRes, 1));
     }

 }

void ReSTIR_PT_Test::resamplingPass(RenderContext* pRenderContext, const RenderData& renderData, uint numResamplingIndex)
 {
    std::string profilerName = "Resample";
    if (numResamplingIndex > 0)
        profilerName += "_Spatial_" + std::to_string(numResamplingIndex);
    else
        profilerName += "_Temporal";
    FALCOR_PROFILE(pRenderContext, profilerName.c_str());
    // Initialize compute pass
    if (!mpResamplePass)
    {
        Program::Desc desc;
        desc.addShaderModules(mpScene->getShaderModules());
        desc.addShaderLibrary(kShaderResampling).csEntry("main").setShaderModel(kShaderModel);
        desc.addTypeConformances(mpScene->getTypeConformances());

        DefineList defines;
        defines.add(mpScene->getSceneDefines());
        defines.add(mpSampleGenerator->getDefines());
        defines.add("RNG_NUM_PASSES", std::to_string(mRNGGenNumberRenderPasses));
        defines.add("JACOBIAN_DISTANCE_THRESHOLD", std::to_string(mJacobianDistanceThreshold));
        defines.add("RETRACE_RC_PATH", mRetraceRCPath ? "1" : "0");

        mpResamplePass = ComputePass::create(mpDevice, desc, defines, true);
    }
    FALCOR_ASSERT(mpResamplePass);

    mpResamplePass->getProgram()->addDefine("RNG_NUM_PASSES", std::to_string(mRNGGenNumberRenderPasses));
    mpResamplePass->getProgram()->addDefine("JACOBIAN_DISTANCE_THRESHOLD", std::to_string(mJacobianDistanceThreshold));
    mpResamplePass->getProgram()->addDefine("RETRACE_RC_PATH", mRetraceRCPath ? "1" : "0");

    auto var = mpResamplePass->getRootVar();
    mpScene->setRaytracingShaderData(pRenderContext, var); // Set scene data
    mpSampleGenerator->setShaderData(var);                 // Sample generator

    // Constant Buffer
    var["CB"]["gFrameCount"] = mFrameCount;
    var["CB"]["gFrameDim"] = mScreenRes;
    var["CB"]["gConfidenceCap"] = mConfidenceCap;
    var["CB"]["gRNGNumPass"] = numResamplingIndex;
    var["CB"]["gSpatialSampleRadius"] = mSpatialSampleRadius;

    // Input
    var["gVBuffer"] = renderData[kInputVBuffer]->asTexture();
    var["gView"] = renderData[kInputView]->asTexture();
    var["gVBufferPrev"] = mpVBufferPrev;
    var["gViewPrev"] = mpViewPrev;
    var["gMVec"] = renderData[kInputMotionVectors]->asTexture();
    var["gReservoirPrev"] = mpReservoirPT[(mFrameCount + 1) % 2];
    var["gRetracedSurfacePrev"] = mpRetraceSurfaceBuffer[1];
    var["gRetracedSurface"] = mpRetraceSurfaceBuffer[0];
    var["gRetraceRCPathThp"] = mpRetraceRCSurfaceThpTexture[0];
    var["gRetraceRCPathThpPrev"] = mpRetraceRCSurfaceThpTexture[1];

    var["gReservoir"] = mpReservoirPT[mFrameCount % 2];

    var["gDebug"] = renderData[kOutputDebug]->asTexture();

    if (renderData[kOutputDebug]->asTexture()) {
        pRenderContext->clearTexture(renderData[kOutputDebug]->asTexture().get());
        pRenderContext->uavBarrier(renderData[kOutputDebug]->asTexture().get());
    }

    // Execute
    FALCOR_ASSERT(mScreenRes.x > 0 && mScreenRes.y > 0);
    mpResamplePass->execute(pRenderContext, uint3(mScreenRes, 1));
}

void ReSTIR_PT_Test::evalReservoirPass(RenderContext* pRenderContext, const RenderData& renderData)
{
    FALCOR_PROFILE(pRenderContext, "EvaluateReservoir");

    // Initialize compute pass
    if (!mpEvalReservoirPass)
    {
        Program::Desc desc;
        desc.addShaderModules(mpScene->getShaderModules());
        desc.addShaderLibrary(kShaderEvalReservoir).csEntry("main").setShaderModel(kShaderModel);
        desc.addTypeConformances(mpScene->getTypeConformances());

        DefineList defines;
        defines.add(mpScene->getSceneDefines());
        defines.add(mpSampleGenerator->getDefines());
        defines.add("USE_ENV_BACKROUND", mpScene->useEnvBackground() ? "1" : "0");
        defines.add(mpRTXDI->getDefines());
        defines.add("RNG_NUM_PASSES", std::to_string(mRNGGenNumberRenderPasses));

        mpEvalReservoirPass = ComputePass::create(mpDevice, desc, defines, true);
    }
    FALCOR_ASSERT(mpEvalReservoirPass);

    mpEvalReservoirPass->getProgram()->addDefines(mpRTXDI->getDefines());
    mpEvalReservoirPass->getProgram()->addDefine("USE_ENV_BACKROUND", mpScene->useEnvBackground() ? "1" : "0");
    mpEvalReservoirPass->getProgram()->addDefine("RNG_NUM_PASSES", std::to_string(mRNGGenNumberRenderPasses));

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
    var["gViewPrev"] = mpViewPrev;
    var["gVBufferPrev"] = mpVBufferPrev;

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
