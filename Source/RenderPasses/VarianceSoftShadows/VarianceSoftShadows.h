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

using namespace Falcor;

class VarianceSoftShadows : public RenderPass
{
public:
    FALCOR_PLUGIN_CLASS(VarianceSoftShadows, "VarianceSoftShadows", "Insert pass description here.");

    static ref<VarianceSoftShadows> create(ref<Device> pDevice, const Properties& props) { return make_ref<VarianceSoftShadows>(pDevice, props); }

    VarianceSoftShadows(ref<Device> pDevice, const Properties& props);

    virtual Properties getProperties() const override;
    virtual RenderPassReflection reflect(const CompileData& compileData) override;
    virtual void compile(RenderContext* pRenderContext, const CompileData& compileData) override {}
    virtual void execute(RenderContext* pRenderContext, const RenderData& renderData) override;
    virtual void renderUI(Gui::Widgets& widget) override;
    virtual void setScene(RenderContext* pRenderContext, const ref<Scene>& pScene) override;
    virtual bool onMouseEvent(const MouseEvent& mouseEvent) override { return false; }
    virtual bool onKeyEvent(const KeyboardEvent& keyEvent) override { return false; }

private:
    struct ShadowMVP
    {
        float4x4 view;
        float4x4 projection;
        float4x4 viewProjection;
    };

    //Resets all render passes
    void resetRenderPasses();
    //Updates light count
    void updateLightCount(const std::vector<ref<Light>>& pLights);
    //Prepares textures and buffers needed for this render pass
    void prepareResources(RenderContext* pRenderContext, const RenderData& renderData);
    //Cascaded MVP
    void calcCascadedMVP();
    //Renders all shadow maps
    void generateShadowMaps(RenderContext* pRenderContext, const RenderData& renderData);
    //Creates the Summed Area Table for the Shadow Map
    void createShadowMapSAT(RenderContext* pRenderContext, const RenderData& renderData);
    //Generates the hierarchical shadow maps
    void createHierarchicalShadowMaps(RenderContext* pRenderContext, const RenderData& renderData);
    //Shades the surface using the VBuffer hit
    void shadeSurfacePass(RenderContext* pRenderContext, const RenderData& renderData);

    // Internal state
    ref<Scene> mpScene;                     ///< Current scene.
    ref<SampleGenerator> mpSampleGenerator; ///< GPU sample generator.
    ref<Sampler> mpShadowSampler;           ///< Linear Sampler
    uint mFrameCount = 0;
    bool mResetRenderPasses = false;        ///< Certain changes will trigger complete shader recompilation

    float mAmbientFactor = 0.01f; //<Ambient light factor
    float mEnvMapFactor = 0.3f;   //< Env Map factor
    float mEmissiveFactor = 2.f;  //< Emissive Factor

    float mSpotLightSize = 1.0f; // Approximated light size
    float mSunAngularDiameter = 0.553f; //For Directional Light

    //Shadow Maps settings
    bool mRebuildShadowMaps = true;
    uint mShadowMapResolution = 2048;
    float2 mNearFar = float2(5.f, 60.f);
    uint mNumberShadowMaps = 1; //Number of shadow map textures
    int mDirectionalIndex = -1;    //Index for the directional light
    uint mNumSpotLights = 0;    //Number of spotlights
    uint mSATMantissaBits = 23; //Mantissa Bits for the SAT
    uint mSATMaxSearchRadius = 12; //Max Search radius

    //Cascaded
    uint mCascadedLevels = 4; // Number of cascaded levels
    float mCascadedCameraMaxFar = 100000000.f;
    std::vector<float> mCascadedDepthRanges;
    std::vector<float> mCascadedZSlices;
    std::vector<float> mCascadedLevelRanges;
    bool mCascadedUseCustomDepthRange = false;
    float2 mCascadedReduceMinMax = float2(0);
    float mMinVariance = 1e-2f;

    //Frustum Culling
    bool mUseFrustumCulling = true;
    std::vector<ref<FrustumCulling>> mFrustumCulling;

    //Shadow Map internal
    std::vector<ShadowMVP> mShadowMVP;

    //Textures
    ref<Texture> mShadowMapRasterDepth;     //Depth texture for the raster pass
    std::vector<ref<Texture>> mShadowMaps;  //Includes all shadow maps (Spot -> Cascaded)

    std::vector<ref<Texture>> mSATVarianceShadowMaps;   //Summed Area Table Variance Shadow Maps
    std::vector<ref<Texture>> mHierarchicalShadowMaps;  //HierarchicalShadowMaps


    // Render Passes
    struct RasterizerPass
    {
        ref<GraphicsState> pState = nullptr;
        ref<GraphicsProgram> pProgram = nullptr;
        ref<GraphicsVars> pVars = nullptr;
        ref<Fbo> pFbo = nullptr;

        void reset()
        {
            pState.reset();
            pProgram.reset();
            pVars.reset();
            pFbo.reset();
        }
    };

    RasterizerPass mGenerateShadowMapPass;
    ref<ComputePass> mpCreateSATPass[2]; // Horizonal and Vertical
    ref<ComputePass> mpCreateHierarchicalShadowMapPass;
    ref<ComputePass> mpShadePass;

};
