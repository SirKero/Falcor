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
#include "Utils/Sampling/SampleGenerator.h"
#include "Rendering/ShadowMaps/ShadowMap.h"
#include "Rendering/Materials/TexLODTypes.slang"  // Using the enum with Mip0, RayCones, etc

using namespace Falcor;

/** Minimal path tracer.

    This pass implements a minimal brute-force path tracer. It does purposely
    not use any importance sampling or other variance reduction techniques.
    The output is unbiased/consistent ground truth images, against which other
    renderers can be validated.

    Note that transmission and nested dielectrics are not yet supported.
*/
class MinimalPathTracerShadowMap : public RenderPass
{
public:
    FALCOR_PLUGIN_CLASS(MinimalPathTracerShadowMap, "MinimalPathTracerShadowMap", "Minimal path tracer that can use ShadowMaps.");

    static ref<MinimalPathTracerShadowMap> create(ref<Device> pDevice, const Properties& props) { return make_ref<MinimalPathTracerShadowMap>(pDevice, props); }

    MinimalPathTracerShadowMap(ref<Device> pDevice, const Properties& props);

    virtual Properties getProperties() const override;
    virtual RenderPassReflection reflect(const CompileData& compileData) override;
    virtual void execute(RenderContext* pRenderContext, const RenderData& renderData) override;
    virtual void renderUI(Gui::Widgets& widget) override;
    virtual void setScene(RenderContext* pRenderContext, const ref<Scene>& pScene) override;
    virtual bool onMouseEvent(const MouseEvent& mouseEvent) override { return false; }
    virtual bool onKeyEvent(const KeyboardEvent& keyEvent) override { return false; }

private:
    void parseProperties(const Properties& props);
    void prepareVars();
    void handleDebugOracleTexture(ShaderVar& var, const RenderData& renderData);
    void setTexLODMode(TexLODMode lodMode);
    void setRayConeMode(RayConeMode rayConeMode) { mRayConeMode = rayConeMode; }

    // Internal state
    ref<Scene>                  mpScene;                        ///< Current scene.
    ref<SampleGenerator>        mpSampleGenerator;              ///< GPU sample generator.
    std::unique_ptr<ShadowMap>  mpShadowMap;                    ///< Shadow Map

    // Configuration
    uint                        mMaxBounces = 3;                ///< Max number of indirect bounces (0 = none).
    bool                        mComputeDirect = true;          ///< Compute direct illumination (otherwise indirect only).
    bool                        mUseImportanceSampling = true;  ///< Use importance sampling for materials.
    bool                        mUseEmissiveLight = true;       ///< Disables Emissive Light
    bool                        mUseAlphaTest = true;           ///< Alpha Test
   
    uint                        mUseShadowMapBounce = 0;        ///< Use the Shadow Map starting at bounce x. If mMaxBounces + 1 it is disabled
    bool                        mOracleDebugShowFunc = false;   ///< Shows the Oracle function
    uint                        mOracleDebugFuncLevel = 0;      ///< Oracle function level that is shown
    int                         mOracleDebugLightIdx = -1;                               ///< Only shows the contributions of selected light
    TexLODMode                  mTexLODMode = TexLODMode::Mip0;  //< Which texture LOD mode to use.
    RayConeMode                 mRayConeMode = RayConeMode::Combo;  //< Which variant of ray cones to use.

    // Runtime data
    uint                        mFrameCount = 0;                ///< Frame count since scene was loaded.
    bool                        mOptionsChanged = false;

    //Debug Texture
    std::vector<ref<Texture>> mpOracleDebug;

    // Ray tracing program.
    struct
    {
        ref<RtProgram> pProgram;
        ref<RtBindingTable> pBindingTable;
        ref<RtProgramVars> pVars;
    } mTracer;
};