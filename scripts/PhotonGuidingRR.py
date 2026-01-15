from pathlib import WindowsPath, PosixPath
from falcor import *

def render_graph_PhotonGuiding():
    g = RenderGraph('PhotonGuiding')
    g.create_pass('ToneMapper', 'ToneMapper', {'outputSize': 'Default', 'useSceneMetadata': True, 'exposureCompensation': 0.0, 'autoExposure': False, 'filmSpeed': 100.0, 'whiteBalance': False, 'whitePoint': 6500.0, 'operator': 'Aces', 'clamp': True, 'whiteMaxLuminance': 1.0, 'whiteScale': 11.199999809265137, 'fNumber': 1.0, 'shutter': 1.0, 'exposureMode': 'AperturePriority'})
    g.create_pass('PhotonGuiding', 'PhotonGuiding', {})
    g.create_pass('VBufferRT', 'VBufferRT', {'outputSize': 'Default', 'samplePattern': 'Center', 'sampleCount': 16, 'useAlphaTest': True, 'adjustShadingNormals': True, 'forceCullMode': False, 'cull': 'Back', 'cullNonOpaque': False, 'useTraceRayInline': False, 'useDOF': True})
    g.create_pass('VideoRecorder', 'VideoRecorder', {})
    g.create_pass('UnpackVBuffer', 'UnpackVBuffer', {})
    g.create_pass('RayReconstructionPass', 'RayReconstructionPass', {})
    g.add_edge('UnpackVBuffer.roughness', 'RayReconstructionPass.roughness')
    g.add_edge('VBufferRT.vbuffer', 'PhotonGuiding.VBuffer')
    g.add_edge('VBufferRT.viewW', 'PhotonGuiding.View')
    g.add_edge('VBufferRT.mvec', 'PhotonGuiding.MotionVector')
    g.add_edge('VideoRecorder', 'VBufferRT')
    g.add_edge('PhotonGuiding.ColorOut', 'RayReconstructionPass.color')
    g.add_edge('VBufferRT.mvec', 'RayReconstructionPass.mvec')
    g.add_edge('VBufferRT.vbuffer', 'UnpackVBuffer.vbuffer')
    g.add_edge('UnpackVBuffer.normalW', 'RayReconstructionPass.normal')
    g.add_edge('UnpackVBuffer.diffuse', 'RayReconstructionPass.diffAlbedo')
    g.add_edge('UnpackVBuffer.specular', 'RayReconstructionPass.specAlbedo')
    g.add_edge('UnpackVBuffer.linearZ', 'RayReconstructionPass.linearZ')
    g.add_edge('RayReconstructionPass.output', 'ToneMapper.src')
    g.mark_output('ToneMapper.dst')
    return g

PhotonGuiding = render_graph_PhotonGuiding()
try: m.addGraph(PhotonGuiding)
except NameError: None
