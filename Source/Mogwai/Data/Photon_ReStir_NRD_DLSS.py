from falcor import *

def render_graph_Photon_ReSTIR_NRD_DLSS():
    g = RenderGraph('Photon_ReSTIR_NRD_DLSS')
    loadRenderPassLibrary('AccumulatePass.dll')
    loadRenderPassLibrary('CompositeReStirNRD.dll')
    loadRenderPassLibrary('DLSSPass.dll')
    loadRenderPassLibrary('VBufferPM.dll')
    loadRenderPassLibrary('ModulateIllumination.dll')
    loadRenderPassLibrary('NRDPass.dll')
    loadRenderPassLibrary('PhotonReSTIR.dll')
    loadRenderPassLibrary('RTXDIPass.dll')
    loadRenderPassLibrary('ToneMapper.dll')
    VBufferPM = createPass('VBufferPM', {'outputSize': IOSize.Default, 'samplePattern': 3, 'specRoughCutoff': 0.5, 'sampleCount': 32, 'useAlphaTest': True, 'adjustShadingNormals': True})
    g.addPass(VBufferPM, 'VBufferPM')
    RTXDIPass = createPass('RTXDIPass', {'options': RTXDIOptions(mode=RTXDIMode.SpatiotemporalResampling, presampledTileCount=128, presampledTileSize=1024, storeCompactLightInfo=True, localLightCandidateCount=24, infiniteLightCandidateCount=8, envLightCandidateCount=8, brdfCandidateCount=1, brdfCutoff=0.0, testCandidateVisibility=True, biasCorrection=RTXDIBiasCorrection.Basic, depthThreshold=0.10000000149011612, normalThreshold=0.5, samplingRadius=30.0, spatialSampleCount=1, spatialIterations=5, maxHistoryLength=20, boilingFilterStrength=0.0, rayEpsilon=0.0010000000474974513, useEmissiveTextures=False, enableVisibilityShortcut=False, enablePermutationSampling=False)})
    g.addPass(RTXDIPass, 'RTXDIPass')
    CompositeReStirNRD = createPass('CompositeReStirNRD')
    g.addPass(CompositeReStirNRD, 'CompositeReStirNRD')
    NRDDiffuseSpecular = createPass('NRD', {'enabled': True, 'method': NRDMethod.RelaxDiffuseSpecular, 'worldSpaceMotion': True, 'disocclusionThreshold': 2.0, 'maxIntensity': 250.0, 'diffusePrepassBlurRadius': 16.0, 'specularPrepassBlurRadius': 16.0, 'diffuseMaxAccumulatedFrameNum': 31, 'specularMaxAccumulatedFrameNum': 31, 'diffuseMaxFastAccumulatedFrameNum': 2, 'specularMaxFastAccumulatedFrameNum': 2, 'diffusePhiLuminance': 2.0, 'specularPhiLuminance': 1.0, 'diffuseLobeAngleFraction': 0.800000011920929, 'specularLobeAngleFraction': 0.8999999761581421, 'roughnessFraction': 0.5, 'diffuseHistoryRejectionNormalThreshold': 0.0, 'specularVarianceBoost': 1.0, 'specularLobeAngleSlack': 10.0, 'disocclusionFixEdgeStoppingNormalPower': 8.0, 'disocclusionFixMaxRadius': 32.0, 'disocclusionFixNumFramesToFix': 4, 'historyClampingColorBoxSigmaScale': 2.0, 'spatialVarianceEstimationHistoryThreshold': 4, 'atrousIterationNum': 6, 'minLuminanceWeight': 0.0, 'depthThreshold': 0.019999999552965164, 'luminanceEdgeStoppingRelaxation': 0.5, 'normalEdgeStoppingRelaxation': 0.30000001192092896, 'roughnessEdgeStoppingRelaxation': 0.30000001192092896, 'enableAntiFirefly': False, 'enableReprojectionTestSkippingWithoutMotion': False, 'enableSpecularVirtualHistoryClamping': False, 'enableRoughnessEdgeStopping': True, 'enableMaterialTestForDiffuse': False, 'enableMaterialTestForSpecular': False})
    g.addPass(NRDDiffuseSpecular, 'NRDDiffuseSpecular')
    NRDDeltaReflection = createPass('NRD', {'enabled': True, 'method': NRDMethod.RelaxDiffuse, 'worldSpaceMotion': False, 'disocclusionThreshold': 2.0, 'maxIntensity': 250.0, 'diffusePrepassBlurRadius': 16.0, 'diffuseMaxAccumulatedFrameNum': 31, 'diffuseMaxFastAccumulatedFrameNum': 2, 'diffusePhiLuminance': 2.0, 'diffuseLobeAngleFraction': 0.800000011920929, 'diffuseHistoryRejectionNormalThreshold': 0.0, 'disocclusionFixEdgeStoppingNormalPower': 8.0, 'disocclusionFixMaxRadius': 32.0, 'disocclusionFixNumFramesToFix': 4, 'historyClampingColorBoxSigmaScale': 2.0, 'spatialVarianceEstimationHistoryThreshold': 1, 'atrousIterationNum': 6, 'minLuminanceWeight': 0.0, 'depthThreshold': 0.019999999552965164, 'enableAntiFirefly': False, 'enableReprojectionTestSkippingWithoutMotion': True, 'enableMaterialTestForDiffuse': False})
    g.addPass(NRDDeltaReflection, 'NRDDeltaReflection')
    NRDDeltaTransmission = createPass('NRD', {'enabled': True, 'method': NRDMethod.RelaxDiffuse, 'worldSpaceMotion': False, 'disocclusionThreshold': 2.0, 'maxIntensity': 250.0, 'diffusePrepassBlurRadius': 16.0, 'diffuseMaxAccumulatedFrameNum': 31, 'diffuseMaxFastAccumulatedFrameNum': 2, 'diffusePhiLuminance': 2.0, 'diffuseLobeAngleFraction': 0.800000011920929, 'diffuseHistoryRejectionNormalThreshold': 0.0, 'disocclusionFixEdgeStoppingNormalPower': 8.0, 'disocclusionFixMaxRadius': 32.0, 'disocclusionFixNumFramesToFix': 4, 'historyClampingColorBoxSigmaScale': 2.0, 'spatialVarianceEstimationHistoryThreshold': 4, 'atrousIterationNum': 6, 'minLuminanceWeight': 0.0, 'depthThreshold': 0.019999999552965164, 'enableAntiFirefly': False, 'enableReprojectionTestSkippingWithoutMotion': True, 'enableMaterialTestForDiffuse': False})
    g.addPass(NRDDeltaTransmission, 'NRDDeltaTransmission')
    NRDReflectionMotionVectors = createPass('NRD', {'enabled': True, 'method': NRDMethod.SpecularReflectionMv, 'worldSpaceMotion': False, 'disocclusionThreshold': 2.0, 'maxIntensity': 1000.0})
    g.addPass(NRDReflectionMotionVectors, 'NRDReflectionMotionVectors')
    NRDTransmissionMotionVectors = createPass('NRD', {'enabled': True, 'method': NRDMethod.SpecularDeltaMv, 'worldSpaceMotion': False, 'disocclusionThreshold': 2.0, 'maxIntensity': 1000.0})
    g.addPass(NRDTransmissionMotionVectors, 'NRDTransmissionMotionVectors')
    ModulateIllumination = createPass('ModulateIllumination', {'useEmission': True, 'useDiffuseReflectance': True, 'useDiffuseRadiance': True, 'useSpecularReflectance': True, 'useSpecularRadiance': True, 'useDeltaReflectionEmission': True, 'useDeltaReflectionReflectance': True, 'useDeltaReflectionRadiance': True, 'useDeltaTransmissionEmission': True, 'useDeltaTransmissionReflectance': True, 'useDeltaTransmissionRadiance': True, 'useResidualRadiance': False})
    g.addPass(ModulateIllumination, 'ModulateIllumination')
    AccumulatePass = createPass('AccumulatePass', {'enabled': False, 'outputSize': IOSize.Default, 'autoReset': True, 'precisionMode': AccumulatePrecision.Single, 'subFrameCount': 0, 'maxAccumulatedFrames': 0})
    g.addPass(AccumulatePass, 'AccumulatePass')
    ToneMapper = createPass('ToneMapper', {'outputSize': IOSize.Default, 'useSceneMetadata': True, 'exposureCompensation': 0.0, 'autoExposure': False, 'filmSpeed': 100.0, 'whiteBalance': False, 'whitePoint': 6500.0, 'operator': ToneMapOp.Aces, 'clamp': True, 'whiteMaxLuminance': 1.0, 'whiteScale': 11.199999809265137, 'fNumber': 1.0, 'shutter': 1.0, 'exposureMode': ExposureMode.AperturePriority})
    g.addPass(ToneMapper, 'ToneMapper')
    DLSSPass = createPass('DLSSPass', {'enabled': True, 'outputSize': IOSize.Default, 'profile': DLSSProfile.Balanced, 'motionVectorScale': DLSSMotionVectorScale.Relative, 'isHDR': True, 'sharpness': 0.0, 'exposure': 0.0})
    g.addPass(DLSSPass, 'DLSSPass')
    PhotonReSTIR = createPass('PhotonReSTIR')
    g.addPass(PhotonReSTIR, 'PhotonReSTIR')
    g.addEdge('VBufferPM.vbuffer', 'RTXDIPass.vbuffer')
    g.addEdge('VBufferPM.mvec', 'RTXDIPass.mvec')
    g.addEdge('VBufferPM.viewW', 'RTXDIPass.viewDir')
    g.addEdge('VBufferPM.linearDepth', 'RTXDIPass.pathLength')
    g.addEdge('RTXDIPass.diffuseIllumination', 'CompositeReStirNRD.ReStirDiffuse')
    g.addEdge('RTXDIPass.specularIllumination', 'CompositeReStirNRD.ReStirSpecular')
    g.addEdge('VBufferPM.NRDMask', 'CompositeReStirNRD.NRDMask')
    g.addEdge('VBufferPM.throughput', 'CompositeReStirNRD.throughput')
    g.addEdge('CompositeReStirNRD.NRDDiffuseRadianceHitDistance', 'NRDDiffuseSpecular.diffuseRadianceHitDist')
    g.addEdge('CompositeReStirNRD.NRDSpecularRadianceHitDistance', 'NRDDiffuseSpecular.specularRadianceHitDist')
    g.addEdge('VBufferPM.FirstHitLinZ', 'NRDDiffuseSpecular.viewZ')
    g.addEdge('VBufferPM.normWRoughMat', 'NRDDiffuseSpecular.normWRoughnessMaterialID')
    g.addEdge('VBufferPM.mvec', 'NRDDiffuseSpecular.mvec')
    g.addEdge('NRDDiffuseSpecular.filteredDiffuseRadianceHitDist', 'ModulateIllumination.diffuseRadiance')
    g.addEdge('NRDDiffuseSpecular.filteredSpecularRadianceHitDist', 'ModulateIllumination.specularRadiance')
    g.addEdge('VBufferPM.NRDDiffuseReflectance', 'ModulateIllumination.diffuseReflectance')
    g.addEdge('VBufferPM.emissive', 'ModulateIllumination.emission')
    g.addEdge('VBufferPM.NRDSpecularReflectance', 'ModulateIllumination.specularReflectance')
    g.addEdge('VBufferPM.FirstHitLinZ', 'NRDReflectionMotionVectors.viewZ')
    g.addEdge('VBufferPM.normWRoughMat', 'NRDReflectionMotionVectors.normWRoughnessMaterialID')
    g.addEdge('VBufferPM.mvec', 'NRDReflectionMotionVectors.mvec')
    g.addEdge('VBufferPM.NRDDeltaReflectionHitDistance', 'NRDReflectionMotionVectors.specularHitDist')
    g.addEdge('NRDReflectionMotionVectors.reflectionMvec', 'NRDDeltaReflection.mvec')
    g.addEdge('VBufferPM.NRDDeltaReflectionNormWRoughMat', 'NRDDeltaReflection.normWRoughnessMaterialID')
    g.addEdge('VBufferPM.linearDepth', 'NRDDeltaReflection.viewZ')
    g.addEdge('CompositeReStirNRD.NRDDeltaReflectionRadianceHitDistance', 'NRDDeltaReflection.diffuseRadianceHitDist')
    g.addEdge('NRDDeltaReflection.filteredDiffuseRadianceHitDist', 'ModulateIllumination.deltaReflectionRadiance')
    g.addEdge('VBufferPM.NRDFirstPosW', 'NRDTransmissionMotionVectors.deltaPrimaryPosW')
    g.addEdge('VBufferPM.NRDDeltaTransmissionPosW', 'NRDTransmissionMotionVectors.deltaSecondaryPosW')
    g.addEdge('VBufferPM.mvec', 'NRDTransmissionMotionVectors.mvec')
    g.addEdge('NRDTransmissionMotionVectors.deltaMvec', 'NRDDeltaTransmission.mvec')
    g.addEdge('VBufferPM.NRDDeltaTransmissionNormWRoughMat', 'NRDDeltaTransmission.normWRoughnessMaterialID')
    g.addEdge('VBufferPM.linearDepth', 'NRDDeltaTransmission.viewZ')
    g.addEdge('CompositeReStirNRD.NRDDeltaTransmissionRadianceHitDistance', 'NRDDeltaTransmission.diffuseRadianceHitDist')
    g.addEdge('NRDDeltaTransmission.filteredDiffuseRadianceHitDist', 'ModulateIllumination.deltaTransmissionRadiance')
    g.addEdge('AccumulatePass.output', 'ToneMapper.src')
    g.addEdge('ModulateIllumination.output', 'DLSSPass.color')
    g.addEdge('VBufferPM.depth', 'DLSSPass.depth')
    g.addEdge('VBufferPM.mvec', 'DLSSPass.mvec')
    g.addEdge('VBufferPM.NRDDeltaReflectionReflectance', 'CompositeReStirNRD.DeltaReflectionReflectance')
    g.addEdge('VBufferPM.NRDDeltaTransmissionReflectance', 'CompositeReStirNRD.TransmissionReflectance')
    g.addEdge('VBufferPM.NRDDeltaTransmissionEmission', 'CompositeReStirNRD.TransmissionEmission')
    g.addEdge('VBufferPM.NRDDeltaReflectionEmission', 'CompositeReStirNRD.DeltaReflectionEmission')
    g.addEdge('VBufferPM.NRDDeltaReflectionEmission', 'ModulateIllumination.deltaReflectionEmission')
    g.addEdge('VBufferPM.NRDDeltaTransmissionEmission', 'ModulateIllumination.deltaTransmissionEmission')
    g.addEdge('VBufferPM.vbuffer', 'PhotonReSTIR.VBuffer')
    g.addEdge('VBufferPM.mvec', 'PhotonReSTIR.MVec')
    g.addEdge('VBufferPM.viewW', 'PhotonReSTIR.View')
    g.addEdge('VBufferPM.linearDepth', 'PhotonReSTIR.RayDistance')
    g.addEdge('PhotonReSTIR.diffuseIllumination', 'CompositeReStirNRD.PhotonReStirDiffuse')
    g.addEdge('PhotonReSTIR.specularIllumination', 'CompositeReStirNRD.PhotonReStirSpecular')
    g.addEdge('DLSSPass.output', 'AccumulatePass.input')
    g.markOutput('ToneMapper.dst')
    g.markOutput('AccumulatePass.output')
    return g

Photon_ReSTIR_NRD_DLSS = render_graph_Photon_ReSTIR_NRD_DLSS()
try: m.addGraph(Photon_ReSTIR_NRD_DLSS)
except NameError: None