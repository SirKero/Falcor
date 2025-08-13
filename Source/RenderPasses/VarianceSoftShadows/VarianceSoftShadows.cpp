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
#include "VarianceSoftShadows.h"
#include "RenderGraph/RenderPassHelpers.h"
#include "RenderGraph/RenderPassStandardFlags.h"

#include "Utils/Math/FalcorMath.h"

namespace
{
    const std::string kShaderFolder = "RenderPasses/VarianceSoftShadows/";
    const std::string kShaderShade = kShaderFolder + "Shade.cs.slang";
    const std::string kShaderCreateSAT = kShaderFolder + "CreateSAT.cs.slang";
    const std::string kShaderCreateHierarchicalShadowMap = kShaderFolder + "CreateHierarchicalShadowMap.cs.slang";
    const std::string kShaderGenerateShadowMap = kShaderFolder + "GenerateShadowMap.3d.slang";

    const std::string kInputVBuffer = "VBuffer";
    const std::string kInputView = "ViewW";
    const ChannelList kInputChannels = {
        {kInputVBuffer, "gVBuffer", "V-Buffer"},
        {kInputView, "gView", "View vector"},
    };

    // Outputs
    const std::string kOutputColor = "color";
    const ChannelList kOutputChannels = {
        {kOutputColor, "gOutColor", "Output Color (linear)", true /*optional*/, ResourceFormat::RGBA32Float},
    };

    Gui::DropdownList kSMResolutionDropdown{{512u, "512"}, {1024u, "1024"}, {2048u, "2048"}, {4096u, "4096"}, {8192u, "8192"}};

} // Namespace


extern "C" FALCOR_API_EXPORT void registerPlugin(Falcor::PluginRegistry& registry)
{
    registry.registerClass<RenderPass, VarianceSoftShadows>();
}

VarianceSoftShadows::VarianceSoftShadows(ref<Device> pDevice, const Properties& props)
    : RenderPass(pDevice)
{
    // Create a sample generator.
    mpSampleGenerator = SampleGenerator::create(mpDevice, SAMPLE_GENERATOR_UNIFORM);
    FALCOR_ASSERT(mpSampleGenerator);

    // Create samplers.
    Sampler::Desc samplerDesc;
    samplerDesc.setAddressingMode(Sampler::AddressMode::Clamp, Sampler::AddressMode::Clamp, Sampler::AddressMode::Clamp);
    samplerDesc.setFilterMode(Sampler::Filter::Linear, Sampler::Filter::Linear, Sampler::Filter::Linear);
    mpShadowSampler = Sampler::create(mpDevice, samplerDesc);
}

Properties VarianceSoftShadows::getProperties() const
{
    return {};
}

RenderPassReflection VarianceSoftShadows::reflect(const CompileData& compileData)
{
    // Define the required resources here
    RenderPassReflection reflector;
    addRenderPassInputs(reflector, kInputChannels);
    addRenderPassOutputs(reflector, kOutputChannels);
    return reflector;
}

void VarianceSoftShadows::execute(RenderContext* pRenderContext, const RenderData& renderData)
{
    FALCOR_PROFILE(pRenderContext, "VarianceSoftShadows");
    //If scene empty clear output
    if (!mpScene)
    {
        pRenderContext->clearTexture(renderData[kOutputColor]->asTexture().get());
        return;
    }

    prepareResources(pRenderContext, renderData);

    //Generate Shadow Map and needed resources
    generateShadowMaps(pRenderContext, renderData);
    createShadowMapSAT(pRenderContext, renderData);

    //Shade
    shadeSurfacePass(pRenderContext, renderData);


    mFrameCount++;
}

void VarianceSoftShadows::renderUI(Gui::Widgets& widget)
{
    bool dirty = false;

    dirty |= widget.var("Ambient Factor", mAmbientFactor);
    widget.tooltip("Factor for ambient light");
    dirty |= widget.var("Emissive Factor", mEmissiveFactor);
    widget.tooltip("Factor for the emissive light strength");
    dirty |= widget.var("EnvMap Factor", mEnvMapFactor);
    widget.tooltip("Factor for the env map sample");
    dirty |= widget.var("Spot Light Size", mSpotLightSize, 0.f, FLT_MAX, 0.001f);
    widget.tooltip("Light size input parameter for analytic spot lights");
    dirty |= widget.var("Sun size (deg)", mSunAngularDiameter, 0.f, 3.f, 0.001f);

    widget.separator();

    widget.text("Shadow Map Settings");
    mRebuildShadowMaps |= widget.dropdown("Shadow Map Resolution", kSMResolutionDropdown, mShadowMapResolution);
    dirty |= widget.var("Near,Far", mNearFar, 0.f, FLT_MAX, 0.001f);
    if (mSceneHasDirectionalLight)
    {
        if (widget.slider("Cascaded Level", mCascadedLevels, 1u, 8u))
        {
            updateLightCount(mpScene->getLights());
            resetRenderPasses();
        }
    }
    if (widget.var("SAT Uint convert bits", mSATMantissaBits, 16u, 23u, 1u))
        resetRenderPasses();
    widget.var("SAT max search radius (pixel)", mSATMaxSearchRadius, 1u, mShadowMapResolution / 4, 1u);
}

void VarianceSoftShadows::setScene(RenderContext* pRenderContext, const ref<Scene>& pScene)
{
    resetRenderPasses();

    if (pScene)
    {
        mpScene = pScene;
        updateLightCount(mpScene->getLights());
    }
}

void VarianceSoftShadows::resetRenderPasses()
{
    // Reset Passes
    mGenerateShadowMapPass.reset();
    mpCreateSATPass[0].reset();
    mpCreateSATPass[1].reset();
    mpCreateHierarchicalShadowMapPass.reset();
    mpShadePass.reset();

    mResetRenderPasses = false;
}

//TODO Currently this is lazily handled. We reserve 1 additional shadow map for directional lights, as we dont know at which index the directional light is
void VarianceSoftShadows::updateLightCount(const std::vector<ref<Light>>& pLights)
{
    mSceneHasDirectionalLight = false;
    mNumberShadowMaps = 0;
    mNumSpotLights = 0;

    //Update light count.
    for (uint i=0; i<pLights.size(); i++)
    {
        auto& light = pLights[i];
        if (light->getType() == LightType::Directional)
        {
            if (mSceneHasDirectionalLight)
            {
                throw RuntimeError(
                    "VarianceSoftShadow: Encountered more than 1 directional light. Please make sure only 1 directional light is in the "
                    "scene!"
                );
            }
            mSceneHasDirectionalLight = true;
            mNumberShadowMaps += mCascadedLevels + 1; 
        }
        else
        {
            mNumSpotLights++;
            mNumberShadowMaps++;
        }
    }

    if (mNumSpotLights == 0)
        mNumberShadowMaps--;

    //At least 1 light is needed
    if (mNumberShadowMaps <= 0)
        mNumberShadowMaps = 1;
}

void VarianceSoftShadows::prepareResources(RenderContext* pRenderContext, const RenderData& renderData)
{
    if (mRebuildShadowMaps)
    {
        mShadowMapRasterDepth.reset();
        mShadowMaps.clear();
        mSATVarianceShadowMaps.clear();
        mHierarchicalShadowMaps.clear();
        mRebuildShadowMaps = false;
        mShadowMVP.clear();
    }

    if (!mShadowMapRasterDepth)
    {
        mShadowMapRasterDepth = Texture::create2D(
            mpDevice, mShadowMapResolution, mShadowMapResolution, ResourceFormat::D32Float, 1u, 1u, nullptr,
            ResourceBindFlags::DepthStencil | ResourceBindFlags::ShaderResource
        );
        mShadowMapRasterDepth->setName("ShadowMapRasterDepth");
    }

    if (mShadowMaps.empty())
    {
        for (uint i = 0; i < mNumberShadowMaps; i++)
        {
            ref<Texture> shadowMap = Texture::create2D(
                mpDevice, mShadowMapResolution, mShadowMapResolution, ResourceFormat::R32Float, 1u, 1u, nullptr,
                ResourceBindFlags::RenderTarget | ResourceBindFlags::ShaderResource
            );
            shadowMap->setName("ShadowMap" + std::to_string(i));
            mShadowMaps.push_back(shadowMap);
        }
    }

    if (mSATVarianceShadowMaps.empty())
    {
        for (uint i = 0; i < mNumberShadowMaps; i++)
        {
            ref<Texture> shadowMap = Texture::create2D(
                mpDevice, mShadowMapResolution, mShadowMapResolution, ResourceFormat::RG32Uint, 1u, 1u, nullptr,
                ResourceBindFlags::UnorderedAccess | ResourceBindFlags::ShaderResource
            );
            shadowMap->setName("SATVarianceShadowMap" + std::to_string(i));
            mSATVarianceShadowMaps.push_back(shadowMap);
        }
    }

    if (mHierarchicalShadowMaps.empty())
    {
        for (uint i = 0; i < mNumberShadowMaps; i++)
        {
            ref<Texture> shadowMap = Texture::create2D(
                mpDevice, mShadowMapResolution / 2, mShadowMapResolution / 2, ResourceFormat::RG32Float, 1u, 1u, nullptr,
                ResourceBindFlags::UnorderedAccess | ResourceBindFlags::ShaderResource
            );
            shadowMap->setName("HierarchicalShadowMap" + std::to_string(i));
            mHierarchicalShadowMaps.push_back(shadowMap);
        }
    }

    if (mShadowMVP.empty())
    {
        mShadowMVP.resize(mNumberShadowMaps);
    }
}

void VarianceSoftShadows::generateShadowMaps(RenderContext* pRenderContext, const RenderData& renderData)
{
    FALCOR_PROFILE(pRenderContext, "UpdateShadowMap");

    //Init raster pipeline
    if (!mGenerateShadowMapPass.pProgram)
    {
        mGenerateShadowMapPass.pState = GraphicsState::create(mpDevice);
        Program::Desc desc;
        desc.addShaderModules(mpScene->getShaderModules());
        desc.addShaderLibrary(kShaderGenerateShadowMap).vsEntry("vsMain").psEntry("psMain");
        desc.addTypeConformances(mpScene->getTypeConformances());

        mGenerateShadowMapPass.pProgram = GraphicsProgram::create(mpDevice, desc, mpScene->getSceneDefines());
        mGenerateShadowMapPass.pState->setProgram(mGenerateShadowMapPass.pProgram);
        mGenerateShadowMapPass.pVars = GraphicsVars::create(mpDevice, mGenerateShadowMapPass.pProgram.get());
        mGenerateShadowMapPass.pFbo = Fbo::create(mpDevice);
    }

    //Render Spotlights
    auto& lights = mpScene->getLights();
    int directionalIndex = -1;
    for (uint i = 0; i < lights.size(); i++)
    {
        auto& light = lights[i];
        auto& lightData = light->getData();
        // Update Light View for Spot
        if (light->getType() == LightType::Point)
        {
            float3 lightTarget = lightData.posW + lightData.dirW;
            const float3 up = abs(lightData.dirW.y) == 1 ? float3(0, 0, 1) : float3(0, 1, 0);
            mShadowMVP[i].view = math::matrixFromLookAt(lightData.posW, lightTarget, up);
            mShadowMVP[i].projection = math::perspective(lightData.openingAngle * 2, 1.f, mNearFar.x, mNearFar.y); // TODO directional
            mShadowMVP[i].viewProjection = math::mul(mShadowMVP[i].projection, mShadowMVP[i].view);

            // if (mUseFrustumCulling)
            //     mFrustumCulling[index]->updateFrustum(lightData.posW, lightTarget, up, 1.f, lightData.openingAngle * 2, mNear, mFar);
        }
        else if (light->getType() == LightType::Directional)
        {
            directionalIndex = i;
            continue;
        }

        auto var = mGenerateShadowMapPass.pVars->getRootVar();
        mGenerateShadowMapPass.pFbo->attachDepthStencilTarget(mShadowMapRasterDepth);
        mGenerateShadowMapPass.pFbo->attachColorTarget(mShadowMaps[i], 0);

        mGenerateShadowMapPass.pState->setFbo(mGenerateShadowMapPass.pFbo);
        pRenderContext->clearFbo(mGenerateShadowMapPass.pFbo.get(), float4(1.f), 1.f, 0);

        var["CB"]["gViewProjection"] = mShadowMVP[i].viewProjection;
        var["CB"]["gNear"] = mNearFar.x;
        var["CB"]["gFar"] = mNearFar.y;

        /*
        if (mUseFrustumCulling)
        {
            mpScene->rasterizeFrustumCulling(
                pRenderContext, mShadowMapRasterPass.pState.get(), mShadowMapRasterPass.pVars.get(), mFrontClockwiseRS[mCullMode],
                mFrontCounterClockwiseRS[mCullMode], mFrontCounterClockwiseRS[RasterizerState::CullMode::None], renderMode, false,
                mFrustumCulling[index]
            );
        }
        else
        */
        {
            mpScene->rasterize(
                pRenderContext, mGenerateShadowMapPass.pState.get(), mGenerateShadowMapPass.pVars.get(), RasterizerState::CullMode::None
            );
        }
    }

    //Render Cascaded
    //TODO
    
}

void VarianceSoftShadows::createShadowMapSAT(RenderContext* pRenderContext, const RenderData& renderData) {
    FALCOR_PROFILE(pRenderContext, "CreateSAT");

    //Init Compute Pass
    if (!mpCreateSATPass[0] || !mpCreateSATPass[1])
    {
        Program::Desc desc;
        desc.addShaderLibrary(kShaderCreateSAT).csEntry("main").setShaderModel("6_5");

        //Horizontal
        {
            DefineList defines;
            defines.add("HORIZONTAL", "1");
            defines.add("NUM_SM", std::to_string(mNumberShadowMaps));
            defines.add("MAX_MANTISSA", std::to_string(math::pow(2.f, float(mSATMantissaBits))));
            mpCreateSATPass[0] = ComputePass::create(mpDevice, desc, defines, true);      
        }
        //Vertical
        {
            DefineList defines;
            defines.add("HORIZONTAL", "0");
            defines.add("NUM_SM", std::to_string(mNumberShadowMaps));
            defines.add("MAX_MANTISSA", std::to_string(math::pow(2.f, float(mSATMantissaBits))));
            mpCreateSATPass[1] = ComputePass::create(mpDevice, desc, defines, true);
        }
    }

    //Horizontal Dispatch
    {
        auto var = mpCreateSATPass[0]->getRootVar();
        var["CB"]["gShadowMapRes"] = mShadowMapResolution;
        for (uint i = 0; i < mNumberShadowMaps; i++)
        {
            var["gShadowMap"][i] = mShadowMaps[i];
            var["gSAT"][i] = mSATVarianceShadowMaps[i];
        }

        mpCreateSATPass[0]->execute(pRenderContext, uint3(mShadowMapResolution, mNumberShadowMaps,1));
    }
    //Barrier
    for (uint i = 0; i < mNumberShadowMaps; i++)
        pRenderContext->uavBarrier(mSATVarianceShadowMaps[i].get());

    //Vertical Dispatch
    {
        auto var = mpCreateSATPass[1]->getRootVar();
        var["CB"]["gShadowMapRes"] = mShadowMapResolution;
        for (uint i = 0; i < mNumberShadowMaps; i++)
        {
            var["gShadowMap"][i] = mShadowMaps[i];
            var["gSAT"][i] = mSATVarianceShadowMaps[i];
        }

        mpCreateSATPass[1]->execute(pRenderContext, uint3(mShadowMapResolution, mNumberShadowMaps, 1));
    }
}

void VarianceSoftShadows::shadeSurfacePass(RenderContext* pRenderContext, const RenderData& renderData)
{
    FALCOR_PROFILE(pRenderContext, "ShadeSurface");

    if (!mpShadePass)
    {
        Program::Desc desc;
        desc.addShaderModules(mpScene->getShaderModules());
        desc.addShaderLibrary(kShaderShade).csEntry("main").setShaderModel("6_5");
        desc.addTypeConformances(mpScene->getTypeConformances());

        DefineList defines;
        defines.add(mpScene->getSceneDefines());
        defines.add(mpSampleGenerator->getDefines());
        defines.add("USE_ENV_BACKROUND", mpScene->useEnvBackground() ? "1" : "0");
        defines.add("NUM_SM", std::to_string(mNumberShadowMaps));
        defines.add("CASCADED_OFFSET", std::to_string(mNumSpotLights));
        defines.add("CASCADED_LEVEL", std::to_string(mCascadedLevels));
        defines.add("MAX_MANTISSA", std::to_string(math::pow(2.f, float(mSATMantissaBits))));

        mpShadePass = ComputePass::create(mpDevice, desc, defines, true);        
    }
    FALCOR_ASSERT(mpShadePass);

    mpShadePass->getProgram()->addDefines(mpScene->getSceneDefines());

    auto var = mpShadePass->getRootVar();

    mpScene->setRaytracingShaderData(pRenderContext, var); // Set scene data
    mpSampleGenerator->setShaderData(var);                 // Sample generator

    // Constant Buffer
    var["CB"]["gFrameCount"] = mFrameCount;
    var["CB"]["gFrameDim"] = renderData.getDefaultTextureDims();
    var["CB"]["gAmbient"] = mAmbientFactor;
    var["CB"]["gEnvMapFac"] = mEnvMapFactor;
    var["CB"]["gEmissiveFac"] = mEmissiveFactor;
    var["CB"]["gSMNear"] = mNearFar.x;
    var["CB"]["gSMFar"] = mNearFar.y;
    var["CB"]["gSMSize"] = mShadowMapResolution;
    var["CB"]["gSATMaxSearchRadius"] = mSATMaxSearchRadius;
    var["CB"]["gSpotLightSize"] = mSpotLightSize;

    //Bind Shadow Maps
    for (uint i = 0; i < mNumberShadowMaps; i++)
    {
        var["CB_SMVMP"]["gSMView"][i] = mShadowMVP[i].view;
        var["CB_SMVMP"]["gSMProjection"][i] = mShadowMVP[i].projection;
        var["gSM"][i] = mShadowMaps[i];
        var["gSAT"][i] = mSATVarianceShadowMaps[i];
    }

    var["gSMSampler"] = mpShadowSampler;

    var["gVBuffer"] = renderData[kInputVBuffer]->asTexture();
    var["gView"] = renderData[kInputView]->asTexture();

    var["gColorOut"] = renderData[kOutputColor]->asTexture();

    // Execute
    const uint2 targetDim = renderData.getDefaultTextureDims();
    FALCOR_ASSERT(targetDim.x > 0 && targetDim.y > 0);
    mpShadePass->execute(pRenderContext, uint3(targetDim, 1));
}
