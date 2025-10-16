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
};
FALCOR_ENUM_INFO(PhotonRenderMode, {
    { PhotonRenderMode::PhotonMapping, "PhotonMapping" },
    { PhotonRenderMode::FinalGathering, "FinalGathering" },
    { PhotonRenderMode::ReSTIR_FG, "ReSTIR FG" }
});
FALCOR_ENUM_REGISTER(PhotonRenderMode);

enum class GuidingMode : uint
{
    Disabled = 0u,
    Uniform = 1u,
    Emission = 2u,
    ReSTIR = 3u,        //Emission but applied to the surviving sample of the ReSTIR pass
    EmissionDiscretized = 4u,
    ReSTIRDiscretized = 5u, // DiscretizedEmission but applied to the surviving sample of the ReSTIR pass
};
FALCOR_ENUM_INFO(GuidingMode, {
    { GuidingMode::Disabled, "Disabled" },
    { GuidingMode::Uniform, "Uniform" },
    { GuidingMode::Emission, "Emission" },
    { GuidingMode::ReSTIR, "ReSTIR" },
    { GuidingMode::EmissionDiscretized, "EmissionDiscretized" },
    { GuidingMode::ReSTIRDiscretized, "ReSTIRDiscretized" },
});
FALCOR_ENUM_REGISTER(GuidingMode);

enum class GuidingLightIndexMode : uint
{
    Disabled = 0u,
    Uniform = 1u,
    DiscretizedEmission = 2u,
    ReSTIR = 3u,                    // DiscretizedEmission but applied to the surviving sample of the ReSTIR pass
    ReSTIRConf = 4u,                // ReSTIR but with confidence weights
};
FALCOR_ENUM_INFO(GuidingLightIndexMode, {
    { GuidingLightIndexMode::Disabled, "Disabled" },
    { GuidingLightIndexMode::Uniform, "Uniform" },
    { GuidingLightIndexMode::DiscretizedEmission, "DiscretizedEmission" },
    { GuidingLightIndexMode::ReSTIR, "ReSTIR" },
    { GuidingLightIndexMode::ReSTIRConf, "ReSTIRConf" },

});
FALCOR_ENUM_REGISTER(GuidingLightIndexMode);

#ifdef HOST_CODE
} //namespace PhotonGuiding
#endif
END_NAMESPACE_FALCOR
