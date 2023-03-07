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

class ReStirExp : public RenderPass
{
public:
    using SharedPtr = std::shared_ptr<ReStirExp>;

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
    virtual void setScene(RenderContext* pRenderContext, const Scene::SharedPtr& pScene) override;
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

private:
    //Functions

    ReStirExp() : RenderPass(kInfo) {}

    /** Prepares the samplers etc needed for lighting.
    */
    void prepareLighting(RenderContext* pRenderContext);

    /** Prepare the reservoir buffers
    */
    void prepareBuffers(RenderContext* pRenderContext, const RenderData& renderData);

    /** Update/Fill lights buffer
    */
    void updateLightsBufferPass(RenderContext* pRenderContext, const RenderData& renderData);

    /** Prepares the surface info buffer
   */
   void prepareSurfaceBufferPass(RenderContext* pRenderContext, const RenderData& renderData);

   /**Presample lights with light pdf texture
   */
   void presampleLightsPass(RenderContext* pRenderContext, const RenderData& renderData);

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

    /* Fills the neighbor offset buffer with psyeudo random numbers
    */
    void fillNeighborOffsetBuffer(std::vector<int8_t>& buffer);

    /** Gets PDF texture size. Taken from RTXDI
    */
    void computePdfTextureSize(uint32_t maxItems, uint32_t& outWidth, uint32_t& outHeight, uint32_t& outMipLevels);

    //Constants
    const uint kNumNeighborOffsets = 8192;  //Size of neighbor offset buffer
    const uint2 kPresampledTitleCount = uint2(1,1024);
    const uint2 kPresampledTitleSize = uint2(256, 8192);

    //UI
    uint mResamplingMode = ResamplingMode::SpartioTemporal;
    uint mNumEmissiveCandidates = 32;  //Number of emissive light samples
    uint mTemporalMaxAge = 20;              // Max age of an temporal reservoir
    uint mSpartialSamples = 1;              // Number of spartial samples
    uint mDisocclusionBoostSamples = 2;     // Number of spartial samples if no temporal surface was found
    float mSpartialSamplingRadius = 30.f;   //Spartial Sampling radius in pixel
    float mRelativeDepthThreshold = 0.1f;   // Realtive Depth threshold (is neighbor 0.1 = 10% as near as the current depth)
    float mNormalThreshold = 0.6f;          //Cosine of maximum angle between both normals allowed
    bool mUseEmissiveTexture = false;        //Use Emissive texture in final shading
    uint mBiasCorrectionMode = BiasCorrectionMode::Basic;   //Bias Correction Mode
    bool mUseFinalVisibilityRay = true;         //For optional visibility ray for each reservoir
    uint2 mPresampledTitleSize = uint2(128, 1024);
    uint2 mPresampledTitleSizeUI = mPresampledTitleSize;
    bool mPresampledTitleSizeChanged = true;
    bool mUsePdfSampling;
    bool mUseDiffuseShadingOnly = false;            //Only diffuse is used for shading (If a path traced V-Buffer that stops on diffuse is used)

    
    //Runtime
    bool mReset = true;
    bool mReuploadBuffers = true;
    bool mBiasCorrectionChanged = false;
    uint2 mScreenRes = { 0,0 };
    bool mUpdateRenderSettings = true;
    uint mFrameCount = 0;
    uint mNumLights = 0;
    bool mUpdateLightBuffer = true;
    

    //Falcor Vars
    Scene::SharedPtr mpScene;       //Pointer for scene
    SampleGenerator::SharedPtr mpGenerateSampleGenerator;       //Sample generator for Generate pass

    //Passes
    ComputePass::SharedPtr mpUpdateLightBufferPass;         //Updates the light buffer
    ComputePass::SharedPtr mpFillSurfaceInfoPass;           //Fills the surfaceInformation
    ComputePass::SharedPtr mpPresampleLightsPass;           //Presamples lights
    ComputePass::SharedPtr mpGenerateCandidates;            //Generate Candidates Pass
    ComputePass::SharedPtr mpTemporalResampling;            //Temporal Resampling Pass
    ComputePass::SharedPtr mpSpartialResampling;            //Spartial Resampling Pass
    ComputePass::SharedPtr mpSpartioTemporalResampling;     //Spartio Temporal Resampling Pass
    ComputePass::SharedPtr mpFinalShading;                  //Final Shading Pass

    //Buffer
    Texture::SharedPtr mpReservoirBuffer[2];    //Buffers for the reservoir
    Texture::SharedPtr mpReservoirUVBuffer[2];  //Buffer for the uv component of the reservoir
    Buffer::SharedPtr mpSurfaceBuffer[2];       //Buffer for surface data
    Texture::SharedPtr mpNeighborOffsetBuffer;   //Constant buffer with neighbor offsets
    Texture::SharedPtr mpLightPdfTexture;
    Buffer::SharedPtr mpLightBuffer;
    Buffer::SharedPtr mpPresampledLight;
    Texture::SharedPtr mpPrevViewTexture;       //Previous view Texture used in Temporal and SpartioTemporal resampling
};