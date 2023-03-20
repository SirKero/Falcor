#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.Raytracing;
import Scene.Intersection;
import Utils.Math.MathHelpers;
import Utils.Sampling.SampleGenerator;
import Scene.Material.ShadingUtils;
import Rendering.Materials.StandardMaterial;
import Rendering.Materials.Microfacet;
import Rendering.Materials.Fresnel;
import Rendering.Lights.LightHelpers;
import Utils.Math.PackedFormats;
import Utils.Math.FormatConversion;
import Utils.Color.ColorHelpers;

import Reservoir;
import VPLs;
import SurfaceData;
import Hash;

cbuffer PerFrame
{
    uint gFrameCount;       // Frame count since scene was loaded.
    bool gDiffuseOnly;
    float gAttenuationRadius;
    uint _pad;
}

cbuffer Constant{
    bool gUseAlphaTest; //Alpha test
    bool gDeltaRejection;   //Accept every non delta surface as diffuse
    bool gCreateFallbackSample; //Creates a reference sample if current sample was invalid
    uint _pad2;
}  

// Inputs
Texture2D<PackedHitInfo> gVBuffer;
Texture2D<float4> gView;
Texture2D <float>gLinZ;

//Outputs
RWStructuredBuffer<PackedSurfaceData> gSurfaceData;
RWStructuredBuffer<PackedVPL> gLights;

//Outputs
#if USE_REDUCED_RESERVOIR_FORMAT
    RWTexture2D<uint2> gReservoir;
#else
    RWTexture2D<uint4> gReservoir;
#endif

struct TraceData
{
    PackedHitInfo packedHitInfo; //< Reflection albedo of the current hit point
    uint packedNormal; ///< Face normal encoded in 16 bit polar coordinates
    float pDiffuseRef;
    float distance; ///< 
    float NdotL; ///< NdotL precalculated for targetPDF

    SampleGenerator sg; ///< Per-ray state for the sample generator (up to 16B).
    
    /** Create ray payload with default parameters.
    */
    static TraceData create()
    {
        TraceData d;
        d.NdotL = 0.f;
        d.packedHitInfo = {
        };
        d.packedNormal = 0;
        d.distance = -1;
        d.pDiffuseRef = 0.f;
        return d;
    }
};

struct ShadowPayload
{
    bool shadowed;
};

struct SphereAttribs
{
    float distance;
};

struct LightSample{
    uint lightIdx;
    float3 dir;
    float Li;
    float invSelectPdf;
    float2 uv;
    //Enum type later ? 
};

uint index2Dto1D(uint2 idx, uint width){
    return idx.x + width * idx.y;
}

//Load in shading data from hit and direction
ShadingData loadShadingData(const HitInfo hit, const float3 rayDir, const ITextureSampler lod)
{
    const TriangleHit triangleHit = hit.getTriangleHit();
    VertexData v = gScene.getVertexData(triangleHit);
    uint materialID = gScene.getMaterialID(triangleHit.instanceID);
    ShadingData sd = gScene.materials.prepareShadingData(v, materialID, -rayDir, lod);
    adjustShadingNormal(sd, v);
    
    return sd;
}


bool sampleAnalyticLight(const float3 posW, inout SampleGenerator sg, out AnalyticLightSample ls, out float invSelectPdf)
{
    //Get a light source and the radiance from it
    const uint lightCount = gScene.getLightCount();
    if (lightCount == 0)
        return false;
        
    float rndLightIdx = float(lightCount) * sampleNext1D(sg);
    uint lightIdx = min(uint(floor(rndLightIdx)), lightCount - 1);
    LightData lightData = gScene.getLight(lightIdx);

    //Only Point(+ Spot) lights are supported (due to RTXDI and PhotonReSTIR)
    if (lightData.type != uint(LightType::Point))
        return false;
    
    sampleLight(posW, lightData, sg, ls);
    invSelectPdf = lightCount;
    
    return true;
}

void fillLightSample(HitInfo hitInfo, float3 view, in AnalyticLightSample ls, inout SampleGenerator sg, out VPL lightSample)
{
    //Calculate the brdf for the current hit and calculate the indirect light
    let lod = ExplicitLodTextureSampler(0.f);
    ShadingData sd = loadShadingData(hitInfo, view, lod);
    let bsdf = gScene.materials.getBSDF(sd, lod);

    float3 toLight = ls.posW - sd.posW;
    float dist = max(FLT_MIN, length(toLight));
    toLight /= dist;
    
    float3 weight = bsdf.eval(sd, toLight, sg);
    //Visibility test
    RayDesc tRay;
    tRay.Origin = sd.computeNewRayOrigin();
    tRay.TMin = 0.01;
    tRay.TMax = dist;
    tRay.Direction = toLight;
    uint rayFlags = RAY_FLAG_SKIP_CLOSEST_HIT_SHADER | RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH;
    ShadowPayload shadowPayload;
    shadowPayload.shadowed = true;

    TraceRay(gScene.rtAccel, rayFlags, 0xff /* instanceInclusionMask */, 1 /* hitIdx */, rayTypeCount, 1 /* missIdx */, tRay, shadowPayload);

    lightSample.posW = sd.posW;
    lightSample.normal = sd.N;
    lightSample.valid = shadowPayload.shadowed ? false :true;
    lightSample.flux = shadowPayload.shadowed ? 0.f : weight * ls.Li;
}


[shader("miss")]
void miss(inout TraceData rayData : SV_RayPayload)
{
    rayData.distance = -1.f;
}

[shader("miss")]
void missShadow(inout ShadowPayload shadowPayload : SV_RayPayload)
{
    shadowPayload.shadowed = false;
}

//Use anyhit for alpha test if activated
[shader("anyhit")]
void anyHit(inout TraceData rayData : SV_RayPayload, BuiltInTriangleIntersectionAttributes attribs : SV_IntersectionAttributes)
{
    if (gUseAlphaTest)
    {
        // Alpha test for non-opaque geometry.
        GeometryInstanceID instanceID = getGeometryInstanceID();
        VertexData v = getVertexData(instanceID, PrimitiveIndex(), attribs);
        uint materialID = gScene.getMaterialID(instanceID);
        if (gScene.materials.alphaTest(v, materialID, 0.f))
            IgnoreHit();
    }
}

[shader("closesthit")]
void closestHitShadow(inout ShadowPayload shadowPayload : SV_RayPayload, BuiltInTriangleIntersectionAttributes attribs : SV_IntersectionAttributes)
{
    
}

[shader("closesthit")]
void closestHit(inout TraceData rayData : SV_RayPayload, BuiltInTriangleIntersectionAttributes attribs : SV_IntersectionAttributes){
    const float3 incomingRayDir = -WorldRayDirection();
    // Evaluate Falcor's material parameters at the hit point.
    TriangleHit triangleHit;
    triangleHit.instanceID = getGeometryInstanceID();
    triangleHit.primitiveIndex = PrimitiveIndex();
    triangleHit.barycentrics = attribs.barycentrics;
    VertexData v = getVertexData(triangleHit.instanceID, PrimitiveIndex(), attribs);
    const uint materialID = gScene.getMaterialID(triangleHit.instanceID);
    let lod = ExplicitLodTextureSampler(0.f);
    ShadingData sd = gScene.materials.prepareShadingData(v, materialID, incomingRayDir, lod);
        
    BSDFSample bsdfSample;
    let bsdf = gScene.materials.getBSDF(sd, lod);
    let bsdfProperties = bsdf.getProperties(sd);
    
    //All properties are guaranteed to be combined <= 1. Norm it to 1 to get the real diffuse Reflection probability
    float3 norm = bsdfProperties.diffuseReflectionAlbedo + bsdfProperties.diffuseTransmissionAlbedo + bsdfProperties.specularReflectionAlbedo + bsdfProperties.specularTransmissionAlbedo;

    //Accept all hits but reject if the surface is only specular
    float pDiffuseRef = luminance(bsdfProperties.diffuseReflectionAlbedo + bsdfProperties.specularReflectionAlbedo) / luminance(norm);

    bool validHit = luminance(bsdfProperties.diffuseReflectionAlbedo + bsdfProperties.specularReflectionAlbedo) > 0;
    
    validHit &= luminance(bsdfProperties.emission) <= 0; //Ignore emissive hits, as they are sampled by ReSTIR
    
    if (validHit)
    {
        rayData.distance = RayTCurrent();
        rayData.packedNormal = encodeNormal2x16(sd.N);
        rayData.pDiffuseRef = pDiffuseRef;
        rayData.packedHitInfo = HitInfo(triangleHit).getData();
        rayData.NdotL = saturate(dot(sd.N, incomingRayDir));
    }else{
        rayData.distance = -1.f;
    }
}

[shader("raygeneration")]
void rayGen()
{
    uint2 launchIndex = DispatchRaysIndex().xy;
    uint2 launchDim = DispatchRaysDimensions().xy;
    
    HitInfo hitInfo = HitInfo(gVBuffer[launchIndex]);
    Surface surface = Surface();
    Reservoir reservoir = Reservoir();
    reservoir.M = 1;
    TraceData traceData = TraceData::create();
    float lightFactor = 1.f;    //Store NdotL in it later
    VPL lightSample = { };
    
    if (hitInfo.isValid())
    {
        float3 view = -gView[launchIndex].xyz;
        float linZ = gLinZ[launchIndex];
        let lod = ExplicitLodTextureSampler(0.f);
        ShadingData sd = loadShadingData(hitInfo, view, lod);

        //The final gather hit is considered diffuse as the V-Buffer only stops on diffuse surfaces
        if (gDiffuseOnly)
            sd.mtl.setActiveLobes((uint) LobeType::DiffuseReflection);
        else
            sd.mtl.setActiveLobes((uint) LobeType::Reflection);

        let bsdf = gScene.materials.getBSDF(sd, lod);
        let bsdfProperties = bsdf.getProperties(sd);

        traceData.sg = SampleGenerator(launchIndex, gFrameCount + 3 * 13);

        BSDFSample bsdfSample;
        bool validSample = bsdf.sample(sd, traceData.sg, bsdfSample, true);

        if (gCreateFallbackSample && !validSample)
            validSample = bsdf.sample(sd, traceData.sg, bsdfSample, false);

        //Fill Surface Buffer used for calculating the target PDF
        surface = Surface::create(sd.computeNewRayOrigin(), sd.N, sd.V, linZ, bsdfProperties.roughness,
                                      luminance(bsdfProperties.diffuseReflectionAlbedo), luminance(bsdfProperties.specularReflectance));
        
        if (gDiffuseOnly)
            reservoir.targetPdf = surface.getDiffusePdf(bsdfSample.wo);
        else
            reservoir.targetPdf = surface.getPdf(bsdfSample.wo);
    
        reservoir.weightSum = 1.f / bsdfSample.pdf; // 1/selectPDF

        RayDesc tRay;
        tRay.Origin = sd.computeNewRayOrigin();
        tRay.TMin = 0.0001;
        tRay.TMax = 1000.f;
        tRay.Direction = bsdfSample.wo;
    
        if (validSample)
        {
            TraceRay(gScene.rtAccel, 0, 0xff /* instanceInclusionMask */, 0 /* hitIdx */, rayTypeCount, 0 /* missIdx */, tRay, traceData);
            validSample = traceData.distance > 0;
        }

        AnalyticLightSample ls;
        
        if (validSample)
        {
            float invSelectPdf = 1.f;
            validSample = sampleAnalyticLight(sd.posW, traceData.sg, ls, invSelectPdf);
            reservoir.weightSum *= invSelectPdf;
        }
        
        if (validSample)
        {
            fillLightSample(HitInfo(traceData.packedHitInfo), tRay.Direction, ls, traceData.sg, lightSample);
           
            float distSqr = max(FLT_MIN, abs(traceData.distance * traceData.distance));
            float cosTheta = max(FLT_MIN, traceData.NdotL);
            
            if (any(isnan(lightSample.flux)) || any(isinf(lightSample.flux)) || cosTheta <= 0)
                lightSample.valid = false;
            else
                lightSample.flux *= distSqr / cosTheta; //Jacobian determinant
            
            float distanceAttenuation = vplAttenuation(traceData.distance, gAttenuationRadius);
            float Li = luminance(lightSample.flux);
            reservoir.targetPdf *= Li * cosTheta * distanceAttenuation; //Jacobian determinant and Li
            if (Li <= 0)
                validSample = false;
        }

    
        if (!validSample || !lightSample.valid)
        {
            reservoir.weightSum = 0.f; //invalidate reseroir
        }
    }
        
    //Store data in buffers
    gLights[index2Dto1D(launchIndex, launchDim.x)] = lightSample.pack();
    gSurfaceData[index2Dto1D(launchIndex, launchDim.x)] = surface.pack();
    #if USE_REDUCED_RESERVOIR_FORMAT
        gReservoir[launchIndex] = reservoir.packReduced();
    #else
        gReservoir[launchIndex] = reservoir.pack();
    #endif
}
