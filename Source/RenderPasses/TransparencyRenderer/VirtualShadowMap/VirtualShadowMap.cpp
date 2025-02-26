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
    const std::string kShaderFolder = "RenderPasses/TransparencyRenderer/VirtualShadowMap/";
    const std::string kGenShader = kShaderFolder + "GenVirtualShadowMap.rt.slang";
    //UI

}; // namespace

VirtualShadowMap::VirtualShadowMap(ref<Device> pDevice, ref<Scene> pScene) : TransparencyShadowMethod(pDevice, pScene)
{
    if (!mpDevice->isShaderModelSupported(Device::ShaderModel::SM6_5))
    {
        throw RuntimeError("ReSTIR_FG: Shader Model 6.5 is not supported by the current device");
    }
    if (!mpDevice->isFeatureSupported(Device::SupportedFeatures::RaytracingTier1_1))
    {
        throw RuntimeError("ReSTIR_FG: Raytracing Tier 1.1 is not supported by the current device");
    }
}

void VirtualShadowMap::prepareResources(RenderContext* pRenderContext)
{
    //setDirectionalLightSource();
    if (mpPhysicalClipMaps.empty())
    {
        mpPhysicalClipMaps.reserve(mNumClipMaps);
        for (size_t clipMap = 0; clipMap < mNumClipMaps; ++clipMap)
        {
            mpPhysicalClipMaps.push_back(Texture::create2D(
                mpDevice, mClipMapSize.x, mClipMapSize.y, ResourceFormat::R32Float, 1u, Texture::kMaxPossible,
                nullptr, ResourceBindFlags::UnorderedAccess | ResourceBindFlags::ShaderResource
            ));
            mpPhysicalClipMaps[clipMap]->setName("VSM::VirtualShadowMap" + std::to_string(clipMap));
        }
    }
    if (mpVirtualClipMaps.empty())
    {
        mpVirtualClipMaps.reserve(mNumClipMaps);
        for (size_t clipMap = 0; clipMap < mNumClipMaps; ++clipMap)
        {
            mpVirtualClipMaps.push_back(Texture::create2D(
                mpDevice, mVirtualClipMapSize.x, mVirtualClipMapSize.y, ResourceFormat::RG8Unorm, 1u, Texture::kMaxPossible,
                nullptr, ResourceBindFlags::UnorderedAccess | ResourceBindFlags::ShaderResource
            ));
            mpVirtualClipMaps[clipMap]->setName("VSM::ClipMapPage" + std::to_string(clipMap));
        }
    }
    if (!mGenVirtualShadowMapPip.pProgram)
    {
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
    updateViewProjection(mLightMVP, mpScene->getLights()[mDirectionalLightSourceIndex]);
    //updateSMMatrices();
}

void VirtualShadowMap::dummyProfileGeneration(RenderContext* pRenderContext)
{}

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

void VirtualShadowMap::updateViewProjection(LightMVP& lightMVP, ref<Light> pLight)
{
    auto& lightData = pLight->getData();
    switch (pLight->getType())
    {
    // Directional light. Create a prespective shadow map
    case LightType::Directional:
    {
        const AABB& sceneBounds = mpScene->getSceneBounds();
        float3 center = sceneBounds.center();
        const float3 upVec = float3(0, 1, 0);
        lightMVP.view = math::matrixFromLookAt(center, center + lightData.dirW, upVec); // Fixed point for view

        auto& cameraData = mpScene->getCamera()->getData();
        // Create a view space AABB to clamp cascaded values
        AABB smViewAABB = sceneBounds.transform(lightMVP.view);
        //Fixed Z
        float maxZ = math::ceil(smViewAABB.maxPoint.z);
        float minZ = math::floor(smViewAABB.minPoint.z);
        //Get Camera Position on a grid
        float2 camPosLV = math::mul(lightMVP.view, float4(cameraData.posW, 1.f)).xy();
        const float2 resF = float2(mClipMap0Resolution);
        camPosLV = math::round(camPosLV * resF) / resF;
        float minX = camPosLV.x - mClipMap0Extention;
        float maxX = camPosLV.x + mClipMap0Extention;
        float minY = camPosLV.y - mClipMap0Extention;
        float maxY = camPosLV.y + mClipMap0Extention;
        lightMVP.viewProjection = math::mul(math::ortho(minX, maxX, minY, maxY, -1.f * maxZ, -1.f * minZ), lightMVP.view); // set projection
        mClipMapOrigin = math::mul(lightMVP.viewProjection, float4(cameraData.posW, 1.f)).xy();
        lightMVP.invViewProjection = math::inverse(lightMVP.viewProjection);
        //Get scene projection to calculate the camera position in the Virtual Shadow Map (the clip map origin)
        maxX = math::ceil(smViewAABB.maxPoint.x);
        minX = math::floor(smViewAABB.minPoint.x);
        maxY = math::ceil(smViewAABB.maxPoint.y);
        minY = math::floor(smViewAABB.minPoint.y);
        float4x4 sceneViewProjectionMatrix = math::mul(math::ortho(minX, maxX, minY, maxY, -1.f * maxZ, -1.f * minZ), lightMVP.view);
        float2 clipMapOrigin = math::mul(sceneViewProjectionMatrix, float4(cameraData.posW,1.f)).xy();
        clipMapOrigin.y *= -1;
        clipMapOrigin = clipMapOrigin * 0.5f + 0.5f;
        clipMapOrigin = math::round(clipMapOrigin * float2(mClipMapSize));
        mClipMapOrigin = clipMapOrigin;
        mTopLeftClipMapCorner = uint2(clipMapOrigin.x - 128, clipMapOrigin.y + 128);
        float4x4 sceneProjectionMatrix = math::ortho(minX, maxX, minY, maxY, -1.f * maxZ, -1.f * minZ);
        float clipMap0Resolution = math::mul(sceneProjectionMatrix, float4(mClipMap0Extention, 0.f, 0.f, 1.f))[0];
        clipMap0Resolution = clipMap0Resolution * 0.5f;
        clipMap0Resolution = math::round(clipMap0Resolution * float(mClipMapSize.x));
        mClipMap0Resolution = uint2(clipMap0Resolution);
        break;
    }
    case LightType::Point:
    {
        lightMVP.pos = lightData.posW;
        float openingAngle = math::min(lightData.openingAngle, float(M_PI / 4.f)); // TODO support point lights
        float3 lightTarget = lightMVP.pos + lightData.dirW;
        const float3 up = abs(lightData.dirW.y) == 1 ? float3(0, 0, 1) : float3(0, 1, 0);
        lightMVP.view = math::matrixFromLookAt(lightData.posW, lightTarget, up);
        lightMVP.projectionNoJitter = math::perspective(openingAngle * 2, 1.f, mNearFar.x, mNearFar.y);
        lightMVP.spreadAngle = std::atan(2.0f * std::tan(openingAngle * 0.5f) / mResolution.y);
        break;
    }
    default:
        throw RuntimeError(
            "Scene contains unsupported Light Type (Distant, Rect, Disc, Sphere)\n Only Spot(+Point) and Directional are currently "
            "supported"
        );
        break;
    }
}

void VirtualShadowMap::generate(RenderContext* pRenderContext, const RenderData& renderData)
{
    FALCOR_PROFILE(pRenderContext, "PrepareResources");

    prepareResources(pRenderContext);

    // Runtime Defines
    //mGenVirtualShadowMapPip.pProgram->addDefine("MAX_IDX", std::to_string(mResolution.x * mResolution.y * mApproxNumElementsPerPixel));
    mGenVirtualShadowMapPip.pProgram->addDefine("NUM_MIPMAPS", std::to_string(1));

    // Create Program Vars
    if (!mGenVirtualShadowMapPip.pVars)
    {
        mGenVirtualShadowMapPip.pProgram->setTypeConformances(mpScene->getTypeConformances());
        mGenVirtualShadowMapPip.pVars = RtProgramVars::create(mpDevice, mGenVirtualShadowMapPip.pProgram, mGenVirtualShadowMapPip.pBindingTable);
    }

    FALCOR_ASSERT(mGenVirtualShadowMapPip.pVars);
    auto var = mGenVirtualShadowMapPip.pVars->getRootVar();
    var["CB"]["gViewProjection"] = mLightMVP.viewProjection; 
    var["CB"]["gInvViewProjection"] = mLightMVP.invViewProjection; 

    auto shadowDataVar = var["gVirtualShadowMapData"];
    shadowDataVar["SMCB"]["gClipMapSize"] = mClipMapSize;
    shadowDataVar["ShadowVPs"]["gViewProjection"] = mLightMVP.viewProjection;
    shadowDataVar["ShadowVPs"]["gInvViewProjection"] = mLightMVP.invViewProjection; 
    for (size_t clipMap = 0; clipMap < mNumClipMaps; ++clipMap)
        shadowDataVar["gPhysicalClipMaps"][clipMap] = mpPhysicalClipMaps[clipMap];
    for (size_t clipMap = 0; clipMap < mNumClipMaps; ++clipMap)
        shadowDataVar["gVirtualClipMaps"][clipMap] = mpVirtualClipMaps[clipMap];
    for (size_t clipMap = 0; clipMap < mNumClipMaps; ++clipMap)
        shadowDataVar["gPhysicalClipMapsRW"][clipMap] = mpPhysicalClipMaps[clipMap];
    for (size_t clipMap = 0; clipMap < mNumClipMaps; ++clipMap)
        shadowDataVar["gVirtualClipMapsRW"][clipMap] = mpVirtualClipMaps[clipMap];

    // Get dimensions of ray dispatch.
    uint2 targetDim = mClipMap0Resolution * mNumClipMaps;
        
    FALCOR_ASSERT(targetDim.x > 0 && targetDim.y > 0);

    // Spawn the rays.
    mpScene->raytrace(pRenderContext, mGenVirtualShadowMapPip.pProgram.get(), mGenVirtualShadowMapPip.pVars, uint3(targetDim, 1));
    mFrameCount++;
}

DefineList VirtualShadowMap::getDefines()
{
    DefineList defines = {};
    defines.add(TransparencyShadowMethod::getDefines());
    defines.add("NUM_CLIPMAPS", std::to_string(mNumClipMaps));
    return defines;
}

void VirtualShadowMap::setShaderData(const ShaderVar& var)
{
}

//TODO Some of the options should not be toggable for this pass as that will probably break the algorithm
bool VirtualShadowMap::renderUI(Gui::Widgets& widget)
{
    bool dirty = false;
    if (auto group = widget.group("Virtual Shadow Map Settings")) {
        dirty |= TransparencyShadowMethod::renderUI(widget);
        group.var("Clip Map 0 Extention", mClipMap0Extention, 2.f, 500.f, 0.5f);
        group.tooltip("Extention of the smallest clip map around the camera position.");
    }
    return true;
}

