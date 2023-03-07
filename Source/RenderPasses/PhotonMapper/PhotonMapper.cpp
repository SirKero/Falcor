/***************************************************************************
 # Copyright (c) 2015-21, NVIDIA CORPORATION. All rights reserved.
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
#include "PhotonMapper.h"
#include <RenderGraph/RenderPassHelpers.h>

//for random seed generation
#include <random>
#include <ctime>
#include <limits>

constexpr float kUint32tMaxF = float((uint32_t)-1);

const RenderPass::Info PhotonMapper::kInfo{"RTPhotonMapper", "A Progressive Photon Mapper based on Acceleration Structure Photon Collection" };

// Don't remove this. it's required for hot-reload to function properly
extern "C" FALCOR_API_EXPORT const char* getProjDir()
{
    return PROJECT_DIR;
}

extern "C" FALCOR_API_EXPORT void getPasses(Falcor::RenderPassLibrary & lib)
{
    lib.registerPass(PhotonMapper::kInfo, PhotonMapper::create);
}

namespace
{
    //Shaders
    const char kShaderGeneratePhoton[] = "RenderPasses/PhotonMapper/PhotonMapperGenerate.rt.slang";
    const char kShaderCollectPhoton[] = "RenderPasses/PhotonMapper/PhotonMapperCollect.rt.slang";
    const char kShaderCollectStochasticPhoton[] = "RenderPasses/PhotonMapper/PhotonMapperStochasticCollect.rt.slang";
    const char kShaderPhotonCulling[] = "RenderPasses/PhotonMapper/PhotonCulling.cs.slang";
    const char kShaderDebugShowPhotonAS[] = "RenderPasses/PhotonMapper/showPhotonAccelerationStructure.rt.slang";

    // Ray tracing settings that affect the traversal stack size.
    const uint32_t kMaxPayloadSizeBytes = 80u;
    const uint32_t kMaxPayloadSizeBytesCollect = 48u;
    const uint32_t kMaxAttributeSizeBytes = 8u;
    const uint32_t kMaxRecursionDepth = 2u;

    //Input/Output
    const ChannelList kInputChannels =
    {
        {"vbuffer",             "gVBuffer",                 "V Buffer to get the intersected triangle",         false},
        {"viewW",               "gViewWorld",               "World View Direction",                             false},
        {"thp",                 "gThp",                     "Throughput",                                       false},
        {"emissive",            "gEmissive",                "Emissive",                                         false},
    };

    const ChannelList kOutputChannels =
    {
        { "PhotonImage",          "gPhotonImage",               "An image that shows the caustics and indirect light from global photons" , false , ResourceFormat::RGBA32Float }
    };

    //GUI Dropdowns
    const Gui::DropdownList kInfoTexDropdownList{
        {(uint)PhotonMapper::TextureFormat::_16Bit , "16Bits"},
        {(uint)PhotonMapper::TextureFormat::_32Bit , "32Bits"}
    };

    const Gui::DropdownList kStochasticCollectList{
        {3 , "3"},{7 , "7"}, {11 , "11"},{15 , "15"},
        {19 , "19"},{23 , "23"},{27 , "27"}
    };

    const Gui::DropdownList kLightTexModeList{
        {PhotonMapper::LightTexMode::power , "Power"},
        {PhotonMapper::LightTexMode::area , "Area"}
    };
}

PhotonMapper::SharedPtr PhotonMapper::create(RenderContext* pRenderContext, const Dictionary& dict)
{
    SharedPtr pPass = SharedPtr(new PhotonMapper);
    return pPass;
}

PhotonMapper::PhotonMapper():
    RenderPass(kInfo)
{
    //Create sample generatior object here
    mpSampleGenerator = SampleGenerator::create(SAMPLE_GENERATOR_UNIFORM);
    FALCOR_ASSERT(mpSampleGenerator);
}

Dictionary PhotonMapper::getScriptingDictionary()
{
    return Dictionary();
}

RenderPassReflection PhotonMapper::reflect(const CompileData& compileData)
{
    // Define the required resources here
    RenderPassReflection reflector;

    // Define our input/output channels.
    addRenderPassInputs(reflector, kInputChannels);
    addRenderPassOutputs(reflector, kOutputChannels);

    return reflector;
}

void PhotonMapper::execute(RenderContext* pRenderContext, const RenderData& renderData)
{
    // Update refresh flag if options that affect the output have changed.
    auto& dict = renderData.getDictionary();
    if (mOptionsChanged) {
        auto flags = dict.getValue(kRenderPassRefreshFlags, RenderPassRefreshFlags::None);
        dict[Falcor::kRenderPassRefreshFlags] = flags | Falcor::RenderPassRefreshFlags::RenderOptionsChanged;
        mResetIterations = true;
        mResetConstantBuffers = true;
        mResetTimer = true;
        mOptionsChanged = false;
    }

    //If we have no scene just return
    if (!mpScene)
    {
        return;
    }

    //Reset Frame Count if conditions are met
    if (mResetIterations || mAlwaysResetIterations || is_set(mpScene->getUpdates(), Scene::UpdateFlags::CameraMoved)) {
        mFrameCount = 0;
        mResetIterations = false;
        mResetTimer = true;
    }

    //Check timer and return if render time is over
    checkTimer();
    if (mUseTimer && mTimerStopRenderer) return;

    //Copy Photon Counter for UI
    copyPhotonCounter(pRenderContext);

    //If number of photons were changed in UI, check if photon textures and light sampling texture need to be reset
    if (mNumPhotonsChanged) {
        changeNumPhotons();
        mNumPhotonsChanged = false;
    }

    //Trace mode Acceleration strucutre
    if (mAccelerationStructureFastBuild != mAccelerationStructureFastBuildUI) {
        mAccelerationStructureFastBuild = mAccelerationStructureFastBuildUI;
        mRebuildAS = true;
    }

    //Reset radius
    if (mFrameCount == 0) {
        mCausticRadius = mCausticRadiusStart;
        mGlobalRadius = mGlobalRadiusStart;
    }

    // Request the light collection if emissive lights are enabled.
    if (mpScene->getRenderSettings().useEmissiveLights)
    {
        mpScene->getLightCollection(pRenderContext);
    }

    prepareLighting(pRenderContext);

    if (mResizePhotonBuffers) {
        //Fits the buffer with the user defined offset percentage
        if (mFitBuffersToPhotonShot) {
            //If there are no photons ignore
            if (mPhotonCount[0] > 0 && mPhotonCount[1] > 0) {
                mCausticBufferSizeUI = static_cast<uint>(mPhotonCount[0] * mPhotonBufferOverestimate);
                mGlobalBufferSizeUI = static_cast<uint>(mPhotonCount[1] * mPhotonBufferOverestimate);
            }
            mFitBuffersToPhotonShot = false;
        }
        //Put in new size with info tex2D height in mind. The height (Y) is currently fixed. 
        uint causticWidth = static_cast<uint>(std::ceil(mCausticBufferSizeUI / static_cast<float>(kInfoTexHeight)));
        mCausticBuffers.maxSize = causticWidth * kInfoTexHeight;
        uint globalWidth = static_cast<uint>(std::ceil(mGlobalBufferSizeUI / static_cast<float>(kInfoTexHeight)));
        mGlobalBuffers.maxSize = globalWidth * kInfoTexHeight;

        //Refresh UI with new photon count
        mCausticBufferSizeUI = mCausticBuffers.maxSize; mGlobalBufferSizeUI = mGlobalBuffers.maxSize;
        mResizePhotonBuffers = false;
        mPhotonBuffersReady = false;
        mRebuildAS = true;
    }

    //Rebuild the photon info textures if the format was changed
    if (mPhotonBuffersReady && mPhotonInfoFormatChanged) {
        preparePhotonInfoTexture();
        mPhotonInfoFormatChanged = false;
    }

    // Build/Rebuild all photon buffers (AABB, Info Textures)
    if (!mPhotonBuffersReady) {
        mPhotonBuffersReady = preparePhotonBuffers();
    }

    //Build random starting seeds for the sample generator. 
    if (!mRandNumSeedBuffer) {
        prepareRandomSeedBuffer(renderData.getDefaultTextureDims());
    }

    //Create / Rebuild light sample texture
    /*
    if (!mLightSampleTex || mRebuildLightTex) {
        createLightSampleTexture(pRenderContext);
        mRebuildLightTex = false;
    }
    */

    //Build / Rebuild Buffer for photon culling
    if (mEnablePhotonCulling && (!mCullingBuffer || mRebuildCullingBuffer)) {
        initPhotonCulling(pRenderContext, renderData.getDefaultTextureDims());
        mRebuildCullingBuffer = false;
    }
        
    //Reset culling buffer if deactivated to save memory
    if (!mEnablePhotonCulling && mCullingBuffer)
        resetCullingVars();

    // Create or Rebuild Acceleration Structure
    if (mRebuildAS)
        createAccelerationStructure(pRenderContext);

    //
    // Photon Culling Pre-Pass
    //

    if (mEnablePhotonCulling)
        photonCullingPass(pRenderContext, renderData);

    //
    // Photon Generation Pass
    //

    generatePhotons(pRenderContext, renderData);


    //Barrier for the AABB buffers (they need to be ready for Acceleration Structure Building)
    pRenderContext->uavBarrier(mGlobalBuffers.aabb.get());
    pRenderContext->uavBarrier(mCausticBuffers.aabb.get());

    //
    // Build BLAS and TLAS Pass
    //

    //Take photon count from last iteration as a basis for this iteration. For first iteration take max buffer size
    mPhotonAccelSizeLastIt = {static_cast<uint>(mPhotonCount[0] * mPhotonBufferOverestimate), static_cast<uint>(mPhotonCount[1] * mPhotonBufferOverestimate)};
    if (mFrameCount == 0) { mPhotonAccelSizeLastIt[0] = mCausticBuffers.maxSize; mPhotonAccelSizeLastIt[1] = mGlobalBuffers.maxSize; }

    buildBottomLevelAS(pRenderContext, mPhotonAccelSizeLastIt);
    buildTopLevelAS(pRenderContext);

    //Debug pass to visualize photons from acceleration structure
    if (mUsePhotonASDebugPass) {
        photonASDebugPass(pRenderContext, renderData);
        //Skip the collection and radius reduction if enabled
        return;
    }

    //
    // Photon Collection Pass
    //

    collectPhotons(pRenderContext, renderData);

    mFrameCount++;

    //Reduce radius with formula by Knaus & Zwicker (2011)
    if (mUseStatisticProgressivePM) {
        float itF = static_cast<float>(mFrameCount);
        mGlobalRadius *= sqrt((itF + mSPPMAlphaGlobal) / (itF + 1.0f));
        mCausticRadius *= sqrt((itF + mSPPMAlphaCaustic) / (itF + 1.0f));

        //Clamp to min radius
        mGlobalRadius = std::max(mGlobalRadius, kMinPhotonRadius);
        mCausticRadius = std::max(mCausticRadius, kMinPhotonRadius);
    }

    //Set to false, as all passes have resetted the constant buffers at this point
    if (mResetConstantBuffers) mResetConstantBuffers = false;
}

void PhotonMapper::renderUI(Gui::Widgets& widget)
{
    float2 dummySpacing = float2(0, 10);
    bool dirty = false;

    //Info
    widget.text("Iterations: " + std::to_string(mFrameCount));
    widget.text("Caustic Photons: " + std::to_string(mPhotonCount[0]) + " / " + std::to_string(mPhotonAccelSizeLastIt[0]) + " / " + std::to_string(mCausticBuffers.maxSize));
    widget.tooltip("Photons for current Iteration / Build Size Acceleration Structure / Max Buffer Size");
    widget.text("Global Photons: " + std::to_string(mPhotonCount[1]) + " / " + std::to_string(mPhotonAccelSizeLastIt[1]) + " / " + std::to_string(mGlobalBuffers.maxSize));
    widget.tooltip("Photons for current Iteration / Build Size Acceleration Structure / Max Buffer Size");

    widget.text("Current Global Radius: " + std::to_string(mGlobalRadius));
    widget.text("Current Caustic Radius: " + std::to_string(mCausticRadius));

    widget.dummy("", dummySpacing);
    widget.var("Number Photons", mNumPhotonsUI, 1000u, UINT_MAX, 1000u);
    widget.tooltip("The number of photons that are shot per iteration. Press \"Apply\" to apply the change");
    widget.var("Max Size Caustic Buffer", mCausticBufferSizeUI, 1000u, UINT_MAX, 1000u);
    widget.var("Max Size Global Buffer", mGlobalBufferSizeUI, 1000u, UINT_MAX, 1000u);
    widget.var("Overestimate size(%)", mPhotonBufferOverestimate, 1.0f, 5.0f, 0.0001f);
    widget.tooltip("Percentage of overestimation for the acceleration structure build and photon buffer fitting");
    mNumPhotonsChanged |= widget.button("Apply");
    widget.dummy("", float2(15, 0), true);
    mFitBuffersToPhotonShot |= widget.button("Fit Max Size", true);
    widget.tooltip("Fitts the Caustic and Global Buffer to current number of photons shot *  Photon extra space.This is reccomended for better Performance when moving around");
    widget.dummy("", dummySpacing);

    //If fit buffers is triggered, also trigger the photon change routine
    mNumPhotonsChanged |= mFitBuffersToPhotonShot;

    //Progressive PM
    dirty |= widget.checkbox("Use SPPM", mUseStatisticProgressivePM);
    widget.tooltip("Activate Statistically Progressive Photon Mapping");

    if (mUseStatisticProgressivePM) {
        dirty |= widget.var("Global Alpha", mSPPMAlphaGlobal, 0.1f, 1.0f, 0.001f);
        widget.tooltip("Sets the Alpha in SPPM for the Global Photons");
        dirty |= widget.var("Caustic Alpha", mSPPMAlphaCaustic, 0.1f, 1.0f, 0.001f);
        widget.tooltip("Sets the Alpha in SPPM for the Caustic Photons");
    }

    widget.dummy("", dummySpacing);
    //miscellaneous
    dirty |= widget.slider("Max Recursion Depth", mMaxBounces, 1u, 32u);
    widget.tooltip("Maximum path length for Photon Bounces");
    dirty |= widget.checkbox("Use Photon Face Normal Rejection", mUseFaceNormalToReject);
    widget.tooltip("Uses encoded Face Normal to reject photon hits on different surfaces (corners / other side of wall). Is around 2% slower");

    dirty |= widget.checkbox("Generation store non delta", mGenerationDeltaRejection);
    widget.tooltip("Interpret every non delta reflection as diffuse surface");

    dirty |= widget.slider("Max Caustic Bounces", mMaxCausticBounces, 0, 32);
    widget.tooltip("Diffuse bounces where a caustic still counts as caustic");

    dirty |= widget.var("Photon Ray TMin", mPhotonRayTMin, 0.0001f, 100.f, 0.0001f);
    widget.tooltip("Sets the tMin value for the photon generation pass");
    widget.dummy("", dummySpacing);

    //Timer
    if (auto group = widget.group("Timer")) {
        bool resetTimer = false;
        resetTimer |= widget.checkbox("Enable Timer", mUseTimer);
        widget.tooltip("Enables the timer");
        if (mUseTimer) {
            uint sec = static_cast<uint>(mTimerDurationSec);
            if (sec != 0) widget.text("Elapsed seconds: " + std::to_string(mCurrentElapsedTime) + " / " + std::to_string(sec));
            if (mTimerMaxIterations != 0) widget.text("Iterations: " + std::to_string(mFrameCount) + " / " + std::to_string(mTimerMaxIterations));
            resetTimer |= widget.var("Timer Seconds", sec, 0u, UINT_MAX, 1u);
            widget.tooltip("Time in seconds needed to stop rendering. When 0 time is not used");
            resetTimer |= widget.var("Max Iterations", mTimerMaxIterations, 0u, UINT_MAX, 1u);
            widget.tooltip("Max iterations until stop. When 0 iterations are not used");
            mTimerDurationSec = static_cast<double>(sec);
            resetTimer |= widget.checkbox("Record Times", mTimerRecordTimes);
            resetTimer |= widget.button("Reset Timer");
            if (mTimerRecordTimes) {
                if (widget.button("Store Times", true)) {
                    FileDialogFilterVec filters;
                    filters.push_back({ "csv", "CSV Files" });
                    std::filesystem::path path;
                    if (saveFileDialog(filters, path))
                    {
                        mTimesOutputFilePath = path.string();
                        outputTimes();
                    }
                }
            }
        }
        mResetTimer |= resetTimer;
        dirty |= resetTimer;
    }

    //Radius settings
    if (auto group = widget.group("Radius Options")) {
        dirty |= widget.var("Caustic Radius Start", mCausticRadiusStart, kMinPhotonRadius, FLT_MAX, 0.001f);
        widget.tooltip("The start value for the radius of caustic Photons");
        dirty |= widget.var("Global Radius Start", mGlobalRadiusStart, kMinPhotonRadius, FLT_MAX, 0.001f);
        widget.tooltip("The start value for the radius of global Photons");
        dirty |= widget.var("Rejection Probability", mRejectionProbability, 0.001f, 1.f, 0.001f);
        widget.tooltip("Probabilty that a Global Photon is saved");
    }
    //Material Settings
    if (auto group = widget.group("Material Options")) {
        dirty |= widget.var("Emissive Scalar", mIntensityScalar, 0.0f, FLT_MAX, 0.001f);
        widget.tooltip("Scales the intensity of all emissive Light Sources");
        dirty |= widget.var("SpecRoughCutoff", mSpecRoughCutoff, 0.0f, 1.0f, 0.01f);
        widget.tooltip("The cutoff for Specular Materials. All Reflections above this threshold are considered Diffuse");
        dirty |= widget.checkbox("Alpha Test", mUseAlphaTest);
        widget.tooltip("Enables Alpha Test for Photon Generation");
        dirty |= widget.checkbox("Adjust Shading Normals", mAdjustShadingNormals);
        widget.tooltip("Adjusts the shading normals in the Photon Generation");
    }
    //Culling Settings
    if (auto group = widget.group("Photon Culling")) {
        dirty |= widget.checkbox("Enable Photon Culling", mEnablePhotonCulling);
        widget.tooltip("Enables photon culling. For reflected pixels outside of the camera frustrum ray tracing is used.");
        mRebuildCullingBuffer |= widget.slider("Culling Buffer Size", mCullingHashBufferSizeBytes, 10u, 32u);
        widget.tooltip("Size of the hash buffer. 2^x");
        bool projMatrix = widget.checkbox("Use Projection Matrix", mUseProjectionMatrixCulling);
        widget.tooltip("Uses Projection Matrix additionally for culling");
        if (mUseProjectionMatrixCulling) {
            dirty |= widget.var("Culling Projection Test Value", mPCullingrojectionTestOver, 1.0f, 1.5f, 0.001f);
            widget.tooltip("Value used for the test with the projected postions. Any absolute value above is culled for the xy coordinate.");
        }
        if (projMatrix)
            mPhotonCullingPass.reset();

        dirty |= mRebuildCullingBuffer | projMatrix;
    }

    //Stochastic Collect settings
    if (auto group = widget.group("Stochastic Collect")) {
        dirty |= widget.checkbox("Use Stochastic Collection", mEnableStochasticCollect);
        widget.tooltip("Enables Stochastic Collection. Photon indices are saved in payload and collected later");
        if (mEnableStochasticCollect) {
            float4 colorRed = float4(1, 0, 0, 1);
            float4 colorGreen = float4(0, 1, 0, 1);
            bool isUsed = ((mFrameCount < mStochasticIterations) || mStochasticIterations == 0);
            widget.text("Is Used: ");
            widget.rect(float2(17.5f), isUsed ? colorGreen : colorRed, true, true);
            widget.text("");
            dirty |= widget.var("Stochastic Iterations", mStochasticIterations, 0u, UINT32_MAX, 1u);
            widget.tooltip("Number of stochastic iterations. When exeeded full Collection is used");
            dirty |= widget.dropdown("Max Photons", kStochasticCollectList, mMaxNumberPhotonsSCUI);
            widget.tooltip("Size of the photon buffer in payload");

        }
    }

    //AC Settings
    if (auto group = widget.group("Acceleration Structure Settings")) {
        dirty |= widget.checkbox("Fast Build", mAccelerationStructureFastBuildUI);
        widget.tooltip("Enables Fast Build for Acceleration Structure. If enabled tracing time is worse");
    }

    //Disable Photon Collection
    if (auto group = widget.group("Disable Photon Collect")) {
        dirty |= widget.checkbox("Disable Global Photons", mDisableGlobalCollection);
        widget.tooltip("Disables the collection of Global Photons. However they will still be generated");
        dirty |= widget.checkbox("Disable Caustic Photons", mDisableCausticCollection);
        widget.tooltip("Disables the collection of Caustic Photons. However they will still be generated");
    }

    //Debug View
    if (auto group = widget.group("Debug View AS")) {
        dirty |= widget.checkbox("Activate", mUsePhotonASDebugPass);

        mCopyToDebugCamera = widget.button("Copy main camera");
    }

    mPhotonInfoFormatChanged |= widget.dropdown("Photon Info size", kInfoTexDropdownList, mInfoTexFormat);
    widget.tooltip("Determines the resolution of each element of the photon info struct.");

    dirty |= mPhotonInfoFormatChanged;  //Reset iterations if format is changed

    widget.dummy("", dummySpacing);
    //Reset Iterations
    widget.checkbox("Always Reset Iterations", mAlwaysResetIterations);
    widget.tooltip("Always Resets the Iterations, currently good for moving the camera");
    mResetIterations |= widget.button("Reset Iterations");
    widget.tooltip("Resets the iterations");
    dirty |= mResetIterations;

    //set flag to indicate that settings have changed and the pass has to be rebuild
    if (dirty)
        mOptionsChanged = true;
}

void PhotonMapper::setScene(RenderContext* pRenderContext, const Scene::SharedPtr& pScene)
{
    // Clear data for previous scene.
    resetPhotonMapper();
    resetCullingVars();

    // After changing scene, the raytracing program should to be recreated.
    mTracerGenerate = RayTraceProgramHelper::create();
    mPhotonASDebugPass = RayTraceProgramHelper::create();
    mResetConstantBuffers = true;
    if (mEnablePhotonCulling) mRebuildCullingBuffer = true;
    // Set new scene.
    mpScene = pScene;

    if (mpScene)
    {
        if (mpScene->hasGeometryType(Scene::GeometryType::Custom))
        {
            logWarning("This render pass only supports triangles. Other types of geometry will be ignored.");
        }

        // Create ray tracing program.
        {
            RtProgram::Desc desc;
            desc.addShaderLibrary(kShaderGeneratePhoton);
            desc.setMaxPayloadSize(kMaxPayloadSizeBytes);
            desc.setMaxAttributeSize(kMaxAttributeSizeBytes);
            desc.setMaxTraceRecursionDepth(kMaxRecursionDepth);

            mTracerGenerate.pBindingTable = RtBindingTable::create(1, 1, mpScene->getGeometryCount());
            auto& sbt = mTracerGenerate.pBindingTable;
            sbt->setRayGen(desc.addRayGen("rayGen"));
            sbt->setMiss(0, desc.addMiss("miss"));
            if (mpScene->hasGeometryType(Scene::GeometryType::TriangleMesh)) {
                sbt->setHitGroup(0, mpScene->getGeometryIDs(Scene::GeometryType::TriangleMesh), desc.addHitGroup("closestHit", "anyHit"));
            }

            mTracerGenerate.pProgram = RtProgram::create(desc, mpScene->getSceneDefines());
        }

        //Create the photon collect programm
        createCollectionProgram();
    }

    //init the photon counters
    preparePhotonCounters();
}

void PhotonMapper::prepareVars()
{
    FALCOR_ASSERT(mTracerGenerate.pProgram);

    // Configure program.
    mTracerGenerate.pProgram->addDefines(mpSampleGenerator->getDefines());
    mTracerGenerate.pProgram->addDefines(mpEmissiveLightSampler->getDefines());
    mTracerGenerate.pProgram->setTypeConformances(mpScene->getTypeConformances());
    // Create program variables for the current program.
    // This may trigger shader compilation. If it fails, throw an exception to abort rendering.
    mTracerGenerate.pVars = RtProgramVars::create(mTracerGenerate.pProgram, mTracerGenerate.pBindingTable);

    // Bind utility classes into shared data.
    auto var = mTracerGenerate.pVars->getRootVar();
    mpSampleGenerator->setShaderData(var);
}

//Gets the resource format from our format enum that is used in UI
ResourceFormat inline getFormatRGBA(uint format)
{
    switch (format) {
    case static_cast<uint>(PhotonMapper::TextureFormat::_16Bit):
        return ResourceFormat::RGBA16Float;
    case static_cast<uint>(PhotonMapper::TextureFormat::_32Bit):
        return ResourceFormat::RGBA32Float;
    default:
        return ResourceFormat::RGBA16Float;
    }
}

void PhotonMapper::preparePhotonInfoTexture()
{
    FALCOR_ASSERT(mCausticBuffers.maxSize > 0 || mGlobalBuffers.maxSize > 0);
    //Clean tex
    mCausticBuffers.infoFlux.reset(); mCausticBuffers.infoDir.reset();
    mGlobalBuffers.infoFlux.reset(); mGlobalBuffers.infoDir.reset();

    //Caustic
    mCausticBuffers.infoFlux = Texture::create2D(mCausticBuffers.maxSize / kInfoTexHeight, kInfoTexHeight, getFormatRGBA(mInfoTexFormat), 1, 1, nullptr, ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess);
    mCausticBuffers.infoFlux->setName("PhotonMapper::mCausticBuffers.fluxInfo");
    mCausticBuffers.infoDir = Texture::create2D(mCausticBuffers.maxSize / kInfoTexHeight, kInfoTexHeight, getFormatRGBA(mInfoTexFormat), 1, 1, nullptr, ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess);
    mCausticBuffers.infoDir->setName("PhotonMapper::mCausticBuffers.dirInfo");

    FALCOR_ASSERT(mCausticBuffers.infoFlux); FALCOR_ASSERT(mCausticBuffers.infoDir);

    //Global
    mGlobalBuffers.infoFlux = Texture::create2D(mGlobalBuffers.maxSize / kInfoTexHeight, kInfoTexHeight, getFormatRGBA(mInfoTexFormat), 1, 1, nullptr, ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess);
    mGlobalBuffers.infoFlux->setName("PhotonMapper::mGlobalBuffers.fluxInfo");
    mGlobalBuffers.infoDir = Texture::create2D(mGlobalBuffers.maxSize / kInfoTexHeight, kInfoTexHeight, getFormatRGBA(mInfoTexFormat), 1, 1, nullptr, ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess);
    mGlobalBuffers.infoDir->setName("PhotonMapper::mGlobalBuffers.dirInfo");

    FALCOR_ASSERT(mGlobalBuffers.infoFlux); FALCOR_ASSERT(mGlobalBuffers.infoDir);
}

bool PhotonMapper::preparePhotonBuffers()
{
    FALCOR_ASSERT(mCausticBuffers.maxSize > 0 || mGlobalBuffers.maxSize > 0);


    //clean buffers
    mCausticBuffers.aabb.reset(); mCausticBuffers.blas.reset();
    mGlobalBuffers.aabb.reset(); mGlobalBuffers.blas.reset();

    //Create AABB buffers
    mCausticBuffers.aabb = Buffer::createStructured(sizeof(D3D12_RAYTRACING_AABB), mCausticBuffers.maxSize);
    mCausticBuffers.aabb->setName("PhotonMapper::mCausticBuffers.aabb");

    FALCOR_ASSERT(mCausticBuffers.aabb);

    mGlobalBuffers.aabb = Buffer::createStructured(sizeof(D3D12_RAYTRACING_AABB), mGlobalBuffers.maxSize);
    mGlobalBuffers.aabb->setName("PhotonMapper::mGlobalBuffers.aabb");

    FALCOR_ASSERT(mGlobalBuffers.aabb);

    //Create the rest of the info textures
    preparePhotonInfoTexture();

    return true;
}

void PhotonMapper::preparePhotonCounters()
{
    //Create a Counter with a Reset Buffer. 
    mPhotonCounterBuffer.counter = Buffer::createStructured(sizeof(uint), 2);
    mPhotonCounterBuffer.counter->setName("PhotonMapper::PhotonCounter");
    uint64_t zeroInit = 0;
    mPhotonCounterBuffer.reset = Buffer::create(sizeof(uint64_t), ResourceBindFlags::None, Buffer::CpuAccess::None, &zeroInit);
    mPhotonCounterBuffer.reset->setName("PhotonMapper::PhotonCounterReset");
    //A CPU buffer to copy to for UI and Buffer fitting
    uint32_t oneInit[2] = { 1,1 };
    mPhotonCounterBuffer.cpuCopy = Buffer::create(sizeof(uint64_t), ResourceBindFlags::None, Buffer::CpuAccess::Read, oneInit);
    mPhotonCounterBuffer.cpuCopy->setName("PhotonMapper::PhotonCounterCPU");
}

void PhotonMapper::resetPhotonMapper()
{
    mFrameCount = 0;

    //For Photon Buffers and resize
    mResizePhotonBuffers = true; mPhotonBuffersReady = false;
    mCausticBuffers.maxSize = 0; mGlobalBuffers.maxSize = 0;
    mPhotonCount[0] = 0; mPhotonCount[1] = 0;
    mCullingBuffer.reset();

    //reset light sample tex
    mpEmissiveLightSampler.reset();
}

void PhotonMapper::changeNumPhotons()
{
    //If photon number differ reset the light sample texture
    if (mNumPhotonsUI != mNumPhotons) {
        //Reset light sample tex and frame counter
        mNumPhotons = mNumPhotonsUI;
        mFrameCount = 0;
    }

    if (mGlobalBuffers.maxSize != mGlobalBufferSizeUI || mCausticBuffers.maxSize != mCausticBufferSizeUI || mFitBuffersToPhotonShot) {
        mResizePhotonBuffers = true; mPhotonBuffersReady = false;
        mCausticBuffers.maxSize = 0; mGlobalBuffers.maxSize = 0;
    }

}

void PhotonMapper::copyPhotonCounter(RenderContext* pRenderContext)
{
    //Copy the photonConter to a CPU Buffer
    pRenderContext->copyBufferRegion(mPhotonCounterBuffer.cpuCopy.get(), 0, mPhotonCounterBuffer.counter.get(), 0, sizeof(uint32_t) * 2);

    void* data = mPhotonCounterBuffer.cpuCopy->map(Buffer::MapType::Read);
    std::memcpy(mPhotonCount.data(), data, sizeof(uint) * 2);
    mPhotonCounterBuffer.cpuCopy->unmap();
}

void PhotonMapper::generatePhotons(RenderContext* pRenderContext, const RenderData& renderData)
{
    FALCOR_PROFILE("Generation_Pass");

    //Reset counter Buffers
    pRenderContext->copyBufferRegion(mPhotonCounterBuffer.counter.get(), 0, mPhotonCounterBuffer.reset.get(), 0, sizeof(uint64_t));
    pRenderContext->resourceBarrier(mPhotonCounterBuffer.counter.get(), Resource::State::ShaderResource);

    //Clear the photon Buffers
    pRenderContext->clearUAV(mGlobalBuffers.aabb.get()->getUAV().get(), uint4(0, 0, 0, 0));
    pRenderContext->clearTexture(mGlobalBuffers.infoFlux.get(), float4(0, 0, 0, 0));
    pRenderContext->clearTexture(mGlobalBuffers.infoDir.get(), float4(0, 0, 0, 0));
    pRenderContext->clearUAV(mCausticBuffers.aabb.get()->getUAV().get(), uint4(0, 0, 0, 0));
    pRenderContext->clearTexture(mCausticBuffers.infoFlux.get(), float4(0, 0, 0, 0));
    pRenderContext->clearTexture(mCausticBuffers.infoDir.get(), float4(0, 0, 0, 0));


    auto lights = mpScene->getLights();
    auto lightCollection = mpScene->getLightCollection(pRenderContext);

    // Specialize the Generate program.
    //Changing these will trigger shader compilation
    mTracerGenerate.pProgram->addDefine("USE_ANALYTIC_LIGHTS", mpScene->useAnalyticLights() ? "1" : "0");
    mTracerGenerate.pProgram->addDefine("USE_EMISSIVE_LIGHTS", mpScene->useEmissiveLights() ? "1" : "0");
    mTracerGenerate.pProgram->addDefine("USE_ENV_LIGHT", mpScene->useEnvLight() ? "1" : "0");
    mTracerGenerate.pProgram->addDefine("USE_ENV_BACKGROUND", mpScene->useEnvBackground() ? "1" : "0");
    mTracerGenerate.pProgram->addDefine("MAX_PHOTON_INDEX_GLOBAL", std::to_string(mGlobalBuffers.maxSize));
    mTracerGenerate.pProgram->addDefine("MAX_PHOTON_INDEX_CAUSTIC", std::to_string(mCausticBuffers.maxSize));
    mTracerGenerate.pProgram->addDefine("INFO_TEXTURE_HEIGHT", std::to_string(kInfoTexHeight));
    mTracerGenerate.pProgram->addDefine("RAY_TMAX", std::to_string(1000.f));    //TODO: Set as variable
    mTracerGenerate.pProgram->addDefine("RAY_TMIN_CULLING", std::to_string(kCollectTMin));
    mTracerGenerate.pProgram->addDefine("RAY_TMAX_CULLING", std::to_string(kCollectTMax));
    mTracerGenerate.pProgram->addDefine("CULLING_USE_PROJECTION", std::to_string(mUseProjectionMatrixCulling));
    mTracerGenerate.pProgram->addDefine("PHOTON_FACE_NORMAL", mUseFaceNormalToReject ? "1" : "0");
    mTracerGenerate.pProgram->addDefine("PHOTON_BUFFER_SIZE_GLOBAL", std::to_string(mGlobalBuffers.maxSize));
    mTracerGenerate.pProgram->addDefine("PHOTON_BUFFER_SIZE_CAUSTIC", std::to_string(mCausticBuffers.maxSize));
    mTracerGenerate.pProgram->addDefine("USE_PHOTON_CULLING", mEnablePhotonCulling ? "1" : "0");


    FALCOR_ASSERT(mpEmissiveLightSampler);
    if (!mTracerGenerate.pVars) prepareVars();
    FALCOR_ASSERT(mTracerGenerate.pVars);

    auto& dict = renderData.getDictionary();

    auto var = mTracerGenerate.pVars->getRootVar();

    mpEmissiveLightSampler->setShaderData(var["Light"]["gEmissiveSampler"]);

    // Set constants (uniforms).
    // 
    //PerFrame Constant Buffer
    std::string nameBuf = "PerFrame";
    var[nameBuf]["gFrameCount"] = mFrameCount;
    var[nameBuf]["gPhotonRadius"] = float2(mCausticRadius, mGlobalRadius);
    var[nameBuf]["gHashScaleFactor"] = 1.0f / (mGlobalRadius * 2);  //Radius needs to be double to ensure that all photons from the camera cell are in it

    //Upload constant buffer only if options changed
    if (mResetConstantBuffers) {
        nameBuf = "CB";
        //Fill flags
        uint flags = 0;
        if (mUseAlphaTest) flags |= 0x01;
        if (mAdjustShadingNormals) flags |= 0x02;
        if (mGenerationDeltaRejection) flags |= 0x08;

        var[nameBuf]["gMaxRecursion"] = mMaxBounces;
        var[nameBuf]["gRejection"] = mRejectionProbability;
        var[nameBuf]["gFlags"] = flags;
        var[nameBuf]["gHashSize"] = 1 << mCullingHashBufferSizeBytes;    //Size of the Photon Culling buffer. 2^x
        var[nameBuf]["gCausticsBounces"] = mMaxCausticBounces;
        var[nameBuf]["gCullingYExtent"] = mCullingYExtent;
        var[nameBuf]["gRayTMin"] = mPhotonRayTMin;
    }

    //set the Photon Buffers
    for (uint32_t i = 0; i <= 1; i++)
    {
        var["gPhotonAABB"][i] = i == 0 ? mCausticBuffers.aabb : mGlobalBuffers.aabb;
        var["gPhotonFlux"][i] = i == 0 ? mCausticBuffers.infoFlux : mGlobalBuffers.infoFlux;
        var["gPhotonDir"][i] = i == 0 ? mCausticBuffers.infoDir : mGlobalBuffers.infoDir;
    }

    //Rest of the buffers
    var["gPhotonCounter"] = mPhotonCounterBuffer.counter;

    //Set optinal culling variables
    if (mEnablePhotonCulling) {
        var["gCullingHashBuffer"] = mCullingBuffer;
    }

    // Get dimensions of ray dispatch.
    const uint2 targetDim = uint2(mNumPhotons / mPhotonYExtent, mPhotonYExtent);
    FALCOR_ASSERT(targetDim.x > 0 && targetDim.y > 0);

    //Trace the photons
    mpScene->raytrace(pRenderContext, mTracerGenerate.pProgram.get(), mTracerGenerate.pVars, uint3(targetDim, 1));
}

void PhotonMapper::collectPhotons(RenderContext* pRenderContext, const RenderData& renderData)
{
    FALCOR_PROFILE("Collect_Pass");

    //Check if stochastic collect variables have changed
    if (mMaxNumberPhotonsSC != mMaxNumberPhotonsSCUI) {
        //Rebuild program
        mMaxNumberPhotonsSC = mMaxNumberPhotonsSCUI;
        createCollectionProgram();
    }

    bool useStochasticCollect = ((mFrameCount < mStochasticIterations) || mStochasticIterations == 0) && mEnableStochasticCollect;
    bool shadersSwitched = mFrameCount == mStochasticIterations && mEnableStochasticCollect;

    // Full Collect
    //************************************
    mTracerCollect.pProgram->addDefines(getValidResourceDefines(kInputChannels, renderData));
    mTracerCollect.pProgram->addDefines(getValidResourceDefines(kOutputChannels, renderData));
    mTracerCollect.pProgram->addDefine("RAY_TMIN", std::to_string(kCollectTMin));
    mTracerCollect.pProgram->addDefine("RAY_TMAX", std::to_string(kCollectTMax));
    mTracerCollect.pProgram->addDefine("INFO_TEXTURE_HEIGHT", std::to_string(kInfoTexHeight));
    mTracerCollect.pProgram->addDefine("PHOTON_FACE_NORMAL", mUseFaceNormalToReject ? "1" : "0");

    // Prepare program for full collect vars. This may trigger shader compilation.
    if (!mTracerCollect.pVars) {
        FALCOR_ASSERT(mTracerCollect.pProgram);
        mTracerCollect.pProgram->addDefines(mpSampleGenerator->getDefines());
        mTracerCollect.pProgram->setTypeConformances(mpScene->getTypeConformances());
        mTracerCollect.pVars = RtProgramVars::create(mTracerCollect.pProgram, mTracerCollect.pBindingTable);
        // Bind utility classes into shared data.
        auto var = mTracerCollect.pVars->getRootVar();
        mpSampleGenerator->setShaderData(var);
    }
    FALCOR_ASSERT(mTracerCollect.pVars);
    //************************************

    //Stochastic Collect
    //************************************
    mTracerStochasticCollect.pProgram->addDefines(getValidResourceDefines(kInputChannels, renderData));
    mTracerStochasticCollect.pProgram->addDefines(getValidResourceDefines(kOutputChannels, renderData));
    mTracerStochasticCollect.pProgram->addDefine("RAY_TMIN", std::to_string(kCollectTMin));
    mTracerStochasticCollect.pProgram->addDefine("RAY_TMAX", std::to_string(kCollectTMax));
    mTracerStochasticCollect.pProgram->addDefine("INFO_TEXTURE_HEIGHT", std::to_string(kInfoTexHeight));
    mTracerStochasticCollect.pProgram->addDefine("NUM_PHOTONS", std::to_string(mMaxNumberPhotonsSC));
    mTracerStochasticCollect.pProgram->addDefine("PHOTON_FACE_NORMAL", mUseFaceNormalToReject ? "1" : "0");

    // Prepare program for full collect vars. This may trigger shader compilation.
    if (!mTracerStochasticCollect.pVars) {
        FALCOR_ASSERT(mTracerStochasticCollect.pProgram);
        mTracerStochasticCollect.pProgram->addDefines(mpSampleGenerator->getDefines());
        mTracerStochasticCollect.pProgram->setTypeConformances(mpScene->getTypeConformances());
        mTracerStochasticCollect.pVars = RtProgramVars::create(mTracerStochasticCollect.pProgram, mTracerStochasticCollect.pBindingTable);
        // Bind utility classes into shared data.
        auto var = mTracerStochasticCollect.pVars->getRootVar();
        mpSampleGenerator->setShaderData(var);
    }
    FALCOR_ASSERT(mTracerStochasticCollect.pVars);
    //************************************

    auto& collectPass = useStochasticCollect ? mTracerStochasticCollect : mTracerCollect;
    auto var = collectPass.pVars->getRootVar();

    // Set constants. (Uniforms)

    //Per frame
    std::string nameBuf = "PerFrame";
    var[nameBuf]["gFrameCount"] = mFrameCount;
    var[nameBuf]["gCausticRadius"] = mCausticRadius;
    var[nameBuf]["gGlobalRadius"] = mGlobalRadius;

    //Constants. Are only set when values changed or shaders switched
    if (mResetConstantBuffers || shadersSwitched) {
        nameBuf = "CB";
        var[nameBuf]["gEmissiveScale"] = mIntensityScalar;
        var[nameBuf]["gCollectGlobalPhotons"] = !mDisableGlobalCollection;
        var[nameBuf]["gCollectCausticPhotons"] = !mDisableCausticCollection;
    }

    //set the Photon Buffers
    for (uint32_t i = 0; i <= 1; i++)
    {
        var["gPhotonAABB"][i] = i == 0 ? mCausticBuffers.aabb : mGlobalBuffers.aabb;
        var["gPhotonFlux"][i] = i == 0 ? mCausticBuffers.infoFlux : mGlobalBuffers.infoFlux;
        var["gPhotonDir"][i] = i == 0 ? mCausticBuffers.infoDir : mGlobalBuffers.infoDir;
    }
  
    // Lamda for binding textures. These needs to be done per-frame as the buffers may change anytime.
    auto bindAsTex = [&](const ChannelDesc& desc)
    {
        if (!desc.texname.empty())
        {
            var[desc.texname] = renderData[desc.name]->asTexture();
        }
    };

    //Bind input and output textures
    for (auto& channel : kInputChannels) bindAsTex(channel);
    bindAsTex(kOutputChannels[0]);

    //bind TLAS
    bool tlasValid = var["gPhotonAS"].setSrv(mPhotonTlas.pSrv);
    FALCOR_ASSERT(tlasValid);

    // Get dimensions of ray dispatch.
    const uint2 targetDim = renderData.getDefaultTextureDims();
    FALCOR_ASSERT(targetDim.x > 0 && targetDim.y > 0);

    FALCOR_ASSERT(pRenderContext && collectPass.pProgram && collectPass.pVars);

    //Collect photons
    mpScene->raytrace(pRenderContext, collectPass.pProgram.get(), collectPass.pVars, uint3(targetDim, 1));
}

void PhotonMapper::createAccelerationStructure(RenderContext* pContext)
{
    //clear all previous data
    if (mRebuildAS) {
        mBlasData.clear();
        mPhotonInstanceDesc.clear();
        mTlasScratch = nullptr;
        mPhotonTlas.pInstanceDescs = nullptr; mPhotonTlas.pSrv = nullptr; mPhotonTlas.pTlas = nullptr;
    }
    //Reset scratch max size here
    mBlasScratchMaxSize = 0; mTlasScratchMaxSize = 0;

    createBottomLevelAS(pContext);
    createTopLevelAS(pContext);

    if (mRebuildAS) mRebuildAS = false;

}

void PhotonMapper::createTopLevelAS(RenderContext* pContext)
{ 
    //fill the instance description if empty
    for (int i = 0; i < 2; i++) {
        D3D12_RAYTRACING_INSTANCE_DESC desc = {};
        desc.AccelerationStructure = i == 0 ? mCausticBuffers.blas->getGpuAddress() : mGlobalBuffers.blas->getGpuAddress();
        desc.Flags = D3D12_RAYTRACING_INSTANCE_FLAG_NONE;
        desc.InstanceID = i;
        desc.InstanceMask = i + 1;  //0b01 for Caustic and 0b10 for Global
        desc.InstanceContributionToHitGroupIndex = 0;

        //Create a identity matrix for the transform and copy it to the instance desc
        glm::mat4 transform4x4 = glm::identity<glm::mat4>();
        std::memcpy(desc.Transform, &transform4x4, sizeof(desc.Transform));
        mPhotonInstanceDesc.push_back(desc);
    }

    D3D12_BUILD_RAYTRACING_ACCELERATION_STRUCTURE_INPUTS inputs = {};
    inputs.Type = D3D12_RAYTRACING_ACCELERATION_STRUCTURE_TYPE_TOP_LEVEL;
    inputs.DescsLayout = D3D12_ELEMENTS_LAYOUT_ARRAY;
    inputs.NumDescs = (uint32_t)mPhotonInstanceDesc.size();
    inputs.Flags = D3D12_RAYTRACING_ACCELERATION_STRUCTURE_BUILD_FLAG_PREFER_FAST_BUILD;

    //Prebuild
    FALCOR_GET_COM_INTERFACE(gpDevice->getApiHandle(), ID3D12Device5, pDevice5);
    pDevice5->GetRaytracingAccelerationStructurePrebuildInfo(&inputs, &mTlasPrebuildInfo);
    mTlasScratch = Buffer::create(std::max(mTlasPrebuildInfo.ScratchDataSizeInBytes, mTlasScratchMaxSize), Buffer::BindFlags::UnorderedAccess, Buffer::CpuAccess::None);
    mTlasScratch->setName("PhotonMapper::TLAS_Scratch");

    //Create buffers for the TLAS
    mPhotonTlas.pTlas = Buffer::create(mTlasPrebuildInfo.ResultDataMaxSizeInBytes, Buffer::BindFlags::AccelerationStructure, Buffer::CpuAccess::None);
    mPhotonTlas.pTlas->setName("PhotonMapper::TLAS");
    mPhotonTlas.pInstanceDescs = Buffer::create((uint32_t)mPhotonInstanceDesc.size() * sizeof(D3D12_RAYTRACING_INSTANCE_DESC), Buffer::BindFlags::None, Buffer::CpuAccess::Write, mPhotonInstanceDesc.data());
    mPhotonTlas.pInstanceDescs->setName("PhotonMapper::TLAS_Instance_Description");

    //Acceleration Structure Buffer view for access in shader
    mPhotonTlas.pSrv = ShaderResourceView::createViewForAccelerationStructure(mPhotonTlas.pTlas);
}

void PhotonMapper::createBottomLevelAS(RenderContext* pContext)
{
    //We have two BLAS. For each photon kind
    mBlasData.resize(2);

    //Prebuild
    for (size_t i = 0; i < mBlasData.size(); i++) {
        auto& blas = mBlasData[i];

        //Create geometry description
        D3D12_RAYTRACING_GEOMETRY_DESC& desc = blas.geomDescs;
        desc.Type = D3D12_RAYTRACING_GEOMETRY_TYPE_PROCEDURAL_PRIMITIVE_AABBS;
        desc.Flags = D3D12_RAYTRACING_GEOMETRY_FLAG_NO_DUPLICATE_ANYHIT_INVOCATION;         //< Important! So that photons are not collected multiple times
        desc.AABBs.AABBCount = i == 0 ? mCausticBuffers.maxSize : mGlobalBuffers.maxSize;
        desc.AABBs.AABBs.StartAddress = i == 0 ? mCausticBuffers.aabb->getGpuAddress() : mGlobalBuffers.aabb->getGpuAddress();
        desc.AABBs.AABBs.StrideInBytes = sizeof(D3D12_RAYTRACING_AABB);

        //Create input for blas
        D3D12_BUILD_RAYTRACING_ACCELERATION_STRUCTURE_INPUTS& inputs = blas.buildInputs;
        inputs.Type = D3D12_RAYTRACING_ACCELERATION_STRUCTURE_TYPE_BOTTOM_LEVEL;
        inputs.DescsLayout = D3D12_ELEMENTS_LAYOUT_ARRAY;
        inputs.NumDescs = 1;
        inputs.pGeometryDescs = &blas.geomDescs;

        //Updating is no option for BLAS as individual photons move to much.
        inputs.Flags = mAccelerationStructureFastBuild ? D3D12_RAYTRACING_ACCELERATION_STRUCTURE_BUILD_FLAG_PREFER_FAST_BUILD : D3D12_RAYTRACING_ACCELERATION_STRUCTURE_BUILD_FLAG_PREFER_FAST_TRACE;
        //get prebuild Info
        FALCOR_GET_COM_INTERFACE(gpDevice->getApiHandle(), ID3D12Device5, pDevice5);
        pDevice5->GetRaytracingAccelerationStructurePrebuildInfo(&blas.buildInputs, &blas.prebuildInfo);

        // Figure out the padded allocation sizes to have proper alignment.
        FALCOR_ASSERT(blas.prebuildInfo.ResultDataMaxSizeInBytes > 0);
        blas.blasByteSize = align_to((uint64_t)D3D12_RAYTRACING_ACCELERATION_STRUCTURE_BYTE_ALIGNMENT, blas.prebuildInfo.ResultDataMaxSizeInBytes);

        uint64_t scratchByteSize = std::max(blas.prebuildInfo.ScratchDataSizeInBytes, blas.prebuildInfo.UpdateScratchDataSizeInBytes);
        blas.scratchByteSize = align_to((uint64_t)D3D12_RAYTRACING_ACCELERATION_STRUCTURE_BYTE_ALIGNMENT, scratchByteSize);

        mBlasScratchMaxSize = std::max(blas.scratchByteSize, mBlasScratchMaxSize);
    }

    //Create the scratch and blas buffers
    mBlasScratch = Buffer::create(mBlasScratchMaxSize, Buffer::BindFlags::UnorderedAccess, Buffer::CpuAccess::None);
    mBlasScratch->setName("PhotonMapper::BlasScratch");

    mCausticBuffers.blas = Buffer::create(mBlasData[0].blasByteSize, Buffer::BindFlags::AccelerationStructure, Buffer::CpuAccess::None);
    mCausticBuffers.blas->setName("PhotonMapper::CausticBlasBuffer");

    mGlobalBuffers.blas = Buffer::create(mBlasData[1].blasByteSize, Buffer::BindFlags::AccelerationStructure, Buffer::CpuAccess::None);
    mGlobalBuffers.blas->setName("PhotonMapper::GlobalBlasBuffer");
}

void PhotonMapper::buildTopLevelAS(RenderContext* pContext)
{
    FALCOR_PROFILE("buildPhotonTlas");

    D3D12_BUILD_RAYTRACING_ACCELERATION_STRUCTURE_INPUTS inputs = {};
    inputs.Type = D3D12_RAYTRACING_ACCELERATION_STRUCTURE_TYPE_TOP_LEVEL;
    inputs.DescsLayout = D3D12_ELEMENTS_LAYOUT_ARRAY;
    inputs.NumDescs = (uint32_t)mPhotonInstanceDesc.size();
    //Update Flag could be set for TLAS. This made no real time difference in our test so it is left out. Updating could reduce the memory of the TLAS scratch buffer a bit
    inputs.Flags = mAccelerationStructureFastBuild ? D3D12_RAYTRACING_ACCELERATION_STRUCTURE_BUILD_FLAG_PREFER_FAST_BUILD : D3D12_RAYTRACING_ACCELERATION_STRUCTURE_BUILD_FLAG_PREFER_FAST_TRACE;

    D3D12_BUILD_RAYTRACING_ACCELERATION_STRUCTURE_DESC asDesc = {};
    asDesc.Inputs = inputs;
    asDesc.Inputs.InstanceDescs = mPhotonTlas.pInstanceDescs->getGpuAddress();
    asDesc.ScratchAccelerationStructureData = mTlasScratch->getGpuAddress();
    asDesc.DestAccelerationStructureData = mPhotonTlas.pTlas->getGpuAddress();

    // Create TLAS
    FALCOR_GET_COM_INTERFACE(pContext->getLowLevelData()->getCommandList(), ID3D12GraphicsCommandList4, pList4);
    pContext->resourceBarrier(mPhotonTlas.pInstanceDescs.get(), Resource::State::NonPixelShader);
    pList4->BuildRaytracingAccelerationStructure(&asDesc, 0, nullptr);
    pContext->uavBarrier(mPhotonTlas.pTlas.get());                   //barrier for the tlas so we can use it savely after creation
}

void PhotonMapper::buildBottomLevelAS(RenderContext* pContext, std::array<uint, 2>& aabbCount)
{

    FALCOR_PROFILE("buildPhotonBlas");
    if (!gpDevice->isFeatureSupported(Device::SupportedFeatures::Raytracing))
    {
        throw std::exception("Raytracing is not supported by the current device");
    }

    //aabb buffers need to be ready
    pContext->uavBarrier(mCausticBuffers.aabb.get());
    pContext->uavBarrier(mGlobalBuffers.aabb.get());

    for (size_t i = 0; i < mBlasData.size(); i++) {
        auto& blas = mBlasData[i];

        //barriers for the scratch and blas buffer
        pContext->uavBarrier(mBlasScratch.get());
        pContext->uavBarrier(i == 0 ? mCausticBuffers.blas.get() : mGlobalBuffers.blas.get());

        //add the photon count for this iteration. geomDesc is saved as a pointer in blasInputs
        uint maxPhotons = i == 0 ? mCausticBuffers.maxSize : mGlobalBuffers.maxSize;
        aabbCount[i] = std::min(aabbCount[i], maxPhotons);
        blas.geomDescs.AABBs.AABBCount = static_cast<UINT64>(aabbCount[i]);

        //Fill the build desc struct
        D3D12_BUILD_RAYTRACING_ACCELERATION_STRUCTURE_DESC asDesc = {};
        asDesc.Inputs = blas.buildInputs;
        asDesc.ScratchAccelerationStructureData = mBlasScratch->getGpuAddress();
        asDesc.DestAccelerationStructureData = i == 0 ? mCausticBuffers.blas->getGpuAddress() : mGlobalBuffers.blas->getGpuAddress();

        //Build the acceleration structure
        FALCOR_GET_COM_INTERFACE(pContext->getLowLevelData()->getCommandList(), ID3D12GraphicsCommandList4, pList4);
        pList4->BuildRaytracingAccelerationStructure(&asDesc, 0, nullptr);

        //Barrier for the blas
        pContext->uavBarrier(i == 0 ? mCausticBuffers.blas.get() : mGlobalBuffers.blas.get());
    }
}

void PhotonMapper::prepareRandomSeedBuffer(const uint2 screenDimensions)
{
    FALCOR_ASSERT(screenDimensions.x > 0 && screenDimensions.y > 0);

    //fill a std vector with random seed from the seed_seq
    std::seed_seq seq{ time(0) };
    std::vector<uint32_t> cpuSeeds(screenDimensions.x * screenDimensions.y);
    seq.generate(cpuSeeds.begin(), cpuSeeds.end());

    //create the gpu buffer
    mRandNumSeedBuffer = Texture::create2D(screenDimensions.x, screenDimensions.y, ResourceFormat::R32Uint, 1, 1, cpuSeeds.data());
    mRandNumSeedBuffer->setName("PhotonMapper::RandomSeedBuffer");

    FALCOR_ASSERT(mRandNumSeedBuffer);
}

void PhotonMapper::createCollectionProgram()
{
    //reset program
    mTracerCollect = RayTraceProgramHelper::create();
    mTracerStochasticCollect = RayTraceProgramHelper::create();
    mResetConstantBuffers = true;

    //Full Collect
    {
        //payload size is num photons + a counter + sampleGenerator(16B)
        uint maxPayloadSize = kMaxPayloadSizeBytesCollect;

        RtProgram::Desc desc;
        desc.addShaderLibrary(kShaderCollectPhoton);
        desc.setMaxPayloadSize(maxPayloadSize);
        desc.setMaxAttributeSize(kMaxAttributeSizeBytes);
        desc.setMaxTraceRecursionDepth(kMaxRecursionDepth);

        mTracerCollect.pBindingTable = RtBindingTable::create(1, 1, mpScene->getGeometryCount());   //TODO: Check if that can be removed
        auto& sbt = mTracerCollect.pBindingTable;
        sbt->setRayGen(desc.addRayGen("rayGen"));
        sbt->setMiss(0, desc.addMiss("miss"));
        auto hitShader = desc.addHitGroup("", "anyHit", "intersection");
        sbt->setHitGroup(0, 0, hitShader);


        mTracerCollect.pProgram = RtProgram::create(desc, mpScene->getSceneDefines());
    }
    //Stochastic collect
    {
        //payload size is num photons + a counter + sampleGenerator(16B)
        uint maxPayloadSize = (mMaxNumberPhotonsSC + 5) * sizeof(uint);

        RtProgram::Desc desc;
        desc.addShaderLibrary(kShaderCollectStochasticPhoton);
        desc.setMaxPayloadSize(maxPayloadSize);
        desc.setMaxAttributeSize(kMaxAttributeSizeBytes);
        desc.setMaxTraceRecursionDepth(kMaxRecursionDepth);

        mTracerStochasticCollect.pBindingTable = RtBindingTable::create(1, 1, mpScene->getGeometryCount());   //TODO: Check if that can be removed
        auto& sbt = mTracerStochasticCollect.pBindingTable;
        sbt->setRayGen(desc.addRayGen("rayGen"));
        sbt->setMiss(0, desc.addMiss("miss"));
        auto hitShader = desc.addHitGroup("", "anyHit", "intersection");
        sbt->setHitGroup(0, 0, hitShader);

        mTracerStochasticCollect.pProgram = RtProgram::create(desc, mpScene->getSceneDefines());
    }

}

void PhotonMapper::initPhotonCulling(RenderContext* pRenderContext, uint2 windowDim)
{
    //Reset Buffer if set
    if (mCullingBuffer) mCullingBuffer.reset();

    //Build hash buffer
    uint size = 1 << mCullingHashBufferSizeBytes;
    size = static_cast<uint>(sqrt(size));
    mCullingYExtent = size;
    mCullingBuffer = Texture::create2D(size, size, ResourceFormat::R8Uint, 1, 1, nullptr, ResourceBindFlags::UnorderedAccess | ResourceBindFlags::ShaderResource);
    mCullingBuffer->setName("Culling hash buffer");
}

void PhotonMapper::resetCullingVars()
{
    //reset all buffers. This saves memory if the culling is deactivated
    mPhotonCullingPass.reset();
    mCullingBuffer.reset();
}

void PhotonMapper::photonCullingPass(RenderContext* pRenderContext, const RenderData& renderData)
{
    FALCOR_PROFILE("PhotonCulling");
    //Reset Counter and AABB
    pRenderContext->clearUAV(mCullingBuffer->getUAV().get(), float4(0));


    //Build shader
    if (!mPhotonCullingPass) {
        Program::Desc desc;
        desc.addShaderLibrary(kShaderPhotonCulling).csEntry("main").setShaderModel("6_5");
        desc.addTypeConformances(mpScene->getTypeConformances());

        Program::DefineList defines;
        defines.add(mpScene->getSceneDefines());
        defines.add("CULLING_USE_PROJECTION", std::to_string(mUseProjectionMatrixCulling));

        mPhotonCullingPass = ComputePass::create(desc, defines, true);
    }

    //Variables
     // Set constants.
    auto var = mPhotonCullingPass->getRootVar();
    //Set Scene data. Is needed for camera etc.
    mpScene->setRaytracingShaderData(pRenderContext, var, 1);

    float fovY = focalLengthToFovY(mpScene->getCamera()->getFocalLength(), Camera::kDefaultFrameHeight);
    float fovX = static_cast<float>(2 * atan(tan(fovY * 0.5) * mpScene->getCamera()->getAspectRatio()));

    var["PerFrame"]["gHashScaleFactor"] = 1.0f / (mGlobalRadius * 2);  //Radius needs to be double to ensure that all photons from the camera cell are in it
    var["PerFrame"]["gHashSize"] = 1 << mCullingHashBufferSizeBytes;
    var["PerFrame"]["gYExtend"] = mCullingYExtent;
    var["PerFrame"]["gProjTest"] = mPCullingrojectionTestOver;

    var[kInputChannels[0].texname] = renderData[kInputChannels[0].name]->asTexture();    //VBuffer
    var["gHashBuffer"] = mCullingBuffer;


    const uint2 targetDim = renderData.getDefaultTextureDims();
    FALCOR_ASSERT(targetDim.x > 0 && targetDim.y > 0);

    mPhotonCullingPass->execute(pRenderContext, uint3(targetDim, 1));

    pRenderContext->uavBarrier(mCullingBuffer.get());
}

void PhotonMapper::checkTimer()
{
    if (!mUseTimer) return;

    //reset timer
    if (mResetTimer) {
        mCurrentElapsedTime = 0.0;
        mTimerStartTime = std::chrono::steady_clock::now();
        mTimerStopRenderer = false;
        mResetTimer = false;
        if (mTimerRecordTimes) {
            mTimesList.clear();
            mTimesList.reserve(10000);
        }
        return;
    }

    if (mTimerStopRenderer) return;

    //check time
    if (mTimerDurationSec != 0) {
        auto currentTime = std::chrono::steady_clock::now();
        std::chrono::duration<double> elapsedSec = currentTime - mTimerStartTime;
        mCurrentElapsedTime = elapsedSec.count();

        if (mTimerDurationSec <= mCurrentElapsedTime) {
            mTimerStopRenderer = true;
        }
    }

    //check iterations
    if (mTimerMaxIterations != 0) {
        if (mTimerMaxIterations <= mFrameCount) {
            mTimerStopRenderer = true;
        }
    }

    //Add to times list
    if (mTimerRecordTimes) {
        mTimesList.push_back(mCurrentElapsedTime);
    }
}

void PhotonMapper::outputTimes()
{
    if (mTimesOutputFilePath.empty() || mTimesList.empty()) return;

    std::ofstream file = std::ofstream(mTimesOutputFilePath, std::ios::trunc);

    if (!file) {
        reportError(fmt::format("Failed to open file '{}'.", mTimesOutputFilePath));
        mTimesOutputFilePath.clear();
        return;
    }

    //Write into file
    file << "RTPM_Times" << std::endl;
    file << std::fixed << std::setprecision(16);
    for (size_t i = 0; i < mTimesList.size(); i++) {
        file << mTimesList[i];
        file << std::endl;
    }
    file.close();
}

void PhotonMapper::photonASDebugPass(RenderContext* pRenderContext, const RenderData& renderData)
{
    //create program if not initialized
    if (!mPhotonASDebugPass.pProgram)
    {
        RtProgram::Desc desc;
        desc.addShaderLibrary(kShaderDebugShowPhotonAS);
        desc.setMaxPayloadSize(16u);
        desc.setMaxAttributeSize(kMaxAttributeSizeBytes);
        desc.setMaxTraceRecursionDepth(kMaxRecursionDepth);

        mPhotonASDebugPass.pBindingTable = RtBindingTable::create(1, 1, mpScene->getGeometryCount());
        auto& sbt = mPhotonASDebugPass.pBindingTable;
        sbt->setRayGen(desc.addRayGen("rayGen"));
        sbt->setMiss(0, desc.addMiss("miss"));
        auto hitShader = desc.addHitGroup("closestHit", "", "intersection");
        sbt->setHitGroup(0, 0, hitShader);

        mPhotonASDebugPass.pProgram = RtProgram::create(desc, mpScene->getSceneDefines());
    }
    bool resetCamera = false;
    //Copy Camera
    if (mCopyToDebugCamera) {
        mDebugCameraData = mpScene->getCamera()->getData();
        resetCamera = true;
        mCopyToDebugCamera = false;
    }

    // Trace the photons
    FALCOR_PROFILE("debugPhotonAS");



    // Prepare program for full collect vars. This may trigger shader compilation.
    if (!mPhotonASDebugPass.pVars) {
        FALCOR_ASSERT(mPhotonASDebugPass.pProgram);
        mPhotonASDebugPass.pProgram->setTypeConformances(mpScene->getTypeConformances());
        mPhotonASDebugPass.pVars = RtProgramVars::create(mPhotonASDebugPass.pProgram, mPhotonASDebugPass.pBindingTable);
        // Bind utility classes into shared data.
        auto var = mPhotonASDebugPass.pVars->getRootVar();
    }
    FALCOR_ASSERT(mPhotonASDebugPass.pVars);

    // Set constants.
    auto var = mPhotonASDebugPass.pVars->getRootVar();

    std::string nameBuf = "PerFrame";
    var[nameBuf]["gCausticRadius"] = mCausticRadius;
    var[nameBuf]["gGlobalRadius"] = mGlobalRadius;

    if (resetCamera) {
        nameBuf = "CB";
        var[nameBuf]["gCamPosW"] = mDebugCameraData.posW;
        var[nameBuf]["gCameraU"] = mDebugCameraData.cameraU;
        var[nameBuf]["gCameraV"] = mDebugCameraData.cameraV;
        var[nameBuf]["gCameraW"] = mDebugCameraData.cameraW;
    }

    for (uint32_t i = 0; i <= 1; i++)
    {
        var["gPhotonAABB"][i] = i == 0 ? mCausticBuffers.aabb : mGlobalBuffers.aabb;
    }

    // Lamda for binding textures. These needs to be done per-frame as the buffers may change anytime.
    auto bindAsTex = [&](const ChannelDesc& desc)
    {
        if (!desc.texname.empty())
        {
            var[desc.texname] = renderData[desc.name]->asTexture();
        }
    };

    //Bind input and output textures
    bindAsTex(kOutputChannels[0]);

    // Get dimensions of ray dispatch.
    const uint2 targetDim = renderData.getDefaultTextureDims();
    FALCOR_ASSERT(targetDim.x > 0 && targetDim.y > 0);

    FALCOR_ASSERT(pRenderContext && mPhotonASDebugPass.pProgram && mPhotonASDebugPass.pVars);

    //bind TLAS
    bool tlasValid = var["gPhotonAS"].setSrv(mPhotonTlas.pSrv);
    FALCOR_ASSERT(tlasValid);

    //pRenderContext->raytrace(mTracerCollect.pProgram.get(), mTracerCollect.pVars.get(), targetDim.x, targetDim.y, 1);
    // Trace the photons
    mpScene->raytrace(pRenderContext, mPhotonASDebugPass.pProgram.get(), mPhotonASDebugPass.pVars, uint3(targetDim, 1));    //TODO: Check if scene defines can be set manually

}

bool PhotonMapper::prepareLighting(RenderContext* pRenderContext)
{
    bool lightingChanged = false;

    if (mpScene->useEmissiveLights()) {
        //Init light sampler if not set
        if (!mpEmissiveLightSampler) {
            //Ensure that emissive light struct is build by falcor
            const auto& pLights = mpScene->getLightCollection(pRenderContext);
            FALCOR_ASSERT(pLights && pLights->getActiveLightCount() > 0);
            //TODO: Support different types of sampler
            mpEmissiveLightSampler = EmissivePowerSampler::create(pRenderContext, mpScene);
            lightingChanged = true;
        }
    }
    else {
        if (mpEmissiveLightSampler) {
            mpEmissiveLightSampler = nullptr;
            lightingChanged = true;
        }
    }

    //Update Emissive light sampler
    if (mpEmissiveLightSampler) {
        lightingChanged |= mpEmissiveLightSampler->update(pRenderContext);
    }

    return lightingChanged;
}