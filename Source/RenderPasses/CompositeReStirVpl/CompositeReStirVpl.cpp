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
#include "CompositeReStirVpl.h"

const RenderPass::Info CompositeReStirVpl::kInfo { "CompositeReStirVpl", "Composite for the VplReStir Algorithm. Adds ReSTIR and VPLReSTIR then multiplies it with the throughput" };

namespace {
    const std::string kShaderFile("RenderPasses/CompositeReStirVpl/CompositeReStirVpl.cs.slang");

    //Inputs
    const std::string kInputReStir = "ReStir";
    const std::string kInputReStirVpl = "ReStirVpl";
    const std::string kInputThroughput = "Throughput";
    const std::string kOutput = "Out";

    //Dictonary names
    const std::string kScaleReStir = "scaleReStir";
    const std::string kScaleReStirVpl = "scaleReStirVpl";
    const std::string kScaleThroughput = "scaleThroughput";
    const std::string kOutputFormat = "outputFormat";
}

// Don't remove this. it's required for hot-reload to function properly
extern "C" FALCOR_API_EXPORT const char* getProjDir()
{
    return PROJECT_DIR;
}

extern "C" FALCOR_API_EXPORT void getPasses(Falcor::RenderPassLibrary& lib)
{
    lib.registerPass(CompositeReStirVpl::kInfo, CompositeReStirVpl::create);
}

CompositeReStirVpl::SharedPtr CompositeReStirVpl::create(RenderContext* pRenderContext, const Dictionary& dict)
{
    SharedPtr pPass = SharedPtr(new CompositeReStirVpl(dict));
    return pPass;
}

CompositeReStirVpl::CompositeReStirVpl(const Dictionary dict)
    : RenderPass(kInfo)
{
    //Parse Dictionary
    for (const auto& [key, value] : dict) {
        if (key == kScaleReStir) mScaleReStir = value;
        else if (key == kScaleReStirVpl) mScaleReStirVpl = value;
        else if (key == kScaleThroughput) mScaleThroughput = value;
        else if (key == kOutputFormat) mOutputFormat = value;
        else logWarning("Unknown field '{}' in CompositeReStirVpl pass dictionary.", key);
    }

    // Create resources.
    mpCompositeReStirVplPass = ComputePass::create(kShaderFile, "main", Program::DefineList(), true);
}

Dictionary CompositeReStirVpl::getScriptingDictionary()
{
    Dictionary dict;

    dict[kScaleReStir] = mScaleReStir;
    dict[kScaleReStirVpl] = mScaleReStirVpl;
    dict[kScaleThroughput] = mScaleThroughput;
    if(mOutputFormat != ResourceFormat::Unknown) dict[kOutputFormat] = mOutputFormat;
    return Dictionary();
}

RenderPassReflection CompositeReStirVpl::reflect(const CompileData& compileData)
{
    // Define the required resources here
    RenderPassReflection reflector;
    reflector.addInput(kInputReStir, "ReStir or RTXDI input image").bindFlags(ResourceBindFlags::ShaderResource);
    reflector.addInput(kInputReStirVpl, "ReStirVpl input image").bindFlags(ResourceBindFlags::ShaderResource);
    reflector.addInput(kInputThroughput, "Throughput input image from VBuffer").bindFlags(ResourceBindFlags::ShaderResource);
    reflector.addOutput(kOutput, "Output").bindFlags(ResourceBindFlags::UnorderedAccess).format(mOutputFormat);
    return reflector;
}

void CompositeReStirVpl::compile(RenderContext* pRenderContext, const CompileData& compileData)
{
    mFrameDim = compileData.defaultTexDims;
}

void CompositeReStirVpl::execute(RenderContext* pRenderContext, const RenderData& renderData)
{
    const auto& pOutput = renderData[kOutput]->asTexture();
    FALCOR_ASSERT(pOutput);
    mOutputFormat = pOutput->getFormat();

    //BindResources
    auto var = mpCompositeReStirVplPass->getRootVar();
    var["CB"]["frameDim"] = mFrameDim;
    var["CB"]["scaleReStir"] = mScaleReStir;
    var["CB"]["scaleReStirVpl"] = mScaleReStirVpl;
    var["CB"]["scaleThroughput"] = mScaleThroughput;

    var["gInReStir"] = renderData[kInputReStir]->asTexture();
    var["gInReStirVpl"] = renderData[kInputReStirVpl]->asTexture();
    var["gInThroughput"] = renderData[kInputThroughput]->asTexture();
    var["gOutput"] = pOutput;
    mpCompositeReStirVplPass->execute(pRenderContext, mFrameDim.x, mFrameDim.y);
}

void CompositeReStirVpl::renderUI(Gui::Widgets& widget)
{
    widget.text("Pass for combining all ReStirVpls passes");
    widget.var("Scale ReStir", mScaleReStir,0.f);
    widget.var("Scale ReStirVpl", mScaleReStirVpl, 0.f);
    widget.var("Scale Throughput", mScaleThroughput, 0.f);
}
