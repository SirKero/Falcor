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
#include "ReducedVCM.h"
#include "Utils/Math/FalcorMath.h"
#include "RenderGraph/RenderPassHelpers.h"
#include "RenderGraph/RenderPassStandardFlags.h"

#include "Rendering/Lights/EmissiveUniformSampler.h"

namespace
{
// Shader
const std::string kShaderFolder = "RenderPasses/ReducedVCM/";
const std::string kShaderTracePhotonGrittmann = kShaderFolder + "TracePhotonGrittmannV2.rt.slang";
const std::string kShaderTracePhotonVCM = kShaderFolder + "TracePhotonVCM.rt.slang";
const std::string kShaderTraceCameraGrittmann = kShaderFolder + "TraceCameraGrittmannV2.rt.slang";
const std::string kShaderTraceCameraVCM = kShaderFolder + "TraceCameraVCM.rt.slang";

// Input Textures
const std::string kInputVBuffer = "VBuffer";
const std::string kInputView = "View";

const Falcor::ChannelList kInputChannels{
    {kInputVBuffer, "gVBuffer", "Visibility buffer in packed format"},
    {kInputView, "gView", "View Vector"},
};

// Output textures
const std::string kOutputColor = "ColorOut";
const Falcor::ChannelList kOutputChannels{{kOutputColor, "gOutColor", "HDR output color", false /*optional*/, ResourceFormat::RGBA32Float}};

} // namespace

extern "C" FALCOR_API_EXPORT void registerPlugin(Falcor::PluginRegistry& registry)
{
    registry.registerClass<RenderPass, ReducedVCM>();
}

ReducedVCM::ReducedVCM(ref<Device> pDevice, const Properties& props) : RenderPass(pDevice)
{
    // Create sample generator.
    mpSampleGenerator = SampleGenerator::create(mpDevice, SAMPLE_GENERATOR_UNIFORM);
    FALCOR_ASSERT(mpSampleGenerator);
}

Properties ReducedVCM::getProperties() const
{
    return {};
}

RenderPassReflection ReducedVCM::reflect(const CompileData& compileData)
{
    // Render Pass In and Output textures
    RenderPassReflection reflector;
    addRenderPassInputs(reflector, kInputChannels);
    addRenderPassOutputs(reflector, kOutputChannels);
    return reflector;
}

void ReducedVCM::setScene(RenderContext* pRenderContext, const ref<Scene>& pScene)
{
    // Reset scene
    mpScene.reset();
    resetRenderPasses();

    if (pScene)
    {
        mpScene = pScene;
    }
}

void ReducedVCM::execute(RenderContext* pRenderContext, const RenderData& renderData)
{
    if (!mpScene)
        return;

    // Add refresh flag if options changed
    auto& dict = renderData.getDictionary();
    auto flags = dict.getValue(kRenderPassRefreshFlags, RenderPassRefreshFlags::None);
    if (mOptionsChanged)
    {
        dict[Falcor::kRenderPassRefreshFlags] = flags | Falcor::RenderPassRefreshFlags::RenderOptionsChanged;
        mOptionsChanged = false;
    }

    // Prepare needed Falcor helpers and Buffers/Textures
    prepareLightingStructure(pRenderContext);

    // Prepare Textures and Buffers
    prepareResources(pRenderContext, renderData);

    prepareCameraData();

    if (mRenderMode == RenderMode::Grittmann)
    {
        tracePhotonGrittmannPass(pRenderContext, renderData);
        traceCameraGrittmannPass(pRenderContext, renderData);
    }
    else if (mRenderMode == RenderMode::VCM)
    {
        tracePhotonVCMPass(pRenderContext, renderData);
        traceCameraVCMPass(pRenderContext, renderData);
    }

    mFrameCount++;
}

void ReducedVCM::renderUI(Gui::Widgets& widget)
{
    bool changed = false;
    changed |= widget.dropdown("RenderMode", mRenderMode);
    widget.tooltip(
        "VCM: Default VCM without bi-directional connections. \n "
        "Grittmann: Further reduced VCM version where photon mapping is only used at the second bounce."
    );

    // if (mRenderMode == RenderMode::VCM)
    {
        changed |= widget.checkbox("UseVC", mUseVC);
        changed |= widget.checkbox("UseVM", mUseVM);
        changed |= widget.checkbox("LightTraceOnly", mLightTraceOnly);

        if (mLightTraceOnly)
        {
            mUseVM = false;
            mUseVC = true;
        }
    }

    if (auto group = widget.group("Photon Options"))
    {
        if (mUseDynamicPhotonDispatchCount)
        {
            group.text("Dispatched Photons: " + std::to_string(mNumDispatchedPhotons));
        }
        else
        {
            group.var("Dispatched Photons", mNumDispatchedPhotons, 1024u, 67108864u, 1u); // Max is 8192^2
        }

        group.text("Global Photons: " + std::to_string(mCurrentPhotonCount) + " / " + std::to_string(mNumMaxPhotons));

        group.text("Photon Buffer Size:");
        group.indent(10.f);
        group.var(" ##MaxPhotonUI", mNumMaxPhotonsUI, 100u, 100000000u, 100);
        group.tooltip("First -> Global, Second -> Caustic");
        mChangePhotonLightBufferSize = group.button("Apply", true);
        group.indent(-10.f);

        changed |= group.checkbox("Enable dynamic photon dispatch", mUseDynamicPhotonDispatchCount);
        group.tooltip("Changed the number of dispatched photons dynamically. Tries to fill the photon buffer");
        if (mUseDynamicPhotonDispatchCount)
        {
            if (auto groupDynChange = group.group("DynamicDispatchOptions"))
            {
                changed |= groupDynChange.var("Max dispatched", mPhotonDynamicDispatchMax, 1024u, 67108864u);
                changed |= groupDynChange.var("Guard Percentage", mPhotonDynamicGuardPercentage, 0.0f, 1.f, 0.001f);
                groupDynChange.tooltip(
                    "If current fill rate is under PhotonBufferSize * (1-pGuard), the values are accepted. Reduces the changes "
                    "every frame"
                );
                changed |= groupDynChange.var("Percentage Change", mPhotonDynamicChangePercentage, 0.01f, 10.f, 0.01f);
                groupDynChange.tooltip(
                    "Increase/Decrease percentage from the Buffer Size. With current value a increase/decrease of :" +
                    std::to_string(mPhotonDynamicChangePercentage * mNumMaxPhotons) + "is expected"
                );
            }
        }

        changed |= group.var("Global photon store probability", mGlobalPhotonRejection, 0.f, 1.f, 0.0001f);
        group.tooltip("Probability a photon light is stored on diffuse hit. Flux is scaled up appropriately");
        changed |= group.var("Max Bounces", mPhotonMaxBounces, 0u, 256u);

        changed |= group.var("Photon Radius", mPhotonRadiusVCM, 0.f, FLT_MAX, 1e-7f, false, "%.7f");
    }

    if (auto group = widget.group("Path Tracer Options"))
    {
        changed |= group.var("Bounces", mPTMaxBounces, 0u, 256u, 1u);
    }

    if (auto group = widget.group("Material Options"))
    {
        changed |= group.var("Roughness Threshold", mSpecularRoughnessThreshold, 0.f, 1.f);
        group.tooltip("Threshold when a surface is handled as delta");
        changed |= group.checkbox("Use Diffuse Lambert BRDF", mUseLambertianDiffuse);
        group.tooltip("Enables Lambertian Diffuse BRDS. If disabled the Frostbyte diffuse BRDF (Falcor default) is used");
    }

    if (auto group = widget.group("Debug"))
    {
        changed |= group.checkbox("Enable", mDebugEnable);
        if (mDebugEnable)
        {
            changed |= group.dropdown("Technique", mDebugTechnique);
            changed |= group.slider("Bounce", mDebugTechniqueBounce, -1, int(mPTMaxBounces) + 1);
        }
    }

    mOptionsChanged = changed;
}

void ReducedVCM::prepareLightingStructure(RenderContext* pRenderContext)
{
    // Make sure that the emissive light is up to date
    auto& pLights = mpScene->getLightCollection(pRenderContext);

    bool emissiveUsed = mpScene->useEmissiveLights();
    bool analyticUsed = mpScene->useAnalyticLights();

    // mHasLights = analyticUsed || emissiveUsed;
    // mHasAnalyticLights = analyticUsed;
    // mMixedLights = emissiveUsed && analyticUsed;

    if (emissiveUsed)
    {
        if (!mpEmissiveLightSampler)
        {
            FALCOR_ASSERT(pLights && pLights->getActiveLightCount(pRenderContext) > 0);
            mpEmissiveLightSampler = std::make_unique<EmissiveUniformSampler>(pRenderContext, mpScene);
        }
    }
    else
    {
        if (mpEmissiveLightSampler)
        {
            mpEmissiveLightSampler = nullptr;
            mTracePhotonVCMPass.pVars.reset();
        }
    }

    if (mpEmissiveLightSampler)
        mpEmissiveLightSampler->update(pRenderContext);
}

void ReducedVCM::prepareResources(RenderContext* pRenderContext, const RenderData& renderData)
{
    if (any(mScreenRes != renderData.getDefaultTextureDims()))
    {
        mScreenRes = renderData.getDefaultTextureDims();
        for (uint i = 0; i < 3; i++)
            mpLightTraceColorSpinlock[i].reset();
        for (uint i = 0; i < 4; i++)
            mpDebugTextures[i].reset();
    }

    if (mChangePhotonLightBufferSize)
    {
        mNumMaxPhotons = mNumMaxPhotonsUI;
        mpPhotonAABB.reset();
        mpPhotonDataVCM.reset();
        mpPhotonAS.reset();
        mChangePhotonLightBufferSize = false;
    }

    // Photon Buffers
    if (!mpPhotonAABB)
    {
        mpPhotonAABB = Buffer::createStructured(
            mpDevice, sizeof(AABB), mNumMaxPhotons, ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess,
            Buffer::CpuAccess::None, nullptr, false
        );
        mpPhotonAABB->setName("PhotonAABB");
    }

    if (!mpPhotonDataVCM)
    {
        mpPhotonDataVCM = Buffer::createStructured(
            mpDevice, sizeof(float) * 16, mNumMaxPhotons, ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess,
            Buffer::CpuAccess::None, nullptr, false
        );
        mpPhotonDataVCM->setName("PhotonDataVCM");
    }

    if (!mpPhotonCounter)
    {
        mpPhotonCounter = Buffer::create(
            mpDevice, sizeof(uint), ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess, Buffer::CpuAccess::None
        );
        mpPhotonCounter->setName("PhotonCounter");

        mpPhotonCounterCPU = Buffer::create(mpDevice, sizeof(uint), ResourceBindFlags::None, Buffer::CpuAccess::Read);
        mpPhotonCounterCPU->setName("PhotonCounterCPU");
    }

    // Acceleration Structure for Photon Collection
    if (!mpPhotonAS)
    {
        std::vector<uint64_t> aabbCount = {mNumMaxPhotons};
        std::vector<uint64_t> aabbGPUAddress = {mpPhotonAABB->getGpuAddress()};
        mpPhotonAS = std::make_unique<CustomAccelerationStructure>(
            mpDevice, aabbCount, aabbGPUAddress, CustomAccelerationStructure::BuildMode::FastBuild,
            CustomAccelerationStructure::UpdateMode::TLASOnly
        );
    }

    // Light Trace Spinlock textures
    for (uint i = 0; i < 3; i++)
    {
        if (!mpLightTraceColorSpinlock[i])
        {
            mpLightTraceColorSpinlock[i] = Texture::create2D(
                mpDevice, mScreenRes.x, mScreenRes.y, ResourceFormat::R32Uint, 1u, 1u, nullptr, ResourceBindFlags::UnorderedAccess
            );
            std::string colorChannel = i == 0 ? "Red" : (i == 1 ? "Green" : "Blue");
            mpLightTraceColorSpinlock[i]->setName("LightTraceSpinlock_" + colorChannel);
        }
    }

    // debug textures
    for (uint i = 0; i < 4; i++)
    {
        ResourceFormat format = renderData[kOutputColor]->asTexture()->getFormat();
        if (!mpDebugTextures[i])
        {
            mpDebugTextures[i] = Texture::create2D(
                mpDevice, mScreenRes.x, mScreenRes.y, format, 1u, 1u, nullptr,
                ResourceBindFlags::UnorderedAccess | ResourceBindFlags::ShaderResource
            );
            mpDebugTextures[i]->setName("Debug" + std::to_string(i));
        }
    }
}

void ReducedVCM::prepareCameraData()
{
    // Update Image plane distance
    auto& cameraData = mpScene->getCamera()->getData();
    float fovY = focalLengthToFovY(cameraData.focalLength, cameraData.frameHeight);
    float camTanHalfAngle = math::tan(fovY);
    mImagePlaneDist = mScreenRes.y / (2.f * camTanHalfAngle);

    // Get normalized pixel area
    float h = tan(fovY / 2.f) * 2.f;
    float w = h * cameraData.aspectRatio;
    float wPix = w / mScreenRes.x;
    float hPix = h / mScreenRes.y;

    mNormalizedPixelArea = wPix * hPix;
}

void ReducedVCM::tracePhotonGrittmannPass(RenderContext* pRenderContext, const RenderData& renderData)
{
    FALCOR_PROFILE(pRenderContext, "Trace Photons");

    // Clear Photon Counter
    pRenderContext->clearUAV(mpPhotonCounter->getUAV().get(), uint4(0));

    // Init Shader
    if (!mTracePhotonGrittmannPass.pProgram)
    {
        RtProgram::Desc desc;
        desc.addShaderModules(mpScene->getShaderModules());
        desc.addShaderLibrary(kShaderTracePhotonGrittmann);
        desc.setMaxPayloadSize(sizeof(float) * 4);
        desc.setMaxAttributeSize(mpScene->getRaytracingMaxAttributeSize());
        desc.setMaxTraceRecursionDepth(1);
        if (!mpScene->hasProceduralGeometry())
            desc.setPipelineFlags(RtPipelineFlags::SkipProceduralPrimitives);

        mTracePhotonGrittmannPass.pBindingTable = RtBindingTable::create(1, 1, mpScene->getGeometryCount());
        auto& sbt = mTracePhotonGrittmannPass.pBindingTable;
        sbt->setRayGen(desc.addRayGen("rayGen", mpScene->getTypeConformances()));
        sbt->setMiss(0, desc.addMiss("miss"));

        if (mpScene->hasGeometryType(Scene::GeometryType::TriangleMesh))
        {
            sbt->setHitGroup(0, mpScene->getGeometryIDs(Scene::GeometryType::TriangleMesh), desc.addHitGroup("closestHit", "anyHit"));
        }
        DefineList defines;
        defines.add("USE_EMISSIVE_LIGHT", mpScene->useEmissiveLights() ? "1" : "0");
        defines.add(mpScene->getSceneDefines());
        defines.add("DiffuseBrdf", mUseLambertianDiffuse ? "DiffuseBrdfLambert" : "DiffuseBrdfFrostbite");

        mTracePhotonGrittmannPass.pProgram = RtProgram::create(mpDevice, desc, defines);
    }
    // Defines
    mTracePhotonGrittmannPass.pProgram->addDefine("PHOTON_BUFFER_SIZE_GLOBAL", std::to_string(mNumMaxPhotons));
    mTracePhotonGrittmannPass.pProgram->addDefine("ROUGHNESS_THRESHOLD", std::to_string(mSpecularRoughnessThreshold));
    mTracePhotonGrittmannPass.pProgram->addDefine("DiffuseBrdf", mUseLambertianDiffuse ? "DiffuseBrdfLambert" : "DiffuseBrdfFrostbite");

    mTracePhotonGrittmannPass.pProgram->addDefine("USE_VC", mUseVC ? "1" : "0");
    mTracePhotonGrittmannPass.pProgram->addDefine("USE_VM", mUseVM ? "1" : "0");
    mTracePhotonGrittmannPass.pProgram->addDefine("USE_LIGHT_TRACE_ONLY", mLightTraceOnly ? "1" : "0");

    if (mpEmissiveLightSampler)
        mTracePhotonGrittmannPass.pProgram->addDefines(mpEmissiveLightSampler->getDefines());

    // Program Vars
    if (!mTracePhotonGrittmannPass.pVars)
        mTracePhotonGrittmannPass.initProgramVars(mpDevice, mpScene, mpSampleGenerator);

    FALCOR_ASSERT(mTracePhotonGrittmannPass.pVars);
    auto var = mTracePhotonGrittmannPass.pVars->getRootVar();
    mpScene->setRaytracingShaderData(pRenderContext, var);

    // Handle shader dimension
    uint dispatchedPhotons = mNumDispatchedPhotons;

    uint shaderDispatchDim = static_cast<uint>(std::floor(sqrt(dispatchedPhotons)));
    shaderDispatchDim = std::max(32u, shaderDispatchDim);

    // Constant Buffer
    var["CB"]["gFrameCount"] = mFrameCount;
    var["CB"]["gPhotonRadius"] = mPhotonRadiusVCM;
    var["CB"]["gMaxBounces"] = mPhotonMaxBounces;
    var["CB"]["gGlobalRejectionProb"] = mGlobalPhotonRejection;
    var["CB"]["gDispatchDimension"] = shaderDispatchDim;
    var["CB"]["gScreenRes"] = mScreenRes;
    var["CB"]["gImagePlaneDist"] = mImagePlaneDist;
    var["CB"]["gNormalizedPixelArea"] = mNormalizedPixelArea;

    // Structures
    if (mpEmissiveLightSampler)
        mpEmissiveLightSampler->setShaderData(var["Light"]["gEmissiveSampler"]);

    // Output
    var["gPhotonAABB"] = mpPhotonAABB;
    var["gPhotonData"] = mpPhotonDataVCM;

    for (uint32_t i = 0; i < 3; i++)
    {
        var["gLightTraceColor"][i] = mpLightTraceColorSpinlock[i];
    }

    var["gPhotonCounter"] = mpPhotonCounter;

    mpScene->raytrace(
        pRenderContext, mTracePhotonGrittmannPass.pProgram.get(), mTracePhotonGrittmannPass.pVars, uint3(shaderDispatchDim, shaderDispatchDim, 1)
    );

    // Light Trace UAV barrier
    for (uint32_t i = 0; i < 3; i++)
    {
        pRenderContext->uavBarrier(mpLightTraceColorSpinlock[i].get());
    }

    mNumberLightPaths = shaderDispatchDim * shaderDispatchDim;

    // Clear values after the counter
    mpPhotonAS->clearAABBBuffers(pRenderContext, mpPhotonAABB, true, mpPhotonCounter);

    // Copy counter to CPU
    handlePhotonCounter(pRenderContext);

    // Build acceleration structure
    uint currentPhotons = mFrameCount > 0 ? uint(float(mCurrentPhotonCount) * mASBuildBufferPhotonOverestimate) : mNumMaxPhotons;
    uint64_t photonBuildSize = std::min(mNumMaxPhotons, currentPhotons);

    mpPhotonAS->update(pRenderContext, photonBuildSize);
}

void ReducedVCM::traceCameraGrittmannPass(RenderContext* pRenderContext, const RenderData& renderData)
{
    FALCOR_PROFILE(pRenderContext, "TraceCamera");

    // Init Shader
    if (!mTraceCameraGrittmannPass.pProgram)
    {
        RtProgram::Desc desc;
        desc.addShaderModules(mpScene->getShaderModules());
        desc.addShaderLibrary(kShaderTraceCameraGrittmann);
        desc.setMaxPayloadSize(sizeof(float) * 4);
        desc.setMaxAttributeSize(mpScene->getRaytracingMaxAttributeSize());
        desc.setMaxTraceRecursionDepth(1);
        if (!mpScene->hasProceduralGeometry())
            desc.setPipelineFlags(RtPipelineFlags::SkipProceduralPrimitives);

        mTraceCameraGrittmannPass.pBindingTable = RtBindingTable::create(1, 1, mpScene->getGeometryCount());
        auto& sbt = mTraceCameraGrittmannPass.pBindingTable;
        sbt->setRayGen(desc.addRayGen("rayGen", mpScene->getTypeConformances()));
        sbt->setMiss(0, desc.addMiss("miss"));

        if (mpScene->hasGeometryType(Scene::GeometryType::TriangleMesh))
        {
            sbt->setHitGroup(0, mpScene->getGeometryIDs(Scene::GeometryType::TriangleMesh), desc.addHitGroup("closestHit", "anyHit"));
        }

        mTraceCameraGrittmannPass.pProgram = RtProgram::create(mpDevice, desc, mpScene->getSceneDefines());
    }

    // Defines
    mTraceCameraGrittmannPass.pProgram->addDefine("USE_EMISSIVE_LIGHT", mpScene->useEmissiveLights() ? "1" : "0");
    mTraceCameraGrittmannPass.pProgram->addDefine("USE_ENV_MAP", mpScene->useEnvBackground() ? "1" : "0");
    mTraceCameraGrittmannPass.pProgram->addDefine("ROUGHNESS_THRESHOLD", std::to_string(mSpecularRoughnessThreshold));
    mTraceCameraGrittmannPass.pProgram->addDefine("DiffuseBrdf", mUseLambertianDiffuse ? "DiffuseBrdfLambert" : "DiffuseBrdfFrostbite");
    if (mpEmissiveLightSampler)
        mTraceCameraGrittmannPass.pProgram->addDefines(mpEmissiveLightSampler->getDefines());

    mTraceCameraGrittmannPass.pProgram->addDefine("USE_VC", mUseVC ? "1" : "0");
    mTraceCameraGrittmannPass.pProgram->addDefine("USE_VM", mUseVM ? "1" : "0");
    mTraceCameraGrittmannPass.pProgram->addDefine("USE_LIGHT_TRACE_ONLY", mLightTraceOnly ? "1" : "0");
    mTraceCameraGrittmannPass.pProgram->addDefine("ENABLE_DEBUG", mDebugEnable ? "1" : "0");

    // Program Vars
    if (!mTraceCameraGrittmannPass.pVars)
        mTraceCameraGrittmannPass.initProgramVars(mpDevice, mpScene, mpSampleGenerator);

    FALCOR_ASSERT(mTraceCameraGrittmannPass.pVars);
    auto var = mTraceCameraGrittmannPass.pVars->getRootVar();

    // Structures
    if (mpEmissiveLightSampler)
        mpEmissiveLightSampler->setShaderData(var["Light"]["gEmissiveSampler"]);

    // Constant Buffer
    var["CB"]["gFrameCount"] = mFrameCount;
    var["CB"]["gMaxBounces"] = mPTMaxBounces;
    var["CB"]["gNumLightPaths"] = mNumberLightPaths;
    var["CB"]["gImagePlaneDist"] = mImagePlaneDist;
    var["CB"]["gNormalizedPixelArea"] = mNormalizedPixelArea;
    var["CB"]["gPhotonRadius"] = mPhotonRadiusVCM;
    var["CB"]["gDebugBounce"] = mDebugTechniqueBounce;

    // Input
    var["gVBuffer"] = renderData[kInputVBuffer]->asTexture();
    var["gView"] = renderData[kInputView]->asTexture();

    // Photon Data
    mpPhotonAS->bindTlas(var, "gPhotonAS");

    var["gPhotonAABB"] = mpPhotonAABB;
    var["gPhotonData"] = mpPhotonDataVCM;

    for (uint32_t i = 0; i < 3; i++)
    {
        var["gLightTraceColor"][i] = mpLightTraceColorSpinlock[i];
    }

    if (mDebugEnable)
        for (uint i = 0; i < 4; i++)
            var["gDebug"][i] = mpDebugTextures[i];

    var["gOutColor"] = renderData[kOutputColor]->asTexture();

    // Dispatch Shader
    mpScene->raytrace(pRenderContext, mTraceCameraGrittmannPass.pProgram.get(), mTraceCameraGrittmannPass.pVars, uint3(mScreenRes, 1));

    // Copy Debug to color out
    if (mDebugEnable)
    {
        ref<Texture> debugTex = mpDebugTextures[uint(mDebugTechnique)];
        pRenderContext->copyResource(renderData[kOutputColor]->asTexture().get(), debugTex.get());
    }
}

void ReducedVCM::tracePhotonVCMPass(RenderContext* pRenderContext, const RenderData& renderData)
{
    FALCOR_PROFILE(pRenderContext, "Trace Photons");

    // Clear Photon Counter
    pRenderContext->clearUAV(mpPhotonCounter->getUAV().get(), uint4(0));

    // Init Shader
    if (!mTracePhotonVCMPass.pProgram)
    {
        RtProgram::Desc desc;
        desc.addShaderModules(mpScene->getShaderModules());
        desc.addShaderLibrary(kShaderTracePhotonVCM);
        desc.setMaxPayloadSize(sizeof(float) * 4);
        desc.setMaxAttributeSize(mpScene->getRaytracingMaxAttributeSize());
        desc.setMaxTraceRecursionDepth(1);
        if (!mpScene->hasProceduralGeometry())
            desc.setPipelineFlags(RtPipelineFlags::SkipProceduralPrimitives);

        mTracePhotonVCMPass.pBindingTable = RtBindingTable::create(1, 1, mpScene->getGeometryCount());
        auto& sbt = mTracePhotonVCMPass.pBindingTable;
        sbt->setRayGen(desc.addRayGen("rayGen", mpScene->getTypeConformances()));
        sbt->setMiss(0, desc.addMiss("miss"));

        if (mpScene->hasGeometryType(Scene::GeometryType::TriangleMesh))
        {
            sbt->setHitGroup(0, mpScene->getGeometryIDs(Scene::GeometryType::TriangleMesh), desc.addHitGroup("closestHit", "anyHit"));
        }
        DefineList defines;
        defines.add("USE_EMISSIVE_LIGHT", mpScene->useEmissiveLights() ? "1" : "0");
        defines.add(mpScene->getSceneDefines());
        defines.add("DiffuseBrdf", mUseLambertianDiffuse ? "DiffuseBrdfLambert" : "DiffuseBrdfFrostbite");

        mTracePhotonVCMPass.pProgram = RtProgram::create(mpDevice, desc, defines);
    }
    // Defines
    mTracePhotonVCMPass.pProgram->addDefine("PHOTON_BUFFER_SIZE_GLOBAL", std::to_string(mNumMaxPhotons));
    mTracePhotonVCMPass.pProgram->addDefine("ROUGHNESS_THRESHOLD", std::to_string(mSpecularRoughnessThreshold));
    mTracePhotonVCMPass.pProgram->addDefine("USE_VC", mUseVC ? "1" : "0");
    mTracePhotonVCMPass.pProgram->addDefine("USE_VM", mUseVM ? "1" : "0");
    mTracePhotonVCMPass.pProgram->addDefine("USE_LIGHT_TRACE_ONLY", mLightTraceOnly ? "1" : "0");
    mTracePhotonVCMPass.pProgram->addDefine("DiffuseBrdf", mUseLambertianDiffuse ? "DiffuseBrdfLambert" : "DiffuseBrdfFrostbite");

    if (mpEmissiveLightSampler)
        mTracePhotonVCMPass.pProgram->addDefines(mpEmissiveLightSampler->getDefines());

    // Program Vars
    if (!mTracePhotonVCMPass.pVars)
        mTracePhotonVCMPass.initProgramVars(mpDevice, mpScene, mpSampleGenerator);

    FALCOR_ASSERT(mTracePhotonVCMPass.pVars);
    auto var = mTracePhotonVCMPass.pVars->getRootVar();
    mpScene->setRaytracingShaderData(pRenderContext, var);

    // Handle shader dimension
    uint dispatchedPhotons = mNumDispatchedPhotons;

    uint shaderDispatchDim = static_cast<uint>(std::floor(sqrt(dispatchedPhotons)));
    shaderDispatchDim = std::max(32u, shaderDispatchDim);

    // Constant Buffer
    var["CB"]["gFrameCount"] = mFrameCount;
    var["CB"]["gPhotonRadius"] = mPhotonRadiusVCM; // TODO temporally until MIS weights are radius independet mPhotonRadius;
    var["CB"]["gMaxBounces"] = mPhotonMaxBounces;
    var["CB"]["gGlobalRejectionProb"] = mGlobalPhotonRejection;
    var["CB"]["gDispatchDimension"] = shaderDispatchDim;
    var["CB"]["gScreenRes"] = mScreenRes;
    var["CB"]["gImagePlaneDist"] = mImagePlaneDist;
    var["CB"]["gNormalizedPixelArea"] = mNormalizedPixelArea;

    // Structures
    if (mpEmissiveLightSampler)
        mpEmissiveLightSampler->setShaderData(var["Light"]["gEmissiveSampler"]);

    // Output
    var["gPhotonAABB"] = mpPhotonAABB;
    var["gPhotonData"] = mpPhotonDataVCM;

    for (uint32_t i = 0; i < 3; i++)
    {
        var["gLightTraceColor"][i] = mpLightTraceColorSpinlock[i];
    }

    var["gPhotonCounter"] = mpPhotonCounter;

    mpScene->raytrace(
        pRenderContext, mTracePhotonVCMPass.pProgram.get(), mTracePhotonVCMPass.pVars, uint3(shaderDispatchDim, shaderDispatchDim, 1)
    );

    // Light Trace UAV barrier
    for (uint32_t i = 0; i < 3; i++)
    {
        pRenderContext->uavBarrier(mpLightTraceColorSpinlock[i].get());
    }

    mNumberLightPaths = shaderDispatchDim * shaderDispatchDim;

    // Clear values after the counter
    mpPhotonAS->clearAABBBuffers(pRenderContext, mpPhotonAABB, true, mpPhotonCounter);

    // Copy counter to CPU
    handlePhotonCounter(pRenderContext);

    // Build acceleration structure
    uint currentPhotons = mFrameCount > 0 ? uint(float(mCurrentPhotonCount) * mASBuildBufferPhotonOverestimate) : mNumMaxPhotons;
    uint64_t photonBuildSize = std::min(mNumMaxPhotons, currentPhotons);

    mpPhotonAS->update(pRenderContext, photonBuildSize);
}

void ReducedVCM::traceCameraVCMPass(RenderContext* pRenderContext, const RenderData& renderData)
{
    FALCOR_PROFILE(pRenderContext, "TraceCamera");

    // Init Shader
    if (!mTraceCameraVCMPass.pProgram)
    {
        RtProgram::Desc desc;
        desc.addShaderModules(mpScene->getShaderModules());
        desc.addShaderLibrary(kShaderTraceCameraVCM);
        desc.setMaxPayloadSize(sizeof(float) * 4);
        desc.setMaxAttributeSize(mpScene->getRaytracingMaxAttributeSize());
        desc.setMaxTraceRecursionDepth(1);
        if (!mpScene->hasProceduralGeometry())
            desc.setPipelineFlags(RtPipelineFlags::SkipProceduralPrimitives);

        mTraceCameraVCMPass.pBindingTable = RtBindingTable::create(1, 1, mpScene->getGeometryCount());
        auto& sbt = mTraceCameraVCMPass.pBindingTable;
        sbt->setRayGen(desc.addRayGen("rayGen", mpScene->getTypeConformances()));
        sbt->setMiss(0, desc.addMiss("miss"));

        if (mpScene->hasGeometryType(Scene::GeometryType::TriangleMesh))
        {
            sbt->setHitGroup(0, mpScene->getGeometryIDs(Scene::GeometryType::TriangleMesh), desc.addHitGroup("closestHit", "anyHit"));
        }

        mTraceCameraVCMPass.pProgram = RtProgram::create(mpDevice, desc, mpScene->getSceneDefines());
    }

    // Defines
    mTraceCameraVCMPass.pProgram->addDefine("USE_EMISSIVE_LIGHT", mpScene->useEmissiveLights() ? "1" : "0");
    mTraceCameraVCMPass.pProgram->addDefine("USE_ENV_MAP", mpScene->useEnvBackground() ? "1" : "0");
    mTraceCameraVCMPass.pProgram->addDefine("ROUGHNESS_THRESHOLD", std::to_string(mSpecularRoughnessThreshold));
    mTraceCameraVCMPass.pProgram->addDefine("USE_VC", mUseVC ? "1" : "0");
    mTraceCameraVCMPass.pProgram->addDefine("USE_VM", mUseVM ? "1" : "0");
    mTraceCameraVCMPass.pProgram->addDefine("USE_LIGHT_TRACE_ONLY", mLightTraceOnly ? "1" : "0");
    mTraceCameraVCMPass.pProgram->addDefine("DiffuseBrdf", mUseLambertianDiffuse ? "DiffuseBrdfLambert" : "DiffuseBrdfFrostbite");
    if (mpEmissiveLightSampler)
        mTraceCameraVCMPass.pProgram->addDefines(mpEmissiveLightSampler->getDefines());
    mTraceCameraVCMPass.pProgram->addDefine("ENABLE_DEBUG", mDebugEnable ? "1" : "0");

    // Program Vars
    if (!mTraceCameraVCMPass.pVars)
        mTraceCameraVCMPass.initProgramVars(mpDevice, mpScene, mpSampleGenerator);

    FALCOR_ASSERT(mTraceCameraVCMPass.pVars);
    auto var = mTraceCameraVCMPass.pVars->getRootVar();

    // Structures
    if (mpEmissiveLightSampler)
        mpEmissiveLightSampler->setShaderData(var["Light"]["gEmissiveSampler"]);

    // Constant Buffer
    var["CB"]["gFrameCount"] = mFrameCount;
    var["CB"]["gMaxBounces"] = mPTMaxBounces;
    var["CB"]["gNumLightPaths"] = mNumberLightPaths;
    var["CB"]["gImagePlaneDist"] = mImagePlaneDist;
    var["CB"]["gNormalizedPixelArea"] = mNormalizedPixelArea;
    var["CB"]["gPhotonRadius"] = mPhotonRadiusVCM;
    var["CB"]["gDebugBounce"] = mDebugTechniqueBounce;

    // Input
    var["gVBuffer"] = renderData[kInputVBuffer]->asTexture();
    var["gView"] = renderData[kInputView]->asTexture();

    // Photon Data
    mpPhotonAS->bindTlas(var, "gPhotonAS");

    var["gPhotonAABB"] = mpPhotonAABB;
    var["gPhotonData"] = mpPhotonDataVCM;

    for (uint32_t i = 0; i < 3; i++)
    {
        var["gLightTraceColor"][i] = mpLightTraceColorSpinlock[i];
    }

    var["gOutColor"] = renderData[kOutputColor]->asTexture();

    // Debug
    if (mDebugEnable)
        for (uint i = 0; i < 4; i++)
            var["gDebug"][i] = mpDebugTextures[i];

    // Dispatch Shader
    mpScene->raytrace(pRenderContext, mTraceCameraVCMPass.pProgram.get(), mTraceCameraVCMPass.pVars, uint3(mScreenRes, 1));

    // Copy Debug to color out
    if (mDebugEnable)
    {
        ref<Texture> debugTex = mpDebugTextures[uint(mDebugTechnique)];
        pRenderContext->copyResource(renderData[kOutputColor]->asTexture().get(), debugTex.get());
    }
}

void ReducedVCM::handlePhotonCounter(RenderContext* pRenderContext)
{
    // Copy the photonCounter to a CPU Buffer
    pRenderContext->copyBufferRegion(mpPhotonCounterCPU.get(), 0, mpPhotonCounter.get(), 0, sizeof(uint));

    void* data = mpPhotonCounterCPU->map(Buffer::MapType::Read);
    std::memcpy(&mCurrentPhotonCount, data, sizeof(uint));
    mpPhotonCounterCPU->unmap();

    // Change Photon dispatch count dynamically.

    if (mUseDynamicPhotonDispatchCount)
    {
        // Only use global photons for the dynamic dispatch count
        uint globalPhotonCount = mCurrentPhotonCount;
        uint globalMaxPhotons = mNumMaxPhotons;
        // If counter is invalid, reset
        if (globalPhotonCount == 0)
        {
            mNumDispatchedPhotons = mPhotonDynamicDispatchMax / 2;
        }
        uint globBufferSizeCompValue = (uint)(globalMaxPhotons * (1.f - mPhotonDynamicGuardPercentage));
        uint globChangeSize = (uint)(globalMaxPhotons * mPhotonDynamicChangePercentage);

        // If smaller, increase dispatch size
        if ((globalPhotonCount < globBufferSizeCompValue))
        {
            uint newDispatched = (uint)(mNumDispatchedPhotons + globChangeSize);
            mNumDispatchedPhotons = std::min(newDispatched, mPhotonDynamicDispatchMax);
        }
        // Reduce dispatch size
        else
        {
            uint newDispatched = (uint)(mNumDispatchedPhotons - globChangeSize);
            mNumDispatchedPhotons = std::max(newDispatched, 1024u);
        }
    }
}

void ReducedVCM::resetRenderPasses()
{
    mTraceCameraVCMPass = RayTraceProgramHelper::create();
    mTracePhotonVCMPass = RayTraceProgramHelper::create();
    mTracePhotonGrittmannPass = RayTraceProgramHelper::create();
    mTraceCameraGrittmannPass = RayTraceProgramHelper::create();

    mpEmissiveLightSampler.reset();
}

void ReducedVCM::RayTraceProgramHelper::initProgramVars(ref<Device> pDevice, ref<Scene> pScene, ref<SampleGenerator> pSampleGenerator)
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
