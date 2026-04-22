
struct PhotonGuiding
{
    static const uint kMappingInvalidIndex = 0xFFFF; //TODO move? 
    static const uint kDiscretizedContributionFactor = PHOTON_GUIDING_DISCRETIZED_CONTRIBUTION_FACTOR;
    static const uint kDiscretizedContributionMax = PHOTON_GUIDING_DISCRETIZED_CONTRIBUTION_MAX;
    static const bool kEnableMapping = PHOTON_GUIDING_USE_MAPPED_GM;

    uint gResolutionLightGM;        // Resolution for the light Contribution/Guiding Map
    uint gMapDirResourcesPerRow;    // Number of directional resources per row if mapping is used
    uint gResolutionGM;             // Resolution of a single directional guiding resource

    RWTexture2D<uint> gContributionLight;           //Contribution for each light. Can be nullptr
    RWTexture2D<uint> gContributionDirection;       // Contribution for all directions
    Texture2D<uint> gMapLightToDirection;           //Mapping from light index -> directional resource, or invalid. Can be nullptr
};

extension PhotonGuiding
{
    /*  Records guiding contribution of a photon
        \param[in] lightIndex: Index of the light the photon was dispatched from
        \param[in] guidingPixel: Pixel of the directional GM the sample was generated from
        \param[in] contribution: Contribution of the sample
    */
    void addGuidingContribution(uint lightIndex, uint2 guidingPixel, float contribution)
    {
        //Early out
        if (contribution <= 0)
            return;

        // Discretize the contribution, as an atomic add is used to count the contrition at each cell
        uint discretizedContribution = uint(round(kDiscretizedContributionFactor * contribution));
        discretizedContribution = clamp(discretizedContribution, 1, kDiscretizedContributionMax); //Clamp

        //If the mapping is enabled, most lights will not have a directional Guiding Map,
        //therefore the contribution needs to be recorded per light. Else, light contribution can be inferred
        //from the directional contribution.
        //Additionally, if the mapping is valid, the guiding pixel needs to be offset by the mapping
        //index, as the input guiding pixel is stored in local pixel coordinates when mapping is enabled.
        if (kEnableMapping)
        {
            //Get cell pixel and add contribution
            uint2 lightCell = uint2(lightIndex % gResolutionLightGM, lightIndex / gResolutionLightGM);
            InterlockedAdd(gContributionLight[lightCell], discretizedContribution);

            // Check if mapping is valid and return if it is invalid
            uint mapIdx = gMapLightToDirection[lightCell];
            if (mapIdx >= kMappingInvalidIndex)
                return;

            // Offset guiding pixel with the mapping index
            guidingPixel += uint2(mapIdx % gMapDirResourcesPerRow, mapIdx / gMapDirResourcesPerRow) * gResolutionGM;
        }

        // Record the directional contribution
        InterlockedAdd(gContributionDirection[guidingPixel], discretizedContribution);
    }
}

// Global Bound Block
ParameterBlock<PhotonGuiding> gPhotonGuiding;
