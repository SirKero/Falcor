#pragma once
#include "Core/Macros.h"
#include "Core/Enum.h"
#include "Scene/Scene.h"
#include <Utils/Math/ScalarTypes.h>
#include <memory>
#include <type_traits>
#include <vector>

namespace Falcor
{
    class RenderContext;
    /*  Photon Guiding helper for integration of Real-Time (or Offline) Photon Guiding into Photon Mappers

        This class is responsible for maintaining and updating the Guiding Resources and offers a interface
        for recording the guiding contribution and creating a Photon Sample

        To use Photon Guiding properly the following steps needs to occur:

        TODO

    */
    class FALCOR_API PhotonGuiding
    {
    public:

        /* Options/UI struct with resonable defaults
        */
        struct Options {
            uint guidingMapResolution = 64;
            uint discretizedContributionFactor = 256;
            uint discretizedContributionMax = 1024;

            bool useMappingScheme = false;
            uint mappingDirGMCount = 64;

            bool useDynamicPMin = false;
        };
        /*
        */
        PhotonGuiding(
            ref<Device> pDevice,
            ref<Scene> pScene,
            RenderContext* pRenderContext
        );

        /* Destroys class. Should be called when the scene changes.
        */
        ~PhotonGuiding();

        /* 
        */
        void update(RenderContext* pRenderContext);

        /* Get defines needed for recording the contribution. Can change at runtime
        */
        DefineList getDefines();

        /* Set shader data for recording the contribution
        */
        void setShaderData(const ShaderVar& rootVar);

    private:
        ref<Scene>      mpScene;    //< Current scene 
        ref<Device>     mpDevice;   //< Device
        Options         mOptions;   //< Options

        bool            mRebuildResources = false;  //Resources needs to be reset
        uint            mTotalLightCount = 0;       //All lights in the scene
        uint            mEmissiveLightCount = 0;    //Emissive (Triangle) Light Count
        uint            mAnalyticLightCount = 0;    //Analytic (Point,Spot) Light Count

        uint            mMipLevelsDirGM = 0;        //MIP levels for Directional Guiding Map
        uint            mResolutionLightGM = 0;     //Size (x&y) of the texture that includes all lights
        uint            mResolutionDirGM = 0;       //Size (x&y) of the texture that includes all GMs

        //
        // Resources
        //

        //Guiding Textures for Directional Atlas (<1024 lights)
        ref<Texture>    mpGuidingMapLight;          //A texture containing the light Guiding Map
        ref<Texture>    mpGuidingMapsDirection;     //A texture containing all directional Guiding Maps (Atlas)
        ref<Texture>    mpHistogramLight;           //A texture containing the guiding weight for the lights
        ref<Texture>    mpHistogramDirection;       //A texture containing all directional Histogram weights
        ref<Texture>    mpContributionDirection;    //Contribution Texture for all directions. 

        //Resources additionally needed for mapping scheme (>1024 lights)
        ref<Buffer>     mpResourceCounter;          //Resource counter needed for Mapping Index (0) and dynamic Photon Minimum (1)
        ref<Texture>    mpContributionLight;        //Contribution Texture for lights
        ref<Texture>    mpGuidingMapsDirectionPrev; //Previous frames Guiding Map. Needed as update uses random access in this case
        ref<Texture>    mpMapLightToDirection;      //Maps light index to a directional Guiding Map or invalid if there is none. Is the size of the light Guiding Map.
        ref<Texture>    mpMapLightToDirectionPrev;  //Light index to directional Guiding Map mapping from previous frame
        ref<Texture>    mpMapDirectionToLight;      //Maps directional Guiding Mapt to light Index. Is the size of all directional Guiding Maps (default 64)

        //Dynamic Photon Minimum
        ref<Texture>    mpReservedPhoton;           //Reserved Photons per light

        //
        // Shader Programs
        //

        ref<ComputePass> mpReducePass;              //Reduces the Contribution


        //
        // Internal Functions
        //

        /* Clears all Resources
        */
        void clearResources();

        /* Create (and update) used Textures and Buffers
        */ 
        void prepareResources(RenderContext* pRenderContext);

        /* Reduce pass to get light and total contribution
        */
        void reduceContributionPass(RenderContext* pRenderContext);
    };
}
