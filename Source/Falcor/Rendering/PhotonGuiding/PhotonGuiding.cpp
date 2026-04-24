#include "PhotonGuiding.h"

namespace Falcor
{
    //Shader Paths and UI elements
    namespace
    {
        const std::string kShaderFolder = "Rendering/PhotonGuiding/"; 
        const std::string kShaderReduce = kShaderFolder + "Reduce.cs.slang";

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

    void PhotonGuiding::update(RenderContext* pRenderContext)
    {
        reduceContributionPass(pRenderContext);

        pRenderContext->clearUAV(mpContributionDirection->getUAV(0).get(), uint4(0));
    }

    DefineList PhotonGuiding::getDefines()
    {
        DefineList defines = {};
        defines.add("PHOTON_GUIDING_DISCRETIZED_CONTRIBUTION_FACTOR", std::to_string(mOptions.discretizedContributionFactor));
        defines.add("PHOTON_GUIDING_DISCRETIZED_CONTRIBUTION_MAX", std::to_string(mOptions.discretizedContributionMax));
        defines.add("PHOTON_GUIDING_USE_MAPPED_GM", std::to_string(mOptions.useMappingScheme));
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
                ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess | ResourceBindFlags::RenderTarget
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
                    ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess | ResourceBindFlags::RenderTarget
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
                    ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess | ResourceBindFlags::RenderTarget
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

    void PhotonGuiding::reduceLoop(RenderContext* pRenderContext, ref<Texture> pContributionTex, const uint startMipLevel, const uint dstMipLevel)
    {
        /* A loop for the reduce pass. Uses work group reduce if there are 5 or more mip levels left and uses a simple mip reduce for the remaining levels.
        * Could be optimized further, but current state is sufficently fast
        */

        auto var = mpReducePass->getRootVar();
        bool useMipReduce = false;      //Mip reduce is used if remaining levels <5
        uint increments = 5;            //The optimized workgroup reduce can handle exactly 5 levels

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
} //namespace Falcor
