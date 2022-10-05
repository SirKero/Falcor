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
#include "PhotonReSTIRVPL.h"
#include <RenderGraph/RenderPassHelpers.h>

const RenderPass::Info PhotonReSTIRVPL::kInfo { "PhotonReSTIRVPL", "Photon based indirect lighting pass using ReSTIR" };

// Don't remove this. it's required for hot-reload to function properly
extern "C" FALCOR_API_EXPORT const char* getProjDir()
{
    return PROJECT_DIR;
}

extern "C" FALCOR_API_EXPORT void getPasses(Falcor::RenderPassLibrary& lib)
{
    lib.registerPass(PhotonReSTIRVPL::kInfo, PhotonReSTIRVPL::create);
}

namespace {
    //Shaders
    const char kShaderDistributeVPLs[] = "RenderPasses/PhotonReSTIRVPL/distributeVPLs.rt.slang";
    const char kShaderGeneratePhoton[] = "RenderPasses/PhotonReSTIRVPL/generatePhotons.rt.slang";
    const char kShaderCollectPhoton[] = "RenderPasses/PhotonReSTIRVPL/collectPhotons.rt.slang";
    const char kShaderPresampleLights[] = "RenderPasses/PhotonReSTIRVPL/presampleLights.cs.slang";
    const char kShaderFillSurfaceInformation[] = "RenderPasses/PhotonReSTIRVPL/fillSurfaceInfo.cs.slang";
    const char kShaderGenerateCandidates[] = "RenderPasses/PhotonReSTIRVPL/generateCandidates.cs.slang";
    const char kShaderCandidatesVisCheck[] = "RenderPasses/PhotonReSTIRVPL/candidatesVisCheck.rt.slang";
    const char kShaderTemporalPass[] = "RenderPasses/PhotonReSTIRVPL/temporalResampling.cs.slang";
    const char kShaderSpartialPass[] = "RenderPasses/PhotonReSTIRVPL/spartialResampling.cs.slang";
    const char kShaderSpartioTemporalPass[] = "RenderPasses/PhotonReSTIRVPL/spartioTemporalResampling.cs.slang";
    const char kShaderFinalShading[] = "RenderPasses/PhotonReSTIRVPL/finalShading.cs.slang";
    const char kShaderShowAABBVPLs[] = "RenderPasses/PhotonReSTIRVPL/showVPLsAABBcalc.cs.slang";
    const char kShaderShowVPLs[] = "RenderPasses/PhotonReSTIRVPL/showVPLs.rt.slang";
    const char kShaderDebugPhotonCollect[] = "RenderPasses/PhotonReSTIRVPL/debugPhotonCollect.rt.slang";    //TODO: Remove

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
    const ChannelDesc kOutDebugDesc = { "debug" ,"gDebug" , "For Debug Purposes" ,false,  ResourceFormat::RGBA32Float };     //TODO: Remove if not needed
    const ChannelList kOutputChannels =
    {
        kOutColorDesc,
        {"diffuseIllumination",     "gDiffuseIllumination",     "Diffuse Illumination and hit distance",    true,   ResourceFormat::RGBA16Float},
        {"diffuseReflectance",      "gDiffuseReflectance",      "Diffuse Reflectance",                      true,   ResourceFormat::RGBA16Float},
        {"specularIllumination",    "gSpecularIllumination",    "Specular illumination and hit distance",   true,   ResourceFormat::RGBA16Float},
        {"specularReflectance",     "gSpecularReflectance",     "Specular reflectance",                     true,   ResourceFormat::RGBA16Float},
        kOutDebugDesc,
    };

    const Gui::DropdownList kResamplingModeList{
        {PhotonReSTIRVPL::ResamplingMode::NoResampling , "No Resampling"},
        {PhotonReSTIRVPL::ResamplingMode::Temporal , "Temporal only"},
        {PhotonReSTIRVPL::ResamplingMode::Spartial , "Spartial only"},
        {PhotonReSTIRVPL::ResamplingMode::SpartioTemporal , "SpartioTemporal"},
    };

    const Gui::DropdownList kBiasCorrectionModeList{
        {PhotonReSTIRVPL::BiasCorrectionMode::Off , "Off"},
        {PhotonReSTIRVPL::BiasCorrectionMode::Basic , "Basic"},
        {PhotonReSTIRVPL::BiasCorrectionMode::RayTraced , "RayTraced"},
    };
}

PhotonReSTIRVPL::SharedPtr PhotonReSTIRVPL::create(RenderContext* pRenderContext, const Dictionary& dict)
{
    SharedPtr pPass = SharedPtr(new PhotonReSTIRVPL());
    return pPass;
}

Dictionary PhotonReSTIRVPL::getScriptingDictionary()
{
    return Dictionary();
}

RenderPassReflection PhotonReSTIRVPL::reflect(const CompileData& compileData)
{
    // Define the required resources here
    RenderPassReflection reflector;
    addRenderPassInputs(reflector, kInputChannels);
    addRenderPassOutputs(reflector, kOutputChannels);
    return reflector;
}

void PhotonReSTIRVPL::execute(RenderContext* pRenderContext, const RenderData& renderData)
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

    //Distribute the vpls
    if (mFrameCount == 0 || mResetVPLs) {
        distributeVPLsPass(pRenderContext, renderData);
    }
    //Generate Photons
    generatePhotonsPass(pRenderContext, renderData);

    collectPhotonsPass(pRenderContext, renderData);

    //Presample generated photon lights
    presamplePhotonLightsPass(pRenderContext, renderData);

    //Copy the counter for UI
    copyPhotonCounter(pRenderContext);
    
    //Prepare the surface buffer
    prepareSurfaceBufferPass(pRenderContext, renderData);

    //Generate Candidates
    generateCandidatesPass(pRenderContext, renderData);

    //Check candidates visibility. Only performed when !mUseVisibilityRayInline
    candidatesVisibilityCheckPass(pRenderContext, renderData);

    //Spartiotemporal Resampling
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
    
    //Show the vpls as spheres for debug purposes (functions return if deactivated)
    showVPLDebugPass(pRenderContext, renderData);

    //Copy view buffer if it is used
    if (renderData[kInViewDesc.name] != nullptr) {
        pRenderContext->copyResource(mpPrevViewTex.get(), renderData[kInViewDesc.name]->asTexture().get());
    }

    //Reset the reset vars
    mReuploadBuffers = mReset ? true : false;
    mBiasCorrectionChanged = false;
    mReset = false;
    mFrameCount++;
}

void PhotonReSTIRVPL::renderUI(Gui::Widgets& widget)
{
    bool changed = false;

    if (auto group = widget.group("PhotonMapper")) {
        //Dispatched Photons
        uint dispatchedPhotons = mNumDispatchedPhotons;
        bool disPhotonChanged = widget.var("Dispatched Photons", dispatchedPhotons, mPhotonYExtent, 9984000u, (float)mPhotonYExtent);
        if (disPhotonChanged)
            mNumDispatchedPhotons = (uint)(dispatchedPhotons / mPhotonYExtent) * mPhotonYExtent;
        //Buffer size
        widget.text("Photon Lights: " + std::to_string(mCurrentPhotonLightsCount) + " / " + std::to_string(mNumMaxPhotons));
        widget.var("Photon Light Buffer Size", mNumMaxPhotonsUI, 100u, 100000000u, 100);
        mChangePhotonLightBufferSize = widget.button("Apply", true);
        if (mChangePhotonLightBufferSize) mNumMaxPhotons = mNumMaxPhotonsUI;

        changed |= widget.var("Light Store Probability", mPhotonRejection, 0.f, 1.f, 0.0001f);
        widget.tooltip("Probability a photon light is stored on diffuse hit. Flux is scaled up appropriately");

        changed |= widget.var("Max Bounces", mPhotonMaxBounces, 0u, 32u);

        changed |= widget.checkbox("Use Alpha Test", mPhotonUseAlphaTest);
        changed |= widget.checkbox("Adjust Shading Normal", mPhotonAdjustShadingNormal);
    }

    if (auto group = widget.group("VPL")) {

        changed |= widget.var("Radius", mVPLCollectionRadius);
        widget.tooltip("Collection Radius for the VPLs");
        changed |= widget.checkbox("Use BSDF sampled distribution", mDistributeVplUseBsdfSampling);
        widget.tooltip("If enabled use bsdf sampling for distribution. If disabled cosine distribution (diffuse) is used");
        changed |= widget.checkbox("Show VPLs", mShowVPLs);
        if (mShowVPLs) {
            widget.var("Debug Scalar", mShowVPLsScalar);
        }
        mResetVPLs = widget.button("Redistribute VPLs");
        changed |= mResetVPLs;
    }

    if (auto group = widget.group("ReSTIR")) {
        changed |= widget.dropdown("ResamplingMode", kResamplingModeList, mResamplingMode);
        //UI here
        changed |= widget.var("Initial Emissive Candidates", mNumEmissiveCandidates, 0u, 4096u);
        widget.tooltip("Number of emissive candidates generated per iteration");

        if (auto group = widget.group("Light Sampling")) {
            bool changeCheck = mUsePdfSampling;
            changed |= widget.checkbox("Use PDF Sampling",mUsePdfSampling);
            if (changeCheck != mUsePdfSampling) {
                mpGenerateCandidates.reset();
            }
            widget.tooltip("If enabled use a pdf texture to generate the samples. If disabled the light is sampled uniformly");
            if (mUsePdfSampling) {
                widget.text("Presample texture size");
                widget.var("Title Count", mPresampledTitleSizeUI.x, 1u, 1024u);
                widget.var("Title Size", mPresampledTitleSizeUI.y, 256u, 8192u, 256.f);
                mPresampledTitleSizeChanged |= widget.button("Apply");
                if (mPresampledTitleSizeChanged) {
                    mPresampledTitleSize = mPresampledTitleSizeUI;
                    changed |= true;
                }
                    
            }
        }

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
                changed |= widget.var("Spartial Samples", mSpartialSamples, 0u, 32u);
                widget.tooltip("Number of spartial samples");

                changed |= widget.var("Disocclusion Sample Boost", mDisocclusionBoostSamples, 0u, 32u);
                widget.tooltip("Number of spartial samples if no temporal surface was found. Needs to be bigger than \"Spartial Samples\" + 1 to have an effect");

                changed |= widget.var("Sampling Radius", mSamplingRadius, 0.0f, 200.f);
                widget.tooltip("Radius for the Spartial Samples");
            }
        }

        if (auto group = widget.group("Misc")) {
            bool visChanged = widget.checkbox("Use Visbility Tracing Inline", mUseVisibiltyRayInline);
            widget.tooltip("If enabled uses inline ray tracing for the visibility ray in Candidate Generate");
            if (visChanged) {
                mpGenerateCandidates.reset();   //Reset the pass (Recompile shader)
                changed = true;
            }
            changed |= widget.checkbox("Use Emissive Texture", mUseEmissiveTexture);
            widget.tooltip("Activate to use the Emissive texture in the final shading step. More correct but noisier");
            changed |= widget.checkbox("Use Final Shading Visibility Ray", mUseFinalVisibilityRay);
            widget.tooltip("Enables a Visibility ray in final shading. Can reduce bias as Reservoir Visibility rays ignore opaque geometry");
            mReset |= widget.var("Visibility Ray TMin Offset", mVisibilityRayOffset, 0.00001f, 10.f, 0.00001f);
            widget.tooltip("Changes offset for visibility ray. Triggers recompilation so typing in the value is advised");
            changed |= widget.var("Geometry Term Band", mGeometryTermBand, 0.f, 1.f, 0.0000001f);
            widget.tooltip("Discards samples with a very small distance. Adds a little bias but removes extremly bright spots at corners");
        }
    }
   

    mReset |= widget.button("Recompile");
    mReuploadBuffers |= changed;
}

void PhotonReSTIRVPL::setScene(RenderContext* pRenderContext, const Scene::SharedPtr& pScene)
{
    resetPass(true);

    mFrameCount = 0;
    //Recreate RayTracing Program on Scene reset
    mPhotonGeneratePass = RayTraceProgramHelper::create();
    mDistributeVPlsPass = RayTraceProgramHelper::create();
    mCollectPhotonsPass = RayTraceProgramHelper::create();
    mVisibilityCheckPass = RayTraceProgramHelper::create();

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

        initStandardRTProgram(mPhotonGeneratePass, kShaderGeneratePhoton, kMaxPayloadSizeBytes);    //Generate Photons
        initStandardRTProgram(mDistributeVPlsPass, kShaderDistributeVPLs, kMaxPayloadSizeBytesVPL);  //Distributre VPLs

        //Init the raytracing collection programm
        {
            RtProgram::Desc desc;
            desc.addShaderLibrary(kShaderCollectPhoton);
            //desc.addShaderLibrary(kShaderDebugPhotonCollect);
            desc.setMaxPayloadSize(kMaxPayloadSizeBytesCollect);
            desc.setMaxAttributeSize(kMaxAttributeSizeBytes);
            desc.setMaxTraceRecursionDepth(kMaxRecursionDepth);

            //Scene geometry count is needed as the scene acceleration struture bound with the scene defines
            mCollectPhotonsPass.pBindingTable = RtBindingTable::create(1, 1, mpScene->getGeometryCount());
            auto& sbt = mCollectPhotonsPass.pBindingTable;
            sbt->setRayGen(desc.addRayGen("rayGen"));
            sbt->setMiss(0, desc.addMiss("miss"));
            sbt->setHitGroup(0, 0, desc.addHitGroup("", "anyHit", "intersection"));
            
            mCollectPhotonsPass.pProgram = RtProgram::create(desc, mpScene->getSceneDefines());
        }
    }

}

void PhotonReSTIRVPL::resetPass(bool resetScene)
{
    mpFillSurfaceInfoPass.reset();
    mpGenerateCandidates.reset();
    mpTemporalResampling.reset();
    mpSpartialResampling.reset();
    mpSpartioTemporalResampling.reset();
    mpFinalShading.reset();

    if (resetScene) {
        mpEmissiveLightSampler.reset();
    }

    mReuploadBuffers = true;
}

bool PhotonReSTIRVPL::prepareLighting(RenderContext* pRenderContext)
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

void PhotonReSTIRVPL::preparePhotonBuffers(RenderContext* pRenderContext,const RenderData& renderData)
{
        
    if (mChangePhotonLightBufferSize) {
        mpPhotonAABB.reset();
        mpPhotonData.reset();
        mPhotonAS.tlas.pTlas.reset();       //This triggers photon as recreation
        mChangePhotonLightBufferSize = false;
    }
    
    if (!mpPhotonCounter) {
        mpPhotonCounter = Buffer::create(sizeof(uint));
        mpPhotonCounter->setName("PhotonReSTIRVPL::PhotonCounterGPU");
    }
    if (!mpPhotonCounterCPU) {
        mpPhotonCounterCPU = Buffer::create(sizeof(uint),ResourceBindFlags::None, Buffer::CpuAccess::Read);
        mpPhotonCounterCPU->setName("PhotonReSTIRVPL::PhotonCounterCPU");
    }
    if (!mpPhotonAABB) {
        mpPhotonAABB = Buffer::createStructured(sizeof(D3D12_RAYTRACING_AABB), mNumMaxPhotons);
        mpPhotonAABB->setName("PhotonReStir::PhotonAABB");
    }
    if (!mpPhotonData) {
        mpPhotonData = Buffer::createStructured(sizeof(uint) * 4, mNumMaxPhotons);
        mpPhotonData->setName("PhotonReStir::PhotonData");
    }

}

void PhotonReSTIRVPL::prepareBuffers(RenderContext* pRenderContext, const RenderData& renderData)
{
    //Has resolution changed ?
    if ((mScreenRes.x != renderData.getDefaultTextureDims().x) || (mScreenRes.y != renderData.getDefaultTextureDims().y) || mReset)
    {
        mScreenRes = renderData.getDefaultTextureDims();
        for (size_t i = 0; i <= 1; i++) {
            mpReservoirBuffer[i].reset();
            mpSurfaceBuffer[i].reset();
            mpPrevViewTex.reset();
        }
        mReuploadBuffers = true; 
    }

    if (!mpReservoirBuffer[0] || !mpReservoirBuffer[1]) {
        mpReservoirBuffer[0] = Texture::create2D(renderData.getDefaultTextureDims().x, renderData.getDefaultTextureDims().y, ResourceFormat::RGBA32Uint,
                                                 1, 1, nullptr, ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess);
        mpReservoirBuffer[0]->setName("PhotonReStir::ReservoirBuf1");
        mpReservoirBuffer[1] = Texture::create2D(renderData.getDefaultTextureDims().x, renderData.getDefaultTextureDims().y, ResourceFormat::RGBA32Uint,
                                                 1, 1, nullptr, ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess);
        mpReservoirBuffer[1]->setName("PhotonReStir::ReservoirBuf2");
    }
   
    
    //Create a buffer filled with surface info for current and last frame
    if (!mpSurfaceBuffer[0] || !mpSurfaceBuffer[1]) {
        uint2 texDim = renderData.getDefaultTextureDims();
        uint bufferSize = texDim.x * texDim.y;
        mpSurfaceBuffer[0] = Buffer::createStructured(sizeof(uint) * 8, bufferSize);
        mpSurfaceBuffer[0]->setName("PhotonReStir::SurfaceBuffer1");
        mpSurfaceBuffer[1] = Buffer::createStructured(sizeof(uint) * 8, bufferSize);
        mpSurfaceBuffer[1]->setName("PhotonReStir::SurfaceBuffer2");
    }

    //Create an fill the neighbor offset buffer
    if (!mpNeighborOffsetBuffer) {
        std::vector<int8_t> offsets(2 * kNumNeighborOffsets);
        fillNeighborOffsetBuffer(offsets);

        mpNeighborOffsetBuffer = Texture::create1D(kNumNeighborOffsets, ResourceFormat::RG8Snorm, 1, 1, offsets.data());


        mpNeighborOffsetBuffer->setName("PhotonReStir::NeighborOffsetBuffer");
    }

    //Create buffer for VPLs
    if (!mpVPLBuffer) {
        mpVPLBuffer = Buffer::createStructured(sizeof(uint) * 6, mNumberVPL, ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess,
                                               Buffer::CpuAccess::None, nullptr, false);
        mpVPLBuffer->setName("PhotonReStir::VPLBuffer");
    }
    if (!mpVPLBufferCounter) {
        uint counterInit = 0;
        mpVPLBufferCounter = Buffer::create(sizeof(uint), ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess,
                                            Buffer::CpuAccess::None, &counterInit);
        mpVPLBufferCounter->setName("PhotonReStir::VPLBufferCounter");
    }
    if (!mpVPLSurface) {
        //Reuse same size as a pdf texture would use
        uint width, height, mip;
        computePdfTextureSize(mNumberVPL, width, height, mip);
        mpVPLSurface = Texture::create2D(width, height, HitInfo::kDefaultFormat, 1u, 1u, nullptr,
                                         ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess);
        mpVPLSurface->setName("PhotonReSTIRVPL::VplSurface");
    }

    //Create pdf texture
    if (mUsePdfSampling) {
        uint width, height, mip;
        computePdfTextureSize(mNumberVPL, width, height, mip);
        if (!mpLightPdfTex || mpLightPdfTex->getWidth() != width || mpLightPdfTex->getHeight() != height || mpLightPdfTex->getMipCount() != mip) {
            mpLightPdfTex = Texture::create2D(width, height, ResourceFormat::R16Float, 1u, mip, nullptr,
                                              ResourceBindFlags::UnorderedAccess | ResourceBindFlags::ShaderResource | ResourceBindFlags::RenderTarget);
            mpLightPdfTex->setName("PhotonReSTIRVPL::PhotonLightPdfTex");
        }

        //Create Buffer for the presampled lights
        if (!mpPresampledLights || mPresampledTitleSizeChanged) {
            mpPresampledLights = Buffer::createStructured(sizeof(uint2), mPresampledTitleSize.x * mPresampledTitleSize.y);
            mpPresampledLights->setName("PhotonReSTIRVPL::PresampledPhotonLights");
            mPresampledTitleSizeChanged = false;
        }
    }
    //Reset buffers if they exist
    else {
        if (mpLightPdfTex)mpLightPdfTex.reset();
        if (mpPresampledLights) mpPresampledLights.reset();
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
}

void PhotonReSTIRVPL::prepareSurfaceBufferPass(RenderContext* pRenderContext, const RenderData& renderData)
{
    FALCOR_PROFILE("FillSurfaceBuffer");

    //init
    if (!mpFillSurfaceInfoPass) {
        Program::Desc desc;
        desc.addShaderLibrary(kShaderFillSurfaceInformation).csEntry("main").setShaderModel("6_5");
        desc.addTypeConformances(mpScene->getTypeConformances());

        Program::DefineList defines;
        defines.add(mpScene->getSceneDefines());
        defines.add(getValidResourceDefines(kInputChannels, renderData));
        mpFillSurfaceInfoPass = ComputePass::create(desc, defines, true);
    }
    FALCOR_ASSERT(mpFillSurfaceInfoPass);

    //Set variables
    auto var = mpFillSurfaceInfoPass->getRootVar();

    // Lamda for binding textures. These needs to be done per-frame as the buffers may change anytime.
    auto bindAsTex = [&](const ChannelDesc& desc)
    {
        if (!desc.texname.empty())
        {
            var[desc.texname] = renderData[desc.name]->asTexture();
        }
    };
    bindAsTex(kInVBufferDesc);
    mpScene->setRaytracingShaderData(pRenderContext, var, 1);   //Set scene data
    var["gSurfaceData"] = mpSurfaceBuffer[mFrameCount % 2];
    var[kInViewDesc.texname] = renderData[kInViewDesc.name]->asTexture();
    var[kInRayDistance.texname] = renderData[kInRayDistance.name]->asTexture();

    if (mReset || mReuploadBuffers) {
        var["Constant"]["gFrameDim"] = renderData.getDefaultTextureDims();
    }

    //Execute
    const uint2 targetDim = renderData.getDefaultTextureDims();
    FALCOR_ASSERT(targetDim.x > 0 && targetDim.y > 0);
    mpFillSurfaceInfoPass->execute(pRenderContext, uint3(targetDim, 1));

    // Barrier for written buffer
    pRenderContext->uavBarrier(mpSurfaceBuffer[mFrameCount % 2].get());
}

void PhotonReSTIRVPL::distributeVPLsPass(RenderContext* pRenderContext, const RenderData& renderData)
{
    FALCOR_PROFILE("DistributeVPLs");

    if (mResetVPLs) {
        pRenderContext->clearUAV(mpVPLBuffer->getUAV().get(), uint4(0));
        pRenderContext->clearUAV(mpVPLBufferCounter->getUAV().get(), uint4(0));
        pRenderContext->clearTexture(renderData[kOutDebugDesc.name]->asTexture().get());
        mResetVPLs = false;
    }

    //Defines
    mDistributeVPlsPass.pProgram->addDefine("USE_BSDF_SAMPLING", mDistributeVplUseBsdfSampling ? "1" : "0");
    if (!mDistributeVPlsPass.pVars) {
        FALCOR_ASSERT(mDistributeVPlsPass.pProgram);

        // Configure program.
        mDistributeVPlsPass.pProgram->addDefines(mpSampleGenerator->getDefines());
        mDistributeVPlsPass.pProgram->setTypeConformances(mpScene->getTypeConformances());
        mDistributeVPlsPass.pProgram->addDefines(getValidResourceDefines(kInputChannels, renderData));
        // Create program variables for the current program.
        // This may trigger shader compilation. If it fails, throw an exception to abort rendering.
        mDistributeVPlsPass.pVars = RtProgramVars::create(mDistributeVPlsPass.pProgram, mDistributeVPlsPass.pBindingTable);

        // Bind utility classes into shared data.
        auto var = mDistributeVPlsPass.pVars->getRootVar();
        mpSampleGenerator->setShaderData(var);
    };
    FALCOR_ASSERT(mDistributeVPlsPass.pVars);

    auto var = mDistributeVPlsPass.pVars->getRootVar();
    // Set constants (uniforms).
   // 
   //PerFrame Constant Buffer
    std::string nameBuf = "PerFrame";
    var[nameBuf]["gFrameCount"] = mFrameCount;

    //Upload constant buffer only if options changed
    if (mReuploadBuffers) {
        nameBuf = "CB";
        var[nameBuf]["gUseAlphaTest"] = mPhotonUseAlphaTest;
        var[nameBuf]["gAdjustShadingNormals"] = mPhotonAdjustShadingNormal;
        var[nameBuf]["gFrameDim"] = renderData.getDefaultTextureDims();
        var[nameBuf]["gMaxNumberVPL"] = mNumberVPL;
    }

    var["gVplSurface"] = mpVPLSurface;
    var["gVPLs"] = mpVPLBuffer;
    var["gVPLCounter"] = mpVPLBufferCounter;
    var["gVBuffer"] = renderData[kInVBufferDesc.name]->asTexture();
    var[kInViewDesc.texname] = renderData[kInViewDesc.name]->asTexture();
    var["gDebug"] = renderData[kOutDebugDesc.name]->asTexture();

    uint2 targetDim = uint2(div_round_up(uint(mNumberVPL * 1.5f), 1024u), 1024u);
    //uint2 targetDim = renderData.getDefaultTextureDims();
    //Trace the photons
    mpScene->raytrace(pRenderContext, mDistributeVPlsPass.pProgram.get(), mDistributeVPlsPass.pVars, uint3(targetDim, 1));

    pRenderContext->uavBarrier(mpVPLBuffer.get());
}

void PhotonReSTIRVPL::generatePhotonsPass(RenderContext* pRenderContext, const RenderData& renderData)
{
    FALCOR_PROFILE("GeneratePhotons");
    //Clear Counter
    pRenderContext->clearUAV(mpPhotonCounter->getUAV().get(), uint4(0));
    pRenderContext->clearUAV(mpPhotonAABB->getUAV().get(), uint4(0));

    //Defines
    mPhotonGeneratePass.pProgram->addDefine("PHOTON_BUFFER_SIZE", std::to_string(mNumMaxPhotons));
    mPhotonGeneratePass.pProgram->addDefine("USE_PDF_SAMPLING", mUsePdfSampling ? "1": "0");

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

    //Upload constant buffer only if options changed
    if (mReuploadBuffers) {
        nameBuf = "CB";
        var[nameBuf]["gMaxRecursion"] = mPhotonMaxBounces;
        var[nameBuf]["gRejection"] = mPhotonRejection;
        var[nameBuf]["gUseAlphaTest"] = mPhotonUseAlphaTest; 
        var[nameBuf]["gAdjustShadingNormals"] = mPhotonAdjustShadingNormal;
        var[nameBuf]["gPhotonRadius"] = mVPLCollectionRadius;
    }

    mpEmissiveLightSampler->setShaderData(var["Light"]["gEmissiveSampler"]);

    var["gPhotonAABB"] = mpPhotonAABB;
    var["gPackedPhotonData"] = mpPhotonData;
    var["gPhotonCounter"] = mpPhotonCounter;

    // Get dimensions of ray dispatch.
    const uint2 targetDim = uint2(mNumDispatchedPhotons/mPhotonYExtent, mPhotonYExtent);
    FALCOR_ASSERT(targetDim.x > 0 && targetDim.y > 0);

    //Trace the photons
    mpScene->raytrace(pRenderContext, mPhotonGeneratePass.pProgram.get(), mPhotonGeneratePass.pVars, uint3(targetDim, 1));

    pRenderContext->uavBarrier(mpPhotonCounter.get());
    pRenderContext->uavBarrier(mpPhotonAABB.get());
    pRenderContext->uavBarrier(mpPhotonData.get());

    //Build Acceleration Structure
    //Create as if not valid
    if (!mPhotonAS.tlas.pTlas) {
        mPhotonAS.update = false;
        createAccelerationStructure(pRenderContext, mPhotonAS, 1, { mNumMaxPhotons }, { mpPhotonAABB->getGpuAddress() });
    }

    buildAccelerationStructure(pRenderContext, mPhotonAS, { mNumMaxPhotons });
}

void PhotonReSTIRVPL::collectPhotonsPass(RenderContext* pRenderContext, const RenderData& renderData)
{
    FALCOR_PROFILE("CollectPhotons");

    //Defines
    mCollectPhotonsPass.pProgram->addDefine("PHOTON_BUFFER_SIZE", std::to_string(mNumMaxPhotons));
    mCollectPhotonsPass.pProgram->addDefine("USE_PDF_SAMPLING", mUsePdfSampling ? "1" : "0");

    if (!mCollectPhotonsPass.pVars) {
        FALCOR_ASSERT(mCollectPhotonsPass.pProgram);

        // Configure program.
        mCollectPhotonsPass.pProgram->addDefines(mpSampleGenerator->getDefines());
        mCollectPhotonsPass.pProgram->setTypeConformances(mpScene->getTypeConformances());
        // Create program variables for the current program.
        // This may trigger shader compilation. If it fails, throw an exception to abort rendering.
        mCollectPhotonsPass.pVars = RtProgramVars::create(mCollectPhotonsPass.pProgram, mCollectPhotonsPass.pBindingTable);

        // Bind utility classes into shared data.
        auto var = mCollectPhotonsPass.pVars->getRootVar();
        mpSampleGenerator->setShaderData(var);
    };
    FALCOR_ASSERT(mCollectPhotonsPass.pVars);

    auto var = mCollectPhotonsPass.pVars->getRootVar();

    // Set constants (uniforms).
    // 
    //PerFrame Constant Buffer
    
    std::string nameBuf = "PerFrame";
    var[nameBuf]["gFrameCount"] = mFrameCount;

    //Upload constant buffer only if options changed
    if (mReuploadBuffers) {
        nameBuf = "CB";
        var[nameBuf]["gPhotonRadius"] = mVPLCollectionRadius;
        var[nameBuf]["gMaxVPLs"] = mNumberVPL;
    }

    var["gVplSurface"] = mpVPLSurface;
    var["gPhotonAABB"] = mpPhotonAABB;
    var["gPackedPhotonData"] = mpPhotonData;
    var["gPhotonCounter"] = mpPhotonCounter;
    var["gVPLs"] = mpVPLBuffer;
    var["gVPLCounter"] = mpVPLBufferCounter;
    if (mUsePdfSampling) var["gLightPdf"] = mpLightPdfTex;
    
    /*
    //TODO Debug stuff remove if done
    std::string nameBuf = "PerFrame";
    var[nameBuf]["gFrameCount"] = mFrameCount;

    if (mReuploadBuffers) {
        nameBuf = "CB";
        var[nameBuf]["gPhotonRadius"] = mVPLCollectionRadius;
        var[nameBuf]["gMaxVPLs"] = mNumberVPL;
    }
    var["gVBuffer"] = renderData[kInVBufferDesc.name]->asTexture();
    var["gView"] = renderData[kInViewDesc.name]->asTexture();
    var["gPhotonAABB"] = mpPhotonAABB;
    var["gPackedPhotonData"] = mpPhotonData;
    var["gPhotonCounter"] = mpPhotonCounter;
    var["gColorOut"] = renderData[kOutColorDesc.name]->asTexture();
    */

    bool tlasValid = var["gPhotonAS"].setSrv(mPhotonAS.tlas.pSrv);
    FALCOR_ASSERT(tlasValid);

    //Create dimensions based on the number of VPLs
    uint2 targetDim = uint2(div_round_up(uint(mNumberVPL), 1024u), 1024u);
    //targetDim = renderData.getDefaultTextureDims();
    FALCOR_ASSERT(targetDim.x > 0 && targetDim.y > 0);

    //Trace the photons
    mpScene->raytrace(pRenderContext, mCollectPhotonsPass.pProgram.get(), mCollectPhotonsPass.pVars, uint3(targetDim, 1));

    //Generate mip chain
    if (mUsePdfSampling) mpLightPdfTex->generateMips(pRenderContext);
}

void PhotonReSTIRVPL::presamplePhotonLightsPass(RenderContext* pRenderContext, const RenderData& renderData)
{
    //Check if it is enabled
    if (!mUsePdfSampling) {
        //Reset buffer and passes if not used
        if (mpPresamplePhotonLightsPass) mpPresamplePhotonLightsPass.reset();
        return;
    }

    FALCOR_PROFILE("PresamplePhotonLight");
    if (!mpPresamplePhotonLightsPass) {
        Program::Desc desc;
        desc.addShaderLibrary(kShaderPresampleLights).csEntry("main").setShaderModel("6_5");
        desc.addTypeConformances(mpScene->getTypeConformances());

        Program::DefineList defines;
        defines.add(mpScene->getSceneDefines());
        defines.add(mpSampleGenerator->getDefines());
        mpPresamplePhotonLightsPass = ComputePass::create(desc, defines, true);
    }
    FALCOR_ASSERT(mpPresamplePhotonLightsPass);

    //Set variables
    auto var = mpPresamplePhotonLightsPass->getRootVar();

    var["PerFrame"]["gFrameCount"] = mFrameCount;

    if (mReset || mReuploadBuffers) {
        var["Constant"]["gPdfTexSize"] = uint2(mpLightPdfTex->getWidth(), mpLightPdfTex->getHeight());
        var["Constant"]["gTileSizes"] = mPresampledTitleSize;
    }

    var["gLightPdf"] = mpLightPdfTex;
    var["gPresampledLights"] = mpPresampledLights;

    uint2 targetDim = mPresampledTitleSize;
    mpPresamplePhotonLightsPass->execute(pRenderContext, uint3(targetDim, 1));

    pRenderContext->uavBarrier(mpPresampledLights.get());
}

void PhotonReSTIRVPL::generateCandidatesPass(RenderContext* pRenderContext, const RenderData& renderData)
{
    FALCOR_PROFILE("GenerateCandidates");

    //Clear current reservoir
    pRenderContext->clearUAV(mpReservoirBuffer[mFrameCount % 2]->getUAV().get(), uint4(0));

    //Create pass
    if (!mpGenerateCandidates) {
        Program::Desc desc;
        desc.addShaderLibrary(kShaderGenerateCandidates).csEntry("main").setShaderModel("6_5");
        desc.addTypeConformances(mpScene->getTypeConformances());

        Program::DefineList defines;
        defines.add(mpScene->getSceneDefines());
        defines.add(mpSampleGenerator->getDefines());
        defines.add("VIS_RAY_OFFSET", std::to_string(mVisibilityRayOffset));
        defines.add("USE_PRESAMPLING", mUsePdfSampling ? "1" : "0");
        defines.add("USE_VISIBILITY_CHECK_INLINE", mUseVisibiltyRayInline ? "1" : "0");
        defines.add(getValidResourceDefines(kInputChannels, renderData));

        mpGenerateCandidates = ComputePass::create(desc, defines, true);
    }
    FALCOR_ASSERT(mpGenerateCandidates);

    //Set variables
    auto var = mpGenerateCandidates->getRootVar();

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
    bindReservoirs(var, mFrameCount, false);
    var["gSurface"] = mpSurfaceBuffer[mFrameCount % 2];
    var[kInViewDesc.texname] = renderData[kInViewDesc.name]->asTexture();
    var["gVPLCounter"] = mpVPLBufferCounter;
    var["gVPLs"] = mpVPLBuffer;
    if(mUsePdfSampling) var["gPresampledLights"] = mpPresampledLights;

    //Uniform
    std::string uniformName = "PerFrame";

    var[uniformName]["gFrameCount"] = mFrameCount;
    if (mReset || mReuploadBuffers) {
        uniformName = "Constant";
        var[uniformName]["gNumEmissiveSamples"] = mNumEmissiveCandidates;
        var[uniformName]["gFrameDim"] = renderData.getDefaultTextureDims();
        var[uniformName]["gTestVisibility"] = (mResamplingMode > 0) | !mUseFinalVisibilityRay; 
        var[uniformName]["gGeometryTermBand"] = mGeometryTermBand;
        var[uniformName]["gNumLights"] = mUsePdfSampling ? mPresampledTitleSize : uint2(mNumberVPL,0);
        var[uniformName]["gRadius"] = mVPLCollectionRadius;
    }

    //Execute
    const uint2 targetDim = renderData.getDefaultTextureDims();
    FALCOR_ASSERT(targetDim.x > 0 && targetDim.y > 0);
    mpGenerateCandidates->execute(pRenderContext, uint3(targetDim, 1));

    //Barrier for written buffer
    pRenderContext->uavBarrier(mpReservoirBuffer[mFrameCount % 2].get());
}

void PhotonReSTIRVPL::candidatesVisibilityCheckPass(RenderContext* pRenderContext, const RenderData& renderData)
{
    if (mUseVisibiltyRayInline) {
        //Reset everything if it was set
        if (mVisibilityCheckPass.pProgram) {
            mVisibilityCheckPass = RayTraceProgramHelper::create();
        }
        return;
    }

    //Create the program
    if (!mVisibilityCheckPass.pProgram) {
        RtProgram::Desc desc;
        desc.addShaderLibrary(kShaderCandidatesVisCheck);
        desc.setMaxPayloadSize(8u);
        desc.setMaxAttributeSize(kMaxAttributeSizeBytes);
        desc.setMaxTraceRecursionDepth(kMaxRecursionDepth);

        mVisibilityCheckPass.pBindingTable = RtBindingTable::create(1, 1, mpScene->getGeometryCount());
        auto& sbt = mVisibilityCheckPass.pBindingTable;
        sbt->setRayGen(desc.addRayGen("rayGen"));
        sbt->setMiss(0, desc.addMiss("miss"));
        sbt->setHitGroup(0, 0, desc.addHitGroup("closestHit"));

        mVisibilityCheckPass.pProgram = RtProgram::create(desc, mpScene->getSceneDefines());
    }

    if (!mVisibilityCheckPass.pVars) {
        FALCOR_ASSERT(mVisibilityCheckPass.pProgram);

        // Configure program.
        mVisibilityCheckPass.pProgram->setTypeConformances(mpScene->getTypeConformances());
        mVisibilityCheckPass.pProgram->addDefines(getValidResourceDefines(kInputChannels, renderData));
        // Create program variables for the current program.
        // This may trigger shader compilation. If it fails, throw an exception to abort rendering.
        mVisibilityCheckPass.pVars = RtProgramVars::create(mVisibilityCheckPass.pProgram, mVisibilityCheckPass.pBindingTable);
    };
    FALCOR_ASSERT(mVisibilityCheckPass.pVars);
    auto var = mVisibilityCheckPass.pVars->getRootVar();

    // Set constants (uniforms).
    // 
    //PerFrame Constant Buffer
    std::string nameBuf = "CB";
    var[nameBuf]["gVisRayOffset"] = mVisibilityRayOffset;

    var["gVPLs"] = mpVPLBuffer;
    bindReservoirs(var, mFrameCount, false);
    var["gSurface"] = mpSurfaceBuffer[mFrameCount % 2];
    var[kInViewDesc.texname] = renderData[kInViewDesc.name]->asTexture();

    uint2 targetDim = renderData.getDefaultTextureDims();
    //Trace the photons
    mpScene->raytrace(pRenderContext, mVisibilityCheckPass.pProgram.get(), mVisibilityCheckPass.pVars, uint3(targetDim, 1));
}

void PhotonReSTIRVPL::temporalResampling(RenderContext* pRenderContext, const RenderData& renderData)
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
        defines.add("VIS_RAY_OFFSET", std::to_string(mVisibilityRayOffset));
        defines.add(getValidResourceDefines(kInputChannels, renderData));

        mpTemporalResampling = ComputePass::create(desc, defines, true);
    }
    FALCOR_ASSERT(mpTemporalResampling);

    if (mReset) return; //Scip the rest on the first frame as the temporal buffer is invalid anyway

    //Set variables
    auto var = mpTemporalResampling->getRootVar();

    mpScene->setRaytracingShaderData(pRenderContext, var, 1);   //Set scene data
    mpSampleGenerator->setShaderData(var);          //Sample generator

    bindReservoirs(var, mFrameCount);
    var["gSurface"] = mpSurfaceBuffer[mFrameCount % 2];
    var["gSurfacePrev"] = mpSurfaceBuffer[(mFrameCount + 1) % 2];
    var[kInViewDesc.texname] = renderData[kInViewDesc.name]->asTexture();
    var["gPrevView"] = mpPrevViewTex;

    var["gVPLs"] = mpVPLBuffer;
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
        var[uniformName]["gGeometryTermBand"] = mGeometryTermBand;
    }

    //Execute
    const uint2 targetDim = renderData.getDefaultTextureDims();
    FALCOR_ASSERT(targetDim.x > 0 && targetDim.y > 0);
    mpTemporalResampling->execute(pRenderContext, uint3(targetDim, 1));

    //Barrier for written buffer
    pRenderContext->uavBarrier(mpReservoirBuffer[mFrameCount % 2].get());
}

void PhotonReSTIRVPL::spartialResampling(RenderContext* pRenderContext, const RenderData& renderData)
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
        defines.add("VIS_RAY_OFFSET", std::to_string(mVisibilityRayOffset));
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
    var["gNeighOffsetBuffer"] = mpNeighborOffsetBuffer;
    var["gSurface"] = mpSurfaceBuffer[mFrameCount % 2];
    var[kInViewDesc.texname] = renderData[kInViewDesc.name]->asTexture();
    var["gVPLs"] = mpVPLBuffer;

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
    }

    //Execute
    const uint2 targetDim = renderData.getDefaultTextureDims();
    FALCOR_ASSERT(targetDim.x > 0 && targetDim.y > 0);
    mpSpartialResampling->execute(pRenderContext, uint3(targetDim, 1));

    //Barrier for written buffer
    pRenderContext->uavBarrier(mpReservoirBuffer[(mFrameCount + 1) % 2].get());
}

void PhotonReSTIRVPL::spartioTemporalResampling(RenderContext* pRenderContext, const RenderData& renderData)
{
    FALCOR_PROFILE("SpartioTemporalResampling");

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
        defines.add("VIS_RAY_OFFSET", std::to_string(mVisibilityRayOffset));
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
    var["gSurfacePrev"] = mpSurfaceBuffer[(mFrameCount + 1) % 2];
    var["gSurface"] = mpSurfaceBuffer[mFrameCount % 2];
    var[kInViewDesc.texname] = renderData[kInViewDesc.name]->asTexture();
    var["gPrevView"] = mpPrevViewTex;
    var["gNeighOffsetBuffer"] = mpNeighborOffsetBuffer;

    var["gVPLs"] = mpVPLBuffer;
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
    }

    //Execute
    const uint2 targetDim = renderData.getDefaultTextureDims();
    FALCOR_ASSERT(targetDim.x > 0 && targetDim.y > 0);
    mpSpartioTemporalResampling->execute(pRenderContext, uint3(targetDim, 1));

    //Barrier for written buffer
    pRenderContext->uavBarrier(mpReservoirBuffer[mFrameCount % 2].get());
}

void PhotonReSTIRVPL::finalShadingPass(RenderContext* pRenderContext, const RenderData& renderData)
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

    var["gVPLs"] = mpVPLBuffer;
    var[kInViewDesc.texname] = renderData[kInViewDesc.name]->asTexture();
    //for (auto& inp : kInputChannels) bindAsTex(inp);
    bindAsTex(kInVBufferDesc);
    bindAsTex(kInMVecDesc);
    //var["gPhotonCounter"] = mpPhotonCounter;
    //var["gPhotonLights"] = mpPhotonLights;
    for (auto& out : kOutputChannels) bindAsTex(out);

    //Uniform
    std::string uniformName = "PerFrame";
    var[uniformName]["gFrameCount"] = mFrameCount;
    if (mReset || mReuploadBuffers) {
        uniformName = "Constant";
        var[uniformName]["gFrameDim"] = renderData.getDefaultTextureDims();
        var[uniformName]["gUseEmissiveTexture"] = mUseEmissiveTexture;
        var[uniformName]["gEnableVisRay"] = mUseFinalVisibilityRay;
        var[uniformName]["gRadius"] = mVPLCollectionRadius;
    }

    //Execute
    const uint2 targetDim = renderData.getDefaultTextureDims();
    FALCOR_ASSERT(targetDim.x > 0 && targetDim.y > 0);
    mpFinalShading->execute(pRenderContext, uint3(targetDim, 1));
}

void PhotonReSTIRVPL::showVPLDebugPass(RenderContext* pRenderContext, const RenderData& renderData)
{
    //TODO delete needed data here if pass becomes invalid
    if (!mShowVPLs) {
        //Reset all data if the buffer is active
        if (mpShowVPLsAABBsBuffer) {
            mpShowVPLsAABBsBuffer.reset();
            mpShowVPLsCalcAABBsPass.reset();
            //Clear all acceleration structure data
            for (uint i = 0; i < mVPLDebugAS.blas.size(); i++)
                mVPLDebugAS.blas[i].reset();
            mVPLDebugAS.blas.clear();
            mVPLDebugAS.blasData.clear();
            mVPLDebugAS.instanceDesc.clear();
            mVPLDebugAS.tlasScratch.reset();
            mVPLDebugAS.tlas.pInstanceDescs.reset();  mVPLDebugAS.tlas.pSrv = nullptr;  mVPLDebugAS.tlas.pTlas.reset();
            mVPLDebugPass = RayTraceProgramHelper::create();
        }

        return;
    }
        

    FALCOR_PROFILE("ShowVPL");

    //Convert Buffer pos to vpls

    //Put a write barrier for the output here to be sure that the final shading shader finished writing
    //auto outTexture = renderData[kOutColorDesc.name]->asTexture();
    //pRenderContext->uavBarrier(outTexture.get());

    //AABB create pass
    {
        //Create AABB buffer
        if (!mpShowVPLsAABBsBuffer) {
            mpShowVPLsAABBsBuffer = Buffer::createStructured(sizeof(D3D12_RAYTRACING_AABB), mNumberVPL);
            mpShowVPLsAABBsBuffer->setName("PhotonReStir::VPLaabbBuffer");
        }
        FALCOR_ASSERT(mpShowVPLsAABBsBuffer);
        //Create pass
        if (!mpShowVPLsCalcAABBsPass) {
            Program::Desc desc;
            desc.addShaderLibrary(kShaderShowAABBVPLs).csEntry("main").setShaderModel("6_5");

            Program::DefineList defines;

            mpShowVPLsCalcAABBsPass = ComputePass::create(desc, defines, true);
        }
        FALCOR_ASSERT(mpShowVPLsCalcAABBsPass);

        auto var = mpShowVPLsCalcAABBsPass->getRootVar();

        var["gVPLs"] = mpVPLBuffer;
        var["gVPLCounter"] = mpVPLBufferCounter;
        var["gAABBs"] = mpShowVPLsAABBsBuffer;

        uint2 targetDim = uint2(1024u, div_round_up(uint(mNumberVPL), 1024u));

        var["Uniform"]["gRadius"] = mVPLCollectionRadius;
        var["Uniform"]["gNumVPLs"] = mNumberVPL;
        var["Uniform"]["gDimY"] = targetDim.y;

        mpShowVPLsCalcAABBsPass->execute(pRenderContext, uint3(targetDim, 1));

        pRenderContext->uavBarrier(mpShowVPLsAABBsBuffer.get());
    }
    //Create the AS
    if (!mVPLDebugAS.tlas.pTlas) {
        mVPLDebugAS.update = true;
        createAccelerationStructure(pRenderContext, mVPLDebugAS, 1, { mNumberVPL }, { mpShowVPLsAABBsBuffer->getGpuAddress() });
    }

    buildAccelerationStructure(pRenderContext, mVPLDebugAS, { mNumberVPL });

    // Sphere Ray Trace pass
    {
        //Create the pass if there is none
        if (!mVPLDebugPass.pProgram) {
            RtProgram::Desc desc;
            desc.addShaderLibrary(kShaderShowVPLs);
            desc.setMaxPayloadSize(16u);
            desc.setMaxAttributeSize(kMaxAttributeSizeBytes);
            desc.setMaxTraceRecursionDepth(kMaxRecursionDepth);

            mVPLDebugPass.pBindingTable = RtBindingTable::create(1, 1, mpScene->getGeometryCount());
            auto& sbt = mVPLDebugPass.pBindingTable;
            sbt->setRayGen(desc.addRayGen("rayGen"));
            sbt->setMiss(0, desc.addMiss("miss"));
            sbt->setHitGroup(0, 0, desc.addHitGroup("closestHit", "", "intersection"));

            mVPLDebugPass.pProgram = RtProgram::create(desc, mpScene->getSceneDefines());
        }

        if (!mVPLDebugPass.pVars) {
            FALCOR_ASSERT(mVPLDebugPass.pProgram);

            // Configure program.
            mVPLDebugPass.pProgram->setTypeConformances(mpScene->getTypeConformances());
            // Create program variables for the current program.
            // This may trigger shader compilation. If it fails, throw an exception to abort rendering.
            mVPLDebugPass.pVars = RtProgramVars::create(mVPLDebugPass.pProgram, mVPLDebugPass.pBindingTable);
        };
        FALCOR_ASSERT(mVPLDebugPass.pVars);

        auto var = mVPLDebugPass.pVars->getRootVar();

        // Set constants (uniforms).
        // 
        //PerFrame Constant Buffer
        std::string nameBuf = "CB";
        var[nameBuf]["gVplRadius"] = mVPLCollectionRadius;
        var[nameBuf]["gFrameDim"] = renderData.getDefaultTextureDims();
        var[nameBuf]["gScalar"] = mShowVPLsScalar;
        
        var["gVPLs"] = mpVPLBuffer;
        var["gAABBs"] = mpShowVPLsAABBsBuffer;
        var["gVBuffer"] = renderData[kInVBufferDesc.name]->asTexture();
        var["gColor"] = renderData[kOutColorDesc.name]->asTexture();
        bool tlasValid = var["gVplAS"].setSrv(mVPLDebugAS.tlas.pSrv);

        FALCOR_ASSERT(tlasValid);

        uint2 targetDim = renderData.getDefaultTextureDims();
        //Trace the photons
        mpScene->raytrace(pRenderContext, mVPLDebugPass.pProgram.get(), mVPLDebugPass.pVars, uint3(targetDim, 1));
    }
}

void PhotonReSTIRVPL::fillNeighborOffsetBuffer(std::vector<int8_t>& buffer)
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

void PhotonReSTIRVPL::copyPhotonCounter(RenderContext* pRenderContext)
{
    //Copy the photonConter to a CPU Buffer
    pRenderContext->copyBufferRegion(mpPhotonCounterCPU.get(), 0, mpPhotonCounter.get(), 0, sizeof(uint32_t));

    void* data = mpPhotonCounterCPU->map(Buffer::MapType::Read);
    std::memcpy(&mCurrentPhotonLightsCount, data, sizeof(uint));
    mpPhotonCounterCPU->unmap();
}

void PhotonReSTIRVPL::bindReservoirs(ShaderVar& var, uint index , bool bindPrev)
{
    var["gReservoir"] = mpReservoirBuffer[index % 2];
    if (bindPrev) {
        var["gReservoirPrev"] = mpReservoirBuffer[(index +1) % 2];
    }
}

void PhotonReSTIRVPL::computePdfTextureSize(uint32_t maxItems, uint32_t& outWidth, uint32_t& outHeight, uint32_t& outMipLevels)
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

void PhotonReSTIRVPL::createAccelerationStructure(RenderContext* pRenderContext, SphereAccelerationStructure& accel,const uint numberBlas,const std::vector<uint>& aabbCount,const std::vector<uint64_t>& aabbGpuAddress)
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

void PhotonReSTIRVPL::createTopLevelAS(RenderContext* pContext, SphereAccelerationStructure& accel)
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

void PhotonReSTIRVPL::createBottomLevelAS(RenderContext* pContext, SphereAccelerationStructure& accel, const std::vector<uint> aabbCount, const std::vector<uint64_t> aabbGpuAddress)
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
        accel.blas[0] = Buffer::create(accel.blasData[i].blasByteSize, Buffer::BindFlags::AccelerationStructure);
        accel.blas[0]->setName("PhotonReStir::BlasBuffer" + std::to_string(i));
    }
}

void PhotonReSTIRVPL::buildAccelerationStructure(RenderContext* pRenderContext, SphereAccelerationStructure& accel, const std::vector<uint>& aabbCount)
{
    //TODO check per assert if buffers are set
    buildBottomLevelAS(pRenderContext, accel, aabbCount);
    buildTopLevelAS(pRenderContext, accel);
}

void PhotonReSTIRVPL::buildTopLevelAS(RenderContext* pContext, SphereAccelerationStructure& accel)
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

void PhotonReSTIRVPL::buildBottomLevelAS(RenderContext* pContext, SphereAccelerationStructure& accel, const std::vector<uint>& aabbCount)
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
