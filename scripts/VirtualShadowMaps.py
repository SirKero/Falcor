from pathlib import WindowsPath, PosixPath
from falcor import *

def render_graph_VirtualShadowMapRenderer():
    g = RenderGraph('VirtualShadowMapRenderer')
    g.create_pass('VirtualShadowMapRenderer', 'VirtualShadowMapRenderer', {})
    g.create_pass('VBufferRT', 'VBufferRT', {'outputSize': 'Default', 'samplePattern': 'Halton', 'sampleCount': 16, 'useAlphaTest': True, 'adjustShadingNormals': True, 'forceCullMode': False, 'cull': 'Back', 'cullNonOpaque': False, 'useTraceRayInline': False, 'useDOF': True})
    g.create_pass('ToneMapper', 'ToneMapper', {'outputSize': 'Default', 'useSceneMetadata': True, 'exposureCompensation': 0.0, 'autoExposure': False, 'filmSpeed': 100.0, 'whiteBalance': False, 'whitePoint': 6500.0, 'operator': 'Aces', 'clamp': True, 'whiteMaxLuminance': 1.0, 'whiteScale': 11.199999809265137, 'fNumber': 1.0, 'shutter': 1.0, 'exposureMode': 'AperturePriority'})
    g.create_pass('DLSSPass', 'DLSSPass', {'enabled': True, 'outputSize': 'Default', 'profile': 'DLAA', 'preset': 'Default(CNN)', 'motionVectorScale': 'Relative', 'isHDR': False, 'useJitteredMV': False, 'sharpness': 0.0, 'exposure': 0.0})
    g.add_edge('VirtualShadowMapRenderer.ColorOut', 'ToneMapper.src')
    g.add_edge('VBufferRT.vbuffer', 'VirtualShadowMapRenderer.VBuffer')
    g.add_edge('VBufferRT.viewW', 'VirtualShadowMapRenderer.ViewW')
    g.add_edge('ToneMapper.dst', 'DLSSPass.color')
    g.add_edge('VBufferRT.depth', 'DLSSPass.depth')
    g.add_edge('VBufferRT.mvec', 'DLSSPass.mvec')
    g.mark_output('DLSSPass.output')
    return g

VirtualShadowMapRenderer = render_graph_VirtualShadowMapRenderer()
try: m.addGraph(VirtualShadowMapRenderer)
except NameError: None
