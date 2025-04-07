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
#include "TransparentShadowMask.h"
#include "Utils/Math/FalcorMath.h"

namespace
{
const std::string kShaderGenRaster = "RenderPasses/TransparencyRenderer/TransparentShadowMask/GenTransparentShadowMask.3d.slang";
const std::string kShaderAccumulate = "RenderPasses/TransparencyRenderer/TransparentShadowMask/AccumulateMask.cs.slang";
const std::string kShaderGenerateOpaqueISMRT = "RenderPasses/TransparencyRenderer/TransparentShadowMask/GenMaskImportanceShadowMap.rt.slang";
const std::string kShaderGenerateOpaqueSMRT = "RenderPasses/TransparencyRenderer/TransparentShadowMask/GenMaskShadowMap.rt.slang";
}

TransparentShadowMask::TransparentShadowMask(ref<Device> pDevice, ref<Scene> pScene) : mpDevice(pDevice), mpScene(pScene)
{
    mpFence = GpuFence::create(mpDevice);
    FALCOR_ASSERT(mpFence);
    for (auto& waitVal : mFenceWaitValues)
        waitVal = 0;
}

void TransparentShadowMask::generate(
    RenderContext* pRenderContext,
    const RenderData& renderData,
    const TransparencyShadowMethod* pTransparencyShadowMethod,
    ref<SampleGenerator> pSampleGenerator,
    MaskGenerateMode genMode
)
{
    if (genMode != MaskGenerateMode::NoMask_SM)
        generateTransparencyMask(pRenderContext, renderData, pTransparencyShadowMethod);

    if (mEnableOpaqueMaskShadowMaps)
    {
        if (genMode == MaskGenerateMode::Mask_ISM)
            generateOpaqueMaskImportanceShadowMap(pRenderContext, renderData, pTransparencyShadowMethod, pSampleGenerator);
        else
            generateOpaqueMaskShadowMap(pRenderContext, renderData, pTransparencyShadowMethod);
    }   
}

void TransparentShadowMask::generateTransparencyMask(RenderContext* pRenderContext, const RenderData& renderData,const TransparencyShadowMethod* pTransparencyShadowMethod) {
    FALCOR_PROFILE(pRenderContext,"TransparentObjectsMasks");

    auto& lights = mpScene->getLights();
    const uint2 smRes = pTransparencyShadowMethod->getShadowMapResolution();
    auto& lightMVPs = pTransparencyShadowMethod->getLightMVPs();

    //Prepare Resources
    //Mask Render target
    if (!mpTransparentShadowMaskRaster || mpTransparentShadowMaskRaster->getWidth() != smRes.x || mpTransparentShadowMaskRaster->getHeight() != smRes.y ||
        mpTransparentShadowMaskRaster->getArraySize() != lights.size())
    {
        mpTransparentShadowMaskRaster = Texture::create2D(
            mpDevice, smRes.x, smRes.y, ResourceFormat::R8Unorm, lights.size(), 1u, nullptr,
            ResourceBindFlags::RenderTarget | ResourceBindFlags::ShaderResource
        );
        mpTransparentShadowMaskRaster->setName("TransparentShadowMaskRenderTarget");
    }
    //Mask temporal accumulate
    if (!mpTransparentShadowMask || mpTransparentShadowMask->getWidth() != smRes.x || mpTransparentShadowMask->getHeight() != smRes.y)
    {
        mpTransparentShadowMask = Texture::create2D(
            mpDevice, smRes.x, smRes.y, ResourceFormat::R8Unorm, lights.size(), 1u, nullptr,
            ResourceBindFlags::UnorderedAccess | ResourceBindFlags::ShaderResource
        );
        mpTransparentShadowMask->setName("TransparentShadowMask");
    }
    
     // Init Program
    if (!mGenerateMaskPip.pProgram)
    {
        // Init program
        Program::Desc desc;
        desc.addShaderLibrary(kShaderGenRaster).vsEntry("vsMain").psEntry("psMain");
        desc.setShaderModel("6_6");
        desc.addShaderModules(mpScene->getShaderModules());
        desc.addTypeConformances(mpScene->getTypeConformances());

        auto defines = mpScene->getSceneDefines();
        defines.add("COUNT_LIGHTS", std::to_string(mpScene->getLightCount()));
        // Create Program and state
        mGenerateMaskPip.pProgram = GraphicsProgram::create(mpDevice, desc, defines);
        mGenerateMaskPip.pState = GraphicsState::create(mpDevice);

        // Set state
        DepthStencilState::Desc dsDesc;
        dsDesc.setDepthEnabled(false);
        mGenerateMaskPip.pState->setDepthStencilState(DepthStencilState::create(dsDesc));
        mGenerateMaskPip.pState->setDepthStencilState(DepthStencilState::create(dsDesc));
        mGenerateMaskPip.pState->setProgram(mGenerateMaskPip.pProgram);

        mGenerateMaskPip.pFBO = Fbo::create(mpDevice);
    }

    FALCOR_ASSERT(mGenerateMaskPip.pProgram);

    if (!mGenerateMaskPip.pVars)
    {
        mGenerateMaskPip.pVars = GraphicsVars::create(mpDevice, mGenerateMaskPip.pProgram.get());
    }

    auto var = mGenerateMaskPip.pVars->getRootVar();

    auto meshRenderMode = RasterizerState::MeshRenderMode::SkipOpaque | RasterizerState::MeshRenderMode::SkipParticleCamera;

    //Raster pass over every light
    for (uint i = 0; i < lights.size(); i++)
    {
        FALCOR_PROFILE(pRenderContext, "Rasterize_Semi-Transparent: " + lights[i]->getName());
        auto& lightData = lights[i]->getData();

        // Get best fitting light direction for particles
        Scene::ParticleOrientationMode partOrientation = Scene::ParticleOrientationMode::XY_Plane;
        float xy = math::abs(math::dot(lightData.dirW, float3(0.f, 0.f, 1.f)));
        float yz = math::abs(math::dot(lightData.dirW, float3(1.f, 0.f, 0.f)));
        float xz = math::abs(math::dot(lightData.dirW, float3(0.f, 1.f, 0.f)));
        if (yz > xy)
        {
            xy = yz;
            partOrientation = Scene::ParticleOrientationMode::YZ_Plane;
        }
        if (xz > xy)
            partOrientation = Scene::ParticleOrientationMode::XZ_Plane;

        switch (partOrientation)
        {
        
        case Falcor::Scene::ParticleOrientationMode::XY_Plane:
            meshRenderMode |= RasterizerState::MeshRenderMode::SkipParticleXZ | RasterizerState::MeshRenderMode::SkipParticleYZ;
            break;
        case Falcor::Scene::ParticleOrientationMode::YZ_Plane:
            meshRenderMode |= RasterizerState::MeshRenderMode::SkipParticleXY | RasterizerState::MeshRenderMode::SkipParticleXZ;
            break;
        case Falcor::Scene::ParticleOrientationMode::XZ_Plane:
            meshRenderMode |= RasterizerState::MeshRenderMode::SkipParticleXY | RasterizerState::MeshRenderMode::SkipParticleYZ;
            break;
        case Falcor::Scene::ParticleOrientationMode::None:
        case Falcor::Scene::ParticleOrientationMode::Camera:
        default:
            FALCOR_UNREACHABLE();
            break;
        }

        //Set and clear FBO
        mGenerateMaskPip.pFBO->attachColorTarget(mpTransparentShadowMaskRaster, 0u, 0u, i, 1u);
        mGenerateMaskPip.pState->setFbo(mGenerateMaskPip.pFBO);

        pRenderContext->clearFbo(mGenerateMaskPip.pFBO.get(), float4(0.f), 1.f, 0);

        //Set shader data
        var["CB"]["gViewProjection"] = lightMVPs[i].viewProjectionNoJitter;

        mpScene->rasterize(pRenderContext, mGenerateMaskPip.pState.get(), mGenerateMaskPip.pVars.get(), RasterizerState::CullMode::None,meshRenderMode, !mEnableBlacklistWithMaterialFlag);
    }

    //Compute pass for temporal accumulate
    if (!mpTemporalAccumulateMaskPass)
    {
        Program::Desc desc;
        desc.addShaderLibrary(kShaderAccumulate).csEntry("main").setShaderModel("6_6");

        DefineList defines;
        defines.add("COUNT_LIGHTS", std::to_string(lights.size()));

        mpTemporalAccumulateMaskPass = ComputePass::create(mpDevice, desc, defines, true);
    }

    FALCOR_ASSERT(mpTemporalAccumulateMaskPass);

    //Dispatch compute
    {
        //FALCOR_PROFILE(pRenderContext, "TemporalAccumulateMask");
        var = mpTemporalAccumulateMaskPass->getRootVar();
        uint3 dispatchDimensions = uint3(mpTransparentShadowMask->getWidth(), mpTransparentShadowMask->getHeight(), lights.size());

        var["CB"]["gDispatchDims"] = dispatchDimensions;
        var["CB"]["gCurrentBit"] = mTemporalCounter % kMaxTemporal;

        var["gCurrentMask"] = mpTransparentShadowMaskRaster;
        var["gTemporalMask"] = mpTransparentShadowMask;

        mpTemporalAccumulateMaskPass->execute(pRenderContext, dispatchDimensions);
    }

    mTemporalCounter++;
}

void TransparentShadowMask::generateOpaqueMaskImportanceShadowMap(RenderContext* pRenderContext, const RenderData& renderData, const TransparencyShadowMethod* pTransparencyShadowMethod, ref<SampleGenerator> pSampleGenerator)
{
    FALCOR_PROFILE(pRenderContext, "Generate_ISM");

    auto& lights = mpScene->getLights();
    const uint2 smRes = pTransparencyShadowMethod->getShadowMapResolution();
    auto& lightMVPs = pTransparencyShadowMethod->getLightMVPs();

    uint2 maxDispatchDim = pTransparencyShadowMethod->getShaderDispatchSize() * mOpaqueImportanceSMMultFactor;
   
    auto pHaltonBuffer = pTransparencyShadowMethod->getJitterSampleBuffer();
    // Prepare Resources
    {
        size_t maxDispatchDim1D = maxDispatchDim.x * maxDispatchDim.y;
        if (!mpMaskOpaqueImportanceShadowMap ||
            mpMaskOpaqueImportanceShadowMap->getSize() != maxDispatchDim1D * sizeof(float) * lights.size())
        {
            mpMaskOpaqueImportanceShadowMap = Buffer::create(mpDevice, maxDispatchDim1D * sizeof(float) * lights.size());
            /*
            mpMaskOpaqueShadowMap = Texture::create2D(
                mpDevice, smRes.x, smRes.y, ResourceFormat::R32Float, lights.size(), 1u, nullptr,
                ResourceBindFlags::UnorderedAccess | ResourceBindFlags::ShaderResource
            );
            */
            mpMaskOpaqueImportanceShadowMap->setName("TransparencyMaskOpaqueImportanceShadowMap");
        }

        if (!mpMaskSampler)
        {
            Sampler::Desc samplerDesc = {};
            samplerDesc.setFilterMode(Sampler::Filter::Linear, Sampler::Filter::Linear, Sampler::Filter::Linear);
            samplerDesc.setAddressingMode(Sampler::AddressMode::Clamp, Sampler::AddressMode::Clamp, Sampler::AddressMode::Clamp);
            mpMaskSampler = Sampler::create(mpDevice, samplerDesc);
        }
        FALCOR_ASSERT(mpMaskSampler);

        if (mDispatchFeedbackBuffers.empty())
        {
            std::vector<uint> init(lights.size(), 0);
            mDispatchFeedbackBuffers.resize(kFramesInFlight);
            for (uint i = 0; i < kFramesInFlight; i++)
            {
                mDispatchFeedbackBuffers[i].gpu = Buffer::create(
                    mpDevice, lights.size() * sizeof(uint), ResourceBindFlags::UnorderedAccess | ResourceBindFlags::ShaderResource,
                    Buffer::CpuAccess::None, init.data()
                );
                mDispatchFeedbackBuffers[i].cpu =
                    Buffer::create(mpDevice, lights.size() * sizeof(uint), ResourceBindFlags::None, Buffer::CpuAccess::Read, init.data());
                mDispatchFeedbackBuffers[i].gpu->setName("MaskDispatchFeedbackBufferGPU_" + std::to_string(i));
                mDispatchFeedbackBuffers[i].cpu->setName("MaskDispatchFeedbackBufferCPU_" + std::to_string(i));
                mDispatchFeedbackBuffers[i].dispatchDims.resize(lights.size());
                for (auto& disDim : mDispatchFeedbackBuffers[i].dispatchDims)
                    disDim = uint2(0);
            }
        }
    }
    
     // Create scene ray tracing program.
    if (!mGenerateMaskImportanceShadowMapRayPass.pProgram)
    {
        // Shader setup
        RtProgram::Desc desc;
        desc.addShaderModules(mpScene->getShaderModules());
        desc.addShaderLibrary(kShaderGenerateOpaqueISMRT);
        desc.setMaxAttributeSize(mpScene->getRaytracingMaxAttributeSize());
        desc.setMaxPayloadSize(4u);
        desc.setMaxTraceRecursionDepth(1u);

        mGenerateMaskImportanceShadowMapRayPass.pBindingTable = RtBindingTable::create(1, 1, mpScene->getGeometryCount());
        auto& sbt = mGenerateMaskImportanceShadowMapRayPass.pBindingTable;
        sbt->setRayGen(desc.addRayGen("rayGen"));
        sbt->setMiss(0, desc.addMiss("miss"));

        // Only Triangle meshes are supported
        if (mpScene->hasGeometryType(Scene::GeometryType::TriangleMesh))
        {
            sbt->setHitGroup(0, mpScene->getGeometryIDs(Scene::GeometryType::TriangleMesh), desc.addHitGroup("closestHit", "anyHit"));
        }

        // Initial defines and program
        DefineList defines;
        defines.add(mpScene->getSceneDefines());
        defines.add(pSampleGenerator->getDefines());

        mGenerateMaskImportanceShadowMapRayPass.pProgram = RtProgram::create(mpDevice, desc, defines);
    }

    FALCOR_ASSERT(mGenerateMaskImportanceShadowMapRayPass.pProgram);
    uint numHaltonSampls = pHaltonBuffer ? pHaltonBuffer->getElementCount() : 1;

    mGenerateMaskImportanceShadowMapRayPass.pProgram->addDefine("USE_HALTON_SAMPLE_PATTERN", pHaltonBuffer ? "1" : "0");
    mGenerateMaskImportanceShadowMapRayPass.pProgram->addDefine("NUM_HALTON_SAMPLES", std::to_string(numHaltonSampls));
    mGenerateMaskImportanceShadowMapRayPass.pProgram->addDefine("USE_BLACKLIST", mEnableBlacklistWithMaterialFlag ? "1" : "0");
    mGenerateMaskImportanceShadowMapRayPass.pProgram->addDefine("USE_MASK", mGenUseMaskToReject ? "1" : "0");
    mGenerateMaskImportanceShadowMapRayPass.pProgram->addDefine("MASK_ISM_MULT_FACTOR", std::to_string(mOpaqueImportanceSMMultFactor));


     // Init Vars
    if (!mGenerateMaskImportanceShadowMapRayPass.pVars)
    {
        mGenerateMaskImportanceShadowMapRayPass.pProgram->setTypeConformances(mpScene->getTypeConformances());
        mGenerateMaskImportanceShadowMapRayPass.pVars = RtProgramVars::create(
            mpDevice, mGenerateMaskImportanceShadowMapRayPass.pProgram, mGenerateMaskImportanceShadowMapRayPass.pBindingTable
        );
        
    }

    //Get Sample distribution
    FALCOR_ASSERT(pTransparencyShadowMethod->getSamplesDistribution());
    auto sampleDistribution = *(pTransparencyShadowMethod->getSamplesDistribution());

    auto var = mGenerateMaskImportanceShadowMapRayPass.pVars->getRootVar();
    pSampleGenerator->setShaderData(var);

    // Ray pass over every light
    for (uint i = 0; i < lights.size(); i++)
    {
        // Get dispatch dim from feedback buffer
        const uint2& feedDims = mDispatchFeedbackBuffers[mStagingCount].dispatchDims[i];
        uint2 targetDim = feedDims.x >= kOverestimateDispatchConstant || feedDims.y >= kOverestimateDispatchConstant ? feedDims
                              : maxDispatchDim;
        FALCOR_ASSERT(targetDim.x > 0 && targetDim.y > 0);

        bool isDirectional = lights[i]->getType() == LightType::Directional;
        var["CB"]["gLightIdx"] = i;
        var["CB"]["gLightPos"] = lights[i]->getData().posW;
        var["CB"]["gIsDirectional"] = isDirectional;
        var["CB"]["gMipCount"] = sampleDistribution[0]->getMipCount();
        var["CB"]["gSMRes"] = smRes;
        var["CB"]["gFrameCount"] = mFrameCount;
        var["CB"]["gInvViewProjection"] = lightMVPs[i].invViewProjection;
        var["CB"]["gViewProjection"] = lightMVPs[i].viewProjection;

        var["gMask"] = mpTransparentShadowMask;
        var["gSampleDistribution"] = sampleDistribution[i];
        var["gShadowMap"] = mpMaskOpaqueImportanceShadowMap;
        var["gMaskSampler"] = mpMaskSampler;
        var["gHaltonSamples"] = pHaltonBuffer;
        var["gDispatchFeedbackBuffer"] = mDispatchFeedbackBuffers[mStagingCount].gpu;

        // Execute
        mpScene->raytrace(
            pRenderContext, mGenerateMaskImportanceShadowMapRayPass.pProgram.get(), mGenerateMaskImportanceShadowMapRayPass.pVars, uint3(targetDim, 1)
        );
    }

    mFrameCount++;

    //Feedback buffer
    {
        // Copy to CPU
        pRenderContext->copyBufferRegion(
            mDispatchFeedbackBuffers[mStagingCount].cpu.get(), 0, mDispatchFeedbackBuffers[mStagingCount].gpu.get(), 0,
            sizeof(uint32_t) * lights.size()
        );

        // Frame in flight for the counter
        mFenceWaitValues[mStagingCount] = mpFence->gpuSignal(pRenderContext->getLowLevelData()->getCommandQueue());
        mStagingCount = (mStagingCount + 1) % kFramesInFlight;

        uint64_t& fenceWaitVal = mFenceWaitValues[mStagingCount];
        // Wait for the GPU to finish the frame
        if (fenceWaitVal > 0)
            mpFence->syncCpu(fenceWaitVal);
        std::vector<uint> sampleCount(lights.size(), 0);
        void* data = mDispatchFeedbackBuffers[mStagingCount].cpu->map(Buffer::MapType::Read);
        std::memcpy(sampleCount.data(), data, sizeof(uint) * lights.size());
        mDispatchFeedbackBuffers[mStagingCount].cpu->unmap();

        //Convert to dispatch dimension
        for (uint i = 0; i < lights.size(); i++)
        {
            mDispatchFeedbackBuffers[mStagingCount].dispatchDims[i] =
                uint2(math::ceil(math::sqrt(double(sampleCount[i])))) + kOverestimateDispatchConstant;
        }
    }
}

void TransparentShadowMask::generateOpaqueMaskShadowMap(
    RenderContext* pRenderContext,
    const RenderData& renderData,
    const TransparencyShadowMethod* pTransparencyShadowMethod
)
{
    FALCOR_PROFILE(pRenderContext, "Generate_OpaqueSM");

    auto& lights = mpScene->getLights();
    const uint2 smRes = pTransparencyShadowMethod->getShadowMapResolution();
    auto& lightMVPs = pTransparencyShadowMethod->getLightMVPs();

    uint2 targetDim = pTransparencyShadowMethod->getShaderDispatchSize();

    //auto pHaltonBuffer = pTransparencyShadowMethod->getJitterSampleBuffer();
    // Prepare Resources
    {
        if (!mpMaskOpaqueShadowMap || mpMaskOpaqueShadowMap->getWidth() != targetDim.x || mpMaskOpaqueShadowMap->getHeight() != targetDim.y)
        {
            mpMaskOpaqueShadowMap = Texture::create2D(
                mpDevice, smRes.x, smRes.y, ResourceFormat::R32Float, lights.size(), 1u, nullptr,
                ResourceBindFlags::UnorderedAccess | ResourceBindFlags::ShaderResource
            );
            mpMaskOpaqueShadowMap->setName("TransparencyMaskOpaqueShadowMap");
        }

        if (!mpMaskSampler)
        {
            Sampler::Desc samplerDesc = {};
            samplerDesc.setFilterMode(Sampler::Filter::Linear, Sampler::Filter::Linear, Sampler::Filter::Linear);
            samplerDesc.setAddressingMode(Sampler::AddressMode::Clamp, Sampler::AddressMode::Clamp, Sampler::AddressMode::Clamp);
            mpMaskSampler = Sampler::create(mpDevice, samplerDesc);
        }
        FALCOR_ASSERT(mpMaskSampler);
    }
    

    // Create scene ray tracing program.
    if (!mGenerateMaskShadowMapRayPass.pProgram)
    {
        // Shader setup
        RtProgram::Desc desc;
        desc.addShaderModules(mpScene->getShaderModules());
        desc.addShaderLibrary(kShaderGenerateOpaqueSMRT);
        desc.setMaxAttributeSize(mpScene->getRaytracingMaxAttributeSize());
        desc.setMaxPayloadSize(4u);
        desc.setMaxTraceRecursionDepth(1u);

        mGenerateMaskShadowMapRayPass.pBindingTable = RtBindingTable::create(1, 1, mpScene->getGeometryCount());
        auto& sbt = mGenerateMaskShadowMapRayPass.pBindingTable;
        sbt->setRayGen(desc.addRayGen("rayGen"));
        sbt->setMiss(0, desc.addMiss("miss"));

        // Only Triangle meshes are supported
        if (mpScene->hasGeometryType(Scene::GeometryType::TriangleMesh))
        {
            sbt->setHitGroup(0, mpScene->getGeometryIDs(Scene::GeometryType::TriangleMesh), desc.addHitGroup("closestHit", "anyHit"));
        }

        // Initial defines and program
        DefineList defines;
        defines.add(mpScene->getSceneDefines());
        //defines.add(pSampleGenerator->getDefines());

        mGenerateMaskShadowMapRayPass.pProgram = RtProgram::create(mpDevice, desc, defines);
    }

    FALCOR_ASSERT(mGenerateMaskShadowMapRayPass.pProgram);
    //uint numHaltonSampls = pHaltonBuffer ? pHaltonBuffer->getElementCount() : 1;

    //mGenerateMaskShadowMapRayPass.pProgram->addDefine("USE_HALTON_SAMPLE_PATTERN", pHaltonBuffer ? "1" : "0");
    //mGenerateMaskShadowMapRayPass.pProgram->addDefine("NUM_HALTON_SAMPLES", std::to_string(numHaltonSampls));
    mGenerateMaskShadowMapRayPass.pProgram->addDefine("USE_BLACKLIST", mEnableBlacklistWithMaterialFlag ? "1" : "0");
    mGenerateMaskShadowMapRayPass.pProgram->addDefine("USE_MASK", mGenUseMaskToReject ? "1" : "0");

    // Init Vars
    if (!mGenerateMaskShadowMapRayPass.pVars)
    {
        mGenerateMaskShadowMapRayPass.pProgram->setTypeConformances(mpScene->getTypeConformances());
        mGenerateMaskShadowMapRayPass.pVars =
            RtProgramVars::create(mpDevice, mGenerateMaskShadowMapRayPass.pProgram, mGenerateMaskShadowMapRayPass.pBindingTable);
    }

    // Bind shader data
    FALCOR_ASSERT(targetDim.x > 0 && targetDim.y > 0);

    auto var = mGenerateMaskShadowMapRayPass.pVars->getRootVar();
    //pSampleGenerator->setShaderData(var);

    // Ray pass over every light
    for (uint i = 0; i < lights.size(); i++)
    {
        bool isDirectional = lights[i]->getType() == LightType::Directional;
        var["CB"]["gLightIdx"] = i;
        var["CB"]["gLightPos"] = lights[i]->getData().posW;
        var["CB"]["gIsDirectional"] = isDirectional;
        var["CB"]["gSMRes"] = smRes;
        var["CB"]["gFrameCount"] = mFrameCount;
        var["CB"]["gInvViewProjection"] = lightMVPs[i].invViewProjection;
        var["CB"]["gViewProjection"] = lightMVPs[i].viewProjection;

        var["gMask"] = mpTransparentShadowMask;
        var["gShadowMap"] = mpMaskOpaqueShadowMap;
        var["gMaskSampler"] = mpMaskSampler;
        //var["gHaltonSamples"] = pHaltonBuffer;

        // Execute
        mpScene->raytrace(
            pRenderContext, mGenerateMaskShadowMapRayPass.pProgram.get(), mGenerateMaskShadowMapRayPass.pVars, uint3(targetDim, 1)
        );
    }

    mFrameCount++;
}
