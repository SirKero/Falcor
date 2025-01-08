import Rendering.Materials.TexLODTypes;
import Rendering.Materials.TexLODHelpers;

#ifndef RAY_LOD_MODE
#define RAY_LOD_MODE 0 //Mip0
#endif

#ifndef SHADOW_LOD_MODE
#define SHADOW_LOD_MODE 0 //Mip 0
#endif

#ifndef SCREEN_SPACE_PIXEL_SPREAD_ANGLE
#define SCREEN_SPACE_PIXEL_SPREAD_ANGLE 1.0
#endif

static const TexLODMode kLODMode = TexLODMode(RAY_LOD_MODE);
static const TexLODMode kShadowLODMode = TexLODMode(SHADOW_LOD_MODE);
static const float2 kInvFrameDim = float2(INV_FRAME_DIM_X, INV_FRAME_DIM_Y);
static const float kScreenSpacePixelSpreadAngle = SCREEN_SPACE_PIXEL_SPREAD_ANGLE;

/** Ray differentials for primary hit. Code from RayTracingGems, Chapter 20.
 */
void computeRayDifferentials(const TriangleHit hit, float3 rayDir, float hitT, const Camera camera, float2 invFrameDim, out float2 ddx, out float2 ddy)
{
    // TODO: Is this code correct for instance transforms that flip the handedness of the coordinate system?

    // Ray differentials
    float3 P[3];
    gScene.getVertexPositionsW(hit.instanceID, hit.primitiveIndex, P);
    float3 e1 = P[1] - P[0];
    float3 e2 = P[2] - P[0];
    float3 d = rayDir;
    float k = dot(cross(e1, e2), d);
    k = abs(k) > 1e-20f ? rcp(k) : 0.0f;
    float3 cu = cross(e2, d);
    float3 cv = cross(d, e1);
    // Assumes a normalized ray direction
    float3 dx = camera.data.cameraU * 2.f * invFrameDim.x / camera.data.focalDistance; // dDdx in ray gen
    float3 dy = camera.data.cameraV * 2.f * invFrameDim.y / camera.data.focalDistance; // dDdy in ray gen
    float3 q = dx * hitT;                                                              // Transfer to primary hit
    float3 r = dy * hitT;
    float dudx = k * dot(cu, q);
    float dudy = k * dot(cu, r);
    float dvdx = k * dot(cv, q);
    float dvdy = k * dot(cv, r);
    float2 T[3];
    gScene.getVertexTexCoords(hit.instanceID, hit.primitiveIndex, T);
    float2 g1 = T[1] - T[0];
    float2 g2 = T[2] - T[0];
    float dsdx = (dudx * g1.x + dvdx * g2.x);
    float dsdy = (dudy * g1.x + dvdy * g2.x);
    float dtdx = (dudx * g1.y + dvdx * g2.y);
    float dtdy = (dudy * g1.y + dvdy * g2.y);
    ddx = float2(dsdx, dtdx);
    ddy = float2(dsdy, dtdy);
}

void computeAnisotropicAxesRayCones(const TriangleHit hit, VertexData v, float3 rayDir, float hitT, float pixelAngle, out float2 ddx, out float2 ddy)
{
    float3 positions[3];
    float2 texCoords[3];
    gScene.getVertexPositionsW(hit.instanceID, hit.primitiveIndex, positions);
    gScene.getVertexTexCoords(hit.instanceID, hit.primitiveIndex, texCoords);

    float coneWidthAtHitPoint = hitT * tan(pixelAngle); // The exact expression is 2.0f * hitT * tan(pixelAngle * 0.5f), but can be approximated as hitT * tan(pixelAngle) due to tan(b) ~= b for small b.
    // Using faceNormal, since it is needed for the barycentric computations inside computeAnisotropicEllipseAxes().
    computeAnisotropicEllipseAxes(v.posW, v.faceNormalW, rayDir, coneWidthAtHitPoint, positions, texCoords, v.texC, ddx, ddy);
}

float3 computeDdxPosW(float3 posW, float3 normW, float2 invFrameDim)
{
    float3 projRight = normalize(cross(normW, cross(normW, gScene.camera.data.cameraV)));
    float distanceToHit = length(posW - gScene.camera.data.posW);
    float2 ddNdc = float2(2.f, -2.f) * invFrameDim;
    float distRight = distanceToHit * ddNdc.x / dot(normalize(gScene.camera.data.cameraV), projRight);
    return distRight * projRight;
}

float3 computeDdyPosW(float3 posW, float3 normW, float2 invFrameDim)
{
    float3 projUp = normalize(cross(normW, cross(normW, gScene.camera.data.cameraU)));
    float distanceToHit = length(posW - gScene.camera.data.posW);
    float2 ddNdc = float2(2.f, -2.f) * invFrameDim;
    float distUp = distanceToHit * ddNdc.y / dot(normalize(gScene.camera.data.cameraU), projUp);
    return distUp * projUp;
}
