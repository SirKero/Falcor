from falcor import *

def render_graph_ReSTIRFG_NRD_DEBUG():
    g = RenderGraph('ReSTIRFG_NRD_DEBUG')
    g.create_pass('NRD', 'NRD', {'enabled': True, 'method': NRDMethod.RelaxDiffuseSpecular, 'outputSize': IOSize.Default, 'worldSpaceMotion': True, 'disocclusionThreshold': 2.0, 'maxIntensity': 1000.0, 'diffusePrepassBlurRadius': 16.0, 'specularPrepassBlurRadius': 16.0, 'diffuseMaxAccumulatedFrameNum': 31, 'specularMaxAccumulatedFrameNum': 31, 'diffuseMaxFastAccumulatedFrameNum': 2, 'specularMaxFastAccumulatedFrameNum': 2, 'diffusePhiLuminance': 2.0, 'specularPhiLuminance': 1.0, 'diffuseLobeAngleFraction': 0.800000011920929, 'specularLobeAngleFraction': 0.8999999761581421, 'roughnessFraction': 0.5, 'diffuseHistoryRejectionNormalThreshold': 0.0, 'specularVarianceBoost': 1.0, 'specularLobeAngleSlack': 10.0, 'disocclusionFixEdgeStoppingNormalPower': 8.0, 'disocclusionFixMaxRadius': 32.0, 'disocclusionFixNumFramesToFix': 4, 'historyClampingColorBoxSigmaScale': 2.0, 'spatialVarianceEstimationHistoryThreshold': 4, 'atrousIterationNum': 6, 'minLuminanceWeight': 0.0, 'depthThreshold': 0.019999999552965164, 'luminanceEdgeStoppingRelaxation': 0.5, 'normalEdgeStoppingRelaxation': 0.30000001192092896, 'roughnessEdgeStoppingRelaxation': 0.30000001192092896, 'enableAntiFirefly': False, 'enableReprojectionTestSkippingWithoutMotion': False, 'enableSpecularVirtualHistoryClamping': False, 'enableRoughnessEdgeStopping': True, 'enableMaterialTestForDiffuse': False, 'enableMaterialTestForSpecular': False})
    g.create_pass('GBufferRT', 'GBufferRT', {'outputSize': IOSize.Default, 'samplePattern': SamplePattern.Center, 'sampleCount': 16, 'useAlphaTest': True, 'adjustShadingNormals': True, 'forceCullMode': False, 'cull': CullMode.CullBack, 'texLOD': TexLODMode.Mip0, 'useTraceRayInline': False, 'useDOF': True})
    g.create_pass('ReSTIR_FG', 'ReSTIR_FG', {})
    g.create_pass('ToneMapper', 'ToneMapper', {'outputSize': IOSize.Default, 'useSceneMetadata': True, 'exposureCompensation': 1.2999999523162842, 'autoExposure': False, 'filmSpeed': 100.0, 'whiteBalance': False, 'whitePoint': 6500.0, 'operator': ToneMapOp.Aces, 'clamp': True, 'whiteMaxLuminance': 1.0, 'whiteScale': 11.199999809265137, 'fNumber': 1.0, 'shutter': 1.0, 'exposureMode': ExposureMode.AperturePriority})
    g.create_pass('DLSSPass', 'DLSSPass', {'enabled': False, 'outputSize': IOSize.Default, 'profile': DLSSProfile.Balanced, 'motionVectorScale': DLSSMotionVectorScale.Relative, 'isHDR': True, 'sharpness': 0.0, 'exposure': 0.0})
    g.create_pass('AccumulatePass', 'AccumulatePass', {'enabled': False, 'outputSize': IOSize.Default, 'autoReset': True, 'precisionMode': AccumulatePrecision.Single, 'maxFrameCount': 0, 'overflowMode': AccumulateOverflowMode.Stop})
    g.create_pass('ModulateIllumination', 'ModulateIllumination', {'useEmission': True, 'useDiffuseReflectance': True, 'useDiffuseRadiance': True, 'useSpecularReflectance': True, 'useSpecularRadiance': True, 'useDeltaReflectionEmission': False, 'useDeltaReflectionReflectance': False, 'useDeltaReflectionRadiance': False, 'useDeltaTransmissionEmission': False, 'useDeltaTransmissionReflectance': False, 'useDeltaTransmissionRadiance': False, 'useResidualRadiance': False, 'outputSize': IOSize.Default})
    g.add_edge('ReSTIR_FG.specularRadiance', 'NRD.specularRadianceHitDist')
    g.add_edge('GBufferRT.vbuffer', 'ReSTIR_FG.vbuffer')
    g.add_edge('GBufferRT.normWRoughnessMaterialID', 'NRD.normWRoughnessMaterialID')
    g.add_edge('ReSTIR_FG.emission', 'ModulateIllumination.emission')
    g.add_edge('ReSTIR_FG.diffuseRadiance', 'NRD.diffuseRadianceHitDist')
    g.add_edge('GBufferRT.linearZ', 'NRD.viewZ')
    g.add_edge('NRD.filteredDiffuseRadianceHitDist', 'ModulateIllumination.diffuseRadiance')
    g.add_edge('NRD.filteredSpecularRadianceHitDist', 'ModulateIllumination.specularRadiance')
    g.add_edge('ReSTIR_FG.diffuseReflectance', 'ModulateIllumination.diffuseReflectance')
    g.add_edge('ReSTIR_FG.specularReflectance', 'ModulateIllumination.specularReflectance')
    g.add_edge('ModulateIllumination.output', 'DLSSPass.color')
    g.add_edge('GBufferRT.depth', 'DLSSPass.depth')
    g.add_edge('GBufferRT.mvec', 'DLSSPass.mvec')
    g.add_edge('DLSSPass.output', 'AccumulatePass.input')
    g.add_edge('AccumulatePass.output', 'ToneMapper.src')
    g.add_edge('GBufferRT.mvecW', 'NRD.mvec')
    g.add_edge('GBufferRT.mvec', 'ReSTIR_FG.mvec')
    g.mark_output('ToneMapper.dst')
    return g

ReSTIRFG_NRD_DEBUG = render_graph_ReSTIRFG_NRD_DEBUG()
try: m.addGraph(ReSTIRFG_NRD_DEBUG)
except NameError: None