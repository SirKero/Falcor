#include "Utils/Math/MathConstants.slangh"

import Scene.RaytracingInline;
import Utils.Color.ColorHelpers;

static const float kShadowRayEpsilon = 0.98f;
static const float kDeltaRoughnessThreshold = 0.08; //see StandardBSDF.slang kMinGGXAlpha. Everything under this value is considered a delta event

/* Struct describing a Photon used with VCM MIS
flux - the energy of the photon
pathLength - Which bounce the photon is on the light path. 0 is the first surface hit (direct light from camera)
dir - incoming direction
lightIndex - index of the light that generated this photon
normalW - world face normal for the photon, used for surface rejections

*/
struct PhotonData {
    float3 flux;
    uint pathLenght;

    float3 dir;
    uint lightIndex;

    float3 normalW;
    uint _pad;

    uint2 guidingPixel;
    float2 guidingRandomVal;

    // Normal helper
    /*
    property uint2 guidingPixels {
        get { return uint2(packedGuidingPixels & 0xFFFF, (packedGuidingPixels >> 16) & 0xFFFF); }
        set {
            packedGuidingPixels = newValue.x & 0xFFFF;
            packedGuidingPixels |= (newValue.y & 0xFFFF) << 16;
        }
    }
    */

    __init() {
        this.dir = float3(0);
        this.normalW = float3(0,1,0);
        this.flux = float3(0);
        this.pathLenght = 0;
        this.lightIndex = 0;
        this.guidingPixel = uint2(0);
        this._pad = 0;
        this.guidingRandomVal = float2(0);
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
