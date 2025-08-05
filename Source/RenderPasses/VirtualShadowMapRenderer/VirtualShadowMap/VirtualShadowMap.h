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
#include "Rendering/ShadowMaps/Blur/SMGaussianBlur.h"

using namespace Falcor;

class VirtualShadowMap
{
public:
    virtual ~VirtualShadowMap() = default;

    VirtualShadowMap(ref<Device> pDevice, ref<Scene> pScene, std::string vBufferName);

    void initAvailableMemoryStack();

    void initStackCounter();

    /** Generate resources needed to evaluate the Shadow Method
     */
    void generate(RenderContext* pRenderContext, const RenderData& renderData);

    /** Allows the transparency method to reset the evaluation program if required
    */
    bool requireReset();

    /** Returns defines needed for the method
     */
    DefineList getDefines();

    /** Set the shader data for the VirtualShadowMapData shader
     */
    void setShadowData(const ShaderVar& var, bool RW);

    /** Set the needed shader data for the method (textures,buffer, etc)
     */
    void setShaderData(const ShaderVar& var);

    /** Render UI for the method
     */
    bool renderUI(Gui::Widgets& widget);

    void debugPass(RenderContext* pRenderContext, const RenderData& renderData, ref<Texture> debugOut);

    bool debugIsEnabled() { return mShowMemoryDebugView; }

    bool resetIsRequired() { return mResetRequired; }

private:
    struct LightVP
    {
        float4x4 viewProjection;
        float4x4 invViewProjection;
    };
    void updateViewProjection(ref<Light> pLight);
    void shiftClipMapOrigin(RenderContext* pRenderContext);
    void sampleViewFrustum(RenderContext* pRenderContext, const RenderData& renderData);
    void updateClipMaps(RenderContext* pRenderContext);
    void updateRenderBuffer(RenderContext* pRenderContext);
    void invalidateRenderData(RenderContext* pRenderContext);
    void setDirectionalLightSource();
    void prepareResources(RenderContext* pRenderContext);
    // Function that generates the profiler passes in case they are not executed this frame
    void dummyProfileGeneration(RenderContext* pRenderContext);

    //Falcor Resources
    ref<Device> mpDevice;
    ref<Scene> mpScene;
    std::string mVBufferName = "";

    //Runtime
    uint mFrameCount = 0;
    // Shader Resources
    uint mRenderBudget = 16; //Render Budget in terms of how many pages are rendered at most every frame
    uint2 mClipMapSize = uint2(4096);
    uint2 mPageSize = uint2(128); //page size * virtual clip map size has to be clip map size
    uint2 mVirtualClipMapSize = uint2(32);
    uint mNumClipMaps = 8; 
    std::vector<ref<Texture>> mpPhysicalClipMaps; //Vector of mClipMapSize x mClipMapSize resolution Textures containing the actual Shadow data for each clipmap
    std::vector<ref<Texture>> mpVirtualClipMaps; //Vector of mVirtualClipMapSize x mVirtualClipMapSize resolution Textures containing the information about the required pages, the state of each page and the physical address of the shadow data 
    uint mDirectionalLightSourceIndex = 0;
    float4x4 mView;
    std::vector<LightVP> mLightVPs;
    float mDepthBias = 0.0001f;
    // Clip Map Handles
    float mClipMap0Extention = 1; //the extention of clip map 0 from the camera origin in camera space. A clip map extention of 1 results into a 2 x 2 rectangle with the current camera position in its center.
    std::vector<float2> mInitCameraPosWs; //the initial camera positions clipped to the resolution of the according clip map level
    std::vector<int2> mOverallOriginOffsets; //vector containing the overall origin for each clip map level
    std::vector<int2> mClipMapOriginOffsets; //vector containing the overall origin offset of the last frame and the origin offset of this frame for each clip map
    //The overall origin offset of the last frame is stored to check if pixels are being pushed out of the last frame by the latest camera movement
    float2 mVirtualClipMapExtentionInLightViewSpace;
    bool mMoved = false;
    // Memory Management Resources
    bool mFirstExecute = true;
    ref<Buffer> mpRenderBuffer;
    uint mRenderBufferSize;
    std::vector<ref<Buffer>> mpAvailableMemoryStack;
    uint mAvailableMemorySize;
    ref<Buffer> mpStackCounter;
    uint mStackCounterSize;

    // Pipelines / Programs
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

    RayTracingPipeline mGenVirtualShadowMapPip;
    ref<ComputePass> mpSampleViewFrustumPass;
    ref<ComputePass> mpUpdateOriginShiftPass;
    ref<ComputePass> mpUpdateVirtualClipMapPass;
    ref<ComputePass> mpUpdateRenderBufferPass;
    ref<ComputePass> mpInvalidateRenderDataPass;
    ref<ComputePass> mpDebugMemoryPass;
    // Memory Debug View
    bool mShowMemoryDebugView = false;
    // UI Handles
    bool mResetRequired = false;
    bool mRenderBudgetChanged = false;
};
