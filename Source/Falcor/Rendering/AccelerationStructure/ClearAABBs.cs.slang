import Utils.Math.AABB;

cbuffer CB {
    uint gMax; //Max number of elements
    uint gOffset; //Index offset
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
    aabb.minPoint.x = 0.0 / 0.0;

    gAABB[aabbIdx] = aabb;
}
