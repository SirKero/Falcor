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
#include "../TransparencyShadowMethod.h"
#include "Rendering/Materials/TexLODTypes.slang"

using namespace Falcor;

class TransparentShadowMask
{
public:
    virtual ~TransparentShadowMask() = default;
    TransparentShadowMask(ref<Device> pDevice, ref<Scene> pScene);

    /** Generate resources needed to evaluate the Shadow Method (e.g. Shadow Map)
    * Should be called every frame and needs to be called before using any resources from that pass
    */
    void generate(RenderContext* pRenderContext, const RenderData& renderData, const TransparencyShadowMethod* pTransparencyShadowMethod, ref<SampleGenerator> pSampleGenerator);

    //Get the layered mask texture
    ref<Texture> getMask() { return mpTransparentShadowMask; }

    //Get layered mask shadow map
    ref<Buffer> getMaskShadowMap() { return mpMaskOpaqueShadowMap; }

    //Set blacklist status
    void enableBlacklist(bool enable) { mEnableBlacklistWithMaterialFlag = enable; }

private:
    void generateTransparencyMask(
        RenderContext* pRenderContext,
        const RenderData& renderData,
        const TransparencyShadowMethod* pTransparencyShadowMethod
    );

    void generateOpaqueMaskShadowMap(
        RenderContext* pRenderContext,
        const RenderData& renderData,
        const TransparencyShadowMethod* pTransparencyShadowMethod,
        ref<SampleGenerator> pSampleGenerator
    );

    //Constants
    const uint kMaxTemporal = 8;    //Max temporal accumulation (8bit)

    //Runtime
    ref<Device> mpDevice;
    ref<Scene> mpScene;

    uint mTemporalCounter = 0;  //< Current frame counter for the temporal mask 
    uint mFrameCount = 0;

    //Options
    bool mEnableOpaqueMaskShadowMaps = true;    //< Enables the opaque mask shadow map pass
    bool mEnableBlacklistWithMaterialFlag = false;  //< Enables blacklist with material flag (castShadows)

    //Buffer and Textures
    ref<Texture> mpTransparentShadowMaskRaster; //2D Array containing the masks for all shadow maps
    ref<Texture> mpTransparentShadowMask; //Containing the temporally accumulated shadow masks
    ref<Buffer> mpMaskOpaqueShadowMap;         //Importance shadow map with only opaque objects
    ref<Sampler> mpMaskSampler;             //Mask sampler for the gen pass
    // Pipelines / Programms
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

    RasterPipeline mGenerateMaskPip;
    ref<ComputePass> mpTemporalAccumulateMaskPass;
         
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
    } mGenerateMaskShadowMapRayPass;
};
