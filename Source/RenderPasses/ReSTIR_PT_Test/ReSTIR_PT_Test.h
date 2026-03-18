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
#include "Rendering/RTXDI/RTXDI.h"
#include "Rendering/Lights/EmissiveLightSampler.h"
#include "Rendering/Lights/LightBVHSampler.h"
#include "Rendering/Lights/EnvMapSampler.h"

using namespace Falcor;

class ReSTIR_PT_Test : public RenderPass
{
public:
    FALCOR_PLUGIN_CLASS(ReSTIR_PT_Test, "ReSTIR_PT_Test", "Reimplementation for ReSTIR PT.");

    static ref<ReSTIR_PT_Test> create(ref<Device> pDevice, const Properties& props) { return make_ref<ReSTIR_PT_Test>(pDevice, props); }

    ReSTIR_PT_Test(ref<Device> pDevice, const Properties& props);

    virtual Properties getProperties() const override;
    virtual RenderPassReflection reflect(const CompileData& compileData) override;
    virtual void compile(RenderContext* pRenderContext, const CompileData& compileData) override {}
    virtual void execute(RenderContext* pRenderContext, const RenderData& renderData) override;
    virtual void renderUI(Gui::Widgets& widget) override;
    virtual void setScene(RenderContext* pRenderContext, const ref<Scene>& pScene) override;
    virtual bool onMouseEvent(const MouseEvent& mouseEvent) override { return false; }
    virtual bool onKeyEvent(const KeyboardEvent& keyEvent) override { return false; }

private:

    //
    // Functions
    //

    // Resets all Render Passes
    void resetRenderPasses();

    // Initializes the emissive sampler
    void prepareLightingStructure(RenderContext* pRenderContext);

    // Initializes and handles all textures and buffers
    void prepareResources(RenderContext* pRenderContext, const RenderData& renderData);

    // Traces the initial Path
    void tracePathPass(RenderContext* pRenderContext, const RenderData& renderData);

    //Resampling Retrace Path pass
    void resamplingRetracePathPass(RenderContext* pRenderContext, const RenderData& renderData, uint numResamplingIndex);

    //Resampling Pass
    void resamplingPass(RenderContext* pRenderContext, const RenderData& renderData, uint numResamplingIndex);

    //Evaluates the Reservoirs
    void evalReservoirPass(RenderContext* pRenderContest, const RenderData& renderData);

    struct PathLengthSettings
    {
        uint maxPathLength = 10;
        uint deltaBounces = 10;
        uint diffuseBounces = 4;
        uint specularBounces = 4;

        bool renderUI(Gui::Widgets& widget, std::string ident = "##") {
            bool changed = false;
            changed |= widget.var(("Path Length" + ident).c_str(), maxPathLength, 0u, 254u, 1u);
            widget.tooltip("Maximal combined path length");
            changed |= widget.var(("Delta Bounces" + ident).c_str(), deltaBounces, 0u, 254u, 1u);
            widget.tooltip("Maximal delta bounces (reflection + transmission)");
            changed |= widget.var(("Diffuse Bounces" + ident).c_str(), diffuseBounces, 0u, 254u, 1u);
            widget.tooltip("Maximal diffuse bounces  (reflection + transmission)");
            changed |= widget.var(("Specular Bounces" + ident).c_str(), specularBounces, 0u, 254u, 1u);
            widget.tooltip("Maximal specular bounces  (reflection + transmission)");
            return changed;
        }

        uint pack() {
            uint packed = 0;
            packed |= maxPathLength & 0xFF;
            packed |= (deltaBounces & 0xFF) << 8;
            packed |= (diffuseBounces & 0xFF) << 16;
            packed |= (specularBounces & 0xFF) << 24;
            return packed;
        }
    };

    //
    // Pointers
    //
    ref<Scene> mpScene;
    ref<SampleGenerator> mpSampleGenerator;
    std::unique_ptr<RTXDI> mpRTXDI; // Ptr to RTXDI for direct use
    RTXDI::Options mRTXDIOptions;   // Options for RTXDI

    std::unique_ptr<EmissiveLightSampler> mpEmissiveLightSampler; // Light Sampler
    EmissiveLightSamplerType mEmissiveLightSamplerType = EmissiveLightSamplerType::LightBVH;
    LightBVHSampler::Options mLightBVHOptions;
    bool mRebuildLightSampler = false;
    std::unique_ptr<EnvMapSampler> mpEnvMapSampler;

    //
    // Parameters
    //
    uint mFrameCount = 0;
    uint2 mScreenRes = uint2(0, 0);
    bool mResetScreenTex = false;
    bool mOptionsChanged = false;
    uint mRNGGenNumberRenderPasses = 4;   //Needed for the RNG

    PathLengthSettings mPathLengthSettings;
    float3 mNeeLightSelectProb = float3(0.33f); //Light selection probability for NEE samples (Emissive, Analytic, EnvMap)
    float mRoughnessThreshold = 0.20f;  //Threshold for reuse
    float mJacobianDistanceThreshold = 0.0001f; //Distance Threshold
    bool mEvalDeltaPDFs = false; //If true uses correct delta pdfs for resampling (pdf = 0)

    bool mEnableResampling = true;
    bool mRetraceRCPath = true; //Traces the whole path for reconnection surfaces
    bool mSeperateRetracePass = true; //If false, traces both random replay paths in one shader
    uint mConfidenceCap = 20;
    uint mSpatialSamples = 1;
    float mSpatialSampleRadius = 20.f;

    bool mResamplingValid = false;

    bool mClearDebug = false;
    //
    // Resources
    //
    ref<Buffer> mpReservoirPT[2];   //Path Reservoir
    ref<Buffer> mpRetraceSurfaceBuffer[2];  //Retrace Surface Data Buffer
    ref<Texture> mpRetraceRCSurfaceThpTexture[2]; //For retracing the throughput for rc surfaces
    ref<Texture> mpViewPrev;        //Previous frame View Vector
    ref<Texture> mpVBufferPrev;     //Previous frame VBuffer


    //
    // Render Passes/Programs
    //
    struct RayTraceProgramHelper
    {
        ref<RtProgram> pProgram;
        ref<RtBindingTable> pBindingTable;
        ref<RtProgramVars> pVars;

        static const RayTraceProgramHelper create()
        {
            RayTraceProgramHelper r;
            r.pProgram = nullptr;
            r.pBindingTable = nullptr;
            r.pVars = nullptr;
            return r;
        }

        void initProgramVars(ref<Device> pDevice, ref<Scene> pScene, ref<SampleGenerator> pSampleGenerator);
    };

    RayTraceProgramHelper mTracePathPass; //Traces the initial Paths (1SPP Path Tracer)
    RayTraceProgramHelper mResampleRetracePathPass;    //Resampling
    ref<ComputePass> mpResamplePass;                 // Resampling
    ref<ComputePass> mpEvalReservoirPass;   //Evaluates the reservoirs
};


