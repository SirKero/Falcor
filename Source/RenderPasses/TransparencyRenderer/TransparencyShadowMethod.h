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

using namespace Falcor;

class TransparencyShadowMethod
{
public:
    virtual ~TransparencyShadowMethod() = default;

    /** Generate resources needed to evaluate the Shadow Method (e.g. Shadow Map)
    * Should be called every frame and needs to be called before using any resources from that pass
    */
    virtual void generate(RenderContext* pRenderContext, const RenderData& renderData) {}

    /** Returns defines needed to evaluate the method
     */
    virtual DefineList getDefines();

    /** Set the needed shader data for the method (textures,buffer, etc)
    */
    virtual void setShaderData(const ShaderVar& var) {}

    /** Render UI for the method
    */
    virtual bool renderUI(Gui::Widgets& widget);

    /** Optional Debug pass.
        It should be called every frame, so if debug is disabled, the function shoud return before doing any computationally expensive work.
    */
    virtual void debugPass(RenderContext* pRenderContext, const RenderData& renderData, ref<Texture> debugOut = nullptr, ref<Texture> colorOut = nullptr) {}

    /* Set enable status for the opaque shadow map
    */
    void enableOpaqueShadowMap(bool enable = true) { mOpaqueShadowMapEnabled = enable; }

protected:
    TransparencyShadowMethod(ref<Device> pDevice, ref<Scene> pScene) : mpDevice(pDevice), mpScene(pScene) {}

    //Function to update the Shadow Map Matrices
    virtual void updateSMMatrices(RenderContext* pRenderContext, bool rebuild = false);

    //Light MVP
    struct LightMVP
    {
        float3 pos = float3(0);
        uint _pad = 0;
        float4x4 view = float4x4();
        float4x4 projection = float4x4();
        float4x4 viewProjection = float4x4();
        float4x4 invViewProjection = float4x4();
        float4x4 invProjection = float4x4();
        float4x4 invView = float4x4();

        void calculate(ref<Light> light, float2 nearFar);
    };

    ref<Device> mpDevice;
    ref<Scene> mpScene;
    bool mOpaqueShadowMapEnabled = false;

    uint2 mResolution = uint2(512);
    float2 mNearFar = float2(0.1f, 60.f);
    bool mResolutionChanged = false;         //True if the resolution changed

    std::vector<LightMVP> mShadowMapMVP;    //Collection of all possible view/projection matrices from each light

    //Pipelines / Programms
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

    struct RasterPipeline
    {
        ref<GraphicsState> pState;
        ref<GraphicsProgram> pProgram;
        ref<GraphicsVars> pVars;
        ref<Fbo> pFBO;

        void resetPip()
        {
            pState.reset();
            pProgram.reset();
            pVars.reset();
            pFBO.reset();
        }
    };

};
