#ifndef USE_COLOR_TRANSPARENCY
#define USE_COLOR_TRANSPARENCY 0
#endif

#if USE_COLOR_TRANSPARENCY
#define SHADOW_DATA_FORMAT float3
#else
#define SHADOW_DATA_FORMAT float
#endif

static const bool kUseColorTransparency = USE_COLOR_TRANSPARENCY;

/*
#if SHADOW_DATA_FORMAT_SIZE == 1
#define SHADOW_DATA_FORMAT uint
#elif SHADOW_DATA_FORMAT_SIZE == 2
#define SHADOW_DATA_FORMAT uint2
#elif SHADOW_DATA_FORMAT_SIZE == 4
#define SHADOW_DATA_FORMAT uint4
#else
#error Unknows Format Size
#endif
*/
//Old format
struct AccelShadowData {
    float transparency;
    float hitDepth;

    __init() {
        this.transparency = 1.0;
        this.hitDepth = 0.0;
    }

    __init(float transparency , float hitDepth) {
        this.transparency = transparency;
        this.hitDepth = hitDepth;
    }

    [mutating]
    void unpack(uint data) {
        this.transparency = f16tof32(data & 0xFFFF);
        this.hitDepth = f16tof32((data >> 16) & 0xFFFF);
    }

    [mutating]
    void unpack(uint2 data) {
        this.transparency = asfloat(data.x);
        this.hitDepth = asfloat(data.y);

    }

    [mutating]
    void unpack(uint4 data) {
        this.transparency = asfloat(data.x);
        this.hitDepth = asfloat(data.y);
    }

    __init(uint data) {
        unpack(data);
    }
    __init(uint2 data) {
        unpack(data);
    }
    __init(uint4 data) {
        unpack(data);
    }

    uint packAsUint() {
        uint data = 0;
        data |= f32tof16(this.transparency);
        data |= f32tof16(this.hitDepth) << 16;
        return data;
    }

    uint2 packAsUint2() {
        uint2 data = uint2(0);
        data.x = asuint(this.transparency);
        data.y = asuint(this.hitDepth);
        return data;
    }

    uint4 packAsUint4() {
        uint4 data = uint4(0);
        data.x = asuint(this.transparency);
        data.y = asuint(this.hitDepth);
        return data;
    }
}
