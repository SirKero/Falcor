from pathlib import WindowsPath, PosixPath
from falcor import *

def render_graph_VarianceSoftShadows():
    g = RenderGraph('VarianceSoftShadows')
    g.create_pass('VBufferRT', 'VBufferRT', {'outputSize': 'Default', 'samplePattern': 'Center', 'sampleCount': 16, 'useAlphaTest': True, 'adjustShadingNormals': True, 'forceCullMode': False, 'cull': 'Back', 'cullNonOpaque': False, 'useTraceRayInline': False, 'useDOF': True})
    g.create_pass('VarianceSoftShadows', 'VarianceSoftShadows', {})
    g.create_pass('DLSSPass', 'DLSSPass', {'enabled': True, 'outputSize': 'Default', 'profile': 'DLAA', 'preset': 'Default(CNN)', 'motionVectorScale': 'Relative', 'isHDR': True, 'useJitteredMV': False, 'sharpness': 0.0, 'exposure': 0.0})
    g.create_pass('ToneMapper', 'ToneMapper', {'outputSize': 'Default', 'useSceneMetadata': True, 'exposureCompensation': 0.0, 'autoExposure': False, 'filmSpeed': 100.0, 'whiteBalance': False, 'whitePoint': 6500.0, 'operator': 'Aces', 'clamp': True, 'whiteMaxLuminance': 1.0, 'whiteScale': 11.199999809265137, 'fNumber': 1.0, 'shutter': 1.0, 'exposureMode': 'AperturePriority'})
    g.add_edge('VBufferRT.vbuffer', 'VarianceSoftShadows.VBuffer')
    g.add_edge('VBufferRT.viewW', 'VarianceSoftShadows.ViewW')
    g.add_edge('VarianceSoftShadows.color', 'DLSSPass.color')
    g.add_edge('VBufferRT.depth', 'DLSSPass.depth')
    g.add_edge('VBufferRT.mvec', 'DLSSPass.mvec')
    g.add_edge('DLSSPass.output', 'ToneMapper.src')
    g.mark_output('ToneMapper.dst')
    return g

VarianceSoftShadows = render_graph_VarianceSoftShadows()
try: m.addGraph(VarianceSoftShadows)
except NameError: None
