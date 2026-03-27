from pathlib import WindowsPath, PosixPath
from falcor import *

def render_graph_DefaultRenderGraph():
    g = RenderGraph('DefaultRenderGraph')
    g.create_pass('GBufferRT', 'GBufferRT', {'outputSize': 'Default', 'samplePattern': 'Center', 'sampleCount': 16, 'useAlphaTest': True, 'adjustShadingNormals': True, 'forceCullMode': False, 'cull': 'Back', 'cullNonOpaque': False, 'texLOD': 'Mip0', 'useTraceRayInline': False, 'useDOF': True})
    g.create_pass('ToneMapper', 'ToneMapper', {'outputSize': 'Default', 'useSceneMetadata': True, 'exposureCompensation': 0.0, 'autoExposure': False, 'filmSpeed': 100.0, 'whiteBalance': False, 'whitePoint': 6500.0, 'operator': 'Aces', 'clamp': True, 'whiteMaxLuminance': 1.0, 'whiteScale': 11.199999809265137, 'fNumber': 1.0, 'shutter': 1.0, 'exposureMode': 'AperturePriority'})
    g.create_pass('DLSSPass', 'DLSSPass', {'enabled': True, 'outputSize': 'Default', 'profile': 'DLAA', 'preset': 'Default(?)', 'motionVectorScale': 'Relative', 'isHDR': True, 'useJitteredMV': False, 'sharpness': 0.0, 'exposure': 0.0})
    g.create_pass('PhotonGuiding', 'PhotonGuiding', {})
    g.create_pass('ModulateIllumination', 'ModulateIllumination', {'useEmission': True, 'useDiffuseReflectance': True, 'useDiffuseRadiance': True, 'useSpecularReflectance': True, 'useSpecularRadiance': True, 'useDeltaReflectionEmission': True, 'useDeltaReflectionReflectance': True, 'useDeltaReflectionRadiance': True, 'useDeltaTransmissionEmission': True, 'useDeltaTransmissionReflectance': True, 'useDeltaTransmissionRadiance': True, 'useResidualRadiance': True, 'outputSize': 'Default', 'useDebug': True, 'inputInYCoCg': False})
    g.create_pass('NRD_Normal', 'NRD_Normal', {'enabled': True, 'method': 'RelaxDiffuseSpecular', 'outputSize': 'Default', 'worldSpaceMotion': False, 'disocclusionThreshold': 2.0, 'maxIntensity': 250.0, 'RelaxAntilagAccelerationAmount': 0.30000001192092896, 'RelaxAntilagSpatialSigmaScale': 4.0, 'RelaxAntilagTemporalSigmaScale': 0.20000000298023224, 'RelaxAntilagResetAmount': 0.699999988079071, 'RelaxDiffusePrepassBlurRadius': 30.0, 'RelaxSpecularPrepassBlurRadius': 40.0, 'RelaxDiffuseMaxAccumulatedFrameNum': 50, 'RelaxSpecularMaxAccumulatedFrameNum': 40, 'RelaxEnableAntiFirefly': True, 'SigmaStabilization': 1.0})
    g.add_edge('PhotonGuiding.NRDDiffuseReflectance', 'ModulateIllumination.diffuseReflectance')
    g.add_edge('PhotonGuiding.NRDSpecularReflectance', 'ModulateIllumination.specularReflectance')
    g.add_edge('PhotonGuiding.ColorOut', 'ModulateIllumination.emission')
    g.add_edge('PhotonGuiding.NRDDiffuseRadiance', 'NRD_Normal.diffuseRadianceHitDist')
    g.add_edge('PhotonGuiding.NRDSpecularRadiance', 'NRD_Normal.specularRadianceHitDist')
    g.add_edge('GBufferRT.mvec', 'PhotonGuiding.MotionVector')
    g.add_edge('GBufferRT.viewW', 'PhotonGuiding.View')
    g.add_edge('GBufferRT.vbuffer', 'PhotonGuiding.VBuffer')
    g.add_edge('GBufferRT.linearZ', 'NRD_Normal.viewZ')
    g.add_edge('GBufferRT.normWRoughnessMaterialID', 'NRD_Normal.normWRoughnessMaterialID')
    g.add_edge('GBufferRT.mvec', 'NRD_Normal.mvec')
    g.add_edge('NRD_Normal.filteredDiffuseRadianceHitDist', 'ModulateIllumination.diffuseRadiance')
    g.add_edge('NRD_Normal.filteredSpecularRadianceHitDist', 'ModulateIllumination.specularRadiance')
    g.add_edge('NRD_Normal.outValidation', 'ModulateIllumination.debugLayer')
    g.add_edge('ModulateIllumination.output', 'DLSSPass.color')
    g.add_edge('GBufferRT.depth', 'DLSSPass.depth')
    g.add_edge('GBufferRT.mvec', 'DLSSPass.mvec')
    g.add_edge('DLSSPass.output', 'ToneMapper.src')
    g.mark_output('ToneMapper.dst')
    return g

DefaultRenderGraph = render_graph_DefaultRenderGraph()
try: m.addGraph(DefaultRenderGraph)
except NameError: None
