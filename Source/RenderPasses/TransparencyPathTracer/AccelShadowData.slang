
#define ACCEL_MODE_SHADOW3D 0
#define ACCEL_MODE_NORMALOFFSET 1

#ifndef ACCEL_MODE
#define ACCEL_MODE ACCEL_MODE_SHADOW3D
#endif

#ifndef SHADOW_DATA_FORMAT_SIZE
#error Please define the SHADOW_DATA_FORMAT_SIZE
#endif

#if SHADOW_DATA_FORMAT_SIZE == 1
#define SHADOW_DATA_FORMAT uint
#elif SHADOW_DATA_FORMAT_SIZE == 2
#define SHADOW_DATA_FORMAT uint2
#elif SHADOW_DATA_FORMAT_SIZE == 4
#define SHADOW_DATA_FORMAT uint4
#else
#error Unknows Format Size
#endif

#if ACCEL_MODE == 0
struct AccelShadowData {
    float transparencyStart;
    float transparencyEnd;

    __init() {
        this.transparencyEnd = 1.0;
        this.transparencyStart = 1.0;
    }

    __init(float transparencyStart, float transparencyEnd) {
        this.transparencyStart = transparencyStart;
        this.transparencyEnd = transparencyEnd;
    }

    [mutating]
    void unpack(uint data) {
        this.transparencyStart = f16tof32(data & 0xFFFF);
        this.transparencyEnd = f16tof32((data >> 16) & 0xFFFF);
    }

    [mutating]
    void unpack(uint2 data) {
        this.transparencyStart = asfloat(data.x);
        this.transparencyEnd = asfloat(data.y);
    }

    [mutating]
    void unpack(uint4 data) {
        this.transparencyStart = asfloat(data.x);
        this.transparencyEnd = asfloat(data.y);
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
        data |= f32tof16(this.transparencyStart);
        data |= f32tof16(this.transparencyEnd) << 16;
        return data;
    }

    uint2 packAsUint2() {
        uint2 data = uint2(0);
        data.x = asuint(this.transparencyStart);
        data.y = asuint(this.transparencyEnd);
        return data;
    }

    uint4 packAsUint4() {
        uint4 data = uint4(0);
        data.x = asuint(this.transparencyStart);
        data.y = asuint(this.transparencyEnd);
        return data;
    }
}

#else // ACCEL_MODE_NORMALOFFSET

struct AccelShadowData {
    float transparencyStart;
    float transparencyEnd;
    float firstBoxRange;

    __init() {
        this.transparencyEnd = 1.0;
        this.transparencyStart = 1.0;
        this.firstBoxRange = 1e-8;
    }

    __init(float transparencyStart, float transparencyEnd, float firstBoxRange) {
        this.transparencyStart = transparencyStart;
        this.transparencyEnd = transparencyEnd;
        this.firstBoxRange = firstBoxRange;
    }

    [mutating]
    void unpack(uint data) {
        this.transparencyStart = float(data & 0xFF) / 255.0;
        this.transparencyEnd = float((data >> 8) & 0xFF) / 255.0;
        this.firstBoxRange = f16tof32((data >> 16) & 0xFFFF);
    }

    [mutating]
    void unpack(uint2 data) {
        this.transparencyStart = f16tof32(data.x & 0xFFFF);
        this.transparencyEnd = f16tof32((data.x >> 16) & 0xFFFF);
        this.firstBoxRange = asfloat(data.y);

    }

    [mutating]
    void unpack(uint4 data) {
        this.transparencyStart = asfloat(data.x);
        this.transparencyEnd = asfloat(data.y);
        this.firstBoxRange = asfloat(data.z);
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
        data |= uint(round(this.transparencyStart * 255.0)) & 0xFF;
        data |= (uint(round(this.transparencyEnd * 255.0)) & 0xFF) << 8;
        data |= f32tof16(this.firstBoxRange) << 16;
        return data;
    }

    uint2 packAsUint2() {
        uint2 data = uint2(0);
        data.x |= f32tof16(this.transparencyStart);
        data.x |= f32tof16(this.transparencyEnd) << 16;
        data.y = asuint(this.firstBoxRange);
        return data;
    }

    uint4 packAsUint4() {
        uint4 data = uint4(0);
        data.x = asuint(this.transparencyStart);
        data.y = asuint(this.transparencyEnd);
        data.z = asuint(this.firstBoxRange);
        return data;
    }
}
#endif
