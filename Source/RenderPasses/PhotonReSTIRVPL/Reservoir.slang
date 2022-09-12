struct Reservoir{
    //In packed
    uint lightIdx;      // Light index of the sample
    uint M;             // Number of samples. Real number equals generatedSamples * M
    float weightSum;    // Weight of the reservoir after finalizing (W in paper). Used as weightSum internaly
    float targetPdf;    // Target Pdf of current sample
    //Not in packed
    uint packedUV ;           //UV encoded as two f16

    //UV
    property float2 uv
    {
        get{ return float2(f16tof32((packedUV >> 16) & 0xFFFF), f16tof32(packedUV & 0xFFFF)); }
        set { packedUV = (f32tof16(newValue.x) << 16u) | f32tof16(newValue.y); }
    }
    
    //Empty init
    __init(){
        this = {};
        M = 0;
        weightSum = 0.f;
    }

    //Init for analytic light types
    __init(const uint4 packed){
        lightIdx = packed.x;
        M = packed.y;
        weightSum = asfloat(packed.z);
        targetPdf = asfloat(packed.w);
        this.packedUV = 0;
    }

    //Init for Emissive light types
    __init(const uint4 packed, const uint packedUV){
        lightIdx = packed.x;
        M = packed.y;
        weightSum = asfloat(packed.z);
        targetPdf = asfloat(packed.w);
        this.packedUV = packedUV;
    }

    //Pack for uint texture
    uint4 pack(){
        uint4 packed;
        packed.x = lightIdx;
        packed.y = M;
        packed.z = asuint(weightSum);
        packed.w = asuint(targetPdf);

        return packed;
    }
};
