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

namespace
{
    //Shader Paths
    const std::string kShaderFolder = "RenderPasses/TransparencyRenderer/LinkedList/";
    const std::string kShaderLinkedList = kShaderFolder + "GenLinkedList.rt.slang";
    const std::string kShaderLinkedListNeighbors = kShaderFolder + "GenLinkedListNeighbors.cs.slang";

    //UI
    

}; // namespace

LinkedListShadow::LinkedListShadow(ref<Device> pDevice, ref<Scene> pScene) : TransparencyShadowMethod(pDevice, pScene)
{
    mpLinkedListCounter = Buffer::createStructured(
        mpDevice, sizeof(uint), 1, ResourceBindFlags::UnorderedAccess | ResourceBindFlags::ShaderResource, Buffer::CpuAccess::None, nullptr,
        false
    );
    mpLinkedListCounter->setName("LinkedListCounter");

    mpLinkedListCounter2 = Buffer::createStructured(
        mpDevice, sizeof(uint), 1, ResourceBindFlags::UnorderedAccess | ResourceBindFlags::ShaderResource, Buffer::CpuAccess::None, nullptr,
        false
    );
    mpLinkedListCounter2->setName("LinkedListCounter2");

}

void LinkedListShadow::prepareResources(RenderContext* pRenderContext)
{
    //Prepare Generate shaders/programms
    if (!mGenLinkedListPip.pProgram)
    {
        RtProgram::Desc desc;
        desc.addShaderModules(mpScene->getShaderModules());
        desc.addShaderLibrary(kShaderLinkedList);
        desc.setMaxPayloadSize(4 * 3);
        desc.setMaxAttributeSize(mpScene->getRaytracingMaxAttributeSize());
        desc.setMaxTraceRecursionDepth(1u);

        mGenLinkedListPip.pBindingTable = RtBindingTable::create(1, 1, mpScene->getGeometryCount());
        auto& sbt = mGenLinkedListPip.pBindingTable;
        sbt->setRayGen(desc.addRayGen("rayGen"));
        sbt->setMiss(0, desc.addMiss("miss"));

        if (mpScene->hasGeometryType(Scene::GeometryType::TriangleMesh))
        {
            sbt->setHitGroup(0, mpScene->getGeometryIDs(Scene::GeometryType::TriangleMesh), desc.addHitGroup("closestHit", "anyHit"));
        }

        DefineList defines;
        defines.add(mpScene->getSceneDefines());
        defines.add("MAX_INDEX", std::to_string(mLinkedElementCount));

        mGenLinkedListPip.pProgram = RtProgram::create(mpDevice, desc, defines);
    }
    if (!mpLinkedListNeighborsPass)
    {
        mpLinkedListNeighborsPass = ComputePass::create(mpDevice, kShaderLinkedListNeighbors);
    }

    auto& lights = mpScene->getLights();

    // Create / Destroy resources
    {
        mpLinkedList.resize(lights.size());
        mpLinkedListNeighbors.resize(lights.size());
        mpLinkedListArray.resize(lights.size());
        mpLinkedListArrayOffsets.resize(lights.size());

        for (size_t i = 0; i < mpLinkedList.size(); i++)
        {
            auto& pList = mpLinkedList[i];
            auto& pListNeighbors = mpLinkedListNeighbors[i];
            auto& pListArray = mpLinkedListArray[i];
            auto& pListArrayOffsets = mpLinkedListArrayOffsets[i];

            if (!pList || pList->getElementCount() != mLinkedElementCount)
            {
                pList = Buffer::createStructured(mpDevice, sizeof(float) * 3, mLinkedElementCount);
                pList->setName("LinkedList_" + std::to_string(i));
            }
            if (mUseLinkedListPcf)
            {
                if (!pListNeighbors || pListNeighbors->getElementCount() != mLinkedElementCount)
                {
                    pListNeighbors = Buffer::createStructured(mpDevice, sizeof(float) * 3, mLinkedElementCount);
                    pListNeighbors->setName("LinkedListNeighbors_" + std::to_string(i));
                }
            }
            else
                pListNeighbors.reset();
            if (mUseLinkedListArray)
            {
                if (!pListArray || pListArray->getElementCount() != mLinkedElementCount)
                {
                    pListArray = Buffer::createStructured(mpDevice, sizeof(float) * 2, mLinkedElementCount);
                    pListArray->setName("LinkedListArray_" + std::to_string(i));
                }
                if (!pListArrayOffsets || pListArrayOffsets->getWidth() != mResolution.x || pListArrayOffsets->getHeight() != mResolution.y)
                {
                    pListArrayOffsets = Texture::create2D(
                        mpDevice, mResolution.x, mResolution.y, ResourceFormat::RG32Uint, 1, 1, nullptr,
                        ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess
                    );
                    pListArrayOffsets->setName("LinkedListArrayOffsets_" + std::to_string(i));
                }
            }
        }
    }

    //Update Matrices
    updateSMMatrices(pRenderContext);
}

void LinkedListShadow::generate(RenderContext* pRenderContext, const RenderData& renderData)
{
    FALCOR_PROFILE(pRenderContext, "Generate Linked List");

    prepareResources(pRenderContext);

    mLLRayFlags = mOpaqueShadowMapEnabled ? RayFlags::CullOpaque : RayFlags::None;

     // Defines
    mGenLinkedListPip.pProgram->addDefine("LL_DEPTH_BIAS", std::to_string(mDepthBias));
    mGenLinkedListPip.pProgram->addDefine("LL_NORMAL_DEPTH_BIAS", std::to_string(mNormalDepthBias));
    mGenLinkedListPip.pProgram->addDefine("LL_RAY_FLAGS", std::to_string((uint)mLLRayFlags));
    if (mUseLinkedListArray)
    {
        mGenLinkedListPip.pProgram->addDefine("USE_LINKED_LIST_ARRAY");
    }
    else
    {
        mGenLinkedListPip.pProgram->removeDefine("USE_LINKED_LIST_ARRAY");
    }

    // Create Program Vars
    if (!mGenLinkedListPip.pVars)
    {
        mGenLinkedListPip.pProgram->setTypeConformances(mpScene->getTypeConformances());
        mGenLinkedListPip.pVars = RtProgramVars::create(mpDevice, mGenLinkedListPip.pProgram, mGenLinkedListPip.pBindingTable);
    }

    FALCOR_ASSERT(mGenLinkedListPip.pVars);

    auto& lights = mpScene->getLights();
    // Trace the pass for every light
    for (uint i = 0; i < lights.size(); i++)
    {
        if (!lights[i]->isActive())
            break;
        FALCOR_PROFILE(pRenderContext, lights[i]->getName());

        // clear to first free index after the head
        pRenderContext->clearUAV(mpLinkedListCounter->getUAV(0, 1).get(), uint4(mResolution.x * mResolution.y));

        // Bind Utility
        auto var = mGenLinkedListPip.pVars->getRootVar();
        var["CB"]["gFrameCount"] = mFrameCount;
        var["CB"]["gLightPos"] = mShadowMapMVP[i].pos;
        var["CB"]["gNear"] = mNearFar.x;
        var["CB"]["gFar"] = mNearFar.y;
        var["CB"]["gViewProj"] = mShadowMapMVP[i].viewProjection;
        var["CB"]["gInvViewProj"] = mShadowMapMVP[i].invViewProjection;
        var["CB"]["gView"] = mShadowMapMVP[i].view;
        float rayConeAngle =
            std::atan(2.0f * std::tan(lights[i]->getData().openingAngle /*opening angle is already halved*/) / float(std::max(mResolution.x, mResolution.y)));
        var["CB"]["gRayConeAngle"] = rayConeAngle;

        var["gLinkedList"] = mpLinkedList[i];
        var["gCounter"] = mpLinkedListCounter;

        if (mUseLinkedListArray)
        {
            pRenderContext->clearUAV(mpLinkedListCounter2->getUAV(0, 1).get(), uint4(0));

            var["gArray"] = mpLinkedListArray[i];
            var["gArrayOffsets"] = mpLinkedListArrayOffsets[i];
            var["gCounter2"] = mpLinkedListCounter2;
        }

        // Get dimensions of ray dispatch.
        const uint2 targetDim = uint2(mResolution);
        FALCOR_ASSERT(targetDim.x > 0 && targetDim.y > 0);

        // Spawn the rays.
        mpScene->raytrace(pRenderContext, mGenLinkedListPip.pProgram.get(), mGenLinkedListPip.pVars, uint3(targetDim, 1));

        if (mUseLinkedListPcf)
        {
            // link neighbors
            auto var2 = mpLinkedListNeighborsPass->getRootVar();
            var2["CB"]["SMSize"] = mResolution.x; //width only for buffer offset
            var2["gLinkedList"] = mpLinkedList[i];
            var2["gLinkedListNeighbors"] = mpLinkedListNeighbors[i];
            mpLinkedListNeighborsPass->execute(pRenderContext, mResolution.x, mResolution.y);
        }
    }
}

DefineList LinkedListShadow::getDefines()
{
    DefineList defines = {};
    defines.add(TransparencyShadowMethod::getDefines());
    defines.add("USE_LINKED_PCF", mUseLinkedListPcf ? "1" : "0");
    defines.add("USE_LINKED_LIST_ARRAY", mUseLinkedListArray ? "1" : "0");

    return defines;
}

void LinkedListShadow::setShaderData(const ShaderVar& var)
{
    auto shadowVar = var["gLinkedListShadow"];

    shadowVar["SMCB"]["gSMSize"] = mResolution;
    shadowVar["SMCB"]["gNear"] = mNearFar.x;
    shadowVar["SMCB"]["gFar"] = mNearFar.y;

    for (uint i = 0; i < mpScene->getLightCount(); i++)
    {
        shadowVar["ShadowVPs"]["gShadowMapVP"][i] = mShadowMapMVP[i].viewProjection;
        shadowVar["gLinkedList"][i] = mpLinkedList[i];
        shadowVar["gLinkedListNeighbors"][i] = mpLinkedListNeighbors[i];
        shadowVar["gLinkedListArrays"][i] = mpLinkedListArray[i];
        shadowVar["gLinkedListArrayOffsets"][i] = mpLinkedListArrayOffsets[i];
    }
}

bool LinkedListShadow::renderUI(Gui::Widgets& widget)
{
    bool dirty = false;
    if (auto group = widget.group("Linked List settings"))
    {
        dirty |= TransparencyShadowMethod::renderUI(widget);

        dirty |= widget.var("Max Elements", mLinkedElementCount, 1u, std::numeric_limits<uint32_t>::max());
        dirty |= widget.checkbox("Use PCF", mUseLinkedListPcf);
        dirty |= widget.checkbox("Store as Array", mUseLinkedListArray);
        if (mUseLinkedListArray)
            mUseLinkedListPcf = false; // TODO implement pcf with array
    }
    
    return dirty;
}

