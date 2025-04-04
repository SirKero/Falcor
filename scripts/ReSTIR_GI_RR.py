from pathlib import WindowsPath, PosixPath
from falcor import *

def render_graph_ReSTIR_GI_RR():
    g = RenderGraph('ReSTIR_GI_RR')
    g.create_pass('AccumulatePass', 'AccumulatePass', {'enabled': False, 'outputSize': 'Default', 'autoReset': True, 'precisionMode': 'Single', 'maxFrameCount': 0, 'overflowMode': 'Stop'})
    g.create_pass('ReSTIR_GI', 'ReSTIR_GI', {})
    g.create_pass('GBufferRT', 'GBufferRT', {'outputSize': 'Default', 'samplePattern': 'Center', 'sampleCount': 16, 'useAlphaTest': True, 'adjustShadingNormals': True, 'forceCullMode': False, 'cull': 'Back', 'cullNonOpaque': False, 'texLOD': 'Mip0', 'useTraceRayInline': False, 'useDOF': True})
    g.create_pass('ToneMapper', 'ToneMapper', {'outputSize': 'Default', 'useSceneMetadata': True, 'exposureCompensation': 0.0, 'autoExposure': False, 'filmSpeed': 100.0, 'whiteBalance': False, 'whitePoint': 6500.0, 'operator': 'Aces', 'clamp': True, 'whiteMaxLuminance': 1.0, 'whiteScale': 11.199999809265137, 'fNumber': 1.0, 'shutter': 1.0, 'exposureMode': 'AperturePriority'})
    g.create_pass('RayReconstructionPass', 'RayReconstructionPass', {})
    g.create_pass('GBufferOutputsToRayReconstructionInputsPass', 'GBufferOutputsToRayReconstructionInputsPass', {})
    g.add_edge('AccumulatePass.output', 'ToneMapper.src')
    g.add_edge('GBufferRT.vbuffer', 'ReSTIR_GI.vbuffer')
    g.add_edge('GBufferRT.mvec', 'ReSTIR_GI.mvec')
    g.add_edge('GBufferRT.diffuseOpacity', 'GBufferOutputsToRayReconstructionInputsPass.diffuseOpacity')
    g.add_edge('GBufferRT.specRough', 'GBufferOutputsToRayReconstructionInputsPass.specRough')
    g.add_edge('GBufferRT.linearZ', 'GBufferOutputsToRayReconstructionInputsPass.linearZDerivative')
    g.add_edge('GBufferOutputsToRayReconstructionInputsPass.outDiffuseAlbedo', 'RayReconstructionPass.diffAlbedo')
    g.add_edge('GBufferOutputsToRayReconstructionInputsPass.outSpecularAlbedo', 'RayReconstructionPass.specAlbedo')
    g.add_edge('GBufferOutputsToRayReconstructionInputsPass.outLinearZ', 'RayReconstructionPass.linearZ')
    g.add_edge('GBufferOutputsToRayReconstructionInputsPass.outRoughness', 'RayReconstructionPass.roughness')
    g.add_edge('GBufferRT.normW', 'RayReconstructionPass.normal')
    g.add_edge('GBufferRT.mvec', 'RayReconstructionPass.mvec')
    g.add_edge('ReSTIR_GI.color', 'RayReconstructionPass.color')
    g.add_edge('RayReconstructionPass.output', 'AccumulatePass.input')
    g.mark_output('ToneMapper.dst')
    g.mark_output('AccumulatePass.output')
    return g

ReSTIR_GI_RR = render_graph_ReSTIR_GI_RR()
try: m.addGraph(ReSTIR_GI_RR)
except NameError: None
