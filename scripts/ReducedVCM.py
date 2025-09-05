from pathlib import WindowsPath, PosixPath
from falcor import *

def render_graph_ReducedVCM():
    g = RenderGraph('ReducedVCM')
    g.create_pass('AccumulatePass', 'AccumulatePass', {'enabled': True, 'outputSize': 'Default', 'autoReset': True, 'precisionMode': 'Double', 'maxFrameCount': 0, 'overflowMode': 'Stop'})
    g.create_pass('ToneMapper', 'ToneMapper', {'outputSize': 'Default', 'useSceneMetadata': True, 'exposureCompensation': 0.0, 'autoExposure': False, 'filmSpeed': 100.0, 'whiteBalance': False, 'whitePoint': 6500.0, 'operator': 'Aces', 'clamp': True, 'whiteMaxLuminance': 1.0, 'whiteScale': 11.199999809265137, 'fNumber': 1.0, 'shutter': 1.0, 'exposureMode': 'AperturePriority'})
    g.create_pass('ReducedVCM', 'ReducedVCM', {})
    g.create_pass('VBufferRT', 'VBufferRT', {'outputSize': 'Default', 'samplePattern': 'Center', 'sampleCount': 16, 'useAlphaTest': True, 'adjustShadingNormals': True, 'forceCullMode': False, 'cull': 'Back', 'cullNonOpaque': False, 'useTraceRayInline': False, 'useDOF': True})
    g.add_edge('AccumulatePass.output', 'ToneMapper.src')
    g.add_edge('ReducedVCM.ColorOut', 'AccumulatePass.input')
    g.add_edge('VBufferRT.vbuffer', 'ReducedVCM.VBuffer')
    g.add_edge('VBufferRT.viewW', 'ReducedVCM.View')
    g.mark_output('ToneMapper.dst')
    g.mark_output('AccumulatePass.output')
    return g

ReducedVCM = render_graph_ReducedVCM()
try: m.addGraph(ReducedVCM)
except NameError: None
