from pathlib import WindowsPath, PosixPath
from falcor import *

def render_graph_PhotonGuiding():
    g = RenderGraph('PhotonGuiding')
    g.create_pass('ToneMapper', 'ToneMapper', {'outputSize': 'Default', 'useSceneMetadata': True, 'exposureCompensation': 0.0, 'autoExposure': False, 'filmSpeed': 100.0, 'whiteBalance': False, 'whitePoint': 6500.0, 'operator': 'Aces', 'clamp': True, 'whiteMaxLuminance': 1.0, 'whiteScale': 11.199999809265137, 'fNumber': 1.0, 'shutter': 1.0, 'exposureMode': 'AperturePriority'})
    g.create_pass('PhotonGuiding', 'PhotonGuiding', {})
    g.create_pass('VBufferRT', 'VBufferRT', {'outputSize': 'Default', 'samplePattern': 'Center', 'sampleCount': 16, 'useAlphaTest': True, 'adjustShadingNormals': True, 'forceCullMode': False, 'cull': 'Back', 'cullNonOpaque': False, 'useTraceRayInline': False, 'useDOF': True})
    g.create_pass('VideoRecorder', 'VideoRecorder', {})
    g.create_pass('DLSSPass', 'DLSSPass', {'enabled': True, 'outputSize': 'Default', 'profile': 'DLAA', 'preset': 'Default(?)', 'motionVectorScale': 'Relative', 'isHDR': True, 'useJitteredMV': False, 'sharpness': 0.0, 'exposure': 0.0})
    g.add_edge('VBufferRT.vbuffer', 'PhotonGuiding.VBuffer')
    g.add_edge('VBufferRT.viewW', 'PhotonGuiding.View')
    g.add_edge('VBufferRT.mvec', 'PhotonGuiding.MotionVector')
    g.add_edge('VideoRecorder', 'VBufferRT')
    g.add_edge('PhotonGuiding.ColorOut', 'DLSSPass.color')
    g.add_edge('DLSSPass.output', 'ToneMapper.src')
    g.add_edge('VBufferRT.depth', 'DLSSPass.depth')
    g.add_edge('VBufferRT.mvec', 'DLSSPass.mvec')
    g.mark_output('ToneMapper.dst')
    return g

PhotonGuiding = render_graph_PhotonGuiding()
try: m.addGraph(PhotonGuiding)
except NameError: None
