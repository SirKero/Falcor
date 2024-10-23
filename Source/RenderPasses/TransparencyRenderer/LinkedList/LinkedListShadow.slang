import Rendering.ShadowMaps.ShadowTestFunctions;
import Rendering.ShadowMaps.ShadowMapHelpers;

#ifndef COUNT_LIGHTS
#define COUNT_LIGHTS 1
#endif

#ifndef USE_LINKED_PCF
#define USE_LINKED_PCF 0
#endif

#ifndef USE_LINKED_LIST_ARRAY
#define USE_LINKED_LIST_ARRAY 0
#endif

struct LinkedListShadow
{
    //Structs
    struct ListNode
    {
        float depth;
        float visibility;
        uint next;
    };

    struct ListNode2
    {
        uint prev;
        uint right;
        uint bot;
    }

    struct ArrayNode
    {
        float depth;
        float visibility;
    };

    struct LinkedPcfData
    {
        float depth;
        float visibilityFront; // visibility in front of the depth
        float visibilityBack; // visibility behind the depth
    };

    //Constant Buffers
    cbuffer SMCB
    {
        uint2 gSMSize;
        float gNear;
        float gFar;
    }

    cbuffer ShadowVPs
    {
        float4x4 gShadowMapVP[COUNT_LIGHTS];
    }

    //Textures/Buffers
    StructuredBuffer<ListNode> gLinkedList[COUNT_LIGHTS];
    StructuredBuffer<ListNode2> gLinkedListNeighbors[COUNT_LIGHTS];
    StructuredBuffer<ArrayNode> gLinkedListArrays[COUNT_LIGHTS];
    Texture2D<uint2> gLinkedListArrayOffsets[COUNT_LIGHTS]; // stores offsets for the array: (start, count) pairs.

    float getLinkedVisibility(ListNode n, float dist, uint lightIdx)
    {
        float visibility = 1.0;
        // from the way we construct the linked list neighbors, we know that we start with n.depth < depth
        while (n.depth < dist)
        {
            visibility = n.visibility;
            if (n.next == 0) break;
            n = gLinkedList[lightIdx][n.next];
        }

        return visibility;
    }

    LinkedPcfData getLinkedPcfData(ListNode n, float dist, uint lightIdx)
    {
        LinkedPcfData data;
        data.depth = n.depth;
        data.visibilityFront = 1.0;
        data.visibilityBack = n.visibility;
        //return data;
        float prevVisibility = n.visibility;

        // find closest depth
        float minDist = abs(n.depth - dist);
        while(n.next != 0 && n.depth < dist)
        {
            n = gLinkedList[lightIdx][n.next];
            float curDist = abs(n.depth - dist); 
            if(curDist < minDist)
            {
                minDist = curDist;
                data.depth = n.depth;
                data.visibilityFront = prevVisibility;
                data.visibilityBack = n.visibility;
            }
            prevVisibility = n.visibility;
        }

        return data;
    }


    float eval(uint lightIdx, float3 posW) {
        float4 shadowPos = mul(gShadowMapVP[lightIdx], float4(posW, 1));
        shadowPos.xyz /= shadowPos.w;

        shadowPos.y *= -1;                       // Flip
        shadowPos.xy = shadowPos.xy * 0.5 + 0.5; // UV from [-1,1] to [0,1]
        shadowPos.z = (shadowPos.w - gNear) / (gFar - gNear); // Linear distance

        // Check if inside
        if (any(shadowPos.xyz < 0.0) || any(shadowPos.xyz > 1.0))
            return 0.0;

        float dist = shadowPos.w; //-1.0 * mul(gShadowMapView[lightIdx], float4(posW, 1.0)).z;
        float visibility = 1.0;

    #if USE_LINKED_LIST_ARRAY
        dist = dist - 1e-2;       // TODO better bias
        uint2 shadowPixel = uint2(floor(shadowPos.xy * gSMSize));
        uint2 offsets = gLinkedListArrayOffsets[lightIdx][shadowPixel];
        for(uint index = offsets.x; index < offsets.x + offsets.y; index++)
        {
            ArrayNode n = gLinkedListArrays[lightIdx][index];
            if (n.depth >= dist) break;
            visibility = n.visibility;
        }
    #else // USE_LINKED_LIST_ARRAY
        if (USE_LINKED_PCF)
        {
            float2 gatherUV;
            // (-,+),(+,+)(+,-)(-,-) => BotLeft (x), BotRight (y), TopRight (z), TopLeft (w)
            float4 w = getGatherWeights(shadowPos.xy, gSMSize.x, gatherUV);
        
            //dist = dist - 1e-8;
            //dist = dist - 1e-2;
            int2 shadowPixel = int2(floor(shadowPos.xy * gSMSize - 0.5));
            // TODO special case for borders
            if (shadowPixel.x < 0 || shadowPixel.y < 0 || shadowPixel.x >= gSMSize.x - 1 || shadowPixel.y >= gSMSize.y - 1)
                return 0.0;

            uint index = shadowPixel.y * gSMSize.x + shadowPixel.x;
            let wData = getLinkedPcfData(gLinkedList[lightIdx][index], dist, lightIdx);
            let zData = getLinkedPcfData(gLinkedList[lightIdx][index + 1], dist, lightIdx);
            let yData = getLinkedPcfData(gLinkedList[lightIdx][index + gSMSize.x + 1], dist, lightIdx);
            let xData = getLinkedPcfData(gLinkedList[lightIdx][index + gSMSize.x], dist, lightIdx);

            float c = 80.0; // exponential shadow map
            float visFront = dot(w, float4(xData.visibilityFront, yData.visibilityFront, zData.visibilityFront, wData.visibilityFront));
            float visBack = dot(w, float4(xData.visibilityBack, yData.visibilityBack, zData.visibilityBack, wData.visibilityBack));
            float4 rawDepths = float4(xData.depth, yData.depth, zData.depth, wData.depth);

            // reformat to [0, 1]
            float4 linearDepths = saturate(rawDepths / gFar);
            dist = saturate(dist / gFar);
            //linearDepths = linearDepths * 2.0 - 1.0;
            //dist = dist * 2.0 - 1.0;

            float2 moments = float2(dot(w, linearDepths), dot(w, linearDepths * linearDepths));
            float shadowTest = ChebyshevUpperBound(moments, dist, 1e-10);

            //float4 moments = float4(dot(w, linearDepths), dot(w, linearDepths * linearDepths), dot(w, linearDepths * linearDepths * linearDepths), dot(w, linearDepths * linearDepths * linearDepths * linearDepths));
            //float shadowTest = msmHamburger(moments, dist);

            //float filteredDepth = dot(w, exp(c * linearDepths));
            //float shadowTest = exp(-c * dist) * filteredDepth;

            shadowTest = saturate(shadowTest);
            visibility = shadowTest * visFront + (1.0 - shadowTest) * visBack;
            //visibility = visFront;
            /*ListNode n = gLinkedList[lightIdx][index];
            float4 v = 1.0; // (-,+),(+,+)(+,-)(-,-) => BotLeft (x), BotRight (y), TopRight (z), TopLeft (w)
            while (n.depth < dist) {
                v.w = n.visibility;
                if (n.next == 0) break;
                uint nextIndex = n.next;
                n = gLinkedList[lightIdx][n.next];
                if (n.depth < dist) index = nextIndex; // only update if the next node is still in front (because index will be used to obtain the neighbors)
            }
            uint zIndex = gLinkedListNeighbors[lightIdx][index].right;
            uint xIndex = gLinkedListNeighbors[lightIdx][index].bot;
            ListNode nZ = gLinkedList[lightIdx][zIndex];
            ListNode nX = gLinkedList[lightIdx][xIndex];
            // TODO trace for correct visibility
            v.z = getLinkedVisibility(nZ, dist, lightIdx);
            v.x = getLinkedVisibility(nX, dist, lightIdx);
            uint yIndex = gLinkedListNeighbors[lightIdx][zIndex].bot;
            ListNode nY = gLinkedList[lightIdx][yIndex];
            v.y = getLinkedVisibility(nY, dist, lightIdx);
            visibility = dot(w, v);
            // visibility = (v.x + v.y + v.z + v.w) * 0.25;
            //visibility = max(max(v.x, v.y), max(v.z, v.w));
            */
        }
        else
        {
            dist = dist - 1e-2;       // TODO better bias
            uint2 shadowPixel = uint2(floor(shadowPos.xy * gSMSize));
            uint index = shadowPixel.y * gSMSize.x + shadowPixel.x;
            ListNode n = gLinkedList[lightIdx][index];
            // traverse visibility until dist is reached
            while (n.depth < dist) {
                visibility = n.visibility;
                if (n.next == 0) break;
                n = gLinkedList[lightIdx][n.next];
            }
        }
    #endif //USE_LINKED_LIST_ARRAY
        return visibility;
    }
    
} gLinkedListShadow;
