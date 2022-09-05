#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.Scene;
import Utils.Color.ColorHelpers;

import Lights;

RWStructuredBuffer<PackedReSTIRLight> gLightBuffer;
RWTexture2D<float> gLightPdf;

cbuffer Constant{
    uint2 gThreadDim;                //ThreadDims
    uint gMaxNumLights;             //MaxNumLights
}

[numthreads(16, 16, 1)]
void main(uint2 dTid : SV_DispatchThreadID)
{
    uint lightIdx = dTid.x + dTid.y * gThreadDim.x;
    //Check if thread is outside of max light idx
    if(gMaxNumLights <= lightIdx)
        return;

    //Get active triangle index
    uint triIdx = gScene.lightCollection.activeTriangles[lightIdx];

    //Load emissive triangle data
    const EmissiveTriangle et = gScene.lightCollection.getTriangle(triIdx);
    const EmissiveFlux ef = gScene.lightCollection.fluxData[triIdx];

    ReSTIRLight light = {};
    light.lightIdx = triIdx;
    light.pos = et.posW[0];
    light.edge0 = et.posW[1] - et.posW[0];
    light.edge1 = et.posW[2] - et.posW[0];
    light.avgRadiance = luminance(ef.averageRadiance);

    gLightBuffer[lightIdx] = light.pack();
    gLightPdf[ReSTIR_LinearIndexToZCurve(lightIdx)] =  light.avgRadiance * M_PI * et.area;
}
