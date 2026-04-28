#include "PhotonGuiding.h"

namespace Falcor
{
    //Shader Paths and UI elements
    namespace
    {
        const std::string kShaderFolder = "Rendering/PhotonGuiding/"; 
        const std::string kShaderReduce = kShaderFolder + "Reduce.cs.slang";
        const std::string kShaderUpdateHistograms = kShaderFolder + "UpdateHistograms.cs.slang"; 
        const std::string kShaderUpdateGuidingMaps = kShaderFolder + "UpdateGuidingMaps.cs.slang"; 

        const std::string kShaderModel = "6_6";
    }

    PhotonGuiding::PhotonGuiding(ref<Device> pDevice, ref<Scene> pScene, RenderContext* pRenderContext)
    {
        mpDevice = pDevice;

        if (!pScene) {
            throw std::exception("PhotonGuiding: Was initialized with an empty scene!");
        }

        mpScene = pScene;
        prepareResources(pRenderContext);
    }

    PhotonGuiding::~PhotonGuiding()
    {
        clearResources();
    }

    void PhotonGuiding::update(RenderContext* pRenderContext, uint maxPhotonsDistributed)
    {
        FALCOR_PROFILE(pRenderContext, "PhotonGuiding_UpdateResources");

        //Get per light and total contribution
        reduceContributionPass(pRenderContext);

        //
        updateGuidingMaps(pRenderContext, maxPhotonsDistributed);

        pRenderContext->clearUAV(mpContributionDirection->getUAV(0).get(), uint4(0));
        mGuidingIterationCount++;
    }

    DefineList PhotonGuiding::getDefines()
    {
        DefineList defines = {};
        defines.add("PHOTON_GUIDING_DISCRETIZED_CONTRIBUTION_FACTOR", std::to_string(mOptions.discretizedContributionFactor));
        defines.add("PHOTON_GUIDING_DISCRETIZED_CONTRIBUTION_MAX", std::to_string(mOptions.discretizedContributionMax));
        defines.add("PHOTON_GUIDING_USE_MAPPED_GM", std::to_string(mOptions.useMappingScheme));

        //Create sample defines
        defines.add("PHOTON_GUIDING_TOTAL_LIGHT_COUNT", std::to_string(mTotalLightCount));
        defines.add("PHOTON_GUIDING_TRAVERSAL_BLOCK_SIZE", std::to_string(mOptions.traversalBlockSize));
        defines.add("PHOTON_GUIDING_LIGHT_GM_MAX_MIP", std::to_string(mpGuidingMapLight->getMipCount() - 1));
        defines.add("PHOTON_GUIDING_DIRECTION_GM_MAX_MIP", std::to_string(mMipLevelsDirGM - 1));
        defines.add("PHOTON_GUIDING_MIN_PHOTONS_FOR_DIR_GUIDING", std::to_string(mOptions.photonNeededForGM));
        defines.add("PHOTON_GUIDING_ANALYTIC_LIGHT_OFFSET", std::to_string(mEmissiveLightCount));

        return defines;
    }

    void PhotonGuiding::setShaderData(const ShaderVar& rootVar)
    {
        auto var = rootVar["gPhotonGuiding"];

        var["gResolutionLightGM"] = mResolutionLightGM;
        var["gMapDirResourcesPerRow"] = mResolutionDirGM / mOptions.guidingMapResolution;
        var["gResolutionGM"] = mOptions.guidingMapResolution;

        var["gContributionLight"] = mpContributionLight;
        var["gContributionDirection"] = mpContributionDirection;
        var["gMapLightToDirection"] = mpMapDirectionToLight;

        var["gGuidingMapLight"] = mpGuidingMapLight;
        var["gGuidingMapsDirection"] = mpGuidingMapsDirection;
    }

    void PhotonGuiding::clearResources()
    {
        mpGuidingMapLight = nullptr;
        mpGuidingMapsDirection = nullptr;
        mpHistogramLight = nullptr;
        mpHistogramDirection = nullptr;
        mpContributionDirection = nullptr;
        mpResourceCounter = nullptr;
        mpContributionLight = nullptr;
        mpGuidingMapsDirectionPrev = nullptr;
        mpMapLightToDirection = nullptr;
        mpMapLightToDirectionPrev = nullptr;
        mpMapDirectionToLight = nullptr;
        mpReservedPhoton= nullptr;
    }

    void PhotonGuiding::prepareResources(RenderContext* pRenderContext)
    {
        //Ensure that Falcors emissive lights are up to date
        auto& pLights = mpScene->getLightCollection(pRenderContext);

        //Check if resources needs to be resetted
        if (pLights->getTotalLightCount() != mEmissiveLightCount || mpScene->getLightCount() != mAnalyticLightCount || mRebuildResources)
        {
            mEmissiveLightCount = pLights->getTotalLightCount();
            mAnalyticLightCount = mpScene->getLightCount();
            mTotalLightCount = mEmissiveLightCount + mAnalyticLightCount;

            clearResources();
        }

        //Create Resources
        if (!mpGuidingMapLight)
        {
           float minSideLen = math::ceil(math::sqrt(float(mTotalLightCount)));  // ceiled pixel width/length
           mResolutionLightGM = uint(pow(2.f, math::ceil(math::log2(minSideLen)))); //Nearest power 2

           mpGuidingMapLight = Texture::create2D(
                mpDevice, mResolutionLightGM, mResolutionLightGM, ResourceFormat::R32Uint, 1u, Texture::kMaxPossible, nullptr,
                ResourceBindFlags::UnorderedAccess | ResourceBindFlags::ShaderResource
            );
           mpGuidingMapLight->setName("PhotonGuiding:GuidingMapsLight");
        }

        if (!mpGuidingMapsDirection)
        {
            uint numGuidingTextures = mOptions.useMappingScheme ? mOptions.mappingDirGMCount : mTotalLightCount;
            //Calc atlas texture size
            float minSideLen = math::ceil(math::sqrt(float(numGuidingTextures * mOptions.guidingMapResolution * mOptions.guidingMapResolution))); // ceiled pixel
            mResolutionDirGM = uint(pow(2.f, math::ceil(math::log2(minSideLen)))); //Nearest power 2
            mMipLevelsDirGM = uint(round(math::log2(float(mOptions.guidingMapResolution)))) + 1;

            mpGuidingMapsDirection = Texture::create2D(
                mpDevice, mResolutionDirGM, mResolutionDirGM, ResourceFormat::R32Uint, 1u, mMipLevelsDirGM, nullptr,
                ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess
            );
            mpGuidingMapsDirection->setName("PhotonGuiding:GuidingMapsDirection");
        }

        if (!mpHistogramLight)
        {
            mpHistogramLight = Texture::create2D(
                mpDevice, mResolutionLightGM, mResolutionLightGM, ResourceFormat::R32Float, 1u, 1u, nullptr,
                ResourceBindFlags::UnorderedAccess | ResourceBindFlags::ShaderResource
            );
            mpHistogramLight->setName("PhotonGuiding:HistogramLight");
        }

        if(!mpHistogramDirection)
        {
            mpHistogramDirection = Texture::create2D(
                mpDevice, mResolutionDirGM, mResolutionDirGM, ResourceFormat::R32Float, 1u, 1u, nullptr,
                ResourceBindFlags::UnorderedAccess | ResourceBindFlags::ShaderResource
            );
            mpHistogramDirection->setName("PhotonGuiding:HistogramDirection");
        }

        if (!mpContributionDirection)
        {
            uint mips = mOptions.useMappingScheme ? mMipLevelsDirGM : Texture::kMaxPossible;
            mpContributionDirection = Texture::create2D(
                    mpDevice, mResolutionDirGM, mResolutionDirGM, ResourceFormat::R32Uint, 1u, mips, nullptr,
                    ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess
                );
            mpContributionDirection->setName("PhotonGuiding:ContributionDirection");
        }

        if ((mOptions.useDynamicPMin || mOptions.useMappingScheme) && !mpResourceCounter)
        {
            mpResourceCounter = Buffer::createStructured(mpDevice, sizeof(uint), 2,  ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess, Buffer::CpuAccess::None, nullptr, false);
            mpResourceCounter->setName("PhotonGuiding:ResourceCounter");
        }

        if (mOptions.useMappingScheme) {
            if (!mpContributionLight)
            {
                mpContributionLight = Texture::create2D(
                    mpDevice, mResolutionLightGM, mResolutionLightGM, ResourceFormat::R32Uint, 1u, Texture::kMaxPossible, nullptr, ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess | ResourceBindFlags::RenderTarget
                );
                mpContributionLight->setName("PhotonGuiding:ContributionLight");
            }

            if (!mpGuidingMapsDirectionPrev)
            {
                mpGuidingMapsDirection = Texture::create2D(
                    mpDevice, mResolutionDirGM, mResolutionDirGM, ResourceFormat::R32Float, 1u, mMipLevelsDirGM, nullptr,
                    ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess
                );
                mpGuidingMapsDirection->setName("PhotonGuiding:GuidingMapsDirectionPrev");
            }

            if (!mpMapLightToDirection || !mpGuidingMapsDirectionPrev)
            {
                mpMapLightToDirection = Texture::create2D(mpDevice, mResolutionLightGM, mResolutionLightGM,
                    ResourceFormat::R16Uint, 1u,1u, nullptr, ResourceBindFlags::UnorderedAccess | ResourceBindFlags::ShaderResource);
                mpMapLightToDirection->setName("PhotonGuiding:MapLightToDirection");
                
                mpMapLightToDirectionPrev = Texture::create2D(mpDevice, mResolutionLightGM, mResolutionLightGM,
                    ResourceFormat::R16Uint, 1u,1u, nullptr, ResourceBindFlags::UnorderedAccess | ResourceBindFlags::ShaderResource);
                mpMapLightToDirectionPrev->setName("PhotonGuiding:MapLightToDirectionPrev");
            }

            if (!mpMapDirectionToLight)
            {
                ResourceFormat resourceFormat = mTotalLightCount > 0xFFFF ? ResourceFormat::R32Uint : ResourceFormat::R16Uint;
                uint size = mResolutionDirGM / mOptions.guidingMapResolution;
                mpMapDirectionToLight = Texture::create2D(mpDevice, size, size, resourceFormat, 1u, 1u,
                    nullptr, ResourceBindFlags::UnorderedAccess | ResourceBindFlags::ShaderResource);
                mpMapDirectionToLight->setName("PhotonGuiding::MapDirectionToLight");
            }
        }

        if (mOptions.useDynamicPMin) {
            if (!mpReservedPhoton)
            {
                mpReservedPhoton = Texture::create2D(mpDevice, mResolutionLightGM, mResolutionLightGM, ResourceFormat::R16Uint,
                     1u, 1u,nullptr, ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess);
                mpReservedPhoton->setName("PhotonGuiding:ReservedPhotonsPerLight");
            }
        }
    }

    void PhotonGuiding::reduceLoop(RenderContext* pRenderContext, ref<Texture>& pContributionTex, const uint startMipLevel, const uint dstMipLevel, const bool forceMipMapGen)
    {
        /* A loop for the reduce pass. Uses work group reduce if there are 5 or more mip levels left and uses a simple mip reduce for the remaining levels.
        * Could be optimized further, but current state is sufficently fast
        */

        auto var = mpReducePass->getRootVar();
        bool useMipReduce = forceMipMapGen;         //Mip reduce is used if remaining levels <5 or if forced
        uint increments = forceMipMapGen ? 1 : 5; //The optimized workgroup reduce can handle exactly 5 levels

        for(uint mip = startMipLevel; mip < dstMipLevel; mip += increments)
        {
             //If there are less than 5 levels left, switch to Mip based reduce
            if (!useMipReduce && (mip + increments) >= dstMipLevel)
            {
                increments = 1;
                useMipReduce = true;
            }
            uint dstMip = mip + increments;
            //Use half resolution of src mip level, as the four nearest samples are always summed
            uint3 dispatchDims = uint3(pContributionTex->getWidth(mip), pContributionTex->getHeight(mip), 2u) / 2u; 

            //Set shader resources
            var["CB"]["gDstSize"] = dispatchDims.xy();
            var["CB"]["gUseMip"] = useMipReduce;

            var["gSrc"].setSrv(pContributionTex->getSRV(mip, 1u));
            var["gDst"].setUav(pContributionTex->getUAV(dstMip, 0u, 1u));

            mpReducePass->execute(pRenderContext, dispatchDims);
        }
    }

    void PhotonGuiding::reduceContributionPass(RenderContext* pRenderContext) {
        FALCOR_PROFILE(pRenderContext, "ReduceContribution");

        //Initialize the shader
        if (!mpReducePass)
        {
            Program::Desc desc;
            desc.addShaderLibrary(kShaderReduce).csEntry("main").setShaderModel(kShaderModel);

            DefineList defines;
            mpReducePass = ComputePass::create(mpDevice, desc, defines, true);
        }
                
        //Depending if the mapping scheme is used or not, different reductions are needed
        //If it is not used, the directional contribution is reduced to light and then total contribution
        //When the mapping scheme is used, only the light contribution needs to be reduced to total contribution
        if(!mOptions.useMappingScheme) //Directional Contribution 2 step reduce (direction->light->total)
        {
            const uint mipLevelMax = mpContributionDirection->getMipCount() - 1;
            const uint mipLevelLight = mMipLevelsDirGM-1;     //Mip level of the light contribution

            reduceLoop(pRenderContext, mpContributionDirection, 0, mipLevelLight); //(direction->light)
            reduceLoop(pRenderContext, mpContributionDirection, mipLevelLight, mipLevelMax); //(light->total)

        }else //Light Contribution 1 step reduce (light->total)
        {
            const uint mipLevelMax = mpContributionLight->getMipCount() - 1;
            reduceLoop(pRenderContext, mpContributionLight, 0, mipLevelMax); //(light->total)
        }        
    }

    void PhotonGuiding::updateGuidingMaps(RenderContext* pRenderContext, uint maxPhotonsDistributed)
    {

        updateHistogramsPass(pRenderContext, false);

        updateGuidingMapsPass(pRenderContext, maxPhotonsDistributed, false);

        updateHistogramsPass(pRenderContext, true);

        updateGuidingMapsPass(pRenderContext, maxPhotonsDistributed, true);
    }

    void PhotonGuiding::updateHistogramsPass(RenderContext* pRenderContext, bool isDirectionalResource)
    {
        std::string profileName = "UpdateHistogram_";
        profileName += isDirectionalResource ? "Direction" : "Light";
        FALCOR_PROFILE(pRenderContext, profileName);

        //Shared runtime defines for Histogram and Guiding Map update
        auto getRuntimeDefines = [&]()
        {
            DefineList defines;
            defines.add("LIGHT_COUNT", std::to_string(mTotalLightCount));
            defines.add("USE_MAPPING", mOptions.useMappingScheme ? "1" : "0");
            return defines;
        };

        //Get Compute Pass
        uint passIndex = isDirectionalResource ? 1 : 0;
        ref<ComputePass>& pUpdateHistogramPass = mpUpdateHistogramsPass[passIndex];

        //Create Shader
        if (!pUpdateHistogramPass)
        {
            Program::Desc desc;
            desc.addShaderLibrary(kShaderUpdateHistograms).csEntry("main").setShaderModel(kShaderModel);

            DefineList defines;
            defines.add("IS_DIRECTIONAL", isDirectionalResource ? "1" : "0");
            defines.add(getRuntimeDefines());
            
            pUpdateHistogramPass = ComputePass::create(mpDevice, desc, defines, true);
        }

        pUpdateHistogramPass->getProgram()->addDefines(getRuntimeDefines()); //Update defines
        auto var = pUpdateHistogramPass->getRootVar();

        //Set resources
        var["CB"]["gDispatchSize"] = isDirectionalResource ? mResolutionDirGM : mResolutionLightGM;
        var["CB"]["gIterationCount"] = mGuidingIterationCount;
        var["CB"]["gDirectionalResourceSize"] = mOptions.guidingMapResolution;
        var["CB"]["gExponentialMovingAverageFactor"] = mOptions.exponentialMovingAverageFactor;

        // Depending if mapping is used, different contribution textures are used
        // If mapping is disabled, light contribution is stored at a mipmap level of the directional contribution
        // else, a seperate resource is bound.
        if (mOptions.useMappingScheme)
        {
            //TODO
        }
        else
        {
            if (isDirectionalResource)
            {
                var["gTotalContribution"].setSrv(mpContributionDirection->getSRV(mMipLevelsDirGM - 1,1u));
                var["gContribution"].setSrv(mpContributionDirection->getSRV(0,1u));
                var["gHistogram"] = mpHistogramDirection;
            }
            else
            {
                var["gTotalContribution"].setSrv(mpContributionDirection->getSRV(mpContributionDirection->getMipCount()-1,1u));
                var["gContribution"].setSrv(mpContributionDirection->getSRV(mMipLevelsDirGM - 1,1u));
                var["gHistogram"] = mpHistogramLight;
            }
        }
        
        uint3 dispatchIndex = isDirectionalResource ?
            uint3(mResolutionDirGM,mResolutionDirGM,1) :
            uint3(mResolutionLightGM,mResolutionLightGM,1);

        pUpdateHistogramPass->execute(pRenderContext, dispatchIndex);
    }

    void PhotonGuiding::updateGuidingMapsPass(RenderContext* pRenderContext, uint maxPhotonsDistributed, bool isDirectionalResource)
    {
        std::string profileName = "UpdateGuidingMap_";
        profileName += isDirectionalResource ? "Direction" : "Light";
        FALCOR_PROFILE(pRenderContext, profileName);

        //Shared runtime defines for Histogram and Guiding Map update
        auto getRuntimeDefines = [&]()
        {
            DefineList defines;
            defines.add("LIGHT_COUNT", std::to_string(mTotalLightCount));
            defines.add("USE_MAPPING", mOptions.useMappingScheme ? "1" : "0");
            defines.add("RESERVED_PHOTONS_PER_CELL", isDirectionalResource ?
                std::to_string(mOptions.reservedPhotonsPerDirection) :
                std::to_string(mOptions.reservedPhotonsPerLight));
            defines.add("PHOTONS_NEEDED_FOR_DIR_GM", std::to_string(mOptions.photonNeededForGM));
            return defines;
        };

        //Get Compute Pass
        uint passIndex = isDirectionalResource ? 1 : 0;
        ref<ComputePass>& pUpdateGuidingMapsPass = mpUpdateGuidingMapsPass[passIndex];

        //Create Shader
        if (!pUpdateGuidingMapsPass)
        {
            Program::Desc desc;
            desc.addShaderLibrary(kShaderUpdateGuidingMaps).csEntry("main").setShaderModel(kShaderModel);

            DefineList defines;
            defines.add("IS_DIRECTIONAL", isDirectionalResource ? "1" : "0");
            defines.add(getRuntimeDefines());
            
            pUpdateGuidingMapsPass = ComputePass::create(mpDevice, desc, defines, true);
        }

        pUpdateGuidingMapsPass->getProgram()->addDefines(getRuntimeDefines()); //Update defines
        auto var = pUpdateGuidingMapsPass->getRootVar();

        //Calculate the free photons for the light Guiding Map
        uint freePhotonsPerLight = maxPhotonsDistributed;
        if(!isDirectionalResource)
        {
            freePhotonsPerLight = maxPhotonsDistributed - mOptions.reservedPhotonsPerLight * mTotalLightCount;
        }

         //Set resources
        var["CB"]["gDispatchSize"] = isDirectionalResource ? mResolutionDirGM : mResolutionLightGM;
        var["CB"]["gDirectionalResourceSize"] = mOptions.guidingMapResolution;
        var["CB"]["gFreePhotonsLight"] = freePhotonsPerLight;

        auto pGuidingMap = isDirectionalResource ? mpGuidingMapsDirection : mpGuidingMapLight;
        var["gHistogram"] = isDirectionalResource ? mpHistogramDirection : mpHistogramLight;
        var["gGuidingMap"] = pGuidingMap;
        if(isDirectionalResource)
            var["gGuidingMapLight"] = mpGuidingMapLight;

        uint3 dispatchIndex = isDirectionalResource ?
            uint3(mResolutionDirGM,mResolutionDirGM,1) :
            uint3(mResolutionLightGM,mResolutionLightGM,1);

        pUpdateGuidingMapsPass->execute(pRenderContext, dispatchIndex);

        //Reuse the reduce loop to generate MipMaps for the Guiding Maps, that are used for top-down quadtree traversal
        reduceLoop(pRenderContext, pGuidingMap, 0, pGuidingMap->getMipCount()-1, true);

    }
} //namespace Falcor
