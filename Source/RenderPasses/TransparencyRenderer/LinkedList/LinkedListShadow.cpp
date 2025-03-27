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
#include "LinkedListShadow.h"
#include "Utils/Math/FalcorMath.h"
#include "Utils/SampleGenerators/HaltonSamplePattern.h"

namespace
{
    //Shader Paths
    const std::string kShaderFolder = "RenderPasses/TransparencyRenderer/LinkedList/";
    const std::string kGenShader = kShaderFolder + "GenLinkedList.rt.slang";
    const std::string kShaderLinkedListNeighbors = kShaderFolder + "GenLinkedListNeighbors.cs.slang";

    //UI
    

}; // namespace

LinkedListShadow::LinkedListShadow(ref<Device> pDevice, ref<Scene> pScene) : TransparencyShadowMethod(pDevice, pScene)
{
    mpFence = GpuFence::create(mpDevice);
    FALCOR_ASSERT(mpFence);
}

void LinkedListShadow::prepareResources(RenderContext* pRenderContext)
{
    // This is triggered if either the resolution or number of lights changed
    if (mResolutionChanged)
    {
        // The following buffers need to be cleared when light count changes
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

    mResolutionChanged = false;

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

void LinkedListShadow::generate(RenderContext* pRenderContext, const RenderData& renderData)
{
    FALCOR_PROFILE(pRenderContext, "GenerateIrregularLinkedList");

    prepareResources(pRenderContext);

    auto& lights = mpScene->getLights();
    uint frameInFlight = mStagingCount; // Counter GPU CPU sync

    // Defines
    mGenLinkedListShadowPip.pProgram->addDefine("MAX_IDX", std::to_string(mLinkedListNodeBufferSize));
    mGenLinkedListShadowPip.pProgram->addDefine("MIDPOINT_PERCENTAGE", std::to_string(mMidpointPercentage));
    mGenLinkedListShadowPip.pProgram->addDefine("MIDPOINT_DEPTH_BIAS", std::to_string(mMidpointDepthBias));
    mGenLinkedListShadowPip.pProgram->addDefine("USE_COLOR_TRANSPARENCY", mUseColoredTransparency ? "1" : "0");
    mGenLinkedListShadowPip.pProgram->addDefine("ACCEL_BOXES_PIXEL_OFFSET", mAccelUsePCF ? "1.0" : "0.5");
    mGenLinkedListShadowPip.pProgram->addDefine("USE_HALTON_SAMPLE_PATTERN", mEnableHalton ? "1" : "0");
    mGenLinkedListShadowPip.pProgram->addDefine("NUM_HALTON_SAMPLES", std::to_string(mNumHaltonSamples));
    mGenLinkedListShadowPip.pProgram->addDefine("USE_RANDOM_RANDOM_SOFT_SHADOWS", mEnableRandomSoftShadows ? "1" : "0");
    mGenLinkedListShadowPip.pProgram->addDefine("RANDOM_SOFT_SHADOWS_POS_RADIUS", std::to_string(mRandomSoftShadowsPositionRadius));
    mGenLinkedListShadowPip.pProgram->addDefine("RANDOM_SOFT_SHADOWS_DIR_SPREAD", std::to_string(mRandomSoftShadowsDirSpread));
    mGenLinkedListShadowPip.pProgram->addDefine("TRACE_NON_OPAQUE_ONLY", mUseOpaqueSM ? "1" : "0"); // Trace non-opaque only if mask is used
    mGenLinkedListShadowPip.pProgram->addDefine(
        "INCLUDE_CAST_SHADOW_INSTANCE_MASK_BIT", mEnableBlacklistWithShadowMaterialFlag ? "0" : "1"
    ); // Determines if the castShadow instance mask bit is used

     // Create Program Vars
    if (!mGenLinkedListShadowPip.pVars)
    {
        mGenLinkedListShadowPip.pProgram->setTypeConformances(mpScene->getTypeConformances());
        mGenLinkedListShadowPip.pVars =
            RtProgramVars::create(mpDevice, mGenLinkedListShadowPip.pProgram, mGenLinkedListShadowPip.pBindingTable);
    }

    //Clear Counter
    pRenderContext->clearUAV(mLinkedListCounter[frameInFlight]->getUAV(0, lights.size()).get(), uint4(mResolution.x * mResolution.y));
    pRenderContext->uavBarrier(mLinkedListCounter[frameInFlight].get());

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
        var["CB"]["gSMRes"] = mResolution;
        var["CB"]["gViewProj"] = mShadowMapMVP[i].viewProjectionNoJitter;
        var["CB"]["gInvViewProj"] = mShadowMapMVP[i].invViewProjection;
        var["CB"]["gSpreadAngle"] = mShadowMapMVP[i].spreadAngle;

        var["gCounter"] = mLinkedListCounter[frameInFlight];
        var["gData"] = mLinkedListData[i];
        var["gHaltonSamples"] = mpHaltonBuffer;

        // Get dimensions of ray dispatch.
        uint2 targetDim = mResolution;

        FALCOR_ASSERT(targetDim.x > 0 && targetDim.y > 0);

        // Spawn the rays.
        mpScene->raytrace(pRenderContext, mGenLinkedListShadowPip.pProgram.get(), mGenLinkedListShadowPip.pVars, uint3(targetDim, 1));

        mFrameCount++;
    }

     const uint numLights = lights.size();

    // Copy data from GPU to CPU counter
    {
        // Copy to CPU
        pRenderContext->copyBufferRegion(
            mLinkedListCounterCPU[mStagingCount].get(), 0, mLinkedListCounter[mStagingCount].get(), 0, sizeof(uint32_t) * numLights
        );
        pRenderContext->flush();
        // Frame in flight for the counter
        mCounterFenceWaitValues[mStagingCount] = mpFence->gpuSignal(pRenderContext->getLowLevelData()->getCommandQueue());
        mStagingCount = (mStagingCount + 1) % kFramesInFlight;

        uint64_t& fenceWaitVal = mCounterFenceWaitValues[mStagingCount];
        // Wait for the GPU to finish the frame
        mpFence->syncCpu(fenceWaitVal);

        void* data = mLinkedListCounterCPU[mStagingCount]->map(Buffer::MapType::Read);
        std::memcpy(mUIElementCounter.data(), data, sizeof(uint) * numLights);
        mLinkedListCounterCPU[mStagingCount]->unmap();
    }

    /*
        if (mUseLinkedListPcf)
        {
            // link neighbors
            auto var2 = mpLinkedListNeighborsPass->getRootVar();
            var2["CB"]["SMSize"] = mResolution.x; //width only for buffer offset
            var2["gLinkedList"] = mpLinkedList[i];
            var2["gLinkedListNeighbors"] = mpLinkedListNeighbors[i];
            mpLinkedListNeighborsPass->execute(pRenderContext, mResolution.x, mResolution.y);
        }
    */
}

DefineList LinkedListShadow::getDefines()
{
    DefineList defines = {};
    defines.add(TransparencyShadowMethod::getDefines());
    defines.add("LINKED_LIST_PCF", mAccelUsePCF ? "1" : "0");
    defines.add("USE_COLOR_TRANSPARENCY", mUseColoredTransparency ? "1" : "0");
    return defines;
}

void LinkedListShadow::setShaderData(const ShaderVar& var)
{
    auto shadowVar = var["gLinkedListShadow"];

    shadowVar["SMCB"]["gSMSize"] = mResolution;
    shadowVar["SMCB"]["gNear"] = mNearFar.x;
    shadowVar["SMCB"]["gFar"] = mNearFar.y;
    shadowVar["SMCB"]["gMaxBufferSize"] = mLinkedListNodeBufferSize;

    auto& lights = mpScene->getLights();
    for (uint i = 0; i < lights.size(); i++)
    {
        shadowVar["ShadowVPs"]["gShadowMapVP"][i] = mShadowMapMVP[i].viewProjectionNoJitter;
    }

    const auto accelDataSize = lights.size();
    for (uint i = 0; i < accelDataSize; i++)
    {
        shadowVar["gLinkedListData"][i] = mLinkedListData[i];
    }
}

void LinkedListShadow::setShadowMask(const ShaderVar& var, ref<Texture> maskTex, ref<Resource> maskSM, bool enable)
{
    mUseOpaqueSM = enable;
    if (mUseOpaqueSM)
    {
        auto shadowVar = var["gLinkedListShadow"];

        //shadowVar["gShadowMask"] = maskTex;
        shadowVar["gMaskShadowMap"] = maskSM->asTexture();
    }
}

bool LinkedListShadow::renderUI(Gui::Widgets& widget)
{
    bool dirty = false;
    if (auto group = widget.group("Linked List settings"))
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
                    group2.text("Used Elements: " + std::to_string(uint(mUIElementCounter[i])));
                    std::string neededMem = std::to_string((mUIElementCounter[i] * sizeof(float) * mLinkedListDataFormatSize) / 1e6f);
                    std::string fillRate = std::to_string(((mUIElementCounter[i]) / float(mLinkedListNodeBufferSize)) * 100.f);
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

        group.checkbox("Enable Jitter", mEnableHalton);
        if (mEnableHalton)
        {
            if (group.var("HaltonSamples", mNumHaltonSamples, 1u, 1024u, 1u))
                mGenLinkedListShadowPip.pVars.reset();
            group.tooltip("Number of Halton Samples");
        }

        /*
        dirty |= widget.checkbox("Use PCF", mUseLinkedListPcf);
        dirty |= widget.checkbox("Store as Array", mUseLinkedListArray);
        if (mUseLinkedListArray)
            mUseLinkedListPcf = false; // TODO implement pcf with array
        */
    }
    
    return dirty;
}

