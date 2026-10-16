// SPDX-License-Identifier: GPL-3.0-or-later
#include "eq_dsp.h"
#include <Accelerate/Accelerate.h>
#include <float.h>
#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

_Static_assert(ATOMIC_INT_LOCK_FREE == 2, "Audio publication requires lock-free integers");

typedef struct {
    uint32_t count;
    double gain;
    double coefficients[EQ_MAX_BANDS][5];
} Prepared;

typedef struct {
    Prepared parameters;
    double state[2][EQ_MAX_BANDS][2];
} Bank;

struct EQDSP {
    double sampleRate;
    uint32_t maxFrames, fadeFrames, fadePosition, activeBank;
    Bank banks[2];
    Prepared pending;
    bool hasPending, fading;
    // Triple-buffer ownership: writer and reader each own one exclusive slot;
    // the atomic middle slot is exchanged, never read or written in place.
    Prepared slots[3];
    uint32_t writerSlot, readerSlot;
    atomic_uint middleSlot;
    atomic_uint peakBits, clipping;
    float *scratch[2];
    atomic_uint analysisState; // 0 idle, 1 render owns storage, 2 control owns storage.
    uint32_t analysisPosition; // Render thread only.
    float analysis[4][EQ_ANALYSIS_FRAMES];
};

enum { DIRTY = 4, SLOT_MASK = 3 };

static bool valid_sample_rate(double rate) {
    return isfinite(rate) && rate >= 8000 && rate <= 384000;
}

bool eq_parameters_set_band(EQParameters *parameters, uint32_t index, EQBand band) {
    if (!parameters || index >= EQ_MAX_BANDS) return false;
    parameters->bands[index] = band;
    if (parameters->count <= index) parameters->count = index + 1;
    return true;
}

bool eq_coefficients(EQBand band, double sampleRate, double out[5]) {
    if (!out || !valid_sample_rate(sampleRate) || band.type < EQ_PEAK ||
        band.type > EQ_NOTCH || band.enabled > 1 || !isfinite(band.frequency) ||
        band.frequency < 10 || band.frequency > 20000 || !isfinite(band.gainDB) ||
        fabs(band.gainDB) > 24 || !isfinite(band.q) || band.q < 0.1 || band.q > 30 ||
        (band.enabled && band.frequency >= sampleRate * 0.5)) return false;

    if (!band.enabled || (band.type <= EQ_HIGH_SHELF && band.gainDB == 0)) {
        out[0] = 1;
        for (int i = 1; i < 5; i++) out[i] = 0;
        return true;
    }

    // Original implementation of RBJ's mathematical biquad formulae:
    // https://www.w3.org/TR/audio-eq-cookbook/
    const double omega = 2 * M_PI * band.frequency / sampleRate;
    const double c = cos(omega), alpha = sin(omega) / (2 * band.q);
    const double a = pow(10, band.gainDB / 40), beta = 2 * sqrt(a) * alpha;
    double b0, b1, b2, a0, a1, a2;
    switch (band.type) {
        case EQ_PEAK:
            b0 = 1 + alpha * a; b1 = -2 * c; b2 = 1 - alpha * a;
            a0 = 1 + alpha / a; a1 = -2 * c; a2 = 1 - alpha / a;
            break;
        case EQ_LOW_SHELF:
            b0 = a * ((a + 1) - (a - 1) * c + beta);
            b1 = 2 * a * ((a - 1) - (a + 1) * c);
            b2 = a * ((a + 1) - (a - 1) * c - beta);
            a0 = (a + 1) + (a - 1) * c + beta;
            a1 = -2 * ((a - 1) + (a + 1) * c);
            a2 = (a + 1) + (a - 1) * c - beta;
            break;
        case EQ_HIGH_SHELF:
            b0 = a * ((a + 1) + (a - 1) * c + beta);
            b1 = -2 * a * ((a - 1) + (a + 1) * c);
            b2 = a * ((a + 1) + (a - 1) * c - beta);
            a0 = (a + 1) - (a - 1) * c + beta;
            a1 = 2 * ((a - 1) - (a + 1) * c);
            a2 = (a + 1) - (a - 1) * c - beta;
            break;
        case EQ_LOW_PASS:
            b0 = (1 - c) / 2; b1 = 1 - c; b2 = b0;
            a0 = 1 + alpha; a1 = -2 * c; a2 = 1 - alpha;
            break;
        case EQ_HIGH_PASS:
            b0 = (1 + c) / 2; b1 = -(1 + c); b2 = b0;
            a0 = 1 + alpha; a1 = -2 * c; a2 = 1 - alpha;
            break;
        default: // EQ_NOTCH
            b0 = 1; b1 = -2 * c; b2 = 1;
            a0 = 1 + alpha; a1 = -2 * c; a2 = 1 - alpha;
            break;
    }
    const double result[5] = {b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0};
    for (int i = 0; i < 5; i++) if (!isfinite(result[i])) return false;
    // Strict Jury stability check on z^2 + a1*z + a2.
    if (fabs(result[4]) >= 1 || 1 + result[3] + result[4] <= 0 ||
        1 - result[3] + result[4] <= 0) return false;
    memcpy(out, result, sizeof(result));
    return true;
}

double eq_response_db(EQBand band, double sampleRate, double frequency) {
    double c[5];
    if (!isfinite(frequency) || frequency < 0 || frequency > sampleRate / 2 ||
        !eq_coefficients(band, sampleRate, c)) return NAN;
    const double w = 2 * M_PI * frequency / sampleRate;
    const double reN = c[0] + c[1] * cos(w) + c[2] * cos(2 * w);
    const double imN = -c[1] * sin(w) - c[2] * sin(2 * w);
    const double reD = 1 + c[3] * cos(w) + c[4] * cos(2 * w);
    const double imD = -c[3] * sin(w) - c[4] * sin(2 * w);
    return 20 * log10(hypot(reN, imN) / hypot(reD, imD));
}

EQDSP *eq_dsp_create(double sampleRate, uint32_t maxFrames) {
    if (!valid_sample_rate(sampleRate) || !maxFrames || maxFrames > 65536) return NULL;
    EQDSP *dsp = calloc(1, sizeof(*dsp));
    if (!dsp) return NULL;
    dsp->scratch[0] = calloc(maxFrames, sizeof(float));
    dsp->scratch[1] = calloc(maxFrames, sizeof(float));
    if (!dsp->scratch[0] || !dsp->scratch[1]) { eq_dsp_destroy(dsp); return NULL; }
    dsp->sampleRate = sampleRate;
    dsp->maxFrames = maxFrames;
    dsp->fadeFrames = (uint32_t)ceil(sampleRate * 0.020);
    dsp->banks[0].parameters.gain = dsp->banks[1].parameters.gain = 1;
    dsp->writerSlot = 0;
    dsp->readerSlot = 1;
    atomic_init(&dsp->middleSlot, 2);
    atomic_init(&dsp->peakBits, 0);
    atomic_init(&dsp->clipping, 0);
    atomic_init(&dsp->analysisState, 0);
    return dsp;
}

void eq_dsp_destroy(EQDSP *dsp) {
    if (!dsp) return;
    free(dsp->scratch[0]);
    free(dsp->scratch[1]);
    free(dsp);
}

bool eq_dsp_set_parameters(EQDSP *dsp, const EQParameters *parameters) {
    if (!dsp || !parameters || parameters->count > EQ_MAX_BANDS ||
        parameters->bypass > 1 || !isfinite(parameters->preampDB) ||
        parameters->preampDB < -60 || parameters->preampDB > 12) return false;
    Prepared next = {0};
    next.gain = parameters->bypass ? 1 : pow(10, parameters->preampDB / 20);
    for (uint32_t i = 0; i < parameters->count; i++) {
        double c[5];
        EQBand band = parameters->bands[i];
        if (band.enabled > 1) return false;
        if (parameters->bypass) band.enabled = 0;
        if (!eq_coefficients(band, dsp->sampleRate, c)) return false;
        if (!parameters->bypass && (c[0] != 1 || c[1] != 0 || c[2] != 0 ||
                                   c[3] != 0 || c[4] != 0))
            memcpy(next.coefficients[next.count++], c, sizeof(c));
    }
    dsp->slots[dsp->writerSlot] = next;
    dsp->writerSlot = atomic_exchange_explicit(&dsp->middleSlot,
                       dsp->writerSlot | DIRTY, memory_order_acq_rel) & SLOT_MASK;
    return true;
}

static void receive_parameters(EQDSP *dsp) {
    if (!(atomic_load_explicit(&dsp->middleSlot, memory_order_acquire) & DIRTY)) return;
    dsp->readerSlot = atomic_exchange_explicit(&dsp->middleSlot, dsp->readerSlot,
                                              memory_order_acq_rel) & SLOT_MASK;
    dsp->pending = dsp->slots[dsp->readerSlot];
    dsp->hasPending = true;
}

static void begin_transition(EQDSP *dsp) {
    if (dsp->fading || !dsp->hasPending) return;
    dsp->hasPending = false;
    Bank *active = &dsp->banks[dsp->activeBank];
    if (active->parameters.count == dsp->pending.count &&
        active->parameters.gain == dsp->pending.gain &&
        !memcmp(active->parameters.coefficients, dsp->pending.coefficients,
                dsp->pending.count * sizeof(dsp->pending.coefficients[0]))) return;
    Bank *target = &dsp->banks[1 - dsp->activeBank];
    memset(target, 0, sizeof(*target));
    target->parameters = dsp->pending;
    // Preserve history only when the prefix feeding a stage is identical.
    if (active->parameters.gain == target->parameters.gain) {
        uint32_t common = active->parameters.count < target->parameters.count ?
                          active->parameters.count : target->parameters.count;
        for (uint32_t i = 0; i < common; i++) {
            if (memcmp(active->parameters.coefficients[i], target->parameters.coefficients[i],
                       sizeof(target->parameters.coefficients[i]))) break;
            for (int ch = 0; ch < 2; ch++)
                memcpy(target->state[ch][i], active->state[ch][i], sizeof(target->state[ch][i]));
        }
    }
    dsp->fadePosition = 0;
    dsp->fading = true;
}

static double render_bank(Bank *bank, int ch, double x, bool *fault) {
    x *= bank->parameters.gain;
    for (uint32_t i = 0; i < bank->parameters.count; i++) {
        const double *c = bank->parameters.coefficients[i];
        double *z = bank->state[ch][i];
        const double y = c[0] * x + z[0];
        const double z0 = c[1] * x - c[3] * y + z[1];
        const double z1 = c[2] * x - c[4] * y;
        if (!isfinite(y) || !isfinite(z0) || !isfinite(z1)) {
            z[0] = z[1] = 0;
            x = 0;
            *fault = true;
        } else {
            // Flush inaudible tails before they enter expensive denormal arithmetic.
            z[0] = fabs(z0) < 1e-30 ? 0 : z0;
            z[1] = fabs(z1) < 1e-30 ? 0 : z1;
            x = y;
        }
    }
    return x;
}

void eq_dsp_process(EQDSP *dsp, const float *inL, const float *inR,
                    uint32_t inStride, float *outL, float *outR,
                    uint32_t outStride, uint32_t frames) {
    if (!dsp || !outL || !outR || !inStride || !outStride || !frames) return;
    receive_parameters(dsp);
    bool analyzing = atomic_load_explicit(&dsp->analysisState, memory_order_acquire) == 1;
    float peak = 0;
    bool fault = false;
    const float lower = -1, upper = 1;
    for (uint32_t start = 0; start < frames;) {
        const uint32_t length = frames - start < dsp->maxFrames ? frames - start : dsp->maxFrames;
        for (uint32_t frame = 0; frame < length; frame++) {
            begin_transition(dsp);
            const size_t index = ((size_t)start + frame) * inStride;
            double input[2] = {inL ? inL[index] : 0, inR ? inR[index] : (inL ? inL[index] : 0)};
            // Double-bank output crossfade keeps both sets of poles stable.
            const double mix = dsp->fading ? (double)(dsp->fadePosition + 1) / dsp->fadeFrames : 0;
            for (int ch = 0; ch < 2; ch++) {
                if (!isfinite(input[ch])) { input[ch] = 0; fault = true; }
                double y = render_bank(&dsp->banks[dsp->activeBank], ch, input[ch], &fault);
                if (dsp->fading) {
                    const double target = render_bank(&dsp->banks[1 - dsp->activeBank], ch, input[ch], &fault);
                    y += (target - y) * mix;
                }
                if (!isfinite(y)) { y = 0; fault = true; }
                dsp->scratch[ch][frame] = (float)fmax(-FLT_MAX, fmin(FLT_MAX, y));
                if (analyzing) {
                    dsp->analysis[ch][dsp->analysisPosition] = (float)input[ch];
                    dsp->analysis[ch + 2][dsp->analysisPosition] = fmaxf(-1, fminf(1, dsp->scratch[ch][frame]));
                }
            }
            if (analyzing && ++dsp->analysisPosition == EQ_ANALYSIS_FRAMES) {
                dsp->analysisPosition = 0;
                atomic_store_explicit(&dsp->analysisState, 2, memory_order_release);
                analyzing = false;
            }
            if (dsp->fading && ++dsp->fadePosition >= dsp->fadeFrames) {
                dsp->activeBank = 1 - dsp->activeBank;
                dsp->fading = false;
            }
        }
        float channelPeak;
        vDSP_maxmgv(dsp->scratch[0], 1, &channelPeak, length);
        peak = fmaxf(peak, channelPeak);
        vDSP_maxmgv(dsp->scratch[1], 1, &channelPeak, length);
        peak = fmaxf(peak, channelPeak);
        vDSP_vclip(dsp->scratch[0], 1, &lower, &upper, outL + (size_t)start * outStride, outStride, length);
        vDSP_vclip(dsp->scratch[1], 1, &lower, &upper, outR + (size_t)start * outStride, outStride, length);
        start += length;
    }
    uint32_t bits;
    memcpy(&bits, &peak, sizeof(bits));
    atomic_store_explicit(&dsp->peakBits, bits, memory_order_relaxed);
    if (peak > 1 || fault) atomic_store_explicit(&dsp->clipping, 1, memory_order_relaxed);
}

float eq_dsp_peak(EQDSP *dsp) {
    if (!dsp) return 0;
    uint32_t bits = atomic_load_explicit(&dsp->peakBits, memory_order_relaxed);
    float peak;
    memcpy(&peak, &bits, sizeof(peak));
    return peak;
}

bool eq_dsp_take_clipping(EQDSP *dsp) {
    return dsp && atomic_exchange_explicit(&dsp->clipping, 0, memory_order_relaxed) != 0;
}

void eq_dsp_request_analysis(EQDSP *dsp) {
    if (!dsp) return;
    unsigned expected = 0;
    atomic_compare_exchange_strong_explicit(&dsp->analysisState, &expected, 1,
                                            memory_order_release, memory_order_relaxed);
}

bool eq_dsp_read_analysis(EQDSP *dsp, float *channels, uint32_t capacity) {
    if (!dsp || !channels || capacity < 4 * EQ_ANALYSIS_FRAMES ||
        atomic_load_explicit(&dsp->analysisState, memory_order_acquire) != 2) return false;
    memcpy(channels, dsp->analysis, sizeof(dsp->analysis));
    atomic_store_explicit(&dsp->analysisState, 0, memory_order_release);
    return true;
}
