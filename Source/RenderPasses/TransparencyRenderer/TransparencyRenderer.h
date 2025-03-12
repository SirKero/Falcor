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
#include "Rendering/Materials/TexLODTypes.slang"
#include "TransparentShadowMask/TransparentShadowMask.h"

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

    //Possible shadow render methods
    enum class ShadowRenderMethod : uint
    {
        RayTracing = 0,
        AccelShadow = 1,
        LinkedList = 2,
        AccelShadowKBuffer = 3,
        AccelIrregularZ = 4,
        LinkedListIrregularZ = 5
    };

    FALCOR_ENUM_INFO(ShadowRenderMethod,  {
            {ShadowRenderMethod::RayTracing, "RayTracing"},
            {ShadowRenderMethod::AccelIrregularZ, "AccelIrregularZ"},
            {ShadowRenderMethod::AccelShadow, "AccelShadow"},
            {ShadowRenderMethod::AccelShadowKBuffer, "AccelShadowKBuffer"},
            {ShadowRenderMethod::LinkedList, "LinkedList"},
            {ShadowRenderMethod::LinkedListIrregularZ, "LinkedListIrregularZ"},
        }
    );

    //Light sample mode for analytic lights (see EvaluateAnalyticLight.slang)
    enum class LightSampleMode : uint
    {
        Uniform = 0,
        RIS = 1,
        All = 2,
    };

    FALCOR_ENUM_INFO(
        LightSampleMode,
        {
            {LightSampleMode::Uniform, "Uniform"},
            {LightSampleMode::RIS, "RIS"},
            {LightSampleMode::All, "All"},
        }
    );

    //Importance mode for the per pixel adaptive shadow maps (see EvaluateAnalyticLight.slang)
    enum class ImportanceMode : uint
    {
        Opacity = 0,
        Opacity_Thp = 1,
        Thp = 2,
        Thp_Thp = 3,
        Brdf_Thp = 4,
        Brdf_Opacity_Thp = 5,
        Uniform = 6,
    };

    FALCOR_ENUM_INFO(
        ImportanceMode,
        {
            {ImportanceMode::Opacity, "Opacity"},
            {ImportanceMode::Opacity_Thp, "Opacity*Throughput"},
            {ImportanceMode::Thp, "Throughput"},
            {ImportanceMode::Thp_Thp, "ThroughputSquare"},
            {ImportanceMode::Brdf_Thp, "BRDF*Throughput"},
            {ImportanceMode::Brdf_Opacity_Thp, "BRDF*Opacity*Throughput"},
            {ImportanceMode::Uniform, "Unweighted(Uniform)"},
        }
    );

    //Renderers
    enum class CameraRenderMode : uint
    {
        DirectRT = 0,
        DirectRT_Reflections = 1,
        PathTracer = 2
    };

    FALCOR_ENUM_INFO(
        CameraRenderMode,
        {
            {CameraRenderMode::DirectRT, "DirectRT"},
            {CameraRenderMode::DirectRT_Reflections, "DirectRT+RayReflections"},
            {CameraRenderMode::PathTracer, "PathTracer"},
        }
    );

private:
    //Defines for the light evaluation. Can update every frame
    DefineList getLightEvalDefines();

    //Prepare additional textures and buffers
    void prepareResources(RenderContext* pRenderContext, const RenderData& renderData);
    //Evaluate direct light with an Compute Shader
    void evalDirectOpaque(RenderContext* pRenderContext, const RenderData& renderData);
    //Evaluates the transparencies until the first opaque surface
    void evalDirectTransparency(RenderContext* pRenderContext, const RenderData& renderData);
    //Ray Traced Reflections
    void evalRayReflections(RenderContext* pRenderContext, const RenderData& renderData);
    //Path tracing pass
    void evalPathTracer(RenderContext* pRenderContext, const RenderData& renderData);

    // Internal state
    ref<Scene> mpScene;                     ///< Current scene.
    ref<SampleGenerator> mpSampleGenerator; ///< GPU sample generator.
    std::shared_ptr<ShadowMap> mpShadowMap; ///< Possible Opaque shadow map
    std::shared_ptr<TransparentShadowMask> mpShadowMask;    ///< Shadow Mask for Irregular Shadow Maps

    CameraRenderMode mCameraRenderMode = CameraRenderMode::DirectRT;
    ShadowRenderMethod mShadowRenderMethod = ShadowRenderMethod::AccelIrregularZ;
    TexLODMode mRayLodMode = TexLODMode::Mip0;
    bool mEnableTransparencyPassLODMode = true;
    TexLODMode mShadowLodMode = TexLODMode::Mip0;
    uint mSelectedShadowMethod = std::max((int)mShadowRenderMethod - 1, 0);

    std::vector<std::shared_ptr<TransparencyShadowMethod>> mShadowMethods; //Shadow Methods that rely on extra structures (mSelectedShadowMethod - 1)

    // Runtime data Tracer
    uint mFrameCount = 0; ///< Frame count since scene was loaded.
    uint2 mRenderDims = uint2(512);
    float2 mNearFar = float2(1.0f, 60.f);
    LightSampleMode mLightSampleMode = LightSampleMode::RIS;
    bool mOptionsChanged = false;
    bool mEnableOpaqueShadowMaps = false;    //Enable opaque shadow pass
    bool mOpaqueShadowMapModeChanged = false;
    bool mEnableFallbackRayTracedShadows = true; //Some techniques allow for fallback shadows
    bool mShadowUseStochasticRayTracing = false; //Enable stochastic ray tracing for visibility
    bool mUseColorTransparency = false; //Enables transparency with color
    ImportanceMode mImportanceMode = ImportanceMode::Opacity_Thp;
    bool mUseNonOpaqueDepthAndMV = false;

    //Reflections
    float mRayReflectionsRoughnessThreshold = 0.7f; //Threshold for ray reflections

    //Shadow Mask
    bool mIrregularUseShadowMask = false; //TODO creates strange bugs do not use until fixed

    float mSMCascadedSize = 50.f; //Global setting for cascaded size

    //Soft Shadows
    bool mEnableSoftShadows = false;
    float mSoftShadowsPositionRadius = 0.001f;
    float mSoftShadowsDirectionalSpread = 1.f;

    //Path Tracer specific settings
    uint mPTMaxBounces = 256;
    bool mPTUseRussianRoulette = true;

    //Shading Settings
    float mAmbientStrength = 0.25f;
    float mEnvMapStrength = 1.f;

    //Buffer/Textures
    ref<Texture> mpTransparencyThp; //Thp texture for transparency
    ref<Texture> mpReflectionsMask; //Mask where ray reflections should be used

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
    RayTracingPipeline mTransparencyPathTracer; //Pipeline for the path tracer
    RayTracingPipeline mReflectionsPass;
};

FALCOR_ENUM_REGISTER(TransparencyRenderer::ShadowRenderMethod);
FALCOR_ENUM_REGISTER(TransparencyRenderer::LightSampleMode);
FALCOR_ENUM_REGISTER(TransparencyRenderer::CameraRenderMode);
FALCOR_ENUM_REGISTER(TransparencyRenderer::ImportanceMode);
