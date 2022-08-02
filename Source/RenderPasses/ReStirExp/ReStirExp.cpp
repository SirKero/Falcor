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

    finalShadingPass(pRenderContext, renderData);

    mRecompile = false;
    mFrameCount++;
}

void ReStirExp::renderUI(Gui::Widgets& widget)
{
    //UI here
    widget.var("Initial Emissive Candidates", mNumEmissiveCandidates, 0u, 4096u);

    mRecompile = widget.button("Recompile");
}

void ReStirExp::setScene(RenderContext* pRenderContext, const Scene::SharedPtr& pScene)
{
    //TODO: Reset Pass
    mpScene = pScene;
    mRecompile = true;
}

bool ReStirExp::prepareLighting(RenderContext* pRenderContext)
{
    //TODO set up a lighting texture for 
    return false;
}

void ReStirExp::prepareBuffers(RenderContext* pRenderContext, const RenderData& renderData)
{
    //TODO check if resolution changed
    if (!mpReservoirBuffer) {
        uint2 texDim = renderData.getDefaultTextureDims();
        uint bufferSize = texDim.x * texDim.y;
        mpReservoirBuffer = Buffer::createStructured(sizeof(uint) * 8, bufferSize);
        mpReservoirBuffer->setName("ReStirExp::ReservoirBuf");
    }

    if (!mpGenerateSampleGenerator) {
        mpGenerateSampleGenerator = SampleGenerator::create(SAMPLE_GENERATOR_UNIFORM);
    }
}

void ReStirExp::generateCandidatesPass(RenderContext* pRenderContext, const RenderData& renderData)
{
    FALCOR_PROFILE("GenerateCandidates");

    if (mRecompile) mpGenerateCandidates.reset();

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
    var["gReservoir"] = mpReservoirBuffer;
    for (auto& inp : kInputs) bindAsTex(inp);

    //Uniform
    
    var["PerFrame"]["gFrameCount"] = mFrameCount;
    var["PerFrame"]["gNumEmissiveSamples"] = mNumEmissiveCandidates;
    var["PerFrame"]["gFrameDim"] = renderData.getDefaultTextureDims();
    
    //Execute
    const uint2 targetDim = renderData.getDefaultTextureDims();
    FALCOR_ASSERT(targetDim.x > 0 && targetDim.y > 0);
    mpGenerateCandidates->execute(pRenderContext, uint3(targetDim, 1));

    //Barrier for written buffer
    pRenderContext->uavBarrier(mpReservoirBuffer.get());
}

void ReStirExp::finalShadingPass(RenderContext* pRenderContext, const RenderData& renderData)
{
    FALCOR_PROFILE("FinalShading");

    if (mRecompile) mpFinalShading.reset();

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

    var["gReservoir"] = mpReservoirBuffer;
    for (auto& inp : kInputs) bindAsTex(inp);
    for (auto& out : kOutputs) bindAsTex(out);

    //Uniform
    var["PerFrame"]["gFrameCount"] = mFrameCount;
    var["PerFrame"]["gFrameDim"] = renderData.getDefaultTextureDims();

    //Execute
    const uint2 targetDim = renderData.getDefaultTextureDims();
    FALCOR_ASSERT(targetDim.x > 0 && targetDim.y > 0);
    mpFinalShading->execute(pRenderContext, uint3(targetDim, 1));
}
