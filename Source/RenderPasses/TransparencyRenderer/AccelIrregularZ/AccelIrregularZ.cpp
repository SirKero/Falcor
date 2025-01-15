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
#include "Utils/SampleGenerators/HaltonSamplePattern.h"

namespace
{
    //Shader Paths
    const std::string kShaderFolder = "RenderPasses/TransparencyRenderer/AccelIrregularZ/";
    const std::string kGenShader = kShaderFolder + "GenAccelIrregularZ.rt.slang";
    const std::string kAccessMipsShader = kShaderFolder + "GenAccessMips.cs.slang";
    const std::string kCalcSampleDistributionShader = kShaderFolder + "CalcSampleDistribution.cs.slang";
    const std::string kDistributeSamplesShader = kShaderFolder + "DistributeSamples.cs.slang";
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
    samplerDesc.setFilterMode(Sampler::Filter::Point, Sampler::Filter::Point, Sampler::Filter::Point);
    samplerDesc.setAddressingMode(Sampler::AddressMode::Clamp, Sampler::AddressMode::Clamp, Sampler::AddressMode::Clamp);
    mpPointSampler = Sampler::create(mpDevice, samplerDesc);
    FALCOR_ASSERT(mpPointSampler);
}

void AccelIrregularZ::prepareResources(RenderContext* pRenderContext) {

    //This is triggered if either the resolution or number of lights changed
    if (mResolutionChanged)
    {
        mAccelShadowAABB.clear();
        mpShadowAccelerationStrucure.reset();
        mAccessTextures.clear();
        mSampleDistribution.clear();
        mPixelSample.clear();
        mpPixelSampleCounter.reset();
        //The following buffers need to be cleared when light count changes
        mAccelShadowCounter.clear();
        mAccelShadowCounterCPU.clear();
        mAccelFenceWaitValues.clear();
        mAccelShadowNumPoints.clear();
    }

    if (mRebuildAccelDataBuffer || mResolutionChanged)
    {
        mAccelShadowData.clear();
        mRebuildAccelDataBuffer = false;
    }

    updateSMMatrices(pRenderContext);

    // Create AVSM trace program
    if (!mGenAccelShadowPip.pProgram)
    {
        RtProgram::Desc desc;
        desc.addShaderModules(mpScene->getShaderModules());
        desc.addShaderLibrary(kGenShader);
        desc.setMaxPayloadSize(16u); //
                                     //(4) + align(4)
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
        defines.add("SHADOW_DATA_FORMAT_SIZE", std::to_string(mAccelDataFormatSize));
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
            for (uint i = 0; i < numAccelBuffers; i++)
            {
                mAccelShadowData[i] = Buffer::createStructured(
                    mpDevice, sizeof(uint) * mAccelDataFormatSize, mResolution.x * mResolution.y * mAccelApproxNumElementsPerPixel,
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
            mpShadowAccelerationStrucure->clearAABBBuffers(pRenderContext, mAccelShadowAABB);
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

        uint pixelSamplesSize = uint(mResolution.x * mResolution.y * mSampleOverestimate);
        if (mPixelSample.empty() || mPixelSample[0]->getElementCount() < pixelSamplesSize)
        {
            mPixelSample.resize(numBuffers);
            for (uint i = 0; i < numBuffers; i++)
            {
                mPixelSample[i] = Buffer::createStructured(
                    mpDevice, sizeof(uint4), pixelSamplesSize,
                    ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess, Buffer::CpuAccess::None, nullptr, false
                );
                mPixelSample[i]->setName("PixelSampleBuf" + std::to_string(i));
            }
        }
        if (!mpPixelSampleCounter)
        {
            std::vector<uint> initData(numBuffers, 0);
            mpPixelSampleCounter = Buffer::createStructured(
                mpDevice, sizeof(uint), numBuffers, ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess,
                Buffer::CpuAccess::None, &initData, false
            );
            mpPixelSampleCounter->setName("PixelSampleConter");
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

/**
 * Returns elements of the Halton low-discrepancy sequence.
 * @param[in] index Index of the queried element, starting from 0.
 * @param[in] base Base for the digit inversion. Should be the next unused prime number.
 */
float halton(uint32_t index, uint32_t base)
{
    // Reversing digit order in the given base in floating point.
    float result = 0.0f;
    float factor = 1.0f;

    for (; index > 0; index /= base)
    {
        factor /= base;
        result += factor * (index % base);
    }

    return result;
}

void AccelIrregularZ::generate(RenderContext* pRenderContext, const RenderData& renderData)
{
    FALCOR_PROFILE(pRenderContext, "Generate Shadow Acceleration Structure");

    prepareResources(pRenderContext);

    // Abort early if disabled
    if (mAccelDebugShowAS.enable && mAccelDebugShowAS.stopGeneration)
        return;

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
    uint frameInFlight = mAccelShadowUseCPUCounterOptimization ? mStagingCount : 0; // For sync if optimization is used

    //Create Access Mips
    {
        FALCOR_PROFILE(pRenderContext, "Generate Access Mips");
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
        FALCOR_PROFILE(pRenderContext, "Calc Shadow Sample distribution");
        // Create Compute Pass
        if (!mCalcSampleDistribution)
        {
            Program::Desc desc;
            desc.addShaderLibrary(kCalcSampleDistributionShader).csEntry("main").setShaderModel("6_6");

            DefineList defines;
            defines.add("COUNT_LIGHTS", std::to_string(lights.size()));

            mCalcSampleDistribution = ComputePass::create(mpDevice, desc, defines, true);
        }

        //Calc ray count dispatch
        auto var = mCalcSampleDistribution->getRootVar();

        if (mEnableDynamicRayCountCalc && mFrameCount > 0)
        {
            //Get mip level
            uint mip = mSampleDistribution[0]->getMipCount() - 1;
            var["CB"]["gCalcTotalDispatchCount"] = true;
            var["CB"]["gMaxNumAABBs"] = int(mResolution.x * mResolution.y * mAccelApproxNumElementsPerPixel * mDynRCGuardPercentage);
            var["CB"]["gChangePercentage"] = mDynRCChangePercentage; // 50% for now
            for (uint i = 0; i < lights.size(); i++)
            {
                var["gImpt"][i].setSrv(mAccessTextures[i]->getSRV(mip, 1u));
                var["gSmp"][i].setUav(mSampleDistribution[i]->getUAV(mip));
            }
            int lastFrameInFlight = 0;
            if (mAccelShadowUseCPUCounterOptimization)
            {
                lastFrameInFlight = mStagingCount - 1;
                lastFrameInFlight = lastFrameInFlight < 0 ? kFramesInFlight - 1 : lastFrameInFlight;
            }
                 
            var["gAABBCount"] = mAccelShadowCounter[lastFrameInFlight];
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
        FALCOR_PROFILE(pRenderContext, "Optimize distributed Samples");
        // Create Compute Pass
        if (!mpOptimizeSamples)
        {
            Program::Desc desc;
            desc.addShaderLibrary(kOptimizeSamplesShader).csEntry("main").setShaderModel("6_6");

            DefineList defines;
            defines.add("COUNT_LIGHTS", std::to_string(lights.size()));
            defines.add("MAX_SAMPLES", std::to_string(mMaxSamplesPerPixelSqr * mMaxSamplesPerPixelSqr));

            mpOptimizeSamples = ComputePass::create(mpDevice, desc, defines, true);
        }
        mpOptimizeSamples->getProgram()->addDefine("MAX_SAMPLES", std::to_string(mMaxSamplesPerPixelSqr * mMaxSamplesPerPixelSqr));
        auto var = mpOptimizeSamples->getRootVar();
        
        for (uint m = 1; m < mSampleDistribution[0]->getMipCount(); m++)
        {
            for (uint i = 0; i < lights.size(); i++)
            {
                var["gSampleDistribution0"][i].setUav(mSampleDistribution[i]->getUAV(m - 1));
                var["gSampleDistribution1"][i].setUav(mSampleDistribution[i]->getUAV(m));
            }
            uint3 dispatchDim = uint3(mAccessTextures[0]->getWidth(m), mAccessTextures[0]->getHeight(m), lights.size());
            var["CB"]["gDispatchSize"] = dispatchDim.xy();
            var["CB"]["gMipLevel"] = 0; // m - 1;
            var["CB"]["gLightCount"] = lights.size();

            mpOptimizeSamples->execute(pRenderContext, dispatchDim);
            //TODO needed?
            for (uint i = 0; i < lights.size(); i++)
            {
                pRenderContext->uavBarrier(mSampleDistribution[i].get());
            }
            
        }
    }

    // Init the sample points for Halton Jitter
    const uint maxSamplesSq = mMaxSamplesPerPixelSqr * mMaxSamplesPerPixelSqr;
    if (mSamplePattern == SMSamplePattern::Halton && mHaltonSampleCount.size() != maxSamplesSq)
    {
        mHaltonSampleCount.resize(maxSamplesSq);
        for (uint i = 0; i < maxSamplesSq; i++)
            mHaltonSampleCount[i] = i;
    }
    auto setHaltonJitterSamples = [&](ShaderVar& shaderVar) {
        for (uint i = 0; i < maxSamplesSq; i++)
        {
            float2 sample = float2(0.5);
            if (mSamplePattern == SMSamplePattern::Halton)
            {
                sample = {halton(mHaltonSampleCount[i], 2), halton(mHaltonSampleCount[i], 3)}; // sample in [0,1]
                mHaltonSampleCount[i] = (mHaltonSampleCount[i] + 1) % 64; // TODO reset count as option?
            }

            shaderVar["JitterSamples"]["gJitterSamples"][i] = sample;
        }
    };


    // Create a pixel sample list
    if(mUseSeperateSampleDistributionPass)
    {
        FALCOR_PROFILE(pRenderContext, "Create Pixel Samples");
        if (!mGenAccelShadowPip.pVars)
            mpDistributeSamples.reset();
        // Clear Counter
        pRenderContext->clearUAV(mpPixelSampleCounter->getUAV(0u, lights.size()).get(), uint4(0));

        // Create Compute Pass
        if (!mpDistributeSamples)
        {
            Program::Desc desc;
            desc.addShaderLibrary(kDistributeSamplesShader).csEntry("main").setShaderModel("6_6");

            DefineList defines;
            defines.add("COUNT_LIGHTS", std::to_string(lights.size()));
            defines.add("USE_MSAA_JITTER", mSamplePattern == SMSamplePattern::MSAA ? "1" : "0");
            defines.add(
                "MAX_SAMPLES_PER_PIXEL_X", std::to_string(mSamplePattern == SMSamplePattern::MSAA ? 8 : mMaxSamplesPerPixelSqr)
            );
            defines.add(
                "MAX_SAMPLES_PER_PIXEL_Y", std::to_string(mSamplePattern == SMSamplePattern::MSAA ? 1 : mMaxSamplesPerPixelSqr)
            );
            defines.add("USE_OPTIMIZED_SAMPLE_DISTRIBUTION", mOptimizeSampleDistribution ? "1" : "0");

            mpDistributeSamples = ComputePass::create(mpDevice, desc, defines, true);
        }

        mpDistributeSamples->getProgram()->addDefine("USE_OPTIMIZED_SAMPLE_DISTRIBUTION", mOptimizeSampleDistribution ? "1" : "0");
        auto var = mpDistributeSamples->getRootVar();

        // Upload jittered sampled
        setHaltonJitterSamples(var);
    
        var["gPixelSampleCounter"] = mpPixelSampleCounter;
        for (uint i = 0; i < lights.size(); i++)
        {
            var["gSampleDistribution"][i] = mSampleDistribution[i];
            var["gPixelSample"][i] = mPixelSample[i];
        }

        //uint3 dispatchDim = uint3(mResolution.x * mMaxSamplesPerPixelSqr, mResolution.y * mMaxSamplesPerPixelSqr, lights.size()); //Old Version(see shader)
        uint3 dispatchDim = uint3(mResolution.x, mResolution.y, lights.size()); //New one
        if (mOptimizeSampleDistribution)
        {
            dispatchDim.x = dispatchDim.x * mSampleOverestimate;
            dispatchDim.y = dispatchDim.y * mSampleOverestimate;
        }
            
        var["CB"]["gSMRes"] = mResolution;
        var["CB"]["gDispatchDim"] = dispatchDim.xy();
        var["CB"]["gMipCount"] = mSampleDistribution[0]->getMipCount();
        var["CB"]["gFrameCount"] = mFrameCount;

        mpDistributeSamples->execute(pRenderContext, dispatchDim);
    }

    // Clear Counter
    uint clearSize = mUseOneAABBForAllLights ? 1 : lights.size();
    pRenderContext->clearUAV(mAccelShadowCounter[frameInFlight]->getUAV(0u, clearSize).get(), uint4(0));
    //Clear AABBs
    mpShadowAccelerationStrucure->clearAABBBuffers(pRenderContext, mAccelShadowAABB);
       
    // Defines
    mGenAccelShadowPip.pProgram->addDefine("MAX_IDX", std::to_string(mResolution.x * mResolution.y * mAccelApproxNumElementsPerPixel));
    mGenAccelShadowPip.pProgram->addDefine("SHADOW_DATA_FORMAT_SIZE", std::to_string(mAccelDataFormatSize));
    mGenAccelShadowPip.pProgram->addDefine("ACCEL_BOXES_PIXEL_OFFSET", mAccelUsePCF ? "1.0" : "0.5");
    mGenAccelShadowPip.pProgram->addDefine("ACCEL_USE_FRUSTUM_CULLING", mAccelUseFrustumCulling ? "1" : "0");
    mGenAccelShadowPip.pProgram->addDefine("ACCEL_RAY_FLAGS", std::to_string((uint)mAccelRayFlags));
    mGenAccelShadowPip.pProgram->addDefine("SAMPLE_DIST_MIPS", std::to_string(mSampleDistribution[0]->getMipCount()));
    mGenAccelShadowPip.pProgram->addDefine("USE_MSAA_JITTER", mSamplePattern == SMSamplePattern::MSAA ? "1" : "0");
    mGenAccelShadowPip.pProgram->addDefine(
        "MAX_SAMPLES_PER_PIXEL_X", std::to_string(mSamplePattern == SMSamplePattern::MSAA ? 8 : mMaxSamplesPerPixelSqr)
    );
    mGenAccelShadowPip.pProgram->addDefine(
        "MAX_SAMPLES_PER_PIXEL_Y", std::to_string(mSamplePattern == SMSamplePattern::MSAA ? 1 : mMaxSamplesPerPixelSqr)
    );
    mGenAccelShadowPip.pProgram->addDefine("USE_SAMPLE_DISTRIBUTION_IN_GEN", mUseSeperateSampleDistributionPass ? "0" : "1");
    mGenAccelShadowPip.pProgram->addDefine("USE_OPTIMIZED_SAMPLE_DISTRIBUTION", mOptimizeSampleDistribution ? "1" : "0");
    mGenAccelShadowPip.pProgram->addDefine("USE_ONE_AABB_BUFFER_FOR_ALL_LIGHTS", mUseOneAABBForAllLights ? "1" : "0");
    mGenAccelShadowPip.pProgram->addDefine("ACCEL_MERGE_BOX_DIST", std::to_string(mMergeBoxDist));

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
        mGenAccelShadowPip.pProgram->setTypeConformances(mpScene->getTypeConformances());
        mGenAccelShadowPip.pVars = RtProgramVars::create(mpDevice, mGenAccelShadowPip.pProgram, mGenAccelShadowPip.pBindingTable);
        //mpSampleGenerator->setShaderData(mGenAccelShadowPip.pVars->getRootVar());
    }

    FALCOR_ASSERT(mGenAccelShadowPip.pVars);
    auto var = mGenAccelShadowPip.pVars->getRootVar();

    // Set Halton Jitter (same for every light)
    if (!mUseSeperateSampleDistributionPass)
        setHaltonJitterSamples(var);

    // Trace the pass for every light
    for (uint i = 0; i < lights.size(); i++)
    {
        if (!lights[i]->isActive())
            break;
        FALCOR_PROFILE(pRenderContext, lights[i]->getName());
        // Bind Utility
        bool isDirectional = lights[i]->getType() == LightType::Directional;

        var["CB"]["gFrameCount"] = mFrameCount;
        var["CB"]["gLightPos"] = isDirectional ? lights[i]->getData().dirW : mShadowMapMVP[i].pos;
        var["CB"]["gIsDirectional"] = isDirectional;
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
        var["gPointSampler"] = mpPointSampler;
        var["gAccessCounter"] = mAccessTextures[i];
        var["gSampleDistribution"] = mSampleDistribution[i];
        var["gPixelSample"] = mPixelSample[i];
        var["gPixelSampleCounter"] = mpPixelSampleCounter;

        // Get dimensions of ray dispatch.
        uint2 targetDim = mResolution;
        /*
        if (!mUseSeperateSampleDistributionPass)
        {
            targetDim = mSamplePattern == SMSamplePattern::MSAA
                            ? uint2(mResolution.x * 8, mResolution.y)
                            : uint2(mResolution.x * mMaxSamplesPerPixelSqr, mResolution.y * mMaxSamplesPerPixelSqr);
        }
        else*/
        if (mOptimizeSampleDistribution)
        {
            targetDim = uint2(float2(targetDim) * mSampleOverestimate);
        }
                    
        FALCOR_ASSERT(targetDim.x > 0 && targetDim.y > 0);

        // Spawn the rays.
        mpScene->raytrace(pRenderContext, mGenAccelShadowPip.pProgram.get(), mGenAccelShadowPip.pVars, uint3(targetDim, 1));
    }

    const uint numAABBs = mUseOneAABBForAllLights ? 1 : lights.size();

    // Sync Photon copy data
    if (mAccelShadowUseCPUCounterOptimization)
    {
        // Copy to CPU
        pRenderContext->copyBufferRegion(
            mAccelShadowCounterCPU[mStagingCount].get(), 0, mAccelShadowCounter[mStagingCount].get(), 0, sizeof(uint32_t) * numAABBs
        );
        pRenderContext->flush();
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

    // Build the Acceleration structure
    std::vector<uint64_t> aabbCount;
    for (uint i = 0; i < numAABBs; i++)
    {
        uint numPoints = mAccelShadowUseCPUCounterOptimization
                             ? std::min(uint(mAccelShadowNumPoints[i] * mAccelShadowOverestimation), mAccelShadowMaxNumPoints)
                             : mAccelShadowMaxNumPoints;
        aabbCount.push_back(numPoints);
    }
    mpShadowAccelerationStrucure->update(pRenderContext, aabbCount);

    mFrameCount++;
}

DefineList AccelIrregularZ::getDefines()
{
    DefineList defines = {};
    defines.add(TransparencyShadowMethod::getDefines());
    defines.add("SHADOW_DATA_FORMAT_SIZE", std::to_string(mAccelDataFormatSize));
    defines.add("SHADOW_ACCEL_PCF", mAccelUsePCF ? "1" : "0");
    defines.add("ACCEL_USE_RAY_INLINE", mAccelUseRayTracingInline ? "1" : "0");
    defines.add("ACCEL_USE_NEAREST_DEPTH", mAccelUseNearestDepth ? "1" : "0");
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
        shadowVar["ShadowVPs"]["gShadowMapVP"][i] = mShadowMapMVP[i].viewProjection;
        shadowVar["ShadowVPs"]["gStaggeredDirVP"] = mStaggeredDirectionalLightMVP.viewProjection;
        shadowVar["gAccessCounter"][i] = mAccessTextures[i];
    }
    const auto accelDataSize = mUseOneAABBForAllLights ? 1 : lights.size();
    for (uint i = 0; i < accelDataSize; i++)
    {
        shadowVar["gAccelShadowData"][i] = mAccelShadowData[i];
        shadowVar["gShadowAABBs"][i] = mAccelShadowAABB[i];
    }

    mpShadowAccelerationStrucure->bindTlas(shadowVar, "gShadowAS");
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
                    group2.text(mUseOneAABBForAllLights ? "Total" : mpScene->getLight(i)->getName());
                    group2.text("Elements:        " + std::to_string(mAccelShadowMaxNumPoints));
                    std::string accelMem = std::to_string((mAccelShadowMaxNumPoints * sizeof(AABB)) / 1e6f);
                    group2.text("AABB Memory:     " + accelMem.substr(0, accelMem.find(".") + 3) + " MB");
                    group2.text("Data Memory:      TBD"); // TODO
                    group2.text(
                        "Needed Elements: " + std::to_string(uint(mAccelShadowNumPoints[i] * mAccelShadowOverestimation)) + " (" +
                        std::to_string(mAccelShadowNumPoints[i]) + ")"
                    );
                    std::string neededMem = std::to_string((mAccelShadowNumPoints[i] * mAccelShadowOverestimation * sizeof(AABB)) / 1e6f);
                    std::string fillRate =
                        std::to_string(((mAccelShadowNumPoints[i] * mAccelShadowOverestimation) / float(mAccelShadowMaxNumPoints)) * 100.f);
                    group2.text(
                        "Needed AABB Memory:   " + neededMem.substr(0, neededMem.find(".") + 3) + " MB (" +
                        fillRate.substr(0, fillRate.find(".") + 2) + "%)"
                    );
                    group2.text("Needed Data Memory:    TBD");
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
            group.var("GPU SD Total Mult", mDynRCGuardPercentage, 0.001f, 1.f);
            group.tooltip("Multiplier for the total that is used to calculate the ray count for the current frame");
            group.var("GPU SD Change Mult", mDynRCChangePercentage, 0.001f, 1.f);
            group.tooltip("Multiplier for the change value in the Sample Distribution");
        }

        group.checkbox("Use CPU Counter optimization", mAccelShadowUseCPUCounterOptimization);
        group.tooltip("Uses the CPU counter value from a previous frame (async) to estimate the acceleration structure build size.");
        if (mAccelShadowUseCPUCounterOptimization)
        {
            group.var("CPU Counter overestimation", mAccelShadowOverestimation, 1.0f, 2.0f, 0.001f);
        }

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


        mRebuildAccelDataBuffer |= group.dropdown("Data Format Size", kAccelDataFormat, mAccelDataFormatSize);
        group.tooltip("Data formats; For more info see AccelShadowData.slang");
        //group.checkbox("Use Frustum Culling", mAccelUseFrustumCulling);
        //group.tooltip("Uses Frustum Culling to reject the storage of the Accel SM samples");

        group.checkbox("Use seperate Sample Distribution Pass", mUseSeperateSampleDistributionPass);
        group.tooltip(
            "Enables a seperate pass that distributes the sample into a buffer. Seems faster as there is less divergence in the raytracing "
            "shader"
        );
        group.dropdown("Subpixel Sample Pattern", mSamplePattern);
        group.tooltip("Changes the Subpixel sample pattern for shadow map generation. Use the option below to change the box size");
        if (mSamplePattern == SMSamplePattern::MSAA)
        {
            group.text("8x8 Subpixel sampling box size (fix for MSAA)");
        }
        else
        {
            if (group.var("Subpixel sampling box size", mMaxSamplesPerPixelSqr, 1u, 1024u, 1u))
                mGenAccelShadowPip.pVars.reset();
            group.tooltip("Box size for the subpixel sampling. E.g. 3 -> 3x3 box.");
        }

        //group.checkbox("Use PCF", mAccelUsePCF);
        group.var("Merge Boxes Dist", mMergeBoxDist, 0.f, FLT_MAX, 0.000001f, false, "% .6f ");
        group.tooltip(
            "Merges Accel Boxes together and takes the transparency of the first box. Can add bias (brightening). \n Set to 0 to disable."
        );
        group.checkbox("Use Inline RayTracing", mAccelUseRayTracingInline);
        group.checkbox("Use Visibility of nearest depth", mAccelUseNearestDepth);
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
        defines.add("SHADOW_DATA_FORMAT_SIZE", std::to_string(mAccelDataFormatSize));
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
    mRasterShowAccelPass.pProgram->addDefine("SHADOW_DATA_FORMAT_SIZE", std::to_string(mAccelDataFormatSize));
    mRasterShowAccelPass.pProgram->addDefine("USE_ONE_AABB_FOR_ALL", mUseOneAABBForAllLights ? "1" : "0");

    // Vars
    if (!mRasterShowAccelPass.pVars)
        mRasterShowAccelPass.pVars = GraphicsVars::create(mpDevice, mRasterShowAccelPass.pProgram.get());

    uint frameInFlight = 0;
    // Staging count was increased at the end of the generation code, so take one less
    if (mAccelShadowUseCPUCounterOptimization)
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
    var["CB"]["gMaxSampleCount"] = mMaxSamplesPerPixelSqr * mMaxSamplesPerPixelSqr;
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

