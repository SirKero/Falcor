#include "EvaluateAnalyticLight.slang"
 
import Utils.Math.MathHelpers;

cbuffer CB
{
    uint gFrameCount; // Current it for sample gen
}

// Inputs
Texture2D<PackedHitInfo> gVBuffer;
Texture2D<float4> gViewW; // Optional

// Depths/MV for TAA or DLSS
Texture2D<float> gInDepth;
Texture2D<float2> gInMotion;
RWTexture2D<float> gOutDepth;
RWTexture2D<float2> gOutMotion;

// Outputs
RWTexture2D<float4> gOutputColor;

#define is_valid(name) (is_valid_##name != 0)
static const float kMinOpacity = 1e-7;
static const uint kMaxElements = 256; // For now 256 max transparent elements on a ray
static const bool kAdjustShadingNormals = true;

// TODO set as CPU defines
static const uint kMaxBounces = 256;           //Max Bounces
static const bool kUseRussianRoulette = false; //Russian Roulette

/** Payload for alpha ray (20B + 16B if lod is enabled)
*/
struct TransparencyRayData {
    PackedHitInfo hit; //< Packed Hit
    float dist;

    __init(float tMax)
    {
        hit = {}; // Init emtpy
        dist = tMax;
    }
}

/** Struct with data for the current path
*/
struct PathData
{
    float3  radiance;       ///< Accumulated outgoing radiance from path.
    bool    terminated;     ///< Set to true when path is terminated.
    float3  thp;            ///< Current path throughput. This is updated at each path vertex.
    uint    pathLength;     ///< Path length in number of path segments (0 at origin, 1 at first secondary hit, etc.). Max 2^31.
    float3 origin;          ///< Next path segment origin.
    float rayTransparency;  ///< Full transparency for the ray
    float3 direction;       ///< Next path segment direction.
    float alphaDist;        ///< Distance when the alpha ray should start

    SampleGenerator sg;     ///< Per-ray state for the sample generator (up to 16B).

    /** Initializes ray payload with default parameters.
    */
    __init()
    {
        this.terminated = false;
        this.pathLength = 0;
        this.radiance = float3(0, 0, 0);
        this.thp = float3(1, 1, 1);
        this.origin = float3(0, 0, 0);
        this.direction = float3(0, 0, 0);
        this.alphaDist = 0.0;
    }
};

/** Setup ShadingData based on loaded vertex/material attributes for a hit point.
    \param[in] hit Hit information.
    \param[in] rayOrigin Ray origin.
    \param[in] rayDir Normalized ray direction.
    \param[in] lod Method for computing texture level-of-detail.
    \return ShadingData struct.
*/
ShadingData loadShadingData(const HitInfo hit, const float3 rayDir, const ITextureSampler lod)
{
    const TriangleHit triangleHit = hit.getTriangleHit();
    VertexData v = gScene.getVertexData(triangleHit);
    uint materialID = gScene.getMaterialID(triangleHit.instanceID);

    ShadingData sd = gScene.materials.prepareShadingData(v, materialID, -rayDir, lod);

    return sd;
}

[shader("miss")]
void miss(inout TransparencyRayData rayData)
{
    rayData.dist = -1.0f; 
}

[shader("anyhit")]
void anyHit(inout TransparencyRayData rayData, BuiltInTriangleIntersectionAttributes attribs)
{
    // Alpha test for non-opaque geometry.
    TriangleHit triangleHit;
    triangleHit.instanceID = getGeometryInstanceID();
    triangleHit.primitiveIndex = PrimitiveIndex();
    triangleHit.barycentrics = attribs.barycentrics;

    VertexData v = gScene.getVertexData(triangleHit);
    uint materialID = gScene.getMaterialID(triangleHit.instanceID);
    ITextureSampler lod = ExplicitLodTextureSampler(0.f);
   
    if (gScene.materials.alphaTest(v, materialID, lod, kMinOpacity))
        IgnoreHit();
}

[shader("closesthit")]
void closestHit(inout TransparencyRayData rayData, BuiltInTriangleIntersectionAttributes attribs)
{
    TriangleHit triangleHit;
    triangleHit.instanceID = getGeometryInstanceID();
    triangleHit.primitiveIndex = PrimitiveIndex();
    triangleHit.barycentrics = attribs.barycentrics;

    rayData.hit = HitInfo(triangleHit).getData();
    rayData.dist = RayTCurrent();
}

[shader("raygeneration")]
void rayGen()
{
    const uint2 pixel = DispatchRaysIndex().xy;
    const uint2 frameDim = DispatchRaysDimensions().xy;
    
    float3 viewDir;
    if (is_valid(gViewW))
        viewDir = -gViewW[pixel].xyz;
    else
        viewDir = gScene.camera.computeRayPinhole(pixel, frameDim).dir;

    // Prepare ray payload.
    PathData pd = PathData();
    pd.origin = gScene.camera.getPosition();
    pd.direction = viewDir;
    pd.sg = SampleGenerator(pixel, gFrameCount);

    float tMax = gScene.camera.data.farZ;
    float depth = 1;
    
    //Get tMax for the first bounce either with depth texture or vBuffer
    if (is_valid(gInDepth)) {
        depth = gInDepth[pixel];
        // Get recreated 3D position
        float2 ndc = (float2(pixel) + 0.5) / frameDim; // in [0,1]
        ndc = 2.0 * ndc - 1.0;                         // in [-1,1]
        float4 recreatedPos = mul(gScene.camera.data.invViewProj, float4(ndc, depth, 1.0));
        recreatedPos.xyz /= recreatedPos.w; //Perspective division

        tMax = min(tMax, distance(recreatedPos.xyz, pd.origin));
    } else { //Use VBuffer for hit
        HitInfo hit = HitInfo(gVBuffer[pixel]);
        if (hit.isValid()) {
            const TriangleHit triangleHit = hit.getTriangleHit();
            VertexData v = gScene.getVertexData(triangleHit);
            tMax = min(tMax, length(v.posW - pd.origin)); // Linear depth
        }
    }

    tMax = 100000.0;

    //Motion vector
    float2 mVec = float2(0);
    if (is_valid(gInMotion))
        mVec = gInMotion[pixel];

    //Prepare Ray
    RayDesc ray;
    ray.Origin = pd.origin;
    ray.Direction = pd.direction;
    ray.TMin =  gScene.camera.data.nearZ;
    ray.TMax = tMax;
    TransparencyRayData rayData = TransparencyRayData(tMax);

    for(uint i=0; i<kMaxBounces && !pd.terminated; i++){
        // Trace Ray
        uint rayFlags = 0;
        TraceRay(gScene.rtAccel, rayFlags, 0xFF, 0, rayTypeCount, 0, ray, rayData);

        //Miss
        if(rayData.dist < 0){
            pd.terminated = true;
            break;
        }

        HitInfo hit = HitInfo(rayData.hit);
        if(!hit.isValid())
            break;

        ITextureSampler lod = ExplicitLodTextureSampler(0.f);
        //Get shading data
        ShadingData sd = loadShadingData(hit, pd.direction, lod);
        // Get material instance
        uint hints = 0;
        if (kAdjustShadingNormals)
            hints |= (uint)MaterialInstanceHints::AdjustShadingNormal;
        let mi = gScene.materials.getMaterialInstance(sd, lod, hints);
        // Emissive lights
        BSDFProperties bsdfProperties = mi.getProperties(sd);
        pd.radiance += pd.thp * bsdfProperties.emission * sd.opacity;

        // Analytic
        pd.radiance += evalDirectAnalytic(sd, mi, pd.sg, pd.thp * sd.opacity);

        //Determine THP and new ray
        if(i==0)
            ray.TMax = 100000.0;

        float pReflect = sampleNext1D(pd.sg);
        if(pReflect < sd.opacity){
            // Sample material.
            BSDFSample bsdfSample;
            pd.terminated |= !mi.sample(sd, pd.sg, bsdfSample);
            pd.origin = sd.computeNewRayOrigin(!bsdfSample.isLobe(LobeType::Transmission));
            pd.direction = bsdfSample.wo;
            pd.thp *= bsdfSample.weight;
            //pd.thp /= sd.opacity;
            ray.TMin = 0.0;
            rayData = TransparencyRayData(ray.TMax);
        }
        else{
            pd.thp *= (1.0 - sd.opacity);
            ray.TMin = rayData.dist + 1e-10;
        }

        if (all(pd.thp <= kMinOpacity))
            pd.terminated = true;

        //Update ray
        rayData = TransparencyRayData(ray.TMax);
        ray.Origin = pd.origin;
        ray.Direction = pd.direction;

        // Update depth and motion vector if valid
        if (i == 0 && is_valid(gOutDepth)) {
            float4 curPosH = mul(gScene.camera.data.viewProjMatNoJitter, float4(sd.posW, 1.f));
            depth = curPosH.z / curPosH.w;
        }
        if (i == 0 && is_valid(gOutMotion)) {
            // Compute motion vector.
            float3 prevPosW = gScene.getPrevPosW(hit.getTriangleHit());
            float2 pixelPos = pixel + float2(0.5f, 0.5f);
            float4 prevPosH = mul(gScene.camera.data.prevViewProjMatNoJitter, float4(prevPosW, 1.f));
            mVec = calcMotionVector(pixelPos, prevPosH, frameDim) + float2(gScene.camera.data.jitterX, -gScene.camera.data.jitterY); // Remove camera jitter from motion vector
        }
    }
    //Write data
    gOutputColor[pixel] = float4(pd.radiance, 1.0);

    if (is_valid(gOutMotion))
        gOutMotion[pixel] = mVec;
    if (is_valid(gOutDepth))
        gOutDepth[pixel] = depth;
}
