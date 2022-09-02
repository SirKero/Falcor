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
#include "PhotonReSTIR.h"
#include <RenderGraph/RenderPassHelpers.h>

const RenderPass::Info PhotonReSTIR::kInfo { "PhotonReSTIR", "Photon based indirect lighting pass using ReSTIR" };

// Don't remove this. it's required for hot-reload to function properly
extern "C" FALCOR_API_EXPORT const char* getProjDir()
{
    return PROJECT_DIR;
}

extern "C" FALCOR_API_EXPORT void getPasses(Falcor::RenderPassLibrary& lib)
{
    lib.registerPass(PhotonReSTIR::kInfo, PhotonReSTIR::create);
}

namespace {
    //Shaders
    const char kShaderGeneratePhoton[] = "RenderPasses/PhotonReSTIR/generatePhotons.rt.slang";
    const char kShaderFillSurfaceInformation[] = "RenderPasses/PhotonReSTIR/fillSurfaceInfo.cs.slang";
    const char kShaderGenerateCandidates[] = "RenderPasses/PhotonReSTIR/generateCandidates.cs.slang";
    const char kShaderTemporalPass[] = "RenderPasses/PhotonReSTIR/temporalResampling.cs.slang";
    const char kShaderSpartialPass[] = "RenderPasses/PhotonReSTIR/spartialResampling.cs.slang";
    const char kShaderSpartioTemporalPass[] = "RenderPasses/PhotonReSTIR/spartioTemporalResampling.cs.slang";
    const char kShaderFinalShading[] = "RenderPasses/PhotonReSTIR/finalShading.cs.slang";

    // Ray tracing settings that affect the traversal stack size.
    const uint32_t kMaxPayloadSizeBytes = 96u;
    const uint32_t kMaxAttributeSizeBytes = 8u;
    const uint32_t kMaxRecursionDepth = 2u;

    //Inputs
    const ChannelDesc kInVBufferDesc = {"VBuffer" , "gVBuffer", "VBuffer hit information", false};
    const ChannelDesc kInMVecDesc = {"MVec" , "gMVec" , "Motion Vector", false};
    const ChannelDesc kInViewDesc = {"View" ,"gView", "View Vector", true};

    const ChannelList kInputChannels = { kInVBufferDesc, kInMVecDesc, kInViewDesc };

    //Outputs
    const ChannelList kOutputChannels =
    {
        {"color" ,                  "gColor" ,               "Indirect illumination of the scene" ,      false,  ResourceFormat::RGBA16Float},
        {"diffuseIllumination",     "gDiffuseIllumination",     "Diffuse Illumination and hit distance",    true,   ResourceFormat::RGBA16Float},
        {"diffuseReflectance",      "gDiffuseReflectance",      "Diffuse Reflectance",                      true,   ResourceFormat::RGBA16Float},
        {"specularIllumination",    "gSpecularIllumination",    "Specular illumination and hit distance",   true,   ResourceFormat::RGBA16Float},
        {"specularReflectance",     "gSpecularReflectance",     "Specular reflectance",                     true,   ResourceFormat::RGBA16Float},
    };

    const Gui::DropdownList kResamplingModeList{
        {PhotonReSTIR::ResamplingMode::NoResampling , "No Resampling"},
        {PhotonReSTIR::ResamplingMode::Temporal , "Temporal only"},
        {PhotonReSTIR::ResamplingMode::Spartial , "Spartial only"},
        {PhotonReSTIR::ResamplingMode::SpartioTemporal , "SpartioTemporal"},
    };

    const Gui::DropdownList kBiasCorrectionModeList{
        {PhotonReSTIR::BiasCorrectionMode::Off , "Off"},
        {PhotonReSTIR::BiasCorrectionMode::Basic , "Basic"},
        {PhotonReSTIR::BiasCorrectionMode::RayTraced , "RayTraced"},
    };
}

PhotonReSTIR::SharedPtr PhotonReSTIR::create(RenderContext* pRenderContext, const Dictionary& dict)
{
    SharedPtr pPass = SharedPtr(new PhotonReSTIR());
    return pPass;
}

Dictionary PhotonReSTIR::getScriptingDictionary()
{
    return Dictionary();
}

RenderPassReflection PhotonReSTIR::reflect(const CompileData& compileData)
{
    // Define the required resources here
    RenderPassReflection reflector;
    addRenderPassInputs(reflector, kInputChannels);
    addRenderPassOutputs(reflector, kOutputChannels);
    return reflector;
}

void PhotonReSTIR::execute(RenderContext* pRenderContext, const RenderData& renderData)
{
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

    //Generate Photons
    generatePhotonsPass(pRenderContext, renderData);

    //Copy the counter for UI
    copyPhotonCounter(pRenderContext);

    //Prepare the surface buffer
    prepareSurfaceBufferPass(pRenderContext, renderData);

    //Generate Canditdates
    generateCandidatesPass(pRenderContext, renderData);

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

    //Reset the reset vars
    mReuploadBuffers = mReset ? true : false;
    mBiasCorrectionChanged = false;
    mReset = false;
    mFrameCount++;
}

void PhotonReSTIR::renderUI(Gui::Widgets& widget)
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

        changed |= widget.checkbox("Use Alpha Test", mPhotonUseAlphaTest);
        changed |= widget.checkbox("Adjust Shading Normal", mPhotonAdjustShadingNormal);
    }

    if (auto group = widget.group("ReSTIR")) {
        changed |= widget.dropdown("ResamplingMode", kResamplingModeList, mResamplingMode);
        //UI here
        changed |= widget.var("Initial Emissive Candidates", mNumEmissiveCandidates, 0u, 4096u);
        widget.tooltip("Number of emissive candidates generated per iteration");

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
            changed |= widget.checkbox("Use Emissive Texture", mUseEmissiveTexture);
            widget.tooltip("Activate to use the Emissive texture in the final shading step. More correct but noisier");
            changed |= widget.checkbox("Use Final Shading Visibility Ray", mUseFinalVisibilityRay);
            widget.tooltip("Enables a Visibility ray in final shading. Can reduce bias as Reservoir Visibility rays ignore opaque geometry");
            mReset |= widget.var("Visibility Ray TMin Offset", mVisibilityRayOffset, 0.00001f, 10.f, 0.00001f);
            widget.tooltip("Changes offset for visibility ray. Triggers recompilation so typing in the value is advised");
        }
    }
   

    mReset |= widget.button("Recompile");
    mReuploadBuffers |= changed;
}

void PhotonReSTIR::setScene(RenderContext* pRenderContext, const Scene::SharedPtr& pScene)
{
    resetPass(true);

    //Recreate RayTracing Program on Scene reset
    mPhotonGeneratePass.create();

    mpScene = pScene;

    if (mpScene) {
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

            mPhotonGeneratePass.pBindingTable = RtBindingTable::create(1, 1, mpScene->getGeometryCount());
            auto& sbt = mPhotonGeneratePass.pBindingTable;
            sbt->setRayGen(desc.addRayGen("rayGen"));
            sbt->setMiss(0, desc.addMiss("miss"));
            if (mpScene->hasGeometryType(Scene::GeometryType::TriangleMesh)) {
                sbt->setHitGroup(0, mpScene->getGeometryIDs(Scene::GeometryType::TriangleMesh), desc.addHitGroup("closestHit", "anyHit"));
            }

            mPhotonGeneratePass.pProgram = RtProgram::create(desc, mpScene->getSceneDefines());
        }
    }

}

void PhotonReSTIR::resetPass(bool resetScene)
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

bool PhotonReSTIR::prepareLighting(RenderContext* pRenderContext)
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

void PhotonReSTIR::preparePhotonBuffers(RenderContext* pRenderContext,const RenderData& renderData)
{
    //Has resolution changed ?. New Value for mScreenRes is set in the prepareBuffer() function
    if ((mScreenRes.x != renderData.getDefaultTextureDims().x) || (mScreenRes.y != renderData.getDefaultTextureDims().y) || mReset)
    {
        for (size_t i = 0; i <= 1; i++) {
            mpPhotonReservoirPos[i].reset();
            mpPhotonReservoirFlux[i].reset();
        }
    }

    if (mChangePhotonLightBufferSize) {
        mpPhotonLights.reset();
        mChangePhotonLightBufferSize = false;
    }


    if (!mpPhotonLightCounter) {
        mpPhotonLightCounter = Buffer::create(sizeof(uint));
        mpPhotonLightCounter->setName("PhotonReSTIR::PhotonCounterGPU");
    }
    if (!mpPhotonLightCounterCPU) {
        mpPhotonLightCounterCPU = Buffer::create(sizeof(uint),ResourceBindFlags::None, Buffer::CpuAccess::Read);
        mpPhotonLightCounterCPU->setName("PhotonReSTIR::PhotonCounterCPU");
    }
    if (!mpPhotonLights) {
        //Calculate real photon max size
        mpPhotonLights = Buffer::createStructured(sizeof(float) * 8, mNumMaxPhotons);
        mpPhotonLights->setName("PhotonReSTIR::PhotonLights");
    }
    //Photon reservoir textures
    if (!mpPhotonReservoirPos[0] || !mpPhotonReservoirPos[1] || !mpPhotonReservoirFlux[0] || !mpPhotonReservoirFlux[1]) {
        uint2 texDim = renderData.getDefaultTextureDims();
        for (uint i = 0; i < 2; i++) {
            mpPhotonReservoirPos[i] = Texture::create2D(texDim.x, texDim.y, ResourceFormat::RGBA32Float, 1, 1, nullptr, ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess);
            mpPhotonReservoirPos[i]->setName("PhotonReSTIR::PhotonReservoirPos" + std::to_string(i));
            mpPhotonReservoirFlux[i] = Texture::create2D(texDim.x, texDim.y, ResourceFormat::RGBA16Float, 1, 1, nullptr, ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess);
            mpPhotonReservoirFlux[i]->setName("PhotonReSTIR::PhotonReservoirFlux" + std::to_string(i));
        }
    }
}

void PhotonReSTIR::prepareBuffers(RenderContext* pRenderContext, const RenderData& renderData)
{
    //Has resolution changed ?
    if ((mScreenRes.x != renderData.getDefaultTextureDims().x) || (mScreenRes.y != renderData.getDefaultTextureDims().y) || mReset)
    {
        mScreenRes = renderData.getDefaultTextureDims();
        for (size_t i = 0; i <= 1; i++) {
            mpReservoirBuffer[i].reset();
            mpSurfaceBuffer[i].reset();
        }
        mReuploadBuffers = true; 
    }

    if (!mpReservoirBuffer[0] || !mpReservoirBuffer[1]) {
        mpReservoirBuffer[0] = Texture::create2D(renderData.getDefaultTextureDims().x, renderData.getDefaultTextureDims().y, ResourceFormat::RGBA32Uint,
                                                 1, 1, nullptr, ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess);
        mpReservoirBuffer[0]->setName("ReStirExp::ReservoirBuf1");
        mpReservoirBuffer[1] = Texture::create2D(renderData.getDefaultTextureDims().x, renderData.getDefaultTextureDims().y, ResourceFormat::RGBA32Uint,
                                                 1, 1, nullptr, ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess);
        mpReservoirBuffer[1]->setName("ReStirExp::ReservoirBuf2");
    }
    
    //Create a buffer filled with surface info for current and last frame
    if (!mpSurfaceBuffer[0] || !mpSurfaceBuffer[1]) {
        uint2 texDim = renderData.getDefaultTextureDims();
        uint bufferSize = texDim.x * texDim.y;
        mpSurfaceBuffer[0] = Buffer::createStructured(sizeof(uint) * 8, bufferSize);
        mpSurfaceBuffer[0]->setName("ReStirExp::SurfaceBuffer1");
        mpSurfaceBuffer[1] = Buffer::createStructured(sizeof(uint) * 8, bufferSize);
        mpSurfaceBuffer[1]->setName("ReStirExp::SurfaceBuffer2");
    }

    //Create an fill the neighbor offset buffer
    if (!mpNeighborOffsetBuffer) {
        std::vector<int8_t> offsets(2 * kNumNeighborOffsets);
        fillNeighborOffsetBuffer(offsets);

        mpNeighborOffsetBuffer = Texture::create1D(kNumNeighborOffsets, ResourceFormat::RG8Snorm, 1, 1, offsets.data());


        mpNeighborOffsetBuffer->setName("ReStirExp::NeighborOffsetBuffer");
    }

    if (!mpSampleGenerator) {
        mpSampleGenerator = SampleGenerator::create(SAMPLE_GENERATOR_UNIFORM);
    }
}

void PhotonReSTIR::prepareSurfaceBufferPass(RenderContext* pRenderContext, const RenderData& renderData)
{
    FALCOR_PROFILE("FillSurfaceBuffer");

    //init
    if (!mpFillSurfaceInfoPass) {
        Program::Desc desc;
        desc.addShaderLibrary(kShaderFillSurfaceInformation).csEntry("main").setShaderModel("6_5");
        desc.addTypeConformances(mpScene->getTypeConformances());

        Program::DefineList defines;
        defines.add(mpScene->getSceneDefines());
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

void PhotonReSTIR::generatePhotonsPass(RenderContext* pRenderContext, const RenderData& renderData)
{
    FALCOR_PROFILE("GeneratePhotons");
    //Clear Counter
    pRenderContext->clearUAV(mpPhotonLightCounter.get()->getUAV().get(), uint4(0));

    pRenderContext->clearUAV(mpPhotonLights.get()->getUAV().get(), uint4(0));

    //Defines
    

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
    }

    mpEmissiveLightSampler->setShaderData(var["Light"]["gEmissiveSampler"]);

    var["gPhotonLights"] = mpPhotonLights;
    var["gPhotonCounter"] = mpPhotonLightCounter;

    // Get dimensions of ray dispatch.
    const uint2 targetDim = uint2(mNumDispatchedPhotons/mPhotonYExtent, mPhotonYExtent);
    FALCOR_ASSERT(targetDim.x > 0 && targetDim.y > 0);

    //Trace the photons
    mpScene->raytrace(pRenderContext, mPhotonGeneratePass.pProgram.get(), mPhotonGeneratePass.pVars, uint3(targetDim, 1));

    pRenderContext->uavBarrier(mpPhotonLightCounter.get());
    pRenderContext->uavBarrier(mpPhotonLights.get());
}

void PhotonReSTIR::generateCandidatesPass(RenderContext* pRenderContext, const RenderData& renderData)
{
    FALCOR_PROFILE("GenerateCandidates");

    //Clear current reservoir
    pRenderContext->clearUAV(mpReservoirBuffer[mFrameCount % 2].get()->getUAV().get(), uint4(0));
    pRenderContext->clearTexture(mpPhotonReservoirPos[mFrameCount % 2].get() , float4(0));
    pRenderContext->clearTexture(mpPhotonReservoirFlux[mFrameCount % 2].get(), float4(0));

    //Create pass
    if (!mpGenerateCandidates) {
        Program::Desc desc;
        desc.addShaderLibrary(kShaderGenerateCandidates).csEntry("main").setShaderModel("6_5");
        desc.addTypeConformances(mpScene->getTypeConformances());

        Program::DefineList defines;
        defines.add(mpScene->getSceneDefines());
        defines.add(mpSampleGenerator->getDefines());
        defines.add("VIS_RAY_OFFSET", std::to_string(mVisibilityRayOffset));

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
    var["gPhotonCounter"] = mpPhotonLightCounter;
    var["gPhotonLights"] = mpPhotonLights;

    //Uniform
    std::string uniformName = "PerFrame";

    var[uniformName]["gFrameCount"] = mFrameCount;
    if (mReset || mReuploadBuffers) {
        uniformName = "Constant";
        var[uniformName]["gNumEmissiveSamples"] = mNumEmissiveCandidates;
        var[uniformName]["gFrameDim"] = renderData.getDefaultTextureDims();
        var[uniformName]["gTestVisibility"] = (mResamplingMode > 0) | !mUseFinalVisibilityRay;   //TODO: Also add a variable to manually disable
    }

    //Execute
    const uint2 targetDim = renderData.getDefaultTextureDims();
    FALCOR_ASSERT(targetDim.x > 0 && targetDim.y > 0);
    mpGenerateCandidates->execute(pRenderContext, uint3(targetDim, 1));

    //Barrier for written buffer
    pRenderContext->uavBarrier(mpReservoirBuffer[mFrameCount % 2].get());
    pRenderContext->uavBarrier(mpPhotonReservoirPos[mFrameCount % 2].get());
    pRenderContext->uavBarrier(mpPhotonReservoirFlux[mFrameCount % 2].get());
}

void PhotonReSTIR::temporalResampling(RenderContext* pRenderContext, const RenderData& renderData)
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

    var["gMVec"] = renderData[kInMVecDesc.name]->asTexture();    //BindMvec

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
}

void PhotonReSTIR::spartialResampling(RenderContext* pRenderContext, const RenderData& renderData)
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

    var["gMVec"] = renderData[kInMVecDesc.name]->asTexture();    //BindMvec

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

void PhotonReSTIR::spartioTemporalResampling(RenderContext* pRenderContext, const RenderData& renderData)
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
    var["gNeighOffsetBuffer"] = mpNeighborOffsetBuffer;

    var["gMVec"] = renderData[kInMVecDesc.name]->asTexture();    //BindMvec

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

void PhotonReSTIR::finalShadingPass(RenderContext* pRenderContext, const RenderData& renderData)
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

    //for (auto& inp : kInputChannels) bindAsTex(inp);
    bindAsTex(kInVBufferDesc);
    bindAsTex(kInMVecDesc);
    //var["gPhotonCounter"] = mpPhotonLightCounter;
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
    }

    //Execute
    const uint2 targetDim = renderData.getDefaultTextureDims();
    FALCOR_ASSERT(targetDim.x > 0 && targetDim.y > 0);
    mpFinalShading->execute(pRenderContext, uint3(targetDim, 1));
}

void PhotonReSTIR::fillNeighborOffsetBuffer(std::vector<int8_t>& buffer)
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

void PhotonReSTIR::copyPhotonCounter(RenderContext* pRenderContext)
{
    //Copy the photonConter to a CPU Buffer
    pRenderContext->copyBufferRegion(mpPhotonLightCounterCPU.get(), 0, mpPhotonLightCounter.get(), 0, sizeof(uint32_t));

    void* data = mpPhotonLightCounterCPU->map(Buffer::MapType::Read);
    std::memcpy(&mCurrentPhotonLightsCount, data, sizeof(uint));
    mpPhotonLightCounterCPU->unmap();
}

void PhotonReSTIR::bindReservoirs(ShaderVar& var, uint index , bool bindPrev)
{
    var["gReservoir"] = mpReservoirBuffer[index % 2];
    var["gPhotonReservoirPos"] = mpPhotonReservoirPos[index % 2];
    var["gPhotonReservoirFlux"] = mpPhotonReservoirFlux[index % 2];
    if (bindPrev) {
        var["gReservoirPrev"] = mpReservoirBuffer[(index +1) % 2];
        var["gPhotonReservoirPosPrev"] = mpPhotonReservoirPos[(index +1) % 2];
        var["gPhotonReservoirFluxPrev"] = mpPhotonReservoirFlux[(index +1) % 2];
    }
}
