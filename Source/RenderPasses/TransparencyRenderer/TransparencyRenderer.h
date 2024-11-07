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

#include "Rendering/ShadowMaps/ShadowMap.h"
#include "TransparencyShadowMethod.h"

using namespace Falcor;

class TransparencyRenderer : public RenderPass
{
public:
    FALCOR_PLUGIN_CLASS(TransparencyRenderer, "TransparencyRenderer", "Renderer for scenes with Transparencies");

    static ref<TransparencyRenderer> create(ref<Device> pDevice, const Properties& props) { return make_ref<TransparencyRenderer>(pDevice, props); }

    TransparencyRenderer(ref<Device> pDevice, const Properties& props);

    virtual Properties getProperties() const override;
    virtual RenderPassReflection reflect(const CompileData& compileData) override;
    virtual void compile(RenderContext* pRenderContext, const CompileData& compileData) override {}
    virtual void execute(RenderContext* pRenderContext, const RenderData& renderData) override;
    virtual void renderUI(Gui::Widgets& widget) override;
    virtual void setScene(RenderContext* pRenderContext, const ref<Scene>& pScene) override;
    virtual bool onMouseEvent(const MouseEvent& mouseEvent) override { return false; }
    virtual bool onKeyEvent(const KeyboardEvent& keyEvent) override { return false; }

    enum class ShadowRenderMethod : uint
    {
        RayTracing = 0,
        AccelShadow = 1,
        LinkedList = 2,
        AccelShadowKBuffer = 3
    };

    FALCOR_ENUM_INFO(ShadowRenderMethod,  {
            {ShadowRenderMethod::RayTracing, "RayTracing"},
            {ShadowRenderMethod::AccelShadow, "AccelShadow"},
            {ShadowRenderMethod::LinkedList, "LinkedList"},
            {ShadowRenderMethod::AccelShadowKBuffer, "AccelShadowKBuffer"},
        }
    );

    enum class LightSampleMode : uint
    {
        Uniform = 0,
        RIS = 1,
    };

    FALCOR_ENUM_INFO(
        LightSampleMode,
        {
            {LightSampleMode::Uniform, "Uniform"},
            {LightSampleMode::RIS, "RIS"},
        }
    );

private:
    //Defines for the light evaluation. Can update every frame
    DefineList getLightEvalDefines();

    //Evaluate direct light with an Compute Shader
    void evalDirect(RenderContext* pRenderContext, const RenderData& renderData);
    //Evaluates the transparencies unitl the first opaque surface
    void evalDirectTransparency(RenderContext* pRenderContext, const RenderData& renderData);

    // Internal state
    ref<Scene> mpScene;                     ///< Current scene.
    ref<SampleGenerator> mpSampleGenerator; ///< GPU sample generator.
    std::shared_ptr<ShadowMap> mpShadowMap; ///< Possible Opaque shadow map

    ShadowRenderMethod mShadowRenderMethod = ShadowRenderMethod::RayTracing;
    uint mSelectedShadowMethod = 0;

    std::vector<std::shared_ptr<TransparencyShadowMethod>> mShadowMethods; //Shadow Methods that rely on extra structures (mSelectedShadowMethod - 1)

    // Runtime data Tracer
    uint mFrameCount = 0; ///< Frame count since scene was loaded.
    LightSampleMode mLightSampleMode = LightSampleMode::RIS;
    bool mOptionsChanged = false;
    bool mEnableOpaqueShadowMaps = true;    //Enable opaque shadow pass

    //Passes
    // Pipelines / Programms
    struct RayTracingPipeline
    {
        ref<RtProgram> pProgram;
        ref<RtBindingTable> pBindingTable;
        ref<RtProgramVars> pVars;

        void resetPip()
        {
            pProgram.reset();
            pBindingTable.reset();
            pVars.reset();
        }
    };

    RayTracingPipeline mEvalTransparencyDirectRay; // Ray Tracing pass for evaluating the Transparencies along the primary ray
    ref<ComputePass> mpEvalDirectPass; //Compute Pass for direct light
    
};

FALCOR_ENUM_REGISTER(TransparencyRenderer::ShadowRenderMethod);
FALCOR_ENUM_REGISTER(TransparencyRenderer::LightSampleMode);
