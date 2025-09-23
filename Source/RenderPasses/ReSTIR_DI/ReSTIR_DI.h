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
#pragma once
#include "Falcor.h"
#include "RenderGraph/RenderPass.h"

#include "Rendering/Lights/EmissiveLightSampler.h"
#include "Rendering/Lights/LightBVHSampler.h"

using namespace Falcor;

class ReSTIR_DI : public RenderPass
{
public:
    FALCOR_PLUGIN_CLASS(ReSTIR_DI, "ReSTIR_DI", "ReSTIR DI");

    static ref<ReSTIR_DI> create(ref<Device> pDevice, const Properties& props) { return make_ref<ReSTIR_DI>(pDevice, props); }

    ReSTIR_DI(ref<Device> pDevice, const Properties& props);

    virtual Properties getProperties() const override;
    virtual RenderPassReflection reflect(const CompileData& compileData) override;
    virtual void compile(RenderContext* pRenderContext, const CompileData& compileData) override {}
    virtual void execute(RenderContext* pRenderContext, const RenderData& renderData) override;
    virtual void renderUI(Gui::Widgets& widget) override;
    virtual void setScene(RenderContext* pRenderContext, const ref<Scene>& pScene) override;
    virtual bool onMouseEvent(const MouseEvent& mouseEvent) override { return false; }
    virtual bool onKeyEvent(const KeyboardEvent& keyEvent) override { return false; }

private:

    // Initializes the emissive sampler
    void prepareLightingStructure(RenderContext* pRenderContext);

    // Initializes and handles all textures and buffers
    void prepareResources(RenderContext* pRenderContext, const RenderData& renderData);

    //Generate initial samples
    void generateInitialSamplesPass(RenderContext* pRenderContext, const RenderData& renderData);

    // Generate initial samples
    void resamplePass(RenderContext* pRenderContext, const RenderData& renderData);
    
    // Generate initial samples
    void finalizeSamplePass(RenderContext* pRenderContext, const RenderData& renderData);

    //Reset Render Passes
    void resetRenderPasses();

    //
    // Pointers
    //
    ref<Scene> mpScene;                     // Scene Pointer
    ref<SampleGenerator> mpSampleGenerator; // GPU Sample Gen
    std::unique_ptr<EmissiveLightSampler> mpEmissiveLightSampler; // Light Sampler
    EmissiveLightSamplerType mEmissiveLightSamplerType = EmissiveLightSamplerType::LightBVH;
    LightBVHSampler::Options mLightBVHOptions;
    bool mRebuildLightSampler = true;

    //
    // Parameters
    //
    uint mFrameCount = 0;
    uint2 mScreenRes = uint2(0, 0);
    bool mResetScreenTex = false;
    bool mOptionsChanged = false;

    uint mNumEmissiveSamples = 1;
    uint mNumBSDFSamples = 1;

    ref<Buffer> mpReservoir[2];

    ref<ComputePass> mpInitialSamplesPass;           // Generate initial samples
    ref<ComputePass> mpResamplePass;                 // Resampling
    ref<ComputePass> mpEvaluateReservoirsPass;       // Evaluate Reservoirs
};
