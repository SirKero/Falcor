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
#include "ImageFilter.h"
#include <RenderGraph/RenderPassHelpers.h>

const RenderPass::Info ImageFilter::kInfo { "ImageFilter", "Different Image Filter operations for up to 2 different Inputs" };

// Don't remove this. it's required for hot-reload to function properly
extern "C" FALCOR_API_EXPORT const char* getProjDir()
{
    return PROJECT_DIR;
}

extern "C" FALCOR_API_EXPORT void getPasses(Falcor::RenderPassLibrary& lib)
{
    lib.registerPass(ImageFilter::kInfo, ImageFilter::create);
}

namespace {
    //Shader
    const char kShader[] = "RenderPasses/ImageFilter/ImageFilter.cs.slang";

    //Inputs
    const ChannelList kInputChannels = {
        { "ImgA", "gAin", "Input image A in", false},
        { "ImgB", "gBin", "Input image B in", true},
        { "MvecA", "gMvecA", "(Relative) Motion Vector for Image A", true},
        { "MvecB", "gMvecB", "(Relative) Motion Vector for Image B", true},
    };
    //Outputs
    //TODO: Changable output format
    const ChannelList kOutputChannels = {
        { "OutA", "gAout", "Filtered output image A", false, ResourceFormat::RGBA16Float },
        { "OutB", "gBout", "Filtered output image B", true, ResourceFormat::RGBA16Float },
    };

    // UI variables.
    const Gui::DropdownList kBlurModeList =
    {
        { ImageFilter::None, "None" },
        { ImageFilter::Blur2x2, "Blur2x2" },
        { ImageFilter::Blur3x3, "Blur3x3" },
        { ImageFilter::Blur5x5, "Blur5x5" },
    };
}

ImageFilter::SharedPtr ImageFilter::create(RenderContext* pRenderContext, const Dictionary& dict)
{
    SharedPtr pPass = SharedPtr(new ImageFilter(dict));
    return pPass;
}

ImageFilter::ImageFilter(const Dictionary dict)
    : RenderPass(kInfo)
{
    //Parse Dictionary
    for (const auto& [key, value] : dict) {

    }

    // Create resources.
    mpTemporalFilterPass = ComputePass::create(kShader, "mainTemporal", Program::DefineList(), false);
    mpBlurFilterPass = ComputePass::create(kShader, "mainTemporal", Program::DefineList(), false);

    Sampler::Desc samplerDesc;
    samplerDesc.setFilterMode(Sampler::Filter::Linear, Sampler::Filter::Linear, Sampler::Filter::Point);
    samplerDesc.setAddressingMode(Sampler::AddressMode::Border, Sampler::AddressMode::Border, Sampler::AddressMode::Border);
    mpLinearSampler = Sampler::create(samplerDesc);
}

Dictionary ImageFilter::getScriptingDictionary()
{
    return Dictionary();
}

RenderPassReflection ImageFilter::reflect(const CompileData& compileData)
{
    // Define the required resources here
    RenderPassReflection reflector;
    addRenderPassInputs(reflector, kInputChannels);
    addRenderPassOutputs(reflector, kOutputChannels);
    return reflector;
}

void ImageFilter::compile(RenderContext* pRenderContext, const CompileData& compileData)
{
    mFrameDim = compileData.defaultTexDims;
}

void ImageFilter::execute(RenderContext* pRenderContext, const RenderData& renderData)
{
    //Build Textures for temporal filtering
    if (mEnableTemporalFilter) {
        if (!mpTemporalTexA) { //TODO Format as parameter
            mpTemporalTexA = Texture::create2D(mFrameDim.x, mFrameDim.y, ResourceFormat::RGBA16Float, 1u, 1u, nullptr, ResourceBindFlags::UnorderedAccess | ResourceBindFlags::ShaderResource);
            mpTemporalTexA->setName("ImageFilter::TemporalA");
        }
        if (!mpTemporalTexB) {
            mpTemporalTexB = Texture::create2D(mFrameDim.x, mFrameDim.y, ResourceFormat::RGBA16Float, 1u, 1u, nullptr, ResourceBindFlags::UnorderedAccess | ResourceBindFlags::ShaderResource);
            mpTemporalTexB->setName("ImageFilter::TemporalB");
        }
    }
    else //Free memory
    {
        if (mpTemporalTexA) {
            mpTemporalTexA.reset();
        }
        if (mpTemporalTexB) {
            mpTemporalTexB.reset();
        }
    }

    //Copy and return if both filters are disabled
    if (!mEnableTemporalFilter && (mBlurFilterMode == BlurFilterMode::None)) {
        pRenderContext->copyResource(renderData[kOutputChannels[0].name].get(), renderData[kInputChannels[0].name].get());
        if(renderData[kInputChannels[1].name] != nullptr)
            pRenderContext->copyResource(renderData[kOutputChannels[1].name].get(), renderData[kInputChannels[1].name].get());
        return;
    }


    //BindResources
    if (mEnableTemporalFilter) {
        //Defines
        Program::DefineList defineList = getValidResourceDefines(kInputChannels, renderData);
        if (mpTemporalFilterPass->getProgram()->addDefines(defineList))
        {
            mpTemporalFilterPass->setVars(nullptr);
        }

        auto var = mpTemporalFilterPass->getRootVar();

        var["CB"]["gFrameDim"] = mFrameDim;
        var["CB"]["gInvFrameDim"] = float2(1.f / mFrameDim.x, 1.f / mFrameDim.y);
        var["CB"]["gTemporalFilterLength"] = mEnableTemporalFilter ? mTemporalFilterIt : 0u;
        var["CB"]["gBlurMode"] = mBlurFilterMode;

        // Bind Input/Output Textures. These needs to be done per-frame as the buffers may change anytime.
        auto bindAsTex = [&](const ChannelDesc& desc)
        {
            if (!desc.texname.empty())
            {
                var[desc.texname] = renderData[desc.name]->asTexture();
            }
        };
        for (auto& input : kInputChannels) bindAsTex(input);
        for (auto& output : kOutputChannels) bindAsTex(output);

        //Bind Internal
        var["gTempA"] = mpTemporalTexA;
        var["gTempB"] = mpTemporalTexB;

        mpTemporalFilterPass->execute(pRenderContext, mFrameDim.x, mFrameDim.y);
    }
    

    //Blur
    if (mBlurFilterMode > BlurFilterMode::None) {

        //Defines
        Program::DefineList defineList = getValidResourceDefines(kInputChannels, renderData);
        if (mpBlurFilterPass->getProgram()->addDefines(defineList))
        {
            mpBlurFilterPass->setVars(nullptr);
        }

        //Use a barrier if the temporal filter was used
        if (mEnableTemporalFilter) {
            pRenderContext->uavBarrier(mpTemporalTexA.get());
            pRenderContext->uavBarrier(mpTemporalTexB.get());
        }

        auto var = mpBlurFilterPass->getRootVar();

        var["CB"]["gFrameDim"] = mFrameDim;
        var["CB"]["gInvFrameDim"] = float2(1.f / mFrameDim.x, 1.f / mFrameDim.y);
        var["CB"]["gTemporalFilterLength"] = mEnableTemporalFilter ? mTemporalFilterIt : 0u;
        var["CB"]["gBlurMode"] = mBlurFilterMode;

        // Bind Input/Output Textures. These needs to be done per-frame as the buffers may change anytime.
        auto bindAsTex = [&](const ChannelDesc& desc)
        {
            if (!desc.texname.empty())
            {
                var[desc.texname] = renderData[desc.name]->asTexture();
            }
        };
        for (auto& input : kInputChannels) bindAsTex(input);
        for (auto& output : kOutputChannels) bindAsTex(output);

        //Bind Inputs manual (Only input tex are needed, no need for the Mvecs for the blur)
        //var[kInputChannels[0].texname] = mEnableTemporalFilter ? mpTemporalTexA : renderData[kInputChannels[0].name]->asTexture();
        //var[kInputChannels[1].texname] = mEnableTemporalFilter ? mpTemporalTexB : renderData[kInputChannels[1].name]->asTexture();



        //Bind Internal
        var["gLinearSampler"] = mpLinearSampler;

        mpBlurFilterPass->execute(pRenderContext, mFrameDim.x, mFrameDim.y);
    }

}

void ImageFilter::renderUI(Gui::Widgets& widget)
{
    widget.checkbox("Enable Temporal", mEnableTemporalFilter);
    if (mEnableTemporalFilter) {
        widget.var("Temporal Filter Length", mTemporalFilterIt, 0u, 1000u, 1u);
    }
    widget.dropdown("Blur Mord", kBlurModeList, mBlurFilterMode);
    widget.tooltip("Change Blur mode. The Blur is executed after the temporal filter");
}
