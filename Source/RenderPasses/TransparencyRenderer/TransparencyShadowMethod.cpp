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

namespace
{
    const Gui::DropdownList kSMResolutionDropdown = {
        {256, "256x256"}, {512, "512x512"}, {768, "768x768"}, {1024, "1024x1024"}, {2048, "2048x2048"}, {4096, "4096x4096"},
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
}

DefineList TransparencyShadowMethod::getDefines()
{
    DefineList defines;
    defines.add("COUNT_LIGHTS", std::to_string(std::max(mpScene->getLightCount(), 1u)));
    return defines;
}

bool TransparencyShadowMethod::renderUI(Gui::Widgets& widget) {
    mResolutionChanged = false;
    //For now only support quadratic shadow maps
    mResolutionChanged |= widget.dropdown("ShadowResolution", kSMResolutionDropdown, mResolution.x);
    if (mResolutionChanged)
        mResolution.y = mResolution.x;

    mUpdateSMMatrices |= widget.var("Near/Far", mNearFar, 0.0f, FLT_MAX, 0.001f);
    if (mHasDirectionalLight)
    {
        widget.var("Directional Light Max Camera Dist", mDirectionalMaxCameraDist, 0.001f, FLT_MAX);
        widget.tooltip("The maximum camera distance that is used to create the perspective shadow map");
    }

    return mResolutionChanged || mUpdateSMMatrices;
}

void TransparencyShadowMethod::updateSMMatrices(RenderContext* pRenderContext, bool rebuild)
{
    auto& lights = mpScene->getLights();
    // Check if resize is neccessary
    bool rebuildAll = mUpdateSMMatrices;
    if (mShadowMapMVP.size() != lights.size())
    {
        mShadowMapMVP.resize(lights.size());
        rebuildAll = true;
    }

    // Update matrices
    for (uint i = 0; i < lights.size(); i++)
    {
        auto changes = lights[i]->getChanges();
        rebuild |= is_set(changes, Light::Changes::Position) || is_set(changes, Light::Changes::Direction) ||
                       is_set(changes, Light::Changes::SurfaceArea);
        rebuild |= lights[i]->getType() == LightType::Directional && mUpdateDirectional;
        rebuild |= rebuildAll;
        if (rebuild)
        {
            updateMVP(mShadowMapMVP[i], lights[i]);
        }
    }
    mUpdateSMMatrices = false;
}

void TransparencyShadowMethod::updateMVP(LightMVP& lightMVP, ref<Light> pLight) {
    auto& lightData = pLight->getData();
    switch (pLight->getType())
    {
    // Directional light. Create a prespective shadow map
    case LightType::Directional:
    {
        auto& cameraData = mpScene->getCamera()->getData();
        float camNear = cameraData.nearZ;
        float camFar = math::min(cameraData.farZ, mDirectionalMaxCameraDist); // TODO better limiter
        float camFovY = focalLengthToFovY(cameraData.focalLength, cameraData.frameHeight);

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
        // Get Centerpoint for view
        float3 center = float3(0);
        const float3 upVec = float3(0, 1, 0);
        for (const auto& p : frustumCorners)
            center += p.xyz();
        center /= 8.f;
        lightMVP.view = math::matrixFromLookAt(center, center + lightData.dirW, upVec); // Set view

        // Create a view space AABB to clamp cascaded values
        const AABB& sceneBounds = mpScene->getSceneBounds();
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
        maxZ = std::max(maxZ, smViewAABB.maxPoint.z);
        minZ = std::min(minZ, smViewAABB.minPoint.z);

        lightMVP.projection = math::ortho(minX, maxX, minY, maxY, -1.f * maxZ, -1.f * minZ); // set projection
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
        lightMVP.projection = math::perspective(openingAngle * 2, 1.f, mNearFar.x, mNearFar.y);
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

    // Same for all valid lights
    lightMVP.viewProjection = math::mul(lightMVP.projection, lightMVP.view);
    lightMVP.invViewProjection = math::inverse(lightMVP.viewProjection);
    lightMVP.invProjection = math::inverse(lightMVP.projection);
    lightMVP.invView = math::inverse(lightMVP.view);
}
