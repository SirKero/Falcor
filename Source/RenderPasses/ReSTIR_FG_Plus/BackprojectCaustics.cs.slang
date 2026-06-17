#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.RaytracingInline;
import Utils.Sampling.SampleGenerator;
import Utils.Color.ColorHelpers;
import StructsAndHelpers;

#ifndef BACKPROJECT_TMP_RESERVOIRS
#define BACKPROJECT_TMP_RESERVOIRS 0
#endif

#if BACKPROJECT_TMP_RESERVOIRS
    StructuredBuffer<CausticReservoir> gCausticReservoir;   //Temporal reservoir

    RWTexture2D<int> gLightTraceHeadCounter;     //
    RWStructuredBuffer<int> gLightTraceLinkedList; // next pointer
#else //Initialize initial Caustic Reservoir by using RIS on all backprojected light paths
    StructuredBuffer<int> gLightTraceLinkedList; // next pointer
    StructuredBuffer<PhotonData> gPhotonData;    // Photon Data
    StructuredBuffer<PhotonGuidingData> gPhotonGuidingData; //Photon guiding data
    StructuredBuffer<PackedHitInfo> gPhotonHitInfo; //Hit Info

    RWStructuredBuffer<CausticReservoir> gCausticReservoir;
    RWTexture2D<uint2> gCausticReservoirGuidingData; 
    RWTexture2D<int> gLightTraceHeadCounter; // Is cleared
#endif

cbuffer CB
{
    uint gFrameCount;          // Current it for sample gen
    uint2 gScreenDims;         //Screen dimensions
    float _pad;
}

static const uint kRNGNumPasses = RNG_NUM_PASSES;
static const uint kMIHints = (uint)MaterialInstanceHints::AdjustShadingNormal;
static const bool kUsePhotonGuiding = USE_PHOTON_GUIDING;

// Backproject Temporal Caustic Reservoirs before resampling. Only used if photon path shift is disabled (e.g. static scenes)
#if BACKPROJECT_TMP_RESERVOIRS
void backprojectTemporalCausticReservoirs(const uint2 pixel)
{
    // Load caustic reservoir
    const int reservoirIndex = index2Dto1D(pixel, gScreenDims.x);
    CausticReservoir r = gCausticReservoir[reservoirIndex];
    if (!r.isValid())
        return;

    HitInfo hit = HitInfo(r.sampleSurface);
    let lod = ExplicitLodTextureSampler(0);
    ShadingData sd = loadShadingData(hit, r.sampleSurfaceView, lod);

    // Backproject Reservoir to camera lens
    causticPhotonBackprojection(sd, gScreenDims, reservoirIndex, gLightTraceHeadCounter, gLightTraceLinkedList);
}
#else // BACKPROJECT_TMP_RESERVOIRS

//Initialization of the caustic reservoir by collecting all backprojected light paths with RIS
void initializeCausticReservoir(const uint2 pixel)
{
    CausticReservoir r = CausticReservoir();
    PhotonGuidingData pgd = PhotonGuidingData();
    SampleGenerator sg = SampleGenerator(pixel, gFrameCount * kRNGNumPasses + 1);
    let lod = ExplicitLodTextureSampler(0);
    r.c = 1;

    // Get head buffer index
    int headIndex = gLightTraceHeadCounter[pixel];
    while (headIndex >= 0)
    {
        // Get Photon and Surface Data
        HitInfo photonHit = HitInfo(gPhotonHitInfo[headIndex]);
        if (!photonHit.isValid())
            break;
        PhotonData photonData = gPhotonData[headIndex];

        // Init Material
        ShadingData sd = loadShadingData(photonHit, photonData.dir, lod);
        let mi = gScene.materials.getMaterialInstance(sd, lod, kMIHints);

        // Get Camera backprojection PDF
        float3 directionToCamera = gScene.camera.getPosition() - sd.posW;
        float distanceToCamera = length(directionToCamera);
        directionToCamera /= distanceToCamera;
        const float3 camForward = normalize(gScene.camera.data.cameraW);
        const float backprojectJacobian = getBackprojectJacobian(gScreenDims.y, directionToCamera, distanceToCamera);

        // Eval BSDF, targetFunction and reservoir weight
        const float3 bsdf = mi.eval(sd, directionToCamera, sg);
        float targetFunction = luminance(photonData.flux * bsdf);
        float w = targetFunction * backprojectJacobian;

        r.wSum += w;
        bool selectNew = (sampleNext1D(sg) * r.wSum) < w;
        if (selectNew) {
            r.sampleSurface = photonHit.getData();
            r.sampleSurfaceView = photonData.dir;
            r.photonRadiance = photonData.flux;
            r.subPixelJacobian = backprojectJacobian * dot(directionToCamera, sd.getOrientedFaceNormal()); //Cos normal is included in BSDF
            r.packedPhotonRetraceData = photonData.packPhotonRetraceData();
            r.invPhotonScaleFactor = photonData.invPhotonScaleFactor;
            r.targetFunction = targetFunction;
            if (kUsePhotonGuiding)
                pgd = gPhotonGuidingData[headIndex];
        }

        // Update head index
        int newHead = gLightTraceLinkedList[headIndex];
        headIndex = newHead;
    }

    // Finalize Reservoir
    if (r.targetFunction > 0) {
        r.wSum /= r.targetFunction;
    }
    else
        r.wSum = 0;

    gCausticReservoir[index2Dto1D(pixel, gScreenDims.x)] = r;
    gLightTraceHeadCounter[pixel] = -1; // Clear Head Counter
    if (kUsePhotonGuiding)
        gCausticReservoirGuidingData[pixel] = pgd.pack();
}
#endif // BACKPROJECT_TMP_RESERVOIRS
[numthreads(16, 16, 1)]
void main(uint2 pixel: SV_DispatchThreadID)
{
    #if BACKPROJECT_TMP_RESERVOIRS
        backprojectTemporalCausticReservoirs(pixel);
    #else
        initializeCausticReservoir(pixel);
    #endif
}
