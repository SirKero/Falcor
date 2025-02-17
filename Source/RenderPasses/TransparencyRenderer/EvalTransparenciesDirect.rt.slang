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
RWTexture2D<float4> gThpOut;

#ifndef ENABLE_TRANSPARENCY_LOD
#define ENABLE_TRANSPARENCY_LOD 0
#endif

#define is_valid(name) (is_valid_##name != 0)
static const float kMinOpacity = 1e-7;
static const uint kMaxElements = 256; // For now 256 max transparent elements on a ray
static const bool kAdjustShadingNormals = true;
static const float kAmbientStrength = AMBIENT_STRENGTH;
static const float kDepthMVOpacityThreshold = 0.7;   //If thp is above this value, the mv and depth are updated if there are multiple hits


/** Payload for alpha ray (20B + 16B if lod is enabled)
*/
struct TransparencyRayData {
    PackedHitInfo hit; //< Packed Hit
    float dist;

    #if ENABLE_TRANSPARENCY_LOD
    float2 ddx;
    float2 ddy;
    #endif

    __init(float tMax)
    {
        hit = {}; // Init emtpy
        dist = tMax;
        #if ENABLE_TRANSPARENCY_LOD
        ddx = float2(0);
        ddy = float2(0);
        #endif
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
    #if ENABLE_TRANSPARENCY_LOD
        float2 ddx = float2(0);
        float2 ddy = float2(0);
        //LOD
        if (kLODMode == TexLODMode::RayCones)
        {
            computeAnisotropicAxesRayCones(triangleHit, v, -WorldRayDirection(), RayTCurrent(), kScreenSpacePixelSpreadAngle, ddx, ddy);
            lod = ExplicitGradientTextureSampler(ddx, ddy);
        }
        else if (kLODMode == TexLODMode::RayDiffs)
        {
            computeRayDifferentials(triangleHit, -WorldRayDirection(), RayTCurrent(), gScene.camera, kInvFrameDim, ddx, ddy);
            lod = ExplicitGradientTextureSampler(ddx, ddy);
        }
    #endif

    if (!gScene.materials.alphaTest(v, materialID, lod, kMinOpacity)) {
        //Update payload
        if (RayTCurrent() < rayData.dist) {
           
            rayData.hit = HitInfo(triangleHit).getData();
            rayData.dist = RayTCurrent();
            #if ENABLE_TRANSPARENCY_LOD
                rayData.ddx = ddx;
                rayData.ddy = ddy;
            #endif
        }
    } else {
        IgnoreHit();
    }
    
}

[shader("closesthit")]
void closestHit(inout TransparencyRayData rayData, BuiltInTriangleIntersectionAttributes attribs)
{
    //Skipped
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
    //Get tMax for this either with depth texture or vBuffer
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
    bool mVecUpdated = false;
    bool depthUpdated = false;

    for(uint i=0; i<kMaxElements && !pd.terminated; i++){
        // Trace Ray
        uint rayFlags = RAY_FLAG_CULL_OPAQUE | RAY_FLAG_SKIP_CLOSEST_HIT_SHADER;
        TraceRay(gScene.rtAccel, rayFlags, kInstanceCameraParticle, 0, rayTypeCount, 0, ray, rayData);

        //Miss
        if(rayData.dist < 0){
            pd.terminated = true;
            break;
        }

        HitInfo hit = HitInfo(rayData.hit);
        if(!hit.isValid())
            break;

        ITextureSampler lod = ExplicitLodTextureSampler(0.f);
        #if ENABLE_TRANSPARENCY_LOD
            lod = ExplicitGradientTextureSampler(rayData.ddx, rayData.ddy);
        #endif 
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

        // Ambient
        pd.radiance += pd.thp * bsdfProperties.diffuseReflectionAlbedo * kAmbientStrength * sd.opacity;

        //Update thp
        float transparency = (1.0 - sd.opacity);
        pd.thp *= transparency; // TODO weight with color?

        if (all(pd.thp <= kMinOpacity))
            pd.terminated = true;

        //Update ray
        ray.TMin = rayData.dist + 1e-10;
        rayData = TransparencyRayData(ray.TMax);

        // Update depth and motion vector if valid
        bool overThreshold = any(pd.thp > kDepthMVOpacityThreshold);
        if (is_valid(gOutDepth) && (!depthUpdated || overThreshold )) {
            float4 curPosH = mul(gScene.camera.data.viewProjMatNoJitter, float4(sd.posW, 1.f));
            depth = curPosH.z / curPosH.w;
            depthUpdated = true;
        }
        if (is_valid(gOutMotion) && (!mVecUpdated || overThreshold)) {
            // Compute motion vector.
            float3 prevPosW = gScene.getPrevPosW(hit.getTriangleHit());
            float2 pixelPos = pixel + float2(0.5f, 0.5f);
            float4 prevPosH = mul(gScene.camera.data.prevViewProjMatNoJitter, float4(prevPosW, 1.f));
            mVec = calcMotionVector(pixelPos, prevPosH, frameDim) + float2(gScene.camera.data.jitterX, -gScene.camera.data.jitterY); // Remove camera jitter from motion vector
            mVecUpdated = true;
        }
    }
    //Write data
    gOutputColor[pixel] = float4(pd.radiance, 1.0);
    gThpOut[pixel] = float4(pd.thp, 1.0);

    if (is_valid(gOutMotion))
        gOutMotion[pixel] = mVec;
    if (is_valid(gOutDepth))
        gOutDepth[pixel] = depth;
}
