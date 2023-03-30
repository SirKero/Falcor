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
import Rendering.Lights.EmissiveLightSampler;
import Rendering.Lights.EmissiveLightSamplerHelpers;

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
    uint gMaxBounces;
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

cbuffer Light{
    EmissiveLightSampler gEmissiveSampler;
}

static const bool kUseEmissiveLights = USE_EMISSIVE_LIGHT;
static const bool kUseAnalyticLights = USE_ANALYTIC_LIGHT;

struct TraceData
{
    PackedHitInfo packedHitInfo; //< Reflection albedo of the current hit point
    uint pathLength;
    bool valid;
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
        d.pathLength = 0;
        d.distance = -1;
        d.valid = true;
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
    float3 posW;
    float invSelectPDF;
    float3 Li;
    uint _pad;
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


bool sampleAnalyticLight(const float3 posW, inout SampleGenerator sg, out LightSample ls)
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

    AnalyticLightSample als;
    sampleLight(posW, lightData, sg, als);
    ls.invSelectPDF = lightCount;
    ls.posW = als.posW;
    ls.Li = als.Li * ls.invSelectPDF;
    
    return true;
}

bool sampleEmissiveLight(in const ShadingData sd, inout SampleGenerator sg, out LightSample ls)
{ 
    TriangleLightSample tls;
    if (!gEmissiveSampler.sampleLight(sd.posW, sd.N, true, sg, tls))
        return false;

    if(tls.pdf <= 0)
        return false;
    
    ls.invSelectPDF = 1 / tls.pdf;
    ls.Li = tls.Le * ls.invSelectPDF;
    ls.posW = tls.posW;

    return true;
}

bool fillLightSample(in const ShadingData sd, float3 view, in LightSample ls, inout SampleGenerator sg, out float3 Li)
{
    //Calculate the brdf for the current hit and calculate the indirect light
    let lod = ExplicitLodTextureSampler(0.f);
    let bsdf = gScene.materials.getBSDF(sd, lod);

    float3 toLight = ls.posW - sd.posW;
    float dist = max(FLT_MIN, length(toLight));
    toLight /= dist;
    
    float3 weight = bsdf.eval(sd, toLight, sg);
    //Visibility test
    RayDesc tRay;
    tRay.Origin = sd.computeNewRayOrigin();
    tRay.TMin = 0.01;
    tRay.TMax = dist * 0.99f;
    tRay.Direction = toLight;
    uint rayFlags = RAY_FLAG_SKIP_CLOSEST_HIT_SHADER | RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH;
    ShadowPayload shadowPayload;
    shadowPayload.shadowed = true;

    TraceRay(gScene.rtAccel, rayFlags, 0xff /* instanceInclusionMask */, 1 /* hitIdx */, rayTypeCount, 1 /* missIdx */, tRay, shadowPayload);

    Li = shadowPayload.shadowed ? 0.f : max(0.0, weight * ls.Li);

    return all(Li >= 0);
}

bool dispatchNewRay(float3 origin, float3 direction, inout TraceData rayData)
{
    RayDesc tRay;
    tRay.Origin = origin;
    tRay.TMin = 0.0001;
    tRay.TMax = 1000.f;
    tRay.Direction = direction;
    
    TraceRay(gScene.rtAccel, 0, 0xff /* instanceInclusionMask */, 0 /* hitIdx */, rayTypeCount, 0 /* missIdx */, tRay, rayData);

    return rayData.valid;
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
    bool validHit = true;
    float NdotL = 0.f;
    let lod = ExplicitLodTextureSampler(0.f);
    ShadingData sd = gScene.materials.prepareShadingData(v, materialID, incomingRayDir, lod);
    
    BSDFSample bsdfSample;
    let bsdf = gScene.materials.getBSDF(sd, lod);
    let bsdfProperties = bsdf.getProperties(sd);
    
    //All properties are guaranteed to be combined <= 1. Norm it to 1 to get the real diffuse Reflection probability
    float3 norm = bsdfProperties.diffuseReflectionAlbedo + bsdfProperties.diffuseTransmissionAlbedo + bsdfProperties.specularReflectionAlbedo + bsdfProperties.specularTransmissionAlbedo;

    //Accept all hits but reject if the surface is only specular
    float pDiffuseRef = luminance(bsdfProperties.diffuseReflectionAlbedo + bsdfProperties.specularReflectionAlbedo) / luminance(norm);

    validHit = luminance(bsdfProperties.diffuseReflectionAlbedo + bsdfProperties.specularReflectionAlbedo) > 0;
    NdotL = saturate(dot(sd.N, incomingRayDir));
    
    if (rayData.pathLength == 0)
    {
        validHit &= luminance(bsdfProperties.emission) <= 0; //Ignore emissive hits on first hit, as they are sampled by ReSTIR
    }
        
    if (validHit)
    {
        rayData.distance = RayTCurrent();
        rayData.pathLength += 1;
        rayData.packedHitInfo = HitInfo(triangleHit).getData();
        rayData.NdotL = NdotL;
    }else{
        rayData.valid = false;
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
    VPL pathLightSample = { };
    
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

        float3 rayOrigin = sd.computeNewRayOrigin();
        float3 rayDirection = bsdfSample.wo;
        float3 radiance = float3(0);
        float3 thp = float3(1);
        float rayDistance = 1;
        float cosTheta = 1;
        
        for (uint i = 0; i < gMaxBounces; i++)
        {
            if(!validSample)
                break;
            
            if (!dispatchNewRay(rayOrigin, rayDirection, traceData))
            {
                if(i== 0 && !traceData.valid)
                    validSample = false;
                break;
            }

            //Sample a light
            LightSample ls = { };
            HitInfo hitInfo = HitInfo(traceData.packedHitInfo);
            ShadingData sd = loadShadingData(hitInfo, rayDirection, lod);
            let bsdf = gScene.materials.getBSDF(sd, lod);
            let bsdfProperties = bsdf.getProperties(sd);
           
            //Get emissive or analytic sample
            float analyticPDF = kUseAnalyticLights ? 1.f : 0;
            float emissivePDF = kUseEmissiveLights ? 1.f : 0;

            analyticPDF /= analyticPDF + emissivePDF; //Normalize

            bool validLightSample = true;
            float invSelect;
            if (sampleNext1D(traceData.sg) <= analyticPDF)
            {
                invSelect = 1.f / analyticPDF;
                if (!sampleAnalyticLight(sd.posW, traceData.sg, ls))
                    validLightSample = false;
                ls.Li *= invSelect;
                //reservoir.weightSum *= ls.invSelectPDF * invSelect;
            }
            else if (kUseEmissiveLights)
            {
                invSelect = 1.f / (1.f - analyticPDF);
                if (!sampleEmissiveLight(sd, traceData.sg, ls))
                    validLightSample = false;
                ls.Li *= invSelect;
                //reservoir.weightSum *= ls.invSelectPDF * invSelect;
            }
            else //Should not happen
            {
                return;
            }
            
            float3 Li = float3(0);
            if (validLightSample)
            {
                ls.Li *= invSelect;
                if (!fillLightSample(sd, rayDirection, ls, traceData.sg, Li))
                    break;
            }

            //Update data for the first light sample
            if (i == 0)
            {
                pathLightSample.posW = sd.posW;
                pathLightSample.normal = sd.N;
                rayDistance = traceData.distance;
                cosTheta = max(FLT_MIN, traceData.NdotL);
            }
            
            radiance += (Li + bsdfProperties.emission) * thp;
                        
            //Calculate next bounce
            if (i + 1 < gMaxBounces)
            {
                if (!bsdf.sample(sd, traceData.sg, bsdfSample))
                    break;
                
                thp *= bsdfSample.weight;
                rayDirection = bsdfSample.wo;
                rayOrigin = sd.computeNewRayOrigin();
            }
            
        }

        pathLightSample.flux = radiance;
        
        if (validSample && !any(isnan(pathLightSample.flux)) && !any(isinf(pathLightSample.flux)))
        {
            float distSqr = max(FLT_MIN, abs(rayDistance * rayDistance));
            if (cosTheta > 0)
                pathLightSample.flux *= distSqr / cosTheta; //Jacobian determinant
            
            float distanceAttenuation = vplAttenuation(rayDistance, gAttenuationRadius);
            float Li = luminance(pathLightSample.flux);
            reservoir.targetPdf *= Li * cosTheta * distanceAttenuation; //Jacobian determinant and Li
            if (Li > 0 && cosTheta > 0)
                pathLightSample.valid = true;
        }

    
        if (!validSample || !pathLightSample.valid)
        {
            reservoir.weightSum = 0.f; //invalidate reseroir
            pathLightSample.flux = float3(0);
            if(!validSample)
                reservoir.M = 0;
        }
    }
        
    //Store data in buffers
    gLights[index2Dto1D(launchIndex, launchDim.x)] = pathLightSample.pack();
    gSurfaceData[index2Dto1D(launchIndex, launchDim.x)] = surface.pack();
    #if USE_REDUCED_RESERVOIR_FORMAT
        gReservoir[launchIndex] = reservoir.packReduced();
    #else
        gReservoir[launchIndex] = reservoir.pack();
    #endif
}
