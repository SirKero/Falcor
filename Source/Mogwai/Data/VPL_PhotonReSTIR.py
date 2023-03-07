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
    VBufferRT = createPass('VBufferRT', {'outputSize': IOSize.Default, 'samplePattern': SamplePattern.Center, 'sampleCount': 16, 'useAlphaTest': True, 'adjustShadingNormals': True, 'forceCullMode': False, 'cull': CullMode.CullBack, 'useTraceRayInline': False, 'useDOF': True})
    g.addPass(VBufferRT, 'VBufferRT')
    RTXDIPass = createPass('RTXDIPass', {'options': RTXDIOptions(mode=RTXDIMode.SpatiotemporalResampling, presampledTileCount=128, presampledTileSize=1024, storeCompactLightInfo=True, localLightCandidateCount=24, infiniteLightCandidateCount=8, envLightCandidateCount=8, brdfCandidateCount=1, brdfCutoff=0.0, testCandidateVisibility=True, biasCorrection=RTXDIBiasCorrection.Basic, depthThreshold=0.10000000149011612, normalThreshold=0.5, samplingRadius=30.0, spatialSampleCount=1, spatialIterations=5, maxHistoryLength=20, boilingFilterStrength=0.0, rayEpsilon=0.0010000000474974513, useEmissiveTextures=False, enableVisibilityShortcut=False, enablePermutationSampling=False)})
    g.addPass(RTXDIPass, 'RTXDIPass')
    AccumulatePass = createPass('AccumulatePass', {'enabled': False, 'outputSize': IOSize.Default, 'autoReset': True, 'precisionMode': AccumulatePrecision.Single, 'subFrameCount': 0, 'maxAccumulatedFrames': 0})
    g.addPass(AccumulatePass, 'AccumulatePass')
    ToneMapper = createPass('ToneMapper', {'outputSize': IOSize.Default, 'useSceneMetadata': True, 'exposureCompensation': 0.0, 'autoExposure': False, 'filmSpeed': 100.0, 'whiteBalance': False, 'whitePoint': 6500.0, 'operator': ToneMapOp.Aces, 'clamp': True, 'whiteMaxLuminance': 1.0, 'whiteScale': 11.199999809265137, 'fNumber': 1.0, 'shutter': 1.0, 'exposureMode': ExposureMode.AperturePriority})
    g.addPass(ToneMapper, 'ToneMapper')
    Composite = createPass('Composite', {'mode': CompositeMode.Add, 'scaleA': 1.0, 'scaleB': 1.0, 'outputFormat': ResourceFormat.RGBA32Float})
    g.addPass(Composite, 'Composite')
    PhotonReSTIRVPL = createPass('PhotonReSTIRVPL')
    g.addPass(PhotonReSTIRVPL, 'PhotonReSTIRVPL')
    g.addEdge('VBufferRT.mvec', 'PhotonReSTIRVPL.MVec')
    g.addEdge('VBufferRT.vbuffer', 'RTXDIPass.vbuffer')
    g.addEdge('PhotonReSTIRVPL.color', 'Composite.B')
    g.addEdge('VBufferRT.mvec', 'RTXDIPass.mvec')
    g.addEdge('AccumulatePass.output', 'ToneMapper.src')
    g.addEdge('Composite.out', 'AccumulatePass.input')
    g.addEdge('RTXDIPass.color', 'Composite.A')
    g.addEdge('VBufferRT.vbuffer', 'PhotonReSTIRVPL.VBuffer')
    g.markOutput('ToneMapper.dst')
    return g

RTXDI = render_graph_RTXDI()
try: m.addGraph(RTXDI)
except NameError: None