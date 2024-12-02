from pathlib import WindowsPath, PosixPath
from falcor import *

def render_graph_TransparencyRenderDLSS():
    g = RenderGraph('TransparencyRenderDLSS')
    g.create_pass('VBufferRT', 'VBufferRT', {'outputSize': 'Default', 'samplePattern': 'Center', 'sampleCount': 16, 'useAlphaTest': True, 'adjustShadingNormals': True, 'forceCullMode': False, 'cull': 'Back', 'cullNonOpaque': True, 'useTraceRayInline': False, 'useDOF': True})
    g.create_pass('TransparencyRenderer', 'TransparencyRenderer', {})
    g.create_pass('ToneMapperAccum', 'ToneMapper', {'outputSize': 'Default', 'useSceneMetadata': True, 'exposureCompensation': 0.0, 'autoExposure': False, 'filmSpeed': 100.0, 'whiteBalance': False, 'whitePoint': 6500.0, 'operator': 'Aces', 'clamp': True, 'whiteMaxLuminance': 1.0, 'whiteScale': 11.199999809265137, 'fNumber': 1.0, 'shutter': 1.0, 'exposureMode': 'AperturePriority'})
    g.create_pass('AccumulatePass', 'AccumulatePass', {'enabled': False, 'outputSize': 'Default', 'autoReset': True, 'precisionMode': 'Single', 'maxFrameCount': 0, 'overflowMode': 'Stop'})
    g.create_pass('DLSSPass', 'DLSSPass', {'enabled': True, 'outputSize': 'Default', 'profile': 'Balanced', 'motionVectorScale': 'Relative', 'isHDR': True, 'useJitteredMV': False, 'sharpness': 0.0, 'exposure': 0.0})
    g.create_pass('ToneMapperDLSS', 'ToneMapper', {'outputSize': 'Default', 'useSceneMetadata': True, 'exposureCompensation': 0.0, 'autoExposure': False, 'filmSpeed': 100.0, 'whiteBalance': False, 'whitePoint': 6500.0, 'operator': 'Aces', 'clamp': True, 'whiteMaxLuminance': 1.0, 'whiteScale': 11.199999809265137, 'fNumber': 1.0, 'shutter': 1.0, 'exposureMode': 'AperturePriority'})
    g.add_edge('TransparencyRenderer.outDepth', 'DLSSPass.depth')
    g.add_edge('VBufferRT.vbuffer', 'TransparencyRenderer.vbuffer')
    g.add_edge('TransparencyRenderer.outMotion', 'DLSSPass.mvec')
    g.add_edge('VBufferRT.viewW', 'TransparencyRenderer.viewW')
    g.add_edge('TransparencyRenderer.outColor', 'AccumulatePass.input')
    g.add_edge('AccumulatePass.output', 'ToneMapperAccum.src')
    g.add_edge('TransparencyRenderer.outColor', 'DLSSPass.color')
    g.add_edge('DLSSPass.output', 'ToneMapperDLSS.src')
    g.add_edge('VBufferRT.mvec', 'TransparencyRenderer.inMotion')
    g.add_edge('VBufferRT.depth', 'TransparencyRenderer.inDepth')
    g.mark_output('ToneMapperDLSS.dst')
    g.mark_output('ToneMapperAccum.dst')
    return g

TransparencyRenderDLSS = render_graph_TransparencyRenderDLSS()
try: m.addGraph(TransparencyRenderDLSS)
except NameError: None
