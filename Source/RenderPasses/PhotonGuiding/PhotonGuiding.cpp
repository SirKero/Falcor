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
    const std::string kShaderGetFreePhotonsBasedOnDist = kShaderFolder + "GetFreePhotonsBasedOnDist.cs.slang";
    const std::string kShaderGuidingBlurAtlas = kShaderFolder + "GuidingBlurAtlas.cs.slang";
    const std::string kShaderGuidingReduce = kShaderFolder + "GuidingCounterReduce.cs.slang";
    const std::string kShaderDebug = kShaderFolder + "Debug.cs.slang";

    //ReSTIR shader
    const std::string kShaderFolderReSTIR = kShaderFolder + "/ReSTIR_FG/";
    const std::string kShaderReSTIRInitialSamples = kShaderFolderReSTIR + "GenerateInitialSamples.rt.slang";
    const std::string kShaderReSTIRResampleFG = kShaderFolderReSTIR + "ResampleReservoirFG.cs.slang";
    const std::string kShaderReSTIRRetracePath = kShaderFolderReSTIR + "RetracePath.rt.slang";
    const std::string kShaderReSTIRResamplePath = kShaderFolderReSTIR + "ResampleReservoirPath.cs.slang";
    const std::string kShaderReSTIRResampleCaustic = kShaderFolderReSTIR + "ResampleReservoirCaustic.cs.slang";
    const std::string kShaderReSTIREvalReservoirs = kShaderFolderReSTIR + "EvaluateReservoirs.cs.slang";
    const std::string kShaderReSTIRTemporalSplatReservoirs = kShaderFolderReSTIR + "TemporalSplatReservoir.cs.slang";
    const std::string kShaderReSTIRRetraceAndSplatReservoirs = kShaderFolderReSTIR + "RetraceAndSplatReservoir.rt.slang";
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
    const std::string kOutputNRDDiffuseRadiance = "NRDDiffuseRadiance";
    const std::string kOutputNRDSpecularRadiance = "NRDSpecularRadiance";
    const std::string kOutputNRDDiffuseReflectance = "NRDDiffuseReflectance";
    const std::string kOutputNRDSpecularReflectance = "NRDSpecularReflectance";
    const Falcor::ChannelList kOutputChannels{
        {kOutputColor, "gOutColor", "HDR output color", false /*optional*/, ResourceFormat::RGBA32Float},
        {kOutputDebug, "gDebug", "Debug Texture", true /*optional*/, ResourceFormat::RGBA32Float},
        {kOutputNRDDiffuseRadiance, "gNRDDiffuseRadiance", "NRD demodulated diffuse color (linear)", true /*optional*/, ResourceFormat::RGBA32Float},
        {kOutputNRDSpecularRadiance, "gNRDSpecularRadiance", "NRD demodulated specular color (linear)", true /*optional*/, ResourceFormat::RGBA32Float},
        {kOutputNRDDiffuseReflectance, "gNRDDiffuseReflectance", "NRD primary surface diffuse reflectance", true /*optional*/, ResourceFormat::RGBA32Float},
        {kOutputNRDSpecularReflectance, "gNRDSpecularReflectance", "NRD primary surface specular reflectance", true /*optional*/, ResourceFormat::RGBA32Float}
    };

    const std::string kShaderModel = "6_6";

    const Gui::DropdownList kNumberOfFixedGuidingMaps = {
        {32, "32"},
        {64, "64"},
        {128, "128"},
        {256, "256"},
        {512, "512"},
        {1024, "1024"},
        {2048, "2048"},
        {4096, "4096"},
        {8192, "8192"},
    };

    const Gui::DropdownList kGuidingMapResolution = {
        {8, "8"},
        {16, "16"},
        {32, "32"},
        {64, "64"},
        {128, "128"},
        {256, "256"},
        {512, "512"}
    };
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

    //Set caustic settings
    mResampleSettingsCaustic.samplingRadius = 4.f;
    mResampleSettingsCaustic.spatialSamples = 0;

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
    if ((cameraMoved && (mGuidingHistogramAccumMode == GuidingHistogramAccumulateMode::ResetOnMove)) || mOptionsChanged || mGuidingResetAccumulateCount)
    {
        mGuidingAccumulateCount = 0;
        mGuidingResetAccumulateCount = false;
    }

    mNormalizedPixelArea = getNormalizedPixelArea();
    mOptionsChanged = false;

    // Prepare needed Falcor helpers and Buffers/Textures
    prepareLightingStructure(pRenderContext, renderData);

    //Return if there is no emissive light
    if (mTotalLightCount == 0)
        return;

    if (mUseDirectionAtlasOptimization) {
        if(mTotalLightCount <= mAtlasOptimizationMaxDirectionGuidingMaps)
            mUseDirectionAtlasOptimization = false;
    }

    //Prepare Textures and Buffers
    prepareResources(pRenderContext, renderData);

    updateGuidingTextures(pRenderContext, renderData);

    updateNumberOfRNGPasses();

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
    case Falcor::PhotonGuidingSharedEnums::PhotonRenderMode::ReSTIR_PathPhoton:
    {
        if (!mpRTXDI)
            mpRTXDI = std::make_unique<RTXDI>(mpScene, mRTXDIOptions);
        mpRTXDI->beginFrame(pRenderContext, mScreenRes);

        // Initial Samples for ReSTIR FG (1SPP Photon Final Gathering) and inti RTXDI structs
        reSTIRGenerateInitialSamplesPass(pRenderContext, renderData);

        if (mEnableLightTraceSplatting)
        {
            //Reproject reservoirs from last frame to current camera
            if (mRetraceLightPaths)
                reSTIRRetraceAndSplatTemporalReservoirsPass(pRenderContext, renderData);
            else
                reSTIRSplatTemporalReservoirsPass(pRenderContext, renderData);

            //Sort Splatted reservoirs, so they can be properly used for resampling
            if (mSplattingResampleUseLinkedList)
                pRenderContext->uavBarrier(mpSplattingCellCounter.get());
            else
                reSTIRSortSplattedReservoirsPass(pRenderContext, renderData);
        }

        // ReSTIR DI pass
        const auto& pMotionVectors = renderData[kInputMVec]->asTexture();
        mpRTXDI->update(pRenderContext, pMotionVectors);

        // Spatiotemporal resampling for final gather samples and caustics
        if (mPhotonRenderMode == Falcor::PhotonGuidingSharedEnums::PhotonRenderMode::ReSTIR_FG)
            reSTIRResampleFGPass(pRenderContext, renderData);
        else
        {
            for (uint i = 0; i < mResampleSettingsFG.spatialSamples + 1; i++)
            {
                reSTIRRetracePathsPass(pRenderContext, renderData, i);

                reSTIRResamplePathsPass(pRenderContext, renderData, i);
            }
        }
            
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

    if (mEnableSPPM)
    {
        if (is_set(mpScene->getUpdates(), Scene::UpdateFlags::CameraMoved) || mSPPMFramesCameraStill == 0)
        {
            mSPPMFramesCameraStill = 0;
            mPhotonRadius = mSPPMStartRadius;
        }

        float itF = static_cast<float>(mSPPMFramesCameraStill);
        mPhotonRadius *= sqrt((itF + mSPPMAlpha) / (itF + 1.0f));

        mSPPMFramesCameraStill++;
    }

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
        if(mPhotonRenderMode == PhotonRenderMode::ReSTIR_FG)
        {
            mEnableLightTraceSplatting = false;
        }else if(mPhotonRenderMode == PhotonRenderMode::ReSTIR_PathPhoton)
        {
            mEnableLightTraceSplatting = true;
        }
    }
    if (widget.dropdown("Guiding Mode", mGuidingMode))
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

        changed |= mPhotonPathLength.renderUI(group, "##Photon");

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

            if(group.checkbox("Use SPPM", mEnableSPPM))
            {
                if(mEnableSPPM)
                    mSPPMStartRadius = mPhotonRadius;
                else
                    mPhotonRadius = mSPPMStartRadius;
                changed = true;
            }

            if(mEnableSPPM)
            {
                group.var("SPPM Alpha", mSPPMAlpha, 0.f, 1.f, 0.0001f);
                if(group.button("Reset SPPM"))
                    mSPPMFramesCameraStill = 0;
            }
        }
      

        group.checkbox("Enable Russian Roulette", mPhotonRussianRoulette);
    }

    if (auto group = widget.group("Guiding Options"))
    {
        bool rebuildGuidingTextures = false;

        //TODO check, is bugged 
        //rebuildGuidingTextures |= group.dropdown("GM Resolution", kGuidingMapResolution, mGuidingTextureResolution);

        //Set default values on reset
        if (group.dropdown("Guiding Histogram Accumulate Mode", mGuidingHistogramAccumMode))
        {
            mGuidingResetAccumulateCount = true;
            if (mGuidingHistogramAccumMode == GuidingHistogramAccumulateMode::AverageFrames)
                mGuidingHistogramAccumValue = 64.f;
            else if (mGuidingHistogramAccumMode == GuidingHistogramAccumulateMode::AveragePercentage)
                mGuidingHistogramAccumValue = 0.3f;
        }
        
        //2nd option for accum mode
        if (mGuidingHistogramAccumMode == GuidingHistogramAccumulateMode::AverageFrames)
        {
            uint frameVal = (uint)floor(mGuidingHistogramAccumValue);
            group.var("Frame Limit", frameVal, 0u, UINT_MAX, 1u);
            mGuidingHistogramAccumValue = (float)frameVal;
        }
        else if (mGuidingHistogramAccumMode == GuidingHistogramAccumulateMode::AveragePercentage)
            group.var("Running Percentage", mGuidingHistogramAccumValue, 0.f, 1.f, 0.0001f);
           

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
        group.var("Guiding Discretized Max", mGuidingDiscretizedEmissionMax, mGuidingDiscretizedEmissionFactor, UINT_MAX, 1u);
        group.tooltip("Max value the discretized emission factor can reach");

        if (mGuidingMode == GuidingMode::Emission || mGuidingMode == GuidingMode::ReSTIR)
            changed |= group.var("Uniform weight (clear value)", mGuidingClearValueEmission, 0.f, FLT_MAX, 0.001f);

        changed |= group.checkbox("Map Guiding to Photon dispatch size", mUseFixedGuidingDispatch);

        changed |= group.checkbox("Use Distance based Min Photons (DBMP) per Light", mGuidingUseDistanceBasedMinPhoton);
        changed |= group.var(
            "Light Guiding: Min Photons Per Light", mFixedGuidingDispatchReservedPhotons, 32u, mGuidingTextureResolution * mGuidingTextureResolution, 1u
        );
        changed |= group.var("DBMP Min/Max Distance", mGuidingDBMPMinMaxDistance, 0.f, FLT_MAX, 0.0001f);
        changed |= group.var("DBMP Min/Max Photons", mGuidingDBMPMinMaxPhotons, 1, UINT_MAX, 1u);

        changed |= group.var("Directional Guiding: Min Photons needed per Texel", mMinPhotonsPerGuidingTexel, 1u, 256u, 1u);
        group.tooltip("Minimum of photons per texel to create a directional guiding map. Else random distribution is used."
            "\n If Optimized Atlas is used, a guiding atlas is dropped if the light photons falls below this number. For creation a seperate value is used (see setting below).");

        rebuildGuidingTextures |= group.checkbox("Use Optimized Guiding Atlas", mUseDirectionAtlasOptimization);
        group.tooltip("Limits the number of directional guiding maps and uses a map texture to map light indices to the guiding maps."
            "Setting is disabled if the number of lights is smaller than the limit.");
        rebuildGuidingTextures |= group.dropdown("Optimized Atlas, Fixed Guiding Textures", kNumberOfFixedGuidingMaps, mAtlasOptimizationMaxDirectionGuidingMaps);
        group.tooltip("Number of directional guiding textures.");

        if (mUseDirectionAtlasOptimization) {
            changed |= group.var("Directional Guiding: Min Photons per Light to create",mAtlasOptiMinPhotonsPerTexelToCreate, mMinPhotonsPerGuidingTexel, 256u, 1u);
            group.tooltip("Only used with the Atlas Optimization. Only creates a directional guiding map if photons for the light are above this value."
                "Needs to be equal or higher than the minimum photons per directional guiding map texels option above");
        }

        mGuidingResetAccumulateCount = group.button("Reset Guiding Textures");

        //Check if guiding texture needs to be resetted
        mResetGuidingTextures |= rebuildGuidingTextures;
        changed |= rebuildGuidingTextures;
    }

    if (mPhotonRenderMode == PhotonRenderMode::ReSTIR_FG || mPhotonRenderMode == PhotonRenderMode::ReSTIR_PathPhoton)
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
        if (auto group = widget.group("ReSTIR FG+"))
        {
            group.var("Final Gather Path Length", mPTMaxBounces, 1u, 64u, 1u);
            group.tooltip(
                "Path length for a final gather sample. A final gather sample stops when it encounters a rough enough surface (see "
                "Material Options)"
            );

            group.checkbox("Use Photons only for indirect light", mUseNEEatFGPoint);
            group.tooltip("Stores and collects photons with path length >= 1. For all direct light, NEE is used");

            auto resampleUI = [](ResamplingSettings& settings, Gui::Widgets& widget, bool isCausticResampling = false, bool includeDisocclusionSamples = false)
            {
                widget.checkbox("Enable Resampling", settings.enable);
                widget.var("Confidence Cap", settings.confidenceCap, 1u, UINT_MAX, 1u);
                widget.tooltip("Maximum confidence a reservoir can have");
                widget.var("Spatial Samples", settings.spatialSamples, 0u, 64u, 1u);
                if (includeDisocclusionSamples) {
                    widget.var("Disocclusion additional spatial samples", settings.disocclusionBoostExtraSamples, 0u, 16u, 1u);
                    widget.tooltip("Extra spatial samples if temporal resampling fails");

                }
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
                resampleUI(mResampleSettingsFG, group2, false, mPhotonRenderMode == PhotonRenderMode::ReSTIR_FG);
                if (mPhotonRenderMode == PhotonRenderMode::ReSTIR_PathPhoton) {
                    if (group2.checkbox("Use NEE for direct Light after specular hit", mPathResamplingUseNEEAfterSpecular))
                        mCanResample = false;
                    group2.tooltip("If enabled, NEE is used for direct light after an specular surface was encountered."
                        "Else, the radiance estimate for those surfaces includes global photons with a path lenght of 0 (direct light for that surface)");
                    if (group2.checkbox("Stop tracing the Path if diffuse->specular hit is encountered", mPathResamplingStopAfterDiffuseSpecular))
                        mCanResample = false;
                    group2.tooltip("If enabled, the path is not traced further if a specular hit is encountered after the first diffuse hit."
                        "This case is usually covered by caustics and tracing further wastes performance.");
                    group2.checkbox("Seperate Retrace shader", mPathRetraceSeperatePass);
                    group2.tooltip("Uses a seperate pass for retracing the current and other reservoir sample");
                }
            }
            if (auto group2 = group.group("Resampling Caustic options"))
            {
                resampleUI(mResampleSettingsCaustic, group2, true);
                if (group2.checkbox("Use Light Trace Splatting for direct", mEnableLightTraceSplatting))
                    mCanResample = false;
                group2.tooltip("Enables Light Trace with ReSTIR Splatting for the directly visible caustics");
                if (group2.checkbox("Splatting: Use Linked List", mSplattingResampleUseLinkedList))
                    mResetClearResources = true;
                group2.tooltip("Uses a linked list instead of sorting the splatted reservoirs");
                group2.checkbox("Use Backup Sample", mCausticReservoirsUseBackupSample);
                group2.tooltip("Uses a backup sample if no reservoir was reprojected into the current pixel");
            }

            if (mPhotonRenderMode == PhotonRenderMode::ReSTIR_PathPhoton)
            {
                if (group.checkbox("Retrace Light Paths (Photons)", mRetraceLightPaths))
                {
                    mCanResample = false;
                }
                group.tooltip(
                    "If enabled, the light paths (photons) are retraced each frame instead assuming that the photon did not move"
                );
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
        changed |= group.checkbox("Evaluate Delta PDFs", mEvalDeltaPdfs);
        group.tooltip("If checked, delta PDFs are evaluated (always 0), which will disable some resampling paths. If unchecked they are set to 1.");
    }

    if (auto group = widget.group("Debug"))
    {
        if(mEnableNRDOutputs)
            group.text("NRD Outputs Enabled");
        group.checkbox("Freeze Guiding Texture", mDebugFreezeGuidingTextures);
        group.checkbox("Show Guiding Texture", mDebugShowGuidingTexture);
        if (mDebugShowGuidingTexture)
        {
            std::string selectText = mUseDirectionAtlasOptimization ? "Show Directional Guiding Atlas" : "Show Light Index Select Guiding Tex";
            group.checkbox(selectText.c_str(), mDebugShowLightIndexGuidingTex);
            group.var("Selected Tri light", mDebugSelectedTriLight, -1, int(mTotalLightCount) - 1);
            group.var("Dir GM Scale", mDebugDirGMScaleFactor, 0.f, FLT_MAX, 0.01f, false, "%.6f");
            group.var("Light GM Scale", mDebugLightGMScaleFactor, 0.f, FLT_MAX, 0.01f, false, "%.6f");

            group.rgbColor("Color Directional GM", mDebugColorDirGM);
            group.rgbColor("Color Light GM", mDebugColorLightGM);

            group.checkbox("Show Selected Light", mDebugShowSelectedLight);
            group.tooltip("Shows the selected light in the Light GM");
            group.checkbox("Show Min Photon Light", mDebugShowMinPhotons);
            group.rgbColor("Show Color", mDebugColorExtra);

        }
        changed |= group.checkbox("Disable Direct Light", mDebugDisableDirectLight);
        changed |= group.checkbox("Disable Indirect Light", mDebugDisableIndirectLight);
        changed |= group.checkbox("ReSTIR FG+ Show Paths", mDebugPathRetracingShowPaths);
    }
    mOptionsChanged = changed;
}

void PhotonGuiding::prepareLightingStructure(RenderContext* pRenderContext, const RenderData& renderData)
{
    // Make sure that the emissive light is up to date
    auto& pLights = mpScene->getLightCollection(pRenderContext);

    bool emissiveUsed = mpScene->useEmissiveLights();
    bool analyticUsed = mpScene->useAnalyticLights();

    //mHasLights = analyticUsed || emissiveUsed;
    //mHasAnalyticLights = analyticUsed;
    //mMixedLights = emissiveUsed && analyticUsed;
    bool lightCountWasResetted = false;

    if (pLights->getTotalLightCount() != mEmissiveLightCount || mpScene->getLightCount() != mAnalyticLightCount)
    {
        mEmissiveLightCount = pLights->getTotalLightCount();
        mAnalyticLightCount = mpScene->getLightCount();
        mTotalLightCount = mEmissiveLightCount + mAnalyticLightCount;
        mpRecordLightIndexGuidingTexture.reset();
        for (uint i = 0; i < 2; i++) {
            mpGuidingAtlas[i].reset();
            mpGuidingAtlasPrevUnblurred[i].reset();
            mpLightIndexGuidingTexture[i].reset();
        }
        mpRecordGuidingAtlas.reset();
        resetRenderPasses();
        lightCountWasResetted = true;
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

    //EnvMap sampler
    if (is_set(mpScene->getUpdates(), Scene::UpdateFlags::EnvMapChanged))
    {
        mpEnvMapSampler = nullptr;
    }

    if (mpScene->useEnvLight())
    {
        if (!mpEnvMapSampler)
        {
            mpEnvMapSampler = std::make_unique<EnvMapSampler>(mpDevice, mpScene->getEnvMap());
        }
    }
    else
    {
        if (mpEnvMapSampler)
        {
            mpEnvMapSampler = nullptr;
            resetRenderPasses();
        }
    }

    //Update NEE selection probability
    mNeeLightSelectProb =
        float3(mpScene->useEmissiveLights() ? 1.f : 0.f, mpScene->useAnalyticLights() ? 1.f : 0.f, mpScene->useEnvLight() ? 1.f : 0.f);
    mNeeLightSelectProb /= mNeeLightSelectProb.x + mNeeLightSelectProb.y + mNeeLightSelectProb.z;

    //Enable Atlas Optimization if enough lights are in the scene
    if (lightCountWasResetted) {
        if (mEmissiveLightCount + mAnalyticLightCount > mAtlasOptimizationMaxDirectionGuidingMaps * 16) {
            mUseDirectionAtlasOptimization = true;
            mGuidingUseDistanceBasedMinPhoton = true;
        }

        //Check if NRD outputs are enabled
        if(renderData[kOutputNRDDiffuseRadiance] && renderData[kOutputNRDDiffuseReflectance]
            && renderData[kOutputNRDSpecularRadiance] && renderData[kOutputNRDSpecularReflectance])
            mEnableNRDOutputs = true;
    }
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
        mpPhotonDirSampleGen[0].reset();
        mpPhotonDirSampleGen[1].reset();
        mpPhotonAS.reset();
        mpLightTraceLinkedList.reset();
        mpCausticPhotonHitInfo.reset();
        mChangePhotonLightBufferSize = false;
        mResetClearResources = true;
    }

    if (mResetGuidingTextures)
    {
        for (uint i = 0; i < 2; i++) {
            mpGuidingAtlas[i].reset();
            mpGuidingAtlasPrevUnblurred[i].reset();
            mpLightIndexGuidingTexture[i].reset();
            mpMapLightIdxToGuidingDirection[i].reset();
        }
        mpRecordGuidingAtlas.reset();
        mpGuidingAtlasBlurHelper.reset();
        mpLightIndexGuidingPrevTex.reset();
        mpRecordLightIndexGuidingTexture.reset();
        mpMapGuidingDirectionToLightIndex.reset();
        mpReservedPhotonsPerLight.reset();
        mResetGuidingTextures = false;
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
                mpDevice, sizeof(float) * 12, mNumMaxPhotons[i], ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess,
                Buffer::CpuAccess::None, nullptr, false
            );
            mpPhotonData[i]->setName("PhotonData" + std::to_string(i));
        }

        if(!mpPhotonDirSampleGen[i])
        {
            mpPhotonDirSampleGen[i] = Buffer::createStructured(
                mpDevice, sizeof(uint), mNumMaxPhotons[i], ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess,
                Buffer::CpuAccess::None, nullptr, false
            );
            mpPhotonDirSampleGen[i]->setName("PhotonDirectionSampleGenerator" + std::to_string(i));
        }
    }

    //Prev VBuffer and View
    if (!mpVBufferPrev || mResetScreenTex)
    {
        auto vBuffer = renderData[kInputVBuffer]->asTexture();
        mpVBufferPrev = Texture::create2D(
            mpDevice, mScreenRes.x, mScreenRes.y, vBuffer->getFormat(), 1u, 1u, nullptr,
            ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess
        );
        mpVBufferPrev->setName("PreviousVBuffer");
    }

    if (!mpViewPrev || mResetScreenTex)
    {
        auto view = renderData[kInputView]->asTexture();
        mpViewPrev = Texture::create2D(
            mpDevice, mScreenRes.x, mScreenRes.y, view->getFormat(), 1u, 1u, nullptr,
            ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess
        );
        mpViewPrev->setName("PreviousView");
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
        uint numGuidingTextures = mUseDirectionAtlasOptimization ? mAtlasOptimizationMaxDirectionGuidingMaps : mTotalLightCount;
        //Update atlas size
        float minSideLength =
            math::ceil(math::sqrt(float(numGuidingTextures * mGuidingTextureResolution * mGuidingTextureResolution))); // ceiled pixel
                                                                                                                        // width/length
        mGuidingAtlasResolution = uint(pow(2.f, math::ceil(math::log2(minSideLength)))); // Gets next nearest power 2 number
        mGuidingAtlasMipLevels = uint(round(math::log2(float(mGuidingTextureResolution)))) + 1;

        for (uint i = 0; i < 2; i++)
        {
            mpGuidingAtlas[i] = Texture::create2D(
                mpDevice, mGuidingAtlasResolution, mGuidingAtlasResolution, ResourceFormat::R32Float, 1u, mGuidingAtlasMipLevels, nullptr,
                ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess | ResourceBindFlags::RenderTarget
            );
            mpGuidingAtlas[i]->setName("GuidingTextureAtlas" + std::to_string(i));        
        }
    }

    for (uint i = 0; i < 2; i++) {
        if (!mpGuidingAtlasPrevUnblurred[i])
        {
            mpGuidingAtlasPrevUnblurred[i] = Texture::create2D(
            mpDevice, mGuidingAtlasResolution, mGuidingAtlasResolution, ResourceFormat::R32Float, 1u, 1u,
                nullptr, ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess
            );
            mpGuidingAtlasPrevUnblurred[i]->setName("GuidingTextureAtlasNoBlur" + std::to_string(i));
        }
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

    //Mapping Resources
    for (uint i = 0; i < 2; i++) {
        if (!mpMapLightIdxToGuidingDirection[i]) {
            mpMapLightIdxToGuidingDirection[i] = Texture::create2D(mpDevice, mGuidingLightIndexSize, mGuidingLightIndexSize, ResourceFormat::R16Uint, 1u, 1u,
                nullptr, ResourceBindFlags::UnorderedAccess | ResourceBindFlags::ShaderResource);
            mpMapLightIdxToGuidingDirection[i]->setName("MapLightIdxToGuidingDirection" + std::to_string(i));
            pRenderContext->clearUAV(mpMapLightIdxToGuidingDirection[i]->getUAV(0).get(), uint4(0xFFFF));
        }
    }

    if (!mpMapGuidingDirectionToLightIndex) {
        ResourceFormat resourceFormat = mTotalLightCount > 0xFFFF ? ResourceFormat::R32Uint : ResourceFormat::R16Uint;
        mAtlasOptimizationMapSize = mGuidingAtlasResolution / mGuidingTextureResolution;
        mpMapGuidingDirectionToLightIndex = Texture::create2D(mpDevice, mAtlasOptimizationMapSize, mAtlasOptimizationMapSize, resourceFormat, 1u, 1u,
            nullptr, ResourceBindFlags::UnorderedAccess | ResourceBindFlags::ShaderResource);
        mpMapGuidingDirectionToLightIndex->setName("MapGuidingDirectionToLightIdx");
        uint clearValue = mTotalLightCount;
        pRenderContext->clearUAV(mpMapGuidingDirectionToLightIndex->getUAV(0).get(), uint4(clearValue));
    }

    if (!mpMapLightIdxToGuidingDirectionCounter) {
            mpMapLightIdxToGuidingDirectionCounter = Buffer::createStructured(mpDevice, sizeof(uint), 1 ,
                ResourceBindFlags::UnorderedAccess | ResourceBindFlags::ShaderResource, Buffer::CpuAccess::None, nullptr, false);
            mpMapLightIdxToGuidingDirectionCounter->setName("MapLightIdxToGuidingDirectionCounter");
        }

    if (!mpReservedPhotonsPerLight) {
        mpReservedPhotonsPerLight = Texture::create2D(mpDevice, mGuidingLightIndexSize, mGuidingLightIndexSize, ResourceFormat::R16Uint, 1u, 1u,
            nullptr, ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess);
        mpReservedPhotonsPerLight->setName("ReservedPhotonsPerLight");
    }

    if(!mpReservedPhotonsBuffer){
        mpReservedPhotonsBuffer = Buffer::createStructured(mpDevice, sizeof(int), 1, ResourceBindFlags::UnorderedAccess | ResourceBindFlags::ShaderResource,
            Buffer::CpuAccess::None, nullptr, false);
        mpReservedPhotonsBuffer->setName("GuidingReservedPhotons");
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
        if (!mpPathReservoir[i] || mResetScreenTex)
        {
            mCanResample = false;
            mpPathReservoir[i] = Buffer::createStructured(
                mpDevice, 28 * sizeof(uint), mScreenRes.x * mScreenRes.y,
                ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess, Buffer::CpuAccess::None, nullptr, false
            );
            mpPathReservoir[i]->setName("PathReservoir" + std::to_string(i));
        }

        if (!mpRetracedPath[i] || mResetScreenTex)
        {
            mCanResample = false;
            mpRetracedPath[i] = Texture::create2D(mpDevice, mScreenRes.x, mScreenRes.y, ResourceFormat::RGBA32Float, 1u, 1u,
                nullptr, ResourceBindFlags::UnorderedAccess | ResourceBindFlags::ShaderResource
            );
            mpRetracedPath[i]->setName("RetracePath" + std::to_string(i));
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
        mResetClearResources = true; //Just to be sure this is triggered
    }

    if (!mpSplattingSortingData || mResetScreenTex)
    {
        mpSplattingSortingData = Buffer::createStructured(
            mpDevice, sizeof(uint4), mScreenRes.x * mScreenRes.y, ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess,
            Buffer::CpuAccess::None, nullptr, false
        );
        mpSplattingSortingData->setName("SplattingSortingData");
    }

    if (!mpSplattingResamlingLinkedList || mResetScreenTex)
    {
        mpSplattingResamlingLinkedList = Buffer::createStructured(
            mpDevice, sizeof(uint), mScreenRes.x * mScreenRes.y, ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess,
            Buffer::CpuAccess::None, nullptr, false
        );
        mpSplattingResamlingLinkedList->setName("SplattingResamplingLinkedList");
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
        uint4 cellCounterClear = mSplattingResampleUseLinkedList ? uint4(uint(-1)) : uint4(0);
        pRenderContext->clearUAV(mpSplattingCellCounter->getUAV(0).get(), cellCounterClear);
        pRenderContext->clearUAV(mpSplattingResamlingLinkedList->getUAV(0).get(), uint4(-1));
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
    case Falcor::PhotonGuidingSharedEnums::GuidingMode::ReSTIRConfidence:
    case Falcor::PhotonGuidingSharedEnums::GuidingMode::ReSTIRReverseConfidence:
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
            if (mip == 0 && !mUseDirectionAtlasOptimization) {
                var["gSrc"].setSrv(mpRecordGuidingAtlas->getSRV(mGuidingAtlasMipLevels - 1u, 1u));
            }
            else {
                var["gSrc"].setSrv(mpRecordLightIndexGuidingTexture->getSRV(mip, 1u));
            }
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

    auto getRuntimeDefines = [&](){
        DefineList defines = {};
        defines.add("HISTORAM_ACCUM_MODE", std::to_string((uint)mGuidingHistogramAccumMode));
        defines.add("USE_ATLAS_OPTIMIZATION", mUseDirectionAtlasOptimization ? "1" : "0");

        return defines;
    };

    if (!mpGenerateGuidingMipTraverseChainPass)
    {
        Program::Desc desc;
        desc.addShaderLibrary(kShaderGuidingGenMipTraverseChain).csEntry("main").setShaderModel(kShaderModel);

        DefineList defines;
        defines.add("COUNT_TEXTURES", std::to_string(mTotalLightCount));
        defines.add("COUNTER_FORMAT", guidingIsUintFormat(mGuidingMode) ? "uint" : "float");
        defines.add("COUNT_LIGHTS", std::to_string(mTotalLightCount));
        defines.add("IS_LIGHT_INDEX_TEXTURE", "0");
        defines.add(getRuntimeDefines());

        mpGenerateGuidingMipTraverseChainPass = ComputePass::create(mpDevice, desc, defines, true);
    }

    //Runtime define
    mpGenerateGuidingMipTraverseChainPass->getProgram()->addDefines(getRuntimeDefines());

    auto var = mpGenerateGuidingMipTraverseChainPass->getRootVar();
    auto pCurrentGuidingTex = mpGuidingAtlas[mFrameCount % 2];

    //First pass to get the level 0 values from the counter and clear counter to 1
    {
        uint iterationCount = mGuidingMode == GuidingMode::Disabled ? 0 : mGuidingAccumulateCount;
        if (mGuidingHistogramAccumMode == GuidingHistogramAccumulateMode::AverageFrames)
            iterationCount = math::min(iterationCount, (uint)floor(mGuidingHistogramAccumValue));

        const uint maxMip = mGuidingAtlasMipLevels - 1;
        var["CB"]["gRes"] = mGuidingTextureResolution;
        var["CB"]["gCopyFromCounter"] = true;
        var["CB"]["gIterationCount"] = iterationCount;
        var["CB"]["gDispatchSize"] = mGuidingAtlasResolution;
        var["CB"]["gFixedGuidingCheckPhotonCount"] = false;
        var["CB"]["gAccumValue"] = mGuidingHistogramAccumValue;

        var["CB"]["gLightGMResolution"] = mGuidingLightIndexSize;
        var["CB"]["gGMResolution"] = mGuidingTextureResolution;
        var["CB"]["gMapResolution"] = mAtlasOptimizationMapSize;

        var["gSrcCounter"].setSrv(mpRecordGuidingAtlas->getSRV(0));
        var["gSrcCounterTotal"].setSrv(mpRecordGuidingAtlas->getSRV(maxMip, 1u));
        var["gWeightLastFrame"] = mUseDirectionAtlasOptimization ? mpGuidingAtlasPrevUnblurred[mFrameCount % 2] : mpGuidingAtlasPrevUnblurred[0];
        if(mUseDirectionAtlasOptimization)
            var["gWeightLastFramePingPongRead"] = mpGuidingAtlasPrevUnblurred[(mFrameCount + 1) % 2];
        var["gSrc"].setSrv(mpGuidingAtlas[(mFrameCount + 1) % 2]->getSRV(0,1u));
        var["gDst"].setUav(pCurrentGuidingTex->getUAV(0));

        var["gMapGuidingDirectionToLightIndex"] = mpMapGuidingDirectionToLightIndex;
        var["gMapLightIdxToDirGMPrev"] = mpMapLightIdxToGuidingDirection[(mFrameCount + 1)% 2];

        const uint maxYDispatch = getOptimizedAtlasYDispatch(mGuidingAtlasResolution, mGuidingTextureResolution, mTotalLightCount);

        mpGenerateGuidingMipTraverseChainPass->execute(pRenderContext, uint3(mGuidingAtlasResolution, maxYDispatch, 1)
        );

        if (guidingIsUintFormat(mGuidingMode)) {
            uint clearValue = mUseFixedGuidingDispatch ? 0 : 1;
            pRenderContext->clearUAV(mpRecordGuidingAtlas->getUAV(0).get(), uint4(clearValue));
        }            
        else {
            float clearValue = mUseFixedGuidingDispatch ? 0.f : mGuidingClearValueEmission;
            pRenderContext->clearUAV(mpRecordGuidingAtlas->getUAV(0).get(), float4(clearValue));
        }
            
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
    for (uint m = 1; m < mGuidingAtlasMipLevels; m++)
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

    //If Optimized dispatch is enabled clear the map to light index texture
    //TODO optimize and place in a shader?
    if (mAtlasOptimizationMaxDirectionGuidingMaps && isLightIndexPass) {
        pRenderContext->clearUAV(mpMapGuidingDirectionToLightIndex->getUAV(0).get(), uint4(mTotalLightCount));
        pRenderContext->uavBarrier(mpMapGuidingDirectionToLightIndex.get());
        pRenderContext->clearUAV(mpMapLightIdxToGuidingDirection[mFrameCount % 2]->getUAV(0).get(), uint4(0xFFFF));
        pRenderContext->uavBarrier(mpMapLightIdxToGuidingDirection[mFrameCount % 2].get());
        pRenderContext->clearUAV(mpMapLightIdxToGuidingDirectionCounter->getUAV(0).get(), uint4(0));
        pRenderContext->uavBarrier(mpMapLightIdxToGuidingDirectionCounter.get());
    }

    //Shared runtime defines
    auto getRuntimeDefine = [&]() {
        DefineList defines = {};
        defines.add("LIGHT_GUIDING_MIN_PHOTONS", std::to_string(mGuidingTextureResolution * mGuidingTextureResolution * mMinPhotonsPerGuidingTexel));
        defines.add("USE_ATLAS_OPTIMIZATION", mUseDirectionAtlasOptimization ? "1" : "0");
        defines.add("ATLAS_OPTIMIZATION_MAX_INDEX", std::to_string(mAtlasOptimizationMaxDirectionGuidingMaps));
        defines.add("ATLAS_OPTIMIZATION_MIN_PHOTONS_TO_CREATE", std::to_string(mGuidingTextureResolution * mGuidingTextureResolution * mAtlasOptiMinPhotonsPerTexelToCreate));
        defines.add("USE_DISTANCE_BASED_MIN_PHOTON", mGuidingUseDistanceBasedMinPhoton ? "1" : "0");
        return defines;
    };

    if (!mpMapGuidingToDistributedPhotonsPass[0] || !mpMapGuidingToDistributedPhotonsPass[1])
    {
        Program::Desc desc;
        desc.addShaderLibrary(kShaderMapGuidingToPhotons).csEntry("main").setShaderModel(kShaderModel);

        DefineList defines;
        defines.add("COUNT_LIGHTS", std::to_string(mTotalLightCount));
        defines.add("IS_LIGHT_PASS", "1");
        defines.add(getRuntimeDefine());
        mpMapGuidingToDistributedPhotonsPass[0] = ComputePass::create(mpDevice, desc, defines, true);

        defines.add("IS_LIGHT_PASS", "0");
        mpMapGuidingToDistributedPhotonsPass[1] = ComputePass::create(mpDevice, desc, defines, true);
    }
    FALCOR_ASSERT(mpMapGuidingToDistributedPhotonsPass[0] && mpMapGuidingToDistributedPhotonsPass[1]);
    mpMapGuidingToDistributedPhotonsPass[0]->getProgram()->addDefines(getRuntimeDefine());
    mpMapGuidingToDistributedPhotonsPass[1]->getProgram()->addDefines(getRuntimeDefine());


    auto& pCurrentAtlas = mpGuidingAtlas[mFrameCount % 2];
    auto& pCurrentIdxGuiding = mpLightIndexGuidingTexture[mFrameCount % 2];

    uint passIdx = isLightIndexPass ? 0 : 1;
    auto var = mpMapGuidingToDistributedPhotonsPass[passIdx]->getRootVar();

    //Get the number of photons that should be distributed
    uint distributedPhotons = static_cast<uint>(std::floor(sqrt(mNumDispatchedPhotons)));
    distributedPhotons *= distributedPhotons; //Dispatched photons, same as in tracePhoton pass
    if (isLightIndexPass && mGuidingUseDistanceBasedMinPhoton) {
        reservePhotonsPerLightSource(pRenderContext);
    }else{
        distributedPhotons = std::max(distributedPhotons, mFixedGuidingDispatchReservedPhotons * mTotalLightCount);
        distributedPhotons -= mFixedGuidingDispatchReservedPhotons * mTotalLightCount;
    }

    var["CB"]["gDistributedPhotons"] = distributedPhotons;
    var["CB"]["gGuidingTextureRes"] = mGuidingTextureResolution;
    var["CB"]["gLightIdxRes"] = mGuidingLightIndexSize;
    var["CB"]["gMinPhotonsPerLight"] = mGuidingUseDistanceBasedMinPhoton ? std::min(mGuidingDBMPMinMaxPhotons.x,mGuidingDBMPMinMaxPhotons.y) : mFixedGuidingDispatchReservedPhotons;
    var["CB"]["gMapTextureSize"] = mAtlasOptimizationMapSize;
    
    uint2 dispatchSize = uint2(0);
    if (isLightIndexPass)
    {
        dispatchSize = uint2(mGuidingLightIndexSize);

        var["gSrc"].setSrv(pCurrentAtlas->getSRV(0, 1));
        var["gDst"].setUav(pCurrentIdxGuiding->getUAV(0));

        var["gMapLightIdxToDirGM"] = mpMapLightIdxToGuidingDirection[mFrameCount % 2];
        var["gMapLightIdxToDirGMPrev"]  = mpMapLightIdxToGuidingDirection[(mFrameCount + 1) % 2];
        var["gMapDirToLightIndexRW"] = mpMapGuidingDirectionToLightIndex;
        var["gMapLightIdxToDirCounter"] = mpMapLightIdxToGuidingDirectionCounter;
        var["gReservedPhotonsPerLight"] = mpReservedPhotonsPerLight; //Only used if mGuidingUseDistanceBasedMinPhoton==true
        var["gReservedPhotons"] = mpReservedPhotonsBuffer;           //Only used if mGuidingUseDistanceBasedMinPhoton==true
    }
    else
    {
        const uint maxYDispatch = getOptimizedAtlasYDispatch(mGuidingAtlasResolution, mGuidingTextureResolution, mTotalLightCount);
        dispatchSize = mUseDirectionAtlasOptimization ? uint2(mGuidingAtlasResolution) : uint2(mGuidingAtlasResolution, maxYDispatch);

        var["gSrc"].setSrv(pCurrentIdxGuiding->getSRV(0,1));
        var["gDst"].setUav(pCurrentAtlas->getUAV(0));

        var["gMapDirToLightIndex"] = mpMapGuidingDirectionToLightIndex;                               
    }
    var["CB"]["gDispatchDim"] = dispatchSize;

    mpMapGuidingToDistributedPhotonsPass[passIdx]->execute(pRenderContext, uint3(dispatchSize, 1));

}

void PhotonGuiding::reservePhotonsPerLightSource(RenderContext* pRenderContext) {
    FALCOR_PROFILE(pRenderContext, "ReservePhotonsPerLight");

    pRenderContext->clearUAV(mpReservedPhotonsBuffer->getUAV().get(), uint4(0));
    pRenderContext->uavBarrier(mpReservedPhotonsBuffer.get());

    if (!mpGetFreePhotonsBasedOnDistPass)
    {
        Program::Desc desc;
        desc.addShaderModules(mpScene->getShaderModules());
        desc.addShaderLibrary(kShaderGetFreePhotonsBasedOnDist).csEntry("main").setShaderModel(kShaderModel);
        desc.addTypeConformances(mpScene->getTypeConformances());

        DefineList defines;
        defines.add("COUNT_LIGHTS", std::to_string(mTotalLightCount));
        defines.add("ANALYTIC_START_INDEX", std::to_string(mEmissiveLightCount));
        defines.add(mpScene->getSceneDefines());
        defines.add(mpSampleGenerator->getDefines());

        mpGetFreePhotonsBasedOnDistPass = ComputePass::create(mpDevice, desc, defines, true);
    }

     auto var = mpGetFreePhotonsBasedOnDistPass->getRootVar();
     mpScene->setRaytracingShaderData(pRenderContext, var);

    
     var["CB"]["gMinDist"] = std::min(mGuidingDBMPMinMaxDistance.x, mGuidingDBMPMinMaxDistance.y);
     var["CB"]["gMaxDist"] = std::max(mGuidingDBMPMinMaxDistance.x, mGuidingDBMPMinMaxDistance.y);
     var["CB"]["gMinPhotons"] = std::min(mGuidingDBMPMinMaxPhotons.x, mGuidingDBMPMinMaxPhotons.y);
     var["CB"]["gMaxPhotons"] = std::max(mGuidingDBMPMinMaxPhotons.x, mGuidingDBMPMinMaxPhotons.y);
     var["CB"]["gLightGMSize"] = mGuidingLightIndexSize;
     
     var["gReservedPhotonsPerLight"] = mpReservedPhotonsPerLight;
     var["gReservedPhotons"] = mpReservedPhotonsBuffer;

     mpGetFreePhotonsBasedOnDistPass->execute(pRenderContext, uint3(mGuidingLightIndexSize, mGuidingLightIndexSize, 1));
}

void PhotonGuiding::generateLightIndexGuidingMipTraverseChainPass(RenderContext* pRenderContext, const RenderData& renderData) {
    FALCOR_PROFILE(pRenderContext, "LightIndexGuidingTraverseChain");

    auto getRuntimeDefines = [&]() {
        DefineList defines;
        defines.add("HISTORAM_ACCUM_MODE", std::to_string((uint)mGuidingHistogramAccumMode));
        return defines;
    };

    if (!mpGenerateLightIndexGuidingMipTraverseChainPass)
    {
        Program::Desc desc;
        desc.addShaderLibrary(kShaderGuidingGenMipTraverseChain).csEntry("main").setShaderModel(kShaderModel);

        DefineList defines;
        defines.add("COUNT_TEXTURES", "1");
        defines.add("COUNTER_FORMAT", "uint");
        defines.add("COUNT_LIGHTS", std::to_string(mTotalLightCount));
        defines.add("IS_LIGHT_INDEX_TEXTURE", "1");
        defines.add(getRuntimeDefines());

        mpGenerateLightIndexGuidingMipTraverseChainPass = ComputePass::create(mpDevice, desc, defines, true);
    }

    // Update Runtime define
    mpGenerateLightIndexGuidingMipTraverseChainPass->getProgram()->addDefines(getRuntimeDefines());

    auto var = mpGenerateLightIndexGuidingMipTraverseChainPass->getRootVar();
    auto pCurrLightGuidingTex = mpLightIndexGuidingTexture[mFrameCount % 2];

    // First pass to get the level 0 values from the counter and clear counter to 1
    {
       uint iterationCount = mGuidingMode == GuidingMode::Disabled ? 0 : mGuidingAccumulateCount; 
       if (mGuidingHistogramAccumMode == GuidingHistogramAccumulateMode::AverageFrames)
            iterationCount = math::min(iterationCount, (uint)floor(mGuidingHistogramAccumValue));

        const uint maxMip = mpRecordLightIndexGuidingTexture->getMipCount() - 1u;
        var["CB"]["gRes"] = mGuidingLightIndexSize;
        var["CB"]["gCopyFromCounter"] = true;
        var["CB"]["gIterationCount"] = iterationCount;
        var["CB"]["gDispatchSize"] = mGuidingLightIndexSize;
        var["CB"]["gAccumValue"] = mGuidingHistogramAccumValue;

        if(mUseDirectionAtlasOptimization)
            var["gSrcCounter"].setSrv(mpRecordLightIndexGuidingTexture->getSRV(0));
        else
            var["gSrcCounter"].setSrv(mpRecordGuidingAtlas->getSRV(mGuidingAtlasMipLevels - 1u));
        var["gSrcCounterTotal"].setSrv(mpRecordLightIndexGuidingTexture->getSRV(maxMip, 1u));
        var["gSrc"].setSrv(mpLightIndexGuidingTexture[(mFrameCount + 1) % 2]->getSRV(0, 1u));
        var["gDst"].setUav(pCurrLightGuidingTex->getUAV(0));
        var["gWeightLastFrame"] = mpLightIndexGuidingPrevTex;

        mpGenerateLightIndexGuidingMipTraverseChainPass->execute(
            pRenderContext, uint3(mGuidingLightIndexSize, mGuidingLightIndexSize, 1)
        );

        if (mUseDirectionAtlasOptimization) {
            uint clearValue = mUseFixedGuidingDispatch ? 0 : 1;
            pRenderContext->clearUAV(mpRecordLightIndexGuidingTexture->getUAV(0).get(), uint4(clearValue));
        }
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
        defines.add(mpScene->getSceneDefines());

        mTracePhotonPass.pProgram = RtProgram::create(mpDevice, desc, defines);
    }
    // Defines
    mTracePhotonPass.pProgram->addDefine("USE_EMISSIVE_LIGHT", mpScene->useEmissiveLights() ? "1" : "0");
    mTracePhotonPass.pProgram->addDefine("PHOTON_BUFFER_SIZE_GLOBAL", std::to_string(mNumMaxPhotons[0]));
    mTracePhotonPass.pProgram->addDefine("PHOTON_BUFFER_SIZE_CAUSTIC", std::to_string(mNumMaxPhotons[1]));
    mTracePhotonPass.pProgram->addDefine("ROUGHNESS_THRESHOLD", std::to_string(mSpecularRoughnessThreshold));
    mTracePhotonPass.pProgram->addDefine("DiffuseBrdf", mUseLambertianDiffuse ? "DiffuseBrdfLambert" : "DiffuseBrdfFrostbite");
    mTracePhotonPass.pProgram->addDefine("RUSSIAN_ROULETTE", mPhotonRussianRoulette ? "1" : "0");
    mTracePhotonPass.pProgram->addDefine("USE_ADAPTIVE_PHOTON_RADIUS", mUseAdaptivePhotonRadius ? "1" : "0");
    mTracePhotonPass.pProgram->addDefine("ENABLE_LIGHT_TRACE_SPATTING", mEnableLightTraceSplatting ? "1" : "0");
    mTracePhotonPass.pProgram->addDefine("USE_FIXED_PHOTON_GUIDING", mUseFixedGuidingDispatch ? "1" : "0");
    mTracePhotonPass.pProgram->addDefine("FIXED_GUIDING_MIN_PHOTONS", std::to_string(mGuidingTextureResolution * mGuidingTextureResolution * mMinPhotonsPerGuidingTexel));
    mTracePhotonPass.pProgram->addDefine("ANALYTIC_START_INDEX", std::to_string(mEmissiveLightCount));
    mTracePhotonPass.pProgram->addDefine("TOTAL_LIGHT_COUNT", std::to_string(mTotalLightCount));
    mTracePhotonPass.pProgram->addDefine("RNG_NUM_PASSES", std::to_string(mRNGNumPasses));
    mTracePhotonPass.pProgram->addDefine("USE_JACOBIAN_DISTANCE_THRESHOLD_TO_MARK_AS_CAUSTIC", mPhotonRenderMode == PhotonRenderMode::ReSTIR_PathPhoton ? "1" : "0");
    mTracePhotonPass.pProgram->addDefine("USE_SEPERATE_DIR_SG", mRetraceLightPaths && mPhotonRenderMode == PhotonRenderMode::ReSTIR_PathPhoton ? "1" : "0");
    mTracePhotonPass.pProgram->addDefine("STORE_ONLY_INDIRECT_PHOTONS", mUseNEEatFGPoint ? "1" : "0");
    mTracePhotonPass.pProgram->addDefine("USE_OPTIMIZED_ATLAS", mUseDirectionAtlasOptimization ? "1" : "0");
    mTracePhotonPass.pProgram->addDefine("LIGHT_GUIDING_MAP_MIPLEVEL", std::to_string(mpLightIndexGuidingTexture[0]->getMipCount() - 1u));
    mTracePhotonPass.pProgram->addDefine("DIRECTION_GUIDING_MAP_MIPLEVEL", std::to_string(mGuidingAtlasMipLevels - 1));
    mTracePhotonPass.pProgram->addDefine("DISABLE_GUIDING", mGuidingMode == GuidingMode::Disabled ? "1" : "0");

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
    var["CB"]["gPackedPathLength"] = mPhotonPathLength.pack();
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
    var["CB"]["gJacobianDistanceThreshold"] = mResampleSettingsFG.jacobianDistanceThreshold;
    var["CB"]["gLightIndexGuidingMaxMip2"] = mpLightIndexGuidingTexture[mFrameCount % 2]->getMipCount() - 1u;
    var["CB"]["gMapTextureResolution"] = mAtlasOptimizationMapSize;

    // Output
    for (uint i = 0; i < 2; i++)
    {
        var["gPhotonAABB"][i] = mpPhotonAABB[i];
        var["gPhotonData"][i] = mpPhotonData[i];
        var["gPhotonDirSG"][i] = mpPhotonDirSampleGen[i];
    }

    var["gGuidingTexture"] = mpGuidingAtlas[mFrameCount % 2];
    var["gGuidingLightIndex"] = mpLightIndexGuidingTexture[mFrameCount % 2];
    var["gMapLightIndexToGuidingDirection"] = mpMapLightIdxToGuidingDirection[mFrameCount % 2];

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

DefineList PhotonGuiding::getPhotonCollectDefines(bool isReSTIRPass) {
    DefineList defines = {};
    defines.add("GUIDING_MODE", std::to_string((uint)mGuidingMode));
    defines.add("GUIDING_LIGHT_INDEX_SIZE", std::to_string(mGuidingLightIndexSize));
    defines.add("GUIDING_DISCRETIZED_EMISSION_FACTOR", std::to_string(mGuidingDiscretizedEmissionFactor));
    defines.add("GUIDING_DISCRETIZED_EMISSION_MAX", std::to_string(mGuidingDiscretizedEmissionMax));
    defines.add("NOT_RESTIR_PASS", isReSTIRPass ? "0" : "1");
    defines.add("ENABLE_PHOTON_RETRACING", mRetraceLightPaths ? "1" : "0");
    defines.add("USE_OPTIMIZED_ATLAS", mUseDirectionAtlasOptimization ? "1" : "0");
    return defines;
}

void PhotonGuiding::bindCollectPhotonData(ShaderVar& var) {
    mpPhotonAS->bindTlas(var, "gPhotonAS");
    for (uint i = 0; i < 2; i++)
    {
        var["gPhotonAABB"][i] = mpPhotonAABB[i];
        var["gPhotonData"][i] = mpPhotonData[i];
        var["gPhotonDirSGPackedPixel"][i] = mpPhotonDirSampleGen[i];
    }
    var["gGuidingCounter"] = mpRecordGuidingAtlas;
    var["gLightIndexGuidingCounter"] = mpRecordLightIndexGuidingTexture;
    var["gMapLightIndexToGuidingDirection"] = mpMapLightIdxToGuidingDirection[mFrameCount % 2];

    var["PhotonHelperCB"]["gLightIndexGuidingResolution"] = mGuidingLightIndexSize;
    var["PhotonHelperCB"]["gGuidingTextureResolution"] = mGuidingTextureResolution;
    var["PhotonHelperCB"]["gMapTextureResolution"] = mAtlasOptimizationMapSize;
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
    mTraceCameraPass.pProgram->addDefine("USE_ENV_LIGHT", mpScene->useEnvLight() ? "1" : "0");
    mTraceCameraPass.pProgram->addDefine("ROUGHNESS_THRESHOLD", std::to_string(mSpecularRoughnessThreshold));
    mTraceCameraPass.pProgram->addDefine("DiffuseBrdf", mUseLambertianDiffuse ? "DiffuseBrdfLambert" : "DiffuseBrdfFrostbite");
    mTraceCameraPass.pProgram->addDefine("RENDER_TECHNIQUE", std::to_string((uint)mPhotonRenderMode));
    mTraceCameraPass.pProgram->addDefine("RNG_NUM_PASSES", std::to_string(mRNGNumPasses));
    mTraceCameraPass.pProgram->addDefines(getPhotonCollectDefines(false));
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
    if(mpEnvMapSampler)
        mpEnvMapSampler->setShaderData(var["Light"]["gEnvMapSampler"]);

    // Constant Buffer
    var["CB"]["gFrameCount"] = mFrameCount;
    var["CB"]["gMaxBounces"] = mPTMaxBounces;
    var["CB"]["gNumLightPaths"] = mNumberLightPaths;
    var["CB"]["gLightIndexGuidingResolution"] = mGuidingLightIndexSize;
    var["CB"]["gLightTypeSelectProbability"] = mNeeLightSelectProb;

    // Input
    var["gVBuffer"] = renderData[kInputVBuffer]->asTexture();
    var["gView"] = renderData[kInputView]->asTexture();

    // Photon Data
    bindCollectPhotonData(var);

    var["gOutColor"] = renderData[kOutputColor]->asTexture();

    // Dispatch Shader
    mpScene->raytrace(pRenderContext, mTraceCameraPass.pProgram.get(), mTraceCameraPass.pVars, uint3(mScreenRes, 1));
}

void PhotonGuiding::debugPass(RenderContext* pRenderContext, const RenderData& renderData)
{
    FALCOR_PROFILE(pRenderContext, "Debug");

    auto getRuntimeDefines = [&](){
        DefineList defines;
        defines.add("USE_OPTIMIZED_ATLAS", mUseDirectionAtlasOptimization ? "1" : "0");
        return defines;
    };

    if (!mpDebugPass)
    {
        Program::Desc desc;
        desc.addShaderLibrary(kShaderDebug).csEntry("main").setShaderModel(kShaderModel);

        DefineList defines;
        defines.add("COUNT_TEXTURES", std::to_string(mTotalLightCount));
        defines.add(getRuntimeDefines());

        mpDebugPass = ComputePass::create(mpDevice, desc, defines, true);
    }

    mpDebugPass->getProgram()->addDefines(getRuntimeDefines()); //Update Runtime defines

    auto var = mpDebugPass->getRootVar();

    uint3 dispatchDim = uint3(renderData.getDefaultTextureDims().xy(), 1);
    //Determine color scales
    float atlasColorScale = mDebugDirGMScaleFactor * mGuidingTextureResolution * mGuidingTextureResolution;
    if (mUseFixedGuidingDispatch)
        atlasColorScale /= mNumDispatchedPhotons;
    float lightIdxColorScale = mDebugLightGMScaleFactor;
    if (mUseFixedGuidingDispatch) {
        lightIdxColorScale /= mUseDirectionAtlasOptimization ?
            mAtlasOptiMinPhotonsPerTexelToCreate * mGuidingTextureResolution * mGuidingTextureResolution
            : mMinPhotonsPerGuidingTexel * mGuidingTextureResolution * mGuidingTextureResolution;
    }

    var["CB"]["gDirGMScaleFactor"] = atlasColorScale;
    var["CB"]["gGuidingAtlasSize"] = mGuidingAtlasResolution;
    var["CB"]["gDispatchSize"] = dispatchDim.xy();
    var["CB"]["gLightIndex"] = mDebugSelectedTriLight;
    var["CB"]["gGuidingTextureSize"] = mGuidingTextureResolution;
    var["CB"]["gShowLightIndexGuiding"] = mDebugShowLightIndexGuidingTex;
    var["CB"]["gLightIndexGuidingSize"] = mGuidingLightIndexSize;
    var["CB"]["gLightIndexGuidingScale"] = lightIdxColorScale;
    var["CB"]["gIsFixedGuidingMode"] = mUseFixedGuidingDispatch;
    var["CB"]["gMapTextureResolution"] = mAtlasOptimizationMapSize;
    var["CB"]["gColorDirGM"] = mDebugColorDirGM;
    var["CB"]["gShowSelectLight"] = mDebugShowSelectedLight;
    var["CB"]["gColorLightGM"] = mDebugColorLightGM;
    var["CB"]["gShowMinPhoton"] = mDebugShowMinPhotons;
    var["CB"]["gColorExtra"] = mDebugColorExtra;
    var["CB"]["gMinPhotonsPerLight"] = float(mFixedGuidingDispatchReservedPhotons);
      
    var["gGuidingTexture"] = mpGuidingAtlas[mFrameCount % 2];
    var["gLightIndexGuidingTexture"] = mpLightIndexGuidingTexture[mFrameCount % 2];
    var["gMapLightIdxToDirGM"] = mpMapLightIdxToGuidingDirection[mFrameCount % 2];
    
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
    mpMapGuidingToDistributedPhotonsPass[0].reset();
    mpMapGuidingToDistributedPhotonsPass[1].reset();
    mpGetFreePhotonsBasedOnDistPass.reset();
    mpDebugPass.reset();

    mGenerateInitialSamplesPass.reset();
    mpResampleReservoirCausticPass.reset();
    mpResampleReservoirFGPass.reset();
    mpEvaluateReservoirsPass.reset();
    mpSplatSortCellData.reset();
    mpSplatSortComputeCellOffsets.reset();
    mpTemporalSplatReservoirs.reset();

    mResetClearResources = true;
    mResetGuidingTextures = true;
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
    mGenerateInitialSamplesPass.pProgram->addDefine("USE_ENV_BACKGROUND", mpScene->useEnvBackground() ? "1" : "0");
    mGenerateInitialSamplesPass.pProgram->addDefine("ROUGHNESS_THRESHOLD", std::to_string(mSpecularRoughnessThreshold));
    mGenerateInitialSamplesPass.pProgram->addDefine("ENABLE_LIGHT_TRACE_SPATTING", mEnableLightTraceSplatting ? "1" : "0");
    mGenerateInitialSamplesPass.pProgram->addDefine(
        "ENABLE_RANDOM_REPLAY", mPhotonRenderMode == Falcor::PhotonGuidingSharedEnums::PhotonRenderMode::ReSTIR_PathPhoton ? "1" : "0"
    );
    mGenerateInitialSamplesPass.pProgram->addDefine("RNG_NUM_PASSES", std::to_string(mRNGNumPasses));
    mGenerateInitialSamplesPass.pProgram->addDefine("EVAL_DELTA_PDFS", mEvalDeltaPdfs ? "1" : "0");
    mGenerateInitialSamplesPass.pProgram->addDefine("USE_ENV_LIGHT", mpScene->useEnvLight() ? "1" : "0");
    mGenerateInitialSamplesPass.pProgram->addDefine("PATH_RESERVOIR_USE_NEE", mPathResamplingUseNEEAfterSpecular ? "1" : "0");
    mGenerateInitialSamplesPass.pProgram->addDefine("PATH_RESERVOIR_STOP_PATH_AFTER_DIFFUSE_SPECULAR", mPathResamplingStopAfterDiffuseSpecular ? "1" : "0");
    mGenerateInitialSamplesPass.pProgram->addDefine("USE_NEE_AT_FG_HIT", mUseNEEatFGPoint ? "1" : "0");
    mGenerateInitialSamplesPass.pProgram->addDefine("DiffuseBrdf", mUseLambertianDiffuse ? "DiffuseBrdfLambert" : "DiffuseBrdfFrostbite");
    mGenerateInitialSamplesPass.pProgram->addDefines(getPhotonCollectDefines());

    if (mpEmissiveLightSampler)
        mGenerateInitialSamplesPass.pProgram->addDefines(mpEmissiveLightSampler->getDefines());

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
    var["CB"]["gJacobianDistanceThreshold"] = mResampleSettingsFG.jacobianDistanceThreshold;
    var["CB"]["gNeeLightSelectProb"] = mNeeLightSelectProb;

    // RTXDI Resources
    mpRTXDI->setShaderData(var);

    // NEE Structures for Path Resampling 
    if (mpEmissiveLightSampler)
        mpEmissiveLightSampler->setShaderData(var["Light"]["gEmissiveSampler"]);
    if (mpEnvMapSampler)
        mpEnvMapSampler->setShaderData(var["Light"]["gEnvMapSampler"]);

    // Input Resources
    bindCollectPhotonData(var);
    var["gVBuffer"] = renderData[kInputVBuffer]->asTexture();
    var["gLightTraceHeadCounter"] = mpLightTraceHeadCounter;
    var["gLightTraceLinkedList"] = mpLightTraceLinkedList;
    var["gCausticPhotonHitInfo"] = mpCausticPhotonHitInfo;
   
    // Output Resources
    var["gFinalGatherReservoir"] = mpFinalGatherReservoir[mFrameCount % 2];
    var["gPathReservoir"] = mpPathReservoir[mFrameCount % 2];
    var["gCausticReservoir"] = mpCausticReservoir[mFrameCount % 2];
    var["gEmission"] = mpEmission;

    // Dispatch Shader
    mpScene->raytrace(pRenderContext, mGenerateInitialSamplesPass.pProgram.get(), mGenerateInitialSamplesPass.pVars, uint3(mScreenRes, 1));

    // Reservoir barrier
    pRenderContext->uavBarrier(mpFinalGatherReservoir[mFrameCount % 2].get());
    pRenderContext->uavBarrier(mpCausticReservoir[mFrameCount % 2].get());

}

void PhotonGuiding::reSTIRResampleFGPass(RenderContext* pRenderContext, const RenderData& renderData)
{
    FALCOR_PROFILE(pRenderContext, "Resampling Final Gather");

    auto getRuntimeDefines = [&]() {
        DefineList defines;
        defines.add("USE_ENV_BACKROUND", mpScene->useEnvBackground() ? "1" : "0");
        defines.add(mpRTXDI->getDefines());
        defines.add("RNG_NUM_PASSES", std::to_string(mRNGNumPasses));
        defines.add("DiffuseBrdf", mUseLambertianDiffuse ? "DiffuseBrdfLambert" : "DiffuseBrdfFrostbite");
        return defines;
    };

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
        defines.add(getRuntimeDefines());

        mpResampleReservoirFGPass = ComputePass::create(mpDevice, desc, defines, true);
    }
    FALCOR_ASSERT(mpResampleReservoirFGPass);

    //Runtime defines
    mpResampleReservoirFGPass->getProgram()->addDefines(getRuntimeDefines());

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

    // Input Resources
    var["gFinalGatherReservoirPrev"] = mpFinalGatherReservoir[(mFrameCount + 1) % 2];
    var["gMVec"] = renderData[kInputMVec]->asTexture();

    // In-/Output Resources
    var["gFinalGatherReservoir"] = mpFinalGatherReservoir[mFrameCount % 2];

    // Execute Compute Pass
    const uint2 targetDim = renderData.getDefaultTextureDims();
    FALCOR_ASSERT(targetDim.x > 0 && targetDim.y > 0);
    mpResampleReservoirFGPass->execute(pRenderContext, uint3(targetDim, 1));
}

void PhotonGuiding::reSTIRRetracePathsPass(RenderContext* pRenderContext, const RenderData& renderData, uint numPass)
{
    std::string profileName = "RetracePaths" + std::to_string(numPass);
    FALCOR_PROFILE(pRenderContext, profileName);

    // Init Shader
    if (!mRetracePathsPass.pProgram)
    {
        RtProgram::Desc desc;
        desc.addShaderModules(mpScene->getShaderModules());
        desc.addShaderLibrary(kShaderReSTIRRetracePath);
        desc.setMaxPayloadSize(sizeof(float) * 4);
        desc.setMaxAttributeSize(mpScene->getRaytracingMaxAttributeSize());
        desc.setMaxTraceRecursionDepth(1);
        if (!mpScene->hasProceduralGeometry())
            desc.setPipelineFlags(RtPipelineFlags::SkipProceduralPrimitives);

        mRetracePathsPass.pBindingTable = RtBindingTable::create(1, 1, mpScene->getGeometryCount());
        auto& sbt = mRetracePathsPass.pBindingTable;
        sbt->setRayGen(desc.addRayGen("rayGen", mpScene->getTypeConformances()));
        sbt->setMiss(0, desc.addMiss("miss"));

        if (mpScene->hasGeometryType(Scene::GeometryType::TriangleMesh))
        {
            sbt->setHitGroup(0, mpScene->getGeometryIDs(Scene::GeometryType::TriangleMesh), desc.addHitGroup("closestHit", "anyHit"));
        }

        mRetracePathsPass.pProgram = RtProgram::create(mpDevice, desc, mpScene->getSceneDefines());
    }

    // Defines that can change on runtime
    mRetracePathsPass.pProgram->addDefine("ROUGHNESS_THRESHOLD", std::to_string(mSpecularRoughnessThreshold));
    mRetracePathsPass.pProgram->addDefine("EVAL_DELTA_PDFS", mEvalDeltaPdfs ? "1" : "0");
    mRetracePathsPass.pProgram->addDefine("USE_ENV_BACKGROUND", mpScene->useEnvBackground() ? "1" : "0");
    mRetracePathsPass.pProgram->addDefine("RNG_NUM_PASSES", std::to_string(mRNGNumPasses));
    mRetracePathsPass.pProgram->addDefine("GUIDING_MODE", std::to_string((uint)mGuidingMode));
    mRetracePathsPass.pProgram->addDefine("USE_ENV_LIGHT", mpScene->useEnvLight() ? "1" : "0");
    mRetracePathsPass.pProgram->addDefine("ANALYTIC_START_INDEX", std::to_string(mEmissiveLightCount));
    mRetracePathsPass.pProgram->addDefine("USE_LIGHT_PATH_RETRACING", mRetraceLightPaths ? "1" : "0");
    mRetracePathsPass.pProgram->addDefine("PHOTON_RUSSIAN_ROULETTE", mPhotonRussianRoulette ? "1" : "0");
    mRetracePathsPass.pProgram->addDefine("DiffuseBrdf", mUseLambertianDiffuse ? "DiffuseBrdfLambert" : "DiffuseBrdfFrostbite");
    if(mpEmissiveLightSampler)
        mRetracePathsPass.pProgram->addDefines(mpEmissiveLightSampler->getDefines());

    // Program Vars
    if (!mRetracePathsPass.pVars)
        mRetracePathsPass.initProgramVars(mpDevice, mpScene, mpSampleGenerator);
    FALCOR_ASSERT(mRetracePathsPass.pVars);

    if (!mCanResample || !mResampleSettingsFG.enable)
        return;

    auto var = mRetracePathsPass.pVars->getRootVar();

    //Bind NEE structures
    if(mpEmissiveLightSampler)
        mpEmissiveLightSampler->setShaderData(var["Light"]["gEmissiveSampler"]);
    if(mpEnvMapSampler)
        mpEnvMapSampler->setShaderData(var["Light"]["gEnvMapSampler"]);

    // Constant Buffer
    var["CB"]["gFrameCount"] = mFrameCount;
    var["CB"]["gFGRayMaxPathLength"] = mPTMaxBounces;
    var["CB"]["gNumResamplingPass"] = numPass; // Current path iteration starting from 0 (temporal)
    var["CB"]["gSpatialSampleRadius"] = mResampleSettingsFG.samplingRadius;
    var["CB"]["gJacobianDistanceThreshold"] = mResampleSettingsFG.jacobianDistanceThreshold;
    var["CB"]["gNeeLightSelectProb"] = mNeeLightSelectProb;
    var["CB"]["gGuidingTextureResolution"] = mGuidingTextureResolution;

    // Input Resources
    var["gVBuffer"] = renderData[kInputVBuffer]->asTexture();
    var["gView"] = renderData[kInputView]->asTexture();
    var["gMVec"] = renderData[kInputMVec]->asTexture();
    var["gVBufferPrev"] = mpVBufferPrev;
    var["gViewPrev"] = mpViewPrev;

    var["gPathReservoir"] = mpPathReservoir[mFrameCount % 2];
    var["gPathReservoirPrev"] = mpPathReservoir[(mFrameCount + 1) % 2];

    // Output Resources
    var["gRetraceReservoirPath"] = mpRetracedPath[0];
    var["gRetraceReservoirPathPrev"] = mpRetracedPath[1];

    // Dispatch Shaders
    if (mRetraceLightPaths && numPass == 0) {
        var["CB"]["gSeperatePasses"] = 2;

        mpScene->raytrace(pRenderContext, mRetracePathsPass.pProgram.get(), mRetracePathsPass.pVars, uint3(mScreenRes, 1));
        pRenderContext->uavBarrier(mpPathReservoir[(mFrameCount + 1) % 2].get());
        pRenderContext->uavBarrier(mpRetracedPath[0].get());
    }

    int numDispatches = mPathRetraceSeperatePass ? 2 : 1;
    for (int i = 0; i < numDispatches; i++) {

        var["CB"]["gSeperatePasses"] = mPathRetraceSeperatePass ? i : -1;

        mpScene->raytrace(pRenderContext, mRetracePathsPass.pProgram.get(), mRetracePathsPass.pVars, uint3(mScreenRes, 1));
    }
    
}

void PhotonGuiding::reSTIRResamplePathsPass(RenderContext* pRenderContext, const RenderData& renderData, uint numPass)
{
    std::string profilerName = "ResamplePaths" + std::to_string(numPass);
    FALCOR_PROFILE(pRenderContext, profilerName);

    auto getRuntimeDefines = [&](){
        DefineList defines;
        defines.add("USE_ENV_BACKROUND", mpScene->useEnvBackground() ? "1" : "0");
        defines.add("RNG_NUM_PASSES", std::to_string(mRNGNumPasses));
        defines.add("RETRACE_LIGHT_PATHS", mRetraceLightPaths ? "1" : "0");
        defines.add("DiffuseBrdf", mUseLambertianDiffuse ? "DiffuseBrdfLambert" : "DiffuseBrdfFrostbite");
        return defines;
    };

    // Initialize compute pass
    if (!mpResampleReservoirPathPass)
    {
        Program::Desc desc;
        desc.addShaderModules(mpScene->getShaderModules());
        desc.addShaderLibrary(kShaderReSTIRResamplePath).csEntry("main").setShaderModel(kShaderModel);
        desc.addTypeConformances(mpScene->getTypeConformances());

        DefineList defines;
        defines.add(mpScene->getSceneDefines());
        defines.add(mpSampleGenerator->getDefines());
        defines.add(getRuntimeDefines());

        mpResampleReservoirPathPass = ComputePass::create(mpDevice, desc, defines, true);
    }
    FALCOR_ASSERT(mpResampleReservoirPathPass);
    mpResampleReservoirPathPass->getProgram()->addDefines(getRuntimeDefines());                       // Runtime define

    // Return early if there is no previous reservoir or resampling is disabled
    if ((!mCanResample) || !mResampleSettingsFG.enable)
    {
        return;
    }

    // Set variables
    auto var = mpResampleReservoirPathPass->getRootVar();
    mpScene->setRaytracingShaderData(pRenderContext, var); // Set scene data
    mpSampleGenerator->setShaderData(var);                 // Sample generator

    // Constant Buffer
    var["CB"]["gFrameCount"] = mFrameCount;
    var["CB"]["gFrameDim"] = mScreenRes;
    var["CB"]["gConfidenceLimit"] = mResampleSettingsFG.confidenceCap;
    var["CB"]["gSpatialRadius"] = mResampleSettingsFG.samplingRadius;
    var["CB"]["gSpatialSamples"] = mResampleSettingsFG.spatialSamples;
    var["CB"]["gNormalThreshold"] = mResampleSettingsFG.usePathThreshold;
    var["CB"]["gRelativeDepthThreshold"] = mResampleSettingsFG.relativeDepthThreshold;
    var["CB"]["gUsePathThreshold"] = mResampleSettingsFG.usePathThreshold;
    var["CB"]["gNumResamplingPass"] = numPass;
    var["CB"]["gJacobianDistanceThreshold"] = mResampleSettingsFG.jacobianDistanceThreshold;
  
    // Input Resources
    var["gVBuffer"] = renderData[kInputVBuffer]->asTexture();
    var["gVBufferPrev"] = mpVBufferPrev;
    var["gView"] = renderData[kInputView]->asTexture();
    var["gViewPrev"] = mpViewPrev;
    var["gMVec"] = renderData[kInputMVec]->asTexture();
    var["gPathReservoirPrev"] = mpPathReservoir[(mFrameCount + 1) % 2];
    var["gRetracedPath"] = mpRetracedPath[0];
    var["gRetracedPathPrev"] = mpRetracedPath[1];

    // In-/Output Resources
    var["gPathReservoir"] = mpPathReservoir[mFrameCount % 2];

    // Execute Compute Pass
    const uint2 targetDim = renderData.getDefaultTextureDims();
    FALCOR_ASSERT(targetDim.x > 0 && targetDim.y > 0);
    mpResampleReservoirPathPass->execute(pRenderContext, uint3(targetDim, 1));
}

void PhotonGuiding::reSTIRResampleCausticPass(RenderContext* pRenderContext, const RenderData& renderData)
{
    FALCOR_PROFILE(pRenderContext, "Resampling Caustics");

    auto getRuntimeDefines = [&]() {
        DefineList defines;
        defines.add("USE_ADAPTIVE_PHOTON_RADIUS", mUseAdaptivePhotonRadius ? "1" : "0");
        defines.add("ENABLE_LIGHT_TRACE_SPATTING", mEnableLightTraceSplatting ? "1" : "0");
        defines.add("RNG_NUM_PASSES", std::to_string(mRNGNumPasses));
        defines.add("USE_BACKUP_SAMPLE", mCausticReservoirsUseBackupSample ? "1" : "0");
        defines.add("SPLATTING_USE_LINKED_LIST", mSplattingResampleUseLinkedList ? "1" : "0");
        defines.add("DiffuseBrdf", mUseLambertianDiffuse ? "DiffuseBrdfLambert" : "DiffuseBrdfFrostbite");
        return defines;
    };

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
        defines.add(getRuntimeDefines());
       

        mpResampleReservoirCausticPass = ComputePass::create(mpDevice, desc, defines, true);
    }
    FALCOR_ASSERT(mpResampleReservoirCausticPass);
    //Runtime defines
    mpResampleReservoirCausticPass->getProgram()->addDefines(getRuntimeDefines());

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

    var["CB"]["gPrevCamPos"] = mTemporalCameraPosition;
    var["CB"]["gPrevCamViewProjection"] = mTemporalCameraViewProjection;
    var["CB"]["gPrevCamForward"] = mTemporalCameraForward;
    var["CB"]["gNormalizedPixelArea"] = mNormalizedPixelArea;

    // Input Resources
    var["gCausticReservoirPrev"] = mpCausticReservoir[(mFrameCount + 1) % 2];
    var["gMVec"] = renderData[kInputMVec]->asTexture();
    
    // In-/Output Resources
    var["gCausticReservoir"] = mpCausticReservoir[mFrameCount % 2];

    var["gCellCounters"] = mpSplattingCellCounter;
    var["gCellOffsets"] = mpSplattingCellOffsets;
    var["gSortedReservoirs"] = mpSplattingSortedReservoirs;
    var["gSplattingLinkedList"] = mpSplattingResamlingLinkedList;

    // Execute
    const uint2 targetDim = renderData.getDefaultTextureDims();
    FALCOR_ASSERT(targetDim.x > 0 && targetDim.y > 0);
    mpResampleReservoirCausticPass->execute(pRenderContext, uint3(targetDim, 1));
}

void PhotonGuiding::reSTIREvaluateReservoirsPass(RenderContext* pRenderContext, const RenderData& renderData)
{
    FALCOR_PROFILE(pRenderContext, "EvaluateReservoirs");

    //Runtime defines
    auto getRuntimeDefines = [&]() {
        DefineList defines;
        defines.add("USE_ENV_BACKROUND", mpScene->useEnvBackground() ? "1" : "0");
        defines.add(mpRTXDI->getDefines());
        defines.add("GUIDING_MODE", std::to_string((uint)mGuidingMode));
        defines.add("ENABLE_LIGHT_TRACE_SPATTING", mEnableLightTraceSplatting ? "1" : "0");
        defines.add("GUIDING_DISCRETIZED_EMISSION_FACTOR", std::to_string(mGuidingDiscretizedEmissionFactor));
        defines.add("GUIDING_DISCRETIZED_EMISSION_MAX", std::to_string(mGuidingDiscretizedEmissionMax));
        defines.add("DEBUG_DISABLE_DIRECT_LIGHT", std::to_string(mDebugDisableDirectLight));
        defines.add("DEBUG_DISABLE_INDIRECT_LIGHT", std::to_string(mDebugDisableIndirectLight));
        defines.add(
            "ENABLE_RANDOM_REPLAY", mPhotonRenderMode == Falcor::PhotonGuidingSharedEnums::PhotonRenderMode::ReSTIR_PathPhoton ? "1" : "0"
        );
        defines.add("RNG_NUM_PASSES", std::to_string(mRNGNumPasses));
        defines.add("DEBUG_SHOW_PATHS", mDebugPathRetracingShowPaths ? "1" : "0");
        defines.add("USE_OPTIMIZED_ATLAS", mUseDirectionAtlasOptimization ? "1" : "0");
        defines.add("DiffuseBrdf", mUseLambertianDiffuse ? "DiffuseBrdfLambert" : "DiffuseBrdfFrostbite");
        return defines;
    };

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
        defines.add("USE_NRD", mEnableNRDOutputs ? "1" : "0"); //Cannot change during runtime
        defines.add(getRuntimeDefines());
       
        mpEvaluateReservoirsPass = ComputePass::create(mpDevice, desc, defines, true);
    }
    FALCOR_ASSERT(mpEvaluateReservoirsPass);

    // Runtime Defines
    mpEvaluateReservoirsPass->getProgram()->addDefines(getRuntimeDefines());

    // Set variables
    auto var = mpEvaluateReservoirsPass->getRootVar();
    mpScene->setRaytracingShaderData(pRenderContext, var); // Set scene data
    mpSampleGenerator->setShaderData(var);                 // Sample generator

    // Constant Buffer
    var["CB"]["gFrameCount"] = mFrameCount;
    var["CB"]["gFrameDim"] = mScreenRes;
    var["CB"]["gNormalizedPixelArea"] = mNormalizedPixelArea;
    var["CB"]["gLightIndexGuidingResolution"] = mGuidingLightIndexSize;
    var["CB"]["gGuidingTextureResolution"] = mGuidingTextureResolution;
    var["CB"]["gMapTextureResolution"] = mAtlasOptimizationMapSize;
    var["CB"]["gConfidenceCapPath"] = float(mResampleSettingsFG.confidenceCap);
    var["CB"]["gConfidenceCapCaustic"] = (mResampleSettingsCaustic.confidenceCap);

    // RTXDI resources
    mpRTXDI->setShaderData(var);

    // Input
    var["gVBuffer"] = renderData[kInputVBuffer]->asTexture();
    var["gFinalGatherReservoir"] = mpFinalGatherReservoir[mFrameCount % 2];
    var["gCausticReservoir"] = mpCausticReservoir[mFrameCount % 2];
    var["gEmission"] = mpEmission;
    var["gPathReservoir"] = mpPathReservoir[mFrameCount % 2];

    // Output
    var["gOutColor"] = renderData[kOutputColor]->asTexture();
    var["gVBufferPrev"] = mpVBufferPrev;
    var["gViewPrev"] = mpViewPrev;

    // Guiding textures
    var["gGuidingCounter"] = mpRecordGuidingAtlas;
    var["gLightIndexGuidingCounter"] = mpRecordLightIndexGuidingTexture;
    var["gMapLightIndexToGuidingDirection"] = mpMapLightIdxToGuidingDirection[mFrameCount % 2];

    //NRD outputs
    if (mEnableNRDOutputs) {
        var["gDiffuseRadiance"] = renderData[kOutputNRDDiffuseRadiance]->asTexture();
        var["gSpecularRadiance"] = renderData[kOutputNRDSpecularRadiance]->asTexture();
        var["gDiffuseReflectance"] = renderData[kOutputNRDDiffuseReflectance]->asTexture();
        var["gSpecularReflectance"] = renderData[kOutputNRDSpecularReflectance]->asTexture();
    }

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

    if (!mSplattingResampleUseLinkedList) {
        pRenderContext->clearUAV(mpSplattingGlobalCounter->getUAV(0).get(), uint4(0));
        pRenderContext->clearUAV(mpSplattingCellOffsets->getUAV(0).get(), uint4(0));
    }

    auto getRuntimeDefines = [&]()
    {
        DefineList defines;
        defines.add("USE_ENV_BACKROUND", mpScene->useEnvBackground() ? "1" : "0");
        defines.add("SPLATTING_USE_LINKED_LIST", mSplattingResampleUseLinkedList ? "1" : "0");
        defines.add("DiffuseBrdf", mUseLambertianDiffuse ? "DiffuseBrdfLambert" : "DiffuseBrdfFrostbite");
        return defines;
    };

    if (!mpTemporalSplatReservoirs)
    {
        Program::Desc desc;
        desc.addShaderModules(mpScene->getShaderModules());
        desc.addShaderLibrary(kShaderReSTIRTemporalSplatReservoirs).csEntry("main").setShaderModel(kShaderModel);
        desc.addTypeConformances(mpScene->getTypeConformances());

        DefineList defines;
        defines.add(mpScene->getSceneDefines());
        defines.add(mpSampleGenerator->getDefines());
        defines.add(getRuntimeDefines());

        mpTemporalSplatReservoirs = ComputePass::create(mpDevice, desc, defines, true);
    }
    mpTemporalSplatReservoirs->getProgram()->addDefines(getRuntimeDefines()); //Update

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
    var["gSplattingLinkedList"] = mpSplattingResamlingLinkedList;

    // Execute Compute Pass
    const uint2 targetDim = mScreenRes;
    FALCOR_ASSERT(targetDim.x > 0 && targetDim.y > 0);
    mpTemporalSplatReservoirs->execute(pRenderContext, uint3(targetDim, 1));
}

void PhotonGuiding::reSTIRRetraceAndSplatTemporalReservoirsPass(RenderContext* pRenderContext, const RenderData& renderData)
{
    //mRetraceCausticPathsPass
    std::string profileName = "RetraceAndSplatCausticReservoirs";
    FALCOR_PROFILE(pRenderContext, profileName);

    //Clear counter
    if (!mSplattingResampleUseLinkedList) {
        pRenderContext->clearUAV(mpSplattingGlobalCounter->getUAV(0).get(), uint4(0));
        pRenderContext->clearUAV(mpSplattingCellOffsets->getUAV(0).get(), uint4(0)); 
    }

    // Init Shader
    if (!mRetraceCausticPathsPass.pProgram)
    {
        RtProgram::Desc desc;
        desc.addShaderModules(mpScene->getShaderModules());
        desc.addShaderLibrary(kShaderReSTIRRetraceAndSplatReservoirs);
        desc.setMaxPayloadSize(sizeof(float) * 4);
        desc.setMaxAttributeSize(mpScene->getRaytracingMaxAttributeSize());
        desc.setMaxTraceRecursionDepth(1);
        if (!mpScene->hasProceduralGeometry())
            desc.setPipelineFlags(RtPipelineFlags::SkipProceduralPrimitives);

        mRetraceCausticPathsPass.pBindingTable = RtBindingTable::create(1, 1, mpScene->getGeometryCount());
        auto& sbt = mRetraceCausticPathsPass.pBindingTable;
        sbt->setRayGen(desc.addRayGen("rayGen", mpScene->getTypeConformances()));
        sbt->setMiss(0, desc.addMiss("miss"));

        if (mpScene->hasGeometryType(Scene::GeometryType::TriangleMesh))
        {
            sbt->setHitGroup(0, mpScene->getGeometryIDs(Scene::GeometryType::TriangleMesh), desc.addHitGroup("closestHit", "anyHit"));
        }

        mRetraceCausticPathsPass.pProgram = RtProgram::create(mpDevice, desc, mpScene->getSceneDefines());
    }

    // Defines that can change on runtime
    mRetraceCausticPathsPass.pProgram->addDefine("ANALYTIC_START_INDEX", std::to_string(mEmissiveLightCount));
    mRetraceCausticPathsPass.pProgram->addDefine("USE_ENV_BACKROUND", mpScene->useEnvBackground() ? "1" : "0");
    mRetraceCausticPathsPass.pProgram->addDefine("ROUGHNESS_THRESHOLD", std::to_string(mSpecularRoughnessThreshold));
    mRetraceCausticPathsPass.pProgram->addDefine("PHOTON_RUSSIAN_ROULETTE", mPhotonRussianRoulette ? "1" : "0");
    mRetraceCausticPathsPass.pProgram->addDefine("SPLATTING_USE_LINKED_LIST", mSplattingResampleUseLinkedList ? "1" : "0");
    mRetraceCausticPathsPass.pProgram->addDefine("DiffuseBrdf", mUseLambertianDiffuse ? "DiffuseBrdfLambert" : "DiffuseBrdfFrostbite");

    // Program Vars
    if (!mRetraceCausticPathsPass.pVars)
        mRetraceCausticPathsPass.initProgramVars(mpDevice, mpScene, mpSampleGenerator);
    FALCOR_ASSERT(mRetraceCausticPathsPass.pVars);

    if (!mCanResample || !mResampleSettingsFG.enable)
        return;

    auto var = mRetraceCausticPathsPass.pVars->getRootVar();

    var["CB"]["gFrameDim"] = mScreenRes;
    var["CB"]["gGuidingTextureResolution"] = mGuidingTextureResolution;

    var["gPrevReservoir"] = mpCausticReservoir[(mFrameCount + 1) % 2];
    var["gCellCounter"] = mpSplattingCellCounter;
    var["gGlobalCounter"] = mpSplattingGlobalCounter;
    var["gSplatSortData"] = mpSplattingSortingData;
    var["gSplattingLinkedList"] = mpSplattingResamlingLinkedList;

    // Dispatch Shader
    mpScene->raytrace(pRenderContext, mRetraceCausticPathsPass.pProgram.get(), mRetraceCausticPathsPass.pVars, uint3(mScreenRes, 1));
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

void PhotonGuiding::updateNumberOfRNGPasses()
{
    switch (mPhotonRenderMode)
    {
    case Falcor::PhotonGuidingSharedEnums::PhotonRenderMode::PhotonMapping:
    case Falcor::PhotonGuidingSharedEnums::PhotonRenderMode::FinalGathering:
        mRNGNumPasses = 2;
        break;
    case Falcor::PhotonGuidingSharedEnums::PhotonRenderMode::ReSTIR_FG:
        mRNGNumPasses = 5;
        break;
    case Falcor::PhotonGuidingSharedEnums::PhotonRenderMode::ReSTIR_PathPhoton:
        mRNGNumPasses = 6 + 3 * (1 + mResampleSettingsFG.spatialSamples);
        break;
    default:
        break;
    }

    //One addition RNG generator is needed when the light passes need to be retraced
    if(mRetraceLightPaths) // && (mPhotonRenderMode != PhotonRenderMode::PhotonMapping) && (mPhotonRenderMode != PhotonRenderMode::FinalGathering))
    {
        mRNGNumPasses++;
    }
}


