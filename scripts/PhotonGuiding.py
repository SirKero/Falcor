from pathlib import WindowsPath, PosixPath
from falcor import *

def render_graph_PhotonGuiding():
    g = RenderGraph('PhotonGuiding')
    g.create_pass('AccumulatePass', 'AccumulatePass', {'enabled': True, 'outputSize': 'Default', 'autoReset': True, 'precisionMode': 'Double', 'maxFrameCount': 0, 'overflowMode': 'Stop'})
    g.create_pass('ToneMapper', 'ToneMapper', {'outputSize': 'Default', 'useSceneMetadata': True, 'exposureCompensation': 0.0, 'autoExposure': False, 'filmSpeed': 100.0, 'whiteBalance': False, 'whitePoint': 6500.0, 'operator': 'Aces', 'clamp': True, 'whiteMaxLuminance': 1.0, 'whiteScale': 11.199999809265137, 'fNumber': 1.0, 'shutter': 1.0, 'exposureMode': 'AperturePriority'})
    g.create_pass('PhotonGuiding', 'PhotonGuiding', {})
    g.create_pass('VBufferRT', 'VBufferRT', {'outputSize': 'Default', 'samplePattern': 'Center', 'sampleCount': 16, 'useAlphaTest': True, 'adjustShadingNormals': True, 'forceCullMode': False, 'cull': 'Back', 'cullNonOpaque': False, 'useTraceRayInline': False, 'useDOF': True})
    g.add_edge('AccumulatePass.output', 'ToneMapper.src')
    g.add_edge('PhotonGuiding.ColorOut', 'AccumulatePass.input')
    g.add_edge('VBufferRT.vbuffer', 'PhotonGuiding.VBuffer')
    g.add_edge('VBufferRT.viewW', 'PhotonGuiding.View')
    g.add_edge('VBufferRT.mvec', 'PhotonGuiding.MotionVector')
    g.mark_output('ToneMapper.dst')
    g.mark_output('AccumulatePass.output')
    return g

PhotonGuiding = render_graph_PhotonGuiding()
try: m.addGraph(PhotonGuiding)
except NameError: None
