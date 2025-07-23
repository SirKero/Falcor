import Scene.Raytracing;

struct PhotonData {
    float3 flux;
    uint _pad1;
    float3 dir;
    uint _pad2;
    float3 normalW;
    uint _pad3;

    __init() {
        this.dir = float3(0);
        this.normalW = float3(0,1,0);
        this.flux = float3(0);
        this._pad1 = 0;
        this._pad2 = 0;
        this._pad3 = 0;
    }
}

enum class PhotonType // : uint32_t
{
    Global = 0,
    Caustic = 1
};

//Data for the FG sample 64B
struct FGSampleData {
    float3 posW;
    float normalX;
    float3 radianceOut;
    float normalY;
    float3 thp;
    float normalZ;

    __init() {
        posW = float3(0);
        normalX = 0;
        normalY = 1;
        normalZ = 0;
        radianceOut = float3(0);
        thp = float3(1);
    }

    //Normal helper
    property float3 normal {
        get { return float3(normalX, normalY, normalZ); }
        set {
            normalX = newValue.x;
            normalY = newValue.y;
            normalZ = newValue.z;
        }
    }
}

//Reservoir for a Final Gather Sample 112B
struct ReservoirFG {
    PackedHitInfo sampleSurface;    // HitSample 16B
    float3 sampleView;              // View vector for the sample
    float targetFunction;           // Store target function
    FGSampleData sampleData;        // Data of the sample
    float wSum;                     // W and wsum
    uint c;                         // Confidence weight
    float jacobianDeterminant;      // Jacobian determinant to the current sample
    uint pathLength;                // Path Length

    __init() {
        sampleSurface = {};
        sampleView = float3(0);
        targetFunction = 0;
        sampleData = FGSampleData();
        wSum = 0;
        c = 0;
        pathLength = 0;
        jacobianDeterminant = -1.0;
    }

    //Valid check
    bool isValid() {
        return jacobianDeterminant >= 0;
    }
}

//Load in shading data from hit and direction
ShadingData loadShadingData(const HitInfo hit, const float3 rayDir, const ITextureSampler lod)
{
    const TriangleHit triangleHit = hit.getTriangleHit();
    VertexData v = gScene.getVertexData(triangleHit);
    uint materialID = gScene.getMaterialID(triangleHit.instanceID);
    ShadingData sd = gScene.materials.prepareShadingData(v, materialID, -rayDir, lod);
    
    return sd;
}

uint index2Dto1D(uint2 index, uint frameDimX) {
    return index.x + index.y * frameDimX;
}

