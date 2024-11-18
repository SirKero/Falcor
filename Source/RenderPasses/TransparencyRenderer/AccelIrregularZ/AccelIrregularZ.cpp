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

namespace
{
    //Shader Paths
    const std::string kShaderFolder = "RenderPasses/TransparencyRenderer/AccelIrregularZ/";
    const std::string kGenShader = kShaderFolder + "GenAccelIrregularZ.rt.slang";
    const std::string kAccessMipsShader = kShaderFolder + "GenAccessMips.cs.slang";
    const std::string kCalcSampleDistributionShader = kShaderFolder + "CalcSampleDistribution.cs.slang";
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
    FALCOR_ASSERT(mpPointSampler)
}

void AccelIrregularZ::prepareResources(RenderContext* pRenderContext) {

    if (mResolutionChanged)
    {
        mAccelShadowAABB.clear();
        mpShadowAccelerationStrucure.reset();
        mAccessTextures.clear();
        mSampleDistribution.clear();
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
        desc.setMaxPayloadSize(20u); //
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

        if (mAccelShadowAABB.empty())
        {
            mAccelShadowAABB.resize(numBuffers);
            mAccelShadowMaxNumPoints = mResolution.x * mResolution.y * mAccelApproxNumElementsPerPixel;
            for (uint i = 0; i < numBuffers; i++)
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
            mAccelShadowNumPoints.resize(numBuffers);

            uint initData = 0;
            for (uint i = 0; i < kFramesInFlight; i++)
            {
                mAccelShadowCounter[i] = Buffer::createStructured(
                    mpDevice, sizeof(uint), numBuffers, ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess,
                    Buffer::CpuAccess::None, &initData, false
                );
                mAccelShadowCounter[i]->setName("AccelShadowAABBCounter_" + std::to_string(i));

                mAccelShadowCounterCPU[i] = Buffer::createStructured(
                    mpDevice, sizeof(uint), numBuffers, ResourceBindFlags::None, Buffer::CpuAccess::Read, &initData, false
                );
                mAccelShadowCounterCPU[i]->setName("AccelShadowAABBCounterCPU_" + std::to_string(i));

                mAccelFenceWaitValues[i] = 0;
            }

            for (uint i = 0; i < numBuffers; i++)
                mAccelShadowNumPoints[i] = mResolution.x * mResolution.y * mAccelApproxNumElementsPerPixel;
        }
        if (mAccelShadowData.empty())
        {
            mAccelShadowData.resize(numBuffers);
            for (uint i = 0; i < numBuffers; i++)
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
            for (uint i = 0; i < numBuffers; i++)
            {
                aabbCount.push_back(mResolution.x * mResolution.y * mAccelApproxNumElementsPerPixel);
                aabbGPUAddress.push_back(mAccelShadowAABB[i]->getGpuAddress());
            }
            mpShadowAccelerationStrucure = std::make_unique<CustomAccelerationStructure>(
                mpDevice, aabbCount, aabbGPUAddress, CustomAccelerationStructure::BuildMode::None,
                CustomAccelerationStructure::UpdateMode::TLASOnly
            );
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
                    mpDevice, mResolution.x, mResolution.y, ResourceFormat::R32Uint, 1u, Texture::kMaxPossible, nullptr,
                    ResourceBindFlags::UnorderedAccess | ResourceBindFlags::ShaderResource
                );
                //Set highest mip to total number of samples
                pRenderContext->clearUAV(
                    mSampleDistribution[i]->getUAV(mSampleDistribution[i]->getMipCount() - 1).get(), uint4(mResolution.x * mResolution.y)
                );
                mSampleDistribution[i]->setName("SampleDistribution" + std::to_string(i));
            }
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

void AccelIrregularZ::generate(RenderContext* pRenderContext, const RenderData& renderData)
{
    FALCOR_PROFILE(pRenderContext, "Generate Shadow Acceleration Structure");

    prepareResources(pRenderContext);

    // Abort early if disabled
    if (mAccelDebugShowAS.enable && mAccelDebugShowAS.stopGeneration)
        return;

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
        FALCOR_PROFILE(pRenderContext, "Distribute Shadow Samples");
        // Create Compute Pass
        if (!mCalcSampleDistribution)
        {
            Program::Desc desc;
            desc.addShaderLibrary(kCalcSampleDistributionShader).csEntry("main").setShaderModel("6_6");

            DefineList defines;
            defines.add("COUNT_LIGHTS", std::to_string(lights.size()));

            mCalcSampleDistribution = ComputePass::create(mpDevice, desc, defines, true);
        }

         for (int m = mSampleDistribution[0]->getMipCount() - 2; m >= 0; m--)
        {
             auto var = mCalcSampleDistribution->getRootVar();
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


    // Clear Counter
    pRenderContext->clearUAV(mAccelShadowCounter[frameInFlight]->getUAV(0u, lights.size()).get(), uint4(0));
    //Clear AABBs
    mpShadowAccelerationStrucure->clearAABBBuffers(pRenderContext, mAccelShadowAABB);


    // Defines
    mGenAccelShadowPip.pProgram->addDefine("MAX_IDX", std::to_string(mResolution.x * mResolution.y * mAccelApproxNumElementsPerPixel));
    mGenAccelShadowPip.pProgram->addDefine("SHADOW_DATA_FORMAT_SIZE", std::to_string(mAccelDataFormatSize));
    mGenAccelShadowPip.pProgram->addDefine("ACCEL_BOXES_PIXEL_OFFSET", mAccelUsePCF ? "1.0" : "0.5");
    mGenAccelShadowPip.pProgram->addDefine("ACCEL_USE_FRUSTUM_CULLING", mAccelUseFrustumCulling ? "1" : "0");
    mGenAccelShadowPip.pProgram->addDefine("ACCEL_RAY_FLAGS", std::to_string((uint)mAccelRayFlags));
    mGenAccelShadowPip.pProgram->addDefine("SAMPLE_DIST_MIPS", std::to_string(mSampleDistribution[0]->getMipCount()));

    // Create Program Vars
    if (!mGenAccelShadowPip.pVars)
    {
        mGenAccelShadowPip.pProgram->setTypeConformances(mpScene->getTypeConformances());
        mGenAccelShadowPip.pVars = RtProgramVars::create(mpDevice, mGenAccelShadowPip.pProgram, mGenAccelShadowPip.pBindingTable);
        //mpSampleGenerator->setShaderData(mGenAccelShadowPip.pVars->getRootVar());
    }

    FALCOR_ASSERT(mGenAccelShadowPip.pVars);

    // Trace the pass for every light
    for (uint i = 0; i < lights.size(); i++)
    {
        if (!lights[i]->isActive())
            break;
        FALCOR_PROFILE(pRenderContext, lights[i]->getName());
        // Bind Utility
        auto var = mGenAccelShadowPip.pVars->getRootVar();
        var["CB"]["gFrameCount"] = mFrameCount;
        var["CB"]["gLightPos"] = mShadowMapMVP[i].pos;
        var["CB"]["gNear"] = mNearFar.x;
        var["CB"]["gFar"] = mNearFar.y;
        var["CB"]["gLightIdx"] = i;
        var["CB"]["gSamplePerRes"] = kSamplesPerPixel;
        var["CB"]["gViewProj"] = mShadowMapMVP[i].viewProjection;
        var["CB"]["gInvViewProj"] = mShadowMapMVP[i].invViewProjection;
        var["CB"]["gInvProj"] = mShadowMapMVP[i].invProjection;
        var["CB"]["gInvView"] = mShadowMapMVP[i].invView;
        var["CB"]["gView"] = mShadowMapMVP[i].view;
        std::array<float4, 4> planes = getCameraFrustumPlanes(); // Get Top,Bottom,Left,Right Camera frustum plane
        for (uint j = 0; j < 4; j++)
            var["CB"]["gFrustumPlanes"][j] = planes[j];

        var["gAABB"] = mAccelShadowAABB[i];
        var["gCounter"] = mAccelShadowCounter[frameInFlight];
        var["gData"] = mAccelShadowData[i];
        var["gAccessCounter"] = mAccessTextures[i];
        var["gSampleDistribution"] = mSampleDistribution[i];
        var["gPointSampler"] = mpPointSampler;

        // Get dimensions of ray dispatch.
        const uint2 targetDim = uint2(mResolution.x * kSamplesPerPixel, mResolution.y);
        FALCOR_ASSERT(targetDim.x > 0 && targetDim.y > 0);

        // Spawn the rays.
        mpScene->raytrace(pRenderContext, mGenAccelShadowPip.pProgram.get(), mGenAccelShadowPip.pVars, uint3(targetDim, 1));
    }

    // Sync Photon copy data
    if (mAccelShadowUseCPUCounterOptimization)
    {
        // Copy to CPU
        uint numLights = lights.size();
        pRenderContext->copyBufferRegion(
            mAccelShadowCounterCPU[mStagingCount].get(), 0, mAccelShadowCounter[mStagingCount].get(), 0, sizeof(uint32_t) * numLights
        );
        pRenderContext->flush();
        // Frame in flight for the counter
        mAccelFenceWaitValues[mStagingCount] = mpFence->gpuSignal(pRenderContext->getLowLevelData()->getCommandQueue());
        mStagingCount = (mStagingCount + 1) % kFramesInFlight;

        uint64_t& fenceWaitVal = mAccelFenceWaitValues[mStagingCount];
        // Wait for the GPU to finish the frame
        mpFence->syncCpu(fenceWaitVal);

        void* data = mAccelShadowCounterCPU[mStagingCount]->map(Buffer::MapType::Read);
        std::memcpy(mAccelShadowNumPoints.data(), data, sizeof(uint) * numLights);
        mAccelShadowCounterCPU[mStagingCount]->unmap();
    }

    // Build the Acceleration structure
    std::vector<uint64_t> aabbCount;
    for (uint i = 0; i < lights.size(); i++)
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
        shadowVar["gAccelShadowData"][i] = mAccelShadowData[i];
        shadowVar["gShadowAABBs"][i] = mAccelShadowAABB[i];
        shadowVar["gAccessCounter"][i] = mAccessTextures[i];
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
                for (uint i = 0; i < mpScene->getLightCount(); i++)
                {
                    if (i > 0)
                        group2.separator();
                    group2.text(mpScene->getLight(i)->getName());
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
        group.checkbox("Use CPU Counter optimization", mAccelShadowUseCPUCounterOptimization);
        group.tooltip("Uses the CPU counter value from a previous frame (async) to estimate the acceleration structure build size.");
        if (mAccelShadowUseCPUCounterOptimization)
        {
            group.var("CPU Counter overestimation", mAccelShadowOverestimation, 1.0f, 2.0f, 0.001f);
        }

        mRebuildAccelDataBuffer |= group.dropdown("Data Format Size", kAccelDataFormat, mAccelDataFormatSize);
        group.tooltip("Data formats; For more info see AccelShadowData.slang");
        group.checkbox("Use Frustum Culling", mAccelUseFrustumCulling);
        group.tooltip("Uses Frustum Culling to reject the storage of the Accel SM samples");
        group.checkbox("Use PCF", mAccelUsePCF);
        group.checkbox("Use Inline RayTracing", mAccelUseRayTracingInline);
        group.checkbox("Use Visibility of nearest depth", mAccelUseNearestDepth);
        group.tooltip("Only uses the Visibility of the sample with the closest depth. If disabled, the average of all hit Boxes is used");
        if (auto group2 = group.group("Debug"))
        {
            group2.checkbox("Enable", mAccelDebugShowAS.enable);
            if (mAccelDebugShowAS.enable && mpScene)
            {
                if (mpScene->getLightCount() > 1)
                    group2.slider("Selected Light", mAccelDebugShowAS.selectedLight, 0u, mpScene->getLightCount() - 1);
                group2.var("Clip X", mAccelDebugShowAS.clipX, 0.f, float(mResolution.x), 0.1f);
                group2.var("Clip Y", mAccelDebugShowAS.clipY, 0.f, float(mResolution.y), 0.1f);
                group2.var("Clip Z", mAccelDebugShowAS.clipZ, -FLT_MAX, FLT_MAX, 0.1f);

                group2.var("Blend with Output", mAccelDebugShowAS.blendT, 0.f, 1.f, 0.001f);
                if (group2.dropdown("Mode", kAccelDebugVisModes, mAccelDebugShowAS.visMode))
                    mAccelDebugShowAS.stopGeneration = mAccelDebugShowAS.visMode == 1 ? true : mAccelDebugShowAS.stopGeneration;
                group2.checkbox("Stop Generation", mAccelDebugShowAS.stopGeneration);
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

    // Vars
    if (!mRasterShowAccelPass.pVars)
        mRasterShowAccelPass.pVars = GraphicsVars::create(mpDevice, mRasterShowAccelPass.pProgram.get());

    uint frameInFlight = 0;
    // Staging count was increased at the end of the generation code, so take one less
    if (mAccelShadowUseCPUCounterOptimization)
        frameInFlight = mStagingCount == 0 ? kFramesInFlight - 1 : mStagingCount - 1;

    auto var = mRasterShowAccelPass.pVars->getRootVar();

    var["gScene"] = mpScene->getParameterBlock();
    var["CB"]["gSMSize"] = mResolution;
    var["CB"]["gNear"] = mNearFar.x;
    var["CB"]["gFar"] = mNearFar.y;
    var["CB"]["gSelectedLight"] = mAccelDebugShowAS.selectedLight;
    var["CB"]["gCullMin"] = float3(mAccelDebugShowAS.clipX.x, mAccelDebugShowAS.clipY.x, mAccelDebugShowAS.clipZ.x);
    var["CB"]["gCullMax"] = float3(mAccelDebugShowAS.clipX.y, mAccelDebugShowAS.clipY.y, mAccelDebugShowAS.clipZ.y);
    var["CB"]["gBlendT"] = mAccelDebugShowAS.blendT;
    var["CB"]["gVisMode"] = mAccelDebugShowAS.visMode;
    var["CB"]["gMaxSampleCount"] = kSamplesPerPixel;
    var["CB"]["gInvView"] = mShadowMapMVP[mAccelDebugShowAS.selectedLight].invView;
    var["CB"]["gInvProj"] = mShadowMapMVP[mAccelDebugShowAS.selectedLight].invProjection;

    var["gShadowAABB"] = mAccelShadowAABB[mAccelDebugShowAS.selectedLight];
    var["gShadowCounter"] = mAccelShadowCounter[frameInFlight];
    var["gShadowData"] = mAccelShadowData[mAccelDebugShowAS.selectedLight];
    var["gOutputColor"] = colorOut; // For blending

    pRenderContext->draw(mRasterShowAccelPass.pState.get(), mRasterShowAccelPass.pVars.get(), mAccelShadowMaxNumPoints, 0);
}

