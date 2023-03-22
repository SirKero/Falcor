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
#include "ReSTIRGI.h"
#include <RenderGraph/RenderPassHelpers.h>

const RenderPass::Info ReSTIRGI::kInfo { "ReSTIRGI", "Photon based indirect lighting pass using ReSTIR" };

// Don't remove this. it's required for hot-reload to function properly
extern "C" FALCOR_API_EXPORT const char* getProjDir()
{
    return PROJECT_DIR;
}

extern "C" FALCOR_API_EXPORT void getPasses(Falcor::RenderPassLibrary& lib)
{
    lib.registerPass(ReSTIRGI::kInfo, ReSTIRGI::create);
}

namespace {
    //Shaders
    const char kShaderGeneratePath[] = "RenderPasses/ReSTIRGI/generatePathSample.rt.slang";
    const char kShaderGenerateAdditionalCandidates[] = "RenderPasses/ReSTIRGI/generateAdditionalCandidates.cs.slang";
    const char kShaderTemporalPass[] = "RenderPasses/ReSTIRGI/temporalResampling.cs.slang";
    const char kShaderSpartialPass[] = "RenderPasses/ReSTIRGI/spartialResampling.cs.slang";
    const char kShaderSpartioTemporalPass[] = "RenderPasses/ReSTIRGI/spartioTemporalResampling.cs.slang";
    const char kShaderFinalShading[] = "RenderPasses/ReSTIRGI/finalShading.cs.slang";
    const char kShaderDebugPass[] = "RenderPasses/ReSTIRGI/debugPass.cs.slang";

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
        {ReSTIRGI::ResamplingMode::NoResampling , "No Resampling"},
        {ReSTIRGI::ResamplingMode::Temporal , "Temporal only"},
        {ReSTIRGI::ResamplingMode::Spartial , "Spartial only"},
        {ReSTIRGI::ResamplingMode::SpartioTemporal , "SpartioTemporal"},
    };

    const Gui::DropdownList kBiasCorrectionModeList{
        {ReSTIRGI::BiasCorrectionMode::Off , "Off"},
        {ReSTIRGI::BiasCorrectionMode::Basic , "Basic"},
        {ReSTIRGI::BiasCorrectionMode::RayTraced , "RayTraced"},
    };

    const Gui::DropdownList kVplEliminateModes{
        {ReSTIRGI::VplEliminationMode::Fixed , "Fixed"},
        {ReSTIRGI::VplEliminationMode::Linear , "Linear"},
        {ReSTIRGI::VplEliminationMode::Power , "Power"},
        {ReSTIRGI::VplEliminationMode::Root , "Root"},
    };
}

ReSTIRGI::SharedPtr ReSTIRGI::create(RenderContext* pRenderContext, const Dictionary& dict)
{
    SharedPtr pPass = SharedPtr(new ReSTIRGI());
    return pPass;
}

Dictionary ReSTIRGI::getScriptingDictionary()
{
    return Dictionary();
}

RenderPassReflection ReSTIRGI::reflect(const CompileData& compileData)
{
    // Define the required resources here
    RenderPassReflection reflector;
    addRenderPassInputs(reflector, kInputChannels);
    addRenderPassOutputs(reflector, kOutputChannels);
    return reflector;
}

void ReSTIRGI::execute(RenderContext* pRenderContext, const RenderData& renderData)
{
    //clear color output |TODO: Clear all valid outputs
    //pRenderContext->clearTexture(renderData[kOutColorDesc.name]->asTexture().get());

    //Return on empty scene
    if (!mpScene)
        return;

    if (mReset)
        resetPass();

    if (mPausePhotonReStir) {
        debugPass(pRenderContext, renderData);
        //Stop Debuging
        if (!mEnableDebug)
            mPausePhotonReStir = false;

        //Skip the rest
        return;
    }

    //Make sure that the emissive light is up to date
    mpScene->getLightCollection(pRenderContext);

    prepareLighting(pRenderContext);

    prepareBuffers(pRenderContext, renderData);

    //Get the final gather hits
    getFinalGatherHitPass(pRenderContext, renderData);

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

    if (mEnableDebug) {
        mPausePhotonReStir = true;
        if (renderData[kOutputChannels[0].name] != nullptr)
            pRenderContext->copyResource(mpDebugColorCopy.get(), renderData[kOutputChannels[0].name]->asTexture().get());
        if (renderData[kInVBufferDesc.name] != nullptr)
            pRenderContext->copyResource(mpDebugVBuffer.get(), renderData[kInVBufferDesc.name]->asTexture().get());
    }

   
    //Reset the reset vars
    mReuploadBuffers = mReset ? true : false;
    mBiasCorrectionChanged = false;
    mReset = false;
    mFrameCount++;
}

void ReSTIRGI::renderUI(Gui::Widgets& widget)
{
    bool changed = false;

    changed |= widget.slider("Sample Max Bounce", mSampleGenMaxBounces, 1u, 32u);


    if (auto group = widget.group("ReSTIR")) {
        changed |= widget.dropdown("ResamplingMode", kResamplingModeList, mResamplingMode);
        
        if (mResamplingMode > 0) {
            if (auto group = widget.group("Resamling")) {
                mBiasCorrectionChanged |= widget.dropdown("BiasCorrection", kBiasCorrectionModeList, mBiasCorrectionMode);

                changed |= widget.var("Depth Threshold", mRelativeDepthThreshold, 0.0f, 1.0f, 0.0001f);
                widget.tooltip("Relative depth threshold. 0.1 = within 10% of current depth (linZ)");

                changed |= widget.var("Normal Threshold", mNormalThreshold, 0.0f, 1.0f, 0.0001f);
                widget.tooltip("Maximum cosine of angle between normals. 1 = Exactly the same ; 0 = disabled");

                changed |= widget.var("Material Threshold", mMaterialThreshold, 0.0f, 1.0f, 0.0001f);
                widget.tooltip("Maximus absolute difference between the Diffuse probabilitys of the surfaces. 1 = Disabled ; 0 = Same surface");
            }
        }
        if ((mResamplingMode & ResamplingMode::Temporal) > 0) {
            if (auto group = widget.group("Temporal Options")) {
                changed |= widget.var("Temporal age", mTemporalMaxAge, 0u, 512u);
                widget.tooltip("Temporal age a sample should have");
            }
        }
        

        if (auto group = widget.group("Spartial Options")) {
            if ((mResamplingMode & ResamplingMode::Spartial) > 0) {
                changed |= widget.var("Spartial Samples", mSpartialSamples, 0u, mResamplingMode & ResamplingMode::SpartioTemporal ? 8u : 32u);
                widget.tooltip("Number of spartial samples");

                changed |= widget.var("Disocclusion Sample Boost", mDisocclusionBoostSamples, 0u, 32u);
                widget.tooltip("Number of spartial samples if no temporal surface was found. Needs to be bigger than \"Spartial Samples\" + 1 to have an effect");

                changed |= widget.var("Sampling Radius", mSamplingRadius, 0.0f, 200.f);
                widget.tooltip("Radius for the Spartial Samples");
            }

            changed |= widget.var("Sample Boosting (Adds Bias)", mSampleBoosting, 0u, 8u);
            changed |= widget.checkbox("Visibility check boost spatial sampling", mBoostSampleTestVisibility);
        }

        if (auto group = widget.group("Misc")) {
            changed |= widget.var("Sample Attenuation Radius", mSampleRadiusAttenuation, 0.0f, 500.f, 0.001f);
            widget.tooltip("The radius that is used for the non-linear sample attenuation(2/(d^2+r^2+d*sqrt(d^2+r^2))). At r=0 this leads to the normal 1/d^2");
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

void ReSTIRGI::setScene(RenderContext* pRenderContext, const Scene::SharedPtr& pScene)
{
    resetPass(true);

    mFrameCount = 0;
    //Recreate RayTracing Program on Scene reset
    mGeneratePathSample = RayTraceProgramHelper::create();

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

            rtHelper.pBindingTable = RtBindingTable::create(2, 2, mpScene->getGeometryCount());
            auto& sbt = rtHelper.pBindingTable;
            sbt->setRayGen(desc.addRayGen("rayGen"));
            sbt->setMiss(0, desc.addMiss("miss"));
            sbt->setMiss(1, desc.addMiss("missShadow"));
            if (mpScene->hasGeometryType(Scene::GeometryType::TriangleMesh)) {
                sbt->setHitGroup(0, mpScene->getGeometryIDs(Scene::GeometryType::TriangleMesh), desc.addHitGroup("closestHit", "anyHit"));
                sbt->setHitGroup(1, mpScene->getGeometryIDs(Scene::GeometryType::TriangleMesh), desc.addHitGroup("closestHitShadow"));
            }

            rtHelper.pProgram = RtProgram::create(desc, mpScene->getSceneDefines());
        };

        initStandardRTProgram(mGeneratePathSample, kShaderGeneratePath, kMaxPayloadSizeBytes);  //Get Final gather hit     
    }

}

void ReSTIRGI::resetPass(bool resetScene)
{
    mpTemporalResampling.reset();
    mpSpartialResampling.reset();
    mpSpartioTemporalResampling.reset();
    mpFinalShading.reset();
    mpGenerateAdditionalCandidates.reset();
    mpDebugPass.reset();

    if (resetScene) {
        mpEmissiveLightSampler.reset();
        mpSampleGenerator.reset();
    }

    mReuploadBuffers = true;
}

bool ReSTIRGI::prepareLighting(RenderContext* pRenderContext)
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
            mGeneratePathSample.pVars.reset();
            lightingChanged = true;
        }
    }

    //Update Emissive light sampler
    if (mpEmissiveLightSampler) {
        lightingChanged |= mpEmissiveLightSampler->update(pRenderContext);
    }

    return lightingChanged;
}

void ReSTIRGI::prepareBuffers(RenderContext* pRenderContext, const RenderData& renderData)
{
    //Has resolution changed ?
    if ((mScreenRes.x != renderData.getDefaultTextureDims().x) || (mScreenRes.y != renderData.getDefaultTextureDims().y) || mReset)
    {
        mScreenRes = renderData.getDefaultTextureDims();
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

    if (mSampleBoosting > 0) {
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

    if (mEnableDebug) {
        mpDebugColorCopy = Texture::create2D(mScreenRes.x, mScreenRes.y, ResourceFormat::RGBA16Float, 1, 1, nullptr, ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess | ResourceBindFlags::RenderTarget);
        mpDebugColorCopy->setName("PhotonReStir::DebugColorCopy");
        mpDebugVBuffer = Texture::create2D(mScreenRes.x, mScreenRes.y, HitInfo::kDefaultFormat, 1, 1, nullptr, ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess | ResourceBindFlags::RenderTarget);
        mpDebugVBuffer->setName("PhotonReStir::DebugVBufferCopy");
        mpDebugInfoBuffer = Buffer::create(sizeof(uint32_t) * 32, ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess);
        mpDebugInfoBuffer->setName("PhotonReStir::Debug");
        mDebugData.resize(8);
    }

}

void ReSTIRGI::getFinalGatherHitPass(RenderContext* pRenderContext, const RenderData& renderData)
{
    FALCOR_PROFILE("GetFinalGatheringHit");

    //Clear Reservoirs (Already done in passes)
    //pRenderContext->clearUAV(mpReservoirBuffer[mFrameCount % 2]->getUAV().get(), uint4(0));
    //pRenderContext->clearUAV(mpPhotonLightBuffer[mFrameCount % 2]->getUAV().get(), uint4(0));
    //Also clear the initial candidates buffer
    if (mSampleBoosting > 0) {
        pRenderContext->clearUAV(mpReservoirBoostBuffer->getUAV().get(), uint4(0));
        pRenderContext->clearUAV(mpPhotonLightBoostBuffer->getUAV().get(), uint4(0));
    }

    //Defines
    mGeneratePathSample.pProgram->addDefine("USE_REDUCED_RESERVOIR_FORMAT", mUseReducedReservoirFormat ? "1" : "0");
    mGeneratePathSample.pProgram->addDefine("USE_EMISSIVE_LIGHT", mpScene->useEmissiveLights() ? "1" : "0");
    mGeneratePathSample.pProgram->addDefine("USE_ANALYTIC_LIGHT", mpScene->useAnalyticLights() ? "1" : "0");
    

    if (!mGeneratePathSample.pVars) {
        FALCOR_ASSERT(mGeneratePathSample.pProgram);

        // Configure program.
        mGeneratePathSample.pProgram->addDefines(mpSampleGenerator->getDefines());
        mGeneratePathSample.pProgram->setTypeConformances(mpScene->getTypeConformances());
        if (mpEmissiveLightSampler)
            mGeneratePathSample.pProgram->addDefines(mpEmissiveLightSampler->getDefines());
        // Create program variables for the current program.
        // This may trigger shader compilation. If it fails, throw an exception to abort rendering.
        mGeneratePathSample.pVars = RtProgramVars::create(mGeneratePathSample.pProgram, mGeneratePathSample.pBindingTable);

        // Bind utility classes into shared data.
        auto var = mGeneratePathSample.pVars->getRootVar();
        mpSampleGenerator->setShaderData(var);
    };
    FALCOR_ASSERT(mGeneratePathSample.pVars);

    auto var = mGeneratePathSample.pVars->getRootVar();

    if (mpEmissiveLightSampler)
        mpEmissiveLightSampler->setShaderData(var["Light"]["gEmissiveSampler"]);

    //Set Constant Buffers
    std::string nameBuf = "PerFrame";
    var[nameBuf]["gFrameCount"] = mFrameCount;
    var[nameBuf]["gDiffuseOnly"] = mUseDiffuseOnlyShading;
    var[nameBuf]["gAttenuationRadius"] = mSampleRadiusAttenuation;

    nameBuf = "Constant";
    var[nameBuf]["gUseAlphaTest"] = mPhotonUseAlphaTest;
    var[nameBuf]["gDeltaRejection"] = mGenerationDeltaRejection;
    var[nameBuf]["gCreateFallbackSample"] = mCreateFallbackFinalGatherSample;
    var[nameBuf]["gMaxBounces"] = mSampleGenMaxBounces;

    var["gVBuffer"] = renderData[kInVBufferDesc.name]->asTexture();
    var["gView"] = renderData[kInViewDesc.name]->asTexture();
    var["gLinZ"] = renderData[kInRayDistance.name]->asTexture();

    var["gReservoir"] = mSampleBoosting > 0 ? mpReservoirBoostBuffer : mpReservoirBuffer[mFrameCount % 2];
    var["gSurfaceData"] = mpSurfaceBuffer[mFrameCount % 2];
    var["gLights"] = mSampleBoosting > 0 ? mpPhotonLightBoostBuffer : mpPhotonLightBuffer[mFrameCount % 2];

    //Create dimensions based on the number of VPLs
    uint2 targetDim = renderData.getDefaultTextureDims();
    FALCOR_ASSERT(targetDim.x > 0 && targetDim.y > 0);

    //Trace the photons
    mpScene->raytrace(pRenderContext, mGeneratePathSample.pProgram.get(), mGeneratePathSample.pVars, uint3(targetDim, 1));
}

void ReSTIRGI::generateAdditionalCandidates(RenderContext* pRenderContext, const RenderData& renderData)
{
    if (mSampleBoosting == 0) return;   //Only execute pass if more than 1 candidate is requested

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

    //Uniform
    std::string uniformName = "PerFrame";
    var[uniformName]["gFrameCount"] = mFrameCount;
    var[uniformName]["gTestVisibility"] = mBoostSampleTestVisibility;
    if (mReset || mReuploadBuffers || mBiasCorrectionChanged) {
        uniformName = "Constant";
        var[uniformName]["gFrameDim"] = renderData.getDefaultTextureDims();
        var[uniformName]["gSpartialSamples"] = mSampleBoosting;
        var[uniformName]["gSamplingRadius"] = mSamplingRadius;
        var[uniformName]["gDepthThreshold"] = mRelativeDepthThreshold;
        var[uniformName]["gNormalThreshold"] = mNormalThreshold;
        var[uniformName]["gMatThreshold"] = mMaterialThreshold;
        var[uniformName]["gAttenuationRadius"] = mSampleRadiusAttenuation; //Attenuation radius
    }


    //Execute
    const uint2 targetDim = renderData.getDefaultTextureDims();
    FALCOR_ASSERT(targetDim.x > 0 && targetDim.y > 0);
    mpGenerateAdditionalCandidates->execute(pRenderContext, uint3(targetDim, 1));

    //Barrier for written buffer
    pRenderContext->uavBarrier(mpReservoirBuffer[mFrameCount % 2].get());
    pRenderContext->uavBarrier(mpPhotonLightBuffer[mFrameCount % 2].get());
}

void ReSTIRGI::temporalResampling(RenderContext* pRenderContext, const RenderData& renderData)
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
        var[uniformName]["gMatThreshold"] = mMaterialThreshold;
        var[uniformName]["gAttenuationRadius"] = mSampleRadiusAttenuation; //Attenuation radius
    }

    //Execute
    const uint2 targetDim = renderData.getDefaultTextureDims();
    FALCOR_ASSERT(targetDim.x > 0 && targetDim.y > 0);
    mpTemporalResampling->execute(pRenderContext, uint3(targetDim, 1));

    //Barrier for written buffer
    pRenderContext->uavBarrier(mpReservoirBuffer[mFrameCount % 2].get());
    pRenderContext->uavBarrier(mpPhotonLightBuffer[mFrameCount % 2].get());
}

void ReSTIRGI::spartialResampling(RenderContext* pRenderContext, const RenderData& renderData)
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
        var[uniformName]["gMatThreshold"] = mMaterialThreshold;
        var[uniformName]["gAttenuationRadius"] = mSampleRadiusAttenuation; //Attenuation radius
    }

    //Execute
    const uint2 targetDim = renderData.getDefaultTextureDims();
    FALCOR_ASSERT(targetDim.x > 0 && targetDim.y > 0);
    mpSpartialResampling->execute(pRenderContext, uint3(targetDim, 1));

    //Barrier for written buffer
    pRenderContext->uavBarrier(mpReservoirBuffer[(mFrameCount + 1) % 2].get());
    pRenderContext->uavBarrier(mpPhotonLightBuffer[(mFrameCount+1) % 2].get());
}

void ReSTIRGI::spartioTemporalResampling(RenderContext* pRenderContext, const RenderData& renderData)
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
    var[uniformName]["gAttenuationRadius"] = mSampleRadiusAttenuation;
    if (mReset || mReuploadBuffers || mBiasCorrectionChanged) {
        uniformName = "Constant";
        var[uniformName]["gFrameDim"] = renderData.getDefaultTextureDims();
        var[uniformName]["gMaxAge"] = mTemporalMaxAge;
        var[uniformName]["gSpartialSamples"] = mSpartialSamples;
        var[uniformName]["gSamplingRadius"] = mSamplingRadius;
        var[uniformName]["gDepthThreshold"] = mRelativeDepthThreshold;
        var[uniformName]["gNormalThreshold"] = mNormalThreshold;
        var[uniformName]["gMatThreshold"] = mMaterialThreshold;
        var[uniformName]["gDisocclusionBoostSamples"] = mDisocclusionBoostSamples;
    }

    //Execute
    const uint2 targetDim = renderData.getDefaultTextureDims();
    FALCOR_ASSERT(targetDim.x > 0 && targetDim.y > 0);
    mpSpartioTemporalResampling->execute(pRenderContext, uint3(targetDim, 1));

    //Barrier for written buffer
    pRenderContext->uavBarrier(mpReservoirBuffer[mFrameCount % 2].get());
    pRenderContext->uavBarrier(mpPhotonLightBuffer[mFrameCount % 2].get());
}

void ReSTIRGI::finalShadingPass(RenderContext* pRenderContext, const RenderData& renderData)
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

    //Uniform
    std::string uniformName = "PerFrame";
    var[uniformName]["gFrameCount"] = mFrameCount;
    var[uniformName]["gAttenuationRadius"] = mSampleRadiusAttenuation; //Attenuation radius

    if (mReset || mReuploadBuffers) {
        uniformName = "Constant";
        var[uniformName]["gFrameDim"] = renderData.getDefaultTextureDims();
        var[uniformName]["gEnableVisRay"] = mUseFinalVisibilityRay;
    }

    //Execute
    const uint2 targetDim = renderData.getDefaultTextureDims();
    FALCOR_ASSERT(targetDim.x > 0 && targetDim.y > 0);
    mpFinalShading->execute(pRenderContext, uint3(targetDim, 1));
}

void ReSTIRGI::debugPass(RenderContext* pRenderContext, const RenderData& renderData)
{
    FALCOR_PROFILE("Debug");

    //Create pass
    if (!mpDebugPass) {
        Program::Desc desc;
        desc.addShaderLibrary(kShaderDebugPass).csEntry("main").setShaderModel("6_5");
        desc.addTypeConformances(mpScene->getTypeConformances());

        Program::DefineList defines;
        defines.add(mpScene->getSceneDefines());
        defines.add(mpSampleGenerator->getDefines());
        defines.add(getValidResourceDefines(kInputChannels, renderData));
        defines.add(getValidResourceDefines(kOutputChannels, renderData));
        if (mUseReducedReservoirFormat) defines.add("USE_REDUCED_RESERVOIR_FORMAT");

        mpDebugPass = ComputePass::create(desc, defines, true);
    }
    FALCOR_ASSERT(mpDebugPass);

    // For optional I/O resources, set 'is_valid_<name>' defines to inform the program of which ones it can access.
    mpDebugPass->getProgram()->addDefines(getValidResourceDefines(kOutputChannels, renderData));

    //Set variables
    auto var = mpDebugPass->getRootVar();

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

    bindReservoirs(var, (mFrameCount - 1 % 2), true);
    bindPhotonLight(var, (mFrameCount - 1 % 2), true);

    var["gOrigColor"] = mpDebugColorCopy;
    var["gOrigVBuffer"] = mpDebugVBuffer;
    var["gDebugData"] = mpDebugInfoBuffer;
    bindAsTex(kInVBufferDesc);
    bindAsTex(kOutputChannels[0]);

    //Uniform
    std::string uniformName = "PerFrame";
    var[uniformName]["gDebugPointRadius"] = mDebugPointRadius;
    var[uniformName]["gCurrentClickedPixel"] = mDebugCurrentClickedPixel;
    var[uniformName]["gCopyLastColor"] = mCopyLastColorImage;
    var[uniformName]["gCopyPixelData"] = mCopyPixelData;
    var[uniformName]["gDistanceFalloff"] = mDebugDistanceFalloff;
    var[uniformName]["gFrameDim"] = renderData.getDefaultTextureDims();

    //Execute
    const uint2 targetDim = renderData.getDefaultTextureDims();
    FALCOR_ASSERT(targetDim.x > 0 && targetDim.y > 0);
    mpDebugPass->execute(pRenderContext, uint3(targetDim, 1));

    if (mCopyPixelData) {
        pRenderContext->flush(true);

        void* data = mpDebugInfoBuffer->map(Buffer::MapType::Read);
        std::memcpy(mDebugData.data(), data, sizeof(uint) * 32);
        mpDebugInfoBuffer->unmap();
        mCopyPixelData = false;
    }

}

void ReSTIRGI::fillNeighborOffsetBuffer(std::vector<int8_t>& buffer)
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

void ReSTIRGI::bindReservoirs(ShaderVar& var, uint index , bool bindPrev)
{
    var["gReservoir"] = mpReservoirBuffer[index % 2];
    if (bindPrev) {
        var["gReservoirPrev"] = mpReservoirBuffer[(index +1) % 2];
    }
}

void ReSTIRGI::bindPhotonLight(ShaderVar& var, uint index, bool bindPrev) {
    var["gPhotonLight"] = mpPhotonLightBuffer[index % 2];
    if (bindPrev) {
        var["gPhotonLightPrev"] = mpPhotonLightBuffer[(index + 1) % 2];
    }
}

void ReSTIRGI::computePdfTextureSize(uint32_t maxItems, uint32_t& outWidth, uint32_t& outHeight, uint32_t& outMipLevels)
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

void ReSTIRGI::createAccelerationStructure(RenderContext* pRenderContext, SphereAccelerationStructure& accel,const uint numberBlas,const std::vector<uint>& aabbCount,const std::vector<uint64_t>& aabbGpuAddress)
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

void ReSTIRGI::createTopLevelAS(RenderContext* pContext, SphereAccelerationStructure& accel)
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

void ReSTIRGI::createBottomLevelAS(RenderContext* pContext, SphereAccelerationStructure& accel, const std::vector<uint> aabbCount, const std::vector<uint64_t> aabbGpuAddress)
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

void ReSTIRGI::buildAccelerationStructure(RenderContext* pRenderContext, SphereAccelerationStructure& accel, const std::vector<uint>& aabbCount)
{
    //TODO check per assert if buffers are set
    buildBottomLevelAS(pRenderContext, accel, aabbCount);
    buildTopLevelAS(pRenderContext, accel);
}

void ReSTIRGI::buildTopLevelAS(RenderContext* pContext, SphereAccelerationStructure& accel)
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

void ReSTIRGI::buildBottomLevelAS(RenderContext* pContext, SphereAccelerationStructure& accel, const std::vector<uint>& aabbCount)
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

bool ReSTIRGI::onMouseEvent(const MouseEvent& mouseEvent)
{
    if (mEnableDebug) {
        if (mouseEvent.type == MouseEvent::Type::ButtonDown && mouseEvent.button == Input::MouseButton::Right)
        {
            mDebugCurrentClickedPixel = uint2(mouseEvent.pos * float2(mScreenRes));
            mCopyPixelData = true;
            return true;
        }
    }
    return false;
}

bool ReSTIRGI::onKeyEvent(const KeyboardEvent& keyEvent) {
    if (mEnableDebug) {
        if (keyEvent.type == KeyboardEvent::Type::KeyPressed && keyEvent.key == Input::Key::O) {
            mCopyLastColorImage = !mCopyLastColorImage;     //Flip
            return true;
        }
    }
    return false;
}
