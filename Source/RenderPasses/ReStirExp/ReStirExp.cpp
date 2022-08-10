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
    mFrameCount++;
}

void ReStirExp::renderUI(Gui::Widgets& widget)
{
    //UI here
    widget.dropdown("ResamplingMode", kResamplingModeList, mResamplingMode);

    widget.var("Initial Emissive Candidates", mNumEmissiveCandidates, 0u, 4096u);

    widget.var("Temporal age", mTemporalMaxAge, 0u, 512u);

    widget.var("Spartial Samples", mSpartialSamples, 0u, 32u);

    widget.var("Sampling Radius", mSamplingRadius, 0.0f, 200.f);

    widget.var("Depth Threshold", mRelativeDepthThreshold, 0.0f, 1.0f, 0.0001f);

    widget.var("Normal Threshold", mNormalThreshold, 0.0f, 1.0f, 0.0001f);

    mReset = widget.button("Recompile");
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

    if (!mpPreviousVBuffer) {
        mpPreviousVBuffer = Texture::create2D(renderData.getDefaultTextureDims().x, renderData.getDefaultTextureDims().y, mVBufferFormat,1 ,1 ,nullptr, Resource::BindFlags::UnorderedAccess | Resource::BindFlags::ShaderResource);
        mpPreviousVBuffer->setName("ReStirExp:PreviousVBuffer");
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
    
    var["PerFrame"]["gFrameCount"] = mFrameCount;
    var["PerFrame"]["gNumEmissiveSamples"] = mNumEmissiveCandidates;
    var["PerFrame"]["gFrameDim"] = renderData.getDefaultTextureDims();
    var["PerFrame"]["gTestVisibility"] = mResamplingMode > 0;   //TODO: Also add a variable to manually disable
    
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
    var["PerFrame"]["gFrameCount"] = mFrameCount;
    var["PerFrame"]["gFrameDim"] = renderData.getDefaultTextureDims();
    var["PerFrame"]["gMaxAge"] = mTemporalMaxAge;
    var["PerFrame"]["gDepthThreshold"] = mRelativeDepthThreshold;
    var["PerFrame"]["gNormalThreshold"] = mNormalThreshold;

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
    for (auto& inp : kInputs) bindAsTex(inp);

    //Uniform
    var["PerFrame"]["gFrameCount"] = mFrameCount;
    var["PerFrame"]["gFrameDim"] = renderData.getDefaultTextureDims();
    var["PerFrame"]["gSpartialSamples"] = mSpartialSamples;
    var["PerFrame"]["gSamplingRadius"] = mSamplingRadius;
    var["PerFrame"]["gDepthThreshold"] = mRelativeDepthThreshold;
    var["PerFrame"]["gNormalThreshold"] = mNormalThreshold;

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
    for (auto& inp : kInputs) bindAsTex(inp);

    //Uniform
    var["PerFrame"]["gFrameCount"] = mFrameCount;
    var["PerFrame"]["gFrameDim"] = renderData.getDefaultTextureDims();
    var["PerFrame"]["gMaxAge"] = mTemporalMaxAge;
    var["PerFrame"]["gSpartialSamples"] = mSpartialSamples;
    var["PerFrame"]["gSamplingRadius"] = mSamplingRadius;
    var["PerFrame"]["gDepthThreshold"] = mRelativeDepthThreshold;
    var["PerFrame"]["gNormalThreshold"] = mNormalThreshold;

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
    var["PerFrame"]["gFrameCount"] = mFrameCount;
    var["PerFrame"]["gFrameDim"] = renderData.getDefaultTextureDims();

    //Execute
    const uint2 targetDim = renderData.getDefaultTextureDims();
    FALCOR_ASSERT(targetDim.x > 0 && targetDim.y > 0);
    mpFinalShading->execute(pRenderContext, uint3(targetDim, 1));
}
