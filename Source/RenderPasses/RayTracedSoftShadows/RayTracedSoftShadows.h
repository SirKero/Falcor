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
 //Light samplers
#include "Rendering/Lights/LightBVHSampler.h"
#include "Rendering/Lights/EmissivePowerSampler.h"
#include "Rendering/Lights/EmissiveUniformSampler.h"

using namespace Falcor;

class RayTracedSoftShadows : public RenderPass
{
public:
    FALCOR_PLUGIN_CLASS(RayTracedSoftShadows, "RayTracedSoftShadows", "A pass for tracing soft shadows");

    static ref<RayTracedSoftShadows> create(ref<Device> pDevice, const Properties& props) { return make_ref<RayTracedSoftShadows>(pDevice, props); }

    RayTracedSoftShadows(ref<Device> pDevice, const Properties& props);

    virtual Properties getProperties() const override;
    virtual RenderPassReflection reflect(const CompileData& compileData) override;
    virtual void compile(RenderContext* pRenderContext, const CompileData& compileData) override {}
    virtual void execute(RenderContext* pRenderContext, const RenderData& renderData) override;
    virtual void renderUI(Gui::Widgets& widget) override;
    virtual void setScene(RenderContext* pRenderContext, const ref<Scene>& pScene) override;
    virtual bool onMouseEvent(const MouseEvent& mouseEvent) override { return false; }
    virtual bool onKeyEvent(const KeyboardEvent& keyEvent) override { return false; }

private:
    //Prepare light sampler for emissive lights
    bool prepareLighting(RenderContext* pRenderContext);
    //Resets the light sampler
    void resetLighting();
    //Shade current frame
    void shade(RenderContext* pRenderContext, const RenderData& renderData);
    //Load blue noise textures
    void initBlueNoiseTextures();

    // Internal state
    ref<Scene> mpScene;                     ///< Current scene.
    ref<SampleGenerator> mpSampleGenerator; ///< GPU sample generator.
    uint mFrameCount = 0;
    bool mRecompile = false;                ///<Recompile Shaders

     // LightSampler
    bool mRebuildLightSampler = false;
    EmissiveLightSamplerType mEmissiveType = EmissiveLightSamplerType::Uniform;
    std::unique_ptr<EmissiveLightSampler> mpEmissiveLightSampler; // Light Sampler
    LightBVHSampler::Options mLightBVHOptions;

    // Configuration
    uint mRenderMode = 0;
    bool mOptionsChanged = false;        //<True if settings changed
    bool mUseAlphaTest = true; //< Alpha Test for ray tracing
    uint mSPP = 1;             //<Shadow Samples per pixel
    bool mClearDemodulationTextures = false; //< Clear textures when demodulation is turned on/off
    float mNRDLightSize = 1.0f; //Approximated light size

    float mAmbientFactor = 0.01f; //<Ambient light factor
    float mEnvMapFactor = 0.3f;  //< Env Map factor
    float mEmissiveFactor = 2.f; //< Emissive Factor
    bool mUseSpatioTemporalBlueNoise = true;

    //Directional Soft Light
    float mSunAngularDiameter = 0.553f;
    float3 mSunDir = float3(0, -1, 0);  //Stored sun direction
    float3 mSunDirT = mSunDir;          //Tangent for sun direction
    float3 mSunDirB = mSunDir;          //Bitangent for sun direction

    //Spot Lights (only used when there is 1 spotlight present)
    float3 mSpotDir = float3(0, -1, 0); // Stored spot direction
    float3 mSpotDirT = mSpotDir;        // Tangent for spot direction
    float3 mSpotDirB = mSpotDir;        // Bitangent for spot direction

    //Textures and Buffers
    std::vector < ref<Texture>> mBlueNoiseTextures; //Blue noise for random light direction

    // Ray tracing program.
    struct
    {
        ref<RtProgram> pProgram;
        ref<RtBindingTable> pBindingTable;
        ref<RtProgramVars> pVars;
    } mSoftShadowPip;
};
