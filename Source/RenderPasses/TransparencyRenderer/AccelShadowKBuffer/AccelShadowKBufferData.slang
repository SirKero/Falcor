#define SHADOW_DATA_FORMAT uint2

#ifndef ACCEL_K_PER_BOX
#define ACCEL_K_PER_BOX 4
#endif

struct AccelShadowKBufferData {
    struct DataNode {
        float rangeStart;
        float rangeEnd;
        float transparency;
    }
    DataNode nodes[ACCEL_K_PER_BOX];
    float transparencyEnd;

    __init() {
        [unroll]
        for (uint i = 0; i < ACCEL_K_PER_BOX; i++) {
            this.nodes[i].rangeStart = 1.0f;
            this.nodes[i].rangeEnd = 0.0f;
            this.nodes[i].transparency = -1.f;
        }
        this.transparencyEnd = 1.f;
    }

    [mutating]
    void unpack(uint2 data[ACCEL_K_PER_BOX]) {
        transparencyEnd = f16tof32((data[0].y >> 16) & 0xFFFF);
        for (uint i = 0; i < ACCEL_K_PER_BOX; i++) {
            nodes[i].rangeStart = float(data[i].x & 0xFFFF) / float(0xFFFF);
            nodes[i].rangeEnd = float((data[i].x >> 16) & 0xFFFF) / float(0xFFFF);
            nodes[i].transparency = f16tof32(data[i].y & 0xFFFF);
        }
    }

    __init(uint2 data[ACCEL_K_PER_BOX]) {
        unpack(data);
    }

    void pack(out uint2 data[ACCEL_K_PER_BOX]) {
        [unroll]
        for (uint i = 0; i < ACCEL_K_PER_BOX; i++) {
            data[i].x = uint(nodes[i].rangeStart * float(0xFFFF)) & 0xFFFF;
            data[i].x |= (uint(nodes[i].rangeEnd * float(0xFFFF)) & 0xFFFF) << 16;
            data[i].y = f32tof16(nodes[i].transparency);
        }

        data[0].y |= f32tof16(transparencyEnd) << 16;
    }

}
