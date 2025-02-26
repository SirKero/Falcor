add_plugin(TransparencyRenderer)

target_sources(TransparencyRenderer PRIVATE
	AccelShadow/AccelShadow.h
	AccelShadow/AccelShadow.cpp
	AccelShadow/GenAccelShadow.rt.slang
	AccelShadow/AccelShadow.slang
	AccelShadow/AccelShadowData.slang
	AccelShadow/DebugShowShadowAccel.3d.slang

	AccelShadowKBuffer/AccelShadowKBuffer.h
	AccelShadowKBuffer/AccelShadowKBuffer.cpp
	AccelShadowKBuffer/GenAccelShadowKBuffer.rt.slang
	AccelShadowKBuffer/AccelShadowKBuffer.slang
	AccelShadowKBuffer/AccelShadowKBufferData.slang
	AccelShadowKBuffer/DebugShowShadowAccel.3d.slang
	
	AccelIrregularZ/AccelIrregularZ.h
	AccelIrregularZ/AccelIrregularZ.cpp
	AccelIrregularZ/GenAccelIrregularZ.rt.slang
	AccelIrregularZ/AccelIrregularZ.slang
	AccelIrregularZ/AccelIrregularZData.slang
	AccelIrregularZ/GenAccessMips.cs.slang
	AccelIrregularZ/CalcSampleDistribution.cs.slang
	AccelIrregularZ/DebugShowShadowAccel.3d.slang
	AccelIrregularZ/OptimizeSamples.cs.slang

	LinkedList/LinkedListShadow.h
	LinkedList/LinkedListShadow.cpp
	LinkedList/LinkedListShadow.slang
	LinkedList/GenLinkedList.rt.slang
	LinkedList/GenLinkedListNeighbors.cs.slang

    	LinkedListIrregularZ/LinkedListIrregularZ.h
	LinkedListIrregularZ/LinkedListIrregularZ.cpp
	LinkedListIrregularZ/LinkedListIrregularZ.slang
	LinkedListIrregularZ/GenLinkedListIrregularZ.rt.slang
	LinkedListIrregularZ/LinkedListIrregularZData.slang

    	VirtualShadowMap/VirtualShadowMap.h
	VirtualShadowMap/VirtualShadowMap.cpp
	VirtualShadowMap/GenVirtualShadowMap.rt.slang
	VirtualShadowMap/VirtualShadowMap.slang
	VirtualShadowMap/VirtualShadowMapData.slang

	TransparencyShadowMethod.h
	TransparencyShadowMethod.cpp

	TransparencyRenderer.cpp
	TransparencyRenderer.h
	
	EvaluateAnalyticLight.slang
	EvalDirect.cs.slang
	EvalTransparenciesDirect.rt.slang
	PathTracer.rt.slang
	RayLodHelper.slang
)

target_copy_shaders(TransparencyRenderer RenderPasses/TransparencyRenderer)
target_source_group(TransparencyRenderer "RenderPasses")
