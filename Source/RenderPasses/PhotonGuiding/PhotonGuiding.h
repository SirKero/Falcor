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
#include "Rendering/Lights/EnvMapSampler.h"

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
    void prepareLightingStructure(RenderContext* pRenderContext, const RenderData& renderData);

    //Prepares needed Buffers and Textures and Acceleration Structures
    void prepareResources(RenderContext* pRenderContext, const RenderData& renderData);

    void updateNumberOfRNGPasses();

    //Uses Reduce and updates the guiding textures
    void updateGuidingTextures(RenderContext* pRenderContext, const RenderData& renderData);

    //Uses reduce on the guiding counter to normalize the texture
    void guidingCounterReducePass(RenderContext* pRenderContext, const RenderData& renderData);

    //Generates the guiding mipmap traverse chain
    void generateGuidingMipTraverseChainPass(RenderContext* pRenderContext, const RenderData& renderData);

    //Blurs the guiding atlas
    void blurGuidingAtlasPass(RenderContext* pRenderContext, const RenderData& renderData);

    //Maps the guiding textures to the number of distributed photons. Also guarantees that a photon is dispatched per guiding texel
    void mapGuidingToPhotonsPass(RenderContext* pRenderContext, const RenderData& renderData, bool isLightIndexPass);

    //Reserverves Photons per Light source and determines hte "free" photons that can be distributed
    void reservePhotonsPerLightSource(RenderContext* pRenderContext);

    //Generates the guiding mipmap for the light index
    void generateLightIndexGuidingMipTraverseChainPass(RenderContext* pRenderContext, const RenderData& renderData);
    
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

    //Get Photon Collect defines
    DefineList getPhotonCollectDefines(bool isReSTIRPass = true);

    //Bind Collect Photon data
    void bindCollectPhotonData(ShaderVar& var);

    //ReSTIR initial sample generation
    void reSTIRGenerateInitialSamplesPass(RenderContext* pRenderContext, const RenderData& renderData);

    //ReSTIR resample final gather reservoirs pass
    void reSTIRResampleFGPass(RenderContext* pRenderContext, const RenderData& renderData);

    //Retraces the paths
    void reSTIRRetracePathsPass(RenderContext* pRenderContext, const RenderData& renderData, uint numPass);

    //Resamples paths
    void reSTIRResamplePathsPass(RenderContext* pRenderContext, const RenderData& renderData, uint numPass);

    //ReSTIR resample caustic reservoirs pass
    void reSTIRResampleCausticPass(RenderContext* pRenderContext, const RenderData& renderData);

    //ReSTIR evaluate reservoirs pass
    void reSTIREvaluateReservoirsPass(RenderContext* pRenderContext, const RenderData& renderData);

    // Splat the reservoirs from last frame into the current frame
    void reSTIRSplatTemporalReservoirsPass(RenderContext* pRenderContext, const RenderData& renderData);

    // Retrace caustic paths and splat last frame into the current frame
    void reSTIRRetraceAndSplatTemporalReservoirsPass(RenderContext* pRenderContext, const RenderData& renderData);

    // Sort the splatted reservoirs so they can be used in the resampling pass
    void reSTIRSortSplattedReservoirsPass(RenderContext* pRenderContext, const RenderData& renderData);

    //
    //Structs
    //
    struct PathLengthSettings
    {
        uint maxPathLength = 10;
        uint deltaBounces = 10;
        uint diffuseBounces = 3;
        uint specularBounces = 3;

        bool renderUI(Gui::Widgets& widget, std::string ident = "##") {
            bool changed = false;
            changed |= widget.var(("Path Length" + ident).c_str(), maxPathLength, 0u, 254u, 1u);
            widget.tooltip("Maximal combined path length");
            changed |= widget.var(("Delta Bounces" + ident).c_str(), deltaBounces, 0u, 254u, 1u);
            widget.tooltip("Maximal delta bounces (reflection + transmission)");
            changed |= widget.var(("Diffuse Bounces" + ident).c_str(), diffuseBounces, 0u, 254u, 1u);
            widget.tooltip("Maximal diffuse bounces  (reflection + transmission)");
            changed |= widget.var(("Specular Bounces" + ident).c_str(), specularBounces, 0u, 254u, 1u);
            widget.tooltip("Maximal specular bounces  (reflection + transmission)");
            return changed;
        }

        uint pack() {
            uint packed = 0;
            packed |= maxPathLength & 0xFF;
            packed |= (deltaBounces & 0xFF) << 8;
            packed |= (diffuseBounces & 0xFF) << 16;
            packed |= (specularBounces & 0xFF) << 24;
            return packed;
        }
    };

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

    //
    // Pointers
    //
    ref<Scene> mpScene;                     // Scene Pointer
    ref<SampleGenerator> mpSampleGenerator; // GPU Sample Gen
    std::unique_ptr<CustomAccelerationStructure> mpPhotonAS;      // Accel Pointer
    std::unique_ptr<RTXDI> mpRTXDI;                                 // Ptr to RTXDI for direct use
    RTXDI::Options mRTXDIOptions;                                 // Options for RTXDI

    //
    // Parameters
    //
    uint mFrameCount = 0;
    uint2 mScreenRes = uint2(0, 0);
    bool mResetScreenTex = false;
    bool mOptionsChanged = false;
    bool mResetClearResources = false;
    uint mNumberLightPaths = 0;
    uint mRNGNumPasses = 29; //For proper offsets in the RNG 

    // Material Settings
    bool mUseLambertianDiffuse = false;         // Enable Lambert Diffuse BRDF instead of Frostbyte
    float mSpecularRoughnessThreshold = 0.20f; // Any material below this is considered specular
    bool mEvalDeltaPdfs = false;                // If true delta pdfs are properly evaluated (==0), if false they are set to 1.

    //NRD
    bool mEnableNRDOutputs = false;      //Enables NRD outputs

    //
    // Path Tracer
    //
    uint mPTMaxBounces = 10;
    PhotonRenderMode mPhotonRenderMode = PhotonRenderMode::ReSTIR_PathPhoton;
    //Light Sampler
    std::unique_ptr<EmissiveLightSampler> mpEmissiveLightSampler; // Light Sampler
    EmissiveLightSamplerType mEmissiveLightSamplerType = EmissiveLightSamplerType::LightBVH;
    LightBVHSampler::Options mLightBVHOptions;
    bool mRebuildLightSampler = false;
    std::unique_ptr<EnvMapSampler> mpEnvMapSampler;
    float3 mNeeLightSelectProb = float3(0.33f);

    //
    // Photon Distribution
    //
    PathLengthSettings mPhotonPathLength = {};      // Number of Photon bounces
    float mGlobalPhotonRejection = 0.3f;            // Probability a global photon is stored
    uint mNumDispatchedPhotons = 1000000;           // Number of Photons dispatched
    uint2 mNumMaxPhotons = uint2(1200000);   // Size of the photon buffer
    uint2 mNumMaxPhotonsUI = mNumMaxPhotons;        // For UI, as changing happens with a button
    bool mChangePhotonLightBufferSize = true;       // If buffer size has changed
    float mASBuildBufferPhotonOverestimate = 1.15f; // Guard percentage for AS building
    uint2 mCurrentPhotonCount = mNumMaxPhotons;
    float2 mPhotonRadius = float2(0.008f, 0.002f); //Global / Caustic Radius
    bool mUseAdaptivePhotonRadius = true;
    float2 mAdaptivePhotonRadius = float2(4.f, 2.f);    //Pixel Size scale for adptive radius
    float mNormalizePixelDiagonal = 0.f;                //Diagonal of a pixel in world space at distance 1. Used in adaptive photon radius calculation

    bool mPhotonRussianRoulette = false; //Enables Russian Roulette for the photon pass
    
    bool mUseDynamicPhotonDispatchCount = false;   // Dynamically change the number of photons to fit the max photon number
    uint mPhotonDynamicDispatchMax = 4000000;     // Max value for dynamically dispatched photons
    float mPhotonDynamicGuardPercentage = 0.08f;  // Determines how much space of the buffer is used to guard against buffer overflows
    float mPhotonDynamicChangePercentage = 0.04f; // The percentage the buffer is increased/decreased per frame

    //Stochastic Progressive photon mapping
    bool mEnableSPPM = false;
    float2 mSPPMStartRadius = mPhotonRadius;
    float mSPPMAlpha = 2.f / 3.f;
    uint mSPPMFramesCameraStill = 0;

    //
    // ReSTIR FG
    //
   
    ResamplingSettings mResampleSettingsFG = {};
    ResamplingSettings mResampleSettingsCaustic = {};
    bool mRebuildReservoirBuffer = false;
    bool mCanResample = false;                              //Is re
    bool mPathResamplingUseNEEAfterSpecular = true;         //Uses NEE instead of radiance estimate after a specular event
    bool mPathResamplingStopAfterDiffuseSpecular = true;   //Enables tracing the path if a specular hit occured after the first diffuse hit. This case is usually covered by caustics.
    bool mPathRetraceSeperatePass = true;                  //Seperate pass for retracing the current and other reservoir sample
    bool mUseNEEatFGPoint = false;                          //Does not store direct photons (pathLenght = 0) and produces a NEE sample at the FG point 


    // Splatting
    float4x4 mTemporalCameraViewProjection = float4x4::identity();
    float3 mTemporalCameraPosition = float3(0);
    float3 mTemporalCameraForward = float3(0);
    float mNormalizedPixelArea = 1.0; // For light trace
    bool mEnableLightTraceSplatting = true;
    bool mRetraceLightPaths = true; //Retrace light paths for final gather and caustic backprojection
    bool mCausticReservoirsUseBackupSample = false; //If there is no valid sample, a backup sample is aquired using motion vectors
    bool mSplattingResampleUseLinkedList = true; //Uses a linked list for resampled reprojection

    //
    //Guiding Infos/Options
    //
    bool mEmissiveLightResetTextures = false;
    uint mEmissiveLightCount = 0;
    uint mAnalyticLightCount = 0;
    uint mTotalLightCount = 0;
    uint mGuidingTextureResolution = 64;    //Resolution of one guiding texture
    uint mGuidingAtlasResolution = 512;     //Resolution of the guiding atlas
    uint mGuidingAtlasMipLevels = 1;        //Mip levels for the atlas
    GuidingMode mGuidingMode = GuidingMode::ReSTIRDiscretized;
    float mGuidingClearValueEmission = 0.1f;
    bool mUseGaussianBlur = false;
    bool mGuidingResetAccumulateCount = false;
    uint mGuidingAccumulateCount = 0;

    GuidingHistogramAccumulateMode mGuidingHistogramAccumMode = GuidingHistogramAccumulateMode::AveragePercentage;   //Determines what happens with the accumulate texture
    float mGuidingHistogramAccumValue = 0.3f;            //64.f; Additional value needed for some accumulate modes

    uint mGuidingLightIndexSize = 1;    //Pixel width/height of the index guiding texture
    uint mGuidingDiscretizedEmissionFactor = 256;    //For the discretized modis, the emission is multiplied with this factor
    uint mGuidingDiscretizedEmissionMax = mGuidingDiscretizedEmissionFactor * 4;    //For the discretized modis, the emission is multiplied with this factor
    uint mGuidingBlurWidth = 3;        //Blur radius
    float mGuidingBlurSigma = 1.f;      //Gaussian blur sigma
    bool mGuidingBlurUpdateWeights = true;         //True if weigths should be updated
    bool mUseFixedGuidingDispatch = true;      //Determine guiding dispatch beforehand and distribute on trace photon pixels
    uint mFixedGuidingDispatchReservedPhotons = 64; //Number of photons that are reserved due to fixed dispatch
    bool mUseDirectionAtlasOptimization = false;  //Reduces the number of recorded and stored direction maps by mapping direction guiding textures only to light sources that need them
    uint mAtlasOptimizationMaxDirectionGuidingMaps = 64;
    uint mAtlasOptimizationMapSize = 8; //Sqrt above
    uint mMinPhotonsPerGuidingTexel = 4; //Minimum number of photons that should be mapped to a guiding texel, else the directional guiding map is not used
    uint mAtlasOptiMinPhotonsPerTexelToCreate = 8; //If the atlas optimization is used, at least this number of photons is needed to create a guiding directional texture
    bool mGuidingUseDistanceBasedMinPhoton = false;
    float2 mGuidingDBMPMinMaxDistance = float2(1.f, 16.f); //Distance for DBMP(DistanceBasedMinPhoton)
    uint2 mGuidingDBMPMinMaxPhotons = uint2(4, 1024);     //Photons for DBMP(DistanceBasedMinPhoton)
    bool mResetGuidingTextures = false;

    //Debug
    bool mDebugFreezeGuidingTextures = false;
    bool mDebugShowGuidingTexture = false;
    int mDebugSelectedTriLight = -1;
    float mDebugDirGMScaleFactor = 1.f;
    float mDebugLightGMScaleFactor = 1.f;
    bool mDebugShowLightIndexGuidingTex = false;
    bool mDebugDisableDirectLight = false;
    bool mDebugDisableIndirectLight = false;
    bool mDebugPathRetracingShowPaths = false;
    float3 mDebugColorDirGM = float3(1,0,0);
    float3 mDebugColorLightGM = float3(0,1,0);
    float3 mDebugColorExtra = float3(0,0,1);
    bool mDebugShowSelectedLight = false;
    bool mDebugShowMinPhotons = false;

    //
    // Resources
    //
    ref<Buffer> mpPhotonAABB[2];    // Photon AABBs for Acceleration Structure building
    ref<Buffer> mpPhotonData[2];    // Additional Photon data (flux, dir)
    ref<Buffer> mpPhotonDirSampleGen[2]; // Stores the RNG states for direction sampling. Used for photon retracing
    ref<Buffer> mpPhotonCounter;    // Counter
    ref<Buffer> mpPhotonCounterCPU; // Counter CPU readable
    ref<Texture> mpGuidingAtlas[2];                  //Atlas for Guiding Textures for Photon Guiding
    ref<Texture> mpGuidingAtlasPrevUnblurred[2];   //Atlas Guiding Textures used for the blur (temporal history needs to be retained)
    ref<Texture> mpGuidingAtlasBlurHelper;           //Gaussian blur helper (separated)
    ref<Buffer> mpAtlasBlurWeights;                 //Weights for the atlas blur
    ref<Texture> mpRecordGuidingAtlas;            //Atlas texture to record guiding data.
    ref<Texture> mpLightIndexGuidingTexture[2];            //Texture with the size corresponding to the number of lights
    ref<Texture> mpLightIndexGuidingPrevTex;            //Light index guiding texture from last frame
    ref<Texture> mpRecordLightIndexGuidingTexture;      //Record the guiding
    ref<Texture> mpMapLightIdxToGuidingDirection[2];       //Size of light Index texture; Maps a light index to a guiding direction
    ref<Buffer> mpMapLightIdxToGuidingDirectionCounter; //A counter needed for the indices
    ref<Texture> mpMapGuidingDirectionToLightIndex;      //Size of number of guiding textures; Maps a guiding direction to a light index
    ref<Texture> mpReservedPhotonsPerLight;             //Number of reserved photons per light source
    ref<Buffer> mpReservedPhotonsBuffer;                          //Total number of "free" photons, that can be distributed according to the guiding map
    //ReSTIR
    ref<Buffer> mpFinalGatherReservoir[2];                     // Reservoir for the Final Gather sample
    ref<Buffer> mpCausticReservoir[2];                         // Reservoir for the Caustic sample
    ref<Texture> mpEmission;                                   // Emission for paths that travel through highly specular materials (ReSTIR FG)
    ref<Buffer> mpPathReservoir[2];                            // Reservoir storing a path
    ref<Texture> mpRetracedPath[2];                             // Texture for path retracing info
    ref<Texture> mpVBufferPrev;                                // VBuffer previous Frame
    ref<Texture> mpViewPrev;                                   // View Vector previous Frame
    //Caustic ReSTIR Splatting
    ref<Texture> mpLightTraceHeadCounter;                      // Screen size head buffer counter for light tracing to store the first hit
    ref<Buffer> mpLightTraceLinkedList;                        // Linked List for light tracing
    ref<Buffer> mpCausticPhotonHitInfo;                        // Hit info for caustic photons used in light trace
    ref<Buffer> mpSplattingGlobalCounter;                      // Counter used in Splatting
    ref<Buffer> mpSplattingCellCounter;                        // Per pixel cell counter
    ref<Buffer> mpSplattingCellOffsets;                        // Per pixel cell offsets
    ref<Buffer> mpSplattingSortingData;                        // Indices needed for sorting
    ref<Buffer> mpSplattingResamlingLinkedList;                // Linked list for resampling step
    ref<Buffer> mpSplattingSortedReservoirs;                   // Sorted reservoirs


    ref<Sampler> mpLinearSampler; //Linear Sampler
    ref<Sampler> mpPointSampler;    //Point Sampler

    //
    // Render Passes/Programs
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
    ref<ComputePass> mpGuidingBlurPass[2];         //Blurs the guiding atlas. Horizonal and vertical pass
    ref<ComputePass> mpGuidingLightIndexCounterReducePass;            // Uses same shader as above, but is may need other data formats
    ref<ComputePass> mpMapGuidingToDistributedPhotonsPass[2];      //Maps the current guiding texture to the actual number of photons. Also guarantees that 1 photon is distributed per guiding pixel. One pass for light and one for directional
    ref<ComputePass> mpGetFreePhotonsBasedOnDistPass;      //Uses a distance based metric to reserve photons per light instead of using a fixed value per light
    ref<ComputePass> mpGenerateGuidingMipTraverseChainPass; // Generates the mips for the guiding textures
    ref<ComputePass> mpGenerateLightIndexGuidingMipTraverseChainPass;  // Uses same shader as above, but is may need other data formats

    ref<ComputePass> mpDebugPass; //For debug

    //ReSTIR Passes
    RayTraceProgramHelper mGenerateInitialSamplesPass; // Trace Final Gather rays and collect photons
    RayTraceProgramHelper mRetracePathsPass;         // Retrace Path Reservoirs
    RayTraceProgramHelper mRetraceCausticPathsPass;  // Retrace the Caustic Paths for the Caustic reservoirs
    ref<ComputePass> mpResampleReservoirFGPass;      // Resampling Pass for Final Gather Reservoirs
    ref<ComputePass> mpResampleReservoirPathPass;    // Resampling of the Reservoirs
    ref<ComputePass> mpResampleReservoirCausticPass; // Resampling Pass for Caustic Reservoirs
    ref<ComputePass> mpEvaluateReservoirsPass;       // Evaluates ReSTIR DI and FG reservoirs
    //Caustic ReSTIR Splatting passes
    ref<ComputePass> mpTemporalSplatReservoirs;     // Reprojects reservoirs from last frame to curren
    ref<ComputePass> mpSplatSortComputeCellOffsets; // Sort step 1, compute cell offsets
    ref<ComputePass> mpSplatSortCellData;           // Sort step 2, sort the cell data
};


