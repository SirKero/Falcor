import Utils.Math.AABB;

cbuffer CB {
    uint gMax; //Max number of elements
    uint gOffset; // Index offset
    bool gClearToNaN; // If true minPoint.x is cleared to nan
    uint _pad;
}

RWStructuredBuffer<AABB> gAABB;


[numthreads(256, 1, 1)]
void main(uint thdID: SV_DispatchThreadID)
{
    const uint aabbIdx = thdID + gOffset;
    if (aabbIdx >= gMax)
        return;
    AABB aabb = {};
    aabb.invalidate();
    if(gClearToNaN)
        aabb.minPoint.x = 0.0 / 0.0;

    gAABB[aabbIdx] = aabb;
}
