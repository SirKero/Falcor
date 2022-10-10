import Utils.Math.AABB;
import VPLs;

StructuredBuffer<PackedVPL> gVPLs;
RWStructuredBuffer<AABB> gAABBs;

cbuffer Uniform{
    float gRadius;      //Collect radius for the vpls
    uint gNumVPLs;      //Total number of vpls;
    uint gDimY;
    uint _pad;
}


[numthreads(16, 16, 1)]
void main(uint2 dTid : SV_DispatchThreadID){
    //Get VPL index and number of vpls
    const uint idx = dTid.x + dTid.y * gDimY;
    const uint vplCount = gNumVPLs;

    //Do nothing on the too high indices
    if(idx >= vplCount)
        return;

    //Load VPL and create AABB
    VPL vpl = VPL(gVPLs[idx]);
    AABB aabb = AABB(vpl.posW - gRadius, vpl.posW + gRadius);

    gAABBs[idx] = aabb; 
}
