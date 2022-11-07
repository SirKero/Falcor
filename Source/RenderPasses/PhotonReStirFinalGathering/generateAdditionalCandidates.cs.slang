#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"


import Utils.Math.PackedFormats;
import Utils.Math.FormatConversion;

import Scene.RaytracingInline;
import Scene.Material.ShadingUtils;
import Rendering.Materials.Microfacet;
import Rendering.Materials.Fresnel;
import Utils.Sampling.SampleGenerator;
import Utils.Math.MathHelpers;
import Utils.Color.ColorHelpers;

import Rendering.Lights.EmissiveLightSampler;
import Rendering.Lights.EmissiveLightSamplerHelpers;
import Reservoir;
import SurfaceData;
import VPLs;


//Define for valid texture channels
#define is_valid(name) (is_valid_##name != 0)

RWTexture2D<uint4> gReservoir;

StructuredBuffer<PackedVPL> gVpls;
RWStructuredBuffer<PackedVPL> gVplsWrite;


StructuredBuffer<PackedSurfaceData>gSurface;
Texture2D gVBuffer;
Texture2D<float4> gView;

cbuffer PerFrame
{
    uint gFrameCount;                   //Current it for sample gen
}

cbuffer Constant
{
    uint gNumCandidates;       // Num emissive samples
    uint2 gFrameDim;                //Frame Dimensions for camera dir
    uint gNumLights;                //Light Buffer Size. If Presampling enabled, x = Title Count, y= Title Size. If !Presampling, then x = Size LightBuffer 
}


struct LightSample{
    uint lightIdx;
    float3 dir;
    float Li;
    float invSelectPdf;
    float2 uv;
    //Enum type later ? 
};

static const float kRayEpsilon = 0.99f;

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

Surface getSurface(uint2 idx)
{
    float3 viewDir;
    if (is_valid(gView))
    {
        viewDir = gView[idx].xyz;
    }
    else
    {
        viewDir = gScene.camera.computeRayPinhole(idx, gFrameDim).dir * -1; //Flip ViewDir here 
    }
    PackedSurfaceData surfaceData = gSurface[index2Dto1D(idx, gFrameDim.x)];
    
    return Surface(surfaceData, viewDir);
}


[numthreads(16, 16, 1)]
void main(uint2 dTid : SV_DispatchThreadID)
{
    SampleGenerator sg = SampleGenerator(dTid, gFrameCount + 3 * 13);
    Reservoir r = Reservoir();
    //Get current reservoir
    VPL selectedVPL = VPL();
    Reservoir current = Reservoir(gReservoir[dTid]);
    if (current.weightSum > 0)
    {
        selectedVPL = VPL(gVpls[index2Dto1D(dTid, gFrameDim.x)]);
    }
    
    r.combineReservoir(current, current.targetPdf, 0.5 /* random */);

    //Get shading data
    Surface surface = getSurface(dTid);
    if (!surface.valid)
    {
        return;
    }
    //Get Vbuffer for ShadingData
    HitInfo hitInfo = HitInfo(gVBuffer[dTid]);
    float3 view = -gView[dTid].xyz;
    let lod = ExplicitLodTextureSampler(0.f);
    ShadingData sd = loadShadingData(hitInfo, view, lod);
    let bsdf = gScene.materials.getBSDF(sd, lod);

    float selectedDistance = 0;
    float3 selectedDirection = float3(0, 1, 0);
    
    for (uint i = 1; i < gNumCandidates; i++)
    {
        float sampleDistance;
        bool valid = true;
        //Generate sample
        uint rndLightIdx = min(uint(float(gNumLights) * sampleNext1D(sg)), gNumLights - 1);
        //Get light
        VPL vpl = VPL(gVpls[index2Dto1D(rndLightIdx, gFrameDim.x)]);
        valid |= vpl.valid;
        float3 toLight = vpl.posW - sd.posW;
        sampleDistance = sqrt(max(FLT_MIN, dot(toLight, toLight))); // Clamp to avoid NaNs below
        toLight /= sampleDistance; //normalize
        float selectPdf = bsdf.evalPdf(sd, toLight, true);
        if (selectPdf < 0.f)
            valid = false;

        //valid = false;
        
        float targetPdf = surface.getPdf(toLight, luminance(vpl.flux));
        if (targetPdf <= 0)
            valid = false;

        if (!valid)
            continue;
        if (r.updateReservoir(rndLightIdx, selectPdf, targetPdf, sampleNext1D(sg)))
        {
            selectedDistance = sampleDistance;
            selectedDirection = toLight;
            selectedVPL = vpl;
        }
    }

    //Finalize sample
    //r.M = 1;    //Every reservoir has the same amount of initial samples
    r.finalizeSample(1.f, r.M);

    bool validSample = r.weightSum > 0 && !isnan(r.weightSum) && !isinf(r.weightSum);

    //Test visibility and shoot a shadow ray from the surface to the selected light
    if (validSample)
    {
        
        selectedDistance *= kRayEpsilon;
        // Ray Query for shadow test; <0> means disabled alpha testing; TODO: Add static const for alpha test
        SceneRayQuery < 0 > rayQuery;
        const Ray ray = Ray(surface.posW, selectedDirection, 0.f, selectedDistance);
        if (!rayQuery.traceVisibilityRay(ray, RAY_FLAG_CULL_NON_OPAQUE, 0xff))
        {
            r.weightSum = 0.f; //Set weight to zero if light is not visible
        }
    }

    gReservoir[dTid] = r.pack();
    gVplsWrite[index2Dto1D(dTid, gFrameDim.x)] = selectedVPL.pack();
}
