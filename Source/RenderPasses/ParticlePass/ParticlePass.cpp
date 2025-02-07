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
#include <nlohmann/json.hpp>
#include <fstream>

using json = nlohmann::json;

//Float3 json defines
namespace Falcor::math
{
    void to_json(json& j, const float3& v)
    {
        j = {v.x, v.y, v.z};
    }

    void from_json(const json& j, float3& v)
    {
        j[0].get_to(v.x);
        j[1].get_to(v.y);
        j[2].get_to(v.z);
    }
}

extern "C" FALCOR_API_EXPORT void registerPlugin(Falcor::PluginRegistry& registry)
{
    registry.registerClass<RenderPass, ParticlePass>();
}

namespace
{
    const std::string kShaderUpdateParticles = "RenderPasses/ParticlePass/UpdateParticlePoints.cs.slang";
    const std::string kShaderModel = "6_6";

    //JSON Keys
    const std::string kJSONKeyLifetime = "lifetime";
    const std::string kJSONKeySpawnPosition = "spawnPosition";
    const std::string kJSONKeyInitialVelocity = "initialVelocity";
    const std::string kJSONKeyGravity = "gravity";
    const std::string kJSONKeySpawnRadius = "spawnRadius";
    const std::string kJSONKeySpreadAngle = "spreadAngle";
}

//Json defines for settings type
void from_json(const json& j, ParticlePass::ParticleSettings& settings) {
    if (j.contains(kJSONKeyLifetime)) j[kJSONKeyLifetime].get_to(settings.lifetime);
    if (j.contains(kJSONKeySpawnPosition)) j[kJSONKeySpawnPosition].get_to(settings.spawnPosition);
    if (j.contains(kJSONKeyInitialVelocity)) j[kJSONKeyInitialVelocity].get_to(settings.initialVelocity);
    if (j.contains(kJSONKeyGravity)) j[kJSONKeyGravity].get_to(settings.gravity);
    if (j.contains(kJSONKeySpawnRadius)) j[kJSONKeySpawnRadius].get_to(settings.spawnRadius);
    if (j.contains(kJSONKeySpreadAngle))j[kJSONKeySpreadAngle].get_to(settings.spreadAngle);
 }

 void to_json(json& j, const ParticlePass::ParticleSettings& settings)
{
    j[kJSONKeyLifetime] = settings.lifetime;
    j[kJSONKeySpawnPosition] = settings.spawnPosition;
    j[kJSONKeyInitialVelocity] = settings.initialVelocity;
    j[kJSONKeyGravity] = settings.gravity;
    j[kJSONKeySpawnRadius] = settings.spawnRadius;
    j[kJSONKeySpreadAngle] = settings.spreadAngle;
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
        mScenePath = mpScene->getPath().parent_path();
        refreshFileList(); //Get possible configuration

        // Reset old buffers
        mParticleSettings.clear();
        mpParticleAnimateDataBuffer.reset();

        //Set all particles in the scene to active and initialize default settings
        auto& particleSystems = mpScene->getParticleSystem();
        uint totalSize = 0;
        for (auto& ps : particleSystems)
        {
            ps.active = true;
            ParticleSettings particleSetting{};
            particleSetting.spawnPosition = ps.spawnPosition;
            mParticleSettings.push_back(particleSetting);
            totalSize += ps.numberParticles;
        }

        //Load Settings from file if exist
        if (totalSize > 0 && !mFileList.empty())
        {
            loadConfigurationFile(mFileList[0].label);
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

    if (mReinitializeBuffer)
    {
        //TODO refill the buffer
        mReinitializeBuffer = false;
    }

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
        var["CB"]["gSpreadAngle"] = pSett.spreadAngle;

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
            group.var("SpreadAngle", pSett.spreadAngle, 0.f, static_cast<float>(M_PI) * 2.f, 0.001f);
        }
    }
    if (!mFileList.empty())
    {
        widget.dropdown("Particle Configs", mFileList, mSelectedFile);
        if (widget.button("Load Config File"))
            mReinitializeBuffer |= loadConfigurationFile(mFileList[mSelectedFile].label);
    }
        

    widget.textbox("Particle Config Name", mConfigurationName);
    bool storeConfig = widget.button("Store Current Configuration");
    if (storeConfig)
        storeCurrentConfiguration();
}

void ParticlePass::storeCurrentConfiguration() {
    //Do nothing if scene is not set
    if (!mpScene)
        return;

    auto& particleSystems = mpScene->getParticleSystem();
    if (particleSystems.empty())
        return;

    //Check if name is empty and set a default name
    std::string fileName = mConfigurationName;
    if (fileName.empty())
        fileName = "ParticleSettings";
    fileName += ".prtsett";

    auto pathToFile = mScenePath;
    pathToFile.append(fileName);

    std::ofstream ofs(pathToFile);
    if (!ofs.good())
    {
        logWarning("Failed to open particle settings file '{}' for writing.", pathToFile);
        return;
    }

    json j;
    for (uint i = 0; i < mParticleSettings.size(); i++)
        j[particleSystems[i].name] = mParticleSettings[i];

    ofs << j.dump(4);
    ofs.close();

    logInfo("Successfully stored Particle Configuration at: '{}'", pathToFile);
    refreshFileList();
}

void ParticlePass::refreshFileList()
{
    if (!mpScene)
        return;

    mFileList.clear();
    Gui::DropdownValue v;
    v.value = 0;
    for (const auto& entry : std::filesystem::directory_iterator(mScenePath))
    {
        if (entry.is_regular_file() && entry.path().extension() == ".prtsett")
        {
            v.label = entry.path().filename().replace_extension().string();
            mFileList.push_back(v);
            ++v.value;
        }
    }
    mSelectedFile = 0;
}

bool ParticlePass::loadConfigurationFile(std::string filename) {
    if (!mpScene)
        return false;

    auto& particleSystems = mpScene->getParticleSystem();
    FALCOR_ASSERT(particleSystems.size() == mParticleSettings.size()); //We assume that both the particle system and settings are initialized

    //Create the path from the filename
    FALCOR_ASSERT(!filename.empty());
    filename += ".prtsett";
    auto pathToFile = mScenePath;
    pathToFile.append(filename);

    std::ifstream ifs(pathToFile);
    if (!ifs.good())
    {
        logWarning("Failed to open Particle Settings file '{}' for reading.", pathToFile);
        return false;
    }

    //Parse json
    try
    {
        json j = json::parse(ifs);
        for (uint i = 0; i < particleSystems.size(); i++)
        {
            //Check if there is a entry with the particle system name
            if (j.contains(particleSystems[i].name))
            {
                mParticleSettings[i] = j[particleSystems[i].name];
            }
        }
    }
    catch (const std::exception& e)
    {
        logWarning("Error when deserializing Particle Setting from '{}': {}", pathToFile, e.what());
        return false;
    }

    return true;
}
