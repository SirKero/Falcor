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
#include "PhotonReSTIRFinalGathering.h"
#include <RenderGraph/RenderPassHelpers.h>

const RenderPass::Info PhotonReSTIRFinalGathering::kInfo { "PhotonReSTIRFinalGathering", "Photon based indirect lighting pass using ReSTIR" };

// Don't remove this. it's required for hot-reload to function properly
extern "C" FALCOR_API_EXPORT const char* getProjDir()
{
    return PROJECT_DIR;
}

extern "C" FALCOR_API_EXPORT void getPasses(Falcor::RenderPassLibrary& lib)
{
    lib.registerPass(PhotonReSTIRFinalGathering::kInfo, PhotonReSTIRFinalGathering::create);
}

namespace {
    //Shaders
    const char kShaderGetFinalGatherHit[] = "RenderPasses/PhotonReSTIRFinalGathering/getFinalGatherHits.rt.slang";
    const char kShaderGeneratePhoton[] = "RenderPasses/PhotonReSTIRFinalGathering/generatePhotons.rt.slang";
    const char kShaderCollectFinalGatherPhotons[] = "RenderPasses/PhotonReSTIRFinalGathering/collectFinalGatherPhotons.rt.slang";
    //const char kShaderGenerateFinalGatheringCandidates[] = "RenderPasses/PhotonReSTIRFinalGathering/generateFinalGatheringCandidates.rt.slang";
    const char kShaderGenerateAdditionalCandidates[] = "RenderPasses/PhotonReSTIRFinalGathering/generateAdditionalCandidates.cs.slang";
    const char kShaderTemporalPass[] = "RenderPasses/PhotonReSTIRFinalGathering/temporalResampling.cs.slang";
    const char kShaderSpartialPass[] = "RenderPasses/PhotonReSTIRFinalGathering/spartialResampling.cs.slang";
    const char kShaderSpartioTemporalPass[] = "RenderPasses/PhotonReSTIRFinalGathering/spartioTemporalResampling.cs.slang";
    const char kShaderFinalShading[] = "RenderPasses/PhotonReSTIRFinalGathering/finalShading.cs.slang";
    const char kShaderCollectCausticPhotons[] = "RenderPasses/PhotonReSTIRFinalGathering/collectCausticPhotons.rt.slang";
    // Ray tracing settings that affect the traversal stack size.
    const uint32_t kMaxPayloadSizeBytesVPL = 48u;
    const uint32_t kMaxPayloadSizeBytesCollect = 80u;
    const uint32_t kMaxPayloadSizeBytes = 96u;
    const uint32_t kMaxAttributeSizeBytes = 8u;
    const uint32_t kMaxRecursionDepth = 2u;

    //Inputs
    const ChannelDesc kInVBufferDesc = {"VBuffer" , "gVBuffer", "VBuffer hit information", false};
    const ChannelDesc kInMVecDesc = {"MVec" , "gMVec" , "Motion Vector", false};
    const ChannelDesc kInViewDesc = {"View" ,"gView", "View Vector", true};
    const ChannelDesc kInRayDistance = { "RayDepth" , "gLinZ", "The ray distance from camera to hit point", true };

    const ChannelList kInputChannels = { kInVBufferDesc, kInMVecDesc, kInViewDesc, kInRayDistance };

    //Outputs
    const ChannelDesc kOutColorDesc = { "color" ,"gColor" , "Indirect illumination of the scene" ,false,  ResourceFormat::RGBA16Float };
    const ChannelList kOutputChannels =
    {
        kOutColorDesc,
        {"diffuseIllumination",     "gDiffuseIllumination",     "Diffuse Illumination and hit distance",    true,   ResourceFormat::RGBA16Float},
        {"diffuseReflectance",      "gDiffuseReflectance",      "Diffuse Reflectance",                      true,   ResourceFormat::RGBA16Float},
        {"specularIllumination",    "gSpecularIllumination",    "Specular illumination and hit distance",   true,   ResourceFormat::RGBA16Float},
        {"specularReflectance",     "gSpecularReflectance",     "Specular reflectance",                     true,   ResourceFormat::RGBA16Float},
    };

    const Gui::DropdownList kResamplingModeList{
        {PhotonReSTIRFinalGathering::ResamplingMode::NoResampling , "No Resampling"},
        {PhotonReSTIRFinalGathering::ResamplingMode::Temporal , "Temporal only"},
        {PhotonReSTIRFinalGathering::ResamplingMode::Spartial , "Spartial only"},
        {PhotonReSTIRFinalGathering::ResamplingMode::SpartioTemporal , "SpartioTemporal"},
    };

    const Gui::DropdownList kBiasCorrectionModeList{
        {PhotonReSTIRFinalGathering::BiasCorrectionMode::Off , "Off"},
        {PhotonReSTIRFinalGathering::BiasCorrectionMode::Basic , "Basic"},
        {PhotonReSTIRFinalGathering::BiasCorrectionMode::RayTraced , "RayTraced"},
    };

    const Gui::DropdownList kVplEliminateModes{
        {PhotonReSTIRFinalGathering::VplEliminationMode::Fixed , "Fixed"},
        {PhotonReSTIRFinalGathering::VplEliminationMode::Linear , "Linear"},
        {PhotonReSTIRFinalGathering::VplEliminationMode::Power , "Power"},
        {PhotonReSTIRFinalGathering::VplEliminationMode::Root , "Root"},
    };
}

PhotonReSTIRFinalGathering::SharedPtr PhotonReSTIRFinalGathering::create(RenderContext* pRenderContext, const Dictionary& dict)
{
    SharedPtr pPass = SharedPtr(new PhotonReSTIRFinalGathering());
    return pPass;
}

Dictionary PhotonReSTIRFinalGathering::getScriptingDictionary()
{
    return Dictionary();
}

RenderPassReflection PhotonReSTIRFinalGathering::reflect(const CompileData& compileData)
{
    // Define the required resources here
    RenderPassReflection reflector;
    addRenderPassInputs(reflector, kInputChannels);
    addRenderPassOutputs(reflector, kOutputChannels);
    return reflector;
}

void PhotonReSTIRFinalGathering::execute(RenderContext* pRenderContext, const RenderData& renderData)
{
    //clear color output |TODO: Clear all valid outputs
    pRenderContext->clearTexture(renderData[kOutColorDesc.name]->asTexture().get());
    
    //Return on empty scene
    if (!mpScene)
        return;

    if (mReset)
        resetPass();

    mpScene->getLightCollection(pRenderContext);

    //currently we only support emissive lights
    if (!mpScene->useEmissiveLights())return;

    prepareLighting(pRenderContext);

    preparePhotonBuffers(pRenderContext,renderData);

    prepareBuffers(pRenderContext, renderData);

    //Get the final gather hits
    getFinalGatherHitPass(pRenderContext, renderData);

    //Generate Photons
    generatePhotonsPass(pRenderContext, renderData);

    //Generate the first candidate with Final Gather photon mapping
    collectFinalGatherHitPhotons(pRenderContext, renderData);

    generateAdditionalCandidates(pRenderContext, renderData);
    //distributeAndCollectFinalGatherPhotonPass(pRenderContext, renderData);

    //Collect the caustic photons
    collectCausticPhotons(pRenderContext, renderData);

    //Copy the counter for UI
    handelPhotonCounter(pRenderContext);

    //Reservoir based resampling
    switch (mResamplingMode) {
    case ResamplingMode::Temporal:
        temporalResampling(pRenderContext, renderData);
        if (mpSpartialResampling || mpSpartioTemporalResampling) {
            mpSpartialResampling.reset();
            mpSpartioTemporalResampling.reset();
        }
        break;
    case ResamplingMode::Spartial:
        spartialResampling(pRenderContext, renderData);
        if (mpTemporalResampling || mpSpartioTemporalResampling) {
            mpTemporalResampling.reset();
            mpSpartioTemporalResampling.reset();
        }
        break;
    case ResamplingMode::SpartioTemporal:
        spartioTemporalResampling(pRenderContext, renderData);
        if (mpSpartialResampling || mpTemporalResampling) {
            mpSpartialResampling.reset();
            mpTemporalResampling.reset();
        }
        break;
    }


    //Shade the pixel
    finalShadingPass(pRenderContext, renderData);
 
    //Copy view buffer if it is used
    if (renderData[kInViewDesc.name] != nullptr) {
        pRenderContext->copyResource(mpPrevViewTex.get(), renderData[kInViewDesc.name]->asTexture().get());
    }

    //Reduce radius if desired with formula by Knaus & Zwicker (2011)
    //Is only done as long as the camera did not move
    if (mUseStatisticProgressivePM) {
        if (is_set(mpScene->getUpdates(), Scene::UpdateFlags::CameraMoved)) {
            mFramesCameraStill = 0;
            mPhotonCollectRadius = mPhotonCollectionRadiusStart;
        }
            
        float itF = static_cast<float>(mFramesCameraStill);
        //Use for both or only caustics
        if(mUseStatisticProgressivePMGlobal)
            mPhotonCollectRadius *= sqrt((itF + mPPM_Alpha) / (itF + 1.0f));
        else
            mPhotonCollectRadius.y *= sqrt((itF + mPPM_Alpha) / (itF + 1.0f));

        mFramesCameraStill++;
    }


    //Reset the reset vars
    mReuploadBuffers = mReset ? true : false;
    mBiasCorrectionChanged = false;
    mReset = false;
    mFrameCount++;
}

void PhotonReSTIRFinalGathering::renderUI(Gui::Widgets& widget)
{
    bool changed = false;

    changed |= widget.var("Initial Candidates", mInitialCandidates, 0u, 8u);

    if (auto group = widget.group("PhotonMapper")) {
        //Dispatched Photons
        changed |= widget.checkbox("Enable dynamic photon dispatch", mUseDynamicePhotonDispatchCount);
        widget.tooltip("Changed the number of dispatched photons dynamically. Tries to fill the photon buffer");
        if (mUseDynamicePhotonDispatchCount) {
            changed |= widget.var("Max dispatched", mPhotonDynamicDispatchMax, mPhotonYExtent, 4000000u);
            widget.tooltip("Maximum number the dispatch can be increased to");
            changed |= widget.var("Guard Percentage", mPhotonDynamicGuardPercentage, 0.0f, 1.f, 0.001f);
            widget.tooltip("If current fill rate is under PhotonBufferSize * (1-pGuard), the values are accepted. Reduces the changes every frame");
            changed |= widget.var("Percentage Change", mPhotonDynamicChangePercentage, 0.01f, 10.f, 0.01f);
            widget.tooltip("Increase/Decrease percentage from the Buffer Size. With current value a increase/decrease of :" +std::to_string(mPhotonDynamicChangePercentage * mNumMaxPhotons[0]) + "is expected");
            widget.text("Dispatched Photons: " + std::to_string(mNumDispatchedPhotons));
        }
        else{
            uint dispatchedPhotons = mNumDispatchedPhotons;
            bool disPhotonChanged = widget.var("Dispatched Photons", dispatchedPhotons, mPhotonYExtent, 9984000u, (float)mPhotonYExtent);
            if (disPhotonChanged)
                mNumDispatchedPhotons = (uint)(dispatchedPhotons / mPhotonYExtent) * mPhotonYExtent;
        }
        
        //Buffer size
        widget.text("Photons: " + std::to_string(mCurrentPhotonCount[0]) + " / " + std::to_string(mNumMaxPhotons[0]));
        widget.text("Caustic photons: " + std::to_string(mCurrentPhotonCount[1]) + " / " + std::to_string(mNumMaxPhotons[1]));
        widget.var("Photon Buffer Size", mNumMaxPhotonsUI, 100u, 100000000u, 100);
        mChangePhotonLightBufferSize = widget.button("Apply", true);
        widget.tooltip("First -> Global, Second -> Caustic");
        if (mChangePhotonLightBufferSize) mNumMaxPhotons = mNumMaxPhotonsUI;

        changed |= widget.var("Light Store Probability", mPhotonRejection, 0.f, 1.f, 0.0001f);
        widget.tooltip("Probability a photon light is stored on diffuse hit. Flux is scaled up appropriately");

        changed |= widget.var("Max Bounces", mPhotonMaxBounces, 0u, 32u);

        bool radiusChanged = widget.var("Collect Radius", mPhotonCollectionRadiusStart, 0.00001f, 1000.f,0.00001f);
        widget.tooltip("Photon Radii for final gather and caustic collecton. First->Global, Second->Caustic");
        if (radiusChanged) {
            mPhotonCollectRadius = mPhotonCollectionRadiusStart;
            mFramesCameraStill = 0;
        }

        widget.checkbox("Use SPPM when Camera is still", mUseStatisticProgressivePM);
        widget.tooltip("Uses Statistic Progressive photon mapping to reduce the radius when the camera stays still");
        if (mUseStatisticProgressivePM) {
            widget.checkbox("SPPM for Global Photons?", mUseStatisticProgressivePMGlobal);
            widget.text("Current Radius: " + std::to_string(mPhotonCollectRadius.x) + " ; " + std::to_string(mPhotonCollectRadius.y));
            widget.var("SPPM Alpha", mPPM_Alpha, 0.f, 1.f, 0.001f);
            widget.tooltip("Alpha value for radius reduction after Knaus and Zwicker (2011).");
            if (widget.button("Reset Radius Reduction"))
                mFramesCameraStill = 0;
        }


        if (auto group = widget.group("Caustic Options")) {
            changed |= widget.checkbox("Enable Caustics", mEnableCausticPhotonCollection);
            widget.tooltip("Enables caustics. Else they are treated as global photons");
            changed |= widget.var("Max Diffuse Bounces", mMaxCausticBounces, -1, 1000);
            widget.tooltip("Max diffuse bounces after that a specular hit is still counted as an caustic.\n -1 -> Always, 0 -> Only direct caustics (LSD paths), 1-> L(D)SD paths ...");
            widget.checkbox("Use Temporal Filter", mCausticUseTemporalFilter);
            if (mCausticUseTemporalFilter) {
                widget.var("Temporal History Limit", mCausticTemporalFilterMaxHistory, 0u, MAXUINT32);
                widget.tooltip("Determines the max median over caustic iterations");
            }
        }

        changed |= widget.checkbox("Use Photon Culling", mUsePhotonCulling);
        widget.tooltip("Enabled culling of photon based on a hash grid. Photons are only stored on cells that are collected");
        if (mUsePhotonCulling) {
            mPhotonCullingRebuildBuffer = widget.var("Culling Size Bytes", mCullingHashBufferSizeBits, 10u, 27u);
            widget.tooltip("Size of the culling buffer (2^x) and effective hash bytes used");
            changed |= mPhotonCullingRebuildBuffer;
        } 

        changed |= widget.checkbox("Use Alpha Test", mPhotonUseAlphaTest);
        changed |= widget.checkbox("Adjust Shading Normal", mPhotonAdjustShadingNormal);
        changed |= widget.checkbox("Final Gather Radius Rejection", mAllowFinalGatherPointsInRadius);
        widget.tooltip("Allow generated Final Gather hit points in the distance of the collection radius");
    }

    if (auto group = widget.group("ReSTIR")) {
        changed |= widget.dropdown("ResamplingMode", kResamplingModeList, mResamplingMode);
        
        if (mResamplingMode > 0) {
            if (auto group = widget.group("Resamling")) {
                mBiasCorrectionChanged |= widget.dropdown("BiasCorrection", kBiasCorrectionModeList, mBiasCorrectionMode);

                changed |= widget.var("Depth Threshold", mRelativeDepthThreshold, 0.0f, 1.0f, 0.0001f);
                widget.tooltip("Relative depth threshold. 0.1 = within 10% of current depth (linZ)");

                changed |= widget.var("Normal Threshold", mNormalThreshold, 0.0f, 1.0f, 0.0001f);
                widget.tooltip("Maximum cosine of angle between normals. 1 = Exactly the same ; 0 = disabled");
            }
        }
        if ((mResamplingMode & ResamplingMode::Temporal) > 0) {
            if (auto group = widget.group("Temporal Options")) {
                changed |= widget.var("Temporal age", mTemporalMaxAge, 0u, 512u);
                widget.tooltip("Temporal age a sample should have");
            }
        }
        if ((mResamplingMode & ResamplingMode::Spartial) > 0) {
            if (auto group = widget.group("Spartial Options")) {
                changed |= widget.var("Spartial Samples", mSpartialSamples, 0u, mResamplingMode & ResamplingMode::SpartioTemporal ? 8u : 32u);
                widget.tooltip("Number of spartial samples");

                changed |= widget.var("Disocclusion Sample Boost", mDisocclusionBoostSamples, 0u, 32u);
                widget.tooltip("Number of spartial samples if no temporal surface was found. Needs to be bigger than \"Spartial Samples\" + 1 to have an effect");

                changed |= widget.var("Sampling Radius", mSamplingRadius, 0.0f, 200.f);
                widget.tooltip("Radius for the Spartial Samples");
            }
        }

        if (auto group = widget.group("Misc")) {
            changed |= widget.checkbox("Use Final Shading Visibility Ray", mUseFinalVisibilityRay);
            widget.tooltip("Enables a Visibility ray in final shading. Can reduce bias as Reservoir Visibility rays ignore opaque geometry");
            mReset |= widget.checkbox("Diffuse Shading Only", mUseDiffuseOnlyShading);
            widget.tooltip("Uses only diffuse shading. Can be used if a Path traced V-Buffer is used. Triggers Recompilation of shaders");
        }

        mReset |= widget.checkbox("Use reduced Reservoir format", mUseReducedReservoirFormat);
        widget.tooltip("If enabled uses RG32_UINT instead of RGBA32_UINT. In reduced format the targetPDF and M only have 16 bits while the weight still has full precision");
    }
   

    mReset |= widget.button("Recompile");
    mReuploadBuffers |= changed;
}

void PhotonReSTIRFinalGathering::setScene(RenderContext* pRenderContext, const Scene::SharedPtr& pScene)
{
    resetPass(true);

    mFrameCount = 0;
    //Recreate RayTracing Program on Scene reset
    mPhotonGeneratePass = RayTraceProgramHelper::create();
    mDistributeAndCollectFinalGatherPointsPass = RayTraceProgramHelper::create();
    mGetFinalGatherHitPass = RayTraceProgramHelper::create();
    mCollectCausticPhotonsPass = RayTraceProgramHelper::create();
    mGeneratePMCandidatesPass = RayTraceProgramHelper::create();

    mpScene = pScene;

    if (mpScene) {
        if (mpScene->hasGeometryType(Scene::GeometryType::Custom))
        {
            logWarning("This render pass only supports triangles. Other types of geometry will be ignored.");
        }

        //Lambda for standard init of a RT Program
        auto initStandardRTProgram = [&](RayTraceProgramHelper& rtHelper, const char shader[], uint maxPayloadBites) {
            RtProgram::Desc desc;
            desc.addShaderLibrary(shader);
            desc.setMaxPayloadSize(maxPayloadBites);
            desc.setMaxAttributeSize(kMaxAttributeSizeBytes);
            desc.setMaxTraceRecursionDepth(kMaxRecursionDepth);

            rtHelper.pBindingTable = RtBindingTable::create(1, 1, mpScene->getGeometryCount());
            auto& sbt = rtHelper.pBindingTable;
            sbt->setRayGen(desc.addRayGen("rayGen"));
            sbt->setMiss(0, desc.addMiss("miss"));
            if (mpScene->hasGeometryType(Scene::GeometryType::TriangleMesh)) {
                sbt->setHitGroup(0, mpScene->getGeometryIDs(Scene::GeometryType::TriangleMesh), desc.addHitGroup("closestHit", "anyHit"));
            }

            rtHelper.pProgram = RtProgram::create(desc, mpScene->getSceneDefines());
        };

        initStandardRTProgram(mGetFinalGatherHitPass, kShaderGetFinalGatherHit, kMaxPayloadSizeBytes);  //Get Final gather hit
        initStandardRTProgram(mPhotonGeneratePass, kShaderGeneratePhoton, kMaxPayloadSizeBytes);    //Generate Photons

        //Collect Photons at Final Gathering Hit
        {
            RtProgram::Desc desc;
            desc.addShaderLibrary(kShaderCollectFinalGatherPhotons);
            desc.setMaxPayloadSize(kMaxPayloadSizeBytesCollect);
            desc.setMaxAttributeSize(kMaxAttributeSizeBytes);
            desc.setMaxTraceRecursionDepth(kMaxRecursionDepth);

            //Scene geometry count is needed as the scene acceleration struture bound with the scene defines
            mGeneratePMCandidatesPass.pBindingTable = RtBindingTable::create(1, 1, mpScene->getGeometryCount());  //Scene geometry count is needed for scene construct to work
            auto& sbt = mGeneratePMCandidatesPass.pBindingTable;
            sbt->setRayGen(desc.addRayGen("rayGen"));
            sbt->setMiss(0, desc.addMiss("miss"));
            sbt->setHitGroup(0, 0, desc.addHitGroup("", "anyHit", "intersection"));

            mGeneratePMCandidatesPass.pProgram = RtProgram::create(desc, mpScene->getSceneDefines());
        }

        //Collect Caustic Photons
        {
            RtProgram::Desc desc;
            desc.addShaderLibrary(kShaderCollectCausticPhotons);
            desc.setMaxPayloadSize(kMaxPayloadSizeBytesCollect);
            desc.setMaxAttributeSize(kMaxAttributeSizeBytes);
            desc.setMaxTraceRecursionDepth(kMaxRecursionDepth);

            //Scene geometry count is needed as the scene acceleration struture bound with the scene defines
            mCollectCausticPhotonsPass.pBindingTable = RtBindingTable::create(1, 1, mpScene->getGeometryCount());  //Scene geometry count is needed for scene construct to work
            auto& sbt = mCollectCausticPhotonsPass.pBindingTable;
            sbt->setRayGen(desc.addRayGen("rayGen"));
            sbt->setMiss(0, desc.addMiss("miss"));
            sbt->setHitGroup(0, 0, desc.addHitGroup("", "anyHit", "intersection"));

            mCollectCausticPhotonsPass.pProgram = RtProgram::create(desc, mpScene->getSceneDefines());
        }

        //Init the raytracing collection programm TODO maybe remove
        /*
        {
            RtProgram::Desc desc;
            //desc.addShaderLibrary(kShaderCollectPhoton);
            desc.addShaderLibrary(kShaderGenerateFinalGatheringCandidates);
            //desc.addShaderLibrary(kShaderDebugPhotonCollect);
            desc.setMaxPayloadSize(kMaxPayloadSizeBytesCollect);
            desc.setMaxAttributeSize(kMaxAttributeSizeBytes);
            desc.setMaxTraceRecursionDepth(kMaxRecursionDepth);

            //Scene geometry count is needed as the scene acceleration struture bound with the scene defines
            mDistributeAndCollectFinalGatherPointsPass.pBindingTable = RtBindingTable::create(2, 2, mpScene->getGeometryCount());
            //mDistributeAndCollectFinalGatherPointsPass.pBindingTable = RtBindingTable::create(1, 1, mpScene->getGeometryCount());
            auto& sbt = mDistributeAndCollectFinalGatherPointsPass.pBindingTable;
            sbt->setRayGen(desc.addRayGen("rayGen"));
            sbt->setMiss(0, desc.addMiss("miss"));
            sbt->setHitGroup(0, 0, desc.addHitGroup("", "anyHit", "intersection"));
            sbt->setMiss(1, desc.addMiss("missDebug"));
            sbt->setHitGroup(1, mpScene->getGeometryIDs(Scene::GeometryType::TriangleMesh), desc.addHitGroup("closestHitDebug"));
            
            mDistributeAndCollectFinalGatherPointsPass.pProgram = RtProgram::create(desc, mpScene->getSceneDefines());
        }
        */
    }

}

void PhotonReSTIRFinalGathering::resetPass(bool resetScene)
{
    mpTemporalResampling.reset();
    mpSpartialResampling.reset();
    mpSpartioTemporalResampling.reset();
    mpFinalShading.reset();
    mpGenerateAdditionalCandidates.reset();

    if (resetScene) {
        mpEmissiveLightSampler.reset();
        mpSampleGenerator.reset();
    }

    mReuploadBuffers = true;
}

bool PhotonReSTIRFinalGathering::prepareLighting(RenderContext* pRenderContext)
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

void PhotonReSTIRFinalGathering::preparePhotonBuffers(RenderContext* pRenderContext,const RenderData& renderData)
{
        
    if (mChangePhotonLightBufferSize) {
        for (uint i = 0; i < 2; i++) {
            mpPhotonAABB[i].reset();
            mpPhotonData[i].reset();
        }
        
        mPhotonAS.tlas.pTlas.reset();       //This triggers photon as recreation
        mChangePhotonLightBufferSize = false;
    }
    
    if (!mpPhotonCounter) {
        mpPhotonCounter = Buffer::create(sizeof(uint) * 2);
        mpPhotonCounter->setName("PhotonReSTIRFinalGathering::PhotonCounterGPU");
    }
    if (!mpPhotonCounterCPU) {
        mpPhotonCounterCPU = Buffer::create(sizeof(uint) * 2,ResourceBindFlags::None, Buffer::CpuAccess::Read);
        mpPhotonCounterCPU->setName("PhotonReSTIRFinalGathering::PhotonCounterCPU");
    }
    for (uint i = 0; i < 2; i++) {
        if (!mpPhotonAABB[i]) {
            mpPhotonAABB[i] = Buffer::createStructured(sizeof(D3D12_RAYTRACING_AABB), mNumMaxPhotons[i]);
            mpPhotonAABB[i]->setName("PhotonReStir::PhotonAABB" + (i+1));
        }
        if (!mpPhotonData[i]) {
            mpPhotonData[i] = Buffer::createStructured(sizeof(uint) * 4, mNumMaxPhotons[i]);
            mpPhotonData[i]->setName("PhotonReStir::PhotonData" + (i + 1));
        }
    }

}

void PhotonReSTIRFinalGathering::prepareBuffers(RenderContext* pRenderContext, const RenderData& renderData)
{
    //Has resolution changed ?
    if ((mScreenRes.x != renderData.getDefaultTextureDims().x) || (mScreenRes.y != renderData.getDefaultTextureDims().y) || mReset)
    {
        mScreenRes = renderData.getDefaultTextureDims();
        mpFinalGatherHit.reset();
        mpFinalGatherExtraInfo.reset();
        for (size_t i = 0; i <= 1; i++) {
            mpSurfaceBuffer[i].reset();
            mpPrevViewTex.reset();
        }
        for (size_t i = 0; i < 2; i++) {
            mpReservoirBuffer[i].reset();
            mpPhotonLightBuffer[i].reset();
        }
        mpReservoirBoostBuffer.reset();
        mpPhotonLightBoostBuffer.reset();
        mReuploadBuffers = true;
    }

    if (!mpReservoirBuffer[0] || !mpReservoirBuffer[1]) {
        for (uint i = 0; i < 2; i++) {
            mpReservoirBuffer[i] = Texture::create2D(renderData.getDefaultTextureDims().x, renderData.getDefaultTextureDims().y,
                                                     mUseReducedReservoirFormat ? ResourceFormat::RG32Uint : ResourceFormat::RGBA32Uint,
                                                     1, 1, nullptr, ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess);
            mpReservoirBuffer[i]->setName("PhotonReStir::ReservoirBuf" + std::to_string(i));
        }
    }


    //Create a buffer filled with surface info for current and last frame
    if (!mpSurfaceBuffer[0] || !mpSurfaceBuffer[1]) {
        uint2 texDim = renderData.getDefaultTextureDims();
        uint bufferSize = texDim.x * texDim.y;
        mpSurfaceBuffer[0] = Buffer::createStructured(sizeof(uint) * 6, bufferSize);
        mpSurfaceBuffer[0]->setName("PhotonReStir::SurfaceBuffer1");
        mpSurfaceBuffer[1] = Buffer::createStructured(sizeof(uint) * 6, bufferSize);
        mpSurfaceBuffer[1]->setName("PhotonReStir::SurfaceBuffer2");
    }

    //Create an fill the neighbor offset buffer
    if (!mpNeighborOffsetBuffer) {
        std::vector<int8_t> offsets(2 * kNumNeighborOffsets);
        fillNeighborOffsetBuffer(offsets);

        mpNeighborOffsetBuffer = Texture::create1D(kNumNeighborOffsets, ResourceFormat::RG8Snorm, 1, 1, offsets.data());


        mpNeighborOffsetBuffer->setName("PhotonReStir::NeighborOffsetBuffer");
    }

    //Photon buffer
    if (!mpPhotonLightBuffer[0] || !mpPhotonLightBuffer[1]) {
        uint bufferSize = renderData.getDefaultTextureDims().x * renderData.getDefaultTextureDims().y;
        for (uint i = 0; i < 2; i++) {
            mpPhotonLightBuffer[i] = Buffer::createStructured(sizeof(uint) * 6, bufferSize, ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess,
                                                   Buffer::CpuAccess::None, nullptr, false);
            mpPhotonLightBuffer[i]->setName("PhotonReStir::PhotonLight" + std::to_string(i));
        }
    }

    //Create Valid Neighbor mask
    if (!mpValidNeighborMask && mInitialCandidates > 0) {
        mpValidNeighborMask = Texture::create2D(renderData.getDefaultTextureDims().x, renderData.getDefaultTextureDims().y, ResourceFormat::R8Unorm,
                                                1, mValidNeighborMaskMipLevel, nullptr, ResourceBindFlags::UnorderedAccess | ResourceBindFlags::ShaderResource | ResourceBindFlags::RenderTarget);
        mpValidNeighborMask->setName("PhotonReStir::ValidNeighborMask");
    }
    //Reset texture if not used
    else if (mpValidNeighborMask && mInitialCandidates == 0) {
        mpValidNeighborMask.reset();
    }

    if (!mpFinalGatherHit) {
        mpFinalGatherHit = Texture::create2D(renderData.getDefaultTextureDims().x, renderData.getDefaultTextureDims().y,
                                             HitInfo::kDefaultFormat, 1u, 1u, nullptr,
                                             ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess);
        mpFinalGatherHit->setName("PhotonReStir::FinalGatherHitInfo");
    }

    if (!mpFinalGatherExtraInfo) {
        mpFinalGatherExtraInfo = Texture::create2D(renderData.getDefaultTextureDims().x, renderData.getDefaultTextureDims().y,
                                             ResourceFormat::RG32Uint, 1u, 1u, nullptr,
                                             ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess);
        mpFinalGatherExtraInfo->setName("PhotonReStir::FinalGatherExtraInfo");
    }

    //Create view tex for previous frame
    if (renderData[kInViewDesc.name] != nullptr && !mpPrevViewTex) {
        auto viewTex = renderData[kInViewDesc.name]->asTexture();
        mpPrevViewTex = Texture::create2D(viewTex->getWidth(), viewTex->getHeight(), viewTex->getFormat(), 1, 1,
            nullptr, ResourceBindFlags::UnorderedAccess | ResourceBindFlags::ShaderResource);
        mpPrevViewTex->setName("PhotonReStir::PrevViewTexture");
    }

    if (!mpSampleGenerator) {
        mpSampleGenerator = SampleGenerator::create(SAMPLE_GENERATOR_UNIFORM);
    }

    //Photon Culling
    if (mUsePhotonCulling && (!mpPhotonCullingMask || mPhotonCullingRebuildBuffer)) {
        uint sizeCullingBuffer = 1 << mCullingHashBufferSizeBits;
        uint width, height, mipLevel;
        computePdfTextureSize(sizeCullingBuffer, width, height, mipLevel);
        mpPhotonCullingMask = Texture::create2D(width, height, ResourceFormat::R8Uint, 1, 1,
                                                nullptr, ResourceBindFlags::UnorderedAccess | ResourceBindFlags::ShaderResource);
        mpPhotonCullingMask->setName("PhotonReStir::PhotonCullingMask");
    }

    //Destroy culling buffer if photon culling is disabled
    if (!mUsePhotonCulling && mpPhotonCullingMask)
        mpPhotonCullingMask.reset();

    if (!mpCausticPhotonsFlux[0] || !mpCausticPhotonsFlux[1]) {
        for (uint i = 0; i < 2; i++) {
            mpCausticPhotonsFlux[i] = Texture::create2D(mScreenRes.x, mScreenRes.y, ResourceFormat::RGBA16Float, 1, 1, nullptr, ResourceBindFlags::UnorderedAccess | ResourceBindFlags::ShaderResource);
            mpCausticPhotonsFlux[i]->setName("PhotonReStir::CausticPhotonTex" + std::to_string(i));
        }
    }

    if (mInitialCandidates > 0) {
        if (!mpReservoirBoostBuffer) {
            mpReservoirBoostBuffer = Texture::create2D(renderData.getDefaultTextureDims().x, renderData.getDefaultTextureDims().y,
                mUseReducedReservoirFormat ? ResourceFormat::RG32Uint : ResourceFormat::RGBA32Uint,
                1, 1, nullptr, ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess);
            mpReservoirBoostBuffer->setName("PhotonReStir::ReservoirBoostBuf");
        }
        if (!mpPhotonLightBoostBuffer) {
            uint bufferSize = renderData.getDefaultTextureDims().x * renderData.getDefaultTextureDims().y;
            mpPhotonLightBoostBuffer = Buffer::createStructured(sizeof(uint) * 6, bufferSize, ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess,
                Buffer::CpuAccess::None, nullptr, false);
            mpPhotonLightBoostBuffer->setName("PhotonReStir::PhotonLightBoost");
        }
    }
    else {
        if (mpReservoirBoostBuffer || mpPhotonLightBoostBuffer) {
            mpReservoirBoostBuffer.reset();
            mpPhotonLightBoostBuffer.reset();
        }
    }
}

void PhotonReSTIRFinalGathering::getFinalGatherHitPass(RenderContext* pRenderContext, const RenderData& renderData)
{
    FALCOR_PROFILE("GetFinalGatheringHit");

    if (mpValidNeighborMask) {
        pRenderContext->clearTexture(mpValidNeighborMask.get(), float4(1, 1, 1, 1));
    }

    //Clear the buffer if photon culling is used
    if (mUsePhotonCulling) {
        pRenderContext->clearUAV(mpPhotonCullingMask->getUAV().get(), uint4(0));
    }

    //Defines
    mGetFinalGatherHitPass.pProgram->addDefine("USE_PHOTON_CULLING", mUsePhotonCulling ? "1" : "0");
    mGetFinalGatherHitPass.pProgram->addDefine("ALLOW_HITS_IN_RADIUS", mAllowFinalGatherPointsInRadius ? "1" : "0");
    mGetFinalGatherHitPass.pProgram->addDefine("FILL_MASK", mpValidNeighborMask ? "1" : "0");

    if (!mGetFinalGatherHitPass.pVars) {
        FALCOR_ASSERT(mGetFinalGatherHitPass.pProgram);

        // Configure program.
        mGetFinalGatherHitPass.pProgram->addDefines(mpSampleGenerator->getDefines());
        mGetFinalGatherHitPass.pProgram->setTypeConformances(mpScene->getTypeConformances());
        // Create program variables for the current program.
        // This may trigger shader compilation. If it fails, throw an exception to abort rendering.
        mGetFinalGatherHitPass.pVars = RtProgramVars::create(mGetFinalGatherHitPass.pProgram, mGetFinalGatherHitPass.pBindingTable);

        // Bind utility classes into shared data.
        auto var = mGetFinalGatherHitPass.pVars->getRootVar();
        mpSampleGenerator->setShaderData(var);
    };
    FALCOR_ASSERT(mGetFinalGatherHitPass.pVars);

    auto var = mGetFinalGatherHitPass.pVars->getRootVar();

    //Set Constant Buffers
    std::string nameBuf = "PerFrame";
    var[nameBuf]["gFrameCount"] = mFrameCount;
    var[nameBuf]["gCollectionRadius"] = mPhotonCollectRadius;
    var[nameBuf]["gHashScaleFactor"] = 1.f / (2 * mPhotonCollectRadius[0]); //Take Global

    nameBuf = "Constant";
    var[nameBuf]["gHashSize"] = 1 << mCullingHashBufferSizeBits;
    var[nameBuf]["gUseAlphaTest"] = mPhotonUseAlphaTest;

    var["gVBuffer"] = renderData[kInVBufferDesc.name]->asTexture();
    var["gView"] = renderData[kInViewDesc.name]->asTexture();
    var["gLinZ"] = renderData[kInRayDistance.name]->asTexture();

    var["gSurfaceData"] = mpSurfaceBuffer[mFrameCount % 2];
    var["gFinalGatherHit"] = mpFinalGatherHit;
    var["gFinalGatherExtraInfo"] = mpFinalGatherExtraInfo;
    var["gPhotonCullingMask"] = mpPhotonCullingMask;
    var["gValidNeighborsMask"] = mpValidNeighborMask;

    //Create dimensions based on the number of VPLs
    uint2 targetDim = renderData.getDefaultTextureDims();
    FALCOR_ASSERT(targetDim.x > 0 && targetDim.y > 0);

    //Trace the photons
    mpScene->raytrace(pRenderContext, mGetFinalGatherHitPass.pProgram.get(), mGetFinalGatherHitPass.pVars, uint3(targetDim, 1));

    //Generate mips for mask
    if (mpValidNeighborMask)
        mpValidNeighborMask->generateMips(pRenderContext);
}

void PhotonReSTIRFinalGathering::generatePhotonsPass(RenderContext* pRenderContext, const RenderData& renderData)
{
    FALCOR_PROFILE("GeneratePhotons");
    //Clear Counter
    pRenderContext->clearUAV(mpPhotonCounter->getUAV().get(), uint4(0));
    pRenderContext->clearUAV(mpPhotonAABB[0]->getUAV().get(), uint4(0));
    pRenderContext->clearUAV(mpPhotonAABB[1]->getUAV().get(), uint4(0));

    //Defines
    mPhotonGeneratePass.pProgram->addDefine("PHOTON_BUFFER_SIZE_GLOBAL", std::to_string(mNumMaxPhotons[0]));
    mPhotonGeneratePass.pProgram->addDefine("PHOTON_BUFFER_SIZE_CAUSTIC", std::to_string(mNumMaxPhotons[1]));
    mPhotonGeneratePass.pProgram->addDefine("USE_PHOTON_CULLING", mUsePhotonCulling ? "1" : "0");

    if (!mPhotonGeneratePass.pVars) {
        FALCOR_ASSERT(mPhotonGeneratePass.pProgram);
        FALCOR_ASSERT(mpEmissiveLightSampler);

        // Configure program.
        mPhotonGeneratePass.pProgram->addDefines(mpSampleGenerator->getDefines());
        mPhotonGeneratePass.pProgram->addDefines(mpEmissiveLightSampler->getDefines());
        mPhotonGeneratePass.pProgram->setTypeConformances(mpScene->getTypeConformances());
        // Create program variables for the current program.
        // This may trigger shader compilation. If it fails, throw an exception to abort rendering.
        mPhotonGeneratePass.pVars = RtProgramVars::create(mPhotonGeneratePass.pProgram, mPhotonGeneratePass.pBindingTable);

        // Bind utility classes into shared data.
        auto var = mPhotonGeneratePass.pVars->getRootVar();
        mpSampleGenerator->setShaderData(var);
    };
    FALCOR_ASSERT(mPhotonGeneratePass.pVars);

    auto var = mPhotonGeneratePass.pVars->getRootVar();

    // Set constants (uniforms).
    // 
    //PerFrame Constant Buffer
    std::string nameBuf = "PerFrame";
    var[nameBuf]["gFrameCount"] = mFrameCount;
    var[nameBuf]["gPhotonRadius"] = mPhotonCollectRadius;
    var[nameBuf]["gHashScaleFactor"] = 1.f / (2 * mPhotonCollectRadius[0]);  //Hash scale factor. 1/diameter. Global Radius is used

    //Upload constant buffer only if options changed
    if (mReuploadBuffers) {
        nameBuf = "CB";
        var[nameBuf]["gMaxRecursion"] = mPhotonMaxBounces;
        var[nameBuf]["gRejection"] = mPhotonRejection;
        var[nameBuf]["gUseAlphaTest"] = mPhotonUseAlphaTest; 
        var[nameBuf]["gAdjustShadingNormals"] = mPhotonAdjustShadingNormal;
        var[nameBuf]["gHashSize"] = 1 << mCullingHashBufferSizeBits;    //Size of the Photon Culling buffer. 2^x
        var[nameBuf]["gEnableCaustics"] = mEnableCausticPhotonCollection;
        var[nameBuf]["gCausticsBounces"] = mMaxCausticBounces;
    }

    mpEmissiveLightSampler->setShaderData(var["Light"]["gEmissiveSampler"]);

    //Set the photon buffers
    for (uint32_t i = 0; i < 2; i++) {
        var["gPhotonAABB"][i] = mpPhotonAABB[i];
        var["gPackedPhotonData"][i] = mpPhotonData[i];
    }
    var["gPhotonCounter"] = mpPhotonCounter;
    var["gPhotonCullingMask"] = mpPhotonCullingMask;

    // Get dimensions of ray dispatch.
    const uint2 targetDim = uint2(mNumDispatchedPhotons/mPhotonYExtent, mPhotonYExtent);
    FALCOR_ASSERT(targetDim.x > 0 && targetDim.y > 0);

    //Trace the photons
    mpScene->raytrace(pRenderContext, mPhotonGeneratePass.pProgram.get(), mPhotonGeneratePass.pVars, uint3(targetDim, 1));

    pRenderContext->uavBarrier(mpPhotonCounter.get());
    pRenderContext->uavBarrier(mpPhotonAABB[0].get());
    pRenderContext->uavBarrier(mpPhotonData[0].get());
    pRenderContext->uavBarrier(mpPhotonAABB[1].get());
    pRenderContext->uavBarrier(mpPhotonData[1].get());

    //Build Acceleration Structure
    //Create as if not valid
    if (!mPhotonAS.tlas.pTlas) {
        mPhotonAS.update = false;
        createAccelerationStructure(pRenderContext, mPhotonAS, 2, { mNumMaxPhotons[0] , mNumMaxPhotons[1]}, {mpPhotonAABB[0]->getGpuAddress(), mpPhotonAABB[1]->getGpuAddress()});
    }
    uint2 currentPhotons = mFrameCount > 0 ? uint2(float2(mCurrentPhotonCount) * mASBuildBufferPhotonOverestimate) : mNumMaxPhotons;
    uint2 photonBuildSize = uint2(std::min(mNumMaxPhotons[0], currentPhotons[0]), std::min(mNumMaxPhotons[1], currentPhotons[1]));
    buildAccelerationStructure(pRenderContext, mPhotonAS, { photonBuildSize[0],photonBuildSize[1]});
}

void PhotonReSTIRFinalGathering::collectFinalGatherHitPhotons(RenderContext* pRenderContext, const RenderData& renderData)
{
    FALCOR_PROFILE("CollectPhotonsAndGenerateReservoir");
    pRenderContext->clearUAV(mpReservoirBuffer[mFrameCount % 2]->getUAV().get(), uint4(0));
    pRenderContext->clearUAV(mpPhotonLightBuffer[mFrameCount % 2]->getUAV().get(), uint4(0));
    //Also clear the initial candidates buffer
    if (mInitialCandidates > 0) {
        pRenderContext->clearUAV(mpReservoirBoostBuffer->getUAV().get(), uint4(0));
        pRenderContext->clearUAV(mpPhotonLightBoostBuffer->getUAV().get(), uint4(0));
    }
    

    //Defines
    mGeneratePMCandidatesPass.pProgram->addDefine("USE_REDUCED_RESERVOIR_FORMAT", mUseReducedReservoirFormat ? "1" : "0");

    if (!mGeneratePMCandidatesPass.pVars) {
        FALCOR_ASSERT(mGeneratePMCandidatesPass.pProgram);

        // Configure program.
        mGeneratePMCandidatesPass.pProgram->addDefines(mpSampleGenerator->getDefines());
        mGeneratePMCandidatesPass.pProgram->setTypeConformances(mpScene->getTypeConformances());
        // Create program variables for the current program.
        // This may trigger shader compilation. If it fails, throw an exception to abort rendering.
        mGeneratePMCandidatesPass.pVars = RtProgramVars::create(mGeneratePMCandidatesPass.pProgram, mGeneratePMCandidatesPass.pBindingTable);

        // Bind utility classes into shared data.
        auto var = mGeneratePMCandidatesPass.pVars->getRootVar();
        mpSampleGenerator->setShaderData(var);
    };
    FALCOR_ASSERT(mGeneratePMCandidatesPass.pVars);

    auto var = mGeneratePMCandidatesPass.pVars->getRootVar();

    //Set Constant Buffers
    std::string nameBuf = "PerFrame";
    var[nameBuf]["gFrameCount"] = mFrameCount;
    var[nameBuf]["gPhotonRadius"] = mPhotonCollectRadius.x;

    //Bind reservoir and light buffer depending on the boost buffer
    var["gReservoir"] = mInitialCandidates > 0 ? mpReservoirBoostBuffer : mpReservoirBuffer[mFrameCount % 2];
    var["gPhotonLights"] = mInitialCandidates > 0 ? mpPhotonLightBoostBuffer : mpPhotonLightBuffer[mFrameCount % 2];
    var["gPhotonAABB"] = mpPhotonAABB[0];
    var["gPackedPhotonData"] = mpPhotonData[0];
    var["gFinalGatherHit"] = mpFinalGatherHit;
    var["gFinalGatherExtraInfo"] = mpFinalGatherExtraInfo;

    bool tlasValid = var["gPhotonAS"].setSrv(mPhotonAS.tlas.pSrv);
    FALCOR_ASSERT(tlasValid);

    //Create dimensions based on the number of VPLs
    uint2 targetDim = renderData.getDefaultTextureDims();
    FALCOR_ASSERT(targetDim.x > 0 && targetDim.y > 0);

    //Trace the photons
    mpScene->raytrace(pRenderContext, mGeneratePMCandidatesPass.pProgram.get(), mGeneratePMCandidatesPass.pVars, uint3(targetDim, 1));

    //Barrier for written buffer depending if boosting is enabled
    pRenderContext->uavBarrier(mInitialCandidates > 0 ? mpReservoirBoostBuffer.get() : mpReservoirBuffer[mFrameCount % 2].get());
    pRenderContext->uavBarrier(mInitialCandidates > 0 ? mpPhotonLightBoostBuffer.get() : mpPhotonLightBuffer[mFrameCount % 2].get());
}

void PhotonReSTIRFinalGathering::collectCausticPhotons(RenderContext* pRenderContext, const RenderData& renderData)
{
    //Return if pass is disabled
    if (!mEnableCausticPhotonCollection) return;
    FALCOR_PROFILE("CollectCausticPhotons");
    pRenderContext->clearTexture(mpCausticPhotonsFlux[mFrameCount % 2].get());   //clear for now


    if (!mCollectCausticPhotonsPass.pVars) {
        FALCOR_ASSERT(mCollectCausticPhotonsPass.pProgram);

        // Configure program.
        mCollectCausticPhotonsPass.pProgram->addDefines(mpSampleGenerator->getDefines());
        mCollectCausticPhotonsPass.pProgram->setTypeConformances(mpScene->getTypeConformances());
        // Create program variables for the current program.
        // This may trigger shader compilation. If it fails, throw an exception to abort rendering.
        mCollectCausticPhotonsPass.pVars = RtProgramVars::create(mCollectCausticPhotonsPass.pProgram, mCollectCausticPhotonsPass.pBindingTable);

        // Bind utility classes into shared data.
        auto var = mCollectCausticPhotonsPass.pVars->getRootVar();
        mpSampleGenerator->setShaderData(var);
    };
    FALCOR_ASSERT(mCollectCausticPhotonsPass.pVars);

    auto var = mCollectCausticPhotonsPass.pVars->getRootVar();

    //Set Constant Buffers
    std::string nameBuf = "PerFrame";
    var[nameBuf]["gFrameCount"] = mFrameCount;
    var[nameBuf]["gPhotonRadius"] = mPhotonCollectRadius.y;
    var[nameBuf]["gEnableTemporalFilter"] = mCausticUseTemporalFilter;
    var[nameBuf]["gTemporalFilterHistoryLimit"] = mCausticTemporalFilterMaxHistory;

    //Bind caustic photon data (index -> 1)
    var["gPhotonAABB"] = mpPhotonAABB[1];
    var["gPackedPhotonData"] = mpPhotonData[1];

    //First diffuse hit data
    var["gVBuffer"] = renderData[kInVBufferDesc.name]->asTexture();
    var["gView"] = renderData[kInViewDesc.name]->asTexture();
    var["gMVec"] = renderData[kInMVecDesc.name]->asTexture();

    //Output flux
    var["gCausticImage"] = mpCausticPhotonsFlux[mFrameCount % 2];
    var["gCausticImagePrev"] = mpCausticPhotonsFlux[(mFrameCount + 1)% 2];

    //Bind Acceleration structure
    bool tlasValid = var["gPhotonAS"].setSrv(mPhotonAS.tlas.pSrv);
    FALCOR_ASSERT(tlasValid);

    //Create dimensions based on the number of VPLs
    uint2 targetDim = renderData.getDefaultTextureDims();
    FALCOR_ASSERT(targetDim.x > 0 && targetDim.y > 0);

    //Trace the photons
    mpScene->raytrace(pRenderContext, mCollectCausticPhotonsPass.pProgram.get(), mCollectCausticPhotonsPass.pVars, uint3(targetDim, 1));

    //Barrier for written buffer
    pRenderContext->uavBarrier(mpCausticPhotonsFlux[mFrameCount % 2].get());
}

/*
void PhotonReSTIRFinalGathering::distributeAndCollectFinalGatherPhotonPass(RenderContext* pRenderContext, const RenderData& renderData)
{
    FALCOR_PROFILE("CollectPhotons");

    if (!mDistributeAndCollectFinalGatherPointsPass.pVars) {
        FALCOR_ASSERT(mDistributeAndCollectFinalGatherPointsPass.pProgram);

        // Configure program.
        mDistributeAndCollectFinalGatherPointsPass.pProgram->addDefines(mpSampleGenerator->getDefines());
        mDistributeAndCollectFinalGatherPointsPass.pProgram->setTypeConformances(mpScene->getTypeConformances());
        // Create program variables for the current program.
        // This may trigger shader compilation. If it fails, throw an exception to abort rendering.
        mDistributeAndCollectFinalGatherPointsPass.pVars = RtProgramVars::create(mDistributeAndCollectFinalGatherPointsPass.pProgram, mDistributeAndCollectFinalGatherPointsPass.pBindingTable);

        // Bind utility classes into shared data.
        auto var = mDistributeAndCollectFinalGatherPointsPass.pVars->getRootVar();
        mpSampleGenerator->setShaderData(var);
    };
    FALCOR_ASSERT(mDistributeAndCollectFinalGatherPointsPass.pVars);

    auto var = mDistributeAndCollectFinalGatherPointsPass.pVars->getRootVar();

    //Set Constant Buffers
    std::string nameBuf = "PerFrame";
    var[nameBuf]["gFrameCount"] = mFrameCount;

    if (mReuploadBuffers) {
        nameBuf = "CB";
        var[nameBuf]["gPhotonRadius"] = mPhotonCollectRadius;
    }
    bindReservoirs(var, mFrameCount, false);
    var["gPhotonLights"] = mpPhotonLightBuffer[mFrameCount % 2];
    var["gVBuffer"] = renderData[kInVBufferDesc.name]->asTexture();
    var["gView"] = renderData[kInViewDesc.name]->asTexture();
    var["gPhotonAABB"] = mpPhotonAABB;
    var["gPackedPhotonData"] = mpPhotonData;
    var["gPhotonCounter"] = mpPhotonCounter;
    var["gSurfaceData"] = mpSurfaceBuffer[mFrameCount % 2];
    var[kInRayDistance.texname] = renderData[kInRayDistance.name]->asTexture();

    bool tlasValid = var["gPhotonAS"].setSrv(mPhotonAS.tlas.pSrv);
    FALCOR_ASSERT(tlasValid);

    //Create dimensions based on the number of VPLs
    uint2 targetDim = renderData.getDefaultTextureDims();
    FALCOR_ASSERT(targetDim.x > 0 && targetDim.y > 0);

    //Trace the photons
    mpScene->raytrace(pRenderContext, mDistributeAndCollectFinalGatherPointsPass.pProgram.get(), mDistributeAndCollectFinalGatherPointsPass.pVars, uint3(targetDim, 1));

    //Barrier for written buffer
    //pRenderContext->copyResource(mpReservoirBuffer[mFrameCount % 2].get(), mpReservoirBuffer[2].get()); //TODO solve that over index
    pRenderContext->uavBarrier(mpPhotonLightBuffer[mFrameCount % 2].get());
}
*/
void PhotonReSTIRFinalGathering::generateAdditionalCandidates(RenderContext* pRenderContext, const RenderData& renderData)
{
    if (mInitialCandidates == 0) return;   //Only execute pass if more than 1 candidate is requested

    FALCOR_PROFILE("Additional Candidates");

    if (mBiasCorrectionChanged) mpGenerateAdditionalCandidates.reset();
    //Create Pass
    if (!mpGenerateAdditionalCandidates) {
        Program::Desc desc;
        desc.addShaderLibrary(kShaderGenerateAdditionalCandidates).csEntry("main").setShaderModel("6_5");
        desc.addTypeConformances(mpScene->getTypeConformances());

        Program::DefineList defines;
        defines.add(mpScene->getSceneDefines());
        defines.add(mpSampleGenerator->getDefines());
        if (mUseDiffuseOnlyShading) defines.add("DIFFUSE_SHADING_ONLY");
        defines.add("BIAS_CORRECTION_MODE", std::to_string(mBiasCorrectionMode));
        defines.add(getValidResourceDefines(kInputChannels, renderData));
        if (mUseReducedReservoirFormat) defines.add("USE_REDUCED_RESERVOIR_FORMAT");

        mpGenerateAdditionalCandidates = ComputePass::create(desc, defines, true);
    }
    FALCOR_ASSERT(mpGenerateAdditionalCandidates);

    //Set variables
    auto var = mpGenerateAdditionalCandidates->getRootVar();

    mpScene->setRaytracingShaderData(pRenderContext, var, 1);   //Set scene data
    mpSampleGenerator->setShaderData(var);          //Sample generator

    var["gReservoir"] = mpReservoirBoostBuffer;
    var["gReservoirWrite"] = mpReservoirBuffer[mFrameCount % 2];
    var["gPhotonLight"] = mpPhotonLightBoostBuffer;
    var["gPhotonLightWrite"] = mpPhotonLightBuffer[mFrameCount % 2];
    var["gSurface"] = mpSurfaceBuffer[mFrameCount % 2];
    var[kInViewDesc.texname] = renderData[kInViewDesc.name]->asTexture();
    
    var["gNeighborMask"] = mpValidNeighborMask;

    //Uniform
    std::string uniformName = "PerFrame";
    var[uniformName]["gFrameCount"] = mFrameCount;
    if (mReset || mReuploadBuffers || mBiasCorrectionChanged) {
        uniformName = "Constant";
        var[uniformName]["gFrameDim"] = renderData.getDefaultTextureDims();
        var[uniformName]["gSpartialSamples"] = mInitialCandidates;
        var[uniformName]["gSamplingRadius"] = mSamplingRadius;
        var[uniformName]["gDepthThreshold"] = mRelativeDepthThreshold;
        var[uniformName]["gNormalThreshold"] = mNormalThreshold;
        var[uniformName]["gMaskMipLevel"] = mValidNeighborMaskMipLevel;
    }


    //Execute
    const uint2 targetDim = renderData.getDefaultTextureDims();
    FALCOR_ASSERT(targetDim.x > 0 && targetDim.y > 0);
    mpGenerateAdditionalCandidates->execute(pRenderContext, uint3(targetDim, 1));

    //Barrier for written buffer
    pRenderContext->uavBarrier(mpReservoirBuffer[mFrameCount % 2].get());
    pRenderContext->uavBarrier(mpPhotonLightBuffer[mFrameCount % 2].get());
}

void PhotonReSTIRFinalGathering::temporalResampling(RenderContext* pRenderContext, const RenderData& renderData)
{
    FALCOR_PROFILE("TemporalResampling");

    if (mBiasCorrectionChanged) mpTemporalResampling.reset();

    //Create Pass
    if (!mpTemporalResampling) {
        Program::Desc desc;
        desc.addShaderLibrary(kShaderTemporalPass).csEntry("main").setShaderModel("6_5");
        desc.addTypeConformances(mpScene->getTypeConformances());

        Program::DefineList defines;
        defines.add(mpScene->getSceneDefines());
        defines.add(mpSampleGenerator->getDefines());
        defines.add("BIAS_CORRECTION_MODE", std::to_string(mBiasCorrectionMode));
        if (mUseDiffuseOnlyShading) defines.add("DIFFUSE_SHADING_ONLY");
        defines.add(getValidResourceDefines(kInputChannels, renderData));
        if (mUseReducedReservoirFormat) defines.add("USE_REDUCED_RESERVOIR_FORMAT");

        mpTemporalResampling = ComputePass::create(desc, defines, true);
    }
    FALCOR_ASSERT(mpTemporalResampling);

    if (mReset) return; //Skip the rest on the first frame as the temporal buffer is invalid anyway

    //Set variables
    auto var = mpTemporalResampling->getRootVar();

    mpScene->setRaytracingShaderData(pRenderContext, var, 1);   //Set scene data
    mpSampleGenerator->setShaderData(var);          //Sample generator

    bindReservoirs(var, mFrameCount, true);
    bindPhotonLight(var, mFrameCount, true);
    var["gSurface"] = mpSurfaceBuffer[mFrameCount % 2];
    var["gSurfacePrev"] = mpSurfaceBuffer[(mFrameCount + 1) % 2];
    var[kInViewDesc.texname] = renderData[kInViewDesc.name]->asTexture();
    var["gPrevView"] = mpPrevViewTex;

    var[kInMVecDesc.texname] = renderData[kInMVecDesc.name]->asTexture();    //BindMvec

    //Uniform
    std::string uniformName = "PerFrame";
    var[uniformName]["gFrameCount"] = mFrameCount;
    if (mReset || mReuploadBuffers || mBiasCorrectionChanged) {
        uniformName = "Constant";
        var[uniformName]["gFrameDim"] = renderData.getDefaultTextureDims();
        var[uniformName]["gMaxAge"] = mTemporalMaxAge;
        var[uniformName]["gDepthThreshold"] = mRelativeDepthThreshold;
        var[uniformName]["gNormalThreshold"] = mNormalThreshold;
    }

    //Execute
    const uint2 targetDim = renderData.getDefaultTextureDims();
    FALCOR_ASSERT(targetDim.x > 0 && targetDim.y > 0);
    mpTemporalResampling->execute(pRenderContext, uint3(targetDim, 1));

    //Barrier for written buffer
    pRenderContext->uavBarrier(mpReservoirBuffer[mFrameCount % 2].get());
    pRenderContext->uavBarrier(mpPhotonLightBuffer[mFrameCount % 2].get());
}

void PhotonReSTIRFinalGathering::spartialResampling(RenderContext* pRenderContext, const RenderData& renderData)
{
    FALCOR_PROFILE("SpartialResampling");

    //Clear the other reservoir
    pRenderContext->clearUAV(mpReservoirBuffer[(mFrameCount + 1) % 2].get()->getUAV().get(), uint4(0));

    if (mBiasCorrectionChanged) mpSpartialResampling.reset();

    //Create Pass
    if (!mpSpartialResampling) {
        Program::Desc desc;
        desc.addShaderLibrary(kShaderSpartialPass).csEntry("main").setShaderModel("6_5");
        desc.addTypeConformances(mpScene->getTypeConformances());

        Program::DefineList defines;
        defines.add(mpScene->getSceneDefines());
        defines.add(mpSampleGenerator->getDefines());
        defines.add("BIAS_CORRECTION_MODE", std::to_string(mBiasCorrectionMode));
        defines.add("OFFSET_BUFFER_SIZE", std::to_string(kNumNeighborOffsets));
        if (mUseDiffuseOnlyShading) defines.add("DIFFUSE_SHADING_ONLY");
        if (mUseReducedReservoirFormat) defines.add("USE_REDUCED_RESERVOIR_FORMAT");
        defines.add(getValidResourceDefines(kInputChannels, renderData));

        mpSpartialResampling = ComputePass::create(desc, defines, true);
    }
    FALCOR_ASSERT(mpSpartialResampling);

    if (mReset) return; //Scip the rest on the first frame as the temporal buffer is invalid anyway

    //Set variables
    auto var = mpSpartialResampling->getRootVar();

    mpScene->setRaytracingShaderData(pRenderContext, var, 1);   //Set scene data
    mpSampleGenerator->setShaderData(var);          //Sample generator

    bindReservoirs(var, mFrameCount, true); //Use "Previous" as output
    bindPhotonLight(var, mFrameCount, true);
    var["gNeighOffsetBuffer"] = mpNeighborOffsetBuffer;
    var["gSurface"] = mpSurfaceBuffer[mFrameCount % 2];
    var[kInViewDesc.texname] = renderData[kInViewDesc.name]->asTexture();

    var[kInMVecDesc.texname] = renderData[kInMVecDesc.name]->asTexture();    //BindMvec

    //Uniform
    std::string uniformName = "PerFrame";
    var[uniformName]["gFrameCount"] = mFrameCount;
    if (mReset || mReuploadBuffers || mBiasCorrectionChanged) {
        uniformName = "Constant";
        var[uniformName]["gFrameDim"] = renderData.getDefaultTextureDims();
        var[uniformName]["gSpartialSamples"] = mSpartialSamples;
        var[uniformName]["gSamplingRadius"] = mSamplingRadius;
        var[uniformName]["gDepthThreshold"] = mRelativeDepthThreshold;
        var[uniformName]["gNormalThreshold"] = mNormalThreshold;
        var[uniformName]["gVplRadius"] = mPhotonCollectRadius;
    }

    //Execute
    const uint2 targetDim = renderData.getDefaultTextureDims();
    FALCOR_ASSERT(targetDim.x > 0 && targetDim.y > 0);
    mpSpartialResampling->execute(pRenderContext, uint3(targetDim, 1));

    //Barrier for written buffer
    pRenderContext->uavBarrier(mpReservoirBuffer[(mFrameCount + 1) % 2].get());
    pRenderContext->uavBarrier(mpPhotonLightBuffer[(mFrameCount+1) % 2].get());
}

void PhotonReSTIRFinalGathering::spartioTemporalResampling(RenderContext* pRenderContext, const RenderData& renderData)
{
    FALCOR_PROFILE("SpatioTemporalResampling");

    if (mBiasCorrectionChanged) mpSpartioTemporalResampling.reset();

    //Create Pass
    if (!mpSpartioTemporalResampling) {
        Program::Desc desc;
        desc.addShaderLibrary(kShaderSpartioTemporalPass).csEntry("main").setShaderModel("6_5");
        desc.addTypeConformances(mpScene->getTypeConformances());

        Program::DefineList defines;
        defines.add(mpScene->getSceneDefines());
        defines.add(mpSampleGenerator->getDefines());
        defines.add("BIAS_CORRECTION_MODE", std::to_string(mBiasCorrectionMode));
        defines.add("OFFSET_BUFFER_SIZE", std::to_string(kNumNeighborOffsets));
        if (mUseDiffuseOnlyShading) defines.add("DIFFUSE_SHADING_ONLY");
        if (mUseReducedReservoirFormat) defines.add("USE_REDUCED_RESERVOIR_FORMAT");
        defines.add(getValidResourceDefines(kInputChannels, renderData));

        mpSpartioTemporalResampling = ComputePass::create(desc, defines, true);
    }
    FALCOR_ASSERT(mpSpartioTemporalResampling);

    if (mReset) return; //Scip the rest on the first frame as the temporal buffer is invalid anyway

    //Set variables
    auto var = mpSpartioTemporalResampling->getRootVar();

    mpScene->setRaytracingShaderData(pRenderContext, var, 1);   //Set scene data
    mpSampleGenerator->setShaderData(var);          //Sample generator

    bindReservoirs(var, mFrameCount, true); //Use "Previous" as output
    bindPhotonLight(var, mFrameCount, true);
    var["gSurfacePrev"] = mpSurfaceBuffer[(mFrameCount + 1) % 2];
    var["gSurface"] = mpSurfaceBuffer[mFrameCount % 2];
    var[kInViewDesc.texname] = renderData[kInViewDesc.name]->asTexture();
    var["gPrevView"] = mpPrevViewTex;

    var[kInMVecDesc.texname] = renderData[kInMVecDesc.name]->asTexture();    //BindMvec

    //Uniform
    std::string uniformName = "PerFrame";
    var[uniformName]["gFrameCount"] = mFrameCount;
    if (mReset || mReuploadBuffers || mBiasCorrectionChanged) {
        uniformName = "Constant";
        var[uniformName]["gFrameDim"] = renderData.getDefaultTextureDims();
        var[uniformName]["gMaxAge"] = mTemporalMaxAge;
        var[uniformName]["gSpartialSamples"] = mSpartialSamples;
        var[uniformName]["gSamplingRadius"] = mSamplingRadius;
        var[uniformName]["gDepthThreshold"] = mRelativeDepthThreshold;
        var[uniformName]["gNormalThreshold"] = mNormalThreshold;
        var[uniformName]["gDisocclusionBoostSamples"] = mDisocclusionBoostSamples;
        var[uniformName]["gVplRadius"] = mPhotonCollectRadius;
    }

    //Execute
    const uint2 targetDim = renderData.getDefaultTextureDims();
    FALCOR_ASSERT(targetDim.x > 0 && targetDim.y > 0);
    mpSpartioTemporalResampling->execute(pRenderContext, uint3(targetDim, 1));

    //Barrier for written buffer
    pRenderContext->uavBarrier(mpReservoirBuffer[mFrameCount % 2].get());
    pRenderContext->uavBarrier(mpPhotonLightBuffer[mFrameCount % 2].get());
}

void PhotonReSTIRFinalGathering::finalShadingPass(RenderContext* pRenderContext, const RenderData& renderData)
{
    FALCOR_PROFILE("FinalShading");

    //Create pass
    if (!mpFinalShading) {
        Program::Desc desc;
        desc.addShaderLibrary(kShaderFinalShading).csEntry("main").setShaderModel("6_5");
        desc.addTypeConformances(mpScene->getTypeConformances());

        Program::DefineList defines;
        defines.add(mpScene->getSceneDefines());
        defines.add(mpSampleGenerator->getDefines());
        defines.add(getValidResourceDefines(kOutputChannels, renderData));
        defines.add(getValidResourceDefines(kInputChannels, renderData));
        if (mUseDiffuseOnlyShading) defines.add("DIFFUSE_SHADING_ONLY");
        if (mUseReducedReservoirFormat) defines.add("USE_REDUCED_RESERVOIR_FORMAT");

        mpFinalShading = ComputePass::create(desc, defines, true);
    }
    FALCOR_ASSERT(mpFinalShading);

    // For optional I/O resources, set 'is_valid_<name>' defines to inform the program of which ones it can access.
    mpFinalShading->getProgram()->addDefines(getValidResourceDefines(kOutputChannels, renderData));

    //Set variables
    auto var = mpFinalShading->getRootVar();

    // Lamda for binding textures. These needs to be done per-frame as the buffers may change anytime.
    auto bindAsTex = [&](const ChannelDesc& desc)
    {
        if (!desc.texname.empty())
        {
            var[desc.texname] = renderData[desc.name]->asTexture();
        }
    };

    mpScene->setRaytracingShaderData(pRenderContext, var, 1);   //Set scene data
    mpSampleGenerator->setShaderData(var);          //Sample generator

    uint reservoirIndex = mResamplingMode == ResamplingMode::Spartial ? (mFrameCount + 1) % 2 : mFrameCount % 2;

    bindReservoirs(var, reservoirIndex ,false);

    bindPhotonLight(var, reservoirIndex, false);
    var[kInViewDesc.texname] = renderData[kInViewDesc.name]->asTexture();
    bindAsTex(kInVBufferDesc);
    bindAsTex(kInMVecDesc);
    for (auto& out : kOutputChannels) bindAsTex(out);

    var["gCausticPhotons"] = mpCausticPhotonsFlux[mFrameCount % 2];

    //Uniform
    std::string uniformName = "PerFrame";
    var[uniformName]["gFrameCount"] = mFrameCount;
    if (mReset || mReuploadBuffers) {
        uniformName = "Constant";
        var[uniformName]["gFrameDim"] = renderData.getDefaultTextureDims();
        var[uniformName]["gEnableVisRay"] = mUseFinalVisibilityRay;
        var[uniformName]["gEnableCaustics"] = mEnableCausticPhotonCollection;
    }

    //Execute
    const uint2 targetDim = renderData.getDefaultTextureDims();
    FALCOR_ASSERT(targetDim.x > 0 && targetDim.y > 0);
    mpFinalShading->execute(pRenderContext, uint3(targetDim, 1));
}


void PhotonReSTIRFinalGathering::fillNeighborOffsetBuffer(std::vector<int8_t>& buffer)
{
    // Taken from the RTXDI implementation
    // 
    // Create a sequence of low-discrepancy samples within a unit radius around the origin
    // for "randomly" sampling neighbors during spatial resampling

    int R = 250;
    const float phi2 = 1.0f / 1.3247179572447f;
    uint32_t num = 0;
    float u = 0.5f;
    float v = 0.5f;
    while (num < kNumNeighborOffsets * 2) {
        u += phi2;
        v += phi2 * phi2;
        if (u >= 1.0f) u -= 1.0f;
        if (v >= 1.0f) v -= 1.0f;

        float rSq = (u - 0.5f) * (u - 0.5f) + (v - 0.5f) * (v - 0.5f);
        if (rSq > 0.25f)
            continue;

        buffer[num++] = int8_t((u - 0.5f) * R);
        buffer[num++] = int8_t((v - 0.5f) * R);
    }
}

void PhotonReSTIRFinalGathering::handelPhotonCounter(RenderContext* pRenderContext)
{
    //Copy the photonCounter to a CPU Buffer
    pRenderContext->copyBufferRegion(mpPhotonCounterCPU.get(), 0, mpPhotonCounter.get(), 0, sizeof(uint32_t) * 2);

    void* data = mpPhotonCounterCPU->map(Buffer::MapType::Read);
    std::memcpy(&mCurrentPhotonCount, data, sizeof(uint) * 2);
    mpPhotonCounterCPU->unmap();


    //Change Photon dispatch count dynamically.
    if (mUseDynamicePhotonDispatchCount) {

        //Only use global photons for the dynamic dispatch count
        uint globalPhotonCount = mCurrentPhotonCount[0];
        uint globalMaxPhotons = mNumMaxPhotons[0];
        //If counter is invalid, reset
        if (globalPhotonCount == 0) {
            mNumDispatchedPhotons = kDynamicPhotonDispatchInitValue;
        }
        uint bufferSizeCompValue =(uint)(globalMaxPhotons * (1.f - mPhotonDynamicGuardPercentage));
        uint changeSize = (uint)(globalMaxPhotons * mPhotonDynamicChangePercentage);

        //If smaller, increase dispatch size
        if(globalPhotonCount < bufferSizeCompValue){
            uint newDispatched = (uint)((mNumDispatchedPhotons + changeSize) / mPhotonYExtent) * mPhotonYExtent;    //mod YExtend == 0
            mNumDispatchedPhotons = std::min(newDispatched, mPhotonDynamicDispatchMax);
        }
        //If bigger, decrease dispatch size
        else if(globalPhotonCount >= globalMaxPhotons) {
            uint newDispatched = (uint)((mNumDispatchedPhotons - changeSize) / mPhotonYExtent) * mPhotonYExtent;    //mod YExtend == 0
            mNumDispatchedPhotons = std::max(newDispatched, mPhotonYExtent);
        }        
    }
}

void PhotonReSTIRFinalGathering::bindReservoirs(ShaderVar& var, uint index , bool bindPrev)
{
    var["gReservoir"] = mpReservoirBuffer[index % 2];
    if (bindPrev) {
        var["gReservoirPrev"] = mpReservoirBuffer[(index +1) % 2];
    }
}

void PhotonReSTIRFinalGathering::bindPhotonLight(ShaderVar& var, uint index, bool bindPrev) {
    var["gPhotonLight"] = mpPhotonLightBuffer[index % 2];
    if (bindPrev) {
        var["gPhotonLightPrev"] = mpPhotonLightBuffer[(index + 1) % 2];
    }
    /*
    switch (pass)
    {
    case CurrentPass::GenerateAdditional:
        var["gVpls"] = mpPhotonLightBuffer[index % 2];
        var["gVplsWrite"] = mpPhotonLightBuffer[2];
        break;
    case CurrentPass::Resampling:
        //Bind input vpls for resampling depending if we generated additional candidates
        if (mInitialCandidates > 0) {
            var["gVpls"] = mpPhotonLightBuffer[2];
        }
        else {
            var["gVpls"] = mpPhotonLightBuffer[index % 2];
        }
        var["gVplsWrite"] = mpPhotonLightBuffer[index % 2];
        var["gVplPrev"] = mpPhotonLightBuffer[(index + 1) % 2];
        break;
    case CurrentPass::SpartialResampling:
        //Bind input vpls for resampling depending if we generated additional candidates
        if (mInitialCandidates > 0) {
            var["gVpls"] = mpPhotonLightBuffer[2];
        }
        else {
            var["gVpls"] = mpPhotonLightBuffer[index % 2];
        }
        var["gVplsWrite"] = mpPhotonLightBuffer[(index + 1) % 2];
        break;
    case CurrentPass::FinalShading:
        var["gVpls"] = mpPhotonLightBuffer[index % 2];
        break;
    case CurrentPass::FinalShadingNoResampling:
        if (mInitialCandidates > 0) {
            var["gVpls"] = mpPhotonLightBuffer[2];
        }
        else {
            var["gVpls"] = mpPhotonLightBuffer[index % 2];
        }
        break;
    }
    */
}

void PhotonReSTIRFinalGathering::computePdfTextureSize(uint32_t maxItems, uint32_t& outWidth, uint32_t& outHeight, uint32_t& outMipLevels)
{
    // Compute the size of a power-of-2 rectangle that fits all items, 1 item per pixel
    double textureWidth = std::max(1.0, ceil(sqrt(double(maxItems))));
    textureWidth = exp2(ceil(log2(textureWidth)));
    double textureHeight = std::max(1.0, ceil(maxItems / textureWidth));
    textureHeight = exp2(ceil(log2(textureHeight)));
    double textureMips = std::max(1.0, log2(std::max(textureWidth, textureHeight)));

    outWidth = uint32_t(textureWidth);
    outHeight = uint32_t(textureHeight);
    outMipLevels = uint32_t(textureMips);
}

void PhotonReSTIRFinalGathering::createAccelerationStructure(RenderContext* pRenderContext, SphereAccelerationStructure& accel,const uint numberBlas,const std::vector<uint>& aabbCount,const std::vector<uint64_t>& aabbGpuAddress)
{
    //clear all previous data
    for (uint i = 0; i < accel.blas.size(); i++)
        accel.blas[i].reset();
    accel.blas.clear();
    accel.blasData.clear();
    accel.instanceDesc.clear();
    accel.tlasScratch.reset();
    accel.tlas.pInstanceDescs.reset();  accel.tlas.pSrv = nullptr;  accel.tlas.pTlas.reset();

    accel.numberBlas = numberBlas;

    createBottomLevelAS(pRenderContext, accel, aabbCount, aabbGpuAddress);
    createTopLevelAS(pRenderContext, accel);
}

void PhotonReSTIRFinalGathering::createTopLevelAS(RenderContext* pContext, SphereAccelerationStructure& accel)
{
    accel.instanceDesc.clear(); //clear to be sure that it is empty

    //fill the instance description if empty
    for (int i = 0; i < accel.numberBlas; i++) {
        D3D12_RAYTRACING_INSTANCE_DESC desc = {};
        desc.AccelerationStructure = accel.blas[i]->getGpuAddress();
        desc.Flags = D3D12_RAYTRACING_INSTANCE_FLAG_NONE;
        desc.InstanceID = i;
        desc.InstanceMask = accel.numberBlas < 8 ? 1 << i : 0xFF;  //For up to 8 they are instanced seperatly
        desc.InstanceContributionToHitGroupIndex = 0;

        //Create a identity matrix for the transform and copy it to the instance desc
        glm::mat4 transform4x4 = glm::identity<glm::mat4>();
        std::memcpy(desc.Transform, &transform4x4, sizeof(desc.Transform));
        accel.instanceDesc.push_back(desc);
    }

    D3D12_BUILD_RAYTRACING_ACCELERATION_STRUCTURE_INPUTS inputs = {};
    inputs.Type = D3D12_RAYTRACING_ACCELERATION_STRUCTURE_TYPE_TOP_LEVEL;
    inputs.DescsLayout = D3D12_ELEMENTS_LAYOUT_ARRAY;
    inputs.NumDescs = (uint32_t)accel.numberBlas;
    inputs.Flags = D3D12_RAYTRACING_ACCELERATION_STRUCTURE_BUILD_FLAG_PREFER_FAST_BUILD;

    //Prebuild
    FALCOR_GET_COM_INTERFACE(gpDevice->getApiHandle(), ID3D12Device5, pDevice5);
    pDevice5->GetRaytracingAccelerationStructurePrebuildInfo(&inputs, &accel.tlasPrebuildInfo);
    accel.tlasScratch = Buffer::create(accel.tlasPrebuildInfo.ScratchDataSizeInBytes, Buffer::BindFlags::UnorderedAccess, Buffer::CpuAccess::None);
    accel.tlasScratch->setName("PhotonReStir::TLAS_Scratch");

    //Create buffers for the TLAS
    accel.tlas.pTlas = Buffer::create(accel.tlasPrebuildInfo.ResultDataMaxSizeInBytes, Buffer::BindFlags::AccelerationStructure, Buffer::CpuAccess::None);
    accel.tlas.pTlas->setName("PhotonReStir::TLAS");
    accel.tlas.pInstanceDescs = Buffer::create((uint32_t)accel.numberBlas * sizeof(D3D12_RAYTRACING_INSTANCE_DESC), Buffer::BindFlags::None, Buffer::CpuAccess::Write, accel.instanceDesc.data());
    accel.tlas.pInstanceDescs->setName("PhotonReStir::TLAS_Instance_Description");

    //Acceleration Structure Buffer view for access in shader
    accel.tlas.pSrv = ShaderResourceView::createViewForAccelerationStructure(accel.tlas.pTlas);
}

void PhotonReSTIRFinalGathering::createBottomLevelAS(RenderContext* pContext, SphereAccelerationStructure& accel, const std::vector<uint> aabbCount, const std::vector<uint64_t> aabbGpuAddress)
{
    //Create Number of desired blas and reset max size
    accel.blasData.resize(accel.numberBlas);
    accel.blas.resize(accel.numberBlas);
    accel.blasScratchMaxSize = 0;

    FALCOR_ASSERT(aabbCount.size() >= accel.numberBlas);
    FALCOR_ASSERT(aabbGpuAddress.size() >= accel.numberBlas);

    //Prebuild
    for (size_t i = 0; i < accel.numberBlas; i++) {
        auto& blas = accel.blasData[i];

        //Create geometry description
        D3D12_RAYTRACING_GEOMETRY_DESC& desc = blas.geomDescs;
        desc.Type = D3D12_RAYTRACING_GEOMETRY_TYPE_PROCEDURAL_PRIMITIVE_AABBS;
        desc.Flags = D3D12_RAYTRACING_GEOMETRY_FLAG_NO_DUPLICATE_ANYHIT_INVOCATION;         //< Important! So that photons are not collected multiple times
        desc.AABBs.AABBCount = aabbCount[i];
        desc.AABBs.AABBs.StartAddress = aabbGpuAddress[i];
        desc.AABBs.AABBs.StrideInBytes = sizeof(D3D12_RAYTRACING_AABB);

        //Create input for blas
        D3D12_BUILD_RAYTRACING_ACCELERATION_STRUCTURE_INPUTS& inputs = blas.buildInputs;
        inputs.Type = D3D12_RAYTRACING_ACCELERATION_STRUCTURE_TYPE_BOTTOM_LEVEL;
        inputs.DescsLayout = D3D12_ELEMENTS_LAYOUT_ARRAY;
        inputs.NumDescs = 1;
        inputs.pGeometryDescs = &blas.geomDescs;

        //Build option flags
        inputs.Flags = accel.fastBuild ? D3D12_RAYTRACING_ACCELERATION_STRUCTURE_BUILD_FLAG_PREFER_FAST_BUILD : D3D12_RAYTRACING_ACCELERATION_STRUCTURE_BUILD_FLAG_PREFER_FAST_TRACE;
        if (accel.update) inputs.Flags |= D3D12_RAYTRACING_ACCELERATION_STRUCTURE_BUILD_FLAG_ALLOW_UPDATE;
        //get prebuild Info
        FALCOR_GET_COM_INTERFACE(gpDevice->getApiHandle(), ID3D12Device5, pDevice5);
        pDevice5->GetRaytracingAccelerationStructurePrebuildInfo(&blas.buildInputs, &blas.prebuildInfo);

        // Figure out the padded allocation sizes to have proper alignment.
        FALCOR_ASSERT(blas.prebuildInfo.ResultDataMaxSizeInBytes > 0);
        blas.blasByteSize = align_to((uint64_t)D3D12_RAYTRACING_ACCELERATION_STRUCTURE_BYTE_ALIGNMENT, blas.prebuildInfo.ResultDataMaxSizeInBytes);

        uint64_t scratchByteSize = std::max(blas.prebuildInfo.ScratchDataSizeInBytes, blas.prebuildInfo.UpdateScratchDataSizeInBytes);
        blas.scratchByteSize = align_to((uint64_t)D3D12_RAYTRACING_ACCELERATION_STRUCTURE_BYTE_ALIGNMENT, scratchByteSize);

        accel.blasScratchMaxSize = std::max(blas.scratchByteSize, accel.blasScratchMaxSize);
    }

    //Create the scratch and blas buffers
    accel.blasScratch = Buffer::create(accel.blasScratchMaxSize, Buffer::BindFlags::UnorderedAccess);
    accel.blasScratch->setName("PhotonReStir::BlasScratch");

    for (uint i = 0; i < accel.numberBlas; i++) {
        accel.blas[i] = Buffer::create(accel.blasData[i].blasByteSize, Buffer::BindFlags::AccelerationStructure);
        accel.blas[i]->setName("PhotonReStir::BlasBuffer" + std::to_string(i));
    }
}

void PhotonReSTIRFinalGathering::buildAccelerationStructure(RenderContext* pRenderContext, SphereAccelerationStructure& accel, const std::vector<uint>& aabbCount)
{
    //TODO check per assert if buffers are set
    buildBottomLevelAS(pRenderContext, accel, aabbCount);
    buildTopLevelAS(pRenderContext, accel);
}

void PhotonReSTIRFinalGathering::buildTopLevelAS(RenderContext* pContext, SphereAccelerationStructure& accel)
{
    FALCOR_PROFILE("buildPhotonTlas");

    D3D12_BUILD_RAYTRACING_ACCELERATION_STRUCTURE_INPUTS inputs = {};
    inputs.Type = D3D12_RAYTRACING_ACCELERATION_STRUCTURE_TYPE_TOP_LEVEL;
    inputs.DescsLayout = D3D12_ELEMENTS_LAYOUT_ARRAY;
    inputs.NumDescs = (uint32_t)accel.instanceDesc.size();
    //Update Flag could be set for TLAS. This made no real time difference in our test so it is left out. Updating could reduce the memory of the TLAS scratch buffer a bit
    inputs.Flags = accel.fastBuild ? D3D12_RAYTRACING_ACCELERATION_STRUCTURE_BUILD_FLAG_PREFER_FAST_BUILD : D3D12_RAYTRACING_ACCELERATION_STRUCTURE_BUILD_FLAG_PREFER_FAST_TRACE;
    if(accel.update) inputs.Flags |= D3D12_RAYTRACING_ACCELERATION_STRUCTURE_BUILD_FLAG_ALLOW_UPDATE;

    D3D12_BUILD_RAYTRACING_ACCELERATION_STRUCTURE_DESC asDesc = {};
    asDesc.Inputs = inputs;
    asDesc.Inputs.InstanceDescs = accel.tlas.pInstanceDescs->getGpuAddress();
    asDesc.ScratchAccelerationStructureData = accel.tlasScratch->getGpuAddress();
    asDesc.DestAccelerationStructureData = accel.tlas.pTlas->getGpuAddress();

    // Create TLAS
    FALCOR_GET_COM_INTERFACE(pContext->getLowLevelData()->getCommandList(), ID3D12GraphicsCommandList4, pList4);
    pContext->resourceBarrier(accel.tlas.pInstanceDescs.get(), Resource::State::NonPixelShader);
    pList4->BuildRaytracingAccelerationStructure(&asDesc, 0, nullptr);
    pContext->uavBarrier(accel.tlas.pTlas.get());                   //barrier for the tlas so it can be used savely after creation
}

void PhotonReSTIRFinalGathering::buildBottomLevelAS(RenderContext* pContext, SphereAccelerationStructure& accel, const std::vector<uint>& aabbCount)
{

    FALCOR_PROFILE("buildPhotonBlas");
    if (!gpDevice->isFeatureSupported(Device::SupportedFeatures::Raytracing))
    {
        throw std::exception("Raytracing is not supported by the current device");
    }

    for (size_t i = 0; i < accel.numberBlas; i++) {
        auto& blas = accel.blasData[i];

        //barriers for the scratch and blas buffer
        pContext->uavBarrier(accel.blasScratch.get());
        pContext->uavBarrier(accel.blas[i].get());

        blas.geomDescs.AABBs.AABBCount = static_cast<UINT64>(aabbCount[i]);

        //Fill the build desc struct
        D3D12_BUILD_RAYTRACING_ACCELERATION_STRUCTURE_DESC asDesc = {};
        asDesc.Inputs = blas.buildInputs;
        asDesc.ScratchAccelerationStructureData = accel.blasScratch->getGpuAddress();
        asDesc.DestAccelerationStructureData = accel.blas[i]->getGpuAddress();

        //Build the acceleration structure
        FALCOR_GET_COM_INTERFACE(pContext->getLowLevelData()->getCommandList(), ID3D12GraphicsCommandList4, pList4);
        pList4->BuildRaytracingAccelerationStructure(&asDesc, 0, nullptr);

        //Barrier for the blas
        pContext->uavBarrier(accel.blas[i].get());
    }
}
