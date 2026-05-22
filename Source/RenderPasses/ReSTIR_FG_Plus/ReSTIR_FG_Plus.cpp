#include "ReSTIR_FG_Plus.h"
#include <memory>
#include <utility>
#include "RenderGraph/RenderPassHelpers.h"
#include "RenderGraph/RenderPassStandardFlags.h"
#include "Utils/Math/FalcorMath.h"

#include "Rendering/Lights/EmissivePowerSampler.h"
#include "Rendering/Lights/EmissiveUniformSampler.h"

namespace
{
    const std::string kShaderFolder = "RenderPasses/ReSTIR_FG_Plus/";
    const std::string kShaderTracePhotons = kShaderFolder + "TracePhotons.rt.slang";
    const std::string kShaderGenInitialSamples = kShaderFolder + "GenerateInitialSamples.rt.slang";
    const std::string kShaderBackprojectCaustics = kShaderFolder + "BackprojectCaustics.cs.slang";
    const std::string kShaderRetraceReservoirs = kShaderFolder + "RetraceReservoirs.rt.slang";
    const std::string kShaderResamplingPathReservoir = kShaderFolder + "ResamplePathReservoir.cs.slang";
    const std::string kShaderResamplingReservoirCaustic = kShaderFolder + "ResampleReservoirCaustic.cs.slang";
    const std::string kShaderEvaluateReservoirs = kShaderFolder + "EvaluateReservoirs.cs.slang";
    const std::string kShaderTemporalSplatReservoirs = kShaderFolder + "TemporalSplatReservoir.cs.slang";
    const std::string kShaderSortSplatReservoirs = kShaderFolder + "SortSplatReservoirs.cs.slang";

    const std::string kShaderModel = "6_5";

    // Render Pass inputs and outputs
    const std::string kInputVBuffer = "vbuffer";
    const std::string kInputView = "view";
    const std::string kInputMotionVectors = "mvec";

    const Falcor::ChannelList kInputChannels{
        {kInputVBuffer, "gVBuffer", "Visibility buffer in packed format"},
        {kInputView, "gView", "View Vector from camera perspective"},
        {kInputMotionVectors, "gMotionVectors", "Motion vector buffer (float format)"},
    };

    //Outputs
    const std::string kOutputColor = "color";
    const std::string kOutputDebug = "debug";

    const Falcor::ChannelList kOutputChannels
    {
        {kOutputColor, "gOutColor", "HDR output color", false /*optional*/, ResourceFormat::RGBA32Float},
        {kOutputDebug, "gDebug", "Debug Texture", false, ResourceFormat::RGBA32Float}
    };

}; // namespace

extern "C" FALCOR_API_EXPORT void registerPlugin(Falcor::PluginRegistry& registry)
{
    registry.registerClass<RenderPass, ReSTIR_FG_Plus>();
}

ReSTIR_FG_Plus::ReSTIR_FG_Plus(ref<Device> pDevice, const Properties& props)
    : RenderPass(pDevice)
{
    if (!mpDevice->isShaderModelSupported(Device::ShaderModel::SM6_5))
    {
        throw RuntimeError("ReSTIR_FG: Shader Model 6.5 is not supported by the current device");
    }
    if (!mpDevice->isFeatureSupported(Device::SupportedFeatures::RaytracingTier1_1))
    {
        throw RuntimeError("ReSTIR_FG: Raytracing Tier 1.1 is not supported by the current device");
    }

    //Caustic Reservoir default values
    mResampleSettingsCaustic.spatialSamples = 0;
    mResampleSettingsCaustic.disocclusionBoostExtraSamples = 1;
    mResampleSettingsCaustic.samplingRadius = 4.f;

    // Create sample generator.
    mpSampleGenerator = SampleGenerator::create(mpDevice, SAMPLE_GENERATOR_UNIFORM);
}

Properties ReSTIR_FG_Plus::getProperties() const
{
    return {}; //TODO
}

RenderPassReflection ReSTIR_FG_Plus::reflect(const CompileData& compileData)
{
    //In- and Output Textures
    RenderPassReflection reflector;
    addRenderPassInputs(reflector, kInputChannels);
    addRenderPassOutputs(reflector, kOutputChannels);
    return reflector;
}

void ReSTIR_FG_Plus::renderUI(Gui::Widgets& widget) {
    bool changed = false; 

    //Lamda for Path Length UI Element
    auto pathLengthUI = [&](PathLengthSettings& pathLength) {
        changed |= widget.var("Max Bounces", pathLength.bounces, 0u, 255u, 1u);
        changed |= widget.var("Max Diffuse Bounces", pathLength.diffuse , 0u, 255u, 1u);
        changed |= widget.var("Max Specular Bounces", pathLength.specular, 0u, 255u, 1u);
        changed |= widget.var("Max Delta Bounces", pathLength.delta, 0u, 255u, 1u);
    };

    if (auto group = widget.group("Photon Options"))
    {
        //DispatchedPhotons
        changed |= group.var("Dispatched Photons", mOptions.photonsDispatched, 1024u, 67108864u, 1u); //Max is 8192^2
        group.text("Global Photons: " + std::to_string(mPhotonCountUI[0]) + " / " + std::to_string(mOptions.photonBufferSizeGlobal));
        group.text("Caustic photons: " + std::to_string(mPhotonCountUI[1]) + " / " + std::to_string( mOptions.photonBufferSizeCaustic));
        //Photon Buffer Size
        static uint2 photonBufferSizeUI = uint2(mOptions.photonBufferSizeGlobal, mOptions.photonBufferSizeCaustic); 
        group.text("Photon Buffer Size:");
        group.indent(10.f);
        group.var(" ##MaxPhotonUI", photonBufferSizeUI, 100u, 100000000u, 100);
        group.tooltip("First -> Global, Second -> Caustic");
        if(group.button("Apply", true)){
            mPhotonBufferSizeChanged = true;
            mOptions.photonBufferSizeGlobal = photonBufferSizeUI.x;
            mOptions.photonBufferSizeCaustic = photonBufferSizeUI.y;
        }
        group.indent(-10.f);

        group.var("Acceleration Structure Build Overestimate", mOptions.photonASBuildBufferOverestimate, 1.f, FLT_MAX, 0.001f);
        group.tooltip("Percentage the CPU photon count value (which is delayed by 1-3 frames) is overestimated to improve acceleration structure build time.");

        pathLengthUI(mOptions.photonPathLenght);

        //Radius Setting
        changed |= group.checkbox("Use Adaptive Photon Radius", mOptions.photonUseAdaptiveRadius);
        group.tooltip("Enables adaptive photon radius, that is equal to the projected camera pixel size, which depends on the distance from the camera to the hit point");
        if(mOptions.photonUseAdaptiveRadius)
        {
            changed |= group.var("Adaptive Scale (Global/Caustic)", mOptions.photonAdaptiveRadius, 0.f, FLT_MAX, 0.0001f);
        }
        else
        {
            changed |= group.var("Radius (Global/Caustic)", mOptions.photonRadius, 0.f, FLT_MAX, 0.000001f, false, "%.6f");
        }

        changed |= group.var("Global Photon Rejection Probability", mOptions.photonGlobalRejection, 0.f, 1.f, 0.0001f);
        group.tooltip("Fixed probability, that a global photon is rejected");
        changed |= group.var("Mixed Light Analytic Probability", mOptions.photonMixedLightRatio, 0.f, 1.f, 0.0001f);
        group.tooltip("Probability, that a photon is generated from an analytic/emissive light 0 -> 0% Analytic, 100% Emissive");
    }

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
        group.var("Max Path Length", mOptions.cameraMaxPathLength, 1u, 64u, 1u);
        group.tooltip(
            "Maximum Path length for a initial path sample. A path sample stops, when it encounters a diffuse surface"
        );

        auto resampleUI = [](ResamplingSettings& settings, Gui::Widgets& widget) {
            widget.checkbox("Enable Resampling", settings.enable);
            widget.var("Confidence Cap", settings.confidenceCap, 1u, UINT_MAX, 1u);
            widget.tooltip("Maximum confidence a reservoir can have");
            widget.var("Spatial Samples", settings.spatialSamples, 0u, 64u, 1u);
            widget.var("Disocclusion additional spatial samples", settings.disocclusionBoostExtraSamples, 0u, 16u, 1u);
            widget.tooltip("Extra spatial samples if temporal resampling fails");
            widget.var("Spatial Sample Radius", settings.samplingRadius, 0.f, FLT_MAX, 1.f);
        };

        if (auto group2 = group.group("Resampling FG options"))
        {
            resampleUI(mResampleSettingsPath, group2);
        }
        if (auto group2 = group.group("Resampling Caustic options"))
        {
            resampleUI(mResampleSettingsCaustic, group2);
            mClearReservoir |= group2.checkbox("Use Light Trace Splatting for direct", mEnableLightTraceSplatting);
            group2.tooltip("Enables Light Trace with ReSTIR Splatting for the directly visible caustics");
        }

        group.separator();
        group.text("Surface Rejection Options:");
        group.var("Normal Rejection Threshold", mNormalThreshold, 0.f, 1.0f, 0.001f);
        group.tooltip("Threshold of dot product between both reservoir face normals");
        group.var("Sample Distance Threshold", mJacobianDistanceThreshold, 0.f, FLT_MAX, 0.001f);
        group.checkbox("Use Path Threshold", mUsePathThreshold);
        group.tooltip("Only resamples if the surfaces used for generating the Final Gather samples have the same path length. Always enabled for caustic collection");

        mClearReservoir = group.button("Clear Reservoirs");
    }

    if (auto group = widget.group("Material Options"))
    {
        changed |= group.checkbox("Use Lambertian Diffuse BSDF", mOptions.useLambertianDiffuseBSDF);
        group.tooltip("BSDF used by ReSTIR PT and Suffix ReSTIR prototype");

        group.text("Diffuse Classification Roughness Threshold:");
        group.tooltip("Surfaces with roughness above this threshold are considered diffuse");
        group.indent(10.f);
        changed |= group.var("##RoughnessThreshold", mOptions.specularRoughnessThreshold, 0.f, 1.f, 0.001f);
        group.indent(-10.f);

        changed |= group.checkbox("Enable Alpha Test", mOptions.enableAlphaTest);
        changed |= group.checkbox("Evaluate Delta PDFs", mOptions.evaluateDeltaPDFs);

    }

    if (auto group = widget.group("Debug"))
    {
        group.checkbox("Clear Debug Texture", mClearDebugTexture);
    }
}

void ReSTIR_FG_Plus::setScene(RenderContext* pRenderContext, const ref<Scene>& pScene) {
    // Reset Scene
    mpScene = pScene;

    //Reset all passes and sampling helpers
    mpPhotonAS.reset();
    mpEmissiveLightSampler.reset();
    mpRTXDI.reset();
    mResetScreenTex = true;
    resetAllRenderPasses();
   

    if (mpScene)
    {
        if (mpScene->hasGeometryType(Scene::GeometryType::Custom))
        {
            logWarning("This render pass only supports triangles. Other types of geometry will be ignored.");
        }
    }
}

void ReSTIR_FG_Plus::execute(RenderContext* pRenderContext, const RenderData& renderData)
{
    if (!mpScene)
        return;

    //Add refresh flag if options changed
    auto& dict = renderData.getDictionary();
    auto flags = dict.getValue(kRenderPassRefreshFlags, RenderPassRefreshFlags::None);
    if (mOptionsChanged)
    {
        dict[Falcor::kRenderPassRefreshFlags] = flags | Falcor::RenderPassRefreshFlags::RenderOptionsChanged;
        mOptionsChanged = false;
    }

    if (mClearDebugTexture)
    {
        auto pDebugTex = renderData[kOutputDebug]->asTexture();
        pRenderContext->clearTexture(pDebugTex.get());
    }

    //Disables Resampling for the frame
    if (mClearReservoir)
    {
        mCanResample = false;
        mClearReservoir = false;
    }

    //Update RNG constants
    mRNGNumPasses = 6 + 3 * (1 + mResampleSettingsPath.spatialSamples);

    //Init ReSTIR DI
    const auto& pMotionVectors = renderData[kInputMotionVectors]->asTexture();
    if (!mpRTXDI)
        mpRTXDI = std::make_unique<RTXDI>(mpScene, mRTXDIOptions);

    //Prepare needed Falcor helpers and Buffers/Textures
    prepareLightingStructure(pRenderContext);
    if (!mHasLights)
    {
        logWarningOnce("Scene has no lights, pass will not execute!");
        return;
    }

    prepareResources(pRenderContext, renderData);

    mpRTXDI->beginFrame(pRenderContext, mScreenRes);

    //Trace Photons and bulids the photon acceleration structure. Also backprojects caustic photons into the camera
    tracePhotonsPass(pRenderContext, renderData);

    //Caustic Backprojection
    backprojectCausticsPass(pRenderContext, renderData);

    //Creates initial Reservoirs samples for Path and Caustic Reservoirs. Also fills the Surface structure for RTXDI
    generateInitialSamplesPass(pRenderContext, renderData);

    // ReSTIR DI pass
    mpRTXDI->update(pRenderContext, pMotionVectors);

    //Reservoir Splatting
    /*
    if (mEnableLightTraceSplatting)
    {
        splatTemporalReservoirsPass(pRenderContext, renderData);

        sortSplattedReservoirsPass(pRenderContext, renderData);
    }

    uint resampleIterations = 1 + mResampleSettingsPath.spatialSamples;
    for (uint i = 0; i < resampleIterations; i++)
    {
        // Retrace
        retraceReservoirPass(pRenderContext, renderData, i);

        // Spatiotemporal resampling for final gather samples and caustics
        resampleReservoirsPass(pRenderContext, renderData, i);
    }   

    resampleReservoirCausticPass(pRenderContext, renderData);
    */


    //Finalize Reservoirs
    evaluateReservoirsPass(pRenderContext, renderData);

    //End ReSTIR DI frame
    mpRTXDI->endFrame(pRenderContext);

    //Copy Camera data for splatting
    const CameraData& camData = mpScene->getCamera()->getData();
    mTemporalCameraViewProjection = camData.viewProjMat;
    mTemporalCameraPosition = camData.posW;
    mTemporalCameraForward = math::normalize(camData.cameraW);

    mFrameCount++;
    mCanResample = true;
}

void ReSTIR_FG_Plus::resetAllRenderPasses()
{
    mTracePhotonPass = RayTraceProgramHelper::create();
    mGenerateInitialSamplesPass = RayTraceProgramHelper::create();
    mRetracePathReservoirsPass = RayTraceProgramHelper::create();
    mpBackprojectCausticSamplesPass.reset();
    mpResampleReservoirPass.reset();
    mpResampleReservoirCausticPass.reset();
    mpEvaluateReservoirsPass.reset();
}

void ReSTIR_FG_Plus::prepareLightingStructure(RenderContext* pRenderContext)
{
    // Make sure that the emissive light is up to date
    auto& pLights = mpScene->getLightCollection(pRenderContext);
    pLights->prepareSyncCPUData(pRenderContext);

    bool emissiveUsed = mpScene->useEmissiveLights();
    bool analyticUsed = mpScene->useAnalyticLights();

    mHasLights = analyticUsed || emissiveUsed;
    mMixedLights = emissiveUsed && analyticUsed;

    //Initialize Emissive Light Sampler
    if (emissiveUsed)
    {
        if (!mpEmissiveLightSampler || mRebuildLightSampler)
        {
            resetAllRenderPasses();
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
            resetAllRenderPasses();
        }
    }

    if (mpEmissiveLightSampler)
        mpEmissiveLightSampler->update(pRenderContext);

    //Initialize Enviroment Map sampler
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
            resetAllRenderPasses();
        }
    }

    //Update NEE selection probability
    mNeeLightSelectProb =
        float3(mpScene->useEmissiveLights() ? 1.f : 0.f, mpScene->useAnalyticLights() ? 1.f : 0.f, mpScene->useEnvLight() ? 1.f : 0.f);
    mNeeLightSelectProb /= mNeeLightSelectProb.x + mNeeLightSelectProb.y + mNeeLightSelectProb.z;
}

void ReSTIR_FG_Plus::prepareResources(RenderContext* pRenderContext, const RenderData& renderData)
{
    //Reset buffers when screen resolution or certain options changed
    auto& screenDims = renderData.getDefaultTextureDims();
    if (screenDims.x != mScreenRes.x || screenDims.y != mScreenRes.y)
    {
        mScreenRes = screenDims;
        mResetScreenTex = true;
    }

    if (mPhotonBufferSizeChanged)
    {
        mpPhotonAABB[0].reset();
        mpPhotonAABB[1].reset();
        mpPhotonData[0].reset();
        mpPhotonData[1].reset();
        mpLightTraceLinkedList.reset();
        mpPhotonAS.reset();
        mPhotonBufferSizeChanged = false;
    }

    //Buffers that exist two times
    for (uint i = 0; i < 2; i++)
    {
        uint photonBufferSize = i == 0 ? mOptions.photonBufferSizeGlobal : mOptions.photonBufferSizeCaustic;
        if (!mpPhotonAABB[i])
        {
            mpPhotonAABB[i] = Buffer::createStructured(
                mpDevice, sizeof(AABB), photonBufferSize , ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess,
                Buffer::CpuAccess::None, nullptr, false
            );
            mpPhotonAABB[i]->setName("PhotonAABB" + std::to_string(i));
        }
        if (!mpPhotonData[i])
        {
            mpPhotonData[i] = Buffer::createStructured(
                mpDevice, sizeof(float) * 12, photonBufferSize, ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess,
                Buffer::CpuAccess::None, nullptr, false
            );
            mpPhotonData[i]->setName("PhotonData" + std::to_string(i));
        }
        if (!mpCausticReservoir[i] || mResetScreenTex)
        {
            mCanResample = false;
            mpCausticReservoir[i] = Buffer::createStructured(
                mpDevice, 112u, mScreenRes.x * mScreenRes.y, ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess,
                Buffer::CpuAccess::None, nullptr, false
            );
            mpCausticReservoir[i]->setName("CausticReservoir" + std::to_string(i));
        }
        if (!mpPathReservoir[i] || mResetScreenTex)
        {
            mCanResample = false;
            mpPathReservoir[i] = Buffer::createStructured(
                mpDevice, 96u, mScreenRes.x * mScreenRes.y, ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess,
                Buffer::CpuAccess::None, nullptr, false
            );
            mpPathReservoir[i]->setName("PathReservoir_" + std::to_string(i));
        }
        if (!mpReservoirRetrace[i] || mResetScreenTex)
        {
            mpReservoirRetrace[i] = Buffer::createStructured(
                mpDevice, sizeof(uint) * 16, mScreenRes.x * mScreenRes.y,
                ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess, Buffer::CpuAccess::None, nullptr, false
            );
            mpReservoirRetrace[i]->setName("ReservoirRetrace" + std::to_string(i));
        }
    }

    //Photon Counters
    if (!mpPhotonCounter)
    {
        mpPhotonCounter = Buffer::createStructured(
            mpDevice, sizeof(uint), 2, ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess, Buffer::CpuAccess::None,
            nullptr, false
        );
        mpPhotonCounter->setName("PhotonCounter");

        mpPhotonCounterCPU = Buffer::createStructured(
            mpDevice, sizeof(uint), 2, ResourceBindFlags::None, Buffer::CpuAccess::Read, nullptr, false
        );
        mpPhotonCounterCPU->setName("PhotonCounterCPU");
    }

    //Light Trace resources
    if (!mpLightTraceHeadCounter || mResetScreenTex)
    {
        mpLightTraceHeadCounter = Texture::create2D(
            mpDevice, mScreenRes.x, mScreenRes.y, ResourceFormat::R32Int, 1u, 1u, nullptr,
            ResourceBindFlags::UnorderedAccess | ResourceBindFlags::ShaderResource
        );
        mpLightTraceHeadCounter->setName("LightTraceHeadCounter");
        pRenderContext->clearUAV(mpLightTraceHeadCounter->getUAV(0).get(), uint4(uint(-1)));
    }

    if (!mpLightTraceLinkedList)
    {
        mpLightTraceLinkedList = Buffer::createStructured(
            mpDevice, sizeof(uint), mOptions.photonBufferSizeCaustic, ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess,
            Buffer::CpuAccess::None, nullptr, false
        );
        mpLightTraceLinkedList->setName("LightTraceLinkedList");
        pRenderContext->clearUAV(mpLightTraceLinkedList->getUAV(0).get(), uint4(uint(-1)));
    }

    if(!mpPhotonHitInfo)
    {
        mpPhotonHitInfo = Buffer::createStructured(
            mpDevice, sizeof(uint) * 4, mOptions.photonBufferSizeCaustic, ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess,
            Buffer::CpuAccess::None, nullptr, false
        );
        mpPhotonHitInfo->setName("PhotonHitInfo");
    }

    //Set Splatting Resources
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

    //Copy of surface from last frame
    if (!mpVBufferPrev || mResetScreenTex)
    {
        auto pVBuffer = renderData[kInputVBuffer]->asTexture();
        mpVBufferPrev = Texture::create2D(
            mpDevice, mScreenRes.x, mScreenRes.y, pVBuffer->getFormat(), 1u, 1u, nullptr,
            ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess
        );
        mpVBufferPrev->setName("VBufferPrev");
    }

    if (!mpViewPrev || mResetScreenTex)
    {
        auto pView = renderData[kInputView]->asTexture();
        mpViewPrev = Texture::create2D(
            mpDevice, mScreenRes.x, mScreenRes.y, pView->getFormat(), 1u, 1u, nullptr,
            ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess
        );
        mpViewPrev->setName("ViewPrev");
    }

    // Create the Photon Acceleration Structure
    if (!mpPhotonAS)
    {
        std::vector<uint64_t> aabbCount = {mOptions.photonBufferSizeGlobal, mOptions.photonBufferSizeCaustic};
        std::vector<uint64_t> aabbGPUAddress = {mpPhotonAABB[0]->getGpuAddress(), mpPhotonAABB[1]->getGpuAddress()};
        mpPhotonAS = std::make_unique<CustomAccelerationStructure>(
            mpDevice, aabbCount, aabbGPUAddress, CustomAccelerationStructure::BuildMode::FastBuild,
            CustomAccelerationStructure::UpdateMode::None
        );
    }

    mResetScreenTex = false;
}

void ReSTIR_FG_Plus::tracePhotonsPass(RenderContext* pRenderContext, const RenderData& renderData)
{
    FALCOR_PROFILE(pRenderContext, "TracePhotons");

    //Clear Photon Counter
    pRenderContext->clearUAV(mpPhotonCounter->getUAV().get(), uint4(0));

    auto getRuntimeDefines = [&](){
        DefineList defines = {};
        defines.add("PHOTON_BUFFER_SIZE_GLOBAL", std::to_string(mOptions.photonBufferSizeGlobal));
        defines.add("PHOTON_BUFFER_SIZE_CAUSTIC", std::to_string(mOptions.photonBufferSizeCaustic));
        defines.add("RNG_NUM_PASSES", std::to_string(mRNGNumPasses));
        defines.add("USE_EMISSIVE_LIGHTS", mpScene->useEmissiveLights()? "1" : "0");
        defines.add("USE_ANALYTIC_LIGHTS", mpScene->useAnalyticLights()? "1" : "0");
        defines.add("USE_ADAPTIVE_PHOTON_RADIUS", mOptions.photonUseAdaptiveRadius ? "1" : "0");
        defines.add(getMaterialDefines());

        return defines;
    };

    // Init Shader
    if (!mTracePhotonPass.pProgram)
    {
        RtProgram::Desc desc;
        desc.addShaderModules(mpScene->getShaderModules());
        desc.addShaderLibrary(kShaderTracePhotons);
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
        defines.add(getRuntimeDefines());

        mTracePhotonPass.pProgram = RtProgram::create(mpDevice, desc, defines);
    }
    //Update Defines
    mTracePhotonPass.pProgram->addDefines(getRuntimeDefines());
    
    // Program Vars
    if (!mTracePhotonPass.pVars)
        mTracePhotonPass.initProgramVars(mpDevice, mpScene, mpSampleGenerator);
    FALCOR_ASSERT(mTracePhotonPass.pVars);
    auto var = mTracePhotonPass.pVars->getRootVar();
    mpScene->setRaytracingShaderData(pRenderContext, var);

    //Shader dispatch dims (TODO optimize for non-guiding case, so that similar lights are traced in the same workgroup)
    uint dispatchedPhotons = mOptions.photonsDispatched;
    uint shaderDispatchDim = static_cast<uint>(std::floor(sqrt(dispatchedPhotons)));
    shaderDispatchDim = std::max(32u, shaderDispatchDim);

    //Approximated pixel diagonal at length 1 for adaptive photon radius
    float approxPixelDiagonal = 0.f;
    if (mOptions.photonUseAdaptiveRadius)
    {
        // Update Image plane distance
        auto& cameraData = mpScene->getCamera()->getData();
        // Get normalized pixel area
        float h = cameraData.frameHeight / cameraData.focalLength; //Normalized Frame height
        float w = h * cameraData.aspectRatio;
        float wPix = w / mScreenRes.x;
        float hPix = h / mScreenRes.y;

        approxPixelDiagonal = sqrt((wPix * wPix) + (hPix * hPix));
    }

    //Constant Buffer
    var["CB"]["gFrameCount"] = mFrameCount;
    var["CB"]["gPhotonRadius"] = mOptions.photonUseAdaptiveRadius ? mOptions.photonAdaptiveRadius : mOptions.photonRadius;
    var["CB"]["gPackedPathLength"] = mOptions.photonPathLenght.pack();
    var["CB"]["gGlobalRejectionProb"] = mOptions.photonGlobalRejection;
    var["CB"]["gDispatchDimension"] = shaderDispatchDim;
    var["CB"]["gScreenDimensions"] = mScreenRes;
    var["CB"]["gMixedLightsAnalyticProbability"] = mOptions.photonMixedLightRatio;
    var["CB"]["gNormalizedPixelDiagonal"] = approxPixelDiagonal;

    //Output Buffers
    for (uint32_t i = 0; i < 2; i++)
    {
        var["gPhotonAABB"][i] = mpPhotonAABB[i];
        var["gPhotonData"][i] = mpPhotonData[i];
    }
    var["gPhotonCounter"] = mpPhotonCounter;

    //Backprojection
    var["gLightTraceHeadCounter"] = mpLightTraceHeadCounter;
    var["gLightTraceLinkedList"] = mpLightTraceLinkedList;
    var["gPhotonHitInfo"] = mpPhotonHitInfo;

    //Dispatch raytracing shader
    mpScene->raytrace(pRenderContext, mTracePhotonPass.pProgram.get(), mTracePhotonPass.pVars, uint3(shaderDispatchDim, shaderDispatchDim, 1));

    pRenderContext->uavBarrier(mpLightTraceHeadCounter.get());

    //
    //Build the AS for that frame
    //

    //Clear values after the counter
    std::vector<ref<Buffer>> aabbs = {mpPhotonAABB[0], mpPhotonAABB[1]};
    mpPhotonAS->clearAABBBuffers(pRenderContext, aabbs, true, mpPhotonCounter); //Clears unused slots 

    // Copy the PhotonCounter to a CPU Buffer (asynchronous, read GPU value can be a couple of frames old)
    pRenderContext->copyBufferRegion(mpPhotonCounterCPU.get(), 0, mpPhotonCounter.get(), 0, sizeof(uint2));
    void* data = mpPhotonCounterCPU->map(Buffer::MapType::Read);
    std::memcpy(&mPhotonCountUI, data, sizeof(uint2));
    mpPhotonCounterCPU->unmap();
        
    //Build acceleration structure
    uint2 currentPhotons = mFrameCount > 0 ?
        uint2(float2(mPhotonCountUI) * mOptions.photonASBuildBufferOverestimate) :
        uint2(mOptions.photonBufferSizeGlobal, mOptions.photonBufferSizeCaustic);
    std::vector<uint64_t> photonBuildSize = {
        std::min(mOptions.photonBufferSizeGlobal, currentPhotons[0]), std::min(mOptions.photonBufferSizeCaustic, currentPhotons[1])
    };
    mpPhotonAS->update(pRenderContext, photonBuildSize);
}

float ReSTIR_FG_Plus::getNormalizedPixelArea()
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

void ReSTIR_FG_Plus::generateInitialSamplesPass(RenderContext* pRenderContext, const RenderData& renderData)
{
    FALCOR_PROFILE(pRenderContext, "InitialSamples");

    auto getRuntimeDefines = [&](){
        DefineList defines = {};
        defines.add(mpRTXDI->getDefines());
        defines.add(getMaterialDefines());
        defines.add("USE_ENV_BACKGROUND", mpScene->useEnvBackground() ? "1" : "0");
        defines.add("RNG_NUM_PASSES", std::to_string(mRNGNumPasses));
        return defines;
    };

    //Init Shader
    if (!mGenerateInitialSamplesPass.pProgram)
    {
        RtProgram::Desc desc;
        desc.addShaderModules(mpScene->getShaderModules());
        desc.addShaderLibrary(kShaderGenInitialSamples);
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

        mGenerateInitialSamplesPass.pProgram = RtProgram::create(mpDevice, desc, mpScene->getSceneDefines());
    }

    //Defines that can change on runtime
    mGenerateInitialSamplesPass.pProgram->addDefines(getRuntimeDefines());
    if (mpEmissiveLightSampler)
        mGenerateInitialSamplesPass.pProgram->addDefines(mpEmissiveLightSampler->getDefines());

    //Program Vars
    if (!mGenerateInitialSamplesPass.pVars)
        mGenerateInitialSamplesPass.initProgramVars(mpDevice, mpScene, mpSampleGenerator);

    FALCOR_ASSERT(mGenerateInitialSamplesPass.pVars);
    auto var = mGenerateInitialSamplesPass.pVars->getRootVar();

    //Update Normalized pixel area for backprojection
    mNormalizedPixelArea = getNormalizedPixelArea();

    //Constant Buffer
    var["CB"]["gFrameCount"] = mFrameCount;
    var["CB"]["gMaxPathLength"] = mOptions.cameraMaxPathLength;
    var["CB"]["gJacobianDistanceThreshold"] = mOptions.jacobianDistanceThreshold;
    var["CB"]["gNeeSelectProbabilites"] = mNeeLightSelectProb;

    //RTXDI Resources
    mpRTXDI->setShaderData(var);
    // NEE Structures for Path Resampling 
    if (mpEmissiveLightSampler)
        mpEmissiveLightSampler->setShaderData(var["Light"]["gEmissiveSampler"]);
    if (mpEnvMapSampler)
        mpEnvMapSampler->setShaderData(var["Light"]["gEnvMapSampler"]);

    //Input Resources
    var["gVBuffer"] = renderData[kInputVBuffer]->asTexture();
    var["gView"] = renderData[kInputView]->asTexture();
    mpPhotonAS->bindTlas(var, "gPhotonAS");
    for (uint32_t i = 0; i < 2; i++)
    {
        var["gPhotonAABB"][i] = mpPhotonAABB[i];
        var["gPhotonData"][i] = mpPhotonData[i];
    }

    //Output Resources
    var["gPathReservoir"] = mpPathReservoir[mReservoirIndex % 2];

    var["gDebug"] = renderData[kOutputDebug]->asTexture();

    //Dispatch Shader
    mpScene->raytrace(pRenderContext, mGenerateInitialSamplesPass.pProgram.get(), mGenerateInitialSamplesPass.pVars, uint3(mScreenRes, 1));
}

void ReSTIR_FG_Plus::backprojectCausticsPass(RenderContext* pRenderContext, const RenderData& renderData)
{
    FALCOR_PROFILE(pRenderContext, "BackprojectCaustics");

    auto getRuntimeDefines = [&](){
        DefineList defines = {};
        defines.add(getMaterialDefines());
        defines.add("RNG_NUM_PASSES", std::to_string(mRNGNumPasses));
        return defines;
    };

    //Initialize Compute Pass
    if(!mpBackprojectCausticSamplesPass)
    {
         Program::Desc desc;
        desc.addShaderModules(mpScene->getShaderModules());
        desc.addShaderLibrary(kShaderBackprojectCaustics).csEntry("main").setShaderModel(kShaderModel);
        desc.addTypeConformances(mpScene->getTypeConformances());

        DefineList defines;
        defines.add(mpScene->getSceneDefines());
        defines.add(mpSampleGenerator->getDefines());
        defines.add(getRuntimeDefines());
       
        mpBackprojectCausticSamplesPass = ComputePass::create(mpDevice, desc, defines, true);
    }
    FALCOR_ASSERT(mpBackprojectCausticSamplesPass);
    //Runtime defines
    mpBackprojectCausticSamplesPass->getProgram()->addDefines(getRuntimeDefines());

    //Set vars
    auto var = mpBackprojectCausticSamplesPass->getRootVar();
    mpScene->setRaytracingShaderData(pRenderContext, var); // Set scene data
    mpSampleGenerator->setShaderData(var);                    // Sample generator

    var["CB"]["gFrameCount"] = mFrameCount;
    var["CB"]["gFrameDimX"] = mScreenRes.x;
    var["CB"]["gNormalizedPixelArea"] = mNormalizedPixelArea;

    var["gLightTraceHeadCounter"] = mpLightTraceHeadCounter;
    var["gLightTraceLinkedList"] = mpLightTraceLinkedList;
    var["gPhotonData"] = mpPhotonData[1]; //Caustic photon data
    var["gPhotonHitInfo"] = mpPhotonHitInfo;

    var["gCausticReservoir"] = mpCausticReservoir[mFrameCount % 2];

     // Execute
    mpBackprojectCausticSamplesPass->execute(pRenderContext, uint3(mScreenRes, 1));
}

void ReSTIR_FG_Plus::splatTemporalReservoirsPass(RenderContext* pRenderContext, const RenderData& renderData)
{
    FALCOR_PROFILE(pRenderContext, "Splat Caustic Reservoirs");

    pRenderContext->clearUAV(mpSplattingGlobalCounter->getUAV(0).get(), uint4(0));
    pRenderContext->clearUAV(mpSplattingCellCounter->getUAV(0).get(), uint4(0));
    pRenderContext->clearUAV(mpSplattingCellOffsets->getUAV(0).get(), uint4(0));
   
    if (!mpTemporalSplatReservoirs)
    {
        Program::Desc desc;
        desc.addShaderModules(mpScene->getShaderModules());
        desc.addShaderLibrary(kShaderTemporalSplatReservoirs).csEntry("main").setShaderModel(kShaderModel);
        desc.addTypeConformances(mpScene->getTypeConformances());

        DefineList defines;
        defines.add(mpScene->getSceneDefines());
        defines.add(mpSampleGenerator->getDefines());
        defines.add("USE_ENV_BACKROUND", mpScene->useEnvBackground() ? "1" : "0");
        defines.add(getMaterialDefines());

        mpTemporalSplatReservoirs = ComputePass::create(mpDevice, desc, defines, true);
    }
    FALCOR_ASSERT(mpTemporalSplatReservoirs);
    mpTemporalSplatReservoirs->getProgram()->addDefines(getMaterialDefines()); // Runtime define

    // Return early if there is no previous reservoir or resampling is disabled
    if ((!mCanResample) || !mResampleSettingsPath.enable)
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

void ReSTIR_FG_Plus::sortSplattedReservoirsPass(RenderContext* pRenderContext, const RenderData& renderData)
{
    FALCOR_PROFILE(pRenderContext, "Sort Splatted Reservoirs");

    //Init Shaders
    if (!mpSplatSortComputeCellOffsets)
    {
        Program::Desc desc;
        desc.addShaderModules(mpScene->getShaderModules());
        desc.addShaderLibrary(kShaderSortSplatReservoirs).csEntry("computeCellOffsets").setShaderModel(kShaderModel);
        desc.addTypeConformances(mpScene->getTypeConformances());

        DefineList defines;
        defines.add(mpScene->getSceneDefines());
        defines.add(mpSampleGenerator->getDefines());
        defines.add(getMaterialDefines());

        mpSplatSortComputeCellOffsets = ComputePass::create(mpDevice, desc, defines, true);
    }
    FALCOR_ASSERT(mpSplatSortComputeCellOffsets);
    mpSplatSortComputeCellOffsets->getProgram()->addDefines(getMaterialDefines()); // Runtime define
    if (!mpSplatSortCellData)
    {
        Program::Desc desc;
        desc.addShaderModules(mpScene->getShaderModules());
        desc.addShaderLibrary(kShaderSortSplatReservoirs).csEntry("sortCellData").setShaderModel(kShaderModel);
        desc.addTypeConformances(mpScene->getTypeConformances());

        DefineList defines;
        defines.add(mpScene->getSceneDefines());
        defines.add(mpSampleGenerator->getDefines());
        defines.add("USE_ENV_BACKROUND", mpScene->useEnvBackground() ? "1" : "0");
        defines.add(getMaterialDefines());

        mpSplatSortCellData = ComputePass::create(mpDevice, desc, defines, true);
    }
    FALCOR_ASSERT(mpSplatSortCellData);
    mpSplatSortCellData->getProgram()->addDefines(getMaterialDefines()); // Runtime define

    // Return early if there is no previous reservoir or resampling is disabled
    if ((!mCanResample) || !mResampleSettingsPath.enable)
    {
        return;
    }

    //Lambda for shader vars as they are the same for both shaders
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

    //Cell offset pass
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

void ReSTIR_FG_Plus::retraceReservoirPass(RenderContext* pRenderContext, const RenderData& renderData, uint numPass)
{
    FALCOR_PROFILE(pRenderContext, "Retrace Reservoir");
    // Init Shader
    if (!mRetracePathReservoirsPass.pProgram)
    {
        RtProgram::Desc desc;
        desc.addShaderModules(mpScene->getShaderModules());
        desc.addShaderLibrary(kShaderRetraceReservoirs);
        desc.setMaxPayloadSize(sizeof(float) * 4);
        desc.setMaxAttributeSize(mpScene->getRaytracingMaxAttributeSize());
        desc.setMaxTraceRecursionDepth(1);
        if (!mpScene->hasProceduralGeometry())
            desc.setPipelineFlags(RtPipelineFlags::SkipProceduralPrimitives);

        mRetracePathReservoirsPass.pBindingTable = RtBindingTable::create(1, 1, mpScene->getGeometryCount());
        auto& sbt = mRetracePathReservoirsPass.pBindingTable;
        sbt->setRayGen(desc.addRayGen("rayGen", mpScene->getTypeConformances()));
        sbt->setMiss(0, desc.addMiss("miss"));

        if (mpScene->hasGeometryType(Scene::GeometryType::TriangleMesh))
        {
            sbt->setHitGroup(0, mpScene->getGeometryIDs(Scene::GeometryType::TriangleMesh), desc.addHitGroup("closestHit", "anyHit"));
        }

        mRetracePathReservoirsPass.pProgram = RtProgram::create(mpDevice, desc, mpScene->getSceneDefines());
    }

    // Defines that can change on runtime
    mRetracePathReservoirsPass.pProgram->addDefines(getMaterialDefines());
    mRetracePathReservoirsPass.pProgram->addDefine("ENABLE_LIGHT_TRACE", mEnableLightTraceSplatting ? "1" : "0");
    mRetracePathReservoirsPass.pProgram->addDefine("USE_ENV_BACKGROUND", mpScene->useEnvBackground() ? "1" : "0");
    mRetracePathReservoirsPass.pProgram->addDefine("RNG_NUM_PASSES", std::to_string(mRNGNumPasses));

    // Program Vars
    if (!mRetracePathReservoirsPass.pVars)
        mRetracePathReservoirsPass.initProgramVars(mpDevice, mpScene, mpSampleGenerator);

    FALCOR_ASSERT(mRetracePathReservoirsPass.pVars);
    auto var = mRetracePathReservoirsPass.pVars->getRootVar();

    // Constant Buffer
    var["CB"]["gFrameCount"] = mFrameCount;
    var["CB"]["gFGRayMaxPathLength"] = mFGRayMaxPathLength;
    var["CB"]["gNumResamplingPass"] = numPass; //Current path iteration starting from 0 (temporal)
    var["CB"]["gSpatialSampleRadius"] = mResampleSettingsPath.samplingRadius;

    // Input Resources
    var["gVBuffer"] = renderData[kInputVBuffer]->asTexture();
    var["gView"] = renderData[kInputView]->asTexture();
    var["gMVec"] = renderData[kInputMotionVectors]->asTexture();
    var["gVBufferPrev"] = mpVBufferPrev;
    var["gViewPrev"] = mpViewPrev;

    mpPhotonAS->bindTlas(var, "gPhotonAS");
    for (uint32_t i = 0; i < 2; i++)
    {
        var["gPhotonAABB"][i] = mpPhotonAABB[i];
        var["gPhotonData"][i] = mpPhotonData[i];
    }
    var["gPathReservoir"] = mpPathReservoir[mFrameCount % 2];
    var["gPathReservoirPrev"] = mpPathReservoir[(mFrameCount + 1) % 2];

    // Output Resources
    var["gRetraceReservoirPath"] = mpReservoirRetrace[0];
    var["gRetraceReservoirPathPrev"] = mpReservoirRetrace[1];
    var["gDebug"] = renderData[kOutputDebug]->asTexture();

    // Dispatch Shader
    mpScene->raytrace(pRenderContext, mRetracePathReservoirsPass.pProgram.get(), mRetracePathReservoirsPass.pVars, uint3(mScreenRes, 1));
}

void ReSTIR_FG_Plus::resampleReservoirsPass(RenderContext* pRenderContext, const RenderData& renderData, uint numPass)
{
    FALCOR_PROFILE(pRenderContext, "Resampling Path Reservoirs");
    //Initialize compute pass
    if (!mpResampleReservoirPass)
    {
        Program::Desc desc;
        desc.addShaderModules(mpScene->getShaderModules());
        desc.addShaderLibrary(kShaderResamplingPathReservoir).csEntry("main").setShaderModel(kShaderModel);
        desc.addTypeConformances(mpScene->getTypeConformances());

        DefineList defines;
        defines.add(mpScene->getSceneDefines());
        defines.add(mpSampleGenerator->getDefines());
        defines.add("USE_ENV_BACKROUND", mpScene->useEnvBackground() ? "1" : "0");
        defines.add(getMaterialDefines());
        defines.add("RNG_NUM_PASSES", std::to_string(mRNGNumPasses));

        mpResampleReservoirPass = ComputePass::create(mpDevice, desc, defines, true);
    }
    FALCOR_ASSERT(mpResampleReservoirPass);
    mpResampleReservoirPass->getProgram()->addDefines(getMaterialDefines()); // Runtime define
    mpResampleReservoirPass->getProgram()->addDefine("RNG_NUM_PASSES", std::to_string(mRNGNumPasses)); // Runtime define

    //Return early if there is no previous reservoir or resampling is disabled
    if ((!mCanResample) || !mResampleSettingsPath.enable)
    {
        return;
    }

    // Set variables
    auto var = mpResampleReservoirPass->getRootVar();
    mpScene->setRaytracingShaderData(pRenderContext, var); // Set scene data
    mpSampleGenerator->setShaderData(var);                 // Sample generator

    // Constant Buffer
    var["CB"]["gFrameCount"] = mFrameCount;
    var["CB"]["gFrameDim"] = mScreenRes;
    var["CB"]["gConfidenceLimit"] = mResampleSettingsPath.confidenceCap;
    var["CB"]["gSpatialRadius"] = mResampleSettingsPath.samplingRadius;
    var["CB"]["gSpatialSamples"] = mResampleSettingsPath.spatialSamples;
    var["CB"]["gDisocclusionBoostSpatialSamples"] = mResampleSettingsPath.disocclusionBoostExtraSamples;
    var["CB"]["gNormalThreshold"] = mNormalThreshold;
    var["CB"]["gJacobianDistanceThreshold"] = mJacobianDistanceThreshold;
    var["CB"]["gUsePathThreshold"] = mUsePathThreshold;
    var["CB"]["gNumResamplingPass"] = numPass;

    // Input Resources
    var["gVBuffer"] = renderData[kInputVBuffer]->asTexture();
    var["gVBufferPrev"] = mpVBufferPrev;
    var["gView"] = renderData[kInputView]->asTexture();
    var["gViewPrev"] = mpViewPrev;
    var["gMVec"] = renderData[kInputMotionVectors]->asTexture();
    var["gPathReservoirPrev"] = mpPathReservoir[(mFrameCount + 1) % 2];
    var["gRetracedPath"] = mpReservoirRetrace[0];
    var["gRetracedPathPrev"] = mpReservoirRetrace[1];

    // In-/Output Resources
    var["gPathReservoir"] = mpPathReservoir[mFrameCount % 2];

    var["gDebug"] = renderData[kOutputDebug]->asTexture();

    // Execute Compute Pass
    const uint2 targetDim = renderData.getDefaultTextureDims();
    FALCOR_ASSERT(targetDim.x > 0 && targetDim.y > 0);
    mpResampleReservoirPass->execute(pRenderContext, uint3(targetDim, 1));
}

void ReSTIR_FG_Plus::resampleReservoirCausticPass(RenderContext* pRenderContext, const RenderData& renderData)
{
    FALCOR_PROFILE(pRenderContext, "Resampling Caustics");
    // Initialize compute pass
    if (!mpResampleReservoirCausticPass)
    {
        Program::Desc desc;
        desc.addShaderModules(mpScene->getShaderModules());
        desc.addShaderLibrary(kShaderResamplingReservoirCaustic).csEntry("main").setShaderModel(kShaderModel);
        desc.addTypeConformances(mpScene->getTypeConformances());

        DefineList defines;
        defines.add(mpScene->getSceneDefines());
        defines.add(mpSampleGenerator->getDefines());
        defines.add(mpRTXDI->getDefines());
        defines.add(getMaterialDefines());
        defines.add("ENABLE_LIGHT_TRACE", mEnableLightTraceSplatting ? "1" : "0");
        defines.add("RNG_NUM_PASSES", std::to_string(mRNGNumPasses));

        mpResampleReservoirCausticPass = ComputePass::create(mpDevice, desc, defines, true);
    }
    FALCOR_ASSERT(mpResampleReservoirCausticPass);
    mpResampleReservoirCausticPass->getProgram()->addDefines(getMaterialDefines()); //Runtime define
    mpResampleReservoirCausticPass->getProgram()->addDefine("ENABLE_LIGHT_TRACE", mEnableLightTraceSplatting ? "1" : "0");
    mpResampleReservoirCausticPass->getProgram()->addDefine("RNG_NUM_PASSES", std::to_string(mRNGNumPasses));

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
    var["CB"]["gNormalThreshold"] = mNormalThreshold;
    var["CB"]["gPhotonRadius"] = mOptions.photonRadius;
    var["CB"]["gPrevCamPos"] = mTemporalCameraPosition;
    var["CB"]["gPrevCamViewProjection"] = mTemporalCameraViewProjection;
    var["CB"]["gPrevCamForward"] = mTemporalCameraForward;
    var["CB"]["gNormalizedPixelArea"] = mNormalizedPixelArea;

    // Input Resources
    var["gCausticReservoirPrev"] = mpCausticReservoir[(mFrameCount + 1) % 2];
    var["gMVec"] = renderData[kInputMotionVectors]->asTexture();

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

void ReSTIR_FG_Plus::evaluateReservoirsPass(RenderContext* pRenderContext, const RenderData& renderData)
{
    FALCOR_PROFILE(pRenderContext, "EvaluateReservoirs");

    // Create compute pass
    if (!mpEvaluateReservoirsPass)
    {
        Program::Desc desc;
        desc.addShaderModules(mpScene->getShaderModules());
        desc.addShaderLibrary(kShaderEvaluateReservoirs).csEntry("main").setShaderModel(kShaderModel);
        desc.addTypeConformances(mpScene->getTypeConformances());

        DefineList defines;
        defines.add(mpScene->getSceneDefines());
        defines.add(mpSampleGenerator->getDefines());
        defines.add("USE_ENV_BACKROUND", mpScene->useEnvBackground() ? "1" : "0");
        defines.add(mpRTXDI->getDefines());
        defines.add(getMaterialDefines());
        defines.add("ENABLE_LIGHT_TRACE", mEnableLightTraceSplatting ? "1" : "0");
        defines.add("RNG_NUM_PASSES", std::to_string(mRNGNumPasses));

        mpEvaluateReservoirsPass = ComputePass::create(mpDevice, desc, defines, true);
    }
    FALCOR_ASSERT(mpEvaluateReservoirsPass);

    //Runtime Defines
    mpEvaluateReservoirsPass->getProgram()->addDefines(mpRTXDI->getDefines());
    mpEvaluateReservoirsPass->getProgram()->addDefines(getMaterialDefines());
    mpEvaluateReservoirsPass->getProgram()->addDefine("USE_ENV_BACKROUND", mpScene->useEnvBackground() ? "1" : "0");
    mpEvaluateReservoirsPass->getProgram()->addDefine("ENABLE_LIGHT_TRACE", mEnableLightTraceSplatting ? "1" : "0");
    mpEvaluateReservoirsPass->getProgram()->addDefine("RNG_NUM_PASSES", std::to_string(mRNGNumPasses));

    // Set variables
    auto var = mpEvaluateReservoirsPass->getRootVar();
    mpScene->setRaytracingShaderData(pRenderContext, var); // Set scene data
    mpSampleGenerator->setShaderData(var);                    // Sample generator

    //Constant Buffer
    var["CB"]["gFrameCount"] = mFrameCount;
    var["CB"]["gFrameDim"] = mScreenRes;
    var["CB"]["gNormalizedPixelArea"] = mNormalizedPixelArea;

    //RTXDI resources
    mpRTXDI->setShaderData(var);

    //Input
    var["gVBuffer"] = renderData[kInputVBuffer]->asTexture();
    var["gView"] = renderData[kInputView]->asTexture();
    var["gPathReservoir"] = mpPathReservoir[mReservoirIndex % 2];
    var["gCausticReservoir"] = mpCausticReservoir[mFrameCount % 2];

    //Output
    var["gVBufferPrev"] = mpVBufferPrev;
    var["gViewPrev"] = mpViewPrev;
    var["gOutColor"] = renderData[kOutputColor]->asTexture();

    // Execute
    const uint2 targetDim = renderData.getDefaultTextureDims();
    FALCOR_ASSERT(targetDim.x > 0 && targetDim.y > 0);
    mpEvaluateReservoirsPass->execute(pRenderContext, uint3(targetDim, 1));
}

DefineList ReSTIR_FG_Plus::getMaterialDefines()
{
    DefineList defines;
    defines.add("DiffuseBrdf", mOptions.useLambertianDiffuseBSDF ? "DiffuseBrdfLambert" : "DiffuseBrdfFrostbite");
    defines.add("enableDiffuse", "1");
    defines.add("enableSpecular", "1");
    defines.add("enableTranslucency", "1");
    defines.add("ROUGHNESS_THRESHOLD", std::to_string(mOptions.specularRoughnessThreshold));
    defines.add("ENABLE_ALPHA_TEST" , mOptions.enableAlphaTest ? "1" : "0");
    defines.add("EVAL_DELTA_PDFS", mOptions.evaluateDeltaPDFs ? "1" : "0");
    return defines;
}

void ReSTIR_FG_Plus::RayTraceProgramHelper::initProgramVars(ref<Device> pDevice, ref<Scene> pScene, ref<SampleGenerator> pSampleGenerator)
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
