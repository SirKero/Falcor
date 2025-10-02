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
#include "Rendering/Lights/EmissiveLightSampler.h"
#include "Rendering/Lights/LightBVHSampler.h"
#include "Rendering/RTXDI/RTXDI.h"

#include "Rendering/ShadowMaps/Blur/SMGaussianBlur.h"
#include "Rendering/AccelerationStructure/CustomAccelerationStructure.h"
#include "SharedEnums.slang"

using namespace Falcor;
using namespace PhotonGuidingSharedEnums;

class PhotonGuiding : public RenderPass
{
public:
    FALCOR_PLUGIN_CLASS(PhotonGuiding, "PhotonGuiding", "Photon Guiding based on Grittmann et al.[2018]");

    static ref<PhotonGuiding> create(ref<Device> pDevice, const Properties& props) { return make_ref<PhotonGuiding>(pDevice, props); }

    PhotonGuiding(ref<Device> pDevice, const Properties& props);

    virtual Properties getProperties() const override;
    virtual RenderPassReflection reflect(const CompileData& compileData) override;
    virtual void compile(RenderContext* pRenderContext, const CompileData& compileData) override {}
    virtual void execute(RenderContext* pRenderContext, const RenderData& renderData) override;
    virtual void renderUI(Gui::Widgets& widget) override;
    virtual void setScene(RenderContext* pRenderContext, const ref<Scene>& pScene) override;
    virtual bool onMouseEvent(const MouseEvent& mouseEvent) override { return false; }
    virtual bool onKeyEvent(const KeyboardEvent& keyEvent) override { return false; }

private:
    //
    // Functions
    //

    //Prepares Falcors light samplers
    void prepareLightingStructure(RenderContext* pRenderContext);

    //Prepares needed Buffers and Textures and Acceleration Structures
    void prepareResources(RenderContext* pRenderContext, const RenderData& renderData);

    //Uses Reduce and updates the guiding textures
    void updateGuidingTextures(RenderContext* pRenderContext, const RenderData& renderData);

    //Uses reduce on the guiding counter to normalize the texture
    void guidingCounterReducePass(RenderContext* pRenderContext, const RenderData& renderData);

    //Generates the guiding mipmap traverse chain
    void generateGuidingMipTraverseChainPass(RenderContext* pRenderContext, const RenderData& renderData);
    
    // Traces the photons and stores them in the scene
    void tracePhotonPass(RenderContext* pRenderContext, const RenderData& renderData);

    // Traces the camera and collects the photons
    void traceCameraPass(RenderContext* pRenderContext, const RenderData& renderData);

    //For debug
    void debugPass(RenderContext* pRenderContext, const RenderData& renderData);

    // Handles readback of the photon counter
    void handlePhotonCounter(RenderContext* pRenderContext);

    //Reset Render Passes
    void resetRenderPasses();

    // Gets normalized pixel area for back projection
    float getNormalizedPixelArea();

    //ReSTIR initial sample generation
    void reSTIRGenerateInitialSamplesPass(RenderContext* pRenderContext, const RenderData& renderData);

    //ReSTIR resample final gather reservoirs pass
    void reSTIRResampleFGPass(RenderContext* pRenderContext, const RenderData& renderData);

    //ReSTIR resample caustic reservoirs pass
    void reSTIRResampleCausticPass(RenderContext* pRenderContext, const RenderData& renderData);

    //ReSTIR evaluate reservoirs pass
    void reSTIREvaluateReservoirsPass(RenderContext* pRenderContext, const RenderData& renderData);

    // Splat the reservoirs from last frame into the current frame
    void reSTIRSplatTemporalReservoirsPass(RenderContext* pRenderContext, const RenderData& renderData);

    // Sort the splatted reservoirs so they can be used in the resampling pass
    void reSTIRSortSplattedReservoirsPass(RenderContext* pRenderContext, const RenderData& renderData);

    //
    // Pointers
    //
    ref<Scene> mpScene;                     // Scene Pointer
    ref<SampleGenerator> mpSampleGenerator; // GPU Sample Gen
    std::unique_ptr<EmissiveLightSampler> mpEmissiveLightSampler; // Light Sampler for NEE
    std::unique_ptr<CustomAccelerationStructure> mpPhotonAS;      // Accel Pointer
    std::unique_ptr<SMGaussianBlur> mpGaussianBlur;               //Gaussian Blur
    std::unique_ptr<RTXDI> mpRTXDI;                                 // Ptr to RTXDI for direct use
    RTXDI::Options mRTXDIOptions;                                 // Options for RTXDI

    //
    // Parameters
    //
    uint mFrameCount = 0;
    uint2 mScreenRes = uint2(0, 0);
    bool mResetScreenTex = false;
    bool mOptionsChanged = false;
    uint mNumberLightPaths = 0;

    // Material Settings
    bool mUseLambertianDiffuse = false;         // Enable Lambert Diffuse BRDF instead of Frostbyte
    float mSpecularRoughnessThreshold = 0.25f; // Any material below this is considered specular

    //
    // Path Tracer
    //

    uint mPTMaxBounces = 10;
    EmissiveLightSamplerType mEmissiveLightSamplerType = EmissiveLightSamplerType::LightBVH;
    LightBVHSampler::Options mLightBVHOptions;
    bool mRebuildLightSampler = true;
    PhotonRenderMode mPhotonRenderMode = PhotonRenderMode::ReSTIR_FG;

    //
    // Photon Distribution
    //
    uint mPhotonMaxBounces = 10;                    // Number of Photon bounces
    float mGlobalPhotonRejection = 0.3f;            // Probability a global photon is stored
    uint mNumDispatchedPhotons = 2000000;           // Number of Photons dispatched
    uint2 mNumMaxPhotons = uint2(1000000);   // Size of the photon buffer
    uint2 mNumMaxPhotonsUI = mNumMaxPhotons;        // For UI, as changing happens with a button
    bool mChangePhotonLightBufferSize = true;       // If buffer size has changed
    float mASBuildBufferPhotonOverestimate = 1.15f; // Guard percentage for AS building
    uint2 mCurrentPhotonCount = mNumMaxPhotons;
    float2 mPhotonRadius = float2(0.008f, 0.002f); //Global / Caustic Radius
    bool mUseAdaptivePhotonRadius = true;
    float2 mAdaptivePhotonRadius = float2(4.f, 1.5f);    //Pixel Size scale for adptive radius
    float mNormalizePixelDiagonal = 0.f;                //Diagonal of a pixel in world space at distance 1. Used in adaptive photon radius calculation

    bool mPhotonRussianRoulette = true; //Enables Russian Roulette for the photon pass
    
    bool mUseDynamicPhotonDispatchCount = true;   // Dynamically change the number of photons to fit the max photon number
    uint mPhotonDynamicDispatchMax = 4000000;     // Max value for dynamically dispatched photons
    float mPhotonDynamicGuardPercentage = 0.08f;  // Determines how much space of the buffer is used to guard against buffer overflows
    float mPhotonDynamicChangePercentage = 0.04f; // The percentage the buffer is increased/decreased per frame

    //
    // ReSTIR FG
    //
    struct ResamplingSettings
    {
        bool enable = true;
        uint confidenceCap = 20;                // Maximum confidence allowed
        uint spatialSamples = 1;                // Number of spatial samples
        uint disocclusionBoostExtraSamples = 1; // Number of spatial samples if no temporal surface was found
        float samplingRadius = 20.f;            // Sampling radius in pixel
        float relativeDepthThreshold = 0.15f;  // Relative Depth threshold(is neighbor 0.1 = 10 % as near as the current depth)
        float normalThreshold = 0.6f;          // Cosine of maximum angle between both normals allowed
        float jacobianDistanceThreshold = 0.001f; // Threshold for Jacobian distances
        bool usePathThreshold;                     // Enable resampling only if path length are the same
    };
    ResamplingSettings mResampleSettingsFG = {};
    ResamplingSettings mResampleSettingsCaustic = {};
    bool mRebuildReservoirBuffer = false;
    bool mCanResample = false;

    // Splatting
    float4x4 mTemporalCameraViewProjection = float4x4::identity();
    float3 mTemporalCameraPosition = float3(0);
    float3 mTemporalCameraForward = float3(0);
    float mNormalizedPixelArea = 1.0; // For light trace
    bool mEnableLightTraceSplatting = false; //TODO Renderer crashed if enabled and mode changes, look into why

    //
    //Guiding Infos/Options
    //
    bool mEmissiveLightResetTextures = false;
    uint mEmissiveLightCount = 0;
    uint mGuidingTextureResolution = 512;
    GuidingMode mGuidingMode = GuidingMode::Disabled;
    float mGuidingClearValueEmission = 0.1f;
    bool mUseGaussianBlur = true;
    bool mGuidingResetAccumulateCount = false;
    uint mGuidingAccumulateCount = 0;
    bool mGuidingRealTimeMode = false;   //If true, the guiding texture does not reset every frame
    uint mGuidingHistoryLimit = 256;    //History limit for the guiding texture

    //Debug
    bool mDebugFreezeGuidingTextures = false;
    bool mDebugShowGuidingTexture = false;
    uint mDebugSelectedTriLight = 0;
    float mDebugColorScaleFactor = float(mGuidingTextureResolution * mGuidingTextureResolution);
    float mDebugSizeScaleFactor = 1.f;
    bool mDebugScaleToDstDim = true;

    //
    // Resources
    //
    ref<Buffer> mpPhotonAABB[2];    // Photon AABBs for Acceleration Structure building
    ref<Buffer> mpPhotonData[2];    // Additional Photon data (flux, dir)
    ref<Buffer> mpPhotonCounter;    // Counter
    ref<Buffer> mpPhotonCounterCPU; // Counter CPU readable
    std::vector<ref<Texture>> mGuidingTextures; //Guiding Textures for Photon Guiding
    std::vector<ref<Texture>> mGuidingLastFrameWeightTextures; //Guiding Textures used for the blur (temporal history needs to be retained)
    std::vector<ref<Texture>> mRecordGuidingTextures; //Textures to record guiding data.
    //ReSTIR
    ref<Buffer> mpFinalGatherReservoir[2];                     // Reservoir for the Final Gather sample
    ref<Buffer> mpCausticReservoir[2];                         // Reservoir for the Caustic sample
    ref<Texture> mpEmission;                                   // Emission for paths that travel through highly specular materials (ReSTIR FG)
    //Caustic ReSTIR Splatting
    ref<Texture> mpLightTraceHeadCounter;                      // Screen size head buffer counter for light tracing to store the first hit
    ref<Buffer> mpLightTraceLinkedList;                        // Linked List for light tracing
    ref<Buffer> mpCausticPhotonHitInfo;                        // Hit info for caustic photons used in light trace
    ref<Buffer> mpSplattingGlobalCounter;                      // Counter used in Splatting
    ref<Buffer> mpSplattingCellCounter;                        // Per pixel cell counter
    ref<Buffer> mpSplattingCellOffsets;                        // Per pixel cell offsets
    ref<Buffer> mpSplattingSortingData;                        // Indices needed for sorting
    ref<Buffer> mpSplattingSortedReservoirs;                   // Sorted reservoirs


    ref<Sampler> mpLinearSampler; //Linear Sampler

    //
    // Render Passes/Programms
    //
    struct RayTraceProgramHelper
    {
        ref<RtProgram> pProgram;
        ref<RtBindingTable> pBindingTable;
        ref<RtProgramVars> pVars;

        void reset()
        {
            pProgram.reset();
            pVars.reset();
        }

        void initProgramVars(ref<Device> pDevice, ref<Scene> pScene, ref<SampleGenerator> pSampleGenerator);
    };

    RayTraceProgramHelper mTracePhotonPass;           // Trace Photons
    RayTraceProgramHelper mTraceCameraPass;              // Trace Camera
   
    ref<ComputePass> mpGuidingCounterReducePass; //Reduce on the guiding counter to obtain the total
    ref<ComputePass> mpGenerateGuidingMipTraverseChainPass; // Generates the mips for the guiding textures
    ref<ComputePass> mpDebugPass; //For debug

    //ReSTIR Passes
    RayTraceProgramHelper mGenerateInitialSamplesPass; // Trace Final Gather rays and collect photons
    ref<ComputePass> mpResampleReservoirFGPass;      // Resampling Pass for Final Gather Reservoirs
    ref<ComputePass> mpResampleReservoirCausticPass; // Resampling Pass for Caustic Reservoirs
    ref<ComputePass> mpEvaluateReservoirsPass;       // Evaluates ReSTIR DI and FG reservoirs
    //Caustic ReSTIR Splatting passes
    ref<ComputePass> mpTemporalSplatReservoirs;     // Reprojects reservoirs from last frame to curren
    ref<ComputePass> mpSplatSortComputeCellOffsets; // Sort step 1, compute cell offsets
    ref<ComputePass> mpSplatSortCellData;           // Sort step 2, sort the cell data
};


