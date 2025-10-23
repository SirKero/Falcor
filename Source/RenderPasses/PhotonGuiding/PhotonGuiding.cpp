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
#include "PhotonGuiding.h"
#include "Utils/Math/FalcorMath.h"
#include "RenderGraph/RenderPassHelpers.h"
#include "RenderGraph/RenderPassStandardFlags.h"

#include "Rendering/Lights/EmissiveUniformSampler.h"
#include "Rendering/Lights/EmissivePowerSampler.h"

namespace
{
    //Shader
    const std::string kShaderFolder = "RenderPasses/PhotonGuiding/";
    const std::string kShaderTracePhoton = kShaderFolder + "TracePhoton.rt.slang";
    const std::string kShaderTraceCamera = kShaderFolder + "TraceCamera.rt.slang";
    const std::string kShaderGuidingGenMipTraverseChain = kShaderFolder + "GuidingTextureGenMipTraverseChain.cs.slang";
    const std::string kShaderMapGuidingToPhotons = kShaderFolder + "MapGuidingToPhotons.cs.slang";
    const std::string kShaderGuidingBlurAtlas = kShaderFolder + "GuidingBlurAtlas.cs.slang";
    const std::string kShaderGuidingReduce = kShaderFolder + "GuidingCounterReduce.cs.slang";
    const std::string kShaderDebug = kShaderFolder + "Debug.cs.slang";

    //ReSTIR shader
    const std::string kShaderFolderReSTIR = kShaderFolder + "/ReSTIR_FG/";
    const std::string kShaderReSTIRInitialSamples = kShaderFolderReSTIR + "GenerateInitialSamples.rt.slang";
    const std::string kShaderReSTIRResampleFG = kShaderFolderReSTIR + "ResampleReservoirFG.cs.slang";
    const std::string kShaderReSTIRResampleCaustic = kShaderFolderReSTIR + "ResampleReservoirCaustic.cs.slang";
    const std::string kShaderReSTIREvalReservoirs = kShaderFolderReSTIR + "EvaluateReservoirs.cs.slang";
    const std::string kShaderReSTIRTemporalSplatReservoirs = kShaderFolderReSTIR + "TemporalSplatReservoir.cs.slang";
    const std::string kShaderReSTIRSortSplatReservoirs = kShaderFolderReSTIR + "SortSplatReservoirs.cs.slang";

    //Input Textures
    const std::string kInputVBuffer = "VBuffer";
    const std::string kInputView = "View";
    const std::string kInputMVec = "MotionVector";

    const Falcor::ChannelList kInputChannels{
        {kInputVBuffer, "gVBuffer", "Visibility buffer in packed format"},
        {kInputView, "gView", "View Vector"},
        {kInputMVec, "gMotionVectors", "Motion Vector"},
    };

    //Output textures
    const std::string kOutputColor = "ColorOut";
    const std::string kOutputDebug = "DebugOut";
    const Falcor::ChannelList kOutputChannels{
        {kOutputColor, "gOutColor", "HDR output color", false /*optional*/, ResourceFormat::RGBA32Float},
        {kOutputDebug, "gDebug", "Debug Texture", true /*optional*/, ResourceFormat::RGBA32Float}
    };

    const std::string kShaderModel = "6_6";
    }

extern "C" FALCOR_API_EXPORT void registerPlugin(Falcor::PluginRegistry& registry)
{
    registry.registerClass<RenderPass, PhotonGuiding>();
}

PhotonGuiding::PhotonGuiding(ref<Device> pDevice, const Properties& props)
    : RenderPass(pDevice)
{
    // Create sample generator.
    mpSampleGenerator = SampleGenerator::create(mpDevice, SAMPLE_GENERATOR_UNIFORM);
    FALCOR_ASSERT(mpSampleGenerator);

    //Create Sampler
    Sampler::Desc samplerDesc = {};
    samplerDesc.setFilterMode(Sampler::Filter::Linear, Sampler::Filter::Linear, Sampler::Filter::Linear);
    samplerDesc.setAddressingMode(Sampler::AddressMode::Clamp, Sampler::AddressMode::Clamp, Sampler::AddressMode::Clamp);
    mpLinearSampler = Sampler::create(mpDevice, samplerDesc);
    samplerDesc.setFilterMode(Sampler::Filter::Point, Sampler::Filter::Point, Sampler::Filter::Point);
    mpPointSampler = Sampler::create(mpDevice, samplerDesc);

    mLightBVHOptions = {};

}

Properties PhotonGuiding::getProperties() const
{
    return {};
}

RenderPassReflection PhotonGuiding::reflect(const CompileData& compileData)
{
    //Render Pass In and Output textures
    RenderPassReflection reflector;
    addRenderPassInputs(reflector, kInputChannels);
    addRenderPassOutputs(reflector, kOutputChannels);
    return reflector;
}

void PhotonGuiding::setScene(RenderContext* pRenderContext, const ref<Scene>& pScene) {
    //Reset scene 
    mpScene.reset();
    resetRenderPasses();
    mpEmissiveLightSampler.reset();

    if (pScene)
    {
        mpScene = pScene;
        mNormalizedPixelArea = getNormalizedPixelArea();
    }
}

void PhotonGuiding::execute(RenderContext* pRenderContext, const RenderData& renderData)
{
    if (!mpScene)
        return;

    //Check for changes that need to reset some settings
    // Add refresh flag if options changed
    auto& dict = renderData.getDictionary();
    auto flags = dict.getValue(kRenderPassRefreshFlags, RenderPassRefreshFlags::None);
    if (mOptionsChanged)
        dict[Falcor::kRenderPassRefreshFlags] = flags | Falcor::RenderPassRefreshFlags::RenderOptionsChanged;
    //Check if camera moved to reset guiding count
    auto excluded = Camera::Changes::Jitter | Camera::Changes::History;
    auto cameraChanges = mpScene->getCamera()->getChanges();
    bool cameraMoved = (cameraChanges & ~excluded) != Camera::Changes::None;
    if ((cameraMoved && !mGuidingRealTimeMode) || mOptionsChanged || mGuidingResetAccumulateCount)
    {
        mGuidingAccumulateCount = 0;
        mGuidingResetAccumulateCount = false;
    }

    mOptionsChanged = false;

    // Prepare needed Falcor helpers and Buffers/Textures
    prepareLightingStructure(pRenderContext);

    //Return if there is no emissive light
    if (mTotalLightCount == 0)
        return;

    //Prepare Textures and Buffers
    prepareResources(pRenderContext, renderData);

    updateGuidingTextures(pRenderContext, renderData);

    tracePhotonPass(pRenderContext, renderData);

    switch (mPhotonRenderMode)
    {
    case Falcor::PhotonGuidingSharedEnums::PhotonRenderMode::PhotonMapping:
    case Falcor::PhotonGuidingSharedEnums::PhotonRenderMode::FinalGathering:
    {
        traceCameraPass(pRenderContext, renderData);
        break;
    }
    case Falcor::PhotonGuidingSharedEnums::PhotonRenderMode::ReSTIR_FG:
    {
        if (!mpRTXDI)
            mpRTXDI = std::make_unique<RTXDI>(mpScene, mRTXDIOptions);
        mpRTXDI->beginFrame(pRenderContext, mScreenRes);

        // Initial Samples for ReSTIR FG (1SPP Photon Final Gathering) and inti RTXDI structs
        reSTIRGenerateInitialSamplesPass(pRenderContext, renderData);

        if (mEnableLightTraceSplatting)
        {
            //Reproject reservoirs from last frame to current camera
            reSTIRSplatTemporalReservoirsPass(pRenderContext, renderData);

            //Sort Splatted reservoirs, so they can be properly used for resampling
            reSTIRSortSplattedReservoirsPass(pRenderContext, renderData);
        }

        // ReSTIR DI pass
        const auto& pMotionVectors = renderData[kInputMVec]->asTexture();
        mpRTXDI->update(pRenderContext, pMotionVectors);

        // Spatiotemporal resampling for final gather samples and caustics
        reSTIRResampleFGPass(pRenderContext, renderData);

        reSTIRResampleCausticPass(pRenderContext, renderData);

        // Finalize Reservoirs
        reSTIREvaluateReservoirsPass(pRenderContext, renderData);

        // End ReSTIR DI frame
        mpRTXDI->endFrame(pRenderContext);
        mCanResample = true;
        break;
    }
    }
    

    if (mDebugShowGuidingTexture)
        debugPass(pRenderContext, renderData);

    mFrameCount++;
    mGuidingAccumulateCount++;

    // Copy Camera data for splatting
    const CameraData& camData = mpScene->getCamera()->getData();
    mTemporalCameraViewProjection = camData.viewProjMat;
    mTemporalCameraPosition = camData.posW;
    mTemporalCameraForward = math::normalize(camData.cameraW);
}

void PhotonGuiding::renderUI(Gui::Widgets& widget)
{
    bool changed = false;

    if(widget.dropdown("Render Technique", mPhotonRenderMode))
    {
        changed = true;
        mCanResample = false;
        resetRenderPasses();
    }
    if (widget.dropdown("Guiding Mode", mGuidingMode))
    {
        changed = true;
        resetRenderPasses();
    }

    if (widget.dropdown("Guiding Light Index Mode", mGuidingLightIndexMode))
    {
        changed = true;
        resetRenderPasses();
    }

    if (auto group = widget.group("Photon Options"))
    {
        if (mUseDynamicPhotonDispatchCount)
        {
            group.text("Dispatched Photons: " + std::to_string(mNumDispatchedPhotons));
        }
        else
        {
            group.var("Dispatched Photons", mNumDispatchedPhotons, 1024u, 67108864u, 1u); // Max is 8192^2
        }

        group.text("Global Photons: " + std::to_string(mCurrentPhotonCount[0]) + " / " + std::to_string(mNumMaxPhotons[0]));
        group.text("Caustic Photons: " + std::to_string(mCurrentPhotonCount[1]) + " / " + std::to_string(mNumMaxPhotons[1]));

        group.text("Photon Buffer Size:");
        group.indent(10.f);
        group.var(" ##MaxPhotonUI", mNumMaxPhotonsUI, 100u, 100000000u, 100);
        group.tooltip("First -> Global, Second -> Caustic");
        mChangePhotonLightBufferSize = group.button("Apply", true);
        group.indent(-10.f);

        changed |= group.checkbox("Enable dynamic photon dispatch", mUseDynamicPhotonDispatchCount);
        group.tooltip("Changed the number of dispatched photons dynamically. Tries to fill the photon buffer");
        if (mUseDynamicPhotonDispatchCount)
        {
            if (auto groupDynChange = group.group("DynamicDispatchOptions"))
            {
                changed |= groupDynChange.var("Max dispatched", mPhotonDynamicDispatchMax, 1024u, 67108864u);
                changed |= groupDynChange.var("Guard Percentage", mPhotonDynamicGuardPercentage, 0.0f, 1.f, 0.001f);
                groupDynChange.tooltip(
                    "If current fill rate is under PhotonBufferSize * (1-pGuard), the values are accepted. Reduces the changes "
                    "every frame"
                );
                changed |= groupDynChange.var("Percentage Change", mPhotonDynamicChangePercentage, 0.01f, 10.f, 0.01f);
                groupDynChange.tooltip(
                    "Increase/Decrease percentage from the Buffer Size. With current value a increase/decrease of :" +
                    std::to_string(mPhotonDynamicChangePercentage * mNumMaxPhotons.x) + "is expected"
                );
            }
        }

        changed |= group.var("Global photon store probability", mGlobalPhotonRejection, 0.f, 1.f, 0.0001f);
        group.tooltip("Probability a photon light is stored on diffuse hit. Flux is scaled up appropriately");
        changed |= group.var("Max Bounces", mPhotonMaxBounces, 0u, 256u);

        group.checkbox("Use per pixel adaptive photon radius", mUseAdaptivePhotonRadius);
        if (mUseAdaptivePhotonRadius)
        {
            group.text("Radius adaptive pixel scale (Global / Caustic):");
            group.indent(10.f);
            changed |= group.var(" ##AdaptiveRadiusScale", mAdaptivePhotonRadius, 0, FLT_MAX, 0.001f);
            group.indent(-10.f);
        }
        else
        {
            group.text("Photon Radius(Global / Caustic):");
            group.indent(10.f);
            changed |= group.var(" ##PhotonRadius", mPhotonRadius, 0, FLT_MAX, 0.0001f, false, "%.6f");
            group.indent(-10.f);
        }
      

        group.checkbox("Enable Russian Roulette", mPhotonRussianRoulette);
    }

    if (auto group = widget.group("Guiding Options"))
    {
        group.checkbox("Use Blur", mUseGaussianBlur);
        if (auto group2 = group.group("Blur Options"))
        {
            group2.text("To update Kernel, please press the button below.");
            group2.var("Blur Kernel Width", mGuidingBlurWidth, 3u, 15u, 2u);
            group2.slider("Sigma", mGuidingBlurSigma, 0.001f, mGuidingBlurWidth / 2.f);
            mGuidingBlurUpdateWeights = group2.button("Update Kernel");
        }
        
        group.var("Guiding Discretized Factor", mGuidingDiscretizedEmissionFactor, 1u, UINT_MAX, 1u);
        group.tooltip("The emission is multiplied with this factor before beeing added to the texture");
        group.checkbox("Use Real Time mode", mGuidingRealTimeMode);
        group.tooltip("In real-time mode, the guiding count is not reset on camera movement. Instead, a history limit is applied");
        if (mGuidingRealTimeMode)
            group.var("History Limit", mGuidingHistoryLimit, 0u, UINT_MAX, 1u);

        if (mGuidingMode == GuidingMode::Emission || mGuidingMode == GuidingMode::ReSTIR)
            changed |= group.var("Uniform weight (clear value)", mGuidingClearValueEmission, 0.f, FLT_MAX, 0.001f);

        if (mPhotonRenderMode == PhotonRenderMode::ReSTIR_FG)
        {
            group.checkbox("ReSTIR Enable Guiding Jacobian", mReSTIREnableGuidingJacobian);
        }

        changed |= group.checkbox("Map Guiding to Photon dispatch size", mUseFixedGuidingDispatch);

        changed |= group.var(
            "Map Guiding: Min Photons Per Light", mFixedGuidingDispatchReservedPhotons, 32u, mGuidingTextureResolution * mGuidingTextureResolution, 1u
        );


        mGuidingResetAccumulateCount = group.button("Reset Guiding Textures");
    }

    if (mPhotonRenderMode == PhotonRenderMode::ReSTIR_FG)
    {
        if (auto group = widget.group("RTXDI"))
        {
            if (mpRTXDI)
            {
                mpRTXDI->renderUI(group);
            }
            else
            {
                group.text("Load a scene for RTXDI options");
            }
        }
        if (auto group = widget.group("ReSTIR FG"))
        {
            group.var("Final Gather Path Length", mPTMaxBounces, 1u, 64u, 1u);
            group.tooltip(
                "Path length for a final gather sample. A final gather sample stops when it encounters a rough enough surface (see "
                "Material Options)"
            );

            auto resampleUI = [](ResamplingSettings& settings, Gui::Widgets& widget, bool isCausticResampling = false)
            {
                widget.checkbox("Enable Resampling", settings.enable);
                widget.var("Confidence Cap", settings.confidenceCap, 1u, UINT_MAX, 1u);
                widget.tooltip("Maximum confidence a reservoir can have");
                widget.var("Spatial Samples", settings.spatialSamples, 0u, 64u, 1u);
                widget.var("Disocclusion additional spatial samples", settings.disocclusionBoostExtraSamples, 0u, 16u, 1u);
                widget.tooltip("Extra spatial samples if temporal resampling fails");
                widget.var("Spatial Sample Radius", settings.samplingRadius, 0.f, FLT_MAX, 1.f);
                widget.var("Normal Rejection Threshold", settings.normalThreshold, 0.f, 1.0f, 0.001f);
                widget.tooltip("Threshold of dot product between both reservoir face normals");
                widget.var("Sample Distance Threshold", settings.jacobianDistanceThreshold, 0.f, FLT_MAX, 0.001f);
                if (!isCausticResampling)
                {
                    widget.checkbox("Use Path Threshold", settings.usePathThreshold);
                    widget.tooltip("Only resamples if the surfaces used for generating the Final Gather samples have the same path length.");
                }
            };

            if (auto group2 = group.group("Resampling FG options"))
            {
                resampleUI(mResampleSettingsFG, group2);
            }
            if (auto group2 = group.group("Resampling Caustic options"))
            {
                resampleUI(mResampleSettingsCaustic, group2, true);
                if (group2.checkbox("Use Light Trace Splatting for direct", mEnableLightTraceSplatting))
                    mCanResample = false;
                group2.tooltip("Enables Light Trace with ReSTIR Splatting for the directly visible caustics");
            }
        }
    }
    else
    {
        if (auto group = widget.group("Path Tracer Options"))
        {
            changed |= group.var("Bounces", mPTMaxBounces, 0u, 256u, 1u);
            if (mPhotonRenderMode != PhotonRenderMode::PhotonMapping)
            {
                mRebuildLightSampler |= group.dropdown("NEE Sampler", mEmissiveLightSamplerType);
                if (mEmissiveLightSamplerType == EmissiveLightSamplerType::LightBVH)
                {
                    if (auto group2 = group.group("NEE Sampler Options"))
                    {
                        mpEmissiveLightSampler->renderUI(group2);
                    }
                }
            }
        }
    }
   

    if (auto group = widget.group("Material Options"))
    {
        changed |= group.var("Roughness Threshold", mSpecularRoughnessThreshold, 0.f, 1.f);
        group.tooltip("Threshold when a surface is handled as delta");
        changed |= group.checkbox("Use Diffuse Lambert BRDF", mUseLambertianDiffuse);
        group.tooltip("Enables Lambertian Diffuse BRDS. If disabled the Frostbyte diffuse BRDF (Falcor default) is used");
    }

    if (auto group = widget.group("Debug"))
    {
        group.checkbox("Freeze Guiding Texture", mDebugFreezeGuidingTextures);
        group.checkbox("Show Guiding Texture", mDebugShowGuidingTexture);
        if (mDebugShowGuidingTexture)
        {
            group.checkbox("Show Light Index Select Guiding Tex", mDebugShowLightIndexGuidingTex);
            group.slider("Selected Tri light", mDebugSelectedTriLight, -1, int(mTotalLightCount) - 1);
            group.var("Color Scale", mDebugColorScaleFactor, 0.f, FLT_MAX, 0.01f, false, "%.6f");
            group.checkbox("Scale to DebugTex", mDebugScaleToDstDim);
            if (!mDebugScaleToDstDim)
                group.var("Size Scale", mDebugSizeScaleFactor, 0.f, FLT_MAX, 0.001f);     
        }
        changed |= group.checkbox("Disable Direct Light", mDebugDisableDirectLight);
        changed |= group.checkbox("Disable Indirect Light", mDebugDisableIndirectLight);
    }
    mOptionsChanged = changed;
}

void PhotonGuiding::prepareLightingStructure(RenderContext* pRenderContext)
{
    // Make sure that the emissive light is up to date
    auto& pLights = mpScene->getLightCollection(pRenderContext);

    bool emissiveUsed = mpScene->useEmissiveLights();
    bool analyticUsed = mpScene->useAnalyticLights();

    //mHasLights = analyticUsed || emissiveUsed;
    //mHasAnalyticLights = analyticUsed;
    //mMixedLights = emissiveUsed && analyticUsed;

    if (pLights->getTotalLightCount() != mEmissiveLightCount || mpScene->getLightCount() != mAnalyticLightCount)
    {
        mEmissiveLightCount = pLights->getTotalLightCount();
        mAnalyticLightCount = mpScene->getLightCount();
        mTotalLightCount = mEmissiveLightCount + mAnalyticLightCount;
        mpGuidingAtlas[0].reset();
        mpGuidingAtlas[1].reset();
        mpGuidingAtlasPrevUnblurred.reset();
        mpRecordGuidingAtlas.reset();
        mpLightIndexGuidingTexture[0].reset();
        mpLightIndexGuidingTexture[1].reset();
        mpRecordLightIndexGuidingTexture.reset();
        resetRenderPasses();
    }
    if (emissiveUsed)
    {
        if (!mpEmissiveLightSampler || mRebuildLightSampler)
        {
            resetRenderPasses();
            FALCOR_ASSERT(pLights && pLights->getActiveLightCount(pRenderContext) > 0);
            switch (mEmissiveLightSamplerType)
            {
            case Falcor::EmissiveLightSamplerType::Uniform:
                mpEmissiveLightSampler = std::make_unique<EmissiveUniformSampler>(pRenderContext, mpScene);
                break;
            case Falcor::EmissiveLightSamplerType::LightBVH:
                mpEmissiveLightSampler = std::make_unique<LightBVHSampler>(pRenderContext, mpScene, mLightBVHOptions);
                break;
            case Falcor::EmissiveLightSamplerType::Power:
                mpEmissiveLightSampler = std::make_unique<EmissivePowerSampler>(pRenderContext, mpScene);
                break;
            case Falcor::EmissiveLightSamplerType::Null:
            default:
                FALCOR_UNREACHABLE();
                break;
            }

            mRebuildLightSampler = false;
        }
    }
    else
    {
        if (mpEmissiveLightSampler)
        {
            if (auto lightBVHSampler = dynamic_cast<LightBVHSampler*>(mpEmissiveLightSampler.get()))
            {
                mLightBVHOptions = lightBVHSampler->getOptions();
            }
            mpEmissiveLightSampler = nullptr;
            resetRenderPasses();
        }
    }

    if (mpEmissiveLightSampler)
        mpEmissiveLightSampler->update(pRenderContext);
}

void PhotonGuiding::prepareResources(RenderContext* pRenderContext, const RenderData& renderData) {
    if (any(mScreenRes != renderData.getDefaultTextureDims()))
    {
        mScreenRes = renderData.getDefaultTextureDims();
        mNormalizedPixelArea = getNormalizedPixelArea();
        mResetScreenTex = true;
        mResetClearResources = true;
    }

    if (mChangePhotonLightBufferSize)
    {
        mNumMaxPhotons = mNumMaxPhotonsUI;
        mpPhotonAABB[0].reset();
        mpPhotonAABB[1].reset();
        mpPhotonData[0].reset();
        mpPhotonData[1].reset();
        mpPhotonAS.reset();
        mpLightTraceLinkedList.reset();
        mpCausticPhotonHitInfo.reset();
        mChangePhotonLightBufferSize = false;
        mResetClearResources = true;
    }

    //Photon Buffers
    for (uint i = 0; i < 2; i++)
    {
        if (!mpPhotonAABB[i])
        {
            mpPhotonAABB[i] = Buffer::createStructured(
                mpDevice, sizeof(AABB), mNumMaxPhotons[i], ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess,
                Buffer::CpuAccess::None, nullptr, false
            );
            mpPhotonAABB[i]->setName("PhotonAABB" + std::to_string(i));
        }

        if (!mpPhotonData[i])
        {
            mpPhotonData[i] = Buffer::createStructured(
                mpDevice, sizeof(float) * 16, mNumMaxPhotons[i], ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess,
                Buffer::CpuAccess::None, nullptr, false
            );
            mpPhotonData[i]->setName("PhotonData" + std::to_string(i));
        }
    }
    

    if (!mpPhotonCounter)
    {
        mpPhotonCounter = Buffer::createStructured(
            mpDevice, sizeof(uint), 2, ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess, Buffer::CpuAccess::None, nullptr, false
        );
        mpPhotonCounter->setName("PhotonCounter");

        mpPhotonCounterCPU = Buffer::createStructured(mpDevice, sizeof(uint), 2, ResourceBindFlags::None, Buffer::CpuAccess::Read, nullptr, false);
        mpPhotonCounterCPU->setName("PhotonCounterCPU");
    }

    //Acceleration Structure for Photon Collection
    if (!mpPhotonAS)
    {
        std::vector<uint64_t> aabbCount = {mNumMaxPhotons[0], mNumMaxPhotons[1]};
        std::vector<uint64_t> aabbGPUAddress = {mpPhotonAABB[0]->getGpuAddress(), mpPhotonAABB[1]->getGpuAddress()};
        mpPhotonAS = std::make_unique<CustomAccelerationStructure>(
            mpDevice, aabbCount, aabbGPUAddress, CustomAccelerationStructure::BuildMode::FastBuild,
            CustomAccelerationStructure::UpdateMode::TLASOnly
        );
    }

    //Guiding Textures
    if (!mpGuidingAtlas[0] || !mpGuidingAtlas[1])
    {
        //Update atlas size
        float minSideLength =
            math::ceil(math::sqrt(float(mTotalLightCount * mGuidingTextureResolution * mGuidingTextureResolution))); // ceiled pixel
                                                                                                                        // width/length
        mGuidingAtlasResolution = uint(pow(2.f, math::ceil(math::log2(minSideLength)))); // Gets next nearest power 2 number
        mGuidingAtlasMipLevels = uint(round(math::log2(float(mGuidingTextureResolution)))) + 1;

        for (uint i = 0; i < 2; i++)
        {
            mpGuidingAtlas[i] = Texture::create2D(
                mpDevice, mGuidingAtlasResolution, mGuidingAtlasResolution, ResourceFormat::R32Float, 1u, Texture::kMaxPossible, nullptr,
                ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess | ResourceBindFlags::RenderTarget
            );
            mpGuidingAtlas[i]->setName("GuidingTextureAtlas" + std::to_string(i));        
        }
    }

    if (!mpGuidingAtlasPrevUnblurred)
{
        mpGuidingAtlasPrevUnblurred = Texture::create2D(
        mpDevice, mGuidingAtlasResolution, mGuidingAtlasResolution, ResourceFormat::R32Float, 1u, 1u,
            nullptr, ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess
        );
        mpGuidingAtlasPrevUnblurred->setName("GuidingTextureAtlasNoBlur");
    }

    //Used in blur
    if (!mpGuidingAtlasBlurHelper)
    {
        mpGuidingAtlasBlurHelper = Texture::create2D(
            mpDevice, mGuidingAtlasResolution, mGuidingAtlasResolution, ResourceFormat::R32Float, 1u, 1u, nullptr,
            ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess
        );
        mpGuidingAtlasBlurHelper->setName("GuidingAtlasBlurHelper");
    }

    if (!mpRecordGuidingAtlas)
    {
        mpRecordGuidingAtlas = Texture::create2D(
            mpDevice, mGuidingAtlasResolution, mGuidingAtlasResolution, ResourceFormat::R32Uint, 1u, mGuidingAtlasMipLevels,
            nullptr, ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess | ResourceBindFlags::RenderTarget
        );
        mpRecordGuidingAtlas->setName("RecordGuidingTextureAtlas");

        pRenderContext->clearUAV(mpRecordGuidingAtlas->getUAV(0).get(), uint4(0));
    }
        
    if (!mpLightIndexGuidingTexture[0] || !mpLightIndexGuidingTexture[1])
    {
        float minSideLength = math::ceil(math::sqrt(float(mTotalLightCount)));                          // ceiled pixel width/length
        mGuidingLightIndexSize = uint(pow(2.f, math::ceil(math::log(minSideLength) / math::log(2.f)))); //Gets next nearest power 2 number
        for (uint i = 0; i < 2; i++)
        {
            mpLightIndexGuidingTexture[i] = Texture::create2D(
                mpDevice, mGuidingLightIndexSize, mGuidingLightIndexSize, ResourceFormat::R32Float, 1u, Texture::kMaxPossible, nullptr,
                ResourceBindFlags::UnorderedAccess | ResourceBindFlags::ShaderResource
            );
            mpLightIndexGuidingTexture[i]->setName("LightIndexGuidingTexture" + std::to_string(i));
        }
    }

    if (!mpLightIndexGuidingPrevTex)
    {
        mpLightIndexGuidingPrevTex = Texture::create2D(
            mpDevice, mGuidingLightIndexSize, mGuidingLightIndexSize, ResourceFormat::R32Float, 1u, 1u, nullptr,
            ResourceBindFlags::UnorderedAccess | ResourceBindFlags::ShaderResource
        );
        mpLightIndexGuidingPrevTex->setName("LightIndexGuidingPrev");
    }

    if (!mpRecordLightIndexGuidingTexture)
    {
        mpRecordLightIndexGuidingTexture = Texture::create2D(
            mpDevice, mGuidingLightIndexSize, mGuidingLightIndexSize, ResourceFormat::R32Uint, 1u, Texture::kMaxPossible, nullptr,
            ResourceBindFlags::UnorderedAccess | ResourceBindFlags::ShaderResource
        );
        mpRecordLightIndexGuidingTexture->setName("LightIndexGuidingRecordTexture");
    }

    //ReSTIR Resources
    for (uint i = 0; i < 2; i++)
    {
        if (!mpFinalGatherReservoir[i] || mResetScreenTex)
        {
            mCanResample = false;
            mpFinalGatherReservoir[i] = Buffer::createStructured(
                mpDevice, 128u, mScreenRes.x * mScreenRes.y, ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess,
                Buffer::CpuAccess::None, nullptr, false
            );
            mpFinalGatherReservoir[i]->setName("FinalGatherReservoir" + std::to_string(i));
        }
        if (!mpCausticReservoir[i] || mResetScreenTex)
        {
            mCanResample = false;
            mpCausticReservoir[i] = Buffer::createStructured(
                mpDevice, 128u, mScreenRes.x * mScreenRes.y, ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess,
                Buffer::CpuAccess::None, nullptr, false
            );
            mpCausticReservoir[i]->setName("CausticReservoir" + std::to_string(i));
        }
    }

    // Emission Texture
    if (!mpEmission || mResetScreenTex)
    {
        mpEmission = Texture::create2D(
            mpDevice, mScreenRes.x, mScreenRes.y, ResourceFormat::RGBA32Float, 1u, 1u, nullptr,
            ResourceBindFlags::UnorderedAccess | ResourceBindFlags::ShaderResource
        );
        mpEmission->setName("EmissionTexture");
    }

    if (!mpResampleMVec || mResetScreenTex)
    {
        mpResampleMVec = Texture::create2D(
            mpDevice, mScreenRes.x, mScreenRes.y, ResourceFormat::RG32Float, 1u, 1u, nullptr,
            ResourceBindFlags::UnorderedAccess | ResourceBindFlags::ShaderResource
        );
        mpResampleMVec->setName("MVecResampling");
    }

    // Light Trace resources
    if (!mpLightTraceHeadCounter || mResetScreenTex)
    {
        mpLightTraceHeadCounter = Texture::create2D(
            mpDevice, mScreenRes.x, mScreenRes.y, ResourceFormat::R32Int, 1u, 1u, nullptr,
            ResourceBindFlags::UnorderedAccess | ResourceBindFlags::ShaderResource
        );
        mpLightTraceHeadCounter->setName("LightTraceHeadCounter");
        mResetClearResources = true; //Just to be sure this is triggered
    }

    if (!mpLightTraceLinkedList)
    {
        mpLightTraceLinkedList = Buffer::createStructured(
            mpDevice, sizeof(uint), mNumMaxPhotons[1], ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess,
            Buffer::CpuAccess::None, nullptr, false
        );
        mpLightTraceLinkedList->setName("LightTraceLinkedList");
    }

    if (!mpCausticPhotonHitInfo)
    {
        mpCausticPhotonHitInfo = Buffer::createStructured(
            mpDevice, sizeof(uint4), mNumMaxPhotons[1], ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess,
            Buffer::CpuAccess::None, nullptr, false
        );
        mpCausticPhotonHitInfo->setName("CausticPhotonHitInfo");
    }

    // Set Splatting Resources
    if (!mpSplattingGlobalCounter)
    {
        mpSplattingGlobalCounter = Buffer::createStructured(
            mpDevice, sizeof(uint), 2, ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess, Buffer::CpuAccess::None,
            nullptr, false
        );
        mpSplattingGlobalCounter->setName("SplattingGlobalCounter");
    }

    if (!mpSplattingCellCounter || mResetScreenTex)
    {
        mpSplattingCellCounter = Buffer::createStructured(
            mpDevice, sizeof(uint), mScreenRes.x * mScreenRes.y, ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess,
            Buffer::CpuAccess::None, nullptr, false
        );
        mpSplattingCellCounter->setName("SplattingCellCounter");
    }

    if (!mpSplattingCellOffsets || mResetScreenTex)
    {
        mpSplattingCellOffsets = Buffer::createStructured(
            mpDevice, sizeof(uint), mScreenRes.x * mScreenRes.y, ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess,
            Buffer::CpuAccess::None, nullptr, false
        );
        mpSplattingCellOffsets->setName("SplattingCellOffsets");
    }

    if (!mpSplattingSortingData || mResetScreenTex)
    {
        mpSplattingSortingData = Buffer::createStructured(
            mpDevice, sizeof(uint4), mScreenRes.x * mScreenRes.y, ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess,
            Buffer::CpuAccess::None, nullptr, false
        );
        mpSplattingSortingData->setName("SplattingSortingData");
    }

    if (!mpSplattingSortedReservoirs || mResetScreenTex)
    {
        mpSplattingSortedReservoirs = Buffer::createStructured(
            mpDevice, sizeof(uint2), mScreenRes.x * mScreenRes.y, ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess,
            Buffer::CpuAccess::None, nullptr, false
        );
        mpSplattingSortedReservoirs->setName("SplattingSortedReservoirs");
    }

    if (mResetClearResources)
    {
        pRenderContext->clearUAV(mpLightTraceHeadCounter->getUAV(0).get(), uint4(uint(-1)));
        pRenderContext->clearUAV(mpLightTraceLinkedList->getUAV(0).get(), uint4(-1));
        pRenderContext->clearUAV(mpCausticPhotonHitInfo->getUAV(0).get(), uint4(0));
        for (uint i = 0; i < 2; i++)
        {
            pRenderContext->clearUAV(mpCausticReservoir[i]->getUAV(0).get(), uint4(0));
            pRenderContext->clearUAV(mpFinalGatherReservoir[i]->getUAV(0).get(), uint4(0));
        }
       
    }

    mResetClearResources = false;
    mResetScreenTex = false;
}

void PhotonGuiding::updateGuidingTextures(RenderContext* pRenderContext, const RenderData& renderData)
{
    FALCOR_PROFILE(pRenderContext, "Update Guiding Textures");

    if (mDebugFreezeGuidingTextures)
    {
        pRenderContext->clearUAV(mpRecordGuidingAtlas->getUAV(0).get(), uint4(1));
        return;
    }

    guidingCounterReducePass(pRenderContext, renderData);
    generateLightIndexGuidingMipTraverseChainPass(pRenderContext, renderData);
    generateGuidingMipTraverseChainPass(pRenderContext, renderData);
}

bool guidingIsUintFormat(PhotonGuidingSharedEnums::GuidingMode guidingMode) {
    switch (guidingMode)
    {
    case Falcor::PhotonGuidingSharedEnums::GuidingMode::Disabled:
    case Falcor::PhotonGuidingSharedEnums::GuidingMode::Uniform:
    case Falcor::PhotonGuidingSharedEnums::GuidingMode::EmissionDiscretized:
    case Falcor::PhotonGuidingSharedEnums::GuidingMode::ReSTIRDiscretized:
        return true;
    case Falcor::PhotonGuidingSharedEnums::GuidingMode::Emission:
    case Falcor::PhotonGuidingSharedEnums::GuidingMode::ReSTIR:
        return false;
    default:
        FALCOR_UNREACHABLE();
        break;
    }
    return true;
}

void PhotonGuiding::guidingCounterReducePass(RenderContext* pRenderContext, const RenderData& renderData)
{
    FALCOR_PROFILE(pRenderContext, "ReduceGuidingCounters");
    
    if (!mpGuidingCounterReducePass)
    {
        Program::Desc desc;
        desc.addShaderLibrary(kShaderGuidingReduce).csEntry("main").setShaderModel(kShaderModel);

        DefineList defines;
        defines.add("TEX_FORMAT", guidingIsUintFormat(mGuidingMode) ? "uint" : "float");

        mpGuidingCounterReducePass = ComputePass::create(mpDevice, desc, defines, true);
    }
  
    //Per triangle light guiding texture
    {
        auto var = mpGuidingCounterReducePass->getRootVar();
        const uint maxMipCount = mGuidingAtlasMipLevels - 1u;
        
        bool useMipMapReduce = maxMipCount < 5;
        uint increments = useMipMapReduce ? 1 : 5;

        for (uint mip = 0; mip < maxMipCount; mip += increments)
        {
            if (!useMipMapReduce && (mip + increments) >= maxMipCount)
            {
                increments = 1;
                useMipMapReduce = true;
            }
            uint dstMip = mip + increments;

            uint3 dispatchDim =
                uint3(mpRecordGuidingAtlas->getWidth(mip), mpRecordGuidingAtlas->getHeight(mip), 1);

            dispatchDim.x = dispatchDim.x / 2u;
            dispatchDim.y = dispatchDim.y / 2u;

            var["CB"]["gDstSize"] = dispatchDim.xy();
            var["CB"]["gUseMip"] = useMipMapReduce;

            var["gSrc"].setSrv(mpRecordGuidingAtlas->getSRV(mip, 1u));
            var["gDst"].setUav(mpRecordGuidingAtlas->getUAV(dstMip, 0u, 1u));

            mpGuidingCounterReducePass->execute(pRenderContext, dispatchDim);
        }
    }

    if (!mpGuidingLightIndexCounterReducePass)
    {
        Program::Desc desc;
        desc.addShaderLibrary(kShaderGuidingReduce).csEntry("main").setShaderModel(kShaderModel);

        DefineList defines;
        defines.add("TEX_FORMAT", "uint");

        mpGuidingLightIndexCounterReducePass = ComputePass::create(mpDevice, desc, defines, true);
    }

    //For the per light guiding texture
    {
        auto var = mpGuidingLightIndexCounterReducePass->getRootVar();
        const uint maxMipCount = mpRecordLightIndexGuidingTexture->getMipCount() - 1u;

        bool useMipMapReduce = maxMipCount < 5;
        uint increments = useMipMapReduce ? 1 : 5;
        for (uint mip = 0; mip < maxMipCount; mip += increments)
        {
            if (!useMipMapReduce && (mip + increments) >= maxMipCount)
            {
                increments = 1;
                useMipMapReduce = true;
            }
            uint dstMip = mip + increments;

            uint3 dispatchDim = uint3(
                mpRecordLightIndexGuidingTexture->getWidth(mip), mpRecordLightIndexGuidingTexture->getHeight(mip), 1
            );

            dispatchDim.x = dispatchDim.x / 2u;
            dispatchDim.y = dispatchDim.y / 2u;

            var["CB"]["gDstSize"] = dispatchDim.xy();
            var["CB"]["gUseMip"] = useMipMapReduce;
            var["gSrc"].setSrv(mpRecordLightIndexGuidingTexture->getSRV(mip, 1u));
            var["gDst"].setUav(mpRecordLightIndexGuidingTexture->getUAV(dstMip, 0u, 1u));
          
            mpGuidingLightIndexCounterReducePass->execute(pRenderContext, dispatchDim);
        }
    }
    
}

//Returns optimized y dispatch size, as the atlas is not always full
uint getOptimizedAtlasYDispatch(uint atlasResolution, uint guidingTexResolution, uint lightCount) {
   
    const uint lightsPerRow = atlasResolution / guidingTexResolution;
    return ((lightCount / lightsPerRow) + 1) * guidingTexResolution;
}

void PhotonGuiding::generateGuidingMipTraverseChainPass(RenderContext* pRenderContext, const RenderData& renderData)
{
    FALCOR_PROFILE(pRenderContext, "GuidingTraverseChain");

    if (!mpGenerateGuidingMipTraverseChainPass)
    {
        Program::Desc desc;
        desc.addShaderLibrary(kShaderGuidingGenMipTraverseChain).csEntry("main").setShaderModel(kShaderModel);

        DefineList defines;
        defines.add("COUNT_TEXTURES", std::to_string(mTotalLightCount));
        defines.add("COUNTER_FORMAT", guidingIsUintFormat(mGuidingMode) ? "uint" : "float");
        defines.add("USE_TEMPORAL_WEIGHT_TEXTURE", "1");
        defines.add("COUNT_LIGHTS", std::to_string(mTotalLightCount));
        defines.add("IS_LIGHT_INDEX_TEXTURE", "0");

        mpGenerateGuidingMipTraverseChainPass = ComputePass::create(mpDevice, desc, defines, true);
    }

    auto var = mpGenerateGuidingMipTraverseChainPass->getRootVar();
    auto pCurrentGuidingTex = mpGuidingAtlas[mFrameCount % 2];

    //First pass to get the level 0 values from the counter and clear counter to 1
    {
        uint iterationCount = mGuidingMode == GuidingMode::Disabled ? 0 : mGuidingAccumulateCount;
        if (mGuidingRealTimeMode)
            iterationCount = math::min(iterationCount, mGuidingHistoryLimit);

        //Adjust clear value
        float clearValue = guidingIsUintFormat(mGuidingMode) ? 1.f : mGuidingClearValueEmission;
        if (mUseFixedGuidingDispatch)
            clearValue = 0.f;

        const uint maxMip = mGuidingAtlasMipLevels - 1;
        var["CB"]["gRes"] = mGuidingTextureResolution;
        var["CB"]["gCopyFromCounter"] = true;
        var["CB"]["gIterationCount"] = iterationCount;
        var["CB"]["gClearValue"] = clearValue;
        var["CB"]["gDispatchSize"] = mGuidingAtlasResolution;
        var["CB"]["gFixedGuidingCheckPhotonCount"] = false;

        var["gSrcCounter"].setUav(mpRecordGuidingAtlas->getUAV(0));
        var["gSrcCounterTotal"].setSrv(mpRecordGuidingAtlas->getSRV(maxMip, 1u));
        var["gWeightLastFrame"] = mpGuidingAtlasPrevUnblurred;
        var["gSrc"].setSrv(mpGuidingAtlas[(mFrameCount + 1) % 2]->getSRV(0,1u));
        var["gDst"].setUav(pCurrentGuidingTex->getUAV(0));

        const uint maxYDispatch = getOptimizedAtlasYDispatch(mGuidingAtlasResolution, mGuidingTextureResolution, mTotalLightCount);

        mpGenerateGuidingMipTraverseChainPass->execute(pRenderContext, uint3(mGuidingAtlasResolution, maxYDispatch, 1)
        );
    }

    if (mUseGaussianBlur)
        blurGuidingAtlasPass(pRenderContext, renderData);

    if (mUseFixedGuidingDispatch)
    {
        pRenderContext->uavBarrier(pCurrentGuidingTex.get());
        mapGuidingToPhotonsPass(pRenderContext, renderData, false);
    }
                
    //Loop to generate the mip chain
    var["CB"]["gCopyFromCounter"] = false;
    var["gFixedGuidingLightIdxPhotons"] = mpLightIndexGuidingTexture[mFrameCount % 2];

    uint resolution = mGuidingAtlasResolution / 2;
    uint resPerLight = mGuidingTextureResolution / 2;
    uint mipCount = mUseFixedGuidingDispatch ? pCurrentGuidingTex->getMipCount() : mGuidingAtlasMipLevels;
    for (uint m = 1; m < mipCount; m++)
    {
        var["CB"]["gRes"] = resPerLight;
        var["CB"]["gDispatchSize"] = resolution;
        if (m == mGuidingAtlasMipLevels - 1)
            var["CB"]["gFixedGuidingCheckPhotonCount"] = true;
        else
            var["CB"]["gFixedGuidingCheckPhotonCount"] = false;

        var["gSrc"].setSrv(pCurrentGuidingTex->getSRV(m - 1, 1u));
        var["gDst"].setUav(pCurrentGuidingTex->getUAV(m));

        uint maxYDispatch = resolution;
        if (m < mGuidingAtlasMipLevels)
            maxYDispatch = getOptimizedAtlasYDispatch(resolution, resPerLight, mTotalLightCount);

        mpGenerateGuidingMipTraverseChainPass->execute(pRenderContext, uint3(resolution, maxYDispatch, 1));
        resolution /= 2;
        resPerLight /= 2;
    }
}

void PhotonGuiding::blurGuidingAtlasPass(RenderContext* pRenderContext, const RenderData& renderData)
{
    FALCOR_PROFILE(pRenderContext, "BlurGuidingAtlas");
    if (!mpGuidingBlurPass[0] || !mpGuidingBlurPass[1] || mGuidingBlurUpdateWeights)
    {
        Program::Desc desc;
        desc.addShaderLibrary(kShaderGuidingBlurAtlas).csEntry("main").setShaderModel(kShaderModel);

        DefineList defines;
        defines.add("BLUR_WIDTH", std::to_string(mGuidingBlurWidth));
        defines.add("COUNT_LIGHTS", std::to_string(mTotalLightCount));
        defines.add("IS_HORIZONTAL", "1");
        defines.add("IS_VERTICAL", "0");
        mpGuidingBlurPass[0] = ComputePass::create(mpDevice, desc, defines, true);
        defines.add("IS_HORIZONTAL", "0");
        defines.add("IS_VERTICAL", "1");
        mpGuidingBlurPass[1] = ComputePass::create(mpDevice, desc, defines, true);
    }

    //Update blur weights
    if (!mpAtlasBlurWeights || mGuidingBlurUpdateWeights)
    {
        auto getCoefficient = [&](float centerOff) {
            float sigmaSquared = mGuidingBlurSigma * mGuidingBlurSigma;
            float p = -(centerOff * centerOff) / (2 * sigmaSquared);
            float e = std::exp(p);

            float a = 2 * (float)M_PI * sigmaSquared;
            return e / a;
        };

        uint center = mGuidingBlurWidth / 2;
        float sum = 0.f;
        std::vector<float> weights(center + 1);
        for (uint i = 0; i <= center; i++)
        {
            weights[i] = getCoefficient((float)i);
            sum += (i == 0) ? weights[i] : 2.f * weights[i];
        }
        //Fill CPU vector
        std::vector<float> weightBufferData (mGuidingBlurWidth);
        for (uint i = 0; i <= center; i++)
        {
            float w = weights[i] / sum;
            weightBufferData[center + i] = w;
            weightBufferData[center - i] = w;
        }

        mpAtlasBlurWeights = Buffer::createStructured(
            mpDevice, sizeof(float), mGuidingBlurWidth, ResourceBindFlags::ShaderResource, Buffer::CpuAccess::None,
            weightBufferData.data(), false
        );
        mpAtlasBlurWeights->setName("GuidingAtlasBlurWeights");

        mGuidingBlurUpdateWeights = false;
    }

    const uint maxYDispatch = getOptimizedAtlasYDispatch(mGuidingAtlasResolution, mGuidingTextureResolution, mTotalLightCount);
    uint3 dispatchSize = uint3(mGuidingAtlasResolution, maxYDispatch, 1);
    //Horizontal Blur
    {
        auto var = mpGuidingBlurPass[0]->getRootVar();
        var["CB"]["gGuidingSize"] = mGuidingTextureResolution;
        var["CB"]["gAtlasSize"] = mGuidingAtlasResolution;
        var["gBlurWeights"] = mpAtlasBlurWeights;
        var["gSrc"].setSrv(mpGuidingAtlas[mFrameCount % 2]->getSRV(0, 1u));
        var["gDst"] = mpGuidingAtlasBlurHelper;
        mpGuidingBlurPass[0]->execute(pRenderContext, dispatchSize);
    }

    // Vertical Blur
    {
        auto var = mpGuidingBlurPass[1]->getRootVar();
        var["CB"]["gGuidingSize"] = mGuidingTextureResolution;
        var["CB"]["gAtlasSize"] = mGuidingAtlasResolution;
        var["gBlurWeights"] = mpAtlasBlurWeights;
        var["gSrc"] = mpGuidingAtlasBlurHelper;
        var["gDst"].setUav(mpGuidingAtlas[mFrameCount % 2]->getUAV(0));
        mpGuidingBlurPass[1]->execute(pRenderContext, dispatchSize);
    }
}

void PhotonGuiding::mapGuidingToPhotonsPass(RenderContext* pRenderContext, const RenderData& renderData, bool isLightIndexPass) {
    FALCOR_PROFILE(pRenderContext, "MapGuidingToDistributedPhotons");

    if (!mpMapGuidingToDistributedPhotonsPass)
    {
        Program::Desc desc;
        desc.addShaderLibrary(kShaderMapGuidingToPhotons).csEntry("main").setShaderModel(kShaderModel);

        DefineList defines;
        defines.add("COUNT_LIGHTS", std::to_string(mTotalLightCount));
        defines.add("LIGHT_GUIDING_MIN_PHOTONS", std::to_string(mGuidingTextureResolution * mGuidingTextureResolution));

        mpMapGuidingToDistributedPhotonsPass = ComputePass::create(mpDevice, desc, defines, true);
    }
    FALCOR_ASSERT(mpMapGuidingToDistributedPhotonsPass);
    mpMapGuidingToDistributedPhotonsPass->getProgram()->addDefine(
        "LIGHT_GUIDING_MIN_PHOTONS", std::to_string(mGuidingTextureResolution * mGuidingTextureResolution)
    );

    auto& pCurrentAtlas = mpGuidingAtlas[mFrameCount % 2];
    auto& pCurrentIdxGuiding = mpLightIndexGuidingTexture[mFrameCount % 2];

    auto var = mpMapGuidingToDistributedPhotonsPass->getRootVar();

    //Get photons that can be freely distributed
    //mFixedGuidingDispatchReservedPhotons = mGuidingTextureResolution * mGuidingTextureResolution; // Reserve 1 photon for every guiding pixel
    uint freePhotons = static_cast<uint>(std::floor(sqrt(mNumDispatchedPhotons)));
    freePhotons = std::max(freePhotons * freePhotons, mFixedGuidingDispatchReservedPhotons * mTotalLightCount);
    freePhotons -= mFixedGuidingDispatchReservedPhotons * mTotalLightCount;

    var["CB"]["gDistributedPhotons"] = freePhotons;
    var["CB"]["gGuidingTextureRes"] = mGuidingTextureResolution;
    var["CB"]["gLightIdxRes"] = mGuidingLightIndexSize;
    var["CB"]["gMinPhotonsPerLight"] = mFixedGuidingDispatchReservedPhotons;

    uint2 dispatchSize = uint2(0);
    if (isLightIndexPass)
    {
        dispatchSize = uint2(mGuidingLightIndexSize);
        var["CB"]["gIsLightIdxPass"] = true;

        var["gSrc"].setSrv(pCurrentAtlas->getSRV(0, 1));
        var["gDst"].setUav(pCurrentIdxGuiding->getUAV(0));
    }
    else
    {
        const uint maxYDispatch = getOptimizedAtlasYDispatch(mGuidingAtlasResolution, mGuidingTextureResolution, mTotalLightCount);
        dispatchSize = uint2(mGuidingAtlasResolution, maxYDispatch);

        var["CB"]["gIsLightIdxPass"] = false;

        var["gSrc"].setSrv(pCurrentIdxGuiding->getSRV(0,1));
        var["gDst"].setUav(pCurrentAtlas->getUAV(0));
    }
    var["CB"]["gDispatchDim"] = dispatchSize;

    mpMapGuidingToDistributedPhotonsPass->execute(pRenderContext, uint3(dispatchSize, 1));
}

void PhotonGuiding::generateLightIndexGuidingMipTraverseChainPass(RenderContext* pRenderContext, const RenderData& renderData) {
    FALCOR_PROFILE(pRenderContext, "LightIndexGuidingTraverseChain");

    if (!mpGenerateLightIndexGuidingMipTraverseChainPass)
    {
        Program::Desc desc;
        desc.addShaderLibrary(kShaderGuidingGenMipTraverseChain).csEntry("main").setShaderModel(kShaderModel);

        DefineList defines;
        defines.add("COUNT_TEXTURES", "1");
        defines.add("COUNTER_FORMAT", "uint");
        defines.add("USE_TEMPORAL_WEIGHT_TEXTURE", "1");
        defines.add("COUNT_LIGHTS", std::to_string(mTotalLightCount));
        defines.add("IS_LIGHT_INDEX_TEXTURE", "1");

        mpGenerateLightIndexGuidingMipTraverseChainPass = ComputePass::create(mpDevice, desc, defines, true);
    }

    auto var = mpGenerateLightIndexGuidingMipTraverseChainPass->getRootVar();
    auto pCurrLightGuidingTex = mpLightIndexGuidingTexture[mFrameCount % 2];

    // First pass to get the level 0 values from the counter and clear counter to 1
    {
        uint iterationCount = mGuidingLightIndexMode == GuidingLightIndexMode::Disabled ? 0 : mGuidingAccumulateCount; 
        if (mGuidingRealTimeMode)
            iterationCount = math::min(iterationCount, mGuidingHistoryLimit);

        const uint maxMip = mpRecordLightIndexGuidingTexture->getMipCount() - 1u;
        var["CB"]["gRes"] = mGuidingLightIndexSize;
        var["CB"]["gCopyFromCounter"] = true;
        var["CB"]["gIterationCount"] = iterationCount;
        var["CB"]["gClearValue"] = mUseFixedGuidingDispatch ? 0.f : 1.f;
        var["CB"]["gDispatchSize"] = mGuidingLightIndexSize;

        var["gSrcCounter"].setUav(mpRecordLightIndexGuidingTexture->getUAV(0));
        var["gSrcCounterTotal"].setSrv(mpRecordLightIndexGuidingTexture->getSRV(maxMip, 1u));
        var["gSrc"].setSrv(mpLightIndexGuidingTexture[(mFrameCount + 1) % 2]->getSRV(0, 1u));
        var["gDst"].setUav(pCurrLightGuidingTex->getUAV(0));
        var["gWeightLastFrame"] = mpLightIndexGuidingPrevTex;

        mpGenerateLightIndexGuidingMipTraverseChainPass->execute(
            pRenderContext, uint3(mGuidingLightIndexSize, mGuidingLightIndexSize, 1)
        );
    }

    if (mUseFixedGuidingDispatch)
    {
        pRenderContext->uavBarrier(pCurrLightGuidingTex.get());
        mapGuidingToPhotonsPass(pRenderContext, renderData, true);
        //return;
    }

    // Loop to generate the mip chain
    var["CB"]["gCopyFromCounter"] = false;
    uint resolution = pCurrLightGuidingTex->getHeight() / 2;
    int mipCount = int(pCurrLightGuidingTex->getMipCount());
    for (int m = 1; m < mipCount; m++)
    {
        var["CB"]["gDispatchSize"] = resolution;
        var["gSrc"].setSrv(pCurrLightGuidingTex->getSRV(m - 1, 1u));
        var["gDst"].setUav(pCurrLightGuidingTex->getUAV(m));

        mpGenerateLightIndexGuidingMipTraverseChainPass->execute(pRenderContext, uint3(resolution, resolution, 1));
        resolution /= 2;
    }
}

//Returns the diagonal of a pixel at distance 1
float getNormalizedPixelDiagonal(ref<Scene> pScene, uint2 screenRes) {
    // Update Image plane distance
    auto& cameraData = pScene->getCamera()->getData();
    float fovY = focalLengthToFovY(cameraData.focalLength, cameraData.frameHeight);

    // Get normalized pixel area
    float h = tan(fovY / 2.f) * 2.f;
    float w = h * cameraData.aspectRatio;
    float wPix = w / screenRes.x;
    float hPix = h / screenRes.y;

    float diagonal = sqrt((wPix * wPix) + (hPix * hPix));
    return diagonal;
}

void PhotonGuiding::tracePhotonPass(RenderContext* pRenderContext, const RenderData& renderData)
{
    FALCOR_PROFILE(pRenderContext, "Trace Photons");

    // Clear Photon Counter
    pRenderContext->clearUAV(mpPhotonCounter->getUAV().get(), uint4(0));

    //Update normalized diagonal
    mNormalizePixelDiagonal = mUseAdaptivePhotonRadius ? getNormalizedPixelDiagonal(mpScene, mScreenRes) : 0.f;

    // Init Shader
    if (!mTracePhotonPass.pProgram)
    {
        RtProgram::Desc desc;
        desc.addShaderModules(mpScene->getShaderModules());
        desc.addShaderLibrary(kShaderTracePhoton);
        desc.setMaxPayloadSize(sizeof(float) * 4);
        desc.setMaxAttributeSize(mpScene->getRaytracingMaxAttributeSize());
        desc.setMaxTraceRecursionDepth(1);
        if (!mpScene->hasProceduralGeometry())
            desc.setPipelineFlags(RtPipelineFlags::SkipProceduralPrimitives);

        mTracePhotonPass.pBindingTable = RtBindingTable::create(1, 1, mpScene->getGeometryCount());
        auto& sbt = mTracePhotonPass.pBindingTable;
        sbt->setRayGen(desc.addRayGen("rayGen", mpScene->getTypeConformances()));
        sbt->setMiss(0, desc.addMiss("miss"));

        if (mpScene->hasGeometryType(Scene::GeometryType::TriangleMesh))
        {
            sbt->setHitGroup(0, mpScene->getGeometryIDs(Scene::GeometryType::TriangleMesh), desc.addHitGroup("closestHit", "anyHit"));
        }
        DefineList defines;
        defines.add("USE_EMISSIVE_LIGHT", mpScene->useEmissiveLights() ? "1" : "0");
        defines.add(mpScene->getSceneDefines());
        defines.add("DiffuseBrdf", mUseLambertianDiffuse ? "DiffuseBrdfLambert" : "DiffuseBrdfFrostbite");
        defines.add("ENABLE_LIGHT_TRACE_SPATTING", mEnableLightTraceSplatting ? "1" : "0");
        defines.add("USE_FIXED_PHOTON_GUIDING", mUseFixedGuidingDispatch ? "1" : "0");
        defines.add("FIXED_GUIDING_MIN_PHOTONS", std::to_string(mGuidingTextureResolution * mGuidingTextureResolution));
        defines.add("ANALYTIC_START_INDEX", std::to_string(mEmissiveLightCount));
        defines.add("TOTAL_LIGHT_COUNT", std::to_string(mTotalLightCount));

        mTracePhotonPass.pProgram = RtProgram::create(mpDevice, desc, defines);
    }
    // Defines
    mTracePhotonPass.pProgram->addDefine("PHOTON_BUFFER_SIZE_GLOBAL", std::to_string(mNumMaxPhotons[0]));
    mTracePhotonPass.pProgram->addDefine("PHOTON_BUFFER_SIZE_CAUSTIC", std::to_string(mNumMaxPhotons[1]));
    mTracePhotonPass.pProgram->addDefine("ROUGHNESS_THRESHOLD", std::to_string(mSpecularRoughnessThreshold));
    mTracePhotonPass.pProgram->addDefine("DiffuseBrdf", mUseLambertianDiffuse ? "DiffuseBrdfLambert" : "DiffuseBrdfFrostbite");
    mTracePhotonPass.pProgram->addDefine("RUSSIAN_ROULETTE", mPhotonRussianRoulette ? "1" : "0");
    mTracePhotonPass.pProgram->addDefine("USE_ADAPTIVE_PHOTON_RADIUS", mUseAdaptivePhotonRadius ? "1" : "0");
    mTracePhotonPass.pProgram->addDefine("ENABLE_LIGHT_TRACE_SPATTING", mEnableLightTraceSplatting ? "1" : "0");
    mTracePhotonPass.pProgram->addDefine("USE_FIXED_PHOTON_GUIDING", mUseFixedGuidingDispatch ? "1" : "0");
    mTracePhotonPass.pProgram->addDefine("FIXED_GUIDING_MIN_PHOTONS", std::to_string(mGuidingTextureResolution * mGuidingTextureResolution));
    mTracePhotonPass.pProgram->addDefine("ANALYTIC_START_INDEX", std::to_string(mEmissiveLightCount));
    mTracePhotonPass.pProgram->addDefine("TOTAL_LIGHT_COUNT", std::to_string(mTotalLightCount));

    // Program Vars
    if (!mTracePhotonPass.pVars)
        mTracePhotonPass.initProgramVars(mpDevice, mpScene, mpSampleGenerator);

    FALCOR_ASSERT(mTracePhotonPass.pVars);
    auto var = mTracePhotonPass.pVars->getRootVar();
    mpScene->setRaytracingShaderData(pRenderContext, var);

    // Handle shader dimension
    uint dispatchedPhotons = mNumDispatchedPhotons;

    uint minDispatchedPhotons = 128u; //At least 128^2 photons
    if (mUseFixedGuidingDispatch)
        minDispatchedPhotons = static_cast<uint>(std::floor(sqrt(mFixedGuidingDispatchReservedPhotons * mTotalLightCount))) + 1;

    uint shaderDispatchDim = static_cast<uint>(std::floor(sqrt(dispatchedPhotons)));
    shaderDispatchDim = std::max(minDispatchedPhotons, shaderDispatchDim);

    // Constant Buffer
    var["CB"]["gFrameCount"] = mFrameCount;
    var["CB"]["gPhotonRadius"] = mPhotonRadius; 
    var["CB"]["gMaxBounces"] = mPhotonMaxBounces;
    var["CB"]["gGlobalRejectionProb"] = mGlobalPhotonRejection;
    var["CB"]["gGuidingTextureResolution"] = mGuidingTextureResolution;
    var["CB"]["gGuidingTextureMaxMip"] = mGuidingAtlasMipLevels - 1;
    var["CB"]["gGuidingAtlasResolution"] = mGuidingAtlasResolution;
    var["CB"]["gAdaptivePhotonRadius"] = mAdaptivePhotonRadius;
    var["CB"]["gNormalizedPixelDiagonal"] = mNormalizePixelDiagonal;
    var["CB"]["gScreenDimensions"] = mScreenRes;
    var["CB"]["gLightIndexGuidingResolution"] = mGuidingLightIndexSize;
    var["CB"]["gLightIndexGuidingMaxMip"] = mUseFixedGuidingDispatch ? mpGuidingAtlas[mFrameCount % 2]->getMipCount() - 1
                                                                     : mpLightIndexGuidingTexture[mFrameCount % 2]->getMipCount() - 1u;

    // Output
    for (uint i = 0; i < 2; i++)
    {
        var["gPhotonAABB"][i] = mpPhotonAABB[i];
        var["gPhotonData"][i] = mpPhotonData[i];
    }

    var["gGuidingTexture"] = mpGuidingAtlas[mFrameCount % 2];
    var["gGuidingLightIndex"] = mpLightIndexGuidingTexture[mFrameCount % 2];

    var["gLightTraceHeadCounter"] = mpLightTraceHeadCounter;
    var["gLightTraceLinkedList"] = mpLightTraceLinkedList;
    var["gCausticPhotonHitInfo"] = mpCausticPhotonHitInfo;
    var["gPhotonCounter"] = mpPhotonCounter;

    mpScene->raytrace(
        pRenderContext, mTracePhotonPass.pProgram.get(), mTracePhotonPass.pVars, uint3(shaderDispatchDim, shaderDispatchDim, 1)
    );

    mNumberLightPaths = shaderDispatchDim * shaderDispatchDim;

    // Clear values after the counter
    std::vector<ref<Buffer>> photonAABBBuffers = {mpPhotonAABB[0], mpPhotonAABB[1]};
    mpPhotonAS->clearAABBBuffers(pRenderContext, photonAABBBuffers, true, mpPhotonCounter);

    // Copy counter to CPU
    handlePhotonCounter(pRenderContext);

    // Build acceleration structure
    uint2 currentPhotons = mFrameCount > 0 ? uint2(float2(mCurrentPhotonCount) * mASBuildBufferPhotonOverestimate) : mNumMaxPhotons;
    std::vector<uint64_t> photonBuildSize = {
        std::min(mNumMaxPhotons[0], currentPhotons[0]), std::min(mNumMaxPhotons[1], currentPhotons[1])
    };

    mpPhotonAS->update(pRenderContext, photonBuildSize);

    pRenderContext->uavBarrier(mpLightTraceHeadCounter.get());
}

void PhotonGuiding::traceCameraPass(RenderContext* pRenderContext, const RenderData& renderData)
{
    FALCOR_PROFILE(pRenderContext, "TraceCamera");

    // Init Shader
    if (!mTraceCameraPass.pProgram)
    {
        RtProgram::Desc desc;
        desc.addShaderModules(mpScene->getShaderModules());
        desc.addShaderLibrary(kShaderTraceCamera);
        desc.setMaxPayloadSize(sizeof(float) * 4);
        desc.setMaxAttributeSize(mpScene->getRaytracingMaxAttributeSize());
        desc.setMaxTraceRecursionDepth(1);
        if (!mpScene->hasProceduralGeometry())
            desc.setPipelineFlags(RtPipelineFlags::SkipProceduralPrimitives);

        mTraceCameraPass.pBindingTable = RtBindingTable::create(1, 1, mpScene->getGeometryCount());
        auto& sbt = mTraceCameraPass.pBindingTable;
        sbt->setRayGen(desc.addRayGen("rayGen", mpScene->getTypeConformances()));
        sbt->setMiss(0, desc.addMiss("miss"));

        if (mpScene->hasGeometryType(Scene::GeometryType::TriangleMesh))
        {
            sbt->setHitGroup(0, mpScene->getGeometryIDs(Scene::GeometryType::TriangleMesh), desc.addHitGroup("closestHit", "anyHit"));
        }
        DefineList defines;
        defines.add(mpScene->getSceneDefines());

        mTraceCameraPass.pProgram = RtProgram::create(mpDevice, desc, defines);
    }

    // Defines
    mTraceCameraPass.pProgram->addDefine("USE_EMISSIVE_LIGHT", mpScene->useEmissiveLights() ? "1" : "0");
    mTraceCameraPass.pProgram->addDefine("USE_ENV_MAP", mpScene->useEnvBackground() ? "1" : "0");
    mTraceCameraPass.pProgram->addDefine("ROUGHNESS_THRESHOLD", std::to_string(mSpecularRoughnessThreshold));
    mTraceCameraPass.pProgram->addDefine("DiffuseBrdf", mUseLambertianDiffuse ? "DiffuseBrdfLambert" : "DiffuseBrdfFrostbite");
    mTraceCameraPass.pProgram->addDefine("RENDER_TECHNIQUE", std::to_string((uint)mPhotonRenderMode));
    mTraceCameraPass.pProgram->addDefine("GUIDING_MODE", std::to_string((uint)mGuidingMode));
    mTraceCameraPass.pProgram->addDefine("LIGHT_INDEX_GUIDING_MODE", std::to_string((uint)mGuidingLightIndexMode));
    mTraceCameraPass.pProgram->addDefine("GUIDING_DISCRETIZED_EMISSION_FACTOR", std::to_string(mGuidingDiscretizedEmissionFactor));
    if (mpEmissiveLightSampler)
        mTraceCameraPass.pProgram->addDefines(mpEmissiveLightSampler->getDefines());


    // Program Vars
    if (!mTraceCameraPass.pVars)
        mTraceCameraPass.initProgramVars(mpDevice, mpScene, mpSampleGenerator);

    FALCOR_ASSERT(mTraceCameraPass.pVars);
    auto var = mTraceCameraPass.pVars->getRootVar();

    // Structures
    if (mpEmissiveLightSampler)
        mpEmissiveLightSampler->setShaderData(var["Light"]["gEmissiveSampler"]);

    // Constant Buffer
    var["CB"]["gFrameCount"] = mFrameCount;
    var["CB"]["gMaxBounces"] = mPTMaxBounces;
    var["CB"]["gNumLightPaths"] = mNumberLightPaths;
    var["CB"]["gLightIndexGuidingResolution"] = mGuidingLightIndexSize;

    // Input
    var["gVBuffer"] = renderData[kInputVBuffer]->asTexture();
    var["gView"] = renderData[kInputView]->asTexture();

    // Photon Data
    mpPhotonAS->bindTlas(var, "gPhotonAS");

    for (uint i = 0; i < 2; i++)
    {
        var["gPhotonAABB"][i] = mpPhotonAABB[i];
        var["gPhotonData"][i] = mpPhotonData[i];
    }
    var["gGuidingCounter"] = mpRecordGuidingAtlas;
    var["gLightIndexGuidingCounter"] = mpRecordLightIndexGuidingTexture;

    var["gOutColor"] = renderData[kOutputColor]->asTexture();

    // Dispatch Shader
    mpScene->raytrace(pRenderContext, mTraceCameraPass.pProgram.get(), mTraceCameraPass.pVars, uint3(mScreenRes, 1));
}

void PhotonGuiding::debugPass(RenderContext* pRenderContext, const RenderData& renderData)
{
    FALCOR_PROFILE(pRenderContext, "Debug");

    if (!mpDebugPass)
    {
        Program::Desc desc;
        desc.addShaderLibrary(kShaderDebug).csEntry("main").setShaderModel(kShaderModel);

        DefineList defines;
        defines.add("COUNT_TEXTURES", std::to_string(mTotalLightCount));

        mpDebugPass = ComputePass::create(mpDevice, desc, defines, true);
    }

    auto var = mpDebugPass->getRootVar();

    uint3 dispatchDim = uint3(renderData.getDefaultTextureDims().xy(), 1);
    uint showDebugTexRes = mDebugShowLightIndexGuidingTex ? mGuidingLightIndexSize : mGuidingAtlasResolution;
    float scaleToDebugTexFactor = (float(math::min(dispatchDim.x, dispatchDim.y)) / float(showDebugTexRes)) + 0.5f;

    //Determine color scales
    float atlasColorScale = mDebugColorScaleFactor * mGuidingTextureResolution * mGuidingTextureResolution;
    if (mUseFixedGuidingDispatch)
        atlasColorScale /= mNumDispatchedPhotons;
    float lightIdxColorScale = mUseFixedGuidingDispatch ? mDebugColorScaleFactor / mNumDispatchedPhotons : mDebugColorScaleFactor;

    var["CB"]["gColorScaleFactor"] = atlasColorScale;
    var["CB"]["gGuidingAtlasSize"] = mGuidingAtlasResolution;
    var["CB"]["gDispatchSize"] = dispatchDim.xy();
    var["CB"]["gLightIndex"] = mDebugSelectedTriLight;
    var["CB"]["gGuidingTextureSize"] = mGuidingTextureResolution;
    var["CB"]["gSizeScaleFactor"] = mDebugScaleToDstDim ? scaleToDebugTexFactor : mDebugSizeScaleFactor;
    var["CB"]["gShowLightIndexGuiding"] = mDebugShowLightIndexGuidingTex;
    var["CB"]["gLightIndexGuidingSize"] = mGuidingLightIndexSize;
    var["CB"]["gLightIndexGuidingScale"] = lightIdxColorScale;
    var["CB"]["gIsFixedGuidingMode"] = mUseFixedGuidingDispatch;
      
    var["gGuidingTexture"] = mpGuidingAtlas[mFrameCount % 2];
    var["gLightIndexGuidingTexture"] = mpLightIndexGuidingTexture[mFrameCount % 2];
    var["gDebug"] = renderData[kOutputDebug]->asTexture();
    var["gLinearSampler"] = mpLinearSampler;
    var["gPointSampler"] = mpPointSampler;

    mpDebugPass->execute(pRenderContext, dispatchDim);
}

void PhotonGuiding::handlePhotonCounter(RenderContext* pRenderContext)
{
    // Copy the photonCounter to a CPU Buffer
    pRenderContext->copyBufferRegion(mpPhotonCounterCPU.get(), 0, mpPhotonCounter.get(), 0, sizeof(uint2));

    void* data = mpPhotonCounterCPU->map(Buffer::MapType::Read);
    std::memcpy(&mCurrentPhotonCount, data, sizeof(uint2));
    mpPhotonCounterCPU->unmap();

    // Change Photon dispatch count dynamically.
    
    if (mUseDynamicPhotonDispatchCount)
    {
        // Only use global photons for the dynamic dispatch count
        uint globalPhotonCount = mCurrentPhotonCount[0];
        uint globalMaxPhotons = mNumMaxPhotons[0];
        uint causticPhotonCount = mCurrentPhotonCount[1];
        uint causticMaxPhotons = mNumMaxPhotons[1];
        // If counter is invalid, reset
        if (globalPhotonCount == 0)
        {
            mNumDispatchedPhotons = mPhotonDynamicDispatchMax / 2;
        }
        uint globBufferSizeCompValue = (uint)(globalMaxPhotons * (1.f - mPhotonDynamicGuardPercentage));
        uint globChangeSize = (uint)(globalMaxPhotons * mPhotonDynamicChangePercentage);
        uint causticBufferSizeCompValue = (uint)(causticMaxPhotons * (1.f - mPhotonDynamicGuardPercentage));
        uint causticChangeSize = (uint)(causticMaxPhotons * mPhotonDynamicChangePercentage);
        uint changeSize = std::max(globChangeSize, causticChangeSize);

        // If smaller, increase dispatch size
        if ((globalPhotonCount < globBufferSizeCompValue) && (causticPhotonCount < causticBufferSizeCompValue))
        {
            uint newDispatched = (uint)(mNumDispatchedPhotons + changeSize);
            mNumDispatchedPhotons = std::min(newDispatched, mPhotonDynamicDispatchMax);
        }
        // Reduce dispatch size
        else
        {
            uint newDispatched = (uint)(mNumDispatchedPhotons - changeSize);
            mNumDispatchedPhotons = std::max(newDispatched, 1024u);
        }
    }
}

void PhotonGuiding::resetRenderPasses()
{
    mTracePhotonPass.reset();
    mTraceCameraPass.reset();
    mpGuidingCounterReducePass.reset();
    mpGuidingLightIndexCounterReducePass.reset();
    mpGenerateGuidingMipTraverseChainPass.reset();
    mpGenerateLightIndexGuidingMipTraverseChainPass.reset();
    mpDebugPass.reset();

    mGenerateInitialSamplesPass.reset();
    mpResampleReservoirCausticPass.reset();
    mpResampleReservoirFGPass.reset();
    mpEvaluateReservoirsPass.reset();
    mpSplatSortCellData.reset();
    mpSplatSortComputeCellOffsets.reset();
    mpTemporalSplatReservoirs.reset();

    mResetClearResources = true;
}

float PhotonGuiding::getNormalizedPixelArea()
{
    if (!mpScene)
        return 1.0;

    // Update Image plane distance
    auto& cameraData = mpScene->getCamera()->getData();
    float fovY = focalLengthToFovY(cameraData.focalLength, cameraData.frameHeight);

    // Get normalized pixel area
    float h = tan(fovY / 2.f) * 2.f;
    float w = h * cameraData.aspectRatio;
    float wPix = w / mScreenRes.x;
    float hPix = h / mScreenRes.y;

    return wPix * hPix;
}

void PhotonGuiding::reSTIRGenerateInitialSamplesPass(RenderContext* pRenderContext, const RenderData& renderData)
{
    FALCOR_PROFILE(pRenderContext, "ReSTIRInitialSamples");

    // Init Shader
    if (!mGenerateInitialSamplesPass.pProgram)
    {
        RtProgram::Desc desc;
        desc.addShaderModules(mpScene->getShaderModules());
        desc.addShaderLibrary(kShaderReSTIRInitialSamples);
        desc.setMaxPayloadSize(sizeof(float) * 4);
        desc.setMaxAttributeSize(mpScene->getRaytracingMaxAttributeSize());
        desc.setMaxTraceRecursionDepth(1);
        if (!mpScene->hasProceduralGeometry())
            desc.setPipelineFlags(RtPipelineFlags::SkipProceduralPrimitives);

        mGenerateInitialSamplesPass.pBindingTable = RtBindingTable::create(1, 1, mpScene->getGeometryCount());
        auto& sbt = mGenerateInitialSamplesPass.pBindingTable;
        sbt->setRayGen(desc.addRayGen("rayGen", mpScene->getTypeConformances()));
        sbt->setMiss(0, desc.addMiss("miss"));

        if (mpScene->hasGeometryType(Scene::GeometryType::TriangleMesh))
        {
            sbt->setHitGroup(0, mpScene->getGeometryIDs(Scene::GeometryType::TriangleMesh), desc.addHitGroup("closestHit", "anyHit"));
        }

        DefineList defines;
        defines.add(mpScene->getSceneDefines());

        mGenerateInitialSamplesPass.pProgram = RtProgram::create(mpDevice, desc, defines);
    }

    // Defines that can change on runtime
    mGenerateInitialSamplesPass.pProgram->addDefines(mpRTXDI->getDefines());
    mGenerateInitialSamplesPass.pProgram->addDefine("ROUGHNESS_THRESHOLD", std::to_string(mSpecularRoughnessThreshold));
    mGenerateInitialSamplesPass.pProgram->addDefine("GUIDING_MODE", std::to_string((uint)mGuidingMode));
    mGenerateInitialSamplesPass.pProgram->addDefine("LIGHT_INDEX_GUIDING_MODE", std::to_string((uint)mGuidingLightIndexMode));
    mGenerateInitialSamplesPass.pProgram->addDefine("ENABLE_LIGHT_TRACE_SPATTING", mEnableLightTraceSplatting ? "1" : "0");
    mGenerateInitialSamplesPass.pProgram->addDefine("GUIDING_DISCRETIZED_EMISSION_FACTOR", std::to_string(mGuidingDiscretizedEmissionFactor));

    // Program Vars
    if (!mGenerateInitialSamplesPass.pVars)
        mGenerateInitialSamplesPass.initProgramVars(mpDevice, mpScene, mpSampleGenerator);

    FALCOR_ASSERT(mGenerateInitialSamplesPass.pVars);
    auto var = mGenerateInitialSamplesPass.pVars->getRootVar();

    // Constant Buffer
    var["CB"]["gFrameCount"] = mFrameCount;
    var["CB"]["gFGRayMaxPathLength"] = mPTMaxBounces;
    var["CB"]["gNumLightPaths"] = mNumberLightPaths;
    var["CB"]["gNormalizedPixelArea"] = mNormalizedPixelArea;
    var["CB"]["gLightIndexGuidingResolution"] = mGuidingLightIndexSize;

    // RTXDI Resources
    mpRTXDI->setShaderData(var);

    // Input Resources
    var["gVBuffer"] = renderData[kInputVBuffer]->asTexture();
    mpPhotonAS->bindTlas(var, "gPhotonAS");
    for (uint32_t i = 0; i < 2; i++)
    {
        var["gPhotonAABB"][i] = mpPhotonAABB[i];
        var["gPhotonData"][i] = mpPhotonData[i];
    }
    var["gLightTraceHeadCounter"] = mpLightTraceHeadCounter;
    var["gLightTraceLinkedList"] = mpLightTraceLinkedList;
    var["gCausticPhotonHitInfo"] = mpCausticPhotonHitInfo;
    var["gMVec"] = renderData[kInputMVec]->asTexture();

    // Output Resources
    var["gFinalGatherReservoir"] = mpFinalGatherReservoir[mFrameCount % 2];
    var["gCausticReservoir"] = mpCausticReservoir[mFrameCount % 2];
    var["gEmission"] = mpEmission;
    var["gResamplingMVec"] = mpResampleMVec;

    //Guiding textures
    var["gGuidingCounter"] = mpRecordGuidingAtlas;
    var["gLightIndexGuidingCounter"] = mpRecordLightIndexGuidingTexture;

    // Dispatch Shader
    mpScene->raytrace(pRenderContext, mGenerateInitialSamplesPass.pProgram.get(), mGenerateInitialSamplesPass.pVars, uint3(mScreenRes, 1));

    // Reservoir barrier
    pRenderContext->uavBarrier(mpFinalGatherReservoir[mFrameCount % 2].get());
    pRenderContext->uavBarrier(mpCausticReservoir[mFrameCount % 2].get());

}

void PhotonGuiding::reSTIRResampleFGPass(RenderContext* pRenderContext, const RenderData& renderData)
{
    FALCOR_PROFILE(pRenderContext, "Resampling Final Gather");
    // Initialize compute pass
    if (!mpResampleReservoirFGPass)
    {
        Program::Desc desc;
        desc.addShaderModules(mpScene->getShaderModules());
        desc.addShaderLibrary(kShaderReSTIRResampleFG).csEntry("main").setShaderModel(kShaderModel);
        desc.addTypeConformances(mpScene->getTypeConformances());

        DefineList defines;
        defines.add(mpScene->getSceneDefines());
        defines.add(mpSampleGenerator->getDefines());
        defines.add("USE_ENV_BACKROUND", mpScene->useEnvBackground() ? "1" : "0");
        defines.add(mpRTXDI->getDefines());
        defines.add("ENABLE_GUIDING_JACOBIAN", mReSTIREnableGuidingJacobian ? "1" : "0");

        mpResampleReservoirFGPass = ComputePass::create(mpDevice, desc, defines, true);
    }
    FALCOR_ASSERT(mpResampleReservoirFGPass);

    //Runtime defines
    mpResampleReservoirFGPass->getProgram()->addDefine("ENABLE_GUIDING_JACOBIAN",mReSTIREnableGuidingJacobian ? "1" : "0");

    // Return early if there is no previous reservoir or resampling is disabled
    if ((!mCanResample) || !mResampleSettingsFG.enable)
    {
        return;
    }

    // Set variables
    auto var = mpResampleReservoirFGPass->getRootVar();
    mpScene->setRaytracingShaderData(pRenderContext, var); // Set scene data
    mpSampleGenerator->setShaderData(var);                 // Sample generator

    // Constant Buffer
    var["CB"]["gFrameCount"] = mFrameCount;
    var["CB"]["gFrameDim"] = mScreenRes;
    var["CB"]["gConfidenceLimit"] = mResampleSettingsFG.confidenceCap;
    var["CB"]["gSpatialRadius"] = mResampleSettingsFG.samplingRadius;
    var["CB"]["gSpatialSamples"] = mResampleSettingsFG.spatialSamples;
    var["CB"]["gDisocclusionBoostSpatialSamples"] = mResampleSettingsFG.disocclusionBoostExtraSamples;
    var["CB"]["gNormalThreshold"] = mResampleSettingsFG.normalThreshold;
    var["CB"]["gJacobianDistanceThreshold"] = mResampleSettingsFG.jacobianDistanceThreshold;
    var["CB"]["gUsePathThreshold"] = mResampleSettingsFG.usePathThreshold;
    var["CB"]["gLightGuidingTextureResSq"] = mGuidingTextureResolution * mGuidingTextureResolution;
    var["CB"]["gLightIndexGuidingResolution"] = mGuidingLightIndexSize;

    // Input Resources
    var["gFinalGatherReservoirPrev"] = mpFinalGatherReservoir[(mFrameCount + 1) % 2];
    var["gMVec"] = mpResampleMVec;
    var["gLightIndexGuiding"] = mpLightIndexGuidingTexture[mFrameCount % 2];
    var["gLightIndexGuidingPrev"] = mpLightIndexGuidingTexture[(mFrameCount + 1) % 2];
    var["gGuidingAtlas"] = mpGuidingAtlas[mFrameCount % 2];
    var["gGuidingAtlasPrev"] = mpGuidingAtlas[(mFrameCount+1) % 2];

    // In-/Output Resources
    var["gFinalGatherReservoir"] = mpFinalGatherReservoir[mFrameCount % 2];

    // Execute Compute Pass
    const uint2 targetDim = renderData.getDefaultTextureDims();
    FALCOR_ASSERT(targetDim.x > 0 && targetDim.y > 0);
    mpResampleReservoirFGPass->execute(pRenderContext, uint3(targetDim, 1));
}

void PhotonGuiding::reSTIRResampleCausticPass(RenderContext* pRenderContext, const RenderData& renderData)
{
    FALCOR_PROFILE(pRenderContext, "Resampling Caustics");
    // Initialize compute pass
    if (!mpResampleReservoirCausticPass)
    {
        Program::Desc desc;
        desc.addShaderModules(mpScene->getShaderModules());
        desc.addShaderLibrary(kShaderReSTIRResampleCaustic).csEntry("main").setShaderModel(kShaderModel);
        desc.addTypeConformances(mpScene->getTypeConformances());

        DefineList defines;
        defines.add(mpScene->getSceneDefines());
        defines.add(mpSampleGenerator->getDefines());
        defines.add(mpRTXDI->getDefines());
        defines.add("USE_ADAPTIVE_PHOTON_RADIUS", mUseAdaptivePhotonRadius ? "1" : "0");
        defines.add("ENABLE_LIGHT_TRACE_SPATTING", mEnableLightTraceSplatting ? "1" : "0");
        defines.add("ENABLE_GUIDING_JACOBIAN", mReSTIREnableGuidingJacobian ? "1" : "0");

        mpResampleReservoirCausticPass = ComputePass::create(mpDevice, desc, defines, true);
    }
    FALCOR_ASSERT(mpResampleReservoirCausticPass);
    //Runtime defines
    mpResampleReservoirCausticPass->getProgram()->addDefine("USE_ADAPTIVE_PHOTON_RADIUS", mUseAdaptivePhotonRadius ? "1" : "0");
    mpResampleReservoirCausticPass->getProgram()->addDefine("ENABLE_LIGHT_TRACE_SPATTING", mEnableLightTraceSplatting ? "1" : "0");
    mpResampleReservoirCausticPass->getProgram()->addDefine("ENABLE_GUIDING_JACOBIAN",mReSTIREnableGuidingJacobian ? "1" : "0"); 

    // Return early if there is no previous reservoir or resampling is disabled
    if ((!mCanResample) || !mResampleSettingsCaustic.enable)
    {
        return;
    }

    // Set variables
    auto var = mpResampleReservoirCausticPass->getRootVar();
    mpScene->setRaytracingShaderData(pRenderContext, var); // Set scene data
    mpSampleGenerator->setShaderData(var);                 // Sample generator

    // Constant Buffer
    var["CB"]["gFrameCount"] = mFrameCount;
    var["CB"]["gFrameDim"] = mScreenRes;
    var["CB"]["gConfidenceLimit"] = mResampleSettingsCaustic.confidenceCap;
    var["CB"]["gSpatialRadius"] = mResampleSettingsCaustic.samplingRadius;
    var["CB"]["gSpatialSamples"] = mResampleSettingsCaustic.spatialSamples;
    var["CB"]["gDisocclusionBoostSpatialSamples"] = mResampleSettingsCaustic.disocclusionBoostExtraSamples;
    var["CB"]["gNormalThreshold"] = mResampleSettingsCaustic.normalThreshold;
    var["CB"]["gPhotonRadius"] = mPhotonRadius;
    var["CB"]["gAdaptivePhotonRadius"] = mAdaptivePhotonRadius;
    var["CB"]["gNormalizedPixelDiagonal"] = mNormalizePixelDiagonal;
    var["CB"]["gLightGuidingTextureResSq"] = mGuidingTextureResolution * mGuidingTextureResolution;
    var["CB"]["gLightIndexGuidingResolution"] = mGuidingLightIndexSize;

    var["CB"]["gPrevCamPos"] = mTemporalCameraPosition;
    var["CB"]["gPrevCamViewProjection"] = mTemporalCameraViewProjection;
    var["CB"]["gPrevCamForward"] = mTemporalCameraForward;
    var["CB"]["gNormalizedPixelArea"] = mNormalizedPixelArea;

    // Input Resources
    var["gCausticReservoirPrev"] = mpCausticReservoir[(mFrameCount + 1) % 2];
    var["gMVec"] = mpResampleMVec;
    var["gLightIndexGuiding"] = mpLightIndexGuidingTexture[mFrameCount % 2];
    var["gLightIndexGuidingPrev"] = mpLightIndexGuidingTexture[(mFrameCount + 1) % 2];
    var["gGuidingAtlas"] = mpGuidingAtlas[mFrameCount % 2];
    var["gGuidingAtlasPrev"] = mpGuidingAtlas[(mFrameCount + 1) % 2];

    // In-/Output Resources
    var["gCausticReservoir"] = mpCausticReservoir[mFrameCount % 2];

    var["gCellCounters"] = mpSplattingCellCounter;
    var["gCellOffsets"] = mpSplattingCellOffsets;
    var["gSortedReservoirs"] = mpSplattingSortedReservoirs;

    // Execute
    const uint2 targetDim = renderData.getDefaultTextureDims();
    FALCOR_ASSERT(targetDim.x > 0 && targetDim.y > 0);
    mpResampleReservoirCausticPass->execute(pRenderContext, uint3(targetDim, 1));
}

void PhotonGuiding::reSTIREvaluateReservoirsPass(RenderContext* pRenderContext, const RenderData& renderData)
{
    FALCOR_PROFILE(pRenderContext, "EvaluateReservoirs");

    // Create compute pass
    if (!mpEvaluateReservoirsPass)
    {
        Program::Desc desc;
        desc.addShaderModules(mpScene->getShaderModules());
        desc.addShaderLibrary(kShaderReSTIREvalReservoirs).csEntry("main").setShaderModel(kShaderModel);
        desc.addTypeConformances(mpScene->getTypeConformances());

        DefineList defines;
        defines.add(mpScene->getSceneDefines());
        defines.add(mpSampleGenerator->getDefines());
        defines.add("USE_ENV_BACKROUND", mpScene->useEnvBackground() ? "1" : "0");
        defines.add(mpRTXDI->getDefines());
        defines.add("GUIDING_MODE", std::to_string((uint)mGuidingMode));
        defines.add("LIGHT_INDEX_GUIDING_MODE", std::to_string((uint)mGuidingLightIndexMode));
        defines.add("ENABLE_LIGHT_TRACE_SPATTING", mEnableLightTraceSplatting ? "1" : "0");
        defines.add("GUIDING_DISCRETIZED_EMISSION_FACTOR", std::to_string(mGuidingDiscretizedEmissionFactor));
        defines.add("DEBUG_DISABLE_DIRECT_LIGHT", std::to_string(mDebugDisableDirectLight));
        defines.add("DEBUG_DISABLE_INDIRECT_LIGHT", std::to_string(mDebugDisableIndirectLight));

        mpEvaluateReservoirsPass = ComputePass::create(mpDevice, desc, defines, true);
    }
    FALCOR_ASSERT(mpEvaluateReservoirsPass);

    // Runtime Defines
    mpEvaluateReservoirsPass->getProgram()->addDefines(mpRTXDI->getDefines());
    mpEvaluateReservoirsPass->getProgram()->addDefine("USE_ENV_BACKROUND", mpScene->useEnvBackground() ? "1" : "0");
    mpEvaluateReservoirsPass->getProgram()->addDefine("GUIDING_MODE", std::to_string((uint)mGuidingMode));
    mpEvaluateReservoirsPass->getProgram()->addDefine("LIGHT_INDEX_GUIDING_MODE", std::to_string((uint)mGuidingLightIndexMode));
    mpEvaluateReservoirsPass->getProgram()->addDefine("ENABLE_LIGHT_TRACE_SPATTING", mEnableLightTraceSplatting ? "1" : "0");
    mpEvaluateReservoirsPass->getProgram()->addDefine("GUIDING_DISCRETIZED_EMISSION_FACTOR", std::to_string(mGuidingDiscretizedEmissionFactor));
    mpEvaluateReservoirsPass->getProgram()->addDefine("DEBUG_DISABLE_DIRECT_LIGHT", std::to_string(mDebugDisableDirectLight));
    mpEvaluateReservoirsPass->getProgram()->addDefine("DEBUG_DISABLE_INDIRECT_LIGHT", std::to_string(mDebugDisableIndirectLight));

    // Set variables
    auto var = mpEvaluateReservoirsPass->getRootVar();
    mpScene->setRaytracingShaderData(pRenderContext, var); // Set scene data
    mpSampleGenerator->setShaderData(var);                 // Sample generator

    // Constant Buffer
    var["CB"]["gFrameCount"] = mFrameCount;
    var["CB"]["gFrameDim"] = mScreenRes;
    var["CB"]["gNormalizedPixelArea"] = mNormalizedPixelArea;
    var["CB"]["gLightIndexGuidingResolution"] = mGuidingLightIndexSize;

    // RTXDI resources
    mpRTXDI->setShaderData(var);

    // Input
    var["gVBuffer"] = renderData[kInputVBuffer]->asTexture();
    var["gFinalGatherReservoir"] = mpFinalGatherReservoir[mFrameCount % 2];
    var["gCausticReservoir"] = mpCausticReservoir[mFrameCount % 2];
    var["gEmission"] = mpEmission;

    // Output
    var["gOutColor"] = renderData[kOutputColor]->asTexture();

    // Guiding textures
    var["gGuidingCounter"] = mpRecordGuidingAtlas;
    var["gLightIndexGuidingCounter"] = mpRecordLightIndexGuidingTexture;

    // Execute
    const uint2 targetDim = renderData.getDefaultTextureDims();
    FALCOR_ASSERT(targetDim.x > 0 && targetDim.y > 0);
    mpEvaluateReservoirsPass->execute(pRenderContext, uint3(targetDim, 1));
}

void PhotonGuiding::RayTraceProgramHelper::initProgramVars(ref<Device> pDevice, ref<Scene> pScene, ref<SampleGenerator> pSampleGenerator)
{
    FALCOR_ASSERT(pProgram);

    // Configure program.
    pProgram->addDefines(pSampleGenerator->getDefines());
    pProgram->setTypeConformances(pScene->getTypeConformances());
    // Create program variables for the current program.
    // This may trigger shader compilation. If it fails, throw an exception to abort rendering.
    pVars = RtProgramVars::create(pDevice, pProgram, pBindingTable);

    // Bind utility classes into shared data.
    auto var = pVars->getRootVar();
    pSampleGenerator->setShaderData(var);
}

void PhotonGuiding::reSTIRSplatTemporalReservoirsPass(RenderContext* pRenderContext, const RenderData& renderData)
{
    FALCOR_PROFILE(pRenderContext, "Splat Caustic Reservoirs");

    pRenderContext->clearUAV(mpSplattingGlobalCounter->getUAV(0).get(), uint4(0));
    pRenderContext->clearUAV(mpSplattingCellCounter->getUAV(0).get(), uint4(0));
    pRenderContext->clearUAV(mpSplattingCellOffsets->getUAV(0).get(), uint4(0));

    if (!mpTemporalSplatReservoirs)
    {
        Program::Desc desc;
        desc.addShaderModules(mpScene->getShaderModules());
        desc.addShaderLibrary(kShaderReSTIRTemporalSplatReservoirs).csEntry("main").setShaderModel(kShaderModel);
        desc.addTypeConformances(mpScene->getTypeConformances());

        DefineList defines;
        defines.add(mpScene->getSceneDefines());
        defines.add(mpSampleGenerator->getDefines());
        defines.add("USE_ENV_BACKROUND", mpScene->useEnvBackground() ? "1" : "0");

        mpTemporalSplatReservoirs = ComputePass::create(mpDevice, desc, defines, true);
    }
    FALCOR_ASSERT(mpTemporalSplatReservoirs);

    // Return early if there is no previous reservoir or resampling is disabled
    if ((!mCanResample) || !mResampleSettingsFG.enable)
    {
        return;
    }

    // Set variables
    auto var = mpTemporalSplatReservoirs->getRootVar();
    mpScene->setRaytracingShaderData(pRenderContext, var); // Set scene data

    var["CB"]["gFrameDim"] = mScreenRes;

    var["gPrevReservoir"] = mpCausticReservoir[(mFrameCount + 1) % 2];
    var["gCellCounter"] = mpSplattingCellCounter;
    var["gGlobalCounter"] = mpSplattingGlobalCounter;
    var["gSplatSortData"] = mpSplattingSortingData;

    // Execute Compute Pass
    const uint2 targetDim = mScreenRes;
    FALCOR_ASSERT(targetDim.x > 0 && targetDim.y > 0);
    mpTemporalSplatReservoirs->execute(pRenderContext, uint3(targetDim, 1));
}

void PhotonGuiding::reSTIRSortSplattedReservoirsPass(RenderContext* pRenderContext, const RenderData& renderData)
{
    FALCOR_PROFILE(pRenderContext, "Sort Splatted Reservoirs");

    // Init Shaders
    if (!mpSplatSortComputeCellOffsets)
    {
        Program::Desc desc;
        desc.addShaderModules(mpScene->getShaderModules());
        desc.addShaderLibrary(kShaderReSTIRSortSplatReservoirs).csEntry("computeCellOffsets").setShaderModel(kShaderModel);
        desc.addTypeConformances(mpScene->getTypeConformances());

        DefineList defines;
        defines.add(mpScene->getSceneDefines());
        defines.add(mpSampleGenerator->getDefines());

        mpSplatSortComputeCellOffsets = ComputePass::create(mpDevice, desc, defines, true);
    }
    FALCOR_ASSERT(mpSplatSortComputeCellOffsets);

    if (!mpSplatSortCellData)
    {
        Program::Desc desc;
        desc.addShaderModules(mpScene->getShaderModules());
        desc.addShaderLibrary(kShaderReSTIRSortSplatReservoirs).csEntry("sortCellData").setShaderModel(kShaderModel);
        desc.addTypeConformances(mpScene->getTypeConformances());

        DefineList defines;
        defines.add(mpScene->getSceneDefines());
        defines.add(mpSampleGenerator->getDefines());
        defines.add("USE_ENV_BACKROUND", mpScene->useEnvBackground() ? "1" : "0");

        mpSplatSortCellData = ComputePass::create(mpDevice, desc, defines, true);
    }
    FALCOR_ASSERT(mpSplatSortCellData);

    // Return early if there is no previous reservoir or resampling is disabled
    if ((!mCanResample) || !mResampleSettingsFG.enable)
    {
        return;
    }

    // Lambda for shader vars as they are the same for both shaders
    auto setProgramVars = [&](ShaderVar& var)
    {
        mpScene->setRaytracingShaderData(pRenderContext, var); // Set scene data
        var["CB"]["gFrameDim"] = mScreenRes;

        var["gGlobalCounter"] = mpSplattingGlobalCounter;
        var["gCellCounter"] = mpSplattingCellCounter;
        var["gCellOffsets"] = mpSplattingCellOffsets;
        var["gSortingData"] = mpSplattingSortingData;
        var["gSortedReservoirs"] = mpSplattingSortedReservoirs;
    };

    // Cell offset pass
    {
        pRenderContext->uavBarrier(mpSplattingGlobalCounter.get());
        auto var = mpSplatSortComputeCellOffsets->getRootVar();
        setProgramVars(var);

        const uint2 targetDim = mScreenRes;
        FALCOR_ASSERT(targetDim.x > 0 && targetDim.y > 0);
        mpSplatSortComputeCellOffsets->execute(pRenderContext, uint3(targetDim, 1));
        pRenderContext->uavBarrier(mpSplattingGlobalCounter.get());
        pRenderContext->uavBarrier(mpSplattingCellOffsets.get());
    }

    // Sorting pass
    {
        auto var = mpSplatSortCellData->getRootVar();
        setProgramVars(var);

        const uint targetDim = mScreenRes.x * mScreenRes.y;
        FALCOR_ASSERT(targetDim > 0);
        mpSplatSortCellData->execute(pRenderContext, uint3(targetDim, 1, 1));
    }
}
