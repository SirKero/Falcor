struct Reservoir{

    uint lightIdx;      // Light index of the sample
    uint M;             // Number of samples. Real number equals generatedSamples * M
    float weightSum;    // Weight of the reservoir after finalizing (W in paper). Used as weightSum internaly
    float targetPdf;    // Target Pdf of current sample
    
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

    //Updates reservoir with new light sample. Returns true if the light sample was selected
    [mutating] bool updateReservoir(const uint lightSampleIndex, const float invSelectPdf,const float lsTargetPdf, const float rnd){
        float risWeight = lsTargetPdf * invSelectPdf;
        weightSum += risWeight;
        M += 1;
        bool selectSample = (rnd * weightSum < risWeight);
    
        if(selectSample){
            lightIdx = lightSampleIndex;
            targetPdf = lsTargetPdf;
        }
        return selectSample;
    }

    //Combines another reservoir with this reservoir. Returs true if the new reservoir was selected
    [mutating] bool combineReservoir(in const Reservoir other, const float otherTargetPDF,const float rnd){
        float normalizationFactor = other.weightSum * other.M;

        float risWeight = otherTargetPDF * normalizationFactor;
    
        M += other.M;
    
        weightSum += risWeight;

        bool selectSample = (rnd * weightSum < risWeight);
    
        if(selectSample){
            lightIdx = other.lightIdx;
            targetPdf = otherTargetPDF;
        }

        return selectSample;
    }

    //Finalizes a sample. Normalizes the Wsum to W (and uses weightSum to store W)
    [mutating] void finalizeSample(float normalizationNumerator, float normalizationDenominator){
        float denominator = targetPdf * normalizationDenominator;

        weightSum = denominator > 0 ? (weightSum * normalizationNumerator) / denominator : 0.f;
    }
};
