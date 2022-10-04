from falcor import *

def render_graph_RTXDI():
    g = RenderGraph('RTXDI')
    loadRenderPassLibrary('DLSSPass.dll')
    loadRenderPassLibrary('PhotonMapper.dll')
    loadRenderPassLibrary('AccumulatePass.dll')
    loadRenderPassLibrary('BSDFViewer.dll')
    loadRenderPassLibrary('Antialiasing.dll')
    loadRenderPassLibrary('BlitPass.dll')
    loadRenderPassLibrary('CSM.dll')
    loadRenderPassLibrary('DebugPasses.dll')
    loadRenderPassLibrary('PathTracer.dll')
    loadRenderPassLibrary('DepthPass.dll')
    loadRenderPassLibrary('ErrorMeasurePass.dll')
    loadRenderPassLibrary('SimplePostFX.dll')
    loadRenderPassLibrary('FLIPPass.dll')
    loadRenderPassLibrary('ForwardLightingPass.dll')
    loadRenderPassLibrary('VBufferPM.dll')
    loadRenderPassLibrary('GBuffer.dll')
    loadRenderPassLibrary('WhittedRayTracer.dll')
    loadRenderPassLibrary('ImageLoader.dll')
    loadRenderPassLibrary('MegakernelPathTracer.dll')
    loadRenderPassLibrary('MinimalPathTracer.dll')
    loadRenderPassLibrary('ModulateIllumination.dll')
    loadRenderPassLibrary('NRDPass.dll')
    loadRenderPassLibrary('OptixDenoiser.dll')
    loadRenderPassLibrary('PassLibraryTemplate.dll')
    loadRenderPassLibrary('PhotonMapperHash.dll')
    loadRenderPassLibrary('PathVBuffer.dll')
    loadRenderPassLibrary('PhotonMapperStochasticHash.dll')
    loadRenderPassLibrary('PhotonReSTIR.dll')
    loadRenderPassLibrary('PhotonReSTIRVPL.dll')
    loadRenderPassLibrary('PixelInspectorPass.dll')
    loadRenderPassLibrary('PTVBuffer.dll')
    loadRenderPassLibrary('ReStirExp.dll')
    loadRenderPassLibrary('SkyBox.dll')
    loadRenderPassLibrary('RTXDIPass.dll')
    loadRenderPassLibrary('RTXGIPass.dll')
    loadRenderPassLibrary('SceneDebugger.dll')
    loadRenderPassLibrary('SDFEditor.dll')
    loadRenderPassLibrary('SSAO.dll')
    loadRenderPassLibrary('SVGFPass.dll')
    loadRenderPassLibrary('TemporalDelayPass.dll')
    loadRenderPassLibrary('TestPasses.dll')
    loadRenderPassLibrary('ToneMapper.dll')
    loadRenderPassLibrary('Utils.dll')
    AccumulatePass = createPass('AccumulatePass', {'enabled': False, 'outputSize': IOSize.Default, 'autoReset': True, 'precisionMode': AccumulatePrecision.Single, 'subFrameCount': 0, 'maxAccumulatedFrames': 0})
    g.addPass(AccumulatePass, 'AccumulatePass')
    ToneMapper = createPass('ToneMapper', {'outputSize': IOSize.Default, 'useSceneMetadata': True, 'exposureCompensation': 0.0, 'autoExposure': False, 'filmSpeed': 100.0, 'whiteBalance': False, 'whitePoint': 6500.0, 'operator': ToneMapOp.Aces, 'clamp': True, 'whiteMaxLuminance': 1.0, 'whiteScale': 11.199999809265137, 'fNumber': 1.0, 'shutter': 1.0, 'exposureMode': ExposureMode.AperturePriority})
    g.addPass(ToneMapper, 'ToneMapper')
    Composite = createPass('Composite', {'mode': CompositeMode.Add, 'scaleA': 1.0, 'scaleB': 1.0, 'outputFormat': ResourceFormat.RGBA32Float})
    g.addPass(Composite, 'Composite')
    PhotonReSTIRVPL = createPass('PhotonReSTIRVPL')
    g.addPass(PhotonReSTIRVPL, 'PhotonReSTIRVPL')
    VBufferPM = createPass('VBufferPM', {'outputSize': IOSize.Default, 'samplePattern': 3, 'specRoughCutoff': 0.0, 'sampleCount': 32, 'useAlphaTest': True, 'adjustShadingNormals': True})
    g.addPass(VBufferPM, 'VBufferPM')
    ReStirExp = createPass('ReStirExp')
    g.addPass(ReStirExp, 'ReStirExp')
    Composite0 = createPass('Composite', {'mode': CompositeMode.Multiply, 'scaleA': 1.0, 'scaleB': 1.0, 'outputFormat': ResourceFormat.RGBA32Float})
    g.addPass(Composite0, 'Composite0')
    g.addEdge('VBufferPM.mvec', 'ReStirExp.mVec')
    g.addEdge('PhotonReSTIRVPL.color', 'Composite.B')
    g.addEdge('VBufferPM.linearDepth', 'ReStirExp.linZ')
    g.addEdge('AccumulatePass.output', 'ToneMapper.src')
    g.addEdge('VBufferPM.vbuffer', 'PhotonReSTIRVPL.VBuffer')
    g.addEdge('VBufferPM.vbuffer', 'ReStirExp.vbuffer')
    g.addEdge('VBufferPM.viewW', 'ReStirExp.view')
    g.addEdge('VBufferPM.mvec', 'PhotonReSTIRVPL.MVec')
    g.addEdge('VBufferPM.viewW', 'PhotonReSTIRVPL.View')
    g.addEdge('VBufferPM.linearDepth', 'PhotonReSTIRVPL.RayDepth')
    g.addEdge('ReStirExp.color', 'Composite.A')
    g.addEdge('Composite.out', 'Composite0.A')
    g.addEdge('Composite0.out', 'AccumulatePass.input')
    g.addEdge('VBufferPM.throughput', 'Composite0.B')
    g.markOutput('ToneMapper.dst')
    return g

RTXDI = render_graph_RTXDI()
try: m.addGraph(RTXDI)
except NameError: None
