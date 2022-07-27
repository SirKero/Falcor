struct Reservoir{
    uint lightIdx;
    uint M;
    float weightSum;
    float W;
    float targetPdf;
    uint lightType;
    uint age;
    uint uv ;

    static Reservoir create(){
        Reservoir r;
        r.lightIdx = 0;
        r.M = 0;
        r.weightSum = 0.f;
        r.W = 0.f;
        r.targetPdf = 0.f;
        r.lightType = 0;
        r.age = 0;
        r.uv = 0;
        return r;
    }
    
    [mutating] void setUV(float2 uvF){
        uint u = f32tof16(uvF.x);
        uint v = f32tof16(uvF.y);
        uv = (u << 16u) | v;
    }
    
    float2 getUV(){
        float u = f16tof32((uv >> 16) & 0xFFFF);
        float v = f16tof32(uv & 0xFFFF);
        return float2(u,v);
    }
};
