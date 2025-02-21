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
#include "../TransparencyShadowMethod.h"
#include "Rendering/ShadowMaps/Blur/SMGaussianBlur.h"

class VirtualShadowMap : public TransparencyShadowMethod
{
public:
    virtual ~VirtualShadowMap() = default;

    VirtualShadowMap(ref<Device> pDevice, ref<Scene> pScene);

    /** Generate resources needed to evaluate the Shadow Method
     */
    virtual void generate(RenderContext* pRenderContext, const RenderData& renderData) override;

    /** Returns defines needed for the method
     */
    virtual DefineList getDefines() override;

    /** Set the needed shader data for the method (textures,buffer, etc)
     */
    virtual void setShaderData(const ShaderVar& var) override;

    /** Render UI for the method
     */
    virtual bool renderUI(Gui::Widgets& widget) override;

private:
    void setDirectionalLightSource();
    void genLightMVPs();
    void prepareResources(RenderContext* pRenderContext);
    // Function that generates the profiler passes in case they are not executed this frame
    void dummyProfileGeneration(RenderContext* pRenderContext);
    //Runtime
    uint mFrameCount = 0;

    ref<Texture> mpVirtualShadowMap;
    ref<Texture> mpFeedbackTexture;
    uint mDirectionalLightSourceIndex;
    std::vector<LightMVP> mLightMVPs;
    
    RayTracingPipeline mGenVirtualShadowMapPip;
};
