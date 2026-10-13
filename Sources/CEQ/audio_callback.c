// SPDX-License-Identifier: GPL-3.0-or-later
#include "audio_callback.h"
#include <stddef.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

_Static_assert(ATOMIC_INT_LOCK_FREE == 2, "The audio callback requires lock-free integer atomics");

struct EQAudioContext {
    EQDSP *dsp;
    uint32_t inputOffset, inputChannels, maxFrames;
    _Atomic int error;
};

EQAudioContext *eq_audio_create(EQDSP *dsp, uint32_t hardwareInputChannels,
                                uint32_t totalInputChannels, uint32_t maxFrames) {
    if (!dsp || !maxFrames || hardwareInputChannels > UINT32_MAX - 2 ||
        totalInputChannels != hardwareInputChannels + 2) return NULL;
    EQAudioContext *c = calloc(1, sizeof(*c));
    if (c) {
        c->dsp = dsp;
        c->inputOffset = hardwareInputChannels;
        c->inputChannels = totalInputChannels;
        c->maxFrames = maxFrames;
        atomic_init(&c->error, 0);
    }
    return c;
}

void eq_audio_destroy(EQAudioContext *c) { free(c); }
int eq_audio_error(const EQAudioContext *c) {
    return c ? atomic_load_explicit(&c->error, memory_order_relaxed) : 0;
}
const char *eq_audio_error_message(int error) {
    switch (error) {
        case 1: return "The audio buffer layout changed. Processing stopped; native playback is restored.";
        case 2: return "System audio input is unavailable. Check System Audio Recording permission, then start again.";
        case 3: return "The device changed its audio buffer size. Processing stopped; start again to reconnect.";
        default: return "Audio processing stopped.";
    }
}

static void silence(AudioBufferList *list) {
    if (!list) return;
    for (UInt32 i = 0; i < list->mNumberBuffers; ++i)
        if (list->mBuffers[i].mData)
            memset(list->mBuffers[i].mData, 0, list->mBuffers[i].mDataByteSize);
}

// Resolve channels from the actual ABL, including inactive duplex hardware buffers.
static float *channel(const AudioBufferList *list, uint32_t wanted,
                      uint32_t expectedChannels, uint32_t *stride, uint32_t *frames) {
    if (!list) return NULL;
    uint32_t base = 0;
    float *result = NULL;
    for (UInt32 i = 0; i < list->mNumberBuffers; ++i) {
        const AudioBuffer *b = &list->mBuffers[i];
        if (b->mNumberChannels > expectedChannels - base) return NULL;
        if (wanted >= base && wanted - base < b->mNumberChannels) {
            if (!b->mData || !b->mNumberChannels ||
                b->mDataByteSize % (sizeof(float) * b->mNumberChannels)) return NULL;
            result = (float *)b->mData + wanted - base;
            *stride = b->mNumberChannels;
            *frames = b->mDataByteSize / (sizeof(float) * b->mNumberChannels);
        }
        base += b->mNumberChannels;
    }
    return base == expectedChannels ? result : NULL;
}

OSStatus eq_audio_io_proc(AudioObjectID device, const AudioTimeStamp *now,
                         const AudioBufferList *input, const AudioTimeStamp *inputTime,
                         AudioBufferList *output, const AudioTimeStamp *outputTime,
                         void *context) {
    (void)device; (void)now; (void)inputTime; (void)outputTime;
    EQAudioContext *c = context;
    if (!c || atomic_load_explicit(&c->error, memory_order_relaxed)) {
        silence(output);
        return noErr;
    }
    bool hasOutput = false;
    for (UInt32 i = 0; i < output->mNumberBuffers; ++i)
        hasOutput |= output->mBuffers[i].mDataByteSize != 0;
    if (!hasOutput) return noErr;
    uint32_t osL = 0, osR = 0, ofL = 0, ofR = 0;
    float *outL = channel(output, 0, 2, &osL, &ofL);
    float *outR = channel(output, 1, 2, &osR, &ofR);
    int error = 0;
    if (!outL || !outR || osL != osR || ofL != ofR) error = 1;
    else if (ofL > c->maxFrames) error = 3;
    // An empty hardware cycle needs no input; it is not a permission failure.
    else if (!ofL) return noErr;
    uint32_t isL = 0, isR = 0, ifL = 0, ifR = 0;
    float *inL = channel(input, c->inputOffset, c->inputChannels, &isL, &ifL);
    float *inR = channel(input, c->inputOffset + 1, c->inputChannels, &isR, &ifR);
    if (!error && (!inL || !inR)) error = 2;
    else if (!error && (isL != isR || ifL != ofL || ifR != ofL)) error = 1;
    if (error) {
        silence(output);
        atomic_store_explicit(&c->error, error, memory_order_relaxed);
        return noErr;
    }
    eq_dsp_process(c->dsp, inL, inR, isL, outL, outR, osL, ofL);
    return noErr;
}

OSStatus eq_audio_disable_hardware_inputs(AudioObjectID device, AudioDeviceIOProcID proc,
                                         uint32_t hardwareStreams, uint32_t totalStreams) {
    if (!hardwareStreams) return noErr;
    if (!totalStreams || hardwareStreams >= totalStreams || totalStreams > 256)
        return kAudioHardwareIllegalOperationError;
    UInt32 size = (UInt32)(offsetof(AudioHardwareIOProcStreamUsage, mStreamIsOn) +
                            totalStreams * sizeof(UInt32));
    AudioHardwareIOProcStreamUsage *usage = calloc(1, size);
    if (!usage) return kAudioHardwareUnspecifiedError;
    usage->mIOProc = (void *)proc;
    usage->mNumberStreams = totalStreams;
    for (uint32_t i = hardwareStreams; i < totalStreams; ++i) usage->mStreamIsOn[i] = 1;
    AudioObjectPropertyAddress a = { kAudioDevicePropertyIOProcStreamUsage,
        kAudioObjectPropertyScopeInput, kAudioObjectPropertyElementMain };
    OSStatus status = AudioObjectSetPropertyData(device, &a, 0, NULL, size, usage);
    free(usage);
    return status;
}

#ifdef EQ_AUDIO_CALLBACK_TEST_MAIN
#include <assert.h>
#include <math.h>
int main(void) {
    EQDSP *dsp = eq_dsp_create(48000, 16);
    assert(dsp);
    EQAudioContext *c = eq_audio_create(dsp, 1, 3, 16);
    assert(c);
    float l[4] = {.1f, .2f, .3f, .4f}, r[4] = {-.1f, -.2f, -.3f, -.4f};
    float out[8] = {0};
    struct { UInt32 count; AudioBuffer buffers[3]; } input = {3,
        {{1, sizeof(l), NULL}, {1, sizeof(l), l}, {1, sizeof(r), r}}};
    AudioBufferList output = {1, {{2, sizeof(out), out}}};
    AudioTimeStamp timestamp = {0};
    eq_audio_io_proc(0, &timestamp, (AudioBufferList *)&input, &timestamp, &output, &timestamp, c);
    assert(eq_audio_error(c) == 0);
    for (int i = 0; i < 4; ++i) {
        assert(fabsf(out[2*i] - l[i]) < 1e-5f);
        assert(fabsf(out[2*i+1] - r[i]) < 1e-5f);
    }
    input.buffers[1].mData = NULL;
    eq_audio_io_proc(0, &timestamp, (AudioBufferList *)&input, &timestamp, &output, &timestamp, c);
    assert(eq_audio_error(c) == 2);
    for (int i = 0; i < 8; ++i) assert(out[i] == 0);
    eq_audio_destroy(c);
    eq_dsp_destroy(dsp);
    return 0;
}
#endif
