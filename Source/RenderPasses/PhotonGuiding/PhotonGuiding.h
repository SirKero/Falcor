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
#include "Rendering/AccelerationStructure/CustomAccelerationStructure.h"

using namespace Falcor;

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

    // GUI Structs and enum
    enum class RenderMode : uint
    {
        VCM = 0u,
        Grittmann = 1u
    };
    FALCOR_ENUM_INFO(
        RenderMode,
        {{RenderMode::VCM, "VCM"},
        {RenderMode::Grittmann, "Grittmann"}
        }
    );

    enum class DebugTechnique : uint
    {
        LightTrace = 0u,
        NEE = 1u,
        EmissiveHit = 2u,
        PhotonMapper = 3u
    };
    FALCOR_ENUM_INFO(
        DebugTechnique,
        {{DebugTechnique::LightTrace, "LightTrace"},
         {DebugTechnique::NEE, "NEE"},
         {DebugTechnique::EmissiveHit, "EmissiveHit"},
         {DebugTechnique::PhotonMapper, "PhotonMapper"}
    });

private:
    //
    // Functions
    //

    //Prepares Falcors light samplers
    void prepareLightingStructure(RenderContext* pRenderContext);

    //Prepares needed Buffers and Textures and Acceleration Structures
    void prepareResources(RenderContext* pRenderContext, const RenderData& renderData);

    //Prepare some camera data needed for reprojection
    void prepareCameraData();

    // Traces the photons and stores them in the scene
    void tracePhotonPass(RenderContext* pRenderContext, const RenderData& renderData);

    // Traces the camera and collects the photons
    void traceCameraPass(RenderContext* pRenderContext, const RenderData& renderData);

    //Traces the photons and stores them in the scene. Uses VCM MIS weights
    void tracePhotonVCMPass(RenderContext* pRenderContext, const RenderData& renderData);

    //Traces the camera and collects the photons. Uses VCM MIS weights
    void traceCameraVCMPass(RenderContext* pRenderContext, const RenderData& renderData);

    // Handles readback of the photon counter
    void handlePhotonCounter(RenderContext* pRenderContext);

    //Reset Render Passes
    void resetRenderPasses();

    //
    // Pointers
    //
    ref<Scene> mpScene;                     // Scene Pointer
    ref<SampleGenerator> mpSampleGenerator; // GPU Sample Gen
    std::unique_ptr<EmissiveLightSampler> mpEmissiveLightSampler; // Light Sampler
    std::unique_ptr<CustomAccelerationStructure> mpPhotonAS;      // Accel Pointer
    std::unique_ptr<CustomAccelerationStructure> mpPhotonASVCM;      // Accel Pointer

    //
    // Parameters
    //
    uint mFrameCount = 0;
    uint2 mScreenRes = uint2(0, 0);
    bool mResetScreenTex = false;
    bool mOptionsChanged = false;
    uint mNumberLightPaths = 0;
    float mImagePlaneDist = 1.0;
    float mNormalizedPixelArea = 1.0;

    bool mUseVC = true;
    bool mUseVM = true;
    bool mLightTraceOnly = false;

    RenderMode mRenderMode = RenderMode::VCM;

    // Material Settings
    bool mUseLambertianDiffuse = false;         // Enable Lambert Diffuse BRDF instead of Frostbyte
    float mSpecularRoughnessThreshold = 0.08f; // Any material below this is considered specular (currently set to delta)

    //
    // Path Tracer
    //
    uint mPTMaxBounces = 10;

    //
    // Photon Distribution
    //
    uint mPhotonMaxBounces = 10;                    // Number of Photon bounces
    float mGlobalPhotonRejection = 1.0f;            // Probability a global photon is stored
    uint mNumDispatchedPhotons = 2000000;           // Number of Photons dispatched
    uint2 mNumMaxPhotons = uint2(1000000, 300000);   // Size of the photon buffer
    uint2 mNumMaxPhotonsUI = mNumMaxPhotons;        // For UI, as changing happens with a button
    bool mChangePhotonLightBufferSize = true;       // If buffer size has changed
    float mASBuildBufferPhotonOverestimate = 1.15f; // Guard percentage for AS building
    uint2 mCurrentPhotonCount = mNumMaxPhotons;
    float mPhotonRadiusVCM = 0.005f;
    float2 mPhotonRadius = float2(0.020f, 0.005f); // Global/Caustic Radius.

    
    bool mUseDynamicPhotonDispatchCount = true;   // Dynamically change the number of photons to fit the max photon number
    uint mPhotonDynamicDispatchMax = 4000000;     // Max value for dynamically dispatched photons
    float mPhotonDynamicGuardPercentage = 0.08f;  // Determines how much space of the buffer is used to guard against buffer overflows
    float mPhotonDynamicChangePercentage = 0.04f; // The percentage the buffer is increased/decreased per frame

    //
    // Debug
    //

    bool mDebugEnable = false;
    DebugTechnique mDebugTechnique = DebugTechnique::LightTrace;
    int mDebugTechniqueBounce = -1;

    //
    // Resources
    //
    ref<Buffer> mpPhotonAABB[2];    // Photon AABBs for Acceleration Structure building
    ref<Buffer> mpPhotonDataVCM;    // Additional Photon data (flux, dir)
    ref<Buffer> mpPhotonData[2];    // Additional Photon data (flux, dir)
    ref<Buffer> mpPhotonCounter;    // Counter
    ref<Buffer> mpPhotonCounterCPU; // Counter CPU readable
    ref<Texture> mpLightTraceColorSpinlock[3]; //Uint texture for each color used in the spinlock
    ref<Texture> mpDebugTextures[4]; //A debug textures for each bounce
     //
    // Render Passes/Programms
    //
    struct RayTraceProgramHelper
    {
        ref<RtProgram> pProgram;
        ref<RtBindingTable> pBindingTable;
        ref<RtProgramVars> pVars;

        static const RayTraceProgramHelper create()
        {
            RayTraceProgramHelper r;
            r.pProgram = nullptr;
            r.pBindingTable = nullptr;
            r.pVars = nullptr;
            return r;
        }

        void initProgramVars(ref<Device> pDevice, ref<Scene> pScene, ref<SampleGenerator> pSampleGenerator);
    };

    RayTraceProgramHelper mTracePhotonPass;           // Trace Photons
    RayTraceProgramHelper mTraceCameraPass;              // Trace Camera
    RayTraceProgramHelper mTracePhotonVCMPass;         // Trace Photons
    RayTraceProgramHelper mTraceCameraVCMPass;         // Trace Camera
};

FALCOR_ENUM_REGISTER(PhotonGuiding::RenderMode);
FALCOR_ENUM_REGISTER(PhotonGuiding::DebugTechnique);
