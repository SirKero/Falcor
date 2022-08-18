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
    const char kShaderGenerateCandidates[] = "RenderPasses/ReStirExp/generateCandidates.cs.slang";
    const char kShaderTemporalPass[] = "RenderPasses/ReStirExp/temporalResampling.cs.slang";
    const char kShaderSpartialPass[] = "RenderPasses/ReStirExp/spartialResampling.cs.slang";
    const char kShaderSpartioTemporalPass[] = "RenderPasses/ReStirExp/spartioTemporalResampling.cs.slang";
    const char kShaderFinalShading[] = "RenderPasses/ReStirExp/finalShading.cs.slang";

    //Input
    const ChannelList kInputs = {
          {"vbuffer",             "gVBuffer",                 "V Buffer to get the intersected triangle",         false},
          {"mVec",                "gMVec",                    "Motion vector",         false}
    };

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

    generateCandidatesPass(pRenderContext, renderData);

    switch (mResamplingMode) {
    case ResamplingMode::Temporal:
        temporalResampling(pRenderContext, renderData);
        break;
    case ResamplingMode::Spartial:
        spartialResampling(pRenderContext, renderData);
        break;
    case ResamplingMode::SpartioTemporal:
        spartioTemporalResampling(pRenderContext, renderData);
        break;
    }

    finalShadingPass(pRenderContext, renderData);


    mReset = false;
    mReuploadBuffers = false;
    mFrameCount++;
}

void ReStirExp::renderUI(Gui::Widgets& widget)
{
    bool changed = false;
    changed |= widget.dropdown("ResamplingMode", kResamplingModeList, mResamplingMode);
    //UI here
    changed |= widget.var("Initial Emissive Candidates", mNumEmissiveCandidates, 0u, 4096u);
    widget.tooltip("Number of emissive candidates generated per iteration");

    if (mResamplingMode > 0) {
        if (auto group = widget.group("Resamling")) {
            changed |= widget.dropdown("BiasCorrection", kBiasCorrectionModeList, mBiasCorrectionMode);

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
    }

    mReset = widget.button("Recompile");
    mReuploadBuffers |= changed;
}

void ReStirExp::setScene(RenderContext* pRenderContext, const Scene::SharedPtr& pScene)
{
    //TODO: Reset Pass
    mpScene = pScene;
    mReset = true;
}

bool ReStirExp::prepareLighting(RenderContext* pRenderContext)
{
    //TODO set up a lighting texture for emissive and area light
    return false;
}

void ReStirExp::prepareBuffers(RenderContext* pRenderContext, const RenderData& renderData)
{
    //Has resolution changed ?
    if ((mScreenRes.x != renderData.getDefaultTextureDims().x) || (mScreenRes.y != renderData.getDefaultTextureDims().y) || mReset)
    {
        mScreenRes = renderData.getDefaultTextureDims();
        mpReservoirBuffer[0].reset(); mpReservoirBuffer[1].reset();
        mpPreviousVBuffer.reset();
        mReset = true;  //TODO: Dont rebuild everything on screen size change
    }
    //TODO check if resolution changed
    if (!mpReservoirBuffer[0] || !mpReservoirBuffer[1]) {
        uint2 texDim = renderData.getDefaultTextureDims();
        uint bufferSize = texDim.x * texDim.y;
        mpReservoirBuffer[0] = Buffer::createStructured(sizeof(uint) * 8, bufferSize);
        mpReservoirBuffer[0]->setName("ReStirExp::ReservoirBuf1");
        mpReservoirBuffer[1] = Buffer::createStructured(sizeof(uint) * 8, bufferSize);
        mpReservoirBuffer[1]->setName("ReStirExp::ReservoirBuf2");
    }

    //Create a VBuffer for temporal Surface resampling
    if (!mpPreviousVBuffer) {
        mpPreviousVBuffer = Texture::create2D(renderData.getDefaultTextureDims().x, renderData.getDefaultTextureDims().y, mVBufferFormat,1 ,1 ,nullptr, Resource::BindFlags::UnorderedAccess | Resource::BindFlags::ShaderResource);
        mpPreviousVBuffer->setName("ReStirExp:PreviousVBuffer");
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

    if (!mpGenerateSampleGenerator) {
        mpGenerateSampleGenerator = SampleGenerator::create(SAMPLE_GENERATOR_UNIFORM);
    }
}

void ReStirExp::generateCandidatesPass(RenderContext* pRenderContext, const RenderData& renderData)
{
    FALCOR_PROFILE("GenerateCandidates");

    //Clear current reservoir
    pRenderContext->clearUAV(mpReservoirBuffer[mFrameCount % 2].get()->getUAV().get(), float4(0.f));

    if (mReset) mpGenerateCandidates.reset();

    //Create pass
    if (!mpGenerateCandidates) {
        Program::Desc desc;
        desc.addShaderLibrary(kShaderGenerateCandidates).csEntry("main").setShaderModel("6_5");
        desc.addTypeConformances(mpScene->getTypeConformances());

        Program::DefineList defines;
        defines.add(mpScene->getSceneDefines());
        defines.add(mpGenerateSampleGenerator->getDefines());

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
    mpGenerateSampleGenerator->setShaderData(var);          //Sample generator
    var["gReservoir"] = mpReservoirBuffer[mFrameCount % 2];
    for (auto& inp : kInputs) bindAsTex(inp);

    //Uniform
    std::string uniformName = "PerFrame";

    var[uniformName]["gFrameCount"] = mFrameCount;
    if (mReset || mReuploadBuffers) {
        uniformName = "Constant";
        var[uniformName]["gNumEmissiveSamples"] = mNumEmissiveCandidates;
        var[uniformName]["gFrameDim"] = renderData.getDefaultTextureDims();
        var[uniformName]["gTestVisibility"] = mResamplingMode > 0;   //TODO: Also add a variable to manually disable
    }

    //Execute
    const uint2 targetDim = renderData.getDefaultTextureDims();
    FALCOR_ASSERT(targetDim.x > 0 && targetDim.y > 0);
    mpGenerateCandidates->execute(pRenderContext, uint3(targetDim, 1));

    //Barrier for written buffer
    pRenderContext->uavBarrier(mpReservoirBuffer[mFrameCount % 2].get());
}

void ReStirExp::temporalResampling(RenderContext* pRenderContext, const RenderData& renderData)
{
    FALCOR_PROFILE("TemporalResampling");

    if (mReset) mpTemporalResampling.reset();

    //Create Pass
    if (!mpTemporalResampling) {
        Program::Desc desc;
        desc.addShaderLibrary(kShaderTemporalPass).csEntry("main").setShaderModel("6_5");
        desc.addTypeConformances(mpScene->getTypeConformances());

        Program::DefineList defines;
        defines.add(mpScene->getSceneDefines());
        defines.add(mpGenerateSampleGenerator->getDefines());

        mpTemporalResampling = ComputePass::create(desc, defines, true);
    }
    FALCOR_ASSERT(mpTemporalResampling);

    if (mReset) return; //Scip the rest on the first frame as the temporal buffer is invalid anyway

    //Set variables
    auto var = mpTemporalResampling->getRootVar();

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

    var["gReservoirPrev"] = mpReservoirBuffer[(mFrameCount + 1) % 2];
    var["gReservoir"] = mpReservoirBuffer[mFrameCount % 2];
    for (auto& inp : kInputs) bindAsTex(inp);
    var["gPrevVBuffer"] = mpPreviousVBuffer;

    //Uniform
    std::string uniformName = "PerFrame";
    var[uniformName]["gFrameCount"] = mFrameCount;
    if (mReset || mReuploadBuffers) {
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

void ReStirExp::spartialResampling(RenderContext* pRenderContext, const RenderData& renderData)
{
    FALCOR_PROFILE("SpartialResampling");

    //Clear the other reservoir
    pRenderContext->clearUAV(mpReservoirBuffer[(mFrameCount+1) % 2].get()->getUAV().get(), float4(0.f));

    if (mReset) mpSpartialResampling.reset();

    //Create Pass
    if (!mpSpartialResampling) {
        Program::Desc desc;
        desc.addShaderLibrary(kShaderSpartialPass).csEntry("main").setShaderModel("6_5");
        desc.addTypeConformances(mpScene->getTypeConformances());

        Program::DefineList defines;
        defines.add(mpScene->getSceneDefines());
        defines.add(mpGenerateSampleGenerator->getDefines());
        defines.add("OFFSET_BUFFER_SIZE", std::to_string(kNumNeighborOffsets));

        mpSpartialResampling = ComputePass::create(desc, defines, true);
    }
    FALCOR_ASSERT(mpSpartialResampling);

    if (mReset) return; //Scip the rest on the first frame as the temporal buffer is invalid anyway

    //Set variables
    auto var = mpSpartialResampling->getRootVar();

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

    var["gReservoir"] = mpReservoirBuffer[mFrameCount % 2];
    var["gOutReservoir"] = mpReservoirBuffer[(mFrameCount+1) % 2];
    var["gNeighOffsetBuffer"] = mpNeighborOffsetBuffer;
    for (auto& inp : kInputs) bindAsTex(inp);

    //Uniform
    std::string uniformName = "PerFrame";
    var[uniformName]["gFrameCount"] = mFrameCount;
    if (mReset || mReuploadBuffers) {
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
    pRenderContext->uavBarrier(mpReservoirBuffer[mFrameCount % 2].get());
}

void ReStirExp::spartioTemporalResampling(RenderContext* pRenderContext, const RenderData& renderData)
{
    FALCOR_PROFILE("SpartioTemporalResampling");

    if (mReset) mpSpartioTemporalResampling.reset();

    //Create Pass
    if (!mpSpartioTemporalResampling) {
        Program::Desc desc;
        desc.addShaderLibrary(kShaderSpartioTemporalPass).csEntry("main").setShaderModel("6_5");
        desc.addTypeConformances(mpScene->getTypeConformances());

        Program::DefineList defines;
        defines.add(mpScene->getSceneDefines());
        defines.add(mpGenerateSampleGenerator->getDefines());
        defines.add("OFFSET_BUFFER_SIZE", std::to_string(kNumNeighborOffsets));

        mpSpartioTemporalResampling = ComputePass::create(desc, defines, true);
    }
    FALCOR_ASSERT(mpSpartioTemporalResampling);

    if (mReset) return; //Scip the rest on the first frame as the temporal buffer is invalid anyway

    //Set variables
    auto var = mpSpartioTemporalResampling->getRootVar();

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

    var["gPrevVBuffer"] = mpPreviousVBuffer;
    var["gReservoirPrev"] = mpReservoirBuffer[(mFrameCount + 1) % 2];
    var["gReservoir"] = mpReservoirBuffer[mFrameCount % 2];
    var["gNeighOffsetBuffer"] = mpNeighborOffsetBuffer;

    for (auto& inp : kInputs) bindAsTex(inp);

    //Uniform
    std::string uniformName = "PerFrame";
    var[uniformName]["gFrameCount"] = mFrameCount;
    if (mReset || mReuploadBuffers) {
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
    for (auto& inp : kInputs) bindAsTex(inp);
    var["gPrevVBuffer"] = mpPreviousVBuffer;        //For copying 
    for (auto& out : kOutputs) bindAsTex(out);

    //Uniform
    std::string uniformName = "PerFrame";
    var[uniformName]["gFrameCount"] = mFrameCount;
    if (mReset || mReuploadBuffers) {
        uniformName = "Constant";
        var[uniformName]["gFrameDim"] = renderData.getDefaultTextureDims();
        var[uniformName]["gUseEmissiveTexture"] = mUseEmissiveTexture;
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
