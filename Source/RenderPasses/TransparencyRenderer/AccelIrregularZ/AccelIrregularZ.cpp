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
#include "AccelIrregularZ.h"
#include "Utils/Math/FalcorMath.h"
#include "Utils/SampleGenerators/DxSamplePattern.h"
#include "Utils/SampleGenerators/HaltonSamplePattern.h"
#include "Utils/SampleGenerators/StratifiedSamplePattern.h"

namespace
{
    //Shader Paths
    const std::string kShaderFolder = "RenderPasses/TransparencyRenderer/AccelIrregularZ/";
    const std::string kGenShader = kShaderFolder + "GenAccelIrregularZ.rt.slang";
    const std::string kAccessMipsShader = kShaderFolder + "GenAccessMips.cs.slang";
    const std::string kCalcSampleDistributionShader = kShaderFolder + "CalcSampleDistribution.cs.slang";
    const std::string kOptimizeSamplesShader = kShaderFolder + "OptimizeSamples.cs.slang";
    const std::string kShaderDebugShowShadowAccelRaster = kShaderFolder + "DebugShowShadowAccel.3d.slang";

    //UI
    const Gui::DropdownList kAccelDebugVisModes = {{0, "Transparency (Heatmap)"}, {1, "AABB index"}, {2, "Pixel"}, {3, "DepthPoints"}};
    const Gui::DropdownList kAccelDataFormat = {{1, "Uint"}, {2, "Uint2"}, {4, "Uint4"}};

}; // namespace

AccelIrregularZ::AccelIrregularZ(ref<Device> pDevice, ref<Scene> pScene) : TransparencyShadowMethod(pDevice, pScene)
{
    mpFence = GpuFence::create(mpDevice);
    FALCOR_ASSERT(mpFence);
    Sampler::Desc samplerDesc = {};
    samplerDesc.setFilterMode(Sampler::Filter::Linear, Sampler::Filter::Linear, Sampler::Filter::Linear);
    samplerDesc.setAddressingMode(Sampler::AddressMode::Clamp, Sampler::AddressMode::Clamp, Sampler::AddressMode::Clamp);
    mpLinearSampler = Sampler::create(mpDevice, samplerDesc);
    FALCOR_ASSERT(mpLinearSampler);
    samplerDesc.setFilterMode(Sampler::Filter::Point, Sampler::Filter::Point, Sampler::Filter::Point);
    mpPointSampler = Sampler::create(mpDevice, samplerDesc);
    FALCOR_ASSERT(mpPointSampler);

    mpSampleGenerator = SampleGenerator::create(mpDevice, SAMPLE_GENERATOR_UNIFORM);
    FALCOR_ASSERT(mpSampleGenerator);
}

void AccelIrregularZ::prepareResources(RenderContext* pRenderContext) {

    //This is triggered if either the resolution or number of lights changed
    if (mResolutionChanged)
    {
        mAccelShadowAABB.clear();
        mpShadowAccelerationStrucure.reset();
        mAccessTextures.clear();
        mSampleDistribution.clear();
        mpLastFrameMaxSampleCount.reset();
        //The following buffers need to be cleared when light count changes
        mAccelShadowCounter.clear();
        mAccelShadowCounterCPU.clear();
        mAccelFenceWaitValues.clear();
        mAccelShadowNumPoints.clear();
    }

    if ((mTransparencyBufferUsesColor != mUseColoredTransparency) || mResolutionChanged)
    {
        mAccelShadowData.clear();
        mTransparencyBufferUsesColor = mUseColoredTransparency;
    }

    //Set Jitter and update Matricies
    if (mpCPUSampleGenerator)
    {
        float2 jitter = mpCPUSampleGenerator->next();
        jitter *= 1.0f / float2(mResolution);
        setJitter(jitter);
    }
        

    updateSMMatrices();

    // Create AVSM trace program
    if (!mGenAccelShadowPip.pProgram)
    {
        RtProgram::Desc desc;
        desc.addShaderModules(mpScene->getShaderModules());
        desc.addShaderLibrary(kGenShader);
        desc.setMaxPayloadSize(32u); 
        desc.setMaxAttributeSize(mpScene->getRaytracingMaxAttributeSize());
        desc.setMaxTraceRecursionDepth(1u);

        mGenAccelShadowPip.pBindingTable = RtBindingTable::create(1, 1, mpScene->getGeometryCount());
        auto& sbt = mGenAccelShadowPip.pBindingTable;
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

        mGenAccelShadowPip.pProgram = RtProgram::create(mpDevice, desc, defines);
    }

    auto& lights = mpScene->getLights();

    // Create / Destroy resources
    {
        const uint numBuffers = lights.size();
        const uint numAccelBuffers = mUseOneAABBForAllLights ? 1 : lights.size();

        if (mAccelShadowAABB.empty())
        {
            mAccelShadowAABB.resize(numAccelBuffers);
            mAccelShadowMaxNumPoints = mResolution.x * mResolution.y * mAccelApproxNumElementsPerPixel;
            for (uint i = 0; i < numAccelBuffers; i++)
            {
                mAccelShadowAABB[i] = Buffer::createStructured(
                    mpDevice, sizeof(AABB), mResolution.x * mResolution.y * mAccelApproxNumElementsPerPixel,
                    ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess, Buffer::CpuAccess::None, nullptr, false
                );
                mAccelShadowAABB[i]->setName("AccelShadowAABB_" + std::to_string(i));
            }
        }
        // Counter
        if (mAccelShadowCounter.empty())
        {
            mAccelShadowCounter.resize(kFramesInFlight);
            mAccelShadowCounterCPU.resize(kFramesInFlight);
            mAccelFenceWaitValues.resize(kFramesInFlight);
            mAccelShadowNumPoints.resize(numAccelBuffers);

            std::vector<uint> initData(numAccelBuffers, 0);
            for (uint i = 0; i < kFramesInFlight; i++)
            {
                mAccelShadowCounter[i] = Buffer::createStructured(
                    mpDevice, sizeof(uint), numAccelBuffers, ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess,
                    Buffer::CpuAccess::None, initData.data(), false
                );
                mAccelShadowCounter[i]->setName("AccelShadowAABBCounter_" + std::to_string(i));

                mAccelShadowCounterCPU[i] = Buffer::createStructured(
                    mpDevice, sizeof(uint), numAccelBuffers, ResourceBindFlags::None, Buffer::CpuAccess::Read, &initData, false
                );
                mAccelShadowCounterCPU[i]->setName("AccelShadowAABBCounterCPU_" + std::to_string(i));

                mAccelFenceWaitValues[i] = 0;
            }

            for (uint i = 0; i < numAccelBuffers; i++)
                mAccelShadowNumPoints[i] = mResolution.x * mResolution.y * mAccelApproxNumElementsPerPixel;
        }
        if (mAccelShadowData.empty())
        {
            mAccelShadowData.resize(numAccelBuffers);
            uint dataSize = mUseColoredTransparency ? 3 : 1;
            dataSize *= sizeof(float);
            for (uint i = 0; i < numAccelBuffers; i++)
            {
                mAccelShadowData[i] = Buffer::createStructured(
                    mpDevice, dataSize , mResolution.x * mResolution.y * mAccelApproxNumElementsPerPixel,
                    ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess, Buffer::CpuAccess::None, nullptr, false
                );       
                mAccelShadowData[i]->setName("AccelShadowData" + std::to_string(i));
            }
        }

        if (!mpShadowAccelerationStrucure)
        {
            std::vector<uint64_t> aabbCount;
            std::vector<uint64_t> aabbGPUAddress;
            for (uint i = 0; i < numAccelBuffers; i++)
            {
                aabbCount.push_back(mResolution.x * mResolution.y * mAccelApproxNumElementsPerPixel);
                aabbGPUAddress.push_back(mAccelShadowAABB[i]->getGpuAddress());
            }
            //Note: TLAS update is slightly faster (~0.02 ms) even though rebuild is usally recommended. Tracing times do not change between toggeling the update mode
            mpShadowAccelerationStrucure = std::make_unique<CustomAccelerationStructure>(
                mpDevice, aabbCount, aabbGPUAddress, CustomAccelerationStructure::BuildMode::None,
                CustomAccelerationStructure::UpdateMode::TLASOnly
            );
            mpShadowAccelerationStrucure->setMinBLASUpdateCount(kMinAABBUpdateCount);
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
                mAccessTextures[i]->setName("AccessTextureLight" + std::to_string(i));
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
                mSampleDistribution[i]->setName("SampleDistribution" + std::to_string(i));
            }
        }

        if (!mpLastFrameMaxSampleCount)
        {
            std::vector<uint> initData(numBuffers,0);
            mpLastFrameMaxSampleCount = Buffer::create(
                mpDevice, sizeof(uint) * numBuffers, ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess,
                Buffer::CpuAccess::None, initData.data()
            );
            mpLastFrameMaxSampleCount->setName("LastFrameMaxSampleDistribution");
        }

        if (!mpHaltonBuffer || mpHaltonBuffer->getElementCount() != mNumHaltonSamples)
        {
            //Generate Halton Samples on CPU
            auto haltonSampler = HaltonSamplePattern::create(mNumHaltonSamples);
            std::vector<float2> haltonInitData(mNumHaltonSamples);
            for (uint i = 0; i < mNumHaltonSamples; i++)
                haltonInitData[i] = haltonSampler->next() + 0.5f; //Halton samples are in [-0.5, 0.5) but we want the samples in [0,1)

            //Create and upload GPU buffer
            mpHaltonBuffer = Buffer::createTyped<float2>(
                mpDevice, mNumHaltonSamples, ResourceBindFlags::ShaderResource, Buffer::CpuAccess::None, haltonInitData.data()
            );
            mpHaltonBuffer->setName("HaltonDataBuffer");
        }
    }
}

std::array<float4, 4> AccelIrregularZ::getCameraFrustumPlanes()
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

void AccelIrregularZ::dummyProfileGeneration(RenderContext* pRenderContext) {
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
    {
        FALCOR_PROFILE(pRenderContext, "ClearAccelAABBBuffers");
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
    {
        FALCOR_PROFILE(pRenderContext, "buildCustomBlas");
    }
    {
        FALCOR_PROFILE(pRenderContext, "buildCustomTlas");
    }
}

void AccelIrregularZ::generate(RenderContext* pRenderContext, const RenderData& renderData)
{
    FALCOR_PROFILE(pRenderContext, "GenerateShadowAccelerationStructure");

    prepareResources(pRenderContext);

    // Abort early if disabled
    bool skipGeneration = (mSkipFrameCount % mSkipGenerationFrameCount) != 0;
    mSkipFrameCount++;
    if ((mAccelDebugShowAS.enable && mAccelDebugShowAS.stopGeneration) || skipGeneration)
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

    auto& lights = mpScene->getLights();
    uint frameInFlight = mStagingCount; // For sync if optimization is used

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

        //One pass to cap the lowest mip at a max value
        {
            auto var = mGenAccessMips->getRootVar();
            for (uint i = 0; i < lights.size(); i++)
                var["gDst"][i].setUav(mAccessTextures[i]->getUAV(0));
            uint3 dispatchDim = uint3(mAccessTextures[0]->getWidth(0), mAccessTextures[0]->getHeight(0), lights.size());
            var["CB"]["gDstSize"] = dispatchDim.xy();
            var["CB"]["gCapLowestLevel"] = true;

            mGenAccessMips->execute(pRenderContext, dispatchDim);
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
            var["CB"]["gCapLowestLevel"] = false;

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
            defines.add("USE_ONE_BUFFER_FOR_ALL_LIGHTS", mUseOneAABBForAllLights ? "1" : "0");

            mCalcSampleDistribution = ComputePass::create(mpDevice, desc, defines, true);
        }

        //Calc ray count dispatch
        auto var = mCalcSampleDistribution->getRootVar();
        mCalcSampleDistribution->getProgram()->addDefine(
            "MAX_SAMPLES", std::to_string(mResolution.x * mResolution.y) 
        );
        mCalcSampleDistribution->getProgram()->addDefine("USE_ONE_BUFFER_FOR_ALL_LIGHTS", mUseOneAABBForAllLights ? "1" : "0");

        if (mEnableDynamicRayCountCalc && mFrameCount > 0)
        {
            //Get mip level
            uint mip = mSampleDistribution[0]->getMipCount() - 1;
            var["CB"]["gCalcTotalDispatchCount"] = true;
            var["CB"]["gMaxNumAABBs"] = int(mResolution.x * mResolution.y * mAccelApproxNumElementsPerPixel * mDynRCGuardPercentage);
            var["CB"]["gChangePercentageIncrease"] = mDynRCChangePercentage.x; 
            var["CB"]["gChangePercentageDecrease"] = mDynRCChangePercentage.y; 
            var["CB"]["gMaxSampleOverestimate"] = mSampleOverestimate * mSampleOverestimate; //Squared as this is applied to x and y of dispatch resolution

            var["gLastFrameSampleCount"] = mpLastFrameMaxSampleCount;
            for (uint i = 0; i < lights.size(); i++)
            {
                var["gImpt"][i].setSrv(mAccessTextures[i]->getSRV(mip, 1u));
                var["gSmp"][i].setUav(mSampleDistribution[i]->getUAV(mip));
            }
            int lastFrameInFlight = 0;
            lastFrameInFlight = mStagingCount - 1;
            lastFrameInFlight = lastFrameInFlight < 0 ? kFramesInFlight - 1 : lastFrameInFlight;
                             
            var["gElementCount"] = mAccelShadowCounter[lastFrameInFlight];
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

            mpOptimizeSamples = ComputePass::create(mpDevice, desc, defines, true);
        }
        auto var = mpOptimizeSamples->getRootVar();

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

    // Clear Counter
    uint clearSize = mUseOneAABBForAllLights ? 1 : lights.size();
    pRenderContext->clearUAV(mAccelShadowCounter[frameInFlight]->getUAV(0u, clearSize).get(), uint4(0));

    // Defines
    mGenAccelShadowPip.pProgram->addDefine("MAX_IDX", std::to_string(mResolution.x * mResolution.y * mAccelApproxNumElementsPerPixel));
    mGenAccelShadowPip.pProgram->addDefine("MIDPOINT_PERCENTAGE", std::to_string(mMidpointPercentage));
    mGenAccelShadowPip.pProgram->addDefine("OPAQUE_HIT_RAY_DEPTH_BIAS", std::to_string(mOpaqueHitRayDepthBias));
    mGenAccelShadowPip.pProgram->addDefine("USE_COLOR_TRANSPARENCY", mUseColoredTransparency ? "1" : "0");
    mGenAccelShadowPip.pProgram->addDefine("ACCEL_BOXES_PIXEL_OFFSET", mAccelUsePCF ? "1.0" : "0.5");
    mGenAccelShadowPip.pProgram->addDefine("ACCEL_USE_FRUSTUM_CULLING", mAccelUseFrustumCulling ? "1" : "0");
    mGenAccelShadowPip.pProgram->addDefine("SAMPLE_DIST_MIPS", std::to_string(mSampleDistribution[0]->getMipCount()));
    mGenAccelShadowPip.pProgram->addDefine("NUM_HALTON_SAMPLES", std::to_string(mNumHaltonSamples));
    mGenAccelShadowPip.pProgram->addDefine("USE_OPTIMIZED_SAMPLE_DISTRIBUTION", mOptimizeSampleDistribution ? "1" : "0");
    mGenAccelShadowPip.pProgram->addDefine("USE_ONE_AABB_BUFFER_FOR_ALL_LIGHTS", mUseOneAABBForAllLights ? "1" : "0");
    mGenAccelShadowPip.pProgram->addDefine("USE_HALTON_SAMPLE_PATTERN", mSamplePattern == SMSamplePattern::Halton ? "1" : "0");
    mGenAccelShadowPip.pProgram->addDefine("USE_RANDOM_RANDOM_SOFT_SHADOWS", mEnableRandomSoftShadows ? "1" : "0");
    mGenAccelShadowPip.pProgram->addDefine("RANDOM_SOFT_SHADOWS_POS_RADIUS", std::to_string(mRandomSoftShadowsPositionRadius));
    mGenAccelShadowPip.pProgram->addDefine("RANDOM_SOFT_SHADOWS_DIR_SPREAD", std::to_string(mRandomSoftShadowsDirSpread));
    mGenAccelShadowPip.pProgram->addDefine("STORE_LIMITED_OPAQUE_SURFACES", mOpaqueShadowMapEnabled ? "1" : "0");
    mGenAccelShadowPip.pProgram->addDefine("TRACE_NON_OPAQUE_ONLY", mUseMask ? "1" : "0"); //Trace non-opaque only if mask is used
    
    //LOD
    bool useLOD = (mRayLodMode == TexLODMode::RayCones) || (mRayLodMode == TexLODMode::RayDiffs);
    mGenAccelShadowPip.pProgram->addDefine("USE_LOD", useLOD ? "1" : "0");
    mGenAccelShadowPip.pProgram->addDefine("SHADOW_LOD_MODE", std::to_string((uint)mRayLodMode));
    float2 invRenderDims = 1.f / float2(mResolution);
    mGenAccelShadowPip.pProgram->addDefine("INV_FRAME_DIM_X", std::to_string(invRenderDims.x));
    mGenAccelShadowPip.pProgram->addDefine("INV_FRAME_DIM_Y", std::to_string(invRenderDims.y));


    // Create Program Vars
    if (!mGenAccelShadowPip.pVars)
    {
        mGenAccelShadowPip.pProgram->addDefines(mpSampleGenerator->getDefines());
        mGenAccelShadowPip.pProgram->setTypeConformances(mpScene->getTypeConformances());
        mGenAccelShadowPip.pVars = RtProgramVars::create(mpDevice, mGenAccelShadowPip.pProgram, mGenAccelShadowPip.pBindingTable);
        mpSampleGenerator->setShaderData(mGenAccelShadowPip.pVars->getRootVar());
    }

    FALCOR_ASSERT(mGenAccelShadowPip.pVars);
    auto var = mGenAccelShadowPip.pVars->getRootVar();

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

        var["gAABB"] = mUseOneAABBForAllLights ? mAccelShadowAABB[0] : mAccelShadowAABB[i];
        var["gCounter"] = mAccelShadowCounter[frameInFlight];
        var["gData"] = mUseOneAABBForAllLights ? mAccelShadowData[0] : mAccelShadowData[i];
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
        mpScene->raytrace(pRenderContext, mGenAccelShadowPip.pProgram.get(), mGenAccelShadowPip.pVars, uint3(targetDim, 1));

        mFrameCount++;
    }

    const uint numAABBs = mUseOneAABBForAllLights ? 1 : lights.size();

    //Copy Counter from GPU to CPU
    {
        // Copy to CPU
        pRenderContext->copyBufferRegion(
            mAccelShadowCounterCPU[mStagingCount].get(), 0, mAccelShadowCounter[mStagingCount].get(), 0, sizeof(uint32_t) * numAABBs
        );

        // Frame in flight for the counter
        mAccelFenceWaitValues[mStagingCount] = mpFence->gpuSignal(pRenderContext->getLowLevelData()->getCommandQueue());
        mStagingCount = (mStagingCount + 1) % kFramesInFlight;

        uint64_t& fenceWaitVal = mAccelFenceWaitValues[mStagingCount];
        // Wait for the GPU to finish the frame
        mpFence->syncCpu(fenceWaitVal);

        void* data = mAccelShadowCounterCPU[mStagingCount]->map(Buffer::MapType::Read);
        std::memcpy(mAccelShadowNumPoints.data(), data, sizeof(uint) * numAABBs);
        mAccelShadowCounterCPU[mStagingCount]->unmap();
    }

    // Clear unused AABBs
    mpShadowAccelerationStrucure->clearAABBBuffers(pRenderContext, mAccelShadowAABB, true, mAccelShadowCounter[frameInFlight]);

    // Build the Acceleration structure
    std::vector<uint64_t> aabbCount;
    uint totalCount = 0;
    for (uint i = 0; i < numAABBs && mAccelShadowUseCPUCounterOptimization; i++)
        totalCount += mAccelShadowNumPoints[i];

    for (uint i = 0; i < numAABBs; i++)
    {
        uint numPoints = mAccelShadowMaxNumPoints;
        if (mAccelShadowUseCPUCounterOptimization)
        {
            float diffPercentage = ((mAccelShadowMaxNumPoints - mAccelShadowNumPoints[i]) / mAccelShadowMaxNumPoints);
            uint maxPossibleCount = diffPercentage > 0.0 && mEnableDynamicRayCountCalc
                                        ? uint(totalCount * diffPercentage * mDynRCChangePercentage.y)
                                        : 0.25f * mAccelShadowMaxNumPoints;
            numPoints = std::min(uint(mAccelShadowNumPoints[i] + maxPossibleCount), mAccelShadowMaxNumPoints);
        }
        aabbCount.push_back(numPoints);
    }
    mpShadowAccelerationStrucure->update(pRenderContext, aabbCount);
}

DefineList AccelIrregularZ::getDefines()
{
    DefineList defines = {};
    defines.add(TransparencyShadowMethod::getDefines());
    defines.add("USE_COLOR_TRANSPARENCY", mUseColoredTransparency ? "1" : "0");
    defines.add("SHADOW_ACCEL_PCF", mAccelUsePCF ? "1" : "0");
    defines.add("ACCEL_USE_RAY_INLINE", mAccelUseRayTracingInline ? "1" : "0");
    defines.add("ACCEL_USE_ONE_AABB_FOR_ALL_LIGHTS", mUseOneAABBForAllLights ? "1" : "0");
    return defines;
}

void AccelIrregularZ::setShaderData(const ShaderVar& var)
{
    auto shadowVar = var["gAccelIrregularZ"];

    shadowVar["SMCB"]["gSMSize"] = mResolution;
    shadowVar["SMCB"]["gNear"] = mNearFar.x;
    shadowVar["SMCB"]["gFar"] = mNearFar.y;

    auto& lights = mpScene->getLights();
    for (uint i = 0; i < lights.size(); i++)
    {
        shadowVar["ShadowVPs"]["gShadowMapVP"][i] = mShadowMapMVP[i].viewProjectionNoJitter;
        shadowVar["ShadowVPs"]["gStaggeredDirVP"] = mStaggeredDirectionalLightMVP.viewProjectionNoJitter;
        shadowVar["gAccessCounter"][i] = mAccessTextures[i];
    }
    const auto accelDataSize = mUseOneAABBForAllLights ? 1 : lights.size();
    for (uint i = 0; i < accelDataSize; i++)
    {
        shadowVar["gAccelShadowData"][i] = mAccelShadowData[i];
        shadowVar["gShadowAABBs"][i] = mAccelShadowAABB[i];
    }

    shadowVar["gPointSampler"] = mpPointSampler;
    shadowVar["gLinearSampler"] = mpLinearSampler;

    mpShadowAccelerationStrucure->bindTlas(shadowVar, "gShadowAS");
}

void AccelIrregularZ::setShadowMask(const ShaderVar& var, ref<Texture> maskTex, ref<Texture> maskSM, bool enable)
{
    mUseMask = enable;
    if (mUseMask)
    {
        auto shadowVar = var["gAccelIrregularZ"];

        shadowVar["gShadowMask"] = maskTex;
        shadowVar["gMaskShadowMap"] = maskSM;
    }
}

bool AccelIrregularZ::renderUI(Gui::Widgets& widget)
{
    bool dirty = false;
    if (auto group = widget.group("Accel Shadow Settings"))
    {
        dirty |= TransparencyShadowMethod::renderUI(widget);

        if (mpScene)
        {
            if (auto group2 = group.group("Current size info:"))
            {
                const auto loopSize = mUseOneAABBForAllLights ? 1 : mpScene->getLightCount();
                for (uint i = 0; i < loopSize; i++)
                {
                    if (i > 0)
                        group2.separator();
                    uint dataBufferSize = mUseColoredTransparency ? 12u : 4u;
                    group2.text(mUseOneAABBForAllLights ? "Total" : mpScene->getLight(i)->getName());
                    group2.text("Buffer Size:        " + std::to_string(mAccelShadowMaxNumPoints));
                    std::string accelMem = std::to_string((mAccelShadowMaxNumPoints * sizeof(AABB)) / 1e6f);
                    std::string dataMem = std::to_string((mAccelShadowMaxNumPoints * dataBufferSize) / 1e6f);
                    std::string totalMem = std::to_string((mAccelShadowMaxNumPoints * dataBufferSize * sizeof(AABB)) / 1e6f);
                    group2.text("AABB Memory:     " + accelMem.substr(0, accelMem.find(".") + 3) + " MB");
                    group2.text("Data Memory:     " + dataMem.substr(0, dataMem.find(".") + 3) + " MB");
                    group2.text("Total Memory:    " + totalMem.substr(0, totalMem.find(".") + 3) + " MB");

                    group2.text("Used Elements:    " + std::to_string(uint(mAccelShadowNumPoints[i])));
                    std::string neededAABBMem = std::to_string((mAccelShadowNumPoints[i] * sizeof(AABB)) / 1e6f);
                    std::string neededDataMem = std::to_string((mAccelShadowNumPoints[i] * dataBufferSize) / 1e6f);
                    std::string neededTotalMem = std::to_string((mAccelShadowNumPoints[i] * dataBufferSize * sizeof(AABB)) / 1e6f);
                    std::string fillRate =
                        std::to_string(((mAccelShadowNumPoints[i]) / float(mAccelShadowMaxNumPoints)) * 100.f);
                    group2.text("Used AABB Memory:   " + neededAABBMem.substr(0, neededAABBMem.find(".") + 3) + " MB" );
                    group2.text("Used Data Memory:   " + neededDataMem.substr(0, neededDataMem.find(".") + 3) + " MB");
                    group2.text(
                        "Used Total Memory:   " + neededTotalMem.substr(0, neededTotalMem.find(".") + 3) + " MB (" +
                        fillRate.substr(0, fillRate.find(".") + 2) + "%)"
                    );

                }
                group2.separator();
            }
        }

        mResolutionChanged |= group.var("AABB size (Res x this)", mAccelApproxNumElementsPerPixel, 1u, 32u, 1u);
        group.tooltip("Multiplier for the AABB buffer size.");

        mResolutionChanged |= group.checkbox("Use one AABB for all lights", mUseOneAABBForAllLights); //Should trigger rebuild of all buffers
        group.tooltip("Uses one AABB for all lights. Light coordinates are put side by side on the x axis");

        mResetRayCount |= group.checkbox("Use GPU Sample Distribution opimization", mEnableDynamicRayCountCalc);
        if (mEnableDynamicRayCountCalc)
        {
            group.var("GPU SD Fill Guard", mDynRCGuardPercentage, 0.001f, 1.f);
            group.tooltip("Buffer should be held around this fill percentage. ");
            group.var("GPU SD Change Mult (Increase/Decrease)", mDynRCChangePercentage, 0.001f, 1.f);
            group.tooltip(
                "Multiplier for the change value in the Sample Distribution. There is a different value for increase and decrease. "
                "Increase should be handled more conserveratively, while the decrease should be quiet aggressive"
            );
        }

        group.var("Generate only every X Frame", mSkipGenerationFrameCount, 1u, UINT_MAX);
        group.tooltip("Number of generated frames is 1/X. Currently poorly optimized (No load distribution, every SM is generated in the same Frame)");

        group.checkbox("Use Element Counter to fit Accelertation Structure", mAccelShadowUseCPUCounterOptimization);
        group.tooltip("Uses the CPU counter value from a previous frame (async) to estimate the acceleration structure build size. Only recommended if there are multiple AABB buffers that are empty or partially filled");
       
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


        //group.checkbox("Use Frustum Culling", mAccelUseFrustumCulling);
        //group.tooltip("Uses Frustum Culling to reject the storage of the Accel SM samples");

        bool patternChanged = group.dropdown("Subpixel Sample Pattern", mSamplePattern);
        group.tooltip("Changes the Subpixel sample pattern for shadow map generation. Use the option below to change the box size");
        if (mSamplePattern == SMSamplePattern::Halton)
        {
            if (group.var("HaltonSamples", mNumHaltonSamples, 1u, 1024u, 1u))
                mGenAccelShadowPip.pVars.reset();
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

        group.checkbox("Use Inline RayTracing", mAccelUseRayTracingInline);
        group.tooltip("Only uses the Visibility of the sample with the closest depth. If disabled, the average of all hit Boxes is used");
        if (auto group2 = group.group("Debug"))
        {
            group2.checkbox("Enable", mAccelDebugShowAS.enable);
            if (mAccelDebugShowAS.enable && mpScene)
            {
                if (mpScene->getLightCount() > 1 && !mUseOneAABBForAllLights)
                    group2.slider("Selected Light", mAccelDebugShowAS.selectedLight, 0u, mpScene->getLightCount() - 1);
                group2.var("Clip X", mAccelDebugShowAS.clipX, 0.f, float(mResolution.x), 0.1f);
                group2.var("Clip Y", mAccelDebugShowAS.clipY, 0.f, float(mResolution.y), 0.1f);
                group2.var("Clip Z", mAccelDebugShowAS.clipZ, -FLT_MAX, FLT_MAX, 0.1f);

                group2.var("Blend with Output", mAccelDebugShowAS.blendT, 0.f, 1.f, 0.001f);
                if (group2.dropdown("Mode", kAccelDebugVisModes, mAccelDebugShowAS.visMode))
                    mAccelDebugShowAS.stopGeneration = mAccelDebugShowAS.visMode == 1 ? true : mAccelDebugShowAS.stopGeneration;
                group2.checkbox("Stop Generation", mAccelDebugShowAS.stopGeneration);
                mUpdateDirectional = !mAccelDebugShowAS.stopGeneration;
            }
        }
    }

    return dirty;
}

void AccelIrregularZ::debugPass(RenderContext* pRenderContext,const RenderData& renderData, ref<Texture> debugOut,  ref<Texture> colorOut)
{
    // Early return if disabled
    if (!mAccelDebugShowAS.enable)
        return;

    FALCOR_PROFILE(pRenderContext, "ShowAccel");

    const uint2 dims = renderData.getDefaultTextureDims();
    if (!mpDebugDepth || math::any(uint2(mpDebugDepth->getWidth(), mpDebugDepth->getHeight()) != dims))
    {
        mpDebugDepth =
            Texture::create2D(mpDevice, dims.x, dims.y, ResourceFormat::D32Float, 1u, 1u, nullptr, ResourceBindFlags::DepthStencil);
        mpDebugDepth->setName("DebugRasterDepth");
    }

    // Init Program
    if (!mRasterShowAccelPass.pProgram)
    {
        // Init program
        Program::Desc desc;
        desc.addShaderLibrary(kShaderDebugShowShadowAccelRaster).vsEntry("vsMain").psEntry("psMain").gsEntry("gsMain");
        desc.setShaderModel("6_6");

        auto defines = mpScene->getSceneDefines();
        defines.add("USE_COLOR_TRANSPARENCY", mUseColoredTransparency ? "1" : "0");
        defines.add("USE_ONE_AABB_FOR_ALL", mUseOneAABBForAllLights ? "1" : "0");
        defines.add("COUNT_LIGHTS", std::to_string(mpScene->getLightCount()));
        // Create Program and state
        mRasterShowAccelPass.pProgram = GraphicsProgram::create(mpDevice, desc, defines);
        mRasterShowAccelPass.pState = GraphicsState::create(mpDevice);

        // Set state
        mRasterShowAccelPass.pState->setProgram(mRasterShowAccelPass.pProgram);
        mRasterShowAccelPass.pState->setVao(Vao::create(Vao::Topology::PointList));

        // Set raster state
        RasterizerState::Desc rsDesc;
        rsDesc.setCullMode(RasterizerState::CullMode::None);
        rsDesc.setFillMode(RasterizerState::FillMode::Solid);
        mRasterShowAccelPass.pState->setRasterizerState(RasterizerState::create(rsDesc));

        mRasterShowAccelPass.pFBO = Fbo::create(mpDevice);
    }

    // Set draw target
    mRasterShowAccelPass.pFBO->attachColorTarget(debugOut, 0);
    mRasterShowAccelPass.pFBO->attachDepthStencilTarget(mpDebugDepth);
    pRenderContext->clearFbo(mRasterShowAccelPass.pFBO.get(), float4(0, 0, 0, 1), 1.0, 0);
    mRasterShowAccelPass.pState->setFbo(mRasterShowAccelPass.pFBO);

    // Runtime Defines
    mRasterShowAccelPass.pProgram->addDefine("USE_COLOR_TRANSPARENCY", mUseColoredTransparency ? "1" : "0");
    mRasterShowAccelPass.pProgram->addDefine("USE_ONE_AABB_FOR_ALL", mUseOneAABBForAllLights ? "1" : "0");

    // Vars
    if (!mRasterShowAccelPass.pVars)
        mRasterShowAccelPass.pVars = GraphicsVars::create(mpDevice, mRasterShowAccelPass.pProgram.get());

    uint frameInFlight = 0;
    // Staging count was increased at the end of the generation code, so take one less
    frameInFlight = mStagingCount == 0 ? kFramesInFlight - 1 : mStagingCount - 1;

    //Get index of directional light if the scene contains it
    uint directionalIndex = UINT_MAX;
    auto& lights = mpScene->getLights();
    for (uint i = 0; i <lights.size(); i++)
    {
        if (lights[i]->getType() == LightType::Directional)
        {
            directionalIndex = i;
            break;
        }
    }

    auto var = mRasterShowAccelPass.pVars->getRootVar();

    var["gScene"] = mpScene->getParameterBlock();
    var["CB"]["gSMSize"] = mResolution;
    var["CB"]["gNear"] = mNearFar.x;
    var["CB"]["gFar"] = mNearFar.y;
    var["CB"]["gSelectedLight"] = mUseOneAABBForAllLights ? 0 : mAccelDebugShowAS.selectedLight;
    var["CB"]["gCullMin"] = float3(mAccelDebugShowAS.clipX.x, mAccelDebugShowAS.clipY.x, mAccelDebugShowAS.clipZ.x);
    var["CB"]["gCullMax"] = float3(mAccelDebugShowAS.clipX.y, mAccelDebugShowAS.clipY.y, mAccelDebugShowAS.clipZ.y);
    var["CB"]["gBlendT"] = mAccelDebugShowAS.blendT;
    var["CB"]["gVisMode"] = mAccelDebugShowAS.visMode;
    var["CB"]["gDirectionalIdx"] = directionalIndex;

    //Set the viewProj matrices
    for (uint i = 0; i < mpScene->getLightCount(); i++)
    {
        var["LightMatrices"]["gInvView"][i] = mShadowMapMVP[i].invView;
        var["LightMatrices"]["gInvProj"][i] = mShadowMapMVP[i].invProjection;
        var["InvViewProjections"]["gInvViewProj"][i] = mShadowMapMVP[i].invViewProjection;
    }

    var["gShadowAABB"] = mAccelShadowAABB[mAccelDebugShowAS.selectedLight];
    var["gShadowCounter"] = mAccelShadowCounter[frameInFlight];
    var["gShadowData"] = mAccelShadowData[mAccelDebugShowAS.selectedLight];
    var["gOutputColor"] = colorOut; // For blending

    pRenderContext->draw(mRasterShowAccelPass.pState.get(), mRasterShowAccelPass.pVars.get(), mAccelShadowMaxNumPoints, 0);
}

static ref<CPUSampleGenerator> createSamplePattern(AccelIrregularZ::SMSamplePattern type, uint32_t sampleCount)
{
    switch (type)
    {
    case AccelIrregularZ::SMSamplePattern::Center:
    case AccelIrregularZ::SMSamplePattern::Halton:
        return nullptr;
    case AccelIrregularZ::SMSamplePattern::MatrixDirectX:
        return DxSamplePattern::create(sampleCount);
    case AccelIrregularZ::SMSamplePattern::MatrixHalton:
        return HaltonSamplePattern::create(sampleCount);
    case AccelIrregularZ::SMSamplePattern::MatrixStratified:
        return StratifiedSamplePattern::create(sampleCount);
    default:
        FALCOR_UNREACHABLE();
        return nullptr;
    }
}

void AccelIrregularZ::updateSamplePattern() {
    mpCPUSampleGenerator = createSamplePattern(mSamplePattern, mNumCPUSampleGenSamples);
    if (mpCPUSampleGenerator)
        mNumCPUSampleGenSamples = mpCPUSampleGenerator->getSampleCount();
    else
        setJitter(float2(0)); //reset jitter
}

