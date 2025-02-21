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
    setDirectionalLightSource();
    if (!mpVirtualShadowMap)
    {
        mpVirtualShadowMap = Texture::create2D(mpDevice, 8192, 8192, ResourceFormat::R32Float, 1u, Texture::kMaxPossible, nullptr, ResourceBindFlags::UnorderedAccess | ResourceBindFlags::ShaderResource);
        mpVirtualShadowMap->setName("VSM::VirtualShadowMap");
    }
    if (!mpFeedbackTexture)
    {
        mpFeedbackTexture= Texture::create2D(mpDevice, 64, 64, ResourceFormat::R8Unorm, 1u, Texture::kMaxPossible, nullptr, ResourceBindFlags::UnorderedAccess | ResourceBindFlags::ShaderResource);
        mpFeedbackTexture->setName("VSM::FeedbackTexture");
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

void VirtualShadowMap::genLightMVPs() {
    mLightMVPs.resize(1);

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
    var["CB"]["gDirectionalLightSourceIndex"] = mDirectionalLightSourceIndex; 
    for (size_t mipMapLevel = 0; mipMapLevel < 1; ++mipMapLevel)
    {
        var["CB"]["gLightMVPs"][mipMapLevel] = mLightMVPs; 
    }
    var["gVirtualShadowMap"] = mpVirtualShadowMap; 
    var["gFeedbackTexture"] = mpFeedbackTexture; 

    // Get dimensions of ray dispatch.
    uint2 targetDim = mResolution;
        
    FALCOR_ASSERT(targetDim.x > 0 && targetDim.y > 0);

    // Spawn the rays.
    mpScene->raytrace(pRenderContext, mGenVirtualShadowMapPip.pProgram.get(), mGenVirtualShadowMapPip.pVars, uint3(targetDim, 1));
    mFrameCount++;
}

DefineList VirtualShadowMap::getDefines()
{
    DefineList defines = {};
    //defines.add(TransparencyShadowMethod::getDefines());
    //defines.add("USE_COLOR_TRANSPARENCY", mUseColoredTransparency ? "1" : "0");
    return defines;
}

void VirtualShadowMap::setShaderData(const ShaderVar& var)
{
}

//TODO Some of the options should not be toggable for this pass as that will probably break the algorithm
bool VirtualShadowMap::renderUI(Gui::Widgets& widget)
{
    return true;
}

