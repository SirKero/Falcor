/***************************************************************************
 # Copyright (c) 2015-23, NVIDIA CORPORATION. All rights reserved.
 #
 # Redistribution and use in source and binary forms, with or without
 # modification, are permitted provided that the following conditions
 # are met:
 #  * Redistributions of source code must retain the above copyright
 #    notice, this list of conditions and the following disclaimer.
 #  * Redistributions in binary form must reproduce the above copyright
 #    notice, this list of conditions and the following disclaimer in the
 #    documentation and/or other materials provided with the distribution.
 #  * Neither the name of NVIDIA CORPORATION nor the names of its
 #    contributors may be used to endorse or promote products derived
 #    from this software without specific prior written permission.
 #
 # THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS "AS IS" AND ANY
 # EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 # IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 # PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE COPYRIGHT OWNER OR
 # CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 # EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 # PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 # PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 # OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 # (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 # OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 **************************************************************************/
#include "TransparencyShadowMethod.h"
#include "Utils/Math/FalcorMath.h"

/* There are different cascaded versions, all use a view matrix at the center of the scene as light view
*  Version 0: More classical approach that tries to put the ortho extends on a grid. However due to variable sizes the sm ratio can change with movement
*  Version 1: Uses fixed size for the cascade and tries to move the camera to the most suitable edge of the cascaded box. Is ill fitting when high above the air or looking up/down
*  Version 2: Uses fixed size with the cameraposition snapped to a grid as the center. 
*/
#define CASCADE_VERSION 2

namespace
{
    const Gui::DropdownList kSMResolutionDropdown = {
        {256, "256x256"}, {512, "512x512"}, {1024, "1024x1024"}, {2048, "2048x2048"}, {4096, "4096x4096"},
    };
}

TransparencyShadowMethod::TransparencyShadowMethod(ref<Device> pDevice, ref<Scene> pScene) : mpDevice(pDevice), mpScene(pScene) {
    uint count = 0;
    for (auto& lights : mpScene->getLights())
        if (lights->getType() == LightType::Directional)
        {
            mHasDirectionalLight = true;
            count++;
        }
    FALCOR_ASSERT(count <= 1); //More than 1 directional light?
    updateSMMatrices(true);
}

DefineList TransparencyShadowMethod::getDefines()
{
    DefineList defines;
    defines.add("COUNT_LIGHTS", std::to_string(std::max(mpScene->getLightCount(), 1u)));
    return defines;
}

bool TransparencyShadowMethod::renderUI(Gui::Widgets& widget) {
    //Legacy
    return false;
}

void TransparencyShadowMethod::updateSMMatrices(bool rebuild)
{
    auto& lights = mpScene->getLights();
    // Check if resize is neccessary
    bool rebuildAll = mUpdateSMMatrices;
    if (mShadowMapMVP.size() != lights.size())
    {
        mShadowMapMVP.resize(lights.size());
        rebuildAll = true;
    }

    // Update view and projection matrices
    for (uint i = 0; i < lights.size(); i++)
    {
        auto changes = lights[i]->getChanges();
        rebuild |= is_set(changes, Light::Changes::Position) || is_set(changes, Light::Changes::Direction) ||
                       is_set(changes, Light::Changes::SurfaceArea);
        rebuild |= lights[i]->getType() == LightType::Directional && mUpdateDirectional;
        rebuild |= rebuildAll;
        if (rebuild)
        {
            updateViewProjection(mShadowMapMVP[i], lights[i]);
        }
    }

    //Update Jitter
    for (uint i = 0; i < lights.size(); i++)
    {
        updateMVPAndJitter(mShadowMapMVP[i]);
    }

    mUpdateSMMatrices = false;
}

void TransparencyShadowMethod::updateViewProjection(LightMVP& lightMVP, ref<Light> pLight) {
    auto& lightData = pLight->getData();
    switch (pLight->getType())
    {
    // Directional light. Create a prespective shadow map
    case LightType::Directional:
    {
        const AABB& sceneBounds = mpScene->getSceneBounds();
        float3 center = sceneBounds.center();
        const float3 upVec = float3(0, 1, 0);
        lightMVP.view = math::matrixFromLookAt(center, center + lightData.dirW, upVec); // Fixed point for view

        auto& cameraData = mpScene->getCamera()->getData();
        float camNear = cameraData.nearZ;
        float camFar = cameraData.farZ;
        float camFovY = focalLengthToFovY(cameraData.focalLength - 2.f, cameraData.frameHeight);

        // Get the 8 corners of the frustum Part
        const float4x4 proj = math::perspective(camFovY, cameraData.aspectRatio, camNear, camFar);
        const float4x4 inv = math::inverse(math::mul(proj, cameraData.viewMat));
        std::vector<float4> frustumCorners;
        for (uint x = 0; x <= 1; x++)
        {
            for (uint y = 0; y <= 1; y++)
            {
                for (uint z = 0; z <= 1; z++)
                {
                    const float4 pt = math::mul(inv, float4(2.f * x - 1.f, 2.f * y - 1.f, z, 1.f));
                    frustumCorners.push_back(pt / pt.w);
                }
            }
        }

        // Create a view space AABB to clamp cascaded values
        AABB smViewAABB = sceneBounds.transform(lightMVP.view);

        // Get Box for Orto
        float minX = std::numeric_limits<float>::max();
        float maxX = std::numeric_limits<float>::lowest();
        float minY = std::numeric_limits<float>::max();
        float maxY = std::numeric_limits<float>::lowest();
        float minZ = std::numeric_limits<float>::max();
        float maxZ = std::numeric_limits<float>::lowest();
        for (const float4& p : frustumCorners)
        {
            float3 vp = math::mul(lightMVP.view, p).xyz();
            minX = std::min(minX, vp.x);
            maxX = std::max(maxX, vp.x);
            minY = std::min(minY, vp.y);
            maxY = std::max(maxY, vp.y);
            minZ = std::min(minZ, vp.z);
            maxZ = std::max(maxZ, vp.z);
        }
        // Set the Z values to min and max for the scene so that all geometry in the way is rendered
    #if CASCADE_VERSION == 2
        //Fixed Z
        float distDifference = smViewAABB.maxPoint.z - smViewAABB.minPoint.z;
        maxZ = math::ceil(smViewAABB.maxPoint.z + distDifference * 0.2f);
        minZ = math::floor(smViewAABB.minPoint.z);

        //Get Camera Position on a grid
        float2 camPosLV = math::mul(lightMVP.view, float4(cameraData.posW, 1.f)).xy();
        const float2 resF = float2(mResolution);
        camPosLV = math::round(camPosLV * resF) / resF;

        //Get xy offset adjusted to the grid
        const float2 halfResF = resF / 2.f;
        float2 halfResOffset = math::round(mCascadedSize * halfResF) / halfResF;
        minX = camPosLV.x - halfResOffset.x;
        maxX = camPosLV.x + halfResOffset.x;
        minY = camPosLV.y - halfResOffset.y;
        maxY = camPosLV.y + halfResOffset.y;

    #elif CASCADE_VERSION == 1
        maxZ = math::ceil(smViewAABB.maxPoint.z);
        minZ = math::floor(smViewAABB.minPoint.z);
        auto smallestDistance = [](const float4& dist, uint idx)
        {
            bool smallest = true;
            for (uint i = 0; i < 4; i++)
            {
                if (i == idx)
                    continue;
                smallest &= dist[idx] <= dist[i];
            }
            return smallest;
        };

        float2 camPosLV = math::mul(lightMVP.view, float4(cameraData.posW, 1.f)).xy();
        float4 distancesToCam = float4(camPosLV.x - minX, maxX - camPosLV.x, camPosLV.y - minY, maxY - camPosLV.y);
        bool isBot = smallestDistance(distancesToCam, 2);
        bool isTop = smallestDistance(distancesToCam, 3);
        bool isLeft = smallestDistance(distancesToCam, 0);
        bool isRight = smallestDistance(distancesToCam, 1);
        // Fix camera pox on grid
        const float2 resF = float2(mResolution);
        camPosLV = math::round(camPosLV * resF) / resF;

        if (isBot || isTop)
        {
            float2 distToCam = float2(camPosLV.x - minX, maxX - camPosLV.x);
            float totalDist = distToCam.x + distToCam.y;
            distToCam /= totalDist; //Normalize
            minX = math::round(mCascadedSize * distToCam.x * resF.x) / resF.x;
            maxX = math::round(mCascadedSize * distToCam.y * resF.x) / resF.x;
            if (isTop)
                distToCam = float2(0.95f, 0.05f);
            else
                distToCam = float2(0.05f, 0.95f);

            minY = math::round(mCascadedSize * distToCam.x * resF.y) / resF.y;
            maxY = math::round(mCascadedSize * distToCam.y * resF.y) / resF.y;
        }
        else //Left, Right
        {
            float2 distToCam = float2(camPosLV.y - minY, maxY - camPosLV.y);
            float totalDist = distToCam.x + distToCam.y;
            distToCam /= totalDist; // Normalize
            minY = math::round(mCascadedSize * distToCam.x * resF.y) / resF.y;
            maxY = math::round(mCascadedSize * distToCam.y * resF.y) / resF.y;
            if (isRight)
                distToCam = float2(0.95f, 0.05f);
            else
                distToCam = float2(0.05f, 0.95f);

            minX = math::round(mCascadedSize * distToCam.x * resF.x) / resF.x;
            maxX = math::round(mCascadedSize * distToCam.y * resF.x) / resF.x;
        }

        minX = camPosLV.x - minX;
        maxX = camPosLV.x + maxX;
        minY = camPosLV.y - minY;
        maxY = camPosLV.y + maxY;
    #elif CASCADE_VERSION == 0
        maxZ = std::max(maxZ, smViewAABB.maxPoint.z);
        minZ = std::min(minZ, smViewAABB.minPoint.z);

        const float2 resF = float2(mResolution);
        const float2 halfRes = float2(mResolution) / 2.f;
        float2 axisCenter = float2((minX + maxX) / 2.f, (minY + maxY) / 2.f);
        int2 axisOffset = int2(math::round((maxX - minX) * halfRes.x), math::round((maxY - minY) * halfRes.y));
        int2 axisCenterI = int2(math::round(axisCenter.x * resF.x), math::round(axisCenter.y * resF.y));

        int2 minCoordinates = int2(axisCenterI.x - axisOffset.x, axisCenterI.y - axisOffset.y);
        int2 maxCoordinates = int2(axisCenterI.x + axisOffset.x, axisCenterI.y + axisOffset.y);
        minX = minCoordinates.x / resF.x;
        minY = minCoordinates.y / resF.y;
        maxX = maxCoordinates.x / resF.x;
        maxY = maxCoordinates.y / resF.y;

        /*
        const float2 resF = float2(mResolution);
        int2 minCoordinates = int2(math::floor(minX * resF.x), math::floor(minY * resF.y));
        int2 maxCoordinates = int2(math::ceil(maxX * resF.x), math::ceil(maxY * resF.y));
        minX = minCoordinates.x/ resF.x;
        minY = minCoordinates.y / resF.y;
        maxX = maxCoordinates.x/ resF.x;
        maxY = maxCoordinates.y / resF.y;
        */
    #endif

        lightMVP.projectionNoJitter = math::ortho(minX, maxX, minY, maxY, -1.f * maxZ, -1.f * minZ); // set projection
        lightMVP.spreadAngle = 1.0;
        break;
    }
    case LightType::Point:
    {
        lightMVP.pos = lightData.posW;
        float openingAngle = math::min(lightData.openingAngle, float(M_PI / 4.f)); // TODO support point lights
        float3 lightTarget = lightMVP.pos + lightData.dirW;
        const float3 up = abs(lightData.dirW.y) == 1 ? float3(0, 0, 1) : float3(0, 1, 0);
        lightMVP.view = math::matrixFromLookAt(lightData.posW, lightTarget, up);
        lightMVP.projectionNoJitter = math::perspective(openingAngle * 2, 1.f, mNearFar.x, mNearFar.y);
        lightMVP.spreadAngle = std::atan(2.0f * std::tan(openingAngle * 0.5f) / mResolution.y);
        break;
    }
    default:
        throw RuntimeError(
            "Scene contains unsupported Light Type (Distant, Rect, Disc, Sphere)\n Only Spot(+Point) and Directional are currently "
            "supported"
        );
        break;
    }
}

void TransparencyShadowMethod::updateMVPAndJitter(LightMVP& lightMVP) {

    float4x4 jitterMat = math::matrixFromTranslation(float3(2.0f * mJitter.x, 2.0f * mJitter.y, 0.0f));
    lightMVP.projection = math::mul(jitterMat, lightMVP.projectionNoJitter);

    lightMVP.viewProjectionNoJitter = math::mul(lightMVP.projectionNoJitter, lightMVP.view);
    lightMVP.viewProjection = math::mul(lightMVP.projection, lightMVP.view);
    lightMVP.invViewProjection = math::inverse(lightMVP.viewProjection);
    lightMVP.invProjection = math::inverse(lightMVP.projection);
    lightMVP.invView = math::inverse(lightMVP.view);
}

void TransparencyShadowMethod::setNearFar(const float2 nearFar) {
    if (mNearFar.x != nearFar.x || mNearFar.y != nearFar.y)
    {
        mNearFar = nearFar;
        mUpdateSMMatrices = true;
    }
}

void TransparencyShadowMethod::setGlobalShadowSettings(GlobalShadowSettings& settings) {
   
    if (mResolution.x != settings.resolution){
        mResolutionChanged = true;
        mResolution = uint2(settings.resolution);
    }

    mNearFar = settings.nearFar;
    mCascadedSize = settings.cascadedSize;
    mUseColoredTransparency = settings.enableColoredTransparency;

    mMidpointPercentage = settings.midpointPercentage;
    mMidpointDepthBias = settings.depthBias;

    mEnableRandomSoftShadows = settings.enableSoftShadows;
    mRandomSoftShadowsPositionRadius = settings.softShadowsPositionRadius;
    mRandomSoftShadowsDirSpread = settings.softShadowsDirectionsSpread;
}

bool TransparencyShadowMethod::GlobalShadowSettings::renderUI(Gui::Widgets& widget) {
    #if SIMPLE_UI
    widget.dropdown("Resolution", kSMResolutionDropdown, resolution);
    widget.var("Cascaded Size", cascadedSize, 0.f, FLT_MAX, 0.1f);
    widget.tooltip("Radius for the cascade from Camera Origin. Ray Tracing is used for the area outside of the radius");
    widget.var("Midpoint Percentage (Dual Depth SM)", midpointPercentage, 0.f, 1.f, 0.001f);
    widget.tooltip("Sets where the midpoint of the midpoint depth is set. 0.0 first depth, 1.0 second depth");
    widget.var("Depth Bias", depthBias, 1e-9f, FLT_MAX, 0.00001f, false, "%.7f");
    widget.tooltip("Depth bias for Dual Depth Shadow Maps. Min(depth + depthBias, midpoint) is used.");
    #else
    widget.dropdown("ShadowResolution", kSMResolutionDropdown, resolution);
    widget.var("Near/Far", nearFar, 0.0f, FLT_MAX, 0.001f);
    widget.tooltip("Global Near/Far values for all lights spotlights");
    widget.var("Cascaded Size", cascadedSize, 0.f, FLT_MAX, 0.1f);
    widget.tooltip("Radius for the cascade");
    widget.checkbox("Enable Colored Transparency", enableColoredTransparency);
    widget.tooltip("Enabled Colored transparency for all methods that support it");

    widget.var("Midpoint Percentage", midpointPercentage, 0.f, 1.f, 0.001f);
    widget.tooltip("Sets where the midpoint of the midpoint depth is set. 0.0 first depth, 1.0 second depth");
    widget.var("Depth Bias", depthBias, 1e-9f, FLT_MAX, 0.00001f, false, "%.7f");
    widget.tooltip("Depth bias for midpoint shadow maps. Min(depth + depthBias, midpoint) is used.");
    #endif

    return false;
}
