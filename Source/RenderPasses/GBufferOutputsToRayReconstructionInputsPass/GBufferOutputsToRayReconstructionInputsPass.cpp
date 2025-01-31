/***************************************************************************
 # Copyright (c) 2015-23, NVIDIA CORPORATION. All rights reserved.
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
#include "GBufferOutputsToRayReconstructionInputsPass.h"
#include "RenderGraph/RenderPassHelpers.h"
#include "RenderGraph/RenderPassStandardFlags.h"

extern "C" FALCOR_API_EXPORT void registerPlugin(Falcor::PluginRegistry& registry)
{
    registry.registerClass<RenderPass, GBufferOutputsToRayReconstructionInputsPass>();
}

namespace
{
// shader
const std::string kShaderCopyData = "RenderPasses/GBufferOutputsToRayReconstructionInputsPass/CopyData.cs.slang";

const std::string kShaderModel = "6_6"; // Shader model for compute shader

const std::string kInputDiffuseOpacity = "diffuseOpacity";
const std::string kInputSpecRough = "specRough";
const std::string kInputLinearZ = "linearZDerivative";
const std::string kOutputDiffuse = "outDiffuseAlbedo";
const std::string kOutputSpecular = "outSpecularAlbedo";
const std::string kOutputLinearZ = "outLinearZ";
const std::string kOutputRoughness = "outRoughness";

const ChannelList kInputChannels = {
    {kInputDiffuseOpacity, "gDiffuseOpacity", "Diffuse reflection albedo and opacity"},
    {kInputSpecRough, "gSpecRoughness", "Specular reflectance and roughness"},
    {kInputLinearZ, "gInLinearZ", "Linear z (and derivative)"},
};

const ChannelList kOutputChannels = {
    {kOutputDiffuse, "gOutDiffuse", "Diffuse reflection albedo", false, ResourceFormat::RGBA32Float},
    {kOutputSpecular, "gOutSpecular", "Specular reflectance", false, ResourceFormat::RGBA32Float},
    {kOutputLinearZ, "gOutLinearZ", "Linear z", false, ResourceFormat::R32Float},
    {kOutputRoughness, "gOutRoughness", "Roughness", false, ResourceFormat::R32Float},
};

}; // namespace

GBufferOutputsToRayReconstructionInputsPass::GBufferOutputsToRayReconstructionInputsPass(ref<Device> pDevice, const Properties& props)
    : RenderPass(pDevice)
{
}

Properties GBufferOutputsToRayReconstructionInputsPass::getProperties() const
{
    return {};
}

RenderPassReflection GBufferOutputsToRayReconstructionInputsPass::reflect(const CompileData& compileData)
{
    RenderPassReflection reflector;

    // Define our input/output channels.
    addRenderPassInputs(reflector, kInputChannels);
    addRenderPassOutputs(reflector, kOutputChannels, ResourceBindFlags::UnorderedAccess);

    return reflector;
}

void GBufferOutputsToRayReconstructionInputsPass::setScene(RenderContext* pRenderContext, const ref<Scene>& pScene) {
    if (pScene)
        mpScene = pScene;
}

void GBufferOutputsToRayReconstructionInputsPass::execute(RenderContext* pRenderContext, const RenderData& renderData)
{
    //Create Compute Pass
    if (!mpCopyResources)
    {
        Program::Desc desc;
        desc.addShaderLibrary(kShaderCopyData).csEntry("main").setShaderModel(kShaderModel);

        DefineList defines;

        mpCopyResources = ComputePass::create(mpDevice, desc, defines, true);
    }

    FALCOR_ASSERT(mpCopyResources);

    // Dispatch Dims
    const uint2 targetDim = renderData.getDefaultTextureDims();
    FALCOR_ASSERT(targetDim.x > 0 && targetDim.y > 0);

    // Set variables
    auto var = mpCopyResources->getRootVar();

    float near = 0.1f;
    float far = 1000.f;
    if (mpScene)
    {
        near = mpScene->getCamera()->getNearPlane();
        far = mpScene->getCamera()->getFarPlane();
    }
    var["CB"]["gCameraNear"] = near;
    var["CB"]["gCameraFar"] = far;
    // Bind I/O buffers. These needs to be done per-frame as the buffers may change anytime.
    auto bind = [&](const ChannelDesc& desc)
    {
        if (!desc.texname.empty())
        {
            var[desc.texname] = renderData.getTexture(desc.name);
        }
    };

    for (auto channel : kInputChannels)
        bind(channel);
    for (auto channel : kOutputChannels)
        bind(channel);

    // Execute
    mpCopyResources->execute(pRenderContext, uint3(targetDim, 1));
}

void GBufferOutputsToRayReconstructionInputsPass::renderUI(Gui::Widgets& widget)
{
}
