#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.Raytracing;
import Scene.Intersection;
import Utils.Math.MathHelpers;
import Utils.Geometry.GeometryHelpers;
import VirtualShadowMapData; 


#ifndef NUM_CLIPMAPS 
#define NUM_CLIPMAPS 1
#endif

#define data gVirtualShadowMapData

Texture2D<PackedHitInfo> gVBuffer;

[numthreads(16, 16, 1)]
void main(uint2 pixel: SV_DispatchThreadID)
{
    for (uint clipMapLevel = 0; clipMapLevel < NUM_CLIPMAPS; ++clipMapLevel)
    {
        if (any(pixel >= uint2(1920, 1080)))
        {
            return;
        }
        HitInfo hit = HitInfo(gVBuffer[pixel]);
        if (hit.isValid()) {
          const TriangleHit triangleHit = hit.getTriangleHit();
          VertexData v = gScene.getVertexData(triangleHit);
          data.updateRequiredPages(v.posW, clipMapLevel);
        }
    }
}
