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

    /** Prepares the surface info buffer
   */
    void prepareSurfaceBufferPass(RenderContext* pRenderContext, const RenderData& renderData);

    /** Distrubute VPLs
    */
    void distributeVPLsPass(RenderContext* pRenderContext, const RenderData& renderData);

    /** Presample the photon lights
    */
    void presamplePhotonLightsPass(RenderContext* pRenderContext, const RenderData& renderData);

    /** Generate Photon lights
    */
    void generatePhotonsPass(RenderContext* pRenderContext, const RenderData& renderData);

    /** Collects the photons in the vpls
    */
    void collectPhotonsPass(RenderContext* pRenderContext, const RenderData& renderData);

    /** Visibility check in raytracing shader instead of Compute shader
    */
    void candidatesVisibilityCheckPass(RenderContext* pRenderContext, const RenderData& renderData);

    /** Generates the canidates for the pass and stores them inside the reservoir
    */
    void generateCandidatesPass(RenderContext* pRenderContext, const RenderData& renderData);

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

    /** Pass for showing the VPLs 
    */
    void showVPLDebugPass(RenderContext* pRenderContext, const RenderData& renderData);

    /* Fills the neighbor offset buffer with psyeudo random numbers
    */
    void fillNeighborOffsetBuffer(std::vector<int8_t>& buffer);

    /** Copies the photon counter to a uint to show the number in UI
    */
    void copyPhotonCounter(RenderContext* pRenderContext);

    /** Binds all the reservoirs
    */
    void bindReservoirs(ShaderVar& var, uint index , bool bindPrev = true);

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

    //
    //UI
    //
    //Resampling
    uint mResamplingMode = ResamplingMode::NoResampling;        //TODO: Change light settings for other modes
    uint mNumEmissiveCandidates = 32;  //Number of emissive light samples
    uint mTemporalMaxAge = 20;              // Max age of an temporal reservoir
    uint mSpartialSamples = 1;              // Number of spartial samples
    uint mDisocclusionBoostSamples = 2;     // Number of spartial samples if no temporal surface was found
    float mSamplingRadius = 20.f;           //Sampling radius in pixel
    float mRelativeDepthThreshold = 0.1f;   // Realtive Depth threshold (is neighbor 0.1 = 10% as near as the current depth)
    float mNormalThreshold = 0.6f;          //Cosine of maximum angle between both normals allowed
    bool mUseEmissiveTexture = false;        //Use Emissive texture in final shading
    uint mBiasCorrectionMode = BiasCorrectionMode::Basic;   //Bias Correction Mode
    bool mUseFinalVisibilityRay = true;         //For optional visibility ray for each reservoir
    float mGeometryTermBand = 0.0f;     //Rejects samples with a small distance due to infinetly large geometry term (Adds Bias)
    uint2 mPresampledTitleSize = uint2(128, 1024);
    uint2 mPresampledTitleSizeUI = mPresampledTitleSize;
    bool mPresampledTitleSizeChanged = true;
    bool mUsePdfSampling = false;
    bool mUseVisibiltyRayInline = true;         //If true, inline ray tracing is used for the visibility check
    bool mUseDiffuseOnlyShading = false;                //Only uses diffuse shading for ReSTIR. Can be used if VBuffer only contains diffuse hits
    uint mVplMaxReplace = 3072;                 //Maximum number of vpls that can be replaced per frame

    //Photon
    bool mChangePhotonLightBufferSize = false;  //Change max size of photon lights buffer
    uint mNumMaxPhotons = 500000;               //Max number of photon lights per iteration
    uint mNumMaxPhotonsUI = mNumMaxPhotons;
    uint mCurrentPhotonLightsCount = 0;             //Gets data from GPU buffer
    uint mNumDispatchedPhotons = 262144;        //Number of dispatched photons 
    uint mPhotonYExtent = 512;
    uint mPhotonMaxBounces = 10;             //Number of bounces  TODOSplit this up in transmissive specular and diffuse
    float mPhotonRejection = 0.3f;          //Rejection probability
    bool mPhotonUseAlphaTest = true;
    bool mPhotonAdjustShadingNormal = true;
    //VPL
    uint mNumberVPL = 28000;                //Number of VPL lights
    float mVPLCollectionRadius = 0.05f;
    bool mShowVPLs = false;
    bool mShowVPLsUseFlatShading = true;                    //Enable a flat shading for debug vpls 
    float3 mShowVPLsUseFlatShadingColor = float3(0, 1, 0);  //Flat shading color for debug vpl (green is standard)
    float mShowVPLsScalar = 1.f;
    bool mResetVPLs = false;
    bool mDistributeVplUseBsdfSampling = false; //Use Bsdf or cosine sampling for vpl distribution
    uint mVplAgeCapCollect = 40;
    uint mVplEliminationAge = 15;
    uint mVplEliminationMode = VplEliminationMode::Fixed;
    float mVplEliminationVar1 = 0.2f;
    uint mVplUsageFramesUsed = 0;       //Frames used for usage elimination

    bool mDebugColor = false;

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
    ComputePass::SharedPtr mpFillSurfaceInfoPass;               //Fills the surfaceInformation
    ComputePass::SharedPtr mpPresamplePhotonLightsPass;     //Presample the photon lights
    ComputePass::SharedPtr mpGenerateCandidates;            //Generate Candidates Pass
    ComputePass::SharedPtr mpTemporalResampling;            //Temporal Resampling Pass
    ComputePass::SharedPtr mpSpartialResampling;            //Spartial Resampling Pass
    ComputePass::SharedPtr mpSpartioTemporalResampling;     //Spartio Temporal Resampling Pass
    ComputePass::SharedPtr mpFinalShading;                  //Final Shading Pass
    ComputePass::SharedPtr mpShowVPLsCalcAABBsPass;             //Calcs the AABB buffer for showing the vpls
    ComputePass::SharedPtr mpVplFeedbackPass;               //Determines VPLs that can be replaced

    //Buffer
    Buffer::SharedPtr mpVPLBuffer;              //Buffer for the VPLs
    Buffer::SharedPtr mpPhotonLightBuffer[2];
    Texture::SharedPtr mpVPLSurface;            //Surface of a vpl. Used to collect the photons and determine the flux
    Texture::SharedPtr mpVplPdfBuffer;          //Pdf for the pdf
    Texture::SharedPtr mpVPLUsageBuffer;        //Buffer indicates when the VPL was lastly used
    Texture::SharedPtr mpReservoirBuffer[2];    //Buffers for the reservoir
    Buffer::SharedPtr mpSurfaceBuffer[2];       //Buffer for surface data
    Texture::SharedPtr mpNeighborOffsetBuffer;   //Constant buffer with neighbor offsets
    Buffer::SharedPtr mpPhotonAABB;              //Photon AABBs for Acceleration Structure building
    Buffer::SharedPtr mpPhotonData;              //Additional Photon data (flux, dir)
    Texture::SharedPtr mpLightPdfTex;           //1 Channel luminance texture for power presampling
    Buffer::SharedPtr mpPresampledLights; //Presampled Photon lights
    Buffer::SharedPtr mpPhotonCounter;     //Counter for the number of lights
    Buffer::SharedPtr mpPhotonCounterCPU;  //For showing the current number of photons in the UI
    Buffer::SharedPtr mpShowVPLsAABBsBuffer;              //AABB buffer for showing the vpls
    Texture::SharedPtr mpPrevViewTex;                   //If view texture is used, we store the last frame here

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
    RayTraceProgramHelper mDistributeVPlsPass;          ///<Description for the Distribute VPL Pass
    RayTraceProgramHelper mCollectPhotonsPass;          ///<Description for collecting the photons
    RayTraceProgramHelper mVisibilityCheckPass;         ///< Description for the visibility check pass
    RayTraceProgramHelper mVPLDebugPass;                ///<A pass to visualize the VPLs

    SphereAccelerationStructure mPhotonAS;
    SphereAccelerationStructure mVPLDebugAS;
};
