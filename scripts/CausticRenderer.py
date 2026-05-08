from pathlib import WindowsPath, PosixPath
from falcor import *

def render_graph_DefaultRenderGraph():
    g = RenderGraph('DefaultRenderGraph')
    g.create_pass('CausticRenderer', 'CausticRenderer', {})
    g.create_pass('VBufferRT', 'VBufferRT', {'outputSize': 'Default', 'samplePattern': 'Halton', 'sampleCount': 32, 'useAlphaTest': True, 'adjustShadingNormals': True, 'forceCullMode': False, 'cull': 'Back', 'cullNonOpaque': False, 'useTraceRayInline': False, 'useDOF': True})
    g.create_pass('DLSSPass', 'DLSSPass', {'enabled': True, 'outputSize': 'Default', 'profile': 'DLAA', 'preset': 'Default(?)', 'motionVectorScale': 'Relative', 'isHDR': True, 'useJitteredMV': False, 'sharpness': 0.0, 'exposure': 0.0})
    g.create_pass('ToneMapper', 'ToneMapper', {'outputSize': 'Default', 'useSceneMetadata': True, 'exposureCompensation': 0.0, 'autoExposure': False, 'filmSpeed': 100.0, 'whiteBalance': False, 'whitePoint': 6500.0, 'operator': 'Aces', 'clamp': True, 'whiteMaxLuminance': 1.0, 'whiteScale': 11.199999809265137, 'fNumber': 1.0, 'shutter': 1.0, 'exposureMode': 'AperturePriority'})
    g.create_pass('AccumulatePass', 'AccumulatePass', {'enabled': False, 'outputSize': 'Default', 'autoReset': True, 'precisionMode': 'Single', 'maxFrameCount': 0, 'overflowMode': 'Stop'})
    g.add_edge('VBufferRT.vbuffer', 'CausticRenderer.vbuffer')
    g.add_edge('VBufferRT.viewW', 'CausticRenderer.view')
    g.add_edge('VBufferRT.depth', 'DLSSPass.depth')
    g.add_edge('VBufferRT.mvec', 'DLSSPass.mvec')
    g.add_edge('DLSSPass.output', 'ToneMapper.src')
    g.add_edge('CausticRenderer.color', 'AccumulatePass.input')
    g.add_edge('AccumulatePass.output', 'DLSSPass.color')
    g.mark_output('ToneMapper.dst')
    return g

DefaultRenderGraph = render_graph_DefaultRenderGraph()
try: m.addGraph(DefaultRenderGraph)
except NameError: None
