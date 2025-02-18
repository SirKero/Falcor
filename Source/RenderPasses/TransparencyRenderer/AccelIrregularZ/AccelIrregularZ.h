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
#include "Rendering/AccelerationStructure/CustomAccelerationStructure.h"
#include "Rendering/ShadowMaps/Blur/SMGaussianBlur.h"

class AccelIrregularZ : public TransparencyShadowMethod
{
public:
    virtual ~AccelIrregularZ() = default;

    AccelIrregularZ(ref<Device> pDevice, ref<Scene> pScene);

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
    virtual void debugPass(RenderContext* pRenderContext, const RenderData& renderData,  ref<Texture> debugOut = nullptr, ref<Texture> colorOut = nullptr) override;

    const std::vector<ref<Texture>>& getAccessTextures() const { return mAccessTextures; }

    enum class SMSamplePattern : uint
    {
        Center = 0,
        Halton = 1,
        MatrixDirectX = 2,
        MatrixHalton = 3,
        MatrixStratified = 4,
    };

    FALCOR_ENUM_INFO(SMSamplePattern,{
            {SMSamplePattern::Center, "Center"},
            {SMSamplePattern::Halton, "Halton"},
            {SMSamplePattern::MatrixDirectX, "MatrixDirectX"},
            {SMSamplePattern::MatrixHalton, "MatrixHalton"},
            {SMSamplePattern::MatrixStratified, "MatrixStratified"},
        }
    );

private:
    void prepareResources(RenderContext* pRenderContext);
    std::array<float4, 4> AccelIrregularZ::getCameraFrustumPlanes();
    //Funktion that generates the profiler passes in case they are not executed this frame
    void dummyProfileGeneration(RenderContext* pRenderContext);

    void updateSamplePattern();

    //Runtime
    uint mFrameCount = 0;

    //Sync Resources
    static const uint kFramesInFlight = 3; ///< Number of frames in flight for GPU/CPU sync
    static const uint kMinAABBUpdateCount = 128; //Shadow map should not be updated if there is less than this amount of AABBs
    ref<GpuFence> mpFence;                 ///< Fence for CPU/GPU syncs
    uint mStagingCount = 0;

    //Sample Gen (+Jitter)
    ref<CPUSampleGenerator> mpCPUSampleGenerator;                ///< Sample generator for uniform camera jitter.
    uint mNumCPUSampleGenSamples = 16;  //For CPU sample gen
    uint mNumHaltonSamples = 64; //Number of halton samples
    SMSamplePattern mSamplePattern = SMSamplePattern::Halton; //Sample Pattern
    bool mOptimizeSampleDistribution = true; //Extra pass that redistributes the weights
    float mSampleOverestimate = 1.75f; //How many more pixels are dispatched than the size of the shadow map. Only used with the opimized sample distribution
    bool mBlurSampleDistribution = true; //Blurs the lowest level of the sample distribution

    //Dynamic ray count on gpu
    bool mEnableDynamicRayCountCalc = true;
    bool mResetRayCount = false;
    float mDynRCGuardPercentage = 0.9f; //10% buffer for possible changes
    float mDynRCChangePercentage = 0.6f; //How much of the optimal value should be taken

    // Accel shadow settings
    float mMidpointPercentage = 0.9f; //Percentage where the midpoint is set. 0.5 is normal midpointSM, 0 is SM without bias
    float mOpaqueHitRayDepthBias = 1e-7f; //Depth bias applied to tmin after a opaque hit. Scaled with pixel size. Normally 1e-7 is used
    bool mUseOneAABBForAllLights = true;
    uint mAccelApproxNumElementsPerPixel = 4u;
    std::vector<uint> mAccelShadowNumPoints;
    std::vector<uint64_t> mAccelFenceWaitValues; // Fence values forCounter sync
    uint mAccelShadowMaxNumPoints = 0;
    bool mAccelShadowUseCPUCounterOptimization = false;
    bool mTransparencyBufferUsesColor = false; //Checks if the transparency buffer data size matches the global setting
    bool mAccelUsePCF = false;
    bool mAccelUseRayTracingInline = true;
    bool mAccelUseFrustumCulling = false;
    RayFlags mAccelRayFlags = RayFlags::None;
    float mMergeBoxDist = 0.f; //Distance the accel boxes are merged

    uint mSkipFrameCount = 0; //Counter for skipping frames
    uint mSkipGenerationFrameCount = 1; //Number of generated frames is 1/X

    LightMVP mStaggeredDirectionalLightMVP = {};
    int mDirectionalLightIndex = -1; //Used to set LightMVP

    struct
    {
        bool enable = false;
        uint selectedLight = 0;
        float2 clipX = float2(0, 4096);
        float2 clipY = float2(0, 4096);
        float2 clipZ = float2(-10000.f, 10000.f);
        float blendT = 0.2f;
        uint visMode = 0;
        bool stopGeneration = false;
    } mAccelDebugShowAS;

    ref<Sampler> mpPointSampler;
    std::unique_ptr<SMGaussianBlur> mpGaussianBlur;
    ref<SampleGenerator> mpSampleGenerator;

    std::vector<ref<Buffer>> mAccelShadowAABB;                                 // For Accel AABB points
    std::vector<ref<Buffer>> mAccelShadowCounter;                              // Counter for inserting points
    std::vector<ref<Buffer>> mAccelShadowCounterCPU;                           // Counter for inserting points
    std::vector<ref<Buffer>> mAccelShadowData;                                 // Transparency Data
    std::unique_ptr<CustomAccelerationStructure> mpShadowAccelerationStrucure; // AS
    ref<Texture> mpDebugDepth;                                                 // Depth for the debug passs
    std::vector<ref<Texture>> mAccessTextures;                                 //Access distribution from the other passes
    std::vector<ref<Texture>> mSampleDistribution;                             //Distribution of samples
    ref<Buffer> mpLastFrameMaxSampleCount;                                  //Buffer to store the sample distribution from last frame. Used with Optimize Sample distribution
    ref<Buffer> mpHaltonBuffer;                                             //Buffer with precalculated Halton numbers
    
    ref<ComputePass> mGenAccessMips;                //Create Prefix Sum Mips for the access texture 
    ref<ComputePass> mCalcSampleDistribution;       //Calcs the sample distribution from the access texture
    ref<ComputePass> mpOptimizeSamples;             //Optimize Sample distribution
    RayTracingPipeline mGenAccelShadowPip; //RayTracingPipeline
    RasterPipeline mRasterShowAccelPass;
};
FALCOR_ENUM_REGISTER(AccelIrregularZ::SMSamplePattern);
