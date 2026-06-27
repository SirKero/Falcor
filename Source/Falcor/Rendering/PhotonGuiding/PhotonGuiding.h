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

        - Create the class after loading the scene

        - Call the "update" function prior to tracing photons

        - Use the "getPhotonDispatchSize" function for the trace photon dispatch size

        - Use the "getDefines" and "setShaderData" functions, to set shader defines and resources. 

        In the shader, import PhotonGuiding.slang (import Rendering.PhotonGuiding.PhotonGuiding;), which allows the usage of the following functions

        - gPhotonGuiding.sampleGuidedLightAndDirection(...)     >> Creates a PhotonGuidingSample from the guiding map (light index and random numbers)
        - gPhotonGuiding.createPhotonSample(...)                >> Helper to sample the scenes light sources. Sample is stored as a PhotonGuidingPhotonLightSample
        - gPhotonGuiding.guidingMapUVToPixel(...)               >> Converts the random numbers to Guiding Map Pixels for compact storage

        - gPhotonGuiding.addGuidingContribution(...)            >> Records contribution. Needs light index and guiding pixels

        For more infos on the shader functions, see "PhotonGuiding.slang"

    */
    class FALCOR_API PhotonGuiding
    {
    public:

        /* Options/UI struct with resonable defaults
        */
        struct Options {
            uint guidingMapResolution = 64;               // x,y size of a guiding map
            uint discretizedContributionFactor = 256;     // Factor for the discretization of the contribution
            uint discretizedContributionMax = 1024;       // Max value a contribution can reach
            float exponentialMovingAverageFactor = 0.3f;  // Alpha factor for the exponential moving average
            uint reservedPhotonsPerLight = 64;      // Reserved photons per light
            uint reservedPhotonsPerDirection = 1;   // Reserved photons per direction cell
            uint photonNeededForGM = 4096;          // Minimum Photons needed to generate a GM (1 Photon per light on 64x64 dir GMs)

            uint traversalBlockSize = 16;   //For traversal, the photonID is linearized in blocks to improve locality 

            // Mapping scheme options, that only maps a small number of directional Guiding Maps instead of one
            // for every light. Is beneficial in terms of memory and runtime, when a scene contains a large
            // number of lights. 
            bool useMappingScheme = false;  //Mapping enabled. Is automatically switched to true, if the scene contains >1000 lights    
            uint mappingDirGMCount = 32;    //Maximum number of Guiding Maps that are reserved
            uint mappingPhotonNeededToCreate = 16384; //Minimum photons needed to create a GM with mapping

            bool useDynamicPMin = false;    //Enables and disabled dynamic PMin
            float2 dynamicPMinMinMaxDistance = float2(1.f, 16.f); //Distance used for the range
            uint2 dynamicPMinPhotonsMinMax = uint2(4, 1024); //Photons at maximum and minimum distance

            bool debugEnable = false;    //Debug view
            bool debugSelectLightHelperMode = false; //Helper mode to select light
            float3 debugSelectLightHelperModeColor = float3(0,0,1); //Helper mode color
            int debugSelectedLightIndex = -1;   // Selected Light index
            float debugLightGMScaleFactor = 1.0;
            float3 debugLightGMColor = float3(0,1,0);
            float debugDirGMScaleFactor = 1.0;
            float3 debugDirGMColor = float3(1,0,0);
            bool debugMappingShowDirectionalGM = false; //Shows the directional GM
        };

        /* Creates the class and initial resources based on the scene. Needs to be re-created when switching scenes
        */
        PhotonGuiding(
            ref<Device> pDevice,
            ref<Scene> pScene,
            RenderContext* pRenderContext
        );

        /* Destroys class. Should be called when the scene changes.
        */
        ~PhotonGuiding();

        /* Updates the Guiding Maps and clears the contribution textures
        */
        void update(RenderContext* pRenderContext, uint maxPhotonsDistributed);

        /*  Return optimal dispatch size for the photon tracing shader. Ensures that linearization of the
            photonID does not break
        */
        uint2 getPhotonDispatchSize(uint numberOfPhotons);

        /* Get defines needed for recording the contribution. Can change at runtime
        */
        DefineList getDefines();

        /* Set shader data for recording the contribution
        */
        void setShaderData(const ShaderVar& rootVar);

        /* Get render UI for Photon Guiding. Returns true if any settings where changed
        */
        bool renderUI(Gui::Widgets& widget);

        /* Renders a debug view into dstTexture. Unordered Access View flag needs to be set in dstTexture
        */
        void renderDebugView(RenderContext* pRenderContext, ref<Texture>& dstTexture);

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
        uint            mResolutionMap = 0;         //Size (x&y) of the map texture
        uint            mGuidingIterationCount = 0; //Number of guiding iterations

        int             mTracePhotonNumberOfPhotonsLastFrame = -1;     //Photon count from last frame
        uint2           mOptimalTracePhotonDispatchDims = uint2(0); //Stored dispatch dims that can be reused if photon count did not change

        uint            mMinPhotonNeededForGuiding = 0;     //Minimum amount of photons needed to cover reserved lights
        bool mWarningNotEnoughDispatchedPhotons = false;    //Warning is triggered if not enough photons are dispatched
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
        ref<Texture>    mpHistogramDirectionPrev;  //Previous frames Histogram. Needed as update uses random access in this case
        ref<Texture>    mpMapLightToDirection;      //Maps light index to a directional Guiding Map or invalid if there is none. Is the size of the light Guiding Map.
        ref<Texture>    mpMapLightToDirectionPrev;  //Light index to directional Guiding Map mapping from previous frame
        ref<Texture>    mpMapDirectionToLight;      //Maps directional Guiding Mapt to light Index. Is the size of all directional Guiding Maps (default 64)

        //Dynamic Photon Minimum
        ref<Texture>    mpReservedPhoton;           //Reserved Photons per light

        //
        // Shader Programs
        //

        ref<ComputePass> mpReducePass;              //Reduces the Contribution
        ref<ComputePass> mpUpdateHistogramsPass[2];    //Updates the histogram with the normalized contribution. 0=Light, 1=Direction
        ref<ComputePass> mpUpdateGuidingMapsPass[2];   //Updates the guiding maps with the histograms. 0=Light, 1=Direction
        ref<ComputePass> mpDynamicPMinPass;             //Dynamically determines the PMin for each light 
        ref<ComputePass> mpDebugViewPass;              //Debug view

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
                
        /* Render loop used in the reduction pass
        */
        void reduceLoop(RenderContext* pRenderContext, ref<Texture>& pContributionTex, const uint startMip, const uint dstMip, const bool forceMipMapGen = false);

        /* Caluclates current Histogram weight from the contribution and updates temporally with
        *  the histogram weight from last frame
        */
        void updateHistogramsPass(RenderContext* pRenderContext, bool isDirectionalResource);

        /* Creates the guiding maps from the histogram and number of photons distributed
        */
        void updateGuidingMapsPass(RenderContext* pRenderContext, uint maxPhotonsDistributed, bool isDirectionalResource);

        /* Dynamically reserves the photons per light cell, depending on (light) distance to camera (origin)
        */
        void dynamicallyPMinPass(RenderContext* pRenderContext);
    };
}
