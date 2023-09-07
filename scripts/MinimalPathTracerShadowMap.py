from pathlib import WindowsPath, PosixPath
from falcor import *

def render_graph_MinimalPathTracerShadowMap():
    g = RenderGraph('MinimalPathTracerShadowMap')
    g.create_pass('MinimalPathTracerShadowMap', 'MinimalPathTracerShadowMap', {'maxBounces': 3, 'computeDirect': True, 'useImportanceSampling': True})
    g.create_pass('VBufferRT', 'VBufferRT', {'outputSize': 'Default', 'samplePattern': 'Center', 'sampleCount': 16, 'useAlphaTest': True, 'adjustShadingNormals': True, 'forceCullMode': False, 'cull': 'Back', 'useTraceRayInline': False, 'useDOF': True})
    g.create_pass('ToneMapper', 'ToneMapper', {'outputSize': 'Default', 'useSceneMetadata': True, 'exposureCompensation': 0.0, 'autoExposure': False, 'filmSpeed': 100.0, 'whiteBalance': False, 'whitePoint': 6500.0, 'operator': 'Aces', 'clamp': True, 'whiteMaxLuminance': 1.0, 'whiteScale': 11.199999809265137, 'fNumber': 1.0, 'shutter': 1.0, 'exposureMode': 'AperturePriority'})
    g.create_pass('AccumulatePass', 'AccumulatePass', {'enabled': True, 'outputSize': 'Default', 'autoReset': True, 'precisionMode': 'Single', 'maxFrameCount': 0, 'overflowMode': 'Stop'})
    g.add_edge('VBufferRT.vbuffer', 'MinimalPathTracerShadowMap.vbuffer')
    g.add_edge('VBufferRT.viewW', 'MinimalPathTracerShadowMap.viewW')
    g.add_edge('MinimalPathTracerShadowMap.color', 'AccumulatePass.input')
    g.add_edge('AccumulatePass.output', 'ToneMapper.src')
    g.mark_output('ToneMapper.dst')
    g.mark_output('AccumulatePass.output')
    return g

MinimalPathTracerShadowMap = render_graph_MinimalPathTracerShadowMap()
try: m.addGraph(MinimalPathTracerShadowMap)
except NameError: None