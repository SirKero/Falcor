#include "Utils/Math/MathConstants.slangh"

import Scene.RaytracingInline;
import Utils.Color.ColorHelpers;

static const float kShadowRayEpsilon = 0.98f;
static const float kDeltaRoughnessThreshold = 0.08; //see StandardBSDF.slang kMinGGXAlpha. Everything under this value is considered a delta event

/* Struct describing a Photon
flux - the energy of the photon
pathLength - Which bounce the photon is on the light path. 0 is the first surface hit (direct light from camera)
dir - incoming direction
dVCM - MIS Quanitiy (small VCM)
normalW - world face normal for the photon, used for surface rejections
dVM - MIS Quanitiy for merging (small VCM)
*/
struct PhotonData {
    float3 flux;
    uint pathLenght;

    float3 dir;
    float pdf;

    float3 normalW;
    float reversePdf;

    float neeReversePdf;
    float photonReversePdf;
    uint2 _pad;

    __init() {
        this.dir = float3(0);
        this.normalW = float3(0, 1, 0);
        this.flux = float3(0);
        this.pathLenght = 0;
        this.pdf = 1.0;
        this.reversePdf = 1.0;
        this.neeReversePdf = 1.0;
        this.photonReversePdf = 0.0;
        this._pad = uint2(0);
    }
}

/* Struct describing a Photon used with VCM MIS
flux - the energy of the photon
pathLength - Which bounce the photon is on the light path. 0 is the first surface hit (direct light from camera)
dir - incoming direction
dVCM - MIS Quanitiy (small VCM)
normalW - world face normal for the photon, used for surface rejections
dVM - MIS Quanitiy for merging (small VCM)
*/
struct PhotonDataVCM {
    float3 flux;
    uint pathLenght;

    float3 dir;
    float dVCM;
    
    float3 normalW;
    float dVM;

    float continationProb;
    float dVC;
    uint2 _pad;

    __init() {
        this.dir = float3(0);
        this.normalW = float3(0,1,0);
        this.flux = float3(0);
        this.pathLenght = 0;
        this.dVCM = 0;
        this.dVM = 0;
        this.continationProb = 1.0;
        this.dVC = 0;
        this._pad = uint2(0);
    }
}

enum class PhotonType // : uint32_t
{
    Global = 0,
    Caustic = 1
};

// Load in shading data from hit and direction
ShadingData loadShadingData(const HitInfo hit, const float3 rayDir, const ITextureSampler lod)
{
    const TriangleHit triangleHit = hit.getTriangleHit();
    VertexData v = gScene.getVertexData(triangleHit);
    uint materialID = gScene.getMaterialID(triangleHit.instanceID);
    ShadingData sd = gScene.materials.prepareShadingData(v, materialID, -rayDir, lod);

    return sd;
}

float getContinuationProbablity(BSDFProperties props)
{
    //Delta events are not accurately captured by the reflection/transmission albedos. Delta has a probability of 1 anyway.
    if (props.roughness <= kDeltaRoughnessThreshold)
        return 1.0;

    float3 totalMaterialEnergie = props.diffuseReflectionAlbedo + props.diffuseTransmissionAlbedo + props.specularReflectionAlbedo + props.specularTransmissionAlbedo;
    return clamp(luminance(totalMaterialEnergie), 0.0, 1.0);
}
