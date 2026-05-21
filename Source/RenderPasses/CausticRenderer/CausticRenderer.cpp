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
#include "CausticRenderer.h"
#include "Utils/Math/FalcorMath.h"
#include "RenderGraph/RenderPassHelpers.h"
#include "RenderGraph/RenderPassStandardFlags.h"

#include "Rendering/Lights/EmissiveUniformSampler.h"
#include "Rendering/Lights/EmissivePowerSampler.h"
#include <bit>

namespace
{
    //Shader
    const std::string kShaderFolder = "RenderPasses/CausticRenderer/";
    const std::string kShaderTraceCaustics = kShaderFolder + "TraceCaustics.rt.slang";
    const std::string kShaderLighting = kShaderFolder + "Lighting.cs.slang";

    const std::string kShaderModel = "6_5";

    // Render Pass inputs and outputs
    const std::string kInputVBuffer = "vbuffer";
    const std::string kInputView = "view";

    const Falcor::ChannelList kInputChannels{
        {kInputVBuffer, "gVBuffer", "Visibility buffer in packed format"},
        {kInputView, "gView", "View Vector from camera perspective"},
    };

    
    //Outputs
    const std::string kOutputColor = "color";
    const std::string kOutputDebug = "debug";
    const Falcor::ChannelList kOutputChannels
    {
        {kOutputColor, "gOutColor", "HDR output color", false /*optional*/, ResourceFormat::RGBA32Float},
        {kOutputDebug, "gOutDebug", "Debug", true /*optional*/, ResourceFormat::RGBA32Float},
    };

};

extern "C" FALCOR_API_EXPORT void registerPlugin(Falcor::PluginRegistry& registry)
{
    registry.registerClass<RenderPass, CausticRenderer>();
}

CausticRenderer::CausticRenderer(ref<Device> pDevice, const Properties& props)
    : RenderPass(pDevice)
{
    // Create sample generator.
    mpSampleGenerator = SampleGenerator::create(mpDevice, SAMPLE_GENERATOR_UNIFORM);
}

Properties CausticRenderer::getProperties() const
{
    return {};
}

RenderPassReflection CausticRenderer::reflect(const CompileData& compileData)
{
    //In- and Output Textures
    RenderPassReflection reflector;
    addRenderPassInputs(reflector, kInputChannels);
    addRenderPassOutputs(reflector, kOutputChannels);
    return reflector;
}

void CausticRenderer::execute(RenderContext* pRenderContext, const RenderData& renderData)
{
    //No Scene
    if(!mpScene)
        return;

    //Add refresh flag if options changed
    auto& dict = renderData.getDictionary();
    auto flags = dict.getValue(kRenderPassRefreshFlags, RenderPassRefreshFlags::None);
    if (mOptionsChanged)
    {
        dict[Falcor::kRenderPassRefreshFlags] = flags | Falcor::RenderPassRefreshFlags::RenderOptionsChanged;
        mOptionsChanged = false;
    }

    //Store current screen resolution
    if (any(mScreenRes != renderData.getDefaultTextureDims())) {
        mResetCausticBuffers = true;
        mScreenRes = renderData.getDefaultTextureDims();
    }

    prepareResources(pRenderContext, renderData);

    traceCausticsPass(pRenderContext, renderData);

    lightingPass(pRenderContext, renderData);

    mFrameCount++;

    //Clear Counter
    pRenderContext->clearUAV(mpCounter->getUAV(0).get(), uint4(0));
}

void CausticRenderer::renderUI(Gui::Widgets& widget)
{
    bool changed = false;

    if(auto group = widget.group("Caustic Settings"))
    {
        changed |= group.var("Light Paths", mOptions.lightPaths, 32u, UINT_MAX, 1u);
        mResetCausticBuffers |= group.var("Caustic Buffer Size", mOptions.lightBufferSize, 32u, UINT_MAX, 1u);
        group.text("Stored Caustics: " + std::to_string(mCausticsStored));

        group.var("Max Path Length", mOptions.maxPathLength, 0u, 1024u, 1u);
        group.var("Max Diffuse Bounces", mOptions.diffuseBounces, 0u, 1024u, 1u);
        group.var("Roughness Threshold", mOptions.causticRoughnessThreshold, 0.f, 0.99f, 0.0001f);
        group.tooltip("All surfaces below the threshold can create caustics. The caustics are only stored on diffuse surfaces");
        if(mSceneHasMixedLights)
            group.var("Probability analytic/emissive", mOptions.probAnalyticEmissive, 0.f, 1.f, 0.0001f);

        group.checkbox("Use Adaptive Radius", mOptions.photonUseAdaptiveRadius);
        if(mOptions.photonUseAdaptiveRadius)
        {
            changed |= group.var("Adaptive Scale (Global/Caustic)", mOptions.photonAdaptiveRadius, 0.f, FLT_MAX, 0.0001f);
        }
        else
        {
            changed |= group.var("Radius (Global/Caustic)", mOptions.photonRadius, 0.f, FLT_MAX, 0.000001f, false, "%.6f");
        }
        group.var("Acceleration Structure Build Overestimate", mOptions.photonASBuildBufferOverestimate, 1.f, FLT_MAX, 0.001f);
        group.tooltip("Percentage the CPU photon count value (which is delayed by 1-3 frames) is overestimated to improve acceleration structure build time.");
    }

    if(auto group = widget.group("Direct Light Settings"))
    {
        changed |= group.checkbox("Eval all Analytic Lights", mOptions.evalAllAnalytic);

        changed |= group.var("Ambient", mOptions.ambient, 0.f, FLT_MAX, 0.001f);
        changed |= group.var("Emissive Strength", mOptions.emissiveStrength, 0.f, FLT_MAX, 0.001f);
        changed |= group.var("Env Map Strength", mOptions.envMapStrength, 0.f, FLT_MAX, 0.001f);
    }

    mOptionsChanged = changed;
}

void CausticRenderer::setScene(RenderContext* pRenderContext, const ref<Scene>& pScene)
{
    if (pScene) {
        mpScene = pScene;
        resetRenderPasses();
    }
}

void CausticRenderer::resetRenderPasses()
{
    mpLightingPass.reset();
    mCausticTracePass = RayTraceProgramHelper::create();
}

void CausticRenderer::prepareResources(RenderContext* pRenderContext, const RenderData& renderData)
{
    //Reset Textures
    if(mResetCausticBuffers)
    {
        mpCausticHead.reset();
        mpCausticsData.reset();
        mpCausticAABB.reset();
        mpPhotonAS.reset();
        mResetCausticBuffers = false;
    }

    //Create Textures/Buffers
    if (!mpCausticHead)
    {
        mpCausticHead = Texture::create2D(mpDevice, mScreenRes.x, mScreenRes.y, ResourceFormat::R32Int, 1u, 1u,
            nullptr, ResourceBindFlags::UnorderedAccess | ResourceBindFlags::ShaderResource);
        mpCausticHead->setName("CausticRenderer:CausticHead");
        //Clear Head buffer (fill with -1, however clear uav is only overloaded with uint4)
        int32_t negOne = -1;
        uint clearVal = 0;
        std::memcpy(&clearVal, &negOne, sizeof(negOne));
        pRenderContext->clearUAV(mpCausticHead->getUAV(0).get(), uint4(clearVal));
    }

    if (!mpCausticsData)
    {
        mpCausticsData = Buffer::createStructured(mpDevice, sizeof(uint) * 12, mOptions.lightBufferSize,
            ResourceBindFlags::UnorderedAccess | ResourceBindFlags::ShaderResource,
            Buffer::CpuAccess::None, nullptr, false);
        mpCausticsData->setName("CausticRenderer:CausticData");
    }

    if(!mpCausticAABB)
    {
        mpCausticAABB = Buffer::createStructured(mpDevice, sizeof(AABB), mOptions.lightBufferSize,
            ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess,
            Buffer::CpuAccess::None, nullptr, false);
        mpCausticAABB->setName("CausticRenderer:CausticAABB");
    }

    if (!mpCounter)
    {
        mpCounter = Buffer::createStructured(mpDevice, sizeof(uint), kCounterCount,
            ResourceBindFlags::UnorderedAccess | ResourceBindFlags::ShaderResource,
            Buffer::CpuAccess::None, nullptr, false);
        mpCounter->setName("CausticRenderer:GlobalCounter");
    }

    if (!mpCounterCPU)
    {
        mpCounterCPU = Buffer::createStructured(mpDevice, sizeof(uint), kCounterCount,
            ResourceBindFlags::None,
            Buffer::CpuAccess::Read, nullptr, false);
        mpCounterCPU->setName("CausticRenderer:GlobalCounterCPURead");
    }

    // Create the Photon Acceleration Structure
    if (!mpPhotonAS)
    {
        mpPhotonAS = std::make_unique<CustomAccelerationStructure>(
            mpDevice, mOptions.lightBufferSize, mpCausticAABB->getGpuAddress(), CustomAccelerationStructure::BuildMode::FastBuild,
            CustomAccelerationStructure::UpdateMode::None
        );
    }

    //Light Sampler
    auto& pLights = mpScene->getLightCollection(pRenderContext); //Make sure lights are up to date
    bool emissiveUsed = mpScene->useEmissiveLights();
    bool analyticUsed = mpScene->useAnalyticLights();
    mSceneHasMixedLights = emissiveUsed && analyticUsed;

    if (emissiveUsed)
    {
        if (!mpEmissiveLightSampler || mRebuildLightSampler)
        {
            resetRenderPasses();
            FALCOR_ASSERT(pLights && pLights->getActiveLightCount(pRenderContext) > 0);
            switch (mEmissiveLightSamplerType)
            {
            case Falcor::EmissiveLightSamplerType::Uniform:
                mpEmissiveLightSampler = std::make_unique<EmissiveUniformSampler>(pRenderContext, mpScene);
                break;
            case Falcor::EmissiveLightSamplerType::LightBVH:
                mpEmissiveLightSampler = std::make_unique<LightBVHSampler>(pRenderContext, mpScene, mLightBVHOptions);
                break;
            case Falcor::EmissiveLightSamplerType::Power:
                mpEmissiveLightSampler = std::make_unique<EmissivePowerSampler>(pRenderContext, mpScene);
                break;
            case Falcor::EmissiveLightSamplerType::Null:
            default:
                FALCOR_UNREACHABLE();
                break;
            }

            mRebuildLightSampler = false;
        }
    }
    else
    {
        if (mpEmissiveLightSampler)
        {
            if (auto lightBVHSampler = dynamic_cast<LightBVHSampler*>(mpEmissiveLightSampler.get()))
            {
                mLightBVHOptions = lightBVHSampler->getOptions();
            }
            mpEmissiveLightSampler = nullptr;
            resetRenderPasses();
        }
    }
     if (mpEmissiveLightSampler)
        mpEmissiveLightSampler->update(pRenderContext);

}

void CausticRenderer::traceCausticsPass(RenderContext* pRenderContext, const RenderData& renderData)
{
    FALCOR_PROFILE(pRenderContext, "TraceCaustics");

    //Init Shader
    if (!mCausticTracePass.pProgram)
    {
         RtProgram::Desc desc;
        desc.addShaderModules(mpScene->getShaderModules());
        desc.addShaderLibrary(kShaderTraceCaustics);
        desc.setMaxPayloadSize(sizeof(uint) * 4);
        desc.setMaxAttributeSize(mpScene->getRaytracingMaxAttributeSize());
        desc.setMaxTraceRecursionDepth(1);
        if (!mpScene->hasProceduralGeometry())
            desc.setPipelineFlags(RtPipelineFlags::SkipProceduralPrimitives);

        mCausticTracePass.pBindingTable = RtBindingTable::create(1, 1, mpScene->getGeometryCount());
        auto& sbt = mCausticTracePass.pBindingTable;
        sbt->setRayGen(desc.addRayGen("rayGen", mpScene->getTypeConformances()));
        sbt->setMiss(0, desc.addMiss("miss"));

        if (mpScene->hasGeometryType(Scene::GeometryType::TriangleMesh))
        {
            sbt->setHitGroup(0, mpScene->getGeometryIDs(Scene::GeometryType::TriangleMesh), desc.addHitGroup("closestHit", "anyHit"));
        }
        DefineList defines;
        defines.add(mpScene->getSceneDefines());
        defines.add("USE_ADAPTIVE_PHOTON_RADIUS", mOptions.photonUseAdaptiveRadius ? "1" : "0");

        mCausticTracePass.pProgram = RtProgram::create(mpDevice, desc, defines);
    }

    //Runtime defines
    mCausticTracePass.pProgram->addDefine("USE_ADAPTIVE_PHOTON_RADIUS", mOptions.photonUseAdaptiveRadius ? "1" : "0");

    // Program Vars
    if (!mCausticTracePass.pVars)
        mCausticTracePass.initProgramVars(mpDevice, mpScene, mpSampleGenerator);

    FALCOR_ASSERT(mCausticTracePass.pVars);
    auto var = mCausticTracePass.pVars->getRootVar();
    mpScene->setRaytracingShaderData(pRenderContext, var);

    uint lightPathsSq = static_cast<uint>(std::floor(std::sqrt(mOptions.lightPaths)));
    uint3 dispatchDims = uint3(lightPathsSq, lightPathsSq, 1u);

    //Probablity to generate a emissive light path
    float emissiveLightProb = mSceneHasMixedLights ? mOptions.probAnalyticEmissive : mpScene->useAnalyticLights() ? 0.f : 1.f;

        //Approximated pixel diagonal at length 1 for adaptive photon radius
    float approxPixelDiagonal = 0.f;
    if (mOptions.photonUseAdaptiveRadius)
    {
        // Update Image plane distance
        auto& cameraData = mpScene->getCamera()->getData();
        // Get normalized pixel area
        float h = cameraData.frameHeight / cameraData.focalLength; //Normalized Frame height
        float w = h * cameraData.aspectRatio;
        float wPix = w / mScreenRes.x;
        float hPix = h / mScreenRes.y;

        approxPixelDiagonal = sqrt((wPix * wPix) + (hPix * hPix));
    }

    var["CB"]["gFrameCount"] = mFrameCount;
    var["CB"]["gLightPaths"] = dispatchDims.x * dispatchDims.y;
    var["CB"]["gRoughnessThreshold"] = mOptions.causticRoughnessThreshold;
    var["CB"]["gEmissiveLightProb"] = emissiveLightProb;
    var["CB"]["gMaxPathLength"] = mOptions.maxPathLength;
    var["CB"]["gDiffuseBounces"] = mOptions.diffuseBounces;
    var["CB"]["gScreenDimensions"] = mScreenRes;

    var["CB"]["gPhotonRadius"] = mOptions.photonUseAdaptiveRadius ? mOptions.photonAdaptiveRadius : mOptions.photonRadius;
    var["CB"]["gNormalizedPixelDiagonal"] = approxPixelDiagonal;

    var["gCausticHead"] = mpCausticHead;
    var["gCausticData"] = mpCausticsData;
    var["gCausticAABB"] = mpCausticAABB;
    var["gCounter"] = mpCounter;

    mpScene->raytrace(pRenderContext, mCausticTracePass.pProgram.get(), mCausticTracePass.pVars, dispatchDims);

    pRenderContext->uavBarrier(mpCausticHead.get());

    //
    //Build the AS for that frame
    //

    //Clear values after the counter
    mpPhotonAS->clearAABBBuffers(pRenderContext, mpCausticAABB, true, mpCounter); //Clears unused slots (Works as counter uses slot 0)

    // Copy the PhotonCounter to a CPU Buffer (asynchronous, read GPU value can be a couple of frames old)
    pRenderContext->copyBufferRegion(mpCounterCPU.get(), 0, mpCounter.get(), 0, sizeof(uint));
    void* data = mpCounterCPU->map(Buffer::MapType::Read);
    std::memcpy(&mCausticsStored, data, sizeof(uint));
    mpCounterCPU->unmap();
        
    //Build acceleration structure
    uint currentPhotons = mFrameCount > 0 ? uint(mCausticsStored * mOptions.photonASBuildBufferOverestimate) : mOptions.lightBufferSize;
    uint photonBuildSize = std::min(mOptions.lightBufferSize, currentPhotons);
    mpPhotonAS->update(pRenderContext, photonBuildSize);
}

void CausticRenderer::lightingPass(RenderContext* pRenderContext, const RenderData& renderData)
{
    FALCOR_PROFILE(pRenderContext, "Lighting");

    auto getRuntimeDefines = [&]() {
        DefineList defines;
        defines.add("USE_ENV_BACKROUND", mpScene->useEnvBackground() ? "1" : "0");
        defines.add("EVAL_ALL_ANALYTIC", mOptions.evalAllAnalytic ? "1" : "0");
        defines.add("USE_EMISSIVE_LIGHT", mpScene->useEmissiveLights() ? "1" : "0");
        return defines;
    };

    if (!mpLightingPass)
    {
        Program::Desc desc;
        desc.addShaderModules(mpScene->getShaderModules());
        desc.addShaderLibrary(kShaderLighting).csEntry("main").setShaderModel(kShaderModel);
        desc.addTypeConformances(mpScene->getTypeConformances());

        DefineList defines;
        defines.add(mpScene->getSceneDefines());
        defines.add(mpSampleGenerator->getDefines());
        defines.add(getRuntimeDefines());
        if(mpEmissiveLightSampler)
            defines.add(mpEmissiveLightSampler->getDefines());
       
        mpLightingPass = ComputePass::create(mpDevice, desc, defines, true);
    }

    //Defines
    mpLightingPass->getProgram()->addDefines(getRuntimeDefines());

    // Set variables
    auto var = mpLightingPass->getRootVar();
    mpScene->setRaytracingShaderData(pRenderContext, var); // Set scene data
    mpSampleGenerator->setShaderData(var);                    // Sample generator
    if(mpEmissiveLightSampler)
        mpEmissiveLightSampler->setShaderData(var["Light"]["gEmissiveSampler"]);

    //Constant Buffer
    var["CB"]["gFrameCount"] = mFrameCount;
    var["CB"]["gFrameDim"] = mScreenRes;
    var["CB"]["gAmbient"] = mOptions.ambient;
    var["CB"]["gEmissiveStrength"] = mOptions.emissiveStrength;
    var["CB"]["gEnvMapStrength"] = mOptions.envMapStrength;
    var["CB"]["gImagePlaneDist"] = getImagePlaneDistance();
    auto& cameraData = mpScene->getCamera()->getData();
    var["CB"]["gFovY"] = focalLengthToFovY(cameraData.focalLength, cameraData.frameHeight);

    //Input
    mpPhotonAS->bindTlas(var, "gPhotonAS");
    var["gVBuffer"] = renderData[kInputVBuffer]->asTexture();
    var["gView"] = renderData[kInputView]->asTexture();

    var["gCausticHead"] = mpCausticHead;
    var["gCausticData"] = mpCausticsData;
    var["gCausticAABB"] = mpCausticAABB;

    var["gOutColor"] = renderData[kOutputColor]->asTexture();

     // Execute
    const uint2 targetDim = renderData.getDefaultTextureDims();
    FALCOR_ASSERT(targetDim.x > 0 && targetDim.y > 0);
    mpLightingPass->execute(pRenderContext, uint3(targetDim, 1));
}

float CausticRenderer::getImagePlaneDistance()
{
    auto& cameraData = mpScene->getCamera()->getData();
    float fovY = focalLengthToFovY(cameraData.focalLength, cameraData.frameHeight);

    //This should be right
    //const float tanHalfAngle = std::tan(fovY / 2.f); 
    //return mScreenRes.x / (2.f * tanHalfAngle);

    float h = tan(fovY / 2.f) * 2.f;
    float w = h * cameraData.aspectRatio;
    float wPix = w / mScreenRes.x;
    float hPix = h / mScreenRes.y;

    return wPix * hPix;

    //
    /*
    float h = tan(fovY / 2.f) * 2.f;
    float w = h * cameraData.aspectRatio;
    float wPix =  mScreenRes.x / h;
    float hPix = mScreenRes.y / w;

    return (hPix + wPix);
    */

    //But this is right
    //const float tanHalfAngle = std::tan(fovY / 2.f) / M_PI_2; //The PI/2 is a bit magic
    //const float tanHalfAngle = (0.5f*  cameraData.frameHeight) / cameraData.focalLength;
    //return mScreenRes.x / (tanHalfAngle);
}

void CausticRenderer::RayTraceProgramHelper::initProgramVars(ref<Device> pDevice, ref<Scene> pScene, ref<SampleGenerator> pSampleGenerator)
{
    FALCOR_ASSERT(pProgram);

    // Configure program.
    pProgram->addDefines(pSampleGenerator->getDefines());
    pProgram->setTypeConformances(pScene->getTypeConformances());
    // Create program variables for the current program.
    // This may trigger shader compilation. If it fails, throw an exception to abort rendering.
    pVars = RtProgramVars::create(pDevice, pProgram, pBindingTable);

    // Bind utility classes into shared data.
    auto var = pVars->getRootVar();
    pSampleGenerator->setShaderData(var);
}
