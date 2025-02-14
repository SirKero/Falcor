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
#include "LinkedListIrregularZ.h"
#include "Utils/Math/FalcorMath.h"
#include "Utils/SampleGenerators/DxSamplePattern.h"
#include "Utils/SampleGenerators/HaltonSamplePattern.h"
#include "Utils/SampleGenerators/StratifiedSamplePattern.h"

namespace
{
    //Shader Paths
    const std::string kShaderFolder = "RenderPasses/TransparencyRenderer/LinkedListIrregularZ/";
    const std::string kShaderFolderOther = "RenderPasses/TransparencyRenderer/AccelIrregularZ/";
    const std::string kGenShader = kShaderFolder + "GenLinkedListIrregularZ.rt.slang";
    const std::string kAccessMipsShader = kShaderFolderOther + "GenAccessMips.cs.slang";
    const std::string kCalcSampleDistributionShader = kShaderFolderOther + "CalcSampleDistribution.cs.slang";
    const std::string kOptimizeSamplesShader = kShaderFolderOther + "OptimizeSamples.cs.slang";
    //const std::string kShaderDebugShowShadowAccelRaster = kShaderFolder + "DebugShowShadowAccel.3d.slang";

    //UI
    const Gui::DropdownList kAccelDataFormat = {{1, "Uint"}, {2, "Uint2"}, {4, "Uint4"}};

}; // namespace

LinkedListIrregularZ::LinkedListIrregularZ(ref<Device> pDevice, ref<Scene> pScene) : TransparencyShadowMethod(pDevice, pScene)
{
    mpFence = GpuFence::create(mpDevice);
    FALCOR_ASSERT(mpFence);
    Sampler::Desc samplerDesc = {};
    samplerDesc.setFilterMode(Sampler::Filter::Point, Sampler::Filter::Point, Sampler::Filter::Point);
    samplerDesc.setAddressingMode(Sampler::AddressMode::Clamp, Sampler::AddressMode::Clamp, Sampler::AddressMode::Clamp);
    mpPointSampler = Sampler::create(mpDevice, samplerDesc);
    FALCOR_ASSERT(mpPointSampler);
    mpSampleGenerator = SampleGenerator::create(mpDevice, SAMPLE_GENERATOR_UNIFORM);
    FALCOR_ASSERT(mpSampleGenerator);
}

void LinkedListIrregularZ::prepareResources(RenderContext* pRenderContext) {

    //This is triggered if either the resolution or number of lights changed
    if (mResolutionChanged)
    {
        mAccessTextures.clear();
        mSampleDistribution.clear();
        mpLastFrameMaxSampleCount.reset();
        //The following buffers need to be cleared when light count changes
        mLinkedListCounter.clear();
        mLinkedListCounterCPU.clear();
        mCounterFenceWaitValues.clear();
        mUIElementCounter.clear();
    }

    if (mTransparencyBufferUsesColor != mUseColoredTransparency || mResolutionChanged)
    {
        mLinkedListData.clear();
        mTransparencyBufferUsesColor = mUseColoredTransparency;
    }

    // Set Jitter and update Matricies
    if (mpCPUSampleGenerator)
    {
        float2 jitter = mpCPUSampleGenerator->next();
        jitter *= 1.0f / float2(mResolution);
        setJitter(jitter);
    }

    updateSMMatrices();

    // Create AVSM trace program
    if (!mGenLinkedListShadowPip.pProgram)
    {
        RtProgram::Desc desc;
        desc.addShaderModules(mpScene->getShaderModules());
        desc.addShaderLibrary(kGenShader);
        desc.setMaxPayloadSize(32u);
        desc.setMaxAttributeSize(mpScene->getRaytracingMaxAttributeSize());
        desc.setMaxTraceRecursionDepth(1u);

        mGenLinkedListShadowPip.pBindingTable = RtBindingTable::create(1, 1, mpScene->getGeometryCount());
        auto& sbt = mGenLinkedListShadowPip.pBindingTable;
        sbt->setRayGen(desc.addRayGen("rayGen"));
        sbt->setMiss(0, desc.addMiss("miss"));

        if (mpScene->hasGeometryType(Scene::GeometryType::TriangleMesh))
        {
            sbt->setHitGroup(0, mpScene->getGeometryIDs(Scene::GeometryType::TriangleMesh), desc.addHitGroup("closestHit", "anyHit"));
        }

        DefineList defines;
        defines.add(mpScene->getSceneDefines());
        defines.add("USE_COLOR_TRANSPARENCY", mUseColoredTransparency ? "1" : "0");
        defines.add("ACCEL_BOXES_PIXEL_OFFSET", mAccelUsePCF ? "1.0" : "0.5");

        mGenLinkedListShadowPip.pProgram = RtProgram::create(mpDevice, desc, defines);
    }

    auto& lights = mpScene->getLights();

    // Create / Destroy resources
    {
        const uint numBuffers = lights.size();
        const uint numAccelBuffers = lights.size();
        mLinkedListNodeBufferSize = mResolution.x * mResolution.y * mApproxNumElementsPerPixel;
        // Counter
        if (mLinkedListCounter.empty())
        {
            mLinkedListCounter.resize(kFramesInFlight);
            mLinkedListCounterCPU.resize(kFramesInFlight);
            mCounterFenceWaitValues.resize(kFramesInFlight);
            mUIElementCounter.resize(numAccelBuffers);

            std::vector<uint> initData(numAccelBuffers, 0);
            for (uint i = 0; i < kFramesInFlight; i++)
            {
                mLinkedListCounter[i] = Buffer::createStructured(
                    mpDevice, sizeof(uint), numAccelBuffers, ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess,
                    Buffer::CpuAccess::None, initData.data(), false
                );
                mLinkedListCounter[i]->setName("LinkedListElementCounter_" + std::to_string(i));

                mLinkedListCounterCPU[i] = Buffer::createStructured(
                    mpDevice, sizeof(uint), numAccelBuffers, ResourceBindFlags::None, Buffer::CpuAccess::Read, &initData, false
                );
                mLinkedListCounterCPU[i]->setName("LinkedListElementCounterCPU_" + std::to_string(i));

                mCounterFenceWaitValues[i] = 0;
            }

            for (uint i = 0; i < numAccelBuffers; i++)
                mUIElementCounter[i] = mResolution.x * mResolution.y * mApproxNumElementsPerPixel;
        }
        if (mLinkedListData.empty())
        {
            mLinkedListData.resize(numAccelBuffers);
            uint dataStructSize = mUseColoredTransparency ? 5 : 3;
            for (uint i = 0; i < numAccelBuffers; i++)
            {
                mLinkedListData[i] = Buffer::createStructured(
                    mpDevice, sizeof(uint) * dataStructSize, mLinkedListNodeBufferSize,
                    ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess, Buffer::CpuAccess::None, nullptr, false
                );
                mLinkedListData[i]->setName("LinkedListIrrShadowNodes" + std::to_string(i));
            }
        }

        if (mAccessTextures.empty())
        {
            mAccessTextures.resize(numBuffers);
            for (uint i=0; i<numBuffers; i++)
            {
                mAccessTextures[i] = Texture::create2D(
                    mpDevice, mResolution.x, mResolution.y, ResourceFormat::R32Uint, 1u, Texture::kMaxPossible, nullptr,
                    ResourceBindFlags::UnorderedAccess | ResourceBindFlags::ShaderResource
                );
                mAccessTextures[i]->setName("AccessTextureLightLLI" + std::to_string(i));
            }
        }

        if (mSampleDistribution.empty())
        {
            mSampleDistribution.resize(numBuffers);
            for (uint i = 0; i < numBuffers; i++)
            {
                mSampleDistribution[i] = Texture::create2D(
                    mpDevice, mResolution.x, mResolution.y, ResourceFormat::R32Float, 1u, Texture::kMaxPossible, nullptr,
                    ResourceBindFlags::UnorderedAccess | ResourceBindFlags::ShaderResource
                );
                //Set highest mip to total number of samples
                pRenderContext->clearUAV(
                    mSampleDistribution[i]->getUAV(mSampleDistribution[i]->getMipCount() - 1).get(), float4(mResolution.x * mResolution.y)
                );
                mSampleDistribution[i]->setName("SampleDistributionLLI" + std::to_string(i));
            }
        }

        if (!mpLastFrameMaxSampleCount)
        {
            std::vector<uint> initData(numBuffers,0);
            mpLastFrameMaxSampleCount = Buffer::create(
                mpDevice, sizeof(uint) * numBuffers, ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess,
                Buffer::CpuAccess::None, initData.data()
            );
            mpLastFrameMaxSampleCount->setName("LastFrameMaxSampleDistributionLLI");
        }

        if (!mpHaltonBuffer || mpHaltonBuffer->getElementCount() != mNumHaltonSamples)
        {
            // Generate Halton Samples on CPU
            auto haltonSampler = HaltonSamplePattern::create(mNumHaltonSamples);
            std::vector<float2> haltonInitData(mNumHaltonSamples);
            for (uint i = 0; i < mNumHaltonSamples; i++)
                haltonInitData[i] = haltonSampler->next() + 0.5f; // Halton samples are in [-0.5, 0.5) but we want the samples in [0,1)

            // Create and upload GPU buffer
            mpHaltonBuffer = Buffer::createTyped<float2>(
                mpDevice, mNumHaltonSamples, ResourceBindFlags::ShaderResource, Buffer::CpuAccess::None, haltonInitData.data()
            );
            mpHaltonBuffer->setName("HaltonDataBuffer");
        }
    }
}

std::array<float4, 4> LinkedListIrregularZ::getCameraFrustumPlanes()
{
    // TODO add motion prediction
    const CameraData& data = mpScene->getCamera()->getData();
    const float fovY = focalLengthToFovY(data.focalLength, data.frameHeight);
    const float3 camU = normalize(data.cameraU);
    const float3 camV = normalize(data.cameraV);
    const float3 camW = normalize(data.cameraW);

    const float halfVSide = data.farZ * math::tan(fovY * 0.5f);
    const float halfHSide = halfVSide * data.aspectRatio;
    const float3 frontTimesFar = camW * data.farZ;

    // Frustum Planes. Data struct xyz = N ; w = distance
    std::array<float4, 4> frustumPlanes;
    // Top
    float3 N = math::normalize(math::cross(camU, frontTimesFar - camV * halfVSide));
    frustumPlanes[0] = float4(N, math::dot(N, data.posW));
    // Bottom
    N = math::normalize(math::cross(frontTimesFar + camV * halfVSide, camU));
    frustumPlanes[1] = float4(N, math::dot(N, data.posW));
    // Left
    N = math::normalize(math::cross(camV, frontTimesFar + camU * halfHSide));
    frustumPlanes[2] = float4(N, math::dot(N, data.posW));
    // Right
    N = math::normalize(math::cross(frontTimesFar - camU * halfHSide, camV));
    frustumPlanes[3] = float4(N, math::dot(N, data.posW));

    return frustumPlanes;
}

void LinkedListIrregularZ::dummyProfileGeneration(RenderContext* pRenderContext)
{
    {
        FALCOR_PROFILE(pRenderContext, "GenerateAccessMips");
    }
    {
        FALCOR_PROFILE(pRenderContext, "CalcShadowSampleDistribution");
    }
    if (mBlurSampleDistribution && mpGaussianBlur)
    {
        mpGaussianBlur->profileDummy(pRenderContext);
    }
    if (mOptimizeSampleDistribution)
    {
        FALCOR_PROFILE(pRenderContext, "OptimizeDistributedSamples");
    }
    auto& lights = mpScene->getLights();
    for (uint i = 0; i < lights.size(); i++)
    {
        if (!lights[i]->isActive())
            break;
        FALCOR_PROFILE(pRenderContext, lights[i]->getName());
        {
            FALCOR_PROFILE(pRenderContext, "raytraceScene");
        }
    }
}

void LinkedListIrregularZ::generate(RenderContext* pRenderContext, const RenderData& renderData)
{
    FALCOR_PROFILE(pRenderContext, "GenerateShadowLinkedList");

    prepareResources(pRenderContext);

    // Abort early if disabled
    bool skipGeneration = (mSkipFrameCount % mSkipGenerationFrameCount) != 0;
    mSkipFrameCount++;
    if (skipGeneration)
    {
        dummyProfileGeneration(pRenderContext);
        return;
    }

    // Handle light MVP for directional lights
    if (mHasDirectionalLight)
    {
        if (mDirectionalLightIndex < 0 || mDirectionalLightIndex < (int(mpScene->getLightCount())-1))
        {
            for (uint i = 0; i < mpScene->getLightCount(); i++)
            {
                if (mpScene->getLight(i)->getType() == LightType::Directional)
                {
                    mDirectionalLightIndex = i;
                    break;
                }
            }
        }        

        LightMVP tmp = mShadowMapMVP[mDirectionalLightIndex];
        mShadowMapMVP[mDirectionalLightIndex] = mStaggeredDirectionalLightMVP;
        mStaggeredDirectionalLightMVP = tmp;
    }

    //Check if opaque shadow map is set and change ray flags accordingly
    mAccelRayFlags = mOpaqueShadowMapEnabled ? RayFlags::CullOpaque : RayFlags::None;

    auto& lights = mpScene->getLights();
    uint frameInFlight = mStagingCount; //Counter GPU CPU sync

    //Create Access Mips
    {
        FALCOR_PROFILE(pRenderContext, "GenerateAccessMips");
        //Create Gen Mips pass
        if (!mGenAccessMips)
        {
            Program::Desc desc;
            desc.addShaderLibrary(kAccessMipsShader).csEntry("main").setShaderModel("6_6");

            DefineList defines;
            defines.add("COUNT_LIGHTS", std::to_string(lights.size()));

            mGenAccessMips = ComputePass::create(mpDevice, desc, defines, true);
        }

        for (uint m = 0; m < mAccessTextures[0]->getMipCount() - 1; m++)
        {
            auto var = mGenAccessMips->getRootVar();
            for (uint i = 0; i < lights.size(); i++)
            {
                var["gSrc"][i].setSrv(mAccessTextures[i]->getSRV(m, 1u));
                var["gDst"][i].setUav(mAccessTextures[i]->getUAV(m + 1));
            }
               
            uint3 dispatchDim = uint3(mAccessTextures[0]->getWidth(m + 1), mAccessTextures[0]->getHeight(m + 1), lights.size());
            var["CB"]["gDstSize"] = dispatchDim.xy();

            mGenAccessMips->execute(pRenderContext, dispatchDim);
        }
    }
    //Distribute Samples
    {
        FALCOR_PROFILE(pRenderContext, "CalcShadowSampleDistribution");
        // Create Compute Pass
        if (!mCalcSampleDistribution)
        {
            Program::Desc desc;
            desc.addShaderLibrary(kCalcSampleDistributionShader).csEntry("main").setShaderModel("6_6");

            DefineList defines;
            defines.add("COUNT_LIGHTS", std::to_string(lights.size()));
            defines.add("MAX_SAMPLES", std::to_string(mResolution.x * mResolution.y));

            mCalcSampleDistribution = ComputePass::create(mpDevice, desc, defines, true);
        }

        //Calc ray count dispatch
        auto var = mCalcSampleDistribution->getRootVar();
        mCalcSampleDistribution->getProgram()->addDefine(
            "MAX_SAMPLES", std::to_string(mResolution.x * mResolution.y) 
        );

        if (mEnableDynamicRayCountCalc && mFrameCount > 0)
        {
            //Get mip level
            uint mip = mSampleDistribution[0]->getMipCount() - 1;
            var["CB"]["gCalcTotalDispatchCount"] = true;
            var["CB"]["gMaxNumAABBs"] = int(mResolution.x * mResolution.y * mApproxNumElementsPerPixel * mDynRCGuardPercentage);
            var["CB"]["gChangePercentage"] = mDynRCChangePercentage; // 50% for now
            var["CB"]["gMaxSampleOverestimate"] = mSampleOverestimate * mSampleOverestimate; // Squared as this is applied to x and y of dispatch resolution

            var["gLastFrameSampleCount"] = mpLastFrameMaxSampleCount;
            for (uint i = 0; i < lights.size(); i++)
            {
                var["gImpt"][i].setSrv(mAccessTextures[i]->getSRV(mip, 1u));
                var["gSmp"][i].setUav(mSampleDistribution[i]->getUAV(mip));
            }
            int lastFrameInFlight = 0;
            lastFrameInFlight = mStagingCount - 1;
            lastFrameInFlight = lastFrameInFlight < 0 ? kFramesInFlight - 1 : lastFrameInFlight;
            
                 
            var["gElementCount"] = mLinkedListCounter[lastFrameInFlight];
            mCalcSampleDistribution->execute(pRenderContext, uint3(1,1,1));
        }

        if (mResetRayCount)
        {
            for (uint i = 0; i < lights.size(); i++)
            {
                pRenderContext->clearUAV(mSampleDistribution[i]->getUAV(mSampleDistribution[i]->getMipCount() - 1).get(), float4(mResolution.x * mResolution.y));
            }
            
            mResetRayCount = false;
        }

        var["CB"]["gCalcTotalDispatchCount"] = false;
        for (int m = mSampleDistribution[0]->getMipCount() - 2; m >= 0; m--)
        {
            
            for (uint i = 0; i < lights.size(); i++)
            {
                var["gImpt"][i].setSrv(mAccessTextures[i]->getSRV(m, 1u));
                var["gImptMip"][i].setSrv(mAccessTextures[i]->getSRV(m+1, 1u));
                var["gSmp"][i].setUav(mSampleDistribution[i]->getUAV(m));
                var["gSmpMip"][i].setSrv(mSampleDistribution[i]->getSRV(m + 1, 1u));
            }

            uint3 dispatchDim = uint3(mAccessTextures[0]->getWidth(m), mAccessTextures[0]->getHeight(m), lights.size());
            var["CB"]["gDstSize"] = dispatchDim.xy();
            

            mCalcSampleDistribution->execute(pRenderContext, dispatchDim);
        }
    }
    //Blur
    if(mBlurSampleDistribution)
    {
        if (!mpGaussianBlur)
            mpGaussianBlur = std::make_unique<SMGaussianBlur>(mpDevice);

        //TODO Maybe optimize so that all shaders execute the same step in parallel (e.g. an array version)
        for (uint i = 0; i < lights.size(); i++)
            mpGaussianBlur->execute(pRenderContext, mSampleDistribution[i]); 
    }
    //Optimize Samples
    if (mOptimizeSampleDistribution)
    {
        FALCOR_PROFILE(pRenderContext, "OptimizeDistributedSamples");
        // Create Compute Pass
        if (!mpOptimizeSamples)
        {
            Program::Desc desc;
            desc.addShaderLibrary(kOptimizeSamplesShader).csEntry("main").setShaderModel("6_6");

            DefineList defines;
            defines.add("COUNT_LIGHTS", std::to_string(lights.size()));
            defines.add("CLEAR_COUNTER", "1");

            mpOptimizeSamples = ComputePass::create(mpDevice, desc, defines, true);
        }
        auto var = mpOptimizeSamples->getRootVar();

        var["gCounter"] = mLinkedListCounter[frameInFlight];
        for (uint m = 1; m < mSampleDistribution[0]->getMipCount(); m++)
        {
            for (uint i = 0; i < lights.size(); i++)
            {
                var["gSampleDistribution0"][i].setUav(mSampleDistribution[i]->getUAV(m - 1,0,1));
                var["gSampleDistribution1"][i].setUav(mSampleDistribution[i]->getUAV(m,0,1));
            }
            uint3 dispatchDim = uint3(mAccessTextures[0]->getWidth(m), mAccessTextures[0]->getHeight(m), lights.size());
            var["CB"]["gDispatchSize"] = dispatchDim.xy();
            var["CB"]["gMipLevel"] = 0; // m - 1;
            var["CB"]["gLightCount"] = lights.size();

            mpOptimizeSamples->execute(pRenderContext, dispatchDim);            
        }
    }

    // Defines
    mGenLinkedListShadowPip.pProgram->addDefine("MAX_IDX", std::to_string(mResolution.x * mResolution.y * mApproxNumElementsPerPixel));
    mGenLinkedListShadowPip.pProgram->addDefine("MIDPOINT_PERCENTAGE", std::to_string(mMidpointPercentage));
    mGenLinkedListShadowPip.pProgram->addDefine("OPAQUE_HIT_RAY_DEPTH_BIAS", std::to_string(mOpaqueHitRayDepthBias));
    mGenLinkedListShadowPip.pProgram->addDefine("USE_COLOR_TRANSPARENCY", mUseColoredTransparency ? "1" : "0");
    mGenLinkedListShadowPip.pProgram->addDefine("ACCEL_BOXES_PIXEL_OFFSET", mAccelUsePCF ? "1.0" : "0.5");
    mGenLinkedListShadowPip.pProgram->addDefine("ACCEL_RAY_FLAGS", std::to_string((uint)mAccelRayFlags));
    mGenLinkedListShadowPip.pProgram->addDefine("SAMPLE_DIST_MIPS", std::to_string(mSampleDistribution[0]->getMipCount()));
    mGenLinkedListShadowPip.pProgram->addDefine("NUM_HALTON_SAMPLES", std::to_string(mNumHaltonSamples));
    mGenLinkedListShadowPip.pProgram->addDefine("USE_OPTIMIZED_SAMPLE_DISTRIBUTION", mOptimizeSampleDistribution ? "1" : "0");
    mGenLinkedListShadowPip.pProgram->addDefine("ACCEL_MERGE_BOX_DIST", std::to_string(mMergeBoxDist));
    mGenLinkedListShadowPip.pProgram->addDefine("USE_HALTON_SAMPLE_PATTERN", mSamplePattern == SMSamplePattern::Halton ? "1" : "0");
    mGenLinkedListShadowPip.pProgram->addDefine("USE_RANDOM_RANDOM_SOFT_SHADOWS", mEnableRandomSoftShadows ? "1" : "0");
    mGenLinkedListShadowPip.pProgram->addDefine("RANDOM_SOFT_SHADOWS_POS_RADIUS", std::to_string(mRandomSoftShadowsPositionRadius));
    

    //LOD
    bool useLOD = (mRayLodMode == TexLODMode::RayCones) || (mRayLodMode == TexLODMode::RayDiffs);
    mGenLinkedListShadowPip.pProgram->addDefine("USE_LOD", useLOD ? "1" : "0");
    mGenLinkedListShadowPip.pProgram->addDefine("SHADOW_LOD_MODE", std::to_string((uint)mRayLodMode));
    float2 invRenderDims = 1.f / float2(mResolution);
    mGenLinkedListShadowPip.pProgram->addDefine("INV_FRAME_DIM_X", std::to_string(invRenderDims.x));
    mGenLinkedListShadowPip.pProgram->addDefine("INV_FRAME_DIM_Y", std::to_string(invRenderDims.y));


    // Create Program Vars
    if (!mGenLinkedListShadowPip.pVars)
    {
        mGenLinkedListShadowPip.pProgram->addDefines(mpSampleGenerator->getDefines());
        mGenLinkedListShadowPip.pProgram->setTypeConformances(mpScene->getTypeConformances());
        mGenLinkedListShadowPip.pVars = RtProgramVars::create(mpDevice, mGenLinkedListShadowPip.pProgram, mGenLinkedListShadowPip.pBindingTable);
        mpSampleGenerator->setShaderData(mGenLinkedListShadowPip.pVars->getRootVar());
    }

    FALCOR_ASSERT(mGenLinkedListShadowPip.pVars);
    auto var = mGenLinkedListShadowPip.pVars->getRootVar();

    // Trace the pass for every light
    for (uint i = 0; i < lights.size(); i++)
    {
        if (!lights[i]->isActive())
            break;
        FALCOR_PROFILE(pRenderContext, lights[i]->getName());
        // Bind Utility
        bool isDirectional = lights[i]->getType() == LightType::Directional;

        var["CB"]["gFrameCount"] = mFrameCount;
        var["CB"]["gLightPos"] = mShadowMapMVP[i].pos;
        var["CB"]["gIsDirectional"] = isDirectional;
        var["CB"]["gLightDir"] = lights[i]->getData().dirW;
        var["CB"]["gFar"] = mNearFar.y;
        var["CB"]["gLightIdx"] = i;
        var["CB"]["gMipCount"] = mSampleDistribution[i]->getMipCount();
        var["CB"]["gSMRes"] = mResolution;
        var["CB"]["gViewProj"] = mShadowMapMVP[i].viewProjection;
        var["CB"]["gInvViewProj"] = mShadowMapMVP[i].invViewProjection;
        var["CB"]["gSpreadAngle"] = mShadowMapMVP[i].spreadAngle;

        var["gCounter"] = mLinkedListCounter[frameInFlight];
        var["gData"] = mLinkedListData[i];
        var["gPointSampler"] = mpPointSampler;
        var["gAccessCounter"] = mAccessTextures[i];
        var["gSampleDistribution"] = mSampleDistribution[i];
        var["gHaltonSamples"] = mpHaltonBuffer;

        // Get dimensions of ray dispatch.
        uint2 targetDim = mResolution;
        
        if (mOptimizeSampleDistribution)
        {
            targetDim = uint2(float2(targetDim) * mSampleOverestimate);
        }
               
        FALCOR_ASSERT(targetDim.x > 0 && targetDim.y > 0);

        // Spawn the rays.
        mpScene->raytrace(pRenderContext, mGenLinkedListShadowPip.pProgram.get(), mGenLinkedListShadowPip.pVars, uint3(targetDim, 1));

        mFrameCount++;
    }

    const uint numAABBs = lights.size();

    //Copy data from GPU to CPU counter
    {
        // Copy to CPU
        pRenderContext->copyBufferRegion(
            mLinkedListCounterCPU[mStagingCount].get(), 0, mLinkedListCounter[mStagingCount].get(), 0, sizeof(uint32_t) * numAABBs
        );
        pRenderContext->flush();
        // Frame in flight for the counter
        mCounterFenceWaitValues[mStagingCount] = mpFence->gpuSignal(pRenderContext->getLowLevelData()->getCommandQueue());
        mStagingCount = (mStagingCount + 1) % kFramesInFlight;

        uint64_t& fenceWaitVal = mCounterFenceWaitValues[mStagingCount];
        // Wait for the GPU to finish the frame
        mpFence->syncCpu(fenceWaitVal);

        void* data = mLinkedListCounterCPU[mStagingCount]->map(Buffer::MapType::Read);
        std::memcpy(mUIElementCounter.data(), data, sizeof(uint) * numAABBs);
        mLinkedListCounterCPU[mStagingCount]->unmap();
    }
}

DefineList LinkedListIrregularZ::getDefines()
{
    DefineList defines = {};
    defines.add(TransparencyShadowMethod::getDefines());
    defines.add("SHADOW_ACCEL_PCF", mAccelUsePCF ? "1" : "0");
    defines.add("USE_COLOR_TRANSPARENCY", mUseColoredTransparency ? "1" : "0");
    return defines;
}

void LinkedListIrregularZ::setShaderData(const ShaderVar& var)
{
    auto shadowVar = var["gLinkedListIrregularZ"];

    shadowVar["SMCB"]["gSMSize"] = mResolution;
    shadowVar["SMCB"]["gNear"] = mNearFar.x;
    shadowVar["SMCB"]["gFar"] = mNearFar.y;
    shadowVar["SMCB"]["gMipCount"] = mSampleDistribution[0]->getMipCount();
    shadowVar["SMCB"]["gMaxBufferSize"] = mLinkedListNodeBufferSize;
    

    auto& lights = mpScene->getLights();
    for (uint i = 0; i < lights.size(); i++)
    {
        shadowVar["ShadowVPs"]["gShadowMapVP"][i] = mShadowMapMVP[i].viewProjectionNoJitter;
        shadowVar["ShadowVPs"]["gStaggeredDirVP"] = mStaggeredDirectionalLightMVP.viewProjectionNoJitter;
        shadowVar["gAccessCounter"][i] = mAccessTextures[i];
    }
    const auto accelDataSize = lights.size();
    for (uint i = 0; i < accelDataSize; i++)
    {
        shadowVar["gSampleDistribution"][i] = mSampleDistribution[i];
        shadowVar["gLinkedListData"][i] = mLinkedListData[i];
    }

}

//TODO Some of the options should not be toggable for this pass as that will probably break the algorithm
bool LinkedListIrregularZ::renderUI(Gui::Widgets& widget)
{
    bool dirty = false;
    if (auto group = widget.group("Irregular LL Shadow Settings"))
    {
        dirty |= TransparencyShadowMethod::renderUI(widget);

        if (mpScene)
        {
            if (auto group2 = group.group("Current size info:"))
            {
                const auto loopSize = mpScene->getLightCount();
                for (uint i = 0; i < loopSize; i++)
                {
                    if (i > 0)
                        group2.separator();
                    group2.text(mpScene->getLight(i)->getName());
                    group2.text("Element Buffer Size:        " + std::to_string(mLinkedListNodeBufferSize));
                    std::string accelMem = std::to_string((mLinkedListNodeBufferSize * sizeof(float) * mLinkedListDataFormatSize) / 1e6f);
                    group2.text("Element Buffer Memory:     " + accelMem.substr(0, accelMem.find(".") + 3) + " MB");
                    group2.text(
                        "Used Elements: " + std::to_string(uint(mUIElementCounter[i]))
                    );
                    std::string neededMem = std::to_string(
                        (mUIElementCounter[i] * sizeof(float) * mLinkedListDataFormatSize) / 1e6f
                    );
                    std::string fillRate =
                        std::to_string(((mUIElementCounter[i]) / float(mLinkedListNodeBufferSize)) * 100.f);
                    group2.text(
                        "Used Element Buffer Memory:   " + neededMem.substr(0, neededMem.find(".") + 3) + " MB (" +
                        fillRate.substr(0, fillRate.find(".") + 2) + "%)"
                    );
                }
                group2.separator();
            }
        }

        mResolutionChanged |= group.var("Node Buffer size (Res x this)", mApproxNumElementsPerPixel, 1u, 32u, 1u);
        group.tooltip("Multiplier for the Node Data buffer.");

        mResetRayCount |= group.checkbox("Use GPU Sample Distribution opimization", mEnableDynamicRayCountCalc);
        if (mEnableDynamicRayCountCalc)
        {
            group.var("GPU SD Total Mult", mDynRCGuardPercentage, 0.001f, 1.f);
            group.tooltip("Multiplier for the total that is used to calculate the ray count for the current frame");
            group.var("GPU SD Change Mult", mDynRCChangePercentage, 0.001f, 1.f);
            group.tooltip("Multiplier for the change value in the Sample Distribution");
        }

        group.var("Generate only every X Frame", mSkipGenerationFrameCount, 1u, UINT_MAX);
        group.tooltip(
            "Number of generated frames is 1/X. Currently poorly optimized (No load distribution, every SM is generated in the same Frame)"
        );

        group.checkbox("Optimize Sample distribution", mOptimizeSampleDistribution);
        group.tooltip("Optimizes the sample distribution texture with an extra compute pass");
        if (mOptimizeSampleDistribution)
        {
            group.var("Sample Dispatch Overestimate", mSampleOverestimate, 1.0f, 4.f);
            group.tooltip("Overestimate for sample dispatch. SMRes * Overestimate");
        }
        group.checkbox("Blur Sample distribution", mBlurSampleDistribution);
        if (mBlurSampleDistribution && mpGaussianBlur)
        {
            if (auto gaussGroup = group.group("Blur Options"))
                mpGaussianBlur->renderUI(gaussGroup);
        }


        bool patternChanged = group.dropdown("Subpixel Sample Pattern", mSamplePattern);
        group.tooltip("Changes the Subpixel sample pattern for shadow map generation. Use the option below to change the box size");
        if (mSamplePattern == SMSamplePattern::Halton)
        {
            if (group.var("HaltonSamples", mNumHaltonSamples, 1u, 1024u, 1u))
                mGenLinkedListShadowPip.pVars.reset();
            group.tooltip("Number of Halton Samples");
        }
        else if (mSamplePattern != SMSamplePattern::Center)
        {
            patternChanged |= group.var("MatrixSamples", mNumCPUSampleGenSamples, 1u, 1024u, 1u);
        }
        if (patternChanged)
            updateSamplePattern();

        group.var("Midpoint Percentage", mMidpointPercentage, 0.f, 1.f, 0.001f);
        group.tooltip("Sets where the midpoint of the midpoint depth is set. 0.0 first depth, 1.0 second depth");
        group.var("OpaqueHitRayDepthBias", mOpaqueHitRayDepthBias, 1e-7f, FLT_MAX, 0.000001f, false, "%.7f");
        group.tooltip("Depth bias applied to tmin after a opaque hit. Scaled with pixel size. Normally 1e-7 is used");

        if (auto group2 = group.group("Stochastic Soft Shadows"))
        {
            group2.text("Info");
            group2.tooltip("Creates soft shadows by randomly offset the starting position or direction");
            group2.checkbox("Enable", mEnableRandomSoftShadows);
            if (mEnableRandomSoftShadows)
            {
                group2.var("Position offset (Spot/Point)", mRandomSoftShadowsPositionRadius, 0.f, FLT_MAX, 0.001f, false, "%.6f");
            }
        } 

        group.var("Merge Boxes Dist", mMergeBoxDist, 0.f, FLT_MAX, 0.000001f, false, "% .6f ");
        group.tooltip(
            "Merges Accel Boxes together and takes the transparency of the first box. Can add bias (brightening). \n Set to 0 to disable."
        );
    }

    return dirty;
}

static ref<CPUSampleGenerator> createSamplePattern(LinkedListIrregularZ::SMSamplePattern type, uint32_t sampleCount)
{
    switch (type)
    {
    case LinkedListIrregularZ::SMSamplePattern::Center:
    case LinkedListIrregularZ::SMSamplePattern::Halton:
        return nullptr;
    case LinkedListIrregularZ::SMSamplePattern::MatrixDirectX:
        return DxSamplePattern::create(sampleCount);
    case LinkedListIrregularZ::SMSamplePattern::MatrixHalton:
        return HaltonSamplePattern::create(sampleCount);
    case LinkedListIrregularZ::SMSamplePattern::MatrixStratified:
        return StratifiedSamplePattern::create(sampleCount);
    default:
        FALCOR_UNREACHABLE();
        return nullptr;
    }
}

void LinkedListIrregularZ::updateSamplePattern()
{
    mpCPUSampleGenerator = createSamplePattern(mSamplePattern, mNumCPUSampleGenSamples);
    if (mpCPUSampleGenerator)
        mNumCPUSampleGenSamples = mpCPUSampleGenerator->getSampleCount();
    else
        setJitter(float2(0)); // reset jitter
}
