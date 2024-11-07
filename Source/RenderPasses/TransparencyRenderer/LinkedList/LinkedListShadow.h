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

class LinkedListShadow : public TransparencyShadowMethod
{
public:
    virtual ~LinkedListShadow() = default;

    LinkedListShadow(ref<Device> pDevice, ref<Scene> pScene);

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

    /** Optional Debug pass
     */
    //virtual void debugPass(RenderContext* pRenderContext, const RenderData& renderData, ref<Texture> debugOut) override;

private:
    void prepareResources(RenderContext* pRenderContext);

    //Runtime
    uint mFrameCount = 0;

    float mDepthBias = 1e-6f;
    float mNormalDepthBias = 1e-3f;
    RayFlags mLLRayFlags = RayFlags::None;

    //Linked List
    std::vector<ref<Buffer>> mpLinkedList;
    std::vector<ref<Buffer>> mpLinkedListNeighbors;
    std::vector<ref<Buffer>> mpLinkedListArray;
    std::vector<ref<Texture>> mpLinkedListArrayOffsets;
    bool mUseLinkedListPcf = false;
    bool mUseLinkedListArray = false;
    uint32_t mLinkedElementCount = mResolution.x * mResolution.y * 16; // (~70mb with 16 byte data => 4 floats)
    RayTracingPipeline mGenLinkedListPip;
    ref<Buffer> mpLinkedListCounter;
    ref<Buffer> mpLinkedListCounter2;
    ref<ComputePass> mpLinkedListNeighborsPass;

};
