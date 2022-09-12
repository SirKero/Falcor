import Utils.Math.PackedFormats;
import Utils.Math.FormatConversion;

struct VPL{
    float3 posW;
    uint packedNormal;
    float3 flux;
    uint valid;

    //Shading world normal
    property float3 normal{
        get { return decodeNormal2x16(packedNormal); }
        set { packedNormal = encodeNormal2x16(newValue); }
    }
};
