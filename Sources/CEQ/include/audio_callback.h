// SPDX-License-Identifier: GPL-3.0-or-later
#ifndef EQ_AUDIO_CALLBACK_H
#define EQ_AUDIO_CALLBACK_H

#include <CoreAudio/CoreAudio.h>
#include "eq_dsp.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct EQAudioContext EQAudioContext;

// Create/destroy on the control queue, while the IOProc is stopped.
EQAudioContext * _Nullable eq_audio_create(EQDSP * _Nonnull dsp, uint32_t hardwareInputChannels,
                                uint32_t totalInputChannels, uint32_t maxFrames);
void eq_audio_destroy(EQAudioContext * _Nullable context);
int eq_audio_error(const EQAudioContext * _Nullable context);
const char * _Nonnull eq_audio_error_message(int error);

OSStatus eq_audio_io_proc(AudioObjectID device, const AudioTimeStamp * _Nonnull now,
                         const AudioBufferList * _Nonnull input, const AudioTimeStamp * _Nonnull inputTime,
                         AudioBufferList * _Nonnull output, const AudioTimeStamp * _Nonnull outputTime,
                         void * _Nullable context);

// Disable physical microphone/line inputs in a duplex aggregate; keep tap streams.
OSStatus eq_audio_disable_hardware_inputs(AudioObjectID device, AudioDeviceIOProcID _Nonnull proc,
                                         uint32_t hardwareStreams, uint32_t totalStreams);

#ifdef __cplusplus
}
#endif
#endif
