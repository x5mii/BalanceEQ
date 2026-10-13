// SPDX-License-Identifier: GPL-3.0-or-later
#ifndef EQ_DSP_H
#define EQ_DSP_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum {
    EQ_MAX_BANDS = 32,
    EQ_PEAK = 0,
    EQ_LOW_SHELF = 1,
    EQ_HIGH_SHELF = 2,
    EQ_LOW_PASS = 3,
    EQ_HIGH_PASS = 4,
    EQ_NOTCH = 5
};

typedef struct {
    int32_t type;
    uint32_t enabled;
    double frequency;
    double gainDB;
    double q;
} EQBand;

typedef struct {
    uint32_t count;
    double preampDB;
    uint32_t bypass;
    EQBand bands[EQ_MAX_BANDS];
} EQParameters;

typedef struct EQDSP EQDSP;

// Assigns a slot and extends count if needed. Validation occurs at publication.
bool eq_parameters_set_band(EQParameters *parameters, uint32_t index, EQBand band);

// Normalized coefficients: b0, b1, b2, a1, a2. Disabled bands return identity.
// Range: 10...20000 Hz (enabled bands below Nyquist), +/-24 dB, Q 0.1...30.
// Shelves use their center frequency and Q, not APO's corner-frequency syntax.
bool eq_coefficients(EQBand band, double sampleRate, double out[5]);
// NaN indicates invalid parameters; an exact null in the response is -infinity.
double eq_response_db(EQBand band, double sampleRate, double frequency);

// Sample rates 8000...384000; scratch capacity 1...65536 frames.
EQDSP *eq_dsp_create(double sampleRate, uint32_t maxFrames);
// Stop the render callback and control producer before destroying the instance.
void eq_dsp_destroy(EQDSP *dsp);

// One serial control producer may publish concurrently with one render consumer.
// Latest valid publication wins. Invalid parameters leave the previous state intact.
// Coefficients are prepared here, never in the audio callback.
bool eq_dsp_set_parameters(EQDSP *dsp, const EQParameters *parameters);

// Single render consumer. No allocations or locks. Both strides must be positive.
// NULL right input duplicates left. NULL left input produces silence. Stereo input
// and output may alias exactly; channel outputs must not alias one another.
// Oversized calls are chunked. Changes crossfade stable complete banks over 20 ms.
// Output is hard-clipped to [-1,1] at the final boundary; this is not a limiter.
void eq_dsp_process(EQDSP *dsp, const float *inL, const float *inR,
                    uint32_t inStride, float *outL, float *outR,
                    uint32_t outStride, uint32_t frames);

// Latest block's peak before final clipping (linear amplitude). Safe atomic polls.
float eq_dsp_peak(EQDSP *dsp);
// Returns and clears latched clipping, also set for nonfinite input/DSP output.
bool eq_dsp_take_clipping(EQDSP *dsp);

#ifdef __cplusplus
}
#endif
#endif
