import Scene.SceneTypes;
import Utils.Sampling.SampleGenerator;
import ParticleDataTypes;

cbuffer CB
{
    uint gFrameCount;           //Frame Count for sample generator
    uint gParticleBufferOffset; // Offset in the global particle point buffer
    uint gNumParticles;     //Number of particles for this particle spawner

    float3 gRestPosition; // Position for inactive particles
    float gBaseRadius;    // Default radius for every active/inactive particle

    float gDeltaT;
    float3 gInitialPosition;
    float3 gInitialVelocity;
    float gMaxLifetime;

    float gGravity;
    float gSpawnRadius;
}

RWStructuredBuffer<ParticlePointDesc> gParticlePointDesc;
RWStructuredBuffer<ParticleAnimateData> gParticleAnimateData; //Extra per point data

[numthreads(64, 1, 1)]
void main(uint3 dispatchThreadId: SV_DispatchThreadID)
{
    const uint prtIdx = dispatchThreadId.x;
    if (prtIdx > gNumParticles)
        return;

    SampleGenerator sg = SampleGenerator(uint2(prtIdx,0), gFrameCount); //TODO add seed in pixel.y ?
    ParticlePointDesc particlePoint = gParticlePointDesc[prtIdx];
    ParticleAnimateData particleData = gParticleAnimateData[prtIdx];

    // Add delta time to lifetime
    particleData.lifetime += gDeltaT;

    // Respawn particle
    if (particleData.lifetime > gMaxLifetime) {
        float3 startPosition = gInitialPosition;
        float3 rnd = sampleNext3D(sg);
        rnd = (rnd * 2.0) - 1.0; // From [0,1] to [-1,1]
        particlePoint.position = startPosition + rnd * gSpawnRadius;
        particlePoint.radius = gBaseRadius;
        particleData.lifetime = 0.f;
        particleData.velocity = gInitialVelocity;
        //TODO Generate random offset. Use spherical coordinates

    }

    // Update position and apply gravity
    particlePoint.position += particleData.velocity * gDeltaT;
    particleData.velocity.y -= gGravity * gDeltaT;

    gParticlePointDesc[prtIdx] = particlePoint;
    gParticleAnimateData[prtIdx] = particleData;
}
