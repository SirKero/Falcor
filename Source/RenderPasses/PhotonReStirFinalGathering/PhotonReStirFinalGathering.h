/***************************************************************************
 # Copyright (c) 2015-21, NVIDIA CORPORATION. All rights reserved.
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
#include "Utils/Sampling/SampleGenerator.h"
 //Light samplers
#include "Rendering/Lights/LightBVHSampler.h"
#include "Rendering/Lights/EmissivePowerSampler.h"
#include "Rendering/Lights/EmissiveUniformSampler.h"

using namespace Falcor;

class PhotonReSTIRFinalGathering : public RenderPass
{
public:
    using SharedPtr = std::shared_ptr<PhotonReSTIRFinalGathering>;

    static const Info kInfo;

    /** Create a new render pass object.
        \param[in] pRenderContext The render context.
        \param[in] dict Dictionary of serialized parameters.
        \return A new object, or an exception is thrown if creation failed.
    */
    static SharedPtr create(RenderContext* pRenderContext = nullptr, const Dictionary& dict = {});

    virtual Dictionary getScriptingDictionary() override;
    virtual RenderPassReflection reflect(const CompileData& compileData) override;
    virtual void compile(RenderContext* pRenderContext, const CompileData& compileData) override {}
    virtual void execute(RenderContext* pRenderContext, const RenderData& renderData) override;
    virtual void renderUI(Gui::Widgets& widget) override;
    virtual void setScene(RenderContext* pRenderContext, const Scene::SharedPtr& pScene);
    virtual bool onMouseEvent(const MouseEvent& mouseEvent) override { return false; }
    virtual bool onKeyEvent(const KeyboardEvent& keyEvent) override { return false; }

    //Structs and enum
    enum ResamplingMode {
        NoResampling = 0,
        Temporal = 0b1,
        Spartial = 0b10,
        SpartioTemporal = 0b11
    };

    enum BiasCorrectionMode {
        Off = 0,
        Basic = 1u,
        RayTraced = 2u
    };

    enum VplEliminationMode {
        Fixed = 0,
        Linear = 1u,
        Power = 2u,
        Root = 3u
    };
private:
    //Acceleration Structure helpers Structs
    struct BLASData {
        D3D12_RAYTRACING_ACCELERATION_STRUCTURE_PREBUILD_INFO prebuildInfo;
        D3D12_BUILD_RAYTRACING_ACCELERATION_STRUCTURE_INPUTS buildInputs;
        D3D12_RAYTRACING_GEOMETRY_DESC geomDescs;

        uint64_t blasByteSize = 0;                    ///< Maximum result data size for the BLAS build, including padding.
        uint64_t scratchByteSize = 0;                   ///< Maximum scratch data size for the BLAS build, including padding.
    };

    struct TLASData {
        Buffer::SharedPtr pTlas;
        ShaderResourceView::SharedPtr pSrv;             ///< Shader Resource View for binding the TLAS.
        Buffer::SharedPtr pInstanceDescs;               ///< Buffer holding instance descs for the TLAS.
    };

    //Holds all needed data for an Acceleration Structure
    struct SphereAccelerationStructure {
        size_t numberBlas = 1;
        bool fastBuild = false;
        bool update = false;    
        size_t blasScratchMaxSize;
        std::vector<BLASData> blasData;
        std::vector<Buffer::SharedPtr> blas;
        std::vector<D3D12_RAYTRACING_INSTANCE_DESC> instanceDesc;
        Buffer::SharedPtr blasScratch;
        D3D12_RAYTRACING_ACCELERATION_STRUCTURE_PREBUILD_INFO tlasPrebuildInfo;
        Buffer::SharedPtr tlasScratch;
        TLASData tlas;
    };

    enum class CurrentPass {
        GenerateAdditional,
        Resampling,
        SpartialResampling,
        FinalShading,
        FinalShadingNoResampling
    };

    PhotonReSTIRFinalGathering() : RenderPass(kInfo) {}

    /** Resets the pass
    */
    void resetPass(bool resetScene = false);
    /** Prepares the samplers etc needed for lighting. Returns true if lighting has changed
    */
    bool prepareLighting(RenderContext* pRenderContext);

    /** Prepares the photon light buffers
    */
    void preparePhotonBuffers(RenderContext* pRenderContext, const RenderData& renderData);

    /** Prepare the reservoir and VPL buffers
    */
    void prepareBuffers(RenderContext* pRenderContext, const RenderData& renderData);

    /** Trace Scene for final gather hit
    */
    void getFinalGatherHitPass(RenderContext* pRenderContext, const RenderData& renderData);

    /** Generate Photon lights
    */
    void generatePhotonsPass(RenderContext* pRenderContext, const RenderData& renderData);

    /** Collect Photons at the final gather hit
    */
    void collectFinalGatherHitPhotons(RenderContext* pRenderContext, const RenderData& renderData);

    /** Collect the caustic photons on the first diffuse hit point
    */
    void collectCausticPhotons(RenderContext* pRenderContext, const RenderData& renderData);

    /** Distributes and collects photons for the final gather hit in one pass
    */
    //void distributeAndCollectFinalGatherPhotonPass(RenderContext* pRenderContext, const RenderData& renderData);

    /** Uses sampled points to genererate additional candidates
    */
    void generateAdditionalCandidates(RenderContext* pRenderContext, const RenderData& renderData);

    /** Uses temporal resampling to combine the reservoir with the reservoir of the previous frame
    */
    void temporalResampling(RenderContext* pRenderContext, const RenderData& renderData);

    /** Uses spartial resampling to combine the reservoir with the reservoir of neighbors
    */
    void spartialResampling(RenderContext* pRenderContext, const RenderData& renderData);

    /** Uses spartial and temporal resampling to combine the reservoir with the reservoir of neighbors
   */
    void spartioTemporalResampling(RenderContext* pRenderContext, const RenderData& renderData);

    /** Uses the reservoir to shade the pixel
    */
    void finalShadingPass(RenderContext* pRenderContext, const RenderData& renderData);

    /* Fills the neighbor offset buffer with psyeudo random numbers
    */
    void fillNeighborOffsetBuffer(std::vector<int8_t>& buffer);

    /** Copies the photon counter to a uint to show the number in UI.
    * If dynamic photon dispatch count is active, the dispatch value is changed here
    */
    void handelPhotonCounter(RenderContext* pRenderContext);

    /** Binds all the reservoirs. useAdditionAsInput is used if the spartial pass is used before the spartiotemporal
    */
    void bindReservoirs(ShaderVar& var, uint index , bool bindPrev = true);

    /** Bindes the vpls depending on the pass
    */
    void bindPhotonLight(ShaderVar& var, uint index, bool bindPrev = true);

    /** Gets PDF texture size.
    */
    void computePdfTextureSize(uint32_t maxItems, uint32_t& outWidth, uint32_t& outHeight, uint32_t& outMipLevels);

    /*  * Creates the acceleration structure.
        * Has to be called at least once to create the AS. buildAccelerationStructure(...) needs to be called after that to build/update the AS
        * Calling it with an existing AS rebuilds it
    */
    void createAccelerationStructure(RenderContext* pRenderContext, SphereAccelerationStructure& accel, const uint numberBlas, const std::vector<uint>& aabbCount, const std::vector<uint64_t>& aabbGpuAddress);

    /** Creates the TLAS
    */
    void createTopLevelAS(RenderContext* pContext, SphereAccelerationStructure& accel);

    /** Creates the BLAS
    */
    void createBottomLevelAS(RenderContext* pContext, SphereAccelerationStructure& accel, const std::vector<uint> aabbCount, const std::vector<uint64_t> aabbGpuAddress);

    /* * Builds the acceleration structure. Is needed every time one of the aabb buffers changes
    */
    void buildAccelerationStructure(RenderContext* pRenderContext, SphereAccelerationStructure& accel, const std::vector<uint>& aabbCount);

    /** Build or Update the TLAS
    */
    void buildTopLevelAS(RenderContext* pContext, SphereAccelerationStructure& accel);

    /** Build the BLAS
    */
    void buildBottomLevelAS(RenderContext* pContext, SphereAccelerationStructure& accel,const std::vector<uint>& aabbCount);

    //Constants
    const uint kNumNeighborOffsets = 8192;  //Size of neighbor offset buffer
    const uint kDynamicPhotonDispatchInitValue = 500224;    //Start with 500 thousand photons

    //
    //UI
    //
    //Resampling
    uint mResamplingMode = ResamplingMode::SpartioTemporal;        //Resample Mode
    uint mInitialCandidates = 1;            // Number of initial candidates per pixel
    uint mValidNeighborMaskMipLevel = 3;    //The mip leve for the valid neighbor mask
    uint mTemporalMaxAge = 20;              // Max age of an temporal reservoir
    uint mSpartialSamples = 1;              // Number of spartial samples
    uint mDisocclusionBoostSamples = 2;     // Number of spartial samples if no temporal surface was found
    float mSamplingRadius = 20.f;           //Sampling radius in pixel
    float mRelativeDepthThreshold = 0.15f;   // Realtive Depth threshold (is neighbor 0.1 = 10% as near as the current depth)
    float mNormalThreshold = 0.6f;          //Cosine of maximum angle between both normals allowed
    uint mBiasCorrectionMode = BiasCorrectionMode::Basic;   //Bias Correction Mode
    bool mUseFinalVisibilityRay = true;         //For optional visibility ray for each reservoir
    bool mUseDiffuseOnlyShading = true;        //Only uses diffuse shading for ReSTIR. Can be used if VBuffer only contains diffuse hits
    bool mUseReducedReservoirFormat = true;    // Full precision = RGBA32_UINT, Reduced = RG32UINT. TargetPdf and M only uses 16 bits in reduced
    bool mBoostSampleTestVisibility = false;    //Extra visibility test for boosting

    //Photon
    bool mChangePhotonLightBufferSize = false;  //Change max size of photon lights buffer
    uint2 mNumMaxPhotons = uint2(400000,100000);               //Size of the photon buffer
    uint2 mNumMaxPhotonsUI = mNumMaxPhotons;
    bool mUseDynamicePhotonDispatchCount = true;    //Dynamically change the number of photons to fit the max photon number
    uint mPhotonDynamicDispatchMax = 2000000;       //Max value for dynamically dispatched photons
    float mPhotonDynamicGuardPercentage = 0.08f;    //Determines how much space of the buffer is used to guard against buffer overflows 
    float mPhotonDynamicChangePercentage = 0.05f;    //The percentage the buffer is increased/decreased per frame
    uint2 mCurrentPhotonCount = uint2(1000000,1000000);             //Gets data from GPU buffer
    float mASBuildBufferPhotonOverestimate = 1.15f;
    uint mNumDispatchedPhotons = 700000;        //Number of dispatched photons 
    uint mPhotonYExtent = 512;
    uint mPhotonMaxBounces = 10;             //Number of bounces  TODOSplit this up in transmissive specular and diffuse
    float mPhotonRejection = 0.3f;          //Rejection probability
    float2 mPhotonCollectionRadiusStart = float2(0.025f, 0.005f);
    float2 mPhotonCollectRadius = mPhotonCollectionRadiusStart;     //Radius for collection
    bool mPhotonUseAlphaTest = true;
    bool mPhotonAdjustShadingNormal = true;
    bool mAllowFinalGatherPointsInRadius = true;
    bool mCausticUseTemporalFilter = true;
    uint mCausticTemporalFilterMaxHistory = 60;
    bool mEnableCausticPhotonCollection = true;
    int mMaxCausticBounces = 0;
    bool mUseStatisticProgressivePM = true;
    bool mUseStatisticProgressivePMGlobal = false;
    float mPPM_Alpha = 0.66f;
    uint mFramesCameraStill = 0;

    //Photon Culling
    bool mUsePhotonCulling = true;
    uint mCullingHashBufferSizeBits = 22;   //Determines the size of the buffer 2^x.
    bool mPhotonCullingRebuildBuffer = true;   //Rebuilds buffer if size was changed
  

    //Runtime
    bool mReset = true;
    bool mReuploadBuffers = true;
    bool mBiasCorrectionChanged = false;
    uint2 mScreenRes = { 0,0 };
    bool mUpdateRenderSettings = true;
    uint mFrameCount = 0;

    //Falcor Vars
    Scene::SharedPtr mpScene;       //Pointer for scene
    SampleGenerator::SharedPtr mpSampleGenerator;       //Sample generator for Generate pass
    EmissiveLightSampler::SharedPtr mpEmissiveLightSampler;     //EmissiveLightSampler for Photon generation

    //Compute Passes
    ComputePass::SharedPtr mpGenerateAdditionalCandidates;  //Generates additional candidates
    ComputePass::SharedPtr mpTemporalResampling;            //Temporal Resampling Pass
    ComputePass::SharedPtr mpSpartialResampling;            //Spartial Resampling Pass
    ComputePass::SharedPtr mpSpartioTemporalResampling;     //Spartio Temporal Resampling Pass
    ComputePass::SharedPtr mpFinalShading;                  //Final Shading Pass

    //Buffer
    Buffer::SharedPtr mpPhotonLightBuffer[2];
    Texture::SharedPtr mpReservoirBuffer[2];    //Buffers for the reservoir
    Texture::SharedPtr mpReservoirBoostBuffer;   //Buffer for current iteration spatial boosting
    Buffer::SharedPtr mpPhotonLightBoostBuffer; //Photon light buffer for spatial boosting
    Texture::SharedPtr mpValidNeighborMask;     //Mask for searching valid neightbors. Only used if currentFrame spartial sampling is used (mInitialCandidates > 0)
    Buffer::SharedPtr mpSurfaceBuffer[2];       //Buffer for surface data
    Texture::SharedPtr mpNeighborOffsetBuffer;   //Constant buffer with neighbor offsets
    Buffer::SharedPtr mpPhotonAABB[2];              //Photon AABBs for Acceleration Structure building
    Buffer::SharedPtr mpPhotonData[2];              //Additional Photon data (flux, dir)
    Buffer::SharedPtr mpPhotonCounter;     //Counter for the number of lights
    Buffer::SharedPtr mpPhotonCounterCPU;  //For showing the current number of photons in the UI
    Texture::SharedPtr mpPrevViewTex;      //If view texture is used, we store the last frame here
    Texture::SharedPtr mpFinalGatherHit;   //Hit info for the final gather
    Texture::SharedPtr mpPhotonCullingMask; //Mask for photon culling
    Texture::SharedPtr mpCausticPhotonsFlux[2];    //Flux onsurfaces for caustic photons

    //
    //Ray tracing programms and helper
    //
    struct RayTraceProgramHelper
    {
        RtProgram::SharedPtr pProgram;
        RtBindingTable::SharedPtr pBindingTable;
        RtProgramVars::SharedPtr pVars;

        static const RayTraceProgramHelper create()
        {
            RayTraceProgramHelper r;
            r.pProgram = nullptr;
            r.pBindingTable = nullptr;
            r.pVars = nullptr;
            return r;
        }
    };

    RayTraceProgramHelper mPhotonGeneratePass;          ///<Description for the Generate Photon pass
    RayTraceProgramHelper mDistributeAndCollectFinalGatherPointsPass;          ///<Distribution and collection of the final gather points in one pass
    RayTraceProgramHelper mGetFinalGatherHitPass;     ///<Description for getting the first diffuse hit
    RayTraceProgramHelper mGeneratePMCandidatesPass;    ///<Description for the 1 SPP Photon Mapper used in ReSTIR
    RayTraceProgramHelper mCollectCausticPhotonsPass;   ///< Collect the caustic photons directly

    SphereAccelerationStructure mPhotonAS;
};
