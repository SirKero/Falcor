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
};
FALCOR_ENUM_INFO(GuidingMode, {
    { GuidingMode::Disabled, "Disabled" },
    { GuidingMode::Uniform, "Uniform" },
    { GuidingMode::Emission, "Emission" },
});
FALCOR_ENUM_REGISTER(GuidingMode);

#ifdef HOST_CODE
} //namespace PhotonGuiding
#endif
END_NAMESPACE_FALCOR
