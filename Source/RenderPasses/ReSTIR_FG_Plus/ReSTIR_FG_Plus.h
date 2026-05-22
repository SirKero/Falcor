#pragma once
#include "Falcor.h"
#include "RenderGraph/RenderPass.h"
#include "Rendering/RTXDI/RTXDI.h"
#include "Rendering/Lights/EmissiveLightSampler.h"
#include "Rendering/Lights/LightBVHSampler.h"
#include "Rendering/Lights/EnvMapSampler.h"

#include "Rendering/AccelerationStructure/CustomAccelerationStructure.h"

using namespace Falcor;

class ReSTIR_FG_Plus : public RenderPass
{
public:
    FALCOR_PLUGIN_CLASS(ReSTIR_FG_Plus, "ReSTIR_FG_Plus", "Real-Time Global Illumination with Caustics");

    static ref<ReSTIR_FG_Plus> create(ref<Device> pDevice, const Properties& props) { return make_ref<ReSTIR_FG_Plus>(pDevice, props); }

    ReSTIR_FG_Plus(ref<Device> pDevice, const Properties& props);

    virtual Properties getProperties() const override;
    virtual RenderPassReflection reflect(const CompileData& compileData) override;
    virtual void compile(RenderContext* pRenderContext, const CompileData& compileData) override {}
    virtual void execute(RenderContext* pRenderContext, const RenderData& renderData) override;
    virtual void renderUI(Gui::Widgets& widget) override;
    virtual void setScene(RenderContext* pRenderContext, const ref<Scene>& pScene) override;
    virtual bool onMouseEvent(const MouseEvent& mouseEvent) override { return false; }
    virtual bool onKeyEvent(const KeyboardEvent& keyEvent) override { return false; }

private:

    struct ResamplingSettings
    {
        bool enable = true;
        uint confidenceCap = 20;                // Maximum confidence allowed
        uint spatialSamples = 1;                // Number of spatial samples
        uint disocclusionBoostExtraSamples = 1; // Number of spatial samples if no temporal surface was found
        float samplingRadius = 20.f;            // Sampling radius in pixel
    };

    struct PathLengthSettings {
        uint bounces = 10;  //Total Bounces
        uint diffuse = 3;   //Max Diffuse Bounces on the path
        uint specular = 3;  //Max Specular Bounces on the path
        uint delta = 10;    //Max Delta Bounces on the Path

        const uint pack() const
        {
            return (bounces & 0xFF) | ((diffuse & 0xFF) << 8) | ((specular & 0xFF) << 16) | ((delta & 0xFF) << 24);
        }
    };

    struct Options {

        //
        //Photon Tracing settings
        //
        PathLengthSettings photonPathLenght = {};       //Photon Path Length
        uint photonsDispatched = 1000000;               //Number of photons, that are distributed each frame
        uint photonBufferSizeGlobal = 1000000;          //Maximum global photons that can be stored
        uint photonBufferSizeCaustic = 1000000;         //Maximum caustic photons that can be stored
        float photonMixedLightRatio = 0.5f;             //Ratio if both analytic and emissive lights are used. 0 -> 0% Analytic, 100% Emissive
        //Radius
        bool photonUseAdaptiveRadius = true;            //Uses a photon radius that is dependent on the (linear) distance to the camera
        float2 photonAdaptiveRadius = float2(4.f, 2.f); //(Global|Caustic) Pixel Size scale for adptive radius
        float2 photonRadius = float2(0.008f, 0.002f);   //(Global|Caustic) Fixed World Space Radius
        //Optimization
        float photonGlobalRejection = 0.3f;             // Fixed probability that a global photon is not stored
        float photonASBuildBufferOverestimate = 1.15f; // Guard percentage for AS building (Uses (delayed) CPU Photon Counter to estimate)

        //
        // Camera Path Tracing Settings
        //

        uint cameraMaxPathLength = 10;

        //
        // Resample Settings
        //

        float jacobianDistanceThreshold = 0.001f;          // Threshold for Jacobian distances

        //
        // Material Options
        //

        bool useLambertianDiffuseBSDF = true;           // Diffuse BSDF used by ReSTIR PT and SuffixReSTIR
        float specularRoughnessThreshold = 0.25f;       // Any material below this is considered specular
        bool evaluateDeltaPDFs = false;                 // If set on true, delta pdfs are evaluated (always 0), else they are set to 1
        bool enableAlphaTest = true;                    // Alpha Test
    };

    //Resets all render passes
    void resetAllRenderPasses();

    //Initializes the emissive sampler used to sample photons
    void prepareLightingStructure(RenderContext* pRenderContext);

    //Initializes and updates all textures and buffers
    void prepareResources(RenderContext* pRenderContext, const RenderData& renderData);

    //Traces the photons and builds the photon Acceleration Structure
    void tracePhotonsPass(RenderContext* pRenderContext, const RenderData& renderData);

    //Generates the initial Path Samples and initialized RTXDI Surfaces
    void generateInitialSamplesPass(RenderContext* pRenderContext, const RenderData& renderData);

    //Collects caustic backprojections and initializes the caustic reservoir
    void backprojectCausticsPass(RenderContext* pRenderContext, const RenderData& renderData);

    //Splats Caustic reservoirs from last frame to current frame
    void splatTemporalReservoirsPass(RenderContext* pRenderContext, const RenderData& renderData);

    //Sort the splatted reservoirs so they can be used in the resampling pass
    void sortSplattedReservoirsPass(RenderContext* pRenderContext, const RenderData& renderData);

    //Retrace Path Reservoirs with Path Length > 0 (or if final gather sample should be updated)
    void retraceReservoirPass(RenderContext* pRenderContext, const RenderData& renderData, uint numPass);

    //Reservoir Resampling for Path Reservoirs
    void resampleReservoirsPass(RenderContext* pRenderContext, const RenderData& renderData, uint numPass);

    //Reservoir Resampling for Caustic Reservoirs
    void resampleReservoirCausticPass(RenderContext* pRenderContext, const RenderData& renderData);

    //Evaluate all Reservoirs (Path, Caustic and RTXDI)
    void evaluateReservoirsPass(RenderContext* pRenderContext, const RenderData& renderData);

    //Get Materials defines
    DefineList getMaterialDefines();

    //Gets normalized pixel area for back projection
    float getNormalizedPixelArea();

    //
    // Pointers
    //
    ref<Scene> mpScene;                     // Scene Pointer
    ref<SampleGenerator> mpSampleGenerator; // GPU Sample Gen
    std::unique_ptr<RTXDI> mpRTXDI;         // Ptr to RTXDI for direct use
    RTXDI::Options mRTXDIOptions;           // Options for RTXDI

    std::unique_ptr<EmissiveLightSampler> mpEmissiveLightSampler; // Light Sampler
    std::unique_ptr<CustomAccelerationStructure> mpPhotonAS;      // Photon Accleration Structure
    std::unique_ptr<EnvMapSampler> mpEnvMapSampler;               // Env Map Sampler

    //
    // Parameters
    //
    Options mOptions = {};                     //Options for the renderer
    uint mFrameCount = 0;
    uint mReservoirIndex = 0;                  //Track reservoir index for path reservoir
    uint2 mScreenRes = uint2(0, 0);
    bool mResetScreenTex = false;
    bool mOptionsChanged = false;

    // Light
    bool mHasLights = false;           // True if the scene has any light sources
    bool mMixedLights = false;         // True if analytic and emissive lights are in the scene
    EmissiveLightSamplerType mEmissiveLightSamplerType = EmissiveLightSamplerType::LightBVH; //Emissive Sampler Type
    LightBVHSampler::Options mLightBVHOptions;                                               //(Cached) Options for Light BVH Sampler
    bool mRebuildLightSampler = false;                                                       //If true, Emissive Sampler is rebuild
    float3 mNeeLightSelectProb = float3(0.33f);                                              //Probability to select a NEE/Analytic/EnvMapSample

    //ReSTIR Reservoirs
    ResamplingSettings mResampleSettingsPath = {};
    ResamplingSettings mResampleSettingsCaustic = {};
    bool mRebuildReservoirBuffer = false;               // Rebuild the reservoir buffer
    bool mClearReservoir = true;                        // Clears both reservoirs
    bool mCanResample = false;                          // Resampling is only allowed if last iterations reservoir was created


    float mRelativeDepthThreshold = 0.15f;              // Relative Depth threshold (is neighbor 0.1 = 10% as near as the current depth)
    float mNormalThreshold = 0.6f;                      // Cosine of maximum angle between both normals allowed
    
    bool mUsePathThreshold = false;                     // Enable resampling only if path length are the same
    bool mUsePhotonsForDirectLightInReflections = true; // Uses photons for direct light in reflections, else the final gather sample is used
    uint mRNGNumPasses = 12;                             // Offset for RNG generator

    //TODO Remove
    uint mFGRayMaxPathLength = 10;                      // Max path length for the final gather ray
    float mJacobianDistanceThreshold = 0.001f;          // Threshold for Jacobian distances


    //Splatting
    float4x4 mTemporalCameraViewProjection = float4x4::identity();
    float3 mTemporalCameraPosition = float3(0);
    float3 mTemporalCameraForward = float3(0);
    float mNormalizedPixelArea = 1.0; //For light trace
    bool mEnableLightTraceSplatting = true;

    //Photon Distribution
    uint2 mPhotonCountUI = uint2(mOptions.photonBufferSizeGlobal, mOptions.photonBufferSizeCaustic);
    bool mPhotonBufferSizeChanged = false;

    //Debug
    bool mClearDebugTexture = true; 

    //
    // Resources
    //
    ref<Texture> mpVBufferPrev;             // VBuffer Hit from last frame
    ref<Texture> mpViewPrev;                // Camera View from last frame
    ref<Buffer> mpPhotonAABB[2];            // Photon AABBs for Acceleration Structure building
    ref<Buffer> mpPhotonData[2];            // Additional Photon data (flux, dir)
    ref<Buffer> mpPhotonHitInfo;            // Hit info for Photons. Is used for backprojections
    ref<Buffer> mpPhotonCounter;            // Photon Counter
    ref<Buffer> mpPhotonCounterCPU;         // CPU copy of counter for readback
    ref<Buffer> mpCausticReservoir[2];      // Reservoir for the Caustic sample
    ref<Buffer> mpPathReservoir[2];         // Reservoir storing the path in primary path space
    ref<Buffer> mpReservoirRetrace[2];      // Buffer storing the retrace reservoir data

    ref<Texture> mpLightTraceHeadCounter;   //Screen size head buffer counter for light tracing to store the first hit
    ref<Buffer> mpLightTraceLinkedList;     //Linked List for light tracing

    //Splatting
    ref<Buffer> mpSplattingGlobalCounter;   //Counter used in Splatting
    ref<Buffer> mpSplattingCellCounter;     //Per pixel cell counter
    ref<Buffer> mpSplattingCellOffsets;     //Per pixel cell offsets
    ref<Buffer> mpSplattingSortingData;     //Indices needed for sorting
    ref<Buffer> mpSplattingSortedReservoirs;//Sorted reservoirs

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

    RayTraceProgramHelper mTracePhotonPass;             // Trace Photons and build AS
    RayTraceProgramHelper mGenerateInitialSamplesPass;  // Trace Final Gather rays and collect photons
    RayTraceProgramHelper mRetracePathReservoirsPass;   // Retrace the path Reservoirs needed for GRIS MIS

    ref<ComputePass> mpBackprojectCausticSamplesPass;   // Backproject the caustic samples
    ref<ComputePass> mpResampleReservoirPass;           // Resampling Pass for the Path Reservoirs
    ref<ComputePass> mpResampleReservoirCausticPass;    // Resampling Pass for Caustic Reservoirs
    ref<ComputePass> mpEvaluateReservoirsPass;          // Evaluates ReSTIR DI and FG reservoirs

    //Splatting
    ref<ComputePass> mpTemporalSplatReservoirs;         //Reprojects reservoirs from last frame to curren
    ref<ComputePass> mpSplatSortComputeCellOffsets;     //Sort step 1, compute cell offsets
    ref<ComputePass> mpSplatSortCellData;               //Sort step 2, sort the cell data
};

