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
#include "CompositeReStirNRD.h"

const RenderPass::Info CompositeReStirNRD::kInfo{ "CompositeReStirNRD", "Composite for the Photon Mapping ReStir Algorithm including NRD. Adds ReSTIR and VPLReSTIR then multiplies it with the throughput" };

namespace {
    const std::string kShaderFile("RenderPasses/CompositeReStirNRD/CompositeReStirNRD.cs.slang");

    //Inputs
    const ChannelList kInputChannels = {
       { "PhotonReStirDiffuse",     "gPhotonReStirDiffuse",     "Diffuse for Photon ReSTIR",                false },
       { "PhotonReStirSpecular",    "gPhotonReStirSpecular",    "Specular for Photon ReSTIR",               false },
       { "ReStirDiffuse",           "gReStirDiffuse",           "Diffuse for ReSTIR",                       false },
       { "ReStirSpecular",          "gReStirSpecular",          "Specular for ReSTIR",                      false },
       { "throughput",              "gThp",                     "Throughput for transparent materials",     false },
       { "NRDMask",                 "gNRDMask",                 "Info for which part that pass is",         true , ResourceFormat::R8Uint },
       { "DeltaReflectionReflectance",                 "gDeltaReflectionReflectance",                 "Reflectance for delta reflection",         true },
       { "TransmissionReflectance",                 "gTransmissionReflectance",                 "Reflectance for delta transmission",         true },
       { "DeltaReflectionEmission",                 "gDeltaReflectionEmission",                 "Emission for delta reflection",         true },
       { "TransmissionEmission",                 "gTransmissionEmission",                 "Emission for delta transmission",         true },

    };

    const ChannelList kOutputChannels = {
       { "NRDDiffuseRadianceHitDistance",               "gNRDDiffuseRadianceHitDistance",               "NRD Diffuse Reflectance",  false , ResourceFormat::RGBA32Float },
       { "NRDSpecularRadianceHitDistance",              "gNRDSpecularRadianceHitDistance",              "NRD Specular Reflectance", false , ResourceFormat::RGBA32Float },
       { "NRDDeltaReflectionRadianceHitDistance",       "gNRDDeltaReflectionRadianceHitDistance",       "NRD Delta Reflectance",    false , ResourceFormat::RGBA32Float },
       { "NRDDeltaTransmissionRadianceHitDistance",     "gNRDDeltaTransmissionRadianceHitDistance",     "NRD Delta Transmission",   false , ResourceFormat::RGBA32Float },

    };

    //Dictonary names
    const std::string kEnableReStir = "enableReStir";
    const std::string kEnablePhotonReStir = "enablePhotonReStir";
    const std::string kEnableThroughput = "enableThroughput";
    const std::string kEnableTranmissionEmission = "enableTranmissionEmission";
    const std::string kEnableDeltaReflectionEmission = "enableDeltaReflectionEmission";
    const std::string kOutputFormat = "outputFormat";
}

// Don't remove this. it's required for hot-reload to function properly
extern "C" FALCOR_API_EXPORT const char* getProjDir()
{
    return PROJECT_DIR;
}

extern "C" FALCOR_API_EXPORT void getPasses(Falcor::RenderPassLibrary & lib)
{
    lib.registerPass(CompositeReStirNRD::kInfo, CompositeReStirNRD::create);
}

CompositeReStirNRD::SharedPtr CompositeReStirNRD::create(RenderContext* pRenderContext, const Dictionary& dict)
{
    SharedPtr pPass = SharedPtr(new CompositeReStirNRD(dict));
    return pPass;
}

CompositeReStirNRD::CompositeReStirNRD(const Dictionary dict)
    : RenderPass(kInfo)
{
    //Parse Dictionary
    for (const auto& [key, value] : dict) {
        if (key == kEnableReStir) mEnableReStir = value;
        else if (key == kEnablePhotonReStir) mEnablePhotonReStir = value;
        else if (key == kEnableThroughput) mEnableThroughput = value;
        else if (key == kOutputFormat) mOutputFormat = value;
        else if (key == kEnableTranmissionEmission) mUseTransmissiveEmission = value;
        else if (key == kEnableDeltaReflectionEmission) mUseReflectiveEmission = value;
        else logWarning("Unknown field '{}' in CompositeReStirVpl pass dictionary.", key);
    }

    // Create resources.
    mpCompositeReStirNDRPass = ComputePass::create(kShaderFile, "main", Program::DefineList(), false);
}

Dictionary CompositeReStirNRD::getScriptingDictionary()
{
    Dictionary dict;

    dict[kEnableReStir] = mEnableReStir;
    dict[kEnablePhotonReStir] = mEnablePhotonReStir;
    dict[kEnableThroughput] = mEnableThroughput;
    dict[kEnableTranmissionEmission] = mUseTransmissiveEmission;
    dict[kEnableDeltaReflectionEmission] = mUseReflectiveEmission;
    if (mOutputFormat != ResourceFormat::Unknown) dict[kOutputFormat] = mOutputFormat;
    return Dictionary();
}

RenderPassReflection CompositeReStirNRD::reflect(const CompileData& compileData)
{
    // Define the required resources here
    RenderPassReflection reflector;
    //Inputs
    addRenderPassInputs(reflector, kInputChannels);
    //Outputs
    addRenderPassOutputs(reflector, kOutputChannels);

    return reflector;
}

void CompositeReStirNRD::compile(RenderContext* pRenderContext, const CompileData& compileData)
{
    mFrameDim = compileData.defaultTexDims;
}

void CompositeReStirNRD::execute(RenderContext* pRenderContext, const RenderData& renderData)
{
    Program::DefineList defineList = getValidResourceDefines(kInputChannels, renderData);

    if (!mUseTransmissiveEmission) defineList["is_valid_gTransmissionEmission"] = "0";
    if (!mUseReflectiveEmission) defineList["is_valid_gDeltaReflectionEmission"] = "0";

    if (mpCompositeReStirNDRPass->getProgram()->addDefines(defineList))
    {
        mpCompositeReStirNDRPass->setVars(nullptr);
    }

    //BindResources
    auto var = mpCompositeReStirNDRPass->getRootVar();
    var["CB"]["frameDim"] = mFrameDim;
    var["CB"]["gEnableReStir"] = mEnableReStir;
    var["CB"]["gEnablePhotonReStir"] = mEnablePhotonReStir;
    var["CB"]["gEnableThroughput"] = mEnableThroughput;

    // Bind Output Textures. These needs to be done per-frame as the buffers may change anytime.
    auto bindAsTex = [&](const ChannelDesc& desc)
    {
        if (!desc.texname.empty())
        {
            var[desc.texname] = renderData[desc.name]->asTexture();
        }
    };
    for (auto& input : kInputChannels) bindAsTex(input);
    for (auto& output : kOutputChannels) bindAsTex(output);

    mpCompositeReStirNDRPass->execute(pRenderContext, mFrameDim.x, mFrameDim.y);
}

void CompositeReStirNRD::renderUI(Gui::Widgets& widget)
{
    widget.text("Pass for combining all ReStirVpls passes");
    widget.checkbox("Enable ReStir", mEnableReStir);
    widget.checkbox("Enable Photon ReStir", mEnablePhotonReStir);
    widget.checkbox("Enable Throughput", mEnableThroughput);
    widget.tooltip("If disabled, thp is set to 1");
    widget.checkbox("Enable Transmissive Emission", mUseTransmissiveEmission);
    widget.checkbox("Enable Delta Reflection Emission", mUseReflectiveEmission);
}
