#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.Raytracing;
import Utils.Math.MathHelpers;
import Utils.Geometry.GeometryHelpers;
import Utils.Sampling.SampleGenerator;
import Rendering.Lights.LightHelpers;
import Rendering.Lights.EmissiveLightSampler;
import Rendering.Lights.EmissiveLightSamplerHelpers;
import StructsAndHelpers;
#if USE_PHOTON_GUIDING
import Rendering.PhotonGuiding.PhotonGuiding;
#endif 

cbuffer CB
{
    PackedPathLength gPackedPathLength;   // Path Length for the photon path
    uint gFrameCount;   // Frame count since scene was loaded.
    float2 gPhotonRadius;//Global/Caustic radius

    float gGlobalRejectionProb;                             // Rejection Probability for global photons
    float gNormalizedPixelDiagonal; //Approximate pixel diagonal at length 1
    bool gUseAnalyticLights;    //true if analytic lights should be used
    uint _pad;    
}

#if USE_EMISSIVE_LIGHT // Buffer is only valid if emissive light is enabled
cbuffer Light {
    EmissiveLightSampler gEmissiveSampler;
}
#endif

RWStructuredBuffer<AABB> gPhotonAABB[2];
RWStructuredBuffer<PhotonData> gPhotonData[2];
RWStructuredBuffer<uint> gPhotonCounter;

static const bool kAlphaTest = true;
static const uint2 kPhotonBufferSize = uint2(PHOTON_BUFFER_SIZE_GLOBAL, PHOTON_BUFFER_SIZE_CAUSTIC);
static const float kRoughnessThreshold = ROUGHNESS_THRESHOLD;
static const bool kRussianRoulette = USE_RUSSIAN_ROULETTE;
static const bool kUseAdaptivePhotonRadius = USE_ADAPTIVE_PHOTON_RADIUS;

struct RayPayload
{
    PackedHitInfo packedHitInfo; //< Hit Info

    /** Create ray payload with default parameters.
     */
    __init()
    {
        this.packedHitInfo = {};
    }
}

//Helper struct to generate a photon form the lightSources
struct PhotonLightSample {
    float3 posW;
    float3 normal;
    float3 flux;
};

float getPhotonRadius(const uint photonTypeIdx, const float3 hitPos)
{
    float adaptiveRadius = 1.0;
    if (kUseAdaptivePhotonRadius)
    {
        float distToCamera = distance(hitPos, gScene.camera.getPosition());
        adaptiveRadius = (gNormalizedPixelDiagonal * distToCamera) / 2.0;
    }
    return adaptiveRadius * gPhotonRadius[photonTypeIdx];
}

/*  Transforms direction from local to world space
    \param[in] Face Normal
    \param[in] local direction
    \return world space direction
*/
float3 fromLocalToWorld(const in float3 normal, float3 w)
{
    // transform from local space -> random dir vector in world space
    float3 bitangent = perp_stark(normal);
    float3 tangent = cross(bitangent, normal);

    return w.x * tangent + w.y * bitangent + w.z * normal;
}

#if USE_EMISSIVE_LIGHT // Function is only valid if the emissive sampler is set
/*  Creates a photon light sample from emissive triangles weighted by emissive power
    \param[in/out] Random Number Generator
    \param[out] Photon light sample
    \return true if light sample is valid
*/
bool createLightSample(inout SampleGenerator sg, out PhotonLightSample pls) {
    pls = {};
    if (gScene.lightCollection.isEmpty())
        return false;

    // Randomly pick a triangle out of the global list with uniform probability
    const uint triangleCount = gScene.lightCollection.triangleCount;
    // Safety precaution as the result of the multiplication may be rounded to triangleCount even if uLight < 1.0 when triangleCount is large.
    uint triangleIndex = min((uint)(sampleNext1D(sg) * triangleCount), triangleCount - 1);

    uint2 packed = gEmissiveSampler._emissivePower.triangleAliasTable[triangleIndex];
    float threshold = f16tof32(packed.x >> 16u);
    uint selectAbove = ((packed.x & 0xFFFFu) << 8u) | ((packed.y >> 24u) & 0xFFu);
    uint selectBelow = packed.y & 0xFFFFFFu;

    // Test the threshold in the current table entry; pick one of the two options
    triangleIndex = (sampleNext1D(sg) >= threshold) ? selectAbove : selectBelow;

    float triangleSelectionPdf = gScene.lightCollection.fluxData[triangleIndex].flux * gEmissiveSampler._emissivePower.invWeightsSum;

    //Sample emissive triangle
    const EmissiveTriangle tri = gScene.lightCollection.getTriangle(triangleIndex);
    const float3 barycentrics = sample_triangle(sampleNext2D(sg));
    pls.posW = tri.getPosition(barycentrics);
    pls.normal = tri.normal;

    // Get Flux
    float2 uv = tri.getTexCoord(barycentrics);
    pls.flux = gScene.materials.evalEmissive(tri.materialID, uv) * tri.area;

    pls.posW = computeRayOrigin(pls.posW, pls.normal); //Offset as this light is real geometry
    pls.flux /= triangleSelectionPdf;

    return true;
}
#endif

/*  Creates a photon light sample from analytic point or spot lights
    \param[in/out] Random Number Generator
    \param[out] Photon light sample
    \param[out] Direction the photon should be dispatched
    \return true if light sample is valid
*/
bool createLightSampleAnalytic(inout SampleGenerator sg, out PhotonLightSample pls, out float3 sampledDir)
{
    pls = {};
    sampledDir = float3(0);
    const uint lightCount = gScene.getLightCount();
    if (lightCount == 0)
        return false;
    // Uniformly sample one of the analytic lights
    float rndLightIdx = float(lightCount) * sampleNext1D(sg);
    uint lightIdx = min(uint(floor(rndLightIdx)), lightCount - 1);
    LightData lightData = gScene.getLight(lightIdx);

    // Only Point(+ Spot) lights are supported (due to RTXDI)
    if (lightData.type != uint(LightType::Point))
        return false;
    float invLightPdf;
    float3 woLocal;
    float3 rnd = sampleNext3D(sg);
    rnd.z = 0;
    float spotAngle = lightData.cosOpeningAngle;
    if (lightData.openingAngle < M_2PI) // If the opening angle is smaller than 2PI it is a spotlight
    {
        spotAngle = cos(lightData.openingAngle - lightData.penumbraAngle * rnd.z);
        woLocal = sample_cone(rnd.xy, spotAngle);
    }
    else // Pointlight
    {
        woLocal = sample_sphere(rnd.xy);
    }
    invLightPdf = M_2PI * (1.f - spotAngle);

    if (invLightPdf <= 0.f)
        return false;

    invLightPdf *= lightCount; // Take the select pdf into account

    // Fill the photon light struct
    pls.posW = lightData.posW;
    pls.normal = lightData.dirW;
    pls.flux = lightData.intensity * invLightPdf;

    sampledDir = fromLocalToWorld(pls.normal, woLocal);
    return true;
}

//Add empty hit info for miss
[shader("miss")]
void miss(inout RayPayload rayData: SV_RayPayload)
{
    HitInfo hitInfo = {};
    rayData.packedHitInfo = hitInfo.getData(); // Invalid hit
}

//For alpha test
[shader("anyhit")]
void anyHit(inout RayPayload rayData: SV_RayPayload, BuiltInTriangleIntersectionAttributes attribs: SV_IntersectionAttributes)
{
    if (kAlphaTest)
    {
        // Alpha test for non-opaque geometry.
        GeometryInstanceID instanceID = getGeometryInstanceID();
        VertexData v = getVertexData(instanceID, PrimitiveIndex(), attribs);
        uint materialID = gScene.getMaterialID(instanceID);
        if (gScene.materials.alphaTest(v, materialID, 0.f))
            IgnoreHit();
    }
}

//Add triangle hit to the payload
[shader("closesthit")]
void closestHit(inout RayPayload rayData: SV_RayPayload, BuiltInTriangleIntersectionAttributes attribs: SV_IntersectionAttributes) {
    TriangleHit triangleHit;
    triangleHit.instanceID = getGeometryInstanceID();
    triangleHit.primitiveIndex = PrimitiveIndex();
    triangleHit.barycentrics = attribs.barycentrics;

    rayData.packedHitInfo = HitInfo(triangleHit).getData();
}

[shader("raygeneration")]
void rayGen()
{
    uint2 pixel = DispatchRaysIndex().xy;
    uint2 dispatchDims = DispatchRaysDimensions().xy;

    const float invRejection = 1.f / gGlobalRejectionProb;

    SampleGenerator sg = SampleGenerator(pixel, gFrameCount * 5);
    RayDesc ray;
    PhotonLightSample pls;
    PhotonData photon = PhotonData();

#if USE_PHOTON_GUIDING

    PhotonGuidingSample pgs = {};
    //Get as sample from the guiding mip
    if (!gPhotonGuiding.sampleGuidedLightAndDirection(pixel, dispatchDims.x, sampleNext2D(sg), pgs))
        return;
    //Sample the selected light
    PhotonGuidingPhotonLightSample pgpls = {};
    if (!gPhotonGuiding.createPhotonSample(pgs, sg, pgpls))
        return;

    //Set Data
    pls.posW = pgpls.posW;
    pls.normal = pgpls.normal;
    pls.flux = pgpls.flux;
    ray.Direction = pgpls.dirW;

    // Store guiding data for the Photon
    photon.lightIndex = pgs.lightIndex;
    photon.guidingPixels = gPhotonGuiding.guidingMapUVToPixel(pgs.directionUV);
#else //USE_PHOTON_GUIDING
        //Create a photon by sampling from emissive lights or analytic light sources
    #if USE_EMISSIVE_LIGHT
        if (gUseAnalyticLights)
    #endif // USE_EMISSIVE_LIGHT
        { // Analytic light sample
            float3 sampleDir;
            if (!createLightSampleAnalytic(sg, pls, sampleDir))
                return;

            ray.Direction = sampleDir;
        }
    #if USE_EMISSIVE_LIGHT
        else { // Emissive light sample
            if (!createLightSample(sg, pls))
                return;

            float lightDirPDF = 1.0;
            float3 woLocal = sample_cosine_hemisphere_concentric(sampleNext2D(sg), lightDirPDF);

            if (lightDirPDF <= 0.f)
                return;

            ray.Direction = fromLocalToWorld(pls.normal, woLocal);
            pls.flux *= M_PI; // Lambert Emitter
        }
    #endif //USE_EMISSIVE_LIGHT
        pls.flux /= dispatchDims.x * dispatchDims.y; // Division through all dipatched photons
#endif //USE_PHOTON_GUIDING
    
    //Prepare the rest of the ray
    ray.Origin = pls.posW;
    ray.TMin = 0.0;
    ray.TMax = FLT_MAX;
    RayPayload rayPayload = RayPayload();
    
    bool storeAsCaustic = false;
    bool reflectedDiffuse = false;
    float3 photonStartFlux = pls.flux;
    float3 thp = float3(1.0); //Throughput

    //Prepare photon
    photon.flux = photonStartFlux;
    photon.dir = -ray.Direction;
    photon.normalW = pls.normal;

    PackedPathLength pathLengthInfo = PackedPathLength();
    const uint maxPathLength = gPackedPathLength.pathLength;
    // Main Raytrace Loop
    for (uint i = 0; i < maxPathLength; i++) {
        TraceRay(gScene.rtAccel, 0 /*Flags*/, 0xff /* instanceInclusionMask */, 0 /* hitIdx */, rayTypeCount, 0 /* missIdx */, ray, rayPayload);

        HitInfo hit = HitInfo(rayPayload.packedHitInfo);
        //Stop if photon leaves the scene
        if (!hit.isValid())
            return;

        // Get shading infos and material properties
        let lod = ExplicitLodTextureSampler(0);
        uint hints = (uint)MaterialInstanceHints::AdjustShadingNormal;
        ShadingData sd = loadShadingData(hit, ray.Direction, lod);
        let mi = gScene.materials.getMaterialInstance(sd, lod, hints);
        let bsdfProperties = mi.getProperties(sd);

        // Store Photon if a diffuse surface was hit
        photon.normalW = sd.getOrientedFaceNormal();
        reflectedDiffuse = bsdfProperties.roughness > kRoughnessThreshold;
        if (reflectedDiffuse) {
            PhotonType photonType = storeAsCaustic ? PhotonType::Caustic : PhotonType::Global;
            //Global photons can be rejected. The flux of the stored ones should be increased by the inverse of the rejection probability
            bool storePhoton = true;
            if (photonType == PhotonType::Global) {
                storePhoton = sampleNext1D(sg) <= gGlobalRejectionProb;
                photon.flux *= invRejection;
            }
            //Insert photon into buffer using a counter with interlocked add
            if (storePhoton) {
                uint photonTypeIdx = (uint)photonType;
                uint photonInsertIndex = 0;
                InterlockedAdd(gPhotonCounter[photonTypeIdx], 1u, photonInsertIndex);
                if (photonInsertIndex <= kPhotonBufferSize[photonTypeIdx])
                {
                    float radius = getPhotonRadius(photonTypeIdx, sd.posW);
                    AABB photonAABB = AABB(sd.posW - radius, sd.posW + radius);
                    gPhotonAABB[photonTypeIdx][photonInsertIndex] = photonAABB;
                    gPhotonData[photonTypeIdx][photonInsertIndex] = photon;
                }
            }
        }

        // Sample Photon bounce for next iteration
        BSDFSample bsdfSample;
        bool validSample = mi.sample(sd, sg, bsdfSample, true /*ImportanceSampling*/);

        // Path Length
        if (bsdfSample.isLobe(LobeType::Delta))
            pathLengthInfo.deltaBounces = pathLengthInfo.deltaBounces + 1;
        else if (bsdfSample.isLobe(LobeType::Diffuse))
            pathLengthInfo.diffuseBounces = pathLengthInfo.diffuseBounces + 1;
        else if (bsdfSample.isLobe(LobeType::Specular))
            pathLengthInfo.specularBounces = pathLengthInfo.specularBounces + 1;
        validSample &= pathLengthInfo.comparePathLengts(gPackedPathLength);

        if (!validSample)
            return;
        bool transmission = bsdfSample.isLobe(LobeType::Transmission);
        ray.Origin = sd.computeNewRayOrigin(!transmission); // false is for transmissions
        ray.Direction = bsdfSample.wo;
        thp *= bsdfSample.weight;

        // Russian Roulette
        if (kRussianRoulette)
        {
            const float rrVal = (thp.x + thp.y + thp.z) / 3.0;
            const float prob = max(0.f, 1.f - rrVal);
            if (sampleNext1D(sg) < prob)
            {
                return; // Photon is absorbed
            }
            else
            {
                thp /= (1.f - prob);
            }
        }
       
        // Update Photon
        storeAsCaustic = !reflectedDiffuse;
        photon.dir = -ray.Direction;
        photon.flux = photonStartFlux * thp;
        photon.pathLenght++;
    }
}
