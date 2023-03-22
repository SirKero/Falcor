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

class ReSTIRGI : public RenderPass
{
public:
    using SharedPtr = std::shared_ptr<ReSTIRGI>;

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
    virtual bool onMouseEvent(const MouseEvent& mouseEvent) override;
    virtual bool onKeyEvent(const KeyboardEvent& keyEvent) override;

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

    ReSTIRGI() : RenderPass(kInfo) {}

    /** Resets the pass
    */
    void resetPass(bool resetScene = false);
    /** Prepares the samplers etc needed for lighting. Returns true if lighting has changed
    */
    bool prepareLighting(RenderContext* pRenderContext);

    /** Prepare the reservoir and VPL buffers
    */
    void prepareBuffers(RenderContext* pRenderContext, const RenderData& renderData);

    /** Trace Scene for final gather hit
    */
    void getFinalGatherHitPass(RenderContext* pRenderContext, const RenderData& renderData);

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

    /** Pass for debuging pixel values
    */
    void debugPass(RenderContext* pRenderContext, const RenderData& renderData);

    /* Fills the neighbor offset buffer with psyeudo random numbers
    */
    void fillNeighborOffsetBuffer(std::vector<int8_t>& buffer);

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
    uint mSampleGenMaxBounces = 1;
    uint mResamplingMode = ResamplingMode::SpartioTemporal;        //Resample Mode
    uint mSampleBoosting = 0;            // Number of initial candidates per pixel
    uint mTemporalMaxAge = 20;              // Max age of an temporal reservoir
    uint mSpartialSamples = 1;              // Number of spartial samples
    uint mDisocclusionBoostSamples = 2;     // Number of spartial samples if no temporal surface was found
    float mSamplingRadius = 20.f;           //Sampling radius in pixel
    float mRelativeDepthThreshold = 0.15f;   // Realtive Depth threshold (is neighbor 0.1 = 10% as near as the current depth)
    float mMaterialThreshold = 0.2f;        //Maximum absolute difference in diffuse material probability
    float mNormalThreshold = 0.6f;          //Cosine of maximum angle between both normals allowed
    uint mBiasCorrectionMode = BiasCorrectionMode::Basic;   //Bias Correction Mode
    bool mUseFinalVisibilityRay = true;         //For optional visibility ray for each reservoir
    bool mUseDiffuseOnlyShading = false;        //Only uses diffuse shading for ReSTIR. Can be used if VBuffer only contains diffuse hits
    bool mUseReducedReservoirFormat = true;    // Full precision = RGBA32_UINT, Reduced = RG32UINT. TargetPdf and M only uses 16 bits in reduced
    bool mBoostSampleTestVisibility = false;    //Extra visibility test for boosting
    ResourceFormat mJacobianResourceFormat = ResourceFormat::R16Float;
    float mSampleRadiusAttenuation = 0.05f;

    //Photon
    bool mPhotonUseAlphaTest = true;
    bool mPhotonAdjustShadingNormal = true;
    float mPhotonRayTMin = 0.02f;
    bool mGenerationDeltaRejection = true;         //Interpret every non delta surface as diffuse
    float mGenerateMinCos = 0.0017f;              //outer 0.1 degree is rejected (generates fireflies)
    bool mCreateFallbackFinalGatherSample = false;  //If sample was invalid, shots another reference sample


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

    //Debug
    bool mPausePhotonReStir = false;       //Stops rendering
    bool mEnableDebug = false;
    bool mCopyLastColorImage = false;
    bool mCopyPixelData = false;
    float mDebugDistanceFalloff = 10.f;
    float mDebugPointRadius = 0.05f;
    uint2 mDebugCurrentClickedPixel = uint2(0, 0);
    std::vector<uint4> mDebugData;

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
    ComputePass::SharedPtr mpDebugPass;                     //For debuging

    //Buffer
    Buffer::SharedPtr mpPhotonLightBuffer[2];
    Texture::SharedPtr mpReservoirBuffer[2];    //Buffers for the reservoir
    Texture::SharedPtr mpReservoirBoostBuffer;   //Buffer for current iteration spatial boosting
    Buffer::SharedPtr mpPhotonLightBoostBuffer; //Photon light buffer for spatial boosting
    Buffer::SharedPtr mpSurfaceBuffer[2];       //Buffer for surface data
    Texture::SharedPtr mpNeighborOffsetBuffer;   //Constant buffer with neighbor offsets
    Texture::SharedPtr mpPrevViewTex;      //If view texture is used, we store the last frame here

    Texture::SharedPtr mpDebugColorCopy;            //Copy of the color buffer
    Buffer::SharedPtr mpDebugInfoBuffer;            //ContainsDebugInfo
    Texture::SharedPtr mpDebugVBuffer;            //Copy of the V-Buffer used for the iteration

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

    RayTraceProgramHelper mGeneratePathSample;     ///<Description for getting the first diffuse hit

    SphereAccelerationStructure mPhotonAS;
};
