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
#include "ParticlePass.h"
#include "ParticleDataTypes.slang"
#include "Utils/Timing/Clock.h"
#include "RenderGraph/RenderPassStandardFlags.h"

extern "C" FALCOR_API_EXPORT void registerPlugin(Falcor::PluginRegistry& registry)
{
    registry.registerClass<RenderPass, ParticlePass>();
}

namespace
{
    const std::string kShaderUpdateParticles = "RenderPasses/ParticlePass/UpdateParticlePoints.cs.slang";
    const std::string kShaderModel = "6_6";
}

ParticlePass::ParticlePass(ref<Device> pDevice, const Properties& props)
    : RenderPass(pDevice)
{
    mpSampleGenerator = SampleGenerator::create(mpDevice, SAMPLE_GENERATOR_UNIFORM);
    FALCOR_ASSERT(mpSampleGenerator);
}

Properties ParticlePass::getProperties() const
{
    return {};
}

RenderPassReflection ParticlePass::reflect(const CompileData& compileData)
{
    // Define the required resources here
    RenderPassReflection reflector;
    //reflector.addOutput("dst");
    //reflector.addInput("src");
    return reflector;
}

void ParticlePass::setScene(RenderContext* pRenderContext, const ref<Scene>& pScene) {
    if (pScene)
    {
        mpScene = pScene;

        //TODO load in settings stored in a file?
        // Reset old buffers
        mParticleSettings.clear();
        mpParticleAnimateDataBuffer.reset();

        //Set all particles in the scene to active
        auto& particleSystems = mpScene->getParticleSystem();
        uint totalSize = 0;
        for (auto& ps : particleSystems)
        {
            ps.active = true;
            ParticleSettings particleSetting{};
            mParticleSettings.push_back(particleSetting);
            totalSize += ps.numberParticles;
        }

        if (totalSize > 0)
        {
            //Set initial data for the buffer
            std::vector<ParticleAnimateData> initialData(totalSize);
            uint offset = 0;
            for (uint i = 0; i<particleSystems.size(); i++)
            {
                auto& ps = particleSystems[i];
                auto& pSett = mParticleSettings[i];
                float lifePerParticle = pSett.lifetime / ps.numberParticles;
                float lastLifeTime = pSett.lifetime;
                for (uint j = 0; j < ps.numberParticles; j++)
                {
                    ParticleAnimateData data{};
                    data.lifetime = lastLifeTime;
                    data.velocity = float3(0);
                    initialData[j + offset] = data;

                    lastLifeTime = math::max(lastLifeTime - lifePerParticle, 0.f);
                }
                offset += ps.numberParticles;
            }

            //Create buffer
            mpParticleAnimateDataBuffer = Buffer::createStructured(
                mpDevice, sizeof(ParticleAnimateData), totalSize, ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess,
                Buffer::CpuAccess::None, initialData.data(), false
            );
            mpParticleAnimateDataBuffer->setName("ParticlePass::ParticleAnimateData");
        }
    }
        
}

void ParticlePass::execute(RenderContext* pRenderContext, const RenderData& renderData)
{
    //if scene is not set do nothing
    if (!mpScene)
        return;

    auto& particleSystems = mpScene->getParticleSystem();

    //Check if particle system is set, else return
    if (particleSystems.empty())
        return;

    FALCOR_PROFILE(pRenderContext, "UpdateParticlePoints");

    //Update Point pass
    if (!mpUpdateParticlePointsPass)
    {
        Program::Desc desc;
        desc.addShaderModules(mpScene->getShaderModules());
        desc.addShaderLibrary(kShaderUpdateParticles).csEntry("main").setShaderModel(kShaderModel);
        //desc.addTypeConformances(mpScene->getTypeConformances());

        DefineList defines;
        defines.add(mpScene->getSceneDefines());
        defines.add(mpSampleGenerator->getDefines());

        mpUpdateParticlePointsPass = ComputePass::create(mpDevice, desc, defines, true);   
    }

    FALCOR_ASSERT(mpUpdateParticlePointsPass);

    //Get Resources
    auto& pParticlePointsBuffer = mpScene->getParticlePointsBuffer();

    //Get deltaT
    auto& renderDict = renderData.getDictionary();
    auto pGlobalClock = static_cast<Clock*>(renderDict[kRenderGlobalClock]);
    double currentTime = pGlobalClock->getTime();
    float deltaT = static_cast<float>(math::max(currentTime - lastFrameTime, 0.0));
    lastFrameTime = currentTime;

    auto var = mpUpdateParticlePointsPass->getRootVar();
    //Set Shader data valid for all particle spawners
    mpSampleGenerator->setShaderData(var);
    var["gParticlePointDesc"] = pParticlePointsBuffer;
    var["gParticleAnimateData"] = mpParticleAnimateDataBuffer;

    //One dispatch per particle system
    for (uint i=0; i<particleSystems.size(); i++)
    {
        auto& ps = particleSystems[i];
        auto& pSett = mParticleSettings[i];

        if (!ps.active)
            continue;
        FALCOR_PROFILE(pRenderContext, ps.name);
        // Set constant buffer
        var["CB"]["gParticleBufferOffset"] = ps.particleBufferOffset;
        var["CB"]["gNumParticles"] = ps.numberParticles;
        var["CB"]["gRestPosition"] = ps.spawnPosition;
        var["CB"]["gBaseRadius"] = ps.intitialRadius;

        var["CB"]["gDeltaT"] = deltaT;
        var["CB"]["gInitialPosition"] = pSett.spawnPosition;
        var["CB"]["gInitialVelocity"] = pSett.initialVelocity;
        var["CB"]["gMaxLifetime"] = pSett.lifetime;
        var["CB"]["gGravity"] = pSett.gravity;
        var["CB"]["gSpawnRadius"] = pSett.spawnRadius;

        mpUpdateParticlePointsPass->execute(pRenderContext, uint3(ps.numberParticles, 1, 1));
    }
}

void ParticlePass::renderUI(Gui::Widgets& widget)
{
    if (!mpScene)
    {
        widget.text("Please load in a scene for options to appear");
        return;
    }
        
    auto& particleSystems = mpScene->getParticleSystem();
    if (particleSystems.empty())
    {
        widget.text(
            "There are no particle system in the current scene \n Please add one or more in the .pyscene with "
            "\"sceneBuilder.addParticleSystem(name, material, numberOfParticles, restPosition)\""
        );
        return;
    }

    widget.text("Particle Systems:");
    for (uint i=0; i<particleSystems.size(); i++)
    {
        auto& ps = particleSystems[i];
        auto& pSett = mParticleSettings[i];
        if (auto group = widget.group(ps.name))
        {
            group.checkbox("Enable", ps.active);
            group.text("Max Number of Particles: " + std::to_string(ps.numberParticles));
            group.var("BaseRadius", ps.intitialRadius);
            group.var("RestPosition", ps.spawnPosition);
            group.tooltip("Position where all inactive particles are moved");

            group.var("Lifetime", pSett.lifetime, 0.0f, FLT_MAX, 0.1f);
            group.tooltip("Time a particle lives");
            group.var("SpawnPosition", pSett.spawnPosition);
            group.tooltip("Position where a active particle spawns. A particles spawns if their current lifetime exeeds the Lifetime");
            group.var("InitialVelocity", pSett.initialVelocity);
            group.var("Gravity", pSett.gravity);
            group.var("SpawnRadius", pSett.spawnRadius, 0.f);
        }
    }
}
