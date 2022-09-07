#include "Utils/Math/MathConstants.slangh"

//Packed Structure
struct PackedReSTIRLight{
    uint4 data0;
    uint4 data1;
};

//Shader Struct
struct ReSTIRLight{
    uint lightIdx;
    float3 pos;
    float3 edge0;
    float avgRadiance;
    float3 edge1;
    int valid;

    //Init
    __init(PackedReSTIRLight packed){
        lightIdx = packed.data0.x;
        pos = asfloat(packed.data0.yzw);
        edge0 = f16tof32(packed.data1.xyz & 0xffff);
        edge1 = f16tof32(packed.data1.xyz >> 16);
        avgRadiance = asfloat(packed.data1.w);
        valid = 1;
    }

    __init(){
        this = {};
        valid = -1;
    }

    bool isValid(){
        return valid > 0;
    }

    PackedReSTIRLight pack(){
        PackedReSTIRLight packed;
        packed.data0 = uint4(lightIdx, asuint(pos));
        packed.data1.xyz = (f32tof16(edge0) & 0xffff) | ((f32tof16(edge1) << 16));
        packed.data1.w = asuint(avgRadiance);

        return packed;
    }

    float getArea()
    {
        return 0.5f * length(cross(edge0, edge1));
    }

    float getFlux()
    {
        // Note: This assumes emission to be diffuse. Same assumption is taken in LightCollection.
        return getArea() * avgRadiance * M_PI;
    }
};

//Helper functions for light index calculations

// "Explodes" an integer, i.e. inserts a 0 between each bit.  Takes inputs up to 16 bit wide.
//      For example, 0b11111111 -> 0b1010101010101010
uint ReSTIR_IntegerExplode(uint x)
{
    x = (x | (x << 8)) & 0x00FF00FF;
    x = (x | (x << 4)) & 0x0F0F0F0F;
    x = (x | (x << 2)) & 0x33333333;
    x = (x | (x << 1)) & 0x55555555;
    return x;
}

// Reverse of ReSTIR_IntegerExplode, i.e. takes every other bit in the integer and compresses
// those bits into a dense bit firld. Takes 32-bit inputs, produces 16-bit outputs.
//    For example, 0b'abcdefgh' -> 0b'0000bdfh'
uint ReSTIR_IntegerCompact(uint x)
{
    x = (x & 0x11111111) | ((x & 0x44444444) >> 1);
    x = (x & 0x03030303) | ((x & 0x30303030) >> 2);
    x = (x & 0x000F000F) | ((x & 0x0F000F00) >> 4);
    x = (x & 0x000000FF) | ((x & 0x00FF0000) >> 8);
    return x;
}

// Converts a 2D position to a linear index following a Z-curve pattern.
uint ReSTIR_ZCurveToLinearIndex(uint2 xy)
{
    return ReSTIR_IntegerExplode(xy[0]) | (ReSTIR_IntegerExplode(xy[1]) << 1);
}

// Converts a linear to a 2D position following a Z-curve pattern.
uint2 ReSTIR_LinearIndexToZCurve(uint index)
{
    return uint2(
        ReSTIR_IntegerCompact(index),
        ReSTIR_IntegerCompact(index >> 1));
}
