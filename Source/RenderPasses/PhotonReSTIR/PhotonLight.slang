import Utils.Math.PackedFormats;
import Utils.Math.FormatConversion;

struct PhotonLight
{
    float4 posW;
    float3 flux;
    uint valid;
    float3 normal;
    uint _pad2 = 0;
}

struct PhotonData
{
    float3 flux;
    uint packedNormal;
    float3 dir;
    uint _pad;

    __init(){
        flux = float3(0);
        dir = float3(0);
        packedNormal = 0;
        _pad = 0;
    }
    
    __init(uint4 data){
        flux.xy = float2(f16tof32((data.x >> 16) & 0xFFFF), f16tof32(data.x & 0xFFFF));
        flux.z = f16tof32((data.y >> 16) & 0xFFFF);
        dir.x = f16tof32(data.y & 0xFFFF);
        dir.yz = float2(f16tof32((data.z >> 16) & 0xFFFF), f16tof32(data.z & 0xFFFF));
        packedNormal = data.w;
    }

    property float3 normal {
        get { return decodeNormal2x16(packedNormal); }
        set { packedNormal = encodeNormal2x16(newValue); }
    }

    uint4 pack()
    {
        uint4 data;
        data.x = (f32tof16(flux.x) << 16u) | f32tof16(flux.y);
        data.y = (f32tof16(flux.z) << 16u) | f32tof16(dir.x);
        data.z = (f32tof16(dir.y) << 16u) | f32tof16(dir.z);
        data.w = packedNormal;
        return data;
    }
};

// Nonsingular Point Light Attenuation by cem yuksel. Reduces bright spots near corners. Simplified version from website
// http://www.cemyuksel.com/research/pointlightattenuation/
//Inputs: Distance d and vpl radius r
//Output: Attenuation
float vplAttenuation(float d, float r)
{
    float drSq = d * d + r * r;
    float denom = drSq + d * sqrt(drSq);
    return 2.f / denom;
}
