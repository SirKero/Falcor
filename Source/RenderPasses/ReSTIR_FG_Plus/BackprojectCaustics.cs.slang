#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.RaytracingInline;
import Utils.Sampling.SampleGenerator;
import Utils.Color.ColorHelpers;
import StructsAndHelpers;

RWStructuredBuffer<ReservoirCaustic> gCausticReservoir;

RWTexture2D<int> gLightTraceHeadCounter;     // Is cleared
StructuredBuffer<int> gLightTraceLinkedList; // next pointer
StructuredBuffer<PhotonData> gPhotonData;    // Photon Data
StructuredBuffer<PackedHitInfo> gPhotonHitInfo; //Hit Info

cbuffer CB
{
    uint gFrameCount; // Current it for sample gen
    uint gFrameDimX;                //Frame Dims in X for linear reservoir buffer offset
    float gNormalizedPixelArea;
}

static const uint kRNGNumPasses = RNG_NUM_PASSES;
static const uint kMIHints = (uint)MaterialInstanceHints::AdjustShadingNormal;

[numthreads(16, 16, 1)]
void main(uint2 pixel: SV_DispatchThreadID)
{
    ReservoirCaustic r = ReservoirCaustic();
    SampleGenerator sg = SampleGenerator(pixel, gFrameCount * kRNGNumPasses + 2);
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

        //Init Material
        ShadingData sd = loadShadingData(photonHit, photonData.dir, lod);
        let mi = gScene.materials.getMaterialInstance(sd, lod, kMIHints);

        //Get Camera backprojection PDF
        float3 directionToCamera = gScene.camera.getPosition() - sd.posW;
        float distanceToCamera = length(directionToCamera);
        directionToCamera /= distanceToCamera;
        const float3 camForward = normalize(gScene.camera.data.cameraW);
        const float cameraPdf = getCameraBackprojectPDF(directionToCamera, distanceToCamera, camForward, gNormalizedPixelArea);

        //Eval BSDF, targetFunction and reservoir weight
        const float3 bsdf = mi.eval(sd, directionToCamera, sg);
        float targetFunction = luminance(photonData.flux * bsdf);
        float w = targetFunction / cameraPdf;

        r.wSum += w;
        bool selectNew = (sampleNext1D(sg) * r.wSum) < w;
        if (selectNew) {
            r.sampleSurface = photonHit.getData();
            r.sampleSurfaceView = photonData.dir;
            r.photonPosW = sd.posW;
            r.photonDir = photonData.dir;
            r.photonRadiance = photonData.flux;
            r.targetFunction = targetFunction;
            r.subPixelJacobian = getSubpixelLocationJacobian(distanceToCamera, directionToCamera, sd.faceN, camForward);
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

    gCausticReservoir[index2Dto1D(pixel, gFrameDimX)] = r;
    gLightTraceHeadCounter[pixel] = -1; //Clear Head Counter
}
