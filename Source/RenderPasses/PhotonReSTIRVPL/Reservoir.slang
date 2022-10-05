struct Reservoir{
    //In packed
    uint lightIdx;      // Light index of the sample
    uint M;             // Number of samples. Real number equals generatedSamples * M
    float weightSum;    // Weight of the reservoir after finalizing (W in paper). Used as weightSum internaly
    float targetPdf;    // Target Pdf of current sample
    //Not in packed
    float2 uv;
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
        this.uv = float2(0);
        //Invalidate if nan or inf is present
        if(isinf(weightSum) || isnan(weightSum)){
            weightSum = 0;
            M = 0;
        }
    }

    //Init for analytic light types
    __init(const uint4 packed, const float2 uv){
        lightIdx = packed.x;
        M = packed.y;
        weightSum = asfloat(packed.z);
        targetPdf = asfloat(packed.w);
        this.uv = uv;
        //Invalidate if nan or inf is present
        if(isinf(weightSum) || isnan(weightSum)){
            weightSum = 0;
            M = 0;
        }
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
