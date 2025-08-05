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
#include "VirtualShadowMap.h"
#include "Utils/Math/FalcorMath.h"

namespace
{
    //Shader Paths
    const std::string kShaderFolder = "RenderPasses/VirtualShadowMapRenderer/VirtualShadowMap/";
    const std::string kSampleViewFrustum = kShaderFolder + "SampleViewFrustum.cs.slang";
    const std::string kUpdateOriginShift = kShaderFolder + "UpdateOriginShift.cs.slang";
    const std::string kUpdateClipMap = kShaderFolder + "UpdateClipMaps.cs.slang";
    const std::string kUpdateRenderBuffer = kShaderFolder + "UpdateRenderBuffer.cs.slang";
    const std::string kInvalidateRenderData = kShaderFolder + "InvalidateRenderData.cs.slang";
    const std::string kShaderDebugMemoryPass = kShaderFolder + "DebugMemoryPass.cs.slang";
    const std::string kGenShader = kShaderFolder + "GenVirtualShadowMap.rt.slang";
    //UI

}; // namespace

VirtualShadowMap::VirtualShadowMap(ref<Device> pDevice, ref<Scene> pScene, std::string vBufferName)
    : mpDevice(pDevice), mpScene(pScene), mVBufferName(vBufferName)
{
    if (!mpDevice->isShaderModelSupported(Device::ShaderModel::SM6_5))
    {
        throw RuntimeError("Virtual Shadow Map:Shader Model 6.5 is not supported by the current device");
    }
    if (!mpDevice->isFeatureSupported(Device::SupportedFeatures::RaytracingTier1_1))
    {
        throw RuntimeError("Virtual Shadow Map: Raytracing Tier 1.1 is not supported by the current device");
    }
}

void VirtualShadowMap::initAvailableMemoryStack()
{
    mAvailableMemorySize = mVirtualClipMapSize.x * mVirtualClipMapSize.y;
    std::vector<uint> initData(mAvailableMemorySize, 0);
    for (size_t index = 1; index < mAvailableMemorySize; ++index)
    {
        initData[index] = index % mVirtualClipMapSize.x * mPageSize.x + index / mVirtualClipMapSize.y * mPageSize.y * mClipMapSize.x;
    }
    mpAvailableMemoryStack.resize(0);
    mpAvailableMemoryStack.reserve(mNumClipMaps);
    for (size_t clipMap = 0; clipMap < mNumClipMaps; ++clipMap)
    {
        mpAvailableMemoryStack.push_back(Buffer::create(mpDevice, sizeof(uint) * mAvailableMemorySize, 
            ResourceBindFlags::UnorderedAccess | ResourceBindFlags::ShaderResource,
            Buffer::CpuAccess::None, 
            initData.data()
            ));
        mpAvailableMemoryStack[clipMap]->setName("VSM::AvailableMemoryStack" + std::to_string(clipMap));
    }
}

void VirtualShadowMap::initStackCounter()
{
    mStackCounterSize = mNumClipMaps + 1;
    std::vector<uint> initData(mStackCounterSize, mAvailableMemorySize);
    initData[mStackCounterSize - 1] = 0;
        mpStackCounter= Buffer::create(mpDevice, sizeof(uint) * mStackCounterSize,
            ResourceBindFlags::UnorderedAccess | ResourceBindFlags::ShaderResource,
            Buffer::CpuAccess::None,
            initData.data()
        );
        mpStackCounter->setName("VSM::StackCounter");
}

void VirtualShadowMap::prepareResources(RenderContext* pRenderContext)
{
    FALCOR_PROFILE(pRenderContext, "PrepareResources");
    //setDirectionalLightSource();
    if (mInitCameraPosWs.empty() || mResetRequired)
    {
        mInitCameraPosWs.resize(0);
        mInitCameraPosWs.reserve(mNumClipMaps);
    }
    if (mOverallOriginOffsets.empty() || mResetRequired)
    {
        mOverallOriginOffsets.resize(0);
        mOverallOriginOffsets.resize(mNumClipMaps, int2(0));
    }
    if (mLightVPs.empty() || mResetRequired)
    {
        mLightVPs.resize(0);
        mLightVPs.reserve(mNumClipMaps);
    }
    if (mClipMapOriginOffsets.empty() || mResetRequired)
    {
        mClipMapOriginOffsets.resize(0);
        mClipMapOriginOffsets.resize(mNumClipMaps * 2);
    }
    if (mpPhysicalClipMaps.empty() || mResetRequired)
    {
        mpPhysicalClipMaps.resize(0);
        mpPhysicalClipMaps.reserve(mNumClipMaps);
        for (size_t clipMap = 0; clipMap < mNumClipMaps; ++clipMap)
        {
            mpPhysicalClipMaps.push_back(Texture::create2D(
                mpDevice, mClipMapSize.x, mClipMapSize.y, ResourceFormat::R32Float, 1u, Texture::kMaxPossible,
                nullptr, ResourceBindFlags::UnorderedAccess | ResourceBindFlags::ShaderResource
            ));
            mpPhysicalClipMaps[clipMap]->setName("VSM::PhysicalClipMap" + std::to_string(clipMap));
        }
    }
    if (mpVirtualClipMaps.empty() || mResetRequired)
    {
        mpVirtualClipMaps.resize(0);
        mpVirtualClipMaps.reserve(mNumClipMaps);
        for (size_t clipMap = 0; clipMap < mNumClipMaps; ++clipMap)
        {
            mpVirtualClipMaps.push_back(Texture::create2D(
                mpDevice, mVirtualClipMapSize.x, mVirtualClipMapSize.y, ResourceFormat::R32Uint, 1u, Texture::kMaxPossible,
                nullptr, ResourceBindFlags::UnorderedAccess | ResourceBindFlags::ShaderResource
            ));
            mpVirtualClipMaps[clipMap]->setName("VSM::VirtualClipMap" + std::to_string(clipMap));
        }
    }
    if (mpAvailableMemoryStack.empty() || mResetRequired)
    {
        initAvailableMemoryStack();
    }
    if (!mpRenderBuffer || mRenderBudgetChanged)
    {
        mRenderBufferSize = mRenderBudget;
        mpRenderBuffer = Buffer::create(mpDevice, sizeof(uint) * mRenderBudget, 
            ResourceBindFlags::UnorderedAccess | ResourceBindFlags::ShaderResource
        );
        mpRenderBuffer->setName("VSM::RenderBuffer");
    }
    if (!mpStackCounter || mResetRequired)
    {
        initStackCounter();
    }
    if (!mpUpdateOriginShiftPass || mResetRequired)
    {
        mpUpdateOriginShiftPass.reset();
        Program::Desc desc;
        desc.addShaderLibrary(kUpdateOriginShift).csEntry("main").setShaderModel("6_6");

        DefineList defines;
        defines.add("NUM_CLIPMAPS", std::to_string(mNumClipMaps));
        mpUpdateOriginShiftPass = ComputePass::create(mpDevice, desc, defines, true);
    }
    if (!mpSampleViewFrustumPass || mResetRequired)
    {
        mpSampleViewFrustumPass.reset();
        Program::Desc desc;
        desc.addShaderModules(mpScene->getShaderModules());
        desc.addShaderLibrary(kSampleViewFrustum).csEntry("main").setShaderModel("6_6");
        desc.addTypeConformances(mpScene->getTypeConformances());

        DefineList defines;
        defines.add(mpScene->getSceneDefines());
        defines.add("NUM_CLIPMAPS", std::to_string(mNumClipMaps));
        mpSampleViewFrustumPass = ComputePass::create(mpDevice, desc, defines, true);
    }
    if (!mpUpdateVirtualClipMapPass || mResetRequired)
    {
        mpUpdateVirtualClipMapPass.reset();
        Program::Desc desc;
        desc.addShaderLibrary(kUpdateClipMap).csEntry("main").setShaderModel("6_6");

        DefineList defines;
        defines.add("NUM_CLIPMAPS", std::to_string(mNumClipMaps));
        mpUpdateVirtualClipMapPass = ComputePass::create(mpDevice, desc, defines, true);
    }
    if (!mpUpdateRenderBufferPass || mResetRequired)
    {
        mpUpdateRenderBufferPass.reset();
        Program::Desc desc;
        desc.addShaderLibrary(kUpdateRenderBuffer).csEntry("main").setShaderModel("6_6");

        DefineList defines;
        defines.add("NUM_CLIPMAPS", std::to_string(mNumClipMaps));
        mpUpdateRenderBufferPass = ComputePass::create(mpDevice, desc, defines, true);
    }
    if (!mpInvalidateRenderDataPass || mResetRequired)
    {
        mpInvalidateRenderDataPass.reset();
        Program::Desc desc;
        desc.addShaderLibrary(kInvalidateRenderData).csEntry("main").setShaderModel("6_6");

        DefineList defines;
        defines.add("NUM_CLIPMAPS", std::to_string(mNumClipMaps));
        mpInvalidateRenderDataPass = ComputePass::create(mpDevice, desc, defines, true);
    }
    if (!mGenVirtualShadowMapPip.pProgram || mResetRequired)
    {
        mGenVirtualShadowMapPip.resetPip();
        RtProgram::Desc desc;
        desc.addShaderModules(mpScene->getShaderModules());
        desc.addShaderLibrary(kGenShader);
        desc.setMaxPayloadSize(32u);
        desc.setMaxAttributeSize(mpScene->getRaytracingMaxAttributeSize());
        desc.setMaxTraceRecursionDepth(1u);

        mGenVirtualShadowMapPip.pBindingTable = RtBindingTable::create(1, 1, mpScene->getGeometryCount());
        auto& sbt = mGenVirtualShadowMapPip.pBindingTable;
        sbt->setRayGen(desc.addRayGen("rayGen"));
        sbt->setMiss(0, desc.addMiss("miss"));
        if (mpScene->hasGeometryType(Scene::GeometryType::TriangleMesh))
        {
            sbt->setHitGroup(0, mpScene->getGeometryIDs(Scene::GeometryType::TriangleMesh), desc.addHitGroup("closestHit", "anyHit"));
        }

        DefineList defines;
        defines.add("NUM_CLIPMAPS", std::to_string(mNumClipMaps));
        defines.add(mpScene->getSceneDefines());
        mGenVirtualShadowMapPip.pProgram = RtProgram::create(mpDevice, desc, defines);
    }
}

void VirtualShadowMap::dummyProfileGeneration(RenderContext* pRenderContext)
{
}

void VirtualShadowMap::setDirectionalLightSource() {
    uint numDirectionalLightSources = mpScene->getSceneStats().directionalLightCount;
    if (numDirectionalLightSources > 1)
        std::cout << "WARNING: More than one directional light source. \n";
    std::vector<ref<Light>> lightSources = mpScene->getLights();
    for (size_t lightIndex = 0; lightIndex < lightSources.size(); ++lightIndex)
    {
        ref<Light> currentLight = lightSources[lightIndex];
        if (currentLight->getType() == LightType::Directional)
        {
            mDirectionalLightSourceIndex = lightIndex;
            break;
        }
    }
}

void VirtualShadowMap::updateViewProjection(ref<Light> pLight)
{
    auto& lightData = pLight->getData();

    const AABB& sceneBounds = mpScene->getSceneBounds();
    auto& cameraData = mpScene->getCamera()->getData();
    //Get Camera Position on a grid
    float2 camPosLV = math::mul(mView, float4(cameraData.posW, 1.f)).xy();
    // Create a view space AABB to clamp cascaded values
    AABB smViewAABB = sceneBounds.transform(mView);
    //Fixed Z
    float maxZ = math::ceil(smViewAABB.maxPoint.z);
    float minZ = math::floor(smViewAABB.minPoint.z);
    float minX = 0; 
    float maxX = 0; 
    float minY = 0; 
    float maxY = 0; 
    if (mFirstExecute || mResetRequired)
    {
        //Size of a pixel of the virtual clip map in light space
        mVirtualClipMapExtentionInLightViewSpace  = float2(2 * mClipMap0Extention / mVirtualClipMapSize.x, 2 * mClipMap0Extention / mVirtualClipMapSize.y);
        float3 center = sceneBounds.center();
        const float3 upVec = float3(0, 1, 0);
        mView = math::matrixFromLookAt(center, center + lightData.dirW, upVec); // Fixed point for view
        camPosLV = math::mul(mView, float4(cameraData.posW, 1.f)).xy();
        smViewAABB = sceneBounds.transform(mView);
        //Fixed Z
        maxZ = math::ceil(smViewAABB.maxPoint.z);
        minZ = math::floor(smViewAABB.minPoint.z);
        for (size_t clipMap = 0; clipMap < mNumClipMaps; ++clipMap)
        {
            float clipMapPow = pow(2, clipMap);
            //Size of a pixel of the current virtual clip map in light space
            float2 clipMapRes = mVirtualClipMapExtentionInLightViewSpace * clipMapPow;
            //Clipping the camera position to the grid defined by the virtual clip map texture in light space
            float2 clipMapCamPosLV =float2(int2(camPosLV / clipMapRes)) * clipMapRes; 
            float clipMapExtention = mClipMap0Extention * clipMapPow;
            minX = clipMapCamPosLV.x - clipMapExtention;
            maxX = clipMapCamPosLV.x + clipMapExtention;
            minY = clipMapCamPosLV.y - clipMapExtention;
            maxY = clipMapCamPosLV.y + clipMapExtention;
            float4x4 viewProjection = math::mul(math::ortho(minX, maxX, minY, maxY, -1.f * maxZ, -1.f * minZ), mView);
            float4x4 invViewProjection = math::inverse(viewProjection);
            mLightVPs.push_back({viewProjection, invViewProjection});
            mInitCameraPosWs.push_back(clipMapCamPosLV);
        }
    }
    else
    {
        mMoved = false;
        for (size_t clipMap = 0; clipMap < mNumClipMaps; ++clipMap)
        {
            float clipMapPow = pow(2, clipMap);
            float2 clipMapRes = mVirtualClipMapExtentionInLightViewSpace * clipMapPow;
            float2 clipMapCamPosLV= float2(int2(camPosLV / clipMapRes)) * clipMapRes;
            int2 overallOriginOffset = int2((clipMapCamPosLV - mInitCameraPosWs[clipMap]) / (clipMapRes));
            overallOriginOffset.y *= -1;
            if (any(overallOriginOffset != mOverallOriginOffsets[clipMap]))
            {
                mMoved = true;
                float clipMapExtention = mClipMap0Extention * clipMapPow;
                minX = clipMapCamPosLV.x - clipMapExtention;
                maxX = clipMapCamPosLV.x + clipMapExtention;
                minY = clipMapCamPosLV.y - clipMapExtention;
                maxY = clipMapCamPosLV.y + clipMapExtention;
                mLightVPs[clipMap].viewProjection = math::mul(math::ortho(minX, maxX, minY, maxY, -1.f * maxZ, -1.f * minZ), mView); // set projection
                mLightVPs[clipMap].invViewProjection = math::inverse(mLightVPs[clipMap].viewProjection);
                //overall origin offset of the last frame
                mClipMapOriginOffsets[2 * clipMap] = mOverallOriginOffsets[clipMap] % (int2) mVirtualClipMapSize; 
                //current origin offset
                mClipMapOriginOffsets[2 * clipMap + 1] = (overallOriginOffset - mOverallOriginOffsets[clipMap]) % (int2) mVirtualClipMapSize;
                mOverallOriginOffsets[clipMap] = overallOriginOffset; 
            }
        }
    }
}
//Invalidates the data of the virtual shadow map and pushes the freed addresses back to the available memory stack based on the clip map origin shift
void VirtualShadowMap::shiftClipMapOrigin(RenderContext* pRenderContext)
{
    FALCOR_PROFILE(pRenderContext, "ShiftOrigin");
    uint2 dispatchResolution = mVirtualClipMapSize;
    dispatchResolution.x *= mNumClipMaps;
    auto prepareCmpVar = mpUpdateOriginShiftPass->getRootVar();
    setShadowData(prepareCmpVar, false);
    mpUpdateOriginShiftPass->execute(pRenderContext, dispatchResolution.x, dispatchResolution.y);
    for (size_t clipMapLevel = 0; clipMapLevel < mNumClipMaps; ++clipMapLevel)
    {
        pRenderContext->uavBarrier(mpVirtualClipMaps[clipMapLevel].get());
        pRenderContext->uavBarrier(mpAvailableMemoryStack[clipMapLevel].get());
    }
    pRenderContext->uavBarrier(mpStackCounter.get());
}
//samples the view frustum and checks which pages are requried for the current frame 
void VirtualShadowMap::sampleViewFrustum(RenderContext* pRenderContext, const RenderData& renderData)
{
    FALCOR_PROFILE(pRenderContext, "SampleViewFrustum");
    uint2 dispatchResolution = renderData.getDefaultTextureDims();
    auto prepareCmpVar = mpSampleViewFrustumPass->getRootVar();

    prepareCmpVar["CB"]["gFrameDim"] = renderData.getDefaultTextureDims();

    prepareCmpVar["gVBuffer"] = renderData[mVBufferName]->asTexture();
    setShadowData(prepareCmpVar, false);
    mpScene->setRaytracingShaderData(pRenderContext,prepareCmpVar, 1); // Set scene data
    mpSampleViewFrustumPass->execute(pRenderContext, dispatchResolution.x, dispatchResolution.y);
    for (size_t clipMapLevel = 0; clipMapLevel < mNumClipMaps; ++clipMapLevel)
    {
        pRenderContext->uavBarrier(mpVirtualClipMaps[clipMapLevel].get());
    }
}
//assigns memory to newly accquired pages
void VirtualShadowMap::updateClipMaps(RenderContext* pRenderContext)
{
    FALCOR_PROFILE(pRenderContext, "ReserveMemory");
    uint2 dispatchResolution = mVirtualClipMapSize;
    dispatchResolution.x *= mNumClipMaps;
    auto prepareCmpVar = mpUpdateVirtualClipMapPass->getRootVar();
    setShadowData(prepareCmpVar, false);
    mpUpdateVirtualClipMapPass->execute(pRenderContext, dispatchResolution.x, dispatchResolution.y);
    for (size_t clipMapLevel = 0; clipMapLevel < mNumClipMaps; ++clipMapLevel)
    {
        pRenderContext->uavBarrier(mpVirtualClipMaps[clipMapLevel].get());
        pRenderContext->uavBarrier(mpAvailableMemoryStack[clipMapLevel].get());
    }
}
//adds the pages that need to be rendered into the render buffer until the current render budget has been reached. Prioritizes higher clip map levels 
void VirtualShadowMap::updateRenderBuffer(RenderContext* pRenderContext)
{
    FALCOR_PROFILE(pRenderContext, "UpdateRenderBuffer");
    uint2 dispatchResolution = mVirtualClipMapSize;
    auto prepareCmpVar = mpUpdateRenderBufferPass->getRootVar();
    setShadowData(prepareCmpVar, false);
    mpUpdateRenderBufferPass->execute(pRenderContext, dispatchResolution.x, dispatchResolution.y);
    for (size_t clipMapLevel = 0; clipMapLevel < mNumClipMaps; ++clipMapLevel)
    {
        pRenderContext->uavBarrier(mpVirtualClipMaps[clipMapLevel].get());
    }
    pRenderContext->uavBarrier(mpRenderBuffer.get());
}
//resets the counter for the render buffer
void VirtualShadowMap::invalidateRenderData(RenderContext* pRenderContext)
{
    FALCOR_PROFILE(pRenderContext, "InvalidateRenderData");
    uint dispatchResolution = mRenderBudget;
    auto prepareCmpVar =mpInvalidateRenderDataPass->getRootVar();
    setShadowData(prepareCmpVar, false);
    mpInvalidateRenderDataPass->execute(pRenderContext, dispatchResolution, 1);
    pRenderContext->uavBarrier(mpRenderBuffer.get());
}

void VirtualShadowMap::generate(RenderContext* pRenderContext, const RenderData& renderData)
{
    FALCOR_PROFILE(pRenderContext, "Generate Virtual Shadow Maps");
    prepareResources(pRenderContext);
    updateViewProjection(mpScene->getLights()[mDirectionalLightSourceIndex]);
    invalidateRenderData(pRenderContext);
    if (mMoved)
        shiftClipMapOrigin(pRenderContext);
    else
    {
        FALCOR_PROFILE(pRenderContext, "ShiftOrigin");
    }
    mFirstExecute = false;
    sampleViewFrustum(pRenderContext, renderData);
    updateClipMaps(pRenderContext);
    updateRenderBuffer(pRenderContext);

    FALCOR_PROFILE(pRenderContext, "RenderShadows");

    // Create Program Vars
    if (!mGenVirtualShadowMapPip.pVars)
    {
        mGenVirtualShadowMapPip.pProgram->setTypeConformances(mpScene->getTypeConformances());
        mGenVirtualShadowMapPip.pVars = RtProgramVars::create(mpDevice, mGenVirtualShadowMapPip.pProgram, mGenVirtualShadowMapPip.pBindingTable);
    }
    // Set up shadow pass shader variables 
    FALCOR_ASSERT(mGenVirtualShadowMapPip.pVars);
    auto var = mGenVirtualShadowMapPip.pVars->getRootVar();
    setShadowData(var, false);
    // Get dimensions of ray dispatch.
    uint2 targetDim = uint2(mRenderBudget * mPageSize.x * mPageSize.y, 1); 
        
    FALCOR_ASSERT(targetDim.x > 0 && targetDim.y > 0);

    // Spawn the rays.
    mpScene->raytrace(pRenderContext, mGenVirtualShadowMapPip.pProgram.get(), mGenVirtualShadowMapPip.pVars, uint3(targetDim, 1));
    mFrameCount++;

    mResetRequired = false;
    mRenderBudgetChanged = false;
}

bool VirtualShadowMap::requireReset()
{
    return mResetRequired;
}

DefineList VirtualShadowMap::getDefines()
{
    DefineList defines = {};
    defines.add("COUNT_LIGHTS", std::to_string(std::max(mpScene->getLightCount(), 1u)));
    defines.add("NUM_CLIPMAPS", std::to_string(mNumClipMaps));
    return defines;
}


void VirtualShadowMap::setShadowData(const ShaderVar& var, bool readOnly)
{
    auto shadowDataVar = var["gVirtualShadowMapData"];
    shadowDataVar["SMCB"]["gClipMapSize"] = mClipMapSize;
    shadowDataVar["SMCB"]["gCameraPosW"] = mpScene->getCamera()->getData().posW; 
    shadowDataVar["SMCB"]["gRenderBudget"] = mRenderBudget; 
    shadowDataVar["SMCB"]["gPageSize"] = mPageSize;
    shadowDataVar["SMCB"]["gVirtualClipMapSize"] = mVirtualClipMapSize;
    shadowDataVar["MemoryManagementResources"]["gAvailableMemorySize"] = mAvailableMemorySize;
    shadowDataVar["MemoryManagementResources"]["gRenderBufferSize"] = mRenderBufferSize;
    shadowDataVar["MemoryManagementResources"]["gCountBufferSize"] = mStackCounterSize;
    if (readOnly)
    {
        for (size_t clipMap = 0; clipMap < mNumClipMaps; ++clipMap)
        {
            shadowDataVar["gPhysicalClipMaps"][clipMap] = mpPhysicalClipMaps[clipMap];
            shadowDataVar["gVirtualClipMaps"][clipMap] = mpVirtualClipMaps[clipMap];
            shadowDataVar["gAvailableMemoryStack"][clipMap] = mpAvailableMemoryStack[clipMap];
        }
    }
    else
    {
        for (size_t clipMap = 0; clipMap < mNumClipMaps; ++clipMap)
        {
            shadowDataVar["gPhysicalClipMapsRW"][clipMap] = mpPhysicalClipMaps[clipMap];
            shadowDataVar["gVirtualClipMapsRW"][clipMap] = mpVirtualClipMaps[clipMap];
            shadowDataVar["gAvailableMemoryStack"][clipMap] = mpAvailableMemoryStack[clipMap];
        }
    }
    for (size_t index = 0; index < 2 * mNumClipMaps; ++index)
        shadowDataVar["SMCB"]["gClipMapOriginOffsets"][index] = mClipMapOriginOffsets[index];
    for (size_t clipMap = 0; clipMap < mNumClipMaps; ++clipMap)
    {
        shadowDataVar["ShadowVPs"]["gViewProjection"][clipMap] = mLightVPs[clipMap].viewProjection;
        shadowDataVar["ShadowVPs"]["gInvViewProjection"][clipMap] = mLightVPs[clipMap].invViewProjection;
    }
    shadowDataVar["gStackCounter"] = mpStackCounter;
    shadowDataVar["gRenderBuffer"] = mpRenderBuffer;
}

void VirtualShadowMap::setShaderData(const ShaderVar& var)
{
    setShadowData(var, true);
    auto shadowDataVar = var["gVirtualShadowMapEval"];
    shadowDataVar["ReadAdjustments"]["gDepthBias"] = mDepthBias;
}

bool VirtualShadowMap::renderUI(Gui::Widgets& widget)
{
    bool dirty = false;
    if (auto group = widget.group("Virtual Shadow Map Settings")) {
        //dirty |= TransparencyShadowMethod::renderUI(widget);
        group.text("Clipmap Size: " + std::to_string(mClipMapSize.x) + "^2");
        group.text("Page size: " + std::to_string(mPageSize.x) + "^2");

        mResetRequired |= group.var("Clip Map 0 Extention", mClipMap0Extention, 0.125f, 500.f, 0.125f);
        group.tooltip("Extention of the smallest clip map around the camera position.");
        mResetRequired |= group.var("Number Of Clipmaps", mNumClipMaps, 1u, 32u);
        mRenderBudgetChanged |= group.var("Render Budget", mRenderBudget, 1u, 8192u);
        group.tooltip("Number of pages  that can be rendered");
        group.var("Depth Bias", mDepthBias, 0.f, std::numeric_limits<float>::max(), 1e-6f, false, "%.6f");
        group.tooltip("Number of pages that will be rendered each frame.");
        group.checkbox("Enable Memory Debug View", mShowMemoryDebugView);
    }
    return true;
}

void VirtualShadowMap::debugPass(RenderContext* pRenderContext,const RenderData& renderData, ref<Texture> debugOut)
{
    //Early return if disabled
    if (!mShowMemoryDebugView)
        return;

    FALCOR_PROFILE(pRenderContext, "MemoryDebugView");

    const uint2 dims = renderData.getDefaultTextureDims();
    // Init Program
    if (!mpDebugMemoryPass || mResetRequired)
    {
        Program::Desc desc;
        desc.addShaderLibrary(kShaderDebugMemoryPass).csEntry("main").setShaderModel("6_6");

        DefineList defines;
        defines.add("NUM_CLIPMAPS", std::to_string(mNumClipMaps));
        mpDebugMemoryPass = ComputePass::create(mpDevice, desc, defines, true);
    }

    auto prepareCmpVar = mpDebugMemoryPass->getRootVar();
    prepareCmpVar["gDebugOut"] = debugOut;
    setShadowData(prepareCmpVar, true);
    uint2 dispatchResolution = renderData.getDefaultTextureDims();
    mpDebugMemoryPass->execute(pRenderContext, dispatchResolution.x, dispatchResolution.y);
}

