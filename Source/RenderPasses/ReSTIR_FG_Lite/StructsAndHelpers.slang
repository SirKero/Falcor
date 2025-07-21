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
    __init(float3 flux, float3 dir, float3 normalW) {
        this.dir = dir;
        this.normalW = normalW;
        this.flux = flux;
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

//Load in shading data from hit and direction
ShadingData loadShadingData(const HitInfo hit, const float3 rayDir, const ITextureSampler lod)
{
    const TriangleHit triangleHit = hit.getTriangleHit();
    VertexData v = gScene.getVertexData(triangleHit);
    uint materialID = gScene.getMaterialID(triangleHit.instanceID);
    ShadingData sd = gScene.materials.prepareShadingData(v, materialID, -rayDir, lod);
    
    return sd;
}


