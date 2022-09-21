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
#include "ReStirExp.h"
#include <RenderGraph/RenderPassHelpers.h>

const RenderPass::Info ReStirExp::kInfo { "ReStirExp", "Simplified ReStir implementation." };

// Don't remove this. it's required for hot-reload to function properly
extern "C" FALCOR_API_EXPORT const char* getProjDir()
{
    return PROJECT_DIR;
}

extern "C" FALCOR_API_EXPORT void getPasses(Falcor::RenderPassLibrary& lib)
{
    lib.registerPass(ReStirExp::kInfo, ReStirExp::create);
}

namespace {
    //Shaders
    const char kShaderUpdateLightInfo[] = "RenderPasses/ReStirExp/updateLightBuffer.cs.slang";
    const char kShaderFillSurfaceInformation[] = "RenderPasses/ReStirExp/fillSurfaceInfo.cs.slang";
    const char kShaderPresampleLights[] = "RenderPasses/ReStirExp/presampleLights.cs.slang";
    const char kShaderGenerateCandidates[] = "RenderPasses/ReStirExp/generateCandidates.cs.slang";
    const char kShaderTemporalPass[] = "RenderPasses/ReStirExp/temporalResampling.cs.slang";
    const char kShaderSpartialPass[] = "RenderPasses/ReStirExp/spartialResampling.cs.slang";
    const char kShaderSpartioTemporalPass[] = "RenderPasses/ReStirExp/spartioTemporalResampling.cs.slang";
    const char kShaderFinalShading[] = "RenderPasses/ReStirExp/finalShading.cs.slang";

    //Input
    const ChannelDesc kInVBuffer = { "vbuffer",             "gVBuffer",                 "V Buffer to get the intersected triangle",         false };
    const ChannelDesc kInMVec = { "mVec",                "gMVec",                    "Motion vector",         false };
    const ChannelDesc kInView = { "view",             "gView",                    "View Vector",           true };
    const ChannelDesc kInLinZ = { "linZ",               "gLinZ",                   "Distance from Camera to hitpoint",  true };
    const ChannelList kInputs = {kInVBuffer, kInMVec, kInView, kInLinZ };

    const ChannelList kOutputs = {
        {"color",                   "gColor",                   "Final shaded hdr image",                   false,  ResourceFormat::RGBA32Float},
        {"diffuseIllumination",     "gDiffuseIllumination",     "Diffuse Illumination and hit distance",    true,   ResourceFormat::RGBA32Float},
        {"diffuseReflectance",      "gDiffuseReflectance",      "Diffuse Reflectance",                      true,   ResourceFormat::RGBA32Float},
        {"specularIllumination",    "gSpecularIllumination",    "Specular illumination and hit distance",   true,   ResourceFormat::RGBA32Float},
        {"specularReflectance",     "gSpecularReflectance",     "Specular reflectance",                     true,   ResourceFormat::RGBA32Float},
    };

    const Gui::DropdownList kResamplingModeList{
        {ReStirExp::ResamplingMode::NoResampling , "No Resampling"},
        {ReStirExp::ResamplingMode::Temporal , "Temporal only"},
        {ReStirExp::ResamplingMode::Spartial , "Spartial only"},
        {ReStirExp::ResamplingMode::SpartioTemporal , "SpartioTemporal"},
    };

    const Gui::DropdownList kBiasCorrectionModeList{
        {ReStirExp::BiasCorrectionMode::Off , "Off"},
        {ReStirExp::BiasCorrectionMode::Basic , "Basic"},
        {ReStirExp::BiasCorrectionMode::RayTraced , "RayTraced"},
    };
}

ReStirExp::SharedPtr ReStirExp::create(RenderContext* pRenderContext, const Dictionary& dict)
{
    SharedPtr pPass = SharedPtr(new ReStirExp());
    return pPass;
}

Dictionary ReStirExp::getScriptingDictionary()
{
    return Dictionary();
}

RenderPassReflection ReStirExp::reflect(const CompileData& compileData)
{
    RenderPassReflection reflector;
    addRenderPassInputs(reflector,kInputs);
    addRenderPassOutputs(reflector, kOutputs);

    return reflector;
}

void ReStirExp::execute(RenderContext* pRenderContext, const RenderData& renderData)
{
    //Return on empty scene
    if (!mpScene)
        return;

    mpScene->getLightCollection(pRenderContext);

    //currently we only support emissive lights
    if (!mpScene->useEmissiveLights())return;

    prepareLighting(pRenderContext);

    prepareBuffers(pRenderContext, renderData);

    //Update/Fill the lightBuffer
    updateLightsBufferPass(pRenderContext, renderData);

    //Prepare the surface buffer
    prepareSurfaceBufferPass(pRenderContext, renderData);

    //Presample lights with light pdf
    presampleLightsPass(pRenderContext, renderData);

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

    //Copy view pass (if resource is valid) for the next pass
    if (renderData[kInView.name] != nullptr)
        pRenderContext->copyResource(mpPrevViewTexture.get(), renderData[kInView.name]->asTexture().get());

    mReuploadBuffers = mReset ? true: false;
    mBiasCorrectionChanged = false;
    mReset = false;
    mFrameCount++;
}

void ReStirExp::renderUI(Gui::Widgets& widget)
{
    bool changed = false;
    changed |= widget.dropdown("ResamplingMode", kResamplingModeList, mResamplingMode);
    //UI here
    changed |= widget.var("Initial Emissive Candidates", mNumEmissiveCandidates, 0u, 4096u);
    widget.tooltip("Number of emissive candidates generated per iteration");

    if (auto group = widget.group("Light Sampling")) {
        bool changeCheck = mUsePdfSampling;
        changed |= widget.checkbox("Use PDF Sampling", mUsePdfSampling);
        //Reset the light buffer pass on change
        if (changeCheck != mUsePdfSampling) {
            mpGenerateCandidates.reset();
            mpUpdateLightBufferPass.reset();
            mUpdateLightBuffer |= true;
        }
            

        widget.tooltip("If enabled use a pdf texture to generate the samples. If disabled the light is sampled uniformly");
        if (mUsePdfSampling) {
            widget.text("Presample texture size");
            widget.var("Title Count", mPresampledTitleSizeUI.x, 1u, 1024u);
            widget.var("Title Size", mPresampledTitleSizeUI.y, 256u, 8192u, 256.f);
            mPresampledTitleSizeChanged |= widget.button("Apply");
            if (mPresampledTitleSizeChanged)
                mPresampledTitleSize = mPresampledTitleSizeUI;
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

            changed |= widget.var("Sampling Radius", mSpartialSamplingRadius, 0.0f, 200.f);
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

    mReset |= widget.button("Recompile");
    mReuploadBuffers |= changed;
}

void ReStirExp::setScene(RenderContext* pRenderContext, const Scene::SharedPtr& pScene)
{
    mpScene = pScene;
    mReset = true;
}

void ReStirExp::prepareLighting(RenderContext* pRenderContext)
{
    //Check if light count has changed
    mUpdateLightBuffer |= mpScene->getLightCollection(pRenderContext)->update(pRenderContext);

    bool countChanged = false;
    uint sceneLightCount = mpScene->getLightCollection(pRenderContext)->getActiveLightCount();
    if (mNumLights != sceneLightCount) {
        mNumLights = sceneLightCount;
        countChanged = true;
    }

    //Create light buffer
    if (!mpLightBuffer || countChanged) {
        mpLightBuffer = Buffer::createStructured(sizeof(uint) * 8, mNumLights);
        mpLightBuffer->setName("ReStirExp::LightsBuffer");
    }

    if (mUsePdfSampling) {
        //Create pdf texture
        uint width, height, mip;
        computePdfTextureSize(mNumLights, width, height, mip);
        if (!mpLightPdfTexture || mpLightPdfTexture->getWidth() != width || mpLightPdfTexture->getHeight() != height || mpLightPdfTexture->getMipCount() != mip) {
            mpLightPdfTexture = Texture::create2D(width, height, ResourceFormat::R16Float, 1u, mip, nullptr,
                                                  ResourceBindFlags::UnorderedAccess | ResourceBindFlags::ShaderResource | ResourceBindFlags::RenderTarget);
            mpLightPdfTexture->setName("ReStirExp::LightPdfTex");
            mUpdateLightBuffer = true;
        }

        //Create Buffer for the presampled lights
        if (!mpPresampledLight || mPresampledTitleSizeChanged) {
            mpPresampledLight = Buffer::createStructured(sizeof(uint2), mPresampledTitleSize.x * mPresampledTitleSize.y);
            mpPresampledLight->setName("ReStirExp::PresampledLights");
            mPresampledTitleSizeChanged = false;
        }
    }
    //Reset buffer if they exist
    else {
        if (mpLightPdfTexture)
            mpLightPdfTexture.reset();
        if (mpPresampledLight)
            mpPresampledLight.reset();
    }
    

    //Rebuild if count changed
    mUpdateLightBuffer |= countChanged;

    //Clear texture if count changed
    if(mUpdateLightBuffer && mUsePdfSampling)
        pRenderContext->clearUAV(mpLightPdfTexture->getUAV().get(), float4(0.f));
}

void ReStirExp::prepareBuffers(RenderContext* pRenderContext, const RenderData& renderData)
{
    //Has resolution changed ?
    if ((mScreenRes.x != renderData.getDefaultTextureDims().x) || (mScreenRes.y != renderData.getDefaultTextureDims().y) || mReset)
    {
        mScreenRes = renderData.getDefaultTextureDims();
        for (size_t i = 0; i <= 1; i++) {
            mpReservoirBuffer[i].reset();
            mpReservoirUVBuffer[i].reset();
            mpSurfaceBuffer[i].reset();
            mpPrevViewTexture.reset();
        }
        mReset = true;  //TODO: Dont rebuild everything on screen size change
    }
    //TODO check if resolution changed
    if (!mpReservoirBuffer[0] || !mpReservoirBuffer[1]) {
        mpReservoirBuffer[0] = Texture::create2D(renderData.getDefaultTextureDims().x, renderData.getDefaultTextureDims().y, ResourceFormat::RGBA32Uint,
                                                 1, 1, nullptr, ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess);
        mpReservoirBuffer[0]->setName("ReStirExp::ReservoirBuf1");
        mpReservoirBuffer[1] = Texture::create2D(renderData.getDefaultTextureDims().x, renderData.getDefaultTextureDims().y, ResourceFormat::RGBA32Uint,
                                                 1, 1, nullptr, ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess);
        mpReservoirBuffer[1]->setName("ReStirExp::ReservoirBuf2");
    }
    if (!mpReservoirUVBuffer[0] || !mpReservoirUVBuffer[1]) {
        uint2 texDim = renderData.getDefaultTextureDims();
        uint bufferSize = texDim.x * texDim.y;
        mpReservoirUVBuffer[0] = Texture::create2D(renderData.getDefaultTextureDims().x, renderData.getDefaultTextureDims().y, ResourceFormat::R32Uint,
                                                 1, 1, nullptr, ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess);
        mpReservoirUVBuffer[0]->setName("ReStirExp::ReservoirBuf1");
        mpReservoirUVBuffer[1] = Texture::create2D(renderData.getDefaultTextureDims().x, renderData.getDefaultTextureDims().y, ResourceFormat::R32Uint,
                                                 1, 1, nullptr, ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess);
        mpReservoirUVBuffer[1]->setName("ReStirExp::ReservoirBuf2");
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
        /*
        mpNeighborOffsetBuffer = Buffer::createTyped(ResourceFormat::RG8Snorm, kNumNeighborOffsets,
                                                     ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess,
                                                     Buffer::CpuAccess::None,
                                                     offsets.data());
        */
        mpNeighborOffsetBuffer = Texture::create1D(kNumNeighborOffsets, ResourceFormat::RG8Snorm, 1, 1, offsets.data());

        
        mpNeighborOffsetBuffer->setName("ReStirExp::NeighborOffsetBuffer");
    }

    //Create a prev view texture if the view texture is valid
    if ((renderData[kInView.name] != nullptr) && !mpPrevViewTexture) {
        mpPrevViewTexture = Texture::create2D(mScreenRes.x, mScreenRes.y, renderData[kInView.name]->asTexture()->getFormat(), 1, 1u,
                                              nullptr, ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess);
        mpPrevViewTexture->setName("ReStirExp::PrevView");
    }

    if (!mpGenerateSampleGenerator) {
        mpGenerateSampleGenerator = SampleGenerator::create(SAMPLE_GENERATOR_UNIFORM);
    }
}

void ReStirExp::updateLightsBufferPass(RenderContext* pRenderContext, const RenderData& renderData)
{
    FALCOR_PROFILE("UpdateLights");
    //Skip Pass if light buffer is up to date
    if (!mUpdateLightBuffer) return;

    //init
    if (!mpUpdateLightBufferPass) {
        Program::Desc desc;
        desc.addShaderLibrary(kShaderUpdateLightInfo).csEntry("main").setShaderModel("6_5");
        desc.addTypeConformances(mpScene->getTypeConformances());

        Program::DefineList defines;
        defines.add(mpScene->getSceneDefines());
        defines.add("USE_PDF_TEX", mUsePdfSampling ? "1" : "0");
        mpUpdateLightBufferPass = ComputePass::create(desc, defines, true);
    }
    FALCOR_ASSERT(mpUpdateLightBufferPass);

    //Set variables
    auto var = mpUpdateLightBufferPass->getRootVar();
    mpScene->setRaytracingShaderData(pRenderContext, var, 1);   //Set scene data

    var["gLightBuffer"] = mpLightBuffer;
    if(mUsePdfSampling) var["gLightPdf"] = mpLightPdfTexture;

    uint2 targetDim = uint2(8192u, div_round_up(mNumLights, 8192u));

    if (mReset || mReuploadBuffers) {
        var["Constant"]["gThreadDim"] = targetDim;
        var["Constant"]["gMaxNumLights"] = mNumLights;
    }

    mpUpdateLightBufferPass->execute(pRenderContext, uint3(targetDim, 1));

    //Create Mip chain
    if (mUsePdfSampling) mpLightPdfTexture->generateMips(pRenderContext);
    mUpdateLightBuffer = false;
}

void ReStirExp::prepareSurfaceBufferPass(RenderContext* pRenderContext, const RenderData& renderData)
{
    FALCOR_PROFILE("FillSurfaceBuffer");

    if (mReset) mpFillSurfaceInfoPass.reset();

    //init
    if (!mpFillSurfaceInfoPass) {
        Program::Desc desc;
        desc.addShaderLibrary(kShaderFillSurfaceInformation).csEntry("main").setShaderModel("6_5");
        desc.addTypeConformances(mpScene->getTypeConformances());
        
        Program::DefineList defines;
        defines.add(mpScene->getSceneDefines());
        defines.add(getValidResourceDefines(kInputs, renderData));
        mpFillSurfaceInfoPass = ComputePass::create(desc, defines, true);
    }
    FALCOR_ASSERT(mpFillSurfaceInfoPass);

    //Set variables
    auto var = mpFillSurfaceInfoPass->getRootVar();

    var[kInVBuffer.texname] = renderData[kInVBuffer.name]->asTexture();
    var[kInView.texname] = renderData[kInView.name]->asTexture();           //Optional view tex
    var[kInLinZ.texname] = renderData[kInLinZ.name]->asTexture();           //Optional linZ texw]
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

void ReStirExp::presampleLightsPass(RenderContext* pRenderContext, const RenderData& renderData)
{
    if (!mUsePdfSampling) {
        if (mpPresampleLightsPass)
            mpPresampleLightsPass.reset();
        return;
    }

    FALCOR_PROFILE("PresampleLight");
    if (!mpPresampleLightsPass) {
        Program::Desc desc;
        desc.addShaderLibrary(kShaderPresampleLights).csEntry("main").setShaderModel("6_5");
        desc.addTypeConformances(mpScene->getTypeConformances());

        Program::DefineList defines;
        defines.add(mpScene->getSceneDefines());
        defines.add(mpGenerateSampleGenerator->getDefines());
        mpPresampleLightsPass = ComputePass::create(desc, defines, true);
    }
    FALCOR_ASSERT(mpPresampleLightsPass);

    //Set variables
    auto var = mpPresampleLightsPass->getRootVar();

    var["PerFrame"]["gFrameCount"] = mFrameCount;

    if (mReset || mReuploadBuffers) {
        var["Constant"]["gPdfTexSize"] = uint2(mpLightPdfTexture->getWidth(), mpLightPdfTexture->getHeight());
        var["Constant"]["gTileSizes"] = mPresampledTitleSize;
    }

    var["gLightPdf"] = mpLightPdfTexture;
    var["gPresampledLights"] = mpPresampledLight;

    uint2 targetDim = mPresampledTitleSize;
    mpPresampleLightsPass->execute(pRenderContext, uint3(targetDim, 1));

    pRenderContext->uavBarrier(mpPresampledLight.get());
}

void ReStirExp::generateCandidatesPass(RenderContext* pRenderContext, const RenderData& renderData)
{
    FALCOR_PROFILE("GenerateCandidates");

    //Clear current reservoir
    pRenderContext->clearUAV(mpReservoirBuffer[mFrameCount % 2].get()->getUAV().get(), uint4(0));
    pRenderContext->clearUAV(mpReservoirUVBuffer[mFrameCount % 2].get()->getUAV().get(), uint4(0));

    if (mReset) mpGenerateCandidates.reset();

    //Create pass
    if (!mpGenerateCandidates) {
        Program::Desc desc;
        desc.addShaderLibrary(kShaderGenerateCandidates).csEntry("main").setShaderModel("6_5");
        desc.addTypeConformances(mpScene->getTypeConformances());

        Program::DefineList defines;
        defines.add(mpScene->getSceneDefines());
        defines.add(mpGenerateSampleGenerator->getDefines());
        defines.add("VIS_RAY_OFFSET", std::to_string(mVisibilityRayOffset));
        defines.add("USE_PRESAMPLED", mUsePdfSampling ? "1" : "0");
        defines.add(getValidResourceDefines(kInputs, renderData));

        mpGenerateCandidates = ComputePass::create(desc, defines, true);
    }
    FALCOR_ASSERT(mpGenerateCandidates);

    //Set variables
    auto var = mpGenerateCandidates->getRootVar();

    mpScene->setRaytracingShaderData(pRenderContext, var, 1);   //Set scene data
    mpGenerateSampleGenerator->setShaderData(var);          //Sample generator
    var["gReservoir"] = mpReservoirBuffer[mFrameCount % 2];
    var["gReservoirUV"] = mpReservoirUVBuffer[mFrameCount % 2];
    var["gSurface"] = mpSurfaceBuffer[mFrameCount % 2];
    if(mUsePdfSampling) var["gPresampledLight"] = mpPresampledLight;
    var["gLights"] = mpLightBuffer;

    var[kInView.texname] = renderData[kInView.name]->asTexture();    //BindView buffer (is only used if valid)

    //Uniform
    std::string uniformName = "PerFrame";

    var[uniformName]["gFrameCount"] = mFrameCount;
    if (mReset || mReuploadBuffers) {
        uniformName = "Constant";
        var[uniformName]["gNumEmissiveSamples"] = mNumEmissiveCandidates;
        var[uniformName]["gFrameDim"] = renderData.getDefaultTextureDims();
        var[uniformName]["gTestVisibility"] = true;   //TODO: Also add a variable to manually disable
        var[uniformName]["gLightBufferSize"] = mUsePdfSampling ? uint2(mPresampledTitleSize.x, mPresampledTitleSize.y) : uint2(mNumLights,0);
    }

    //Execute
    const uint2 targetDim = renderData.getDefaultTextureDims();
    FALCOR_ASSERT(targetDim.x > 0 && targetDim.y > 0);
    mpGenerateCandidates->execute(pRenderContext, uint3(targetDim, 1));

    //Barrier for written buffer
    pRenderContext->uavBarrier(mpReservoirBuffer[mFrameCount % 2].get());
    pRenderContext->uavBarrier(mpReservoirUVBuffer[mFrameCount % 2].get());
}

void ReStirExp::temporalResampling(RenderContext* pRenderContext, const RenderData& renderData)
{
    FALCOR_PROFILE("TemporalResampling");

    if (mReset || mBiasCorrectionChanged) mpTemporalResampling.reset();

    //Create Pass
    if (!mpTemporalResampling) {
        Program::Desc desc;
        desc.addShaderLibrary(kShaderTemporalPass).csEntry("main").setShaderModel("6_5");
        desc.addTypeConformances(mpScene->getTypeConformances());

        Program::DefineList defines;
        defines.add(mpScene->getSceneDefines());
        defines.add(mpGenerateSampleGenerator->getDefines());
        defines.add("BIAS_CORRECTION_MODE", std::to_string(mBiasCorrectionMode));
        defines.add("VIS_RAY_OFFSET", std::to_string(mVisibilityRayOffset));
        defines.add(getValidResourceDefines(kInputs, renderData));

        mpTemporalResampling = ComputePass::create(desc, defines, true);
    }
    FALCOR_ASSERT(mpTemporalResampling);

    if (mReset) return; //Scip the rest on the first frame as the temporal buffer is invalid anyway

    //Set variables
    auto var = mpTemporalResampling->getRootVar();

    mpScene->setRaytracingShaderData(pRenderContext, var, 1);   //Set scene data
    mpGenerateSampleGenerator->setShaderData(var);          //Sample generator

    var["gLights"] = mpLightBuffer;
    var["gReservoirPrev"] = mpReservoirBuffer[(mFrameCount + 1) % 2];
    var["gReservoir"] = mpReservoirBuffer[mFrameCount % 2];
    var["gReservoirUVPrev"] = mpReservoirUVBuffer[(mFrameCount + 1) % 2];
    var["gReservoirUV"] = mpReservoirUVBuffer[mFrameCount % 2];
    var["gSurface"] = mpSurfaceBuffer[mFrameCount % 2];
    var["gSurfacePrev"] = mpSurfaceBuffer[(mFrameCount + 1) % 2];

    var[kInMVec.texname] = renderData[kInMVec.name]->asTexture();    //BindMvec
    var[kInView.texname] = renderData[kInView.name]->asTexture();    //BindView buffer (is only used if valid)
    var["gPrevView"] = mpPrevViewTexture;                           //Is nullptr if view not set

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
    pRenderContext->uavBarrier(mpReservoirUVBuffer[mFrameCount % 2].get());
}

void ReStirExp::spartialResampling(RenderContext* pRenderContext, const RenderData& renderData)
{
    FALCOR_PROFILE("SpartialResampling");

    //Clear the other reservoir
    pRenderContext->clearUAV(mpReservoirBuffer[(mFrameCount+1) % 2].get()->getUAV().get(), uint4(0));
    pRenderContext->clearUAV(mpReservoirUVBuffer[(mFrameCount + 1) % 2].get()->getUAV().get(), uint4(0));

    if (mReset ||mBiasCorrectionChanged) mpSpartialResampling.reset();

    //Create Pass
    if (!mpSpartialResampling) {
        Program::Desc desc;
        desc.addShaderLibrary(kShaderSpartialPass).csEntry("main").setShaderModel("6_5");
        desc.addTypeConformances(mpScene->getTypeConformances());

        Program::DefineList defines;
        defines.add(mpScene->getSceneDefines());
        defines.add(mpGenerateSampleGenerator->getDefines());
        defines.add("BIAS_CORRECTION_MODE", std::to_string(mBiasCorrectionMode));
        defines.add("OFFSET_BUFFER_SIZE", std::to_string(kNumNeighborOffsets));
        defines.add("VIS_RAY_OFFSET", std::to_string(mVisibilityRayOffset));
        defines.add(getValidResourceDefines(kInputs, renderData));

        mpSpartialResampling = ComputePass::create(desc, defines, true);
    }
    FALCOR_ASSERT(mpSpartialResampling);

    if (mReset) return; //Scip the rest on the first frame as the temporal buffer is invalid anyway

    //Set variables
    auto var = mpSpartialResampling->getRootVar();

    mpScene->setRaytracingShaderData(pRenderContext, var, 1);   //Set scene data
    mpGenerateSampleGenerator->setShaderData(var);          //Sample generator

    var["gLights"] = mpLightBuffer;
    var["gReservoir"] = mpReservoirBuffer[mFrameCount % 2];
    var["gOutReservoir"] = mpReservoirBuffer[(mFrameCount+1) % 2];
    var["gOutReservoirUV"] = mpReservoirUVBuffer[(mFrameCount + 1) % 2];
    var["gReservoirUV"] = mpReservoirUVBuffer[mFrameCount % 2];
    var["gNeighOffsetBuffer"] = mpNeighborOffsetBuffer;
    var["gSurface"] = mpSurfaceBuffer[mFrameCount % 2];

    var[kInMVec.texname] = renderData[kInMVec.name]->asTexture();    //BindMvec
    var[kInView.texname] = renderData[kInView.name]->asTexture();    //BindView buffer (is only used if valid)

    //Uniform
    std::string uniformName = "PerFrame";
    var[uniformName]["gFrameCount"] = mFrameCount;
    if (mReset || mReuploadBuffers || mBiasCorrectionChanged) {
        uniformName = "Constant";
        var[uniformName]["gFrameDim"] = renderData.getDefaultTextureDims();
        var[uniformName]["gSpartialSamples"] = mSpartialSamples;
        var[uniformName]["gSamplingRadius"] = mSpartialSamplingRadius;
        var[uniformName]["gDepthThreshold"] = mRelativeDepthThreshold;
        var[uniformName]["gNormalThreshold"] = mNormalThreshold;
    }

    //Execute
    const uint2 targetDim = renderData.getDefaultTextureDims();
    FALCOR_ASSERT(targetDim.x > 0 && targetDim.y > 0);
    mpSpartialResampling->execute(pRenderContext, uint3(targetDim, 1));

    //Barrier for written buffer
    pRenderContext->uavBarrier(mpReservoirBuffer[(mFrameCount + 1) % 2].get());
    pRenderContext->uavBarrier(mpReservoirUVBuffer[(mFrameCount + 1) % 2].get());
}

void ReStirExp::spartioTemporalResampling(RenderContext* pRenderContext, const RenderData& renderData)
{
    FALCOR_PROFILE("SpartioTemporalResampling");

    if (mReset || mBiasCorrectionChanged) mpSpartioTemporalResampling.reset();

    //Create Pass
    if (!mpSpartioTemporalResampling) {
        Program::Desc desc;
        desc.addShaderLibrary(kShaderSpartioTemporalPass).csEntry("main").setShaderModel("6_5");
        desc.addTypeConformances(mpScene->getTypeConformances());

        Program::DefineList defines;
        defines.add(mpScene->getSceneDefines());
        defines.add(mpGenerateSampleGenerator->getDefines());
        defines.add("BIAS_CORRECTION_MODE", std::to_string(mBiasCorrectionMode));
        defines.add("OFFSET_BUFFER_SIZE", std::to_string(kNumNeighborOffsets));
        defines.add("VIS_RAY_OFFSET", std::to_string(mVisibilityRayOffset));
        defines.add(getValidResourceDefines(kInputs, renderData));

        mpSpartioTemporalResampling = ComputePass::create(desc, defines, true);
    }
    FALCOR_ASSERT(mpSpartioTemporalResampling);

    if (mReset) return; //Scip the rest on the first frame as the temporal buffer is invalid anyway

    //Set variables
    auto var = mpSpartioTemporalResampling->getRootVar();

    mpScene->setRaytracingShaderData(pRenderContext, var, 1);   //Set scene data
    mpGenerateSampleGenerator->setShaderData(var);          //Sample generator

    var["gLights"] = mpLightBuffer;
    var["gSurfacePrev"] =  mpSurfaceBuffer[(mFrameCount + 1) % 2];
    var["gSurface"] = mpSurfaceBuffer[mFrameCount % 2];
    var["gReservoirPrev"] = mpReservoirBuffer[(mFrameCount + 1) % 2];
    var["gReservoir"] = mpReservoirBuffer[mFrameCount % 2];
    var["gReservoirUVPrev"] = mpReservoirUVBuffer[(mFrameCount + 1) % 2];
    var["gReservoirUV"] = mpReservoirUVBuffer[mFrameCount % 2];
    var["gNeighOffsetBuffer"] = mpNeighborOffsetBuffer;

    var[kInMVec.texname] = renderData[kInMVec.name]->asTexture();    //BindMvec
    var[kInView.texname] = renderData[kInView.name]->asTexture();    //BindView buffer (is only used if valid)
    var["gPrevView"] = mpPrevViewTexture;                            //Is nullptr if view not set

    //Uniform
    std::string uniformName = "PerFrame";
    var[uniformName]["gFrameCount"] = mFrameCount;
    if (mReset || mReuploadBuffers || mBiasCorrectionChanged) {
        uniformName = "Constant";
        var[uniformName]["gFrameDim"] = renderData.getDefaultTextureDims();
        var[uniformName]["gMaxAge"] = mTemporalMaxAge;
        var[uniformName]["gSpartialSamples"] = mSpartialSamples;
        var[uniformName]["gSamplingRadius"] = mSpartialSamplingRadius;
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

void ReStirExp::finalShadingPass(RenderContext* pRenderContext, const RenderData& renderData)
{
    FALCOR_PROFILE("FinalShading");

    if (mReset) mpFinalShading.reset();

    //Create pass
    if (!mpFinalShading) {
        Program::Desc desc;
        desc.addShaderLibrary(kShaderFinalShading).csEntry("main").setShaderModel("6_5");
        desc.addTypeConformances(mpScene->getTypeConformances());

        Program::DefineList defines;
        defines.add(mpScene->getSceneDefines());
        defines.add(mpGenerateSampleGenerator->getDefines());
        defines.add(getValidResourceDefines(kInputs, renderData));
        defines.add(getValidResourceDefines(kOutputs, renderData));

        mpFinalShading = ComputePass::create(desc, defines, true);
    }
    FALCOR_ASSERT(mpFinalShading);

    // For optional I/O resources, set 'is_valid_<name>' defines to inform the program of which ones it can access.
    mpFinalShading->getProgram()->addDefines(getValidResourceDefines(kOutputs, renderData));

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
    mpGenerateSampleGenerator->setShaderData(var);          //Sample generator

    uint reservoirIndex = mResamplingMode == ResamplingMode::Spartial ? (mFrameCount + 1) % 2 : mFrameCount % 2;

    var["gReservoir"] = mpReservoirBuffer[reservoirIndex];
    var["gReservoirUV"] = mpReservoirUVBuffer[reservoirIndex];
    var["gLights"] = mpLightBuffer;
    //Bind I/O
    bindAsTex(kInVBuffer);
    bindAsTex(kInMVec);
    bindAsTex(kInView);
    for (auto& out : kOutputs) bindAsTex(out);

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

void ReStirExp::fillNeighborOffsetBuffer(std::vector<int8_t>& buffer)
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


        //buffer[num++] = (u - 0.5f) * R;
        //buffer[num++] = (v - 0.5f) * R;
        buffer[num++] = int8_t((u - 0.5f) * R);
        buffer[num++] = int8_t((v - 0.5f) * R);
    }
}

void ReStirExp::computePdfTextureSize(uint32_t maxItems, uint32_t& outWidth, uint32_t& outHeight, uint32_t& outMipLevels)
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
