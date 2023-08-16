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
#include "Core/Macros.h"
#include "Core/Enum.h"
#include "Core/State/GraphicsState.h"
#include "Core/Program/ComputeProgram.h"
#include "Core/Program/GraphicsProgram.h"
#include "Core/Program/Program.h"
#include "Core/Program/ProgramReflection.h"
#include "Core/Program/ProgramVars.h"
#include "Core/Program/ProgramVersion.h"
#include "Core/Program/RtProgram.h"
#include "Utils/Properties.h"
#include "Utils/Debug/PixelDebug.h"
#include "Scene/Scene.h"

#include <memory>
#include <type_traits>
#include <vector>

/*
    Wrapper Module for Shadow Maps, which allow ShadowMaps to be easily integrated into every Render Pass.
*/
namespace Falcor
{
class RenderContext;

class FALCOR_API ShadowMap
{
public:
    ShadowMap(ref<Device> device, ref<Scene> scene);

    // Renders and updates the shadow maps if necessary
    bool update(RenderContext* pRenderContext);

    void renderUI(Gui::Widgets& widget);

    // Returns a define List with all the defines. Need to be called once per frame to update defines
    DefineList getDefines() const;
    // Sets Shader data
    void setShaderData();
    // Gets the parameter block needed for shader usage
    ref<ParameterBlock> getParameterBlock() const { return mpShadowMapParameterBlock; }

    // Getter
    std::vector<ref<Texture>>& getShadowMapsCube() { return mpShadowMapsCube; }
    std::vector<ref<Texture>>& getShadowMaps() { return mpShadowMaps; }
    ref<Buffer> getViewProjectionBuffer() { return mpVPMatrixBuffer; }
    ref<Buffer> getLightMapBuffer() { return mpLightMapping; }
    ref<Sampler> getSampler() { return mpShadowSampler; }
    float getFarPlane() { return mFar; }
    float getNearPlane() { return mNear; }
    uint getResolution() { return mShadowMapSize; }
    float3 getSceneCenter() { return mSceneCenter; }
    float getDirectionalOffset() { return mDirLightPosOffset; }
    uint getCountShadowMapsCube() const { return mpShadowMapsCube.size(); }
    uint getCountShadowMaps() const { return mpShadowMaps.size(); }

private:
    struct ShaderParameters
    {
        float4x4 viewProjectionMatrix = float4x4();

        float3 lightPosition = float3(0, 0, 0);
        float farPlane = 30.f;
    };

    bool isPointLight(const ref<Light> light);
    void prepareShadowMapBuffers();
    void prepareRasterProgramms();
    void prepareProgramms();
    void setSMShaderVars(ShaderVar& var, ShaderParameters& params);
    void setProjection(float near = -1.f, float far = -1.f);

    DefineList getDefinesShadowMapGenPass() const;

    void renderCubeEachFace(uint index, ref<Light> light, RenderContext* pRenderContext);
    float4x4 getProjViewForCubeFace(uint face, const LightData& lightData, bool useOrtho = false);

    ref<Device> mpDevice;
    ref<Scene> mpScene;
    ref<Fbo> mpFbo;
    ref<Fbo> mpFboCube;

    uint mShadowMapSize = 1024;
    uint mShadowMapSizeCube = 512;
    ResourceFormat mShadowMapFormat = ResourceFormat::D32Float;
    RasterizerState::CullMode mCullMode = RasterizerState::CullMode::Front;

    // Settings
    float4x4 mProjectionMatrix = float4x4();
    float4x4 mOrthoMatrix = float4x4();
    float mNear = 0.01f;
    float mFar = 30.f;
    float mDirLightPosOffset = 400.f;
    float3 mSceneCenter = float3(0);
    bool mUsePCF = false;
    bool mUsePoissonDisc = false;
    float mShadowMapWorldAcneBias = 0.0f;
    bool mUseAlphaTest = true;
    float gPoissonDiscRad = 0.15f;

    bool mApplyUiSettings = false;
    bool mAlwaysRenderSM = false;
    bool mFirstFrame = true;
    bool mResetShadowMapBuffers = false;
    bool mShadowResChanged = false;
    bool mRasterDefinesChanged = false;
    std::vector<bool> mIsCubeSM; // Vector for fast checks if the type is still correct

    std::vector<float4x4> mSpotDirViewProjMat;

    std::vector<ref<Texture>> mpShadowMapsCube; // Cube Shadow Maps (Point Lights)
    std::vector<ref<Texture>> mpShadowMaps;     // 2D Texture Shadow Maps (Spot + Directional Light)
    ref<Buffer> mpLightMapping;
    ref<Buffer> mpVPMatrixBuffer;
    ref<Buffer> mpVPMatrixStangingBuffer;
    ref<Sampler> mpShadowSampler;
    ref<Texture> mpDepth;
    ref<Texture> mpTestTex;

    ref<ComputePass> mpReflectTypes;               // Dummy pass needed to create the parameter block
    ref<ParameterBlock> mpShadowMapParameterBlock; // Parameter Block

    struct RasterizerPass
    {
        ref<GraphicsState> pState = nullptr;
        ref<GraphicsProgram> pProgram = nullptr;
        ref<GraphicsVars> pVars = nullptr;

        void reset()
        {
            pState.reset();
            pProgram.reset();
            pVars.reset();
        }
    };

    RasterizerPass mShadowCubePass;
    RasterizerPass mShadowMiscPass;
};

}