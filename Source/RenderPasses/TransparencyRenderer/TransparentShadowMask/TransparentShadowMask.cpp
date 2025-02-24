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
const std::string kShaderFile = "RenderPasses/TransparencyRenderer/TransparentShadowMask/GenTransparentShadowMask.3d.slang";
}

TransparentShadowMask::TransparentShadowMask(ref<Device> pDevice, ref<Scene> pScene) : mpDevice(pDevice), mpScene(pScene)
{

}

void TransparentShadowMask::generate(RenderContext* pRenderContext, const RenderData& renderData,const TransparencyShadowMethod* pTransparencyShadowMethod) {
    FALCOR_PROFILE(pRenderContext,"GenerateTransparencyMasks");

    auto& lights = mpScene->getLights();
    const uint2 smRes = pTransparencyShadowMethod->getShadowMapResolution();
    auto& lightMVPs = pTransparencyShadowMethod->getLightMVPs();

    //Prepare Resources
    //Mask
    if (!mpTransparentShadowMask || mpTransparentShadowMask->getWidth() != smRes.x || mpTransparentShadowMask->getHeight() != smRes.y ||
        mpTransparentShadowMask->getArraySize() != lights.size())
    {
        mpTransparentShadowMask = Texture::create2D(
            mpDevice, smRes.x, smRes.y, ResourceFormat::R8Unorm, lights.size(), 1u, nullptr,
            ResourceBindFlags::RenderTarget | ResourceBindFlags::ShaderResource
        );
        mpTransparentShadowMask->setName("TransparentShadowMask");
    }
    //Depth
    if (!mpRasterDepth || mpRasterDepth->getWidth() != smRes.x || mpRasterDepth->getHeight() != smRes.y)
    {
        mpRasterDepth = Texture::create2D(
            mpDevice, smRes.x, smRes.y, ResourceFormat::D32Float, 1u, 1u, nullptr,
            ResourceBindFlags::DepthStencil
        );
        mpRasterDepth->setName("TransparentShadowMask_RasterDepth");
    }

     // Init Program
    if (!mGenerateMaskPip.pProgram)
    {
        // Init program
        Program::Desc desc;
        desc.addShaderLibrary(kShaderFile).vsEntry("vsMain").psEntry("psMain");
        desc.setShaderModel("6_6");
        desc.addShaderModules(mpScene->getShaderModules());
        desc.addTypeConformances(mpScene->getTypeConformances());

        auto defines = mpScene->getSceneDefines();
        defines.add("COUNT_LIGHTS", std::to_string(mpScene->getLightCount()));
        // Create Program and state
        mGenerateMaskPip.pProgram = GraphicsProgram::create(mpDevice, desc, defines);
        mGenerateMaskPip.pState = GraphicsState::create(mpDevice);

        // Set state
        mGenerateMaskPip.pState->setProgram(mGenerateMaskPip.pProgram);

        mGenerateMaskPip.pFBO = Fbo::create(mpDevice);
    }

    FALCOR_ASSERT(mGenerateMaskPip.pProgram);

    if (!mGenerateMaskPip.pVars)
    {
        mGenerateMaskPip.pVars = GraphicsVars::create(mpDevice, mGenerateMaskPip.pProgram.get());
    }

    auto var = mGenerateMaskPip.pVars->getRootVar();

    mGenerateMaskPip.pFBO->attachDepthStencilTarget(mpRasterDepth, 0u, 0u, 1u);
    auto meshRenderMode = RasterizerState::MeshRenderMode::SkipOpaque | RasterizerState::MeshRenderMode::SkipParticleCamera;

    //Raster pass over every light
    for (uint i = 0; i < lights.size(); i++)
    {
        FALCOR_PROFILE(pRenderContext, lights[i]->getName());
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
        mGenerateMaskPip.pFBO->attachColorTarget(mpTransparentShadowMask, 0u, 0u, i, 1u);
        mGenerateMaskPip.pState->setFbo(mGenerateMaskPip.pFBO);

        pRenderContext->clearFbo(mGenerateMaskPip.pFBO.get(), float4(0.f), 1.f, 0);

        //Set shader data
        var["CB"]["gViewProjection"] = lightMVPs[i].viewProjectionNoJitter;

        mpScene->rasterize(pRenderContext, mGenerateMaskPip.pState.get(), mGenerateMaskPip.pVars.get(), RasterizerState::CullMode::None,meshRenderMode);
    }
}
