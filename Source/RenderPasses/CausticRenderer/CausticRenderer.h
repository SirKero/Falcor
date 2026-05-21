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
#include "Rendering/AccelerationStructure/CustomAccelerationStructure.h"


using namespace Falcor;

class CausticRenderer : public RenderPass
{
public:
    FALCOR_PLUGIN_CLASS(CausticRenderer, "CausticRenderer", "Insert pass description here.");

    static ref<CausticRenderer> create(ref<Device> pDevice, const Properties& props) { return make_ref<CausticRenderer>(pDevice, props); }

    CausticRenderer(ref<Device> pDevice, const Properties& props);

    virtual Properties getProperties() const override;
    virtual RenderPassReflection reflect(const CompileData& compileData) override;
    virtual void compile(RenderContext* pRenderContext, const CompileData& compileData) override {}
    virtual void execute(RenderContext* pRenderContext, const RenderData& renderData) override;
    virtual void renderUI(Gui::Widgets& widget) override;
    virtual void setScene(RenderContext* pRenderContext, const ref<Scene>& pScene) override;
    virtual bool onMouseEvent(const MouseEvent& mouseEvent) override { return false; }
    virtual bool onKeyEvent(const KeyboardEvent& keyEvent) override { return false; }

private:
    /* Resets all render passes
    */
    void resetRenderPasses();

    /* Prepares Resources
    */
    void prepareResources(RenderContext* pRenderContext, const RenderData& renderData);

    /* Trace and backproject Caustics
    */
    void traceCausticsPass(RenderContext* pRenderContext, const RenderData& renderData);

    /* Lighting pass
    */
    void lightingPass(RenderContext* pRenderContext, const RenderData& renderData);

    /* Gets the image plane distance for the current camera
    */
    float getImagePlaneDistance();

    struct Options {
        //Caustic Settings
        uint lightPaths = 1000000;      //Number of light paths generated
        uint lightBufferSize = 1000000; //Size of the buffer
        uint maxPathLength = 32;        //Max Path Length
        uint diffuseBounces = 0;        //How many diffuse bounces are allowed
        float probAnalyticEmissive = 0.5f; //Probablility to generate from analytic / emissive if scene contains both
        float causticRoughnessThreshold = 0.25f;    //Roughness threshold, when a surface is considered specular

        //Caustic Photon Settings
        bool photonUseAdaptiveRadius = true;            //Uses a photon radius that is dependent on the (linear) distance to the camera
        float photonAdaptiveRadius = 2.f;               //Pixel Size scale for adptive radius
        float photonRadius = 0.002f;   // Fixed World Space Radius
        float photonASBuildBufferOverestimate = 1.15f; // Guard percentage for AS building (Uses (delayed) CPU Photon Counter to estimate)

        //Direct Light
        bool evalAllAnalytic = true;    //Evals all analytic lights, else a random one in choosen
        float ambient = 0.2f;            //Ambient Factor
        float envMapStrength = 1.f;     //Env Map Strength
        float emissiveStrength = 1.f;   //Brightness factor for directly visible emissive materials
    };

    static const uint kCounterCount = 1;
    static const uint kCausticCounterSmoothIntervall = 512; //Smooths over 512 values

    //
    // Pointers
    //
    ref<Scene> mpScene;                     // Scene Pointer
    ref<SampleGenerator> mpSampleGenerator; // GPU Sample Gen
    std::unique_ptr<CustomAccelerationStructure> mpPhotonAS;      // Photon Acceleration Structure

    //Light Sampler
    std::unique_ptr<EmissiveLightSampler> mpEmissiveLightSampler; // Light Sampler
    EmissiveLightSamplerType mEmissiveLightSamplerType = EmissiveLightSamplerType::LightBVH;
    LightBVHSampler::Options mLightBVHOptions;
    bool mRebuildLightSampler = false;

    uint mFrameCount = 0;           //Frame Count for the sample generator
    uint2 mScreenRes = uint2(0);    //Frame Count for the sample generator
    bool mOptionsChanged = false;   //Options flag
    Options mOptions;   

    bool mResetCausticBuffers = false;  //Reset Caustic buffers
    bool mSceneHasMixedLights = true;  //If scene has analytic and emissive

    uint mCausticsStored = 0;       //Number of caustic stored
    double mCausticStoredIntervallCounter = 0.0;    //Smooth counter data.
    uint mCausticStoredFrameCount = 0;              //Number of frames used for the smooth

    //Resources
    ref<Texture> mpCausticHead;         //Head buffer, containing the first index of the linked list
    ref<Buffer> mpCausticsData;         //Contains all backprojected caustic data
    ref<Buffer> mpCounter;              //Global counter buffer
    ref<Buffer> mpCounterCPU;           //Global counter buffer CPU read copy

    ref<Buffer> mpCausticAABB;          //For Acceleration Structure Collection

    //
    // Render Passes/Programs
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

    RayTraceProgramHelper mCausticTracePass;       //Trace light paths

    ref<ComputePass> mpLightingPass;           //Calculates direct light

};
