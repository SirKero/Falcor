#pragma once
#include "Utils/HostDeviceShared.slangh"

BEGIN_NAMESPACE_FALCOR
#ifdef HOST_CODE
namespace PhotonGuidingSharedEnums {
#endif

enum class PhotonRenderMode : uint32_t
{
    PhotonMapping = 0,
    FinalGathering = 1,
    ReSTIR_FG = 2,
    ReSTIR_PathPhoton = 3,
};
FALCOR_ENUM_INFO(PhotonRenderMode, {
    { PhotonRenderMode::PhotonMapping, "PhotonMapping" },
    { PhotonRenderMode::FinalGathering, "FinalGathering" },
    { PhotonRenderMode::ReSTIR_FG, "ReSTIR FG" },
    { PhotonRenderMode::ReSTIR_PathPhoton, "ReSTIR PathPhoton" },
});
FALCOR_ENUM_REGISTER(PhotonRenderMode);

enum class GuidingMode : uint
{
    Disabled = 0u,
    Uniform = 1u,
    Emission = 2u,
    EmissionDiscretized = 3u,
    HigherIsReSTIR = 4u, //To check if it is a ReSTIR mode
    ReSTIR = 5u, // Emission but applied to the surviving sample of the ReSTIR pass
    ReSTIRDiscretized = 6u, // DiscretizedEmission but applied to the surviving sample of the ReSTIR pass
    ReSTIRConfidence = 7u,  // Same as above but multiplied by confidence
    ReSTIRReverseConfidence = 8u, // Same as above but multiplied by (reverse) confidence (c_cap - c)
};
FALCOR_ENUM_INFO(GuidingMode, {
    { GuidingMode::Disabled, "Disabled" },
    { GuidingMode::Uniform, "Uniform" },
    { GuidingMode::Emission, "Emission" },
    { GuidingMode::EmissionDiscretized, "EmissionDiscretized" },
    { GuidingMode::ReSTIR, "ReSTIR" },
    { GuidingMode::ReSTIRDiscretized, "ReSTIRDiscretized" },
    { GuidingMode::ReSTIRConfidence, "ReSTIRConfidence" },
    { GuidingMode::ReSTIRReverseConfidence, "ReSTIRReverseConfidence" },
});
FALCOR_ENUM_REGISTER(GuidingMode);

enum class GuidingHistogramAccumulateMode : uint
{
    ResetOnMove = 0u,
    AverageFrames = 1u,
    AveragePercentage = 2u,
    UseLastFrame = 3u,
};
FALCOR_ENUM_INFO(GuidingHistogramAccumulateMode, {
    { GuidingHistogramAccumulateMode::ResetOnMove, "ResetOnMove" },
    { GuidingHistogramAccumulateMode::AverageFrames, "AverageFrames" },
    { GuidingHistogramAccumulateMode::AveragePercentage, "AveragePercentage" },
    { GuidingHistogramAccumulateMode::UseLastFrame, "UseLastFrame" },

});
FALCOR_ENUM_REGISTER(GuidingHistogramAccumulateMode);

#ifdef HOST_CODE
} //namespace PhotonGuiding
#endif
END_NAMESPACE_FALCOR
