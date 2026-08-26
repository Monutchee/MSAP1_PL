#ifndef SIM_WAVE_ENGINE_HPP
#define SIM_WAVE_ENGINE_HPP

// The request beat is 1568 bits, past ap_int's 1024 default; raise the
// ceiling before the first ap_int.h include in every translation unit
// (the build also passes -DAP_INT_MAX_W as belt and braces).
#ifndef AP_INT_MAX_W
#define AP_INT_MAX_W 2048
#endif
#if AP_INT_MAX_W < 2048
#error "AP_INT_MAX_W was fixed below 2048 by an earlier include"
#endif

#include <ap_int.h>
#include <hls_stream.h>

// The ADC simulator waveform engine (normative source). It is the HLS
// rewrite of the sine datapath that used to live inline in
// adc_simulator.vhd (256-entry full-wave LUT indexed by the top 8 phase
// bits; in git history). The VHDL block keeps everything deterministic --
// the AXI-Lite register file with its shadow/APPLY banks, the fractional
// sample-rate scheduler, the Q0.32 phase accumulator, AXIS framing/TLAST
// and backpressure accounting -- and delegates only the per-frame sample
// mathematics here:
//
//   s_request : one beat per due frame (layout below), packed by
//               adc_simulator.vhd in lock step from the ACTIVE bank and
//               the frame's base phase.
//   m_frame   : one beat per request -- eight sign-extended 24-bit
//               samples plus per-channel saturation flags. Exactly one
//               response per request, always, so the VHDL scheduler can
//               keep its single-frame pending accounting.
//
// Waveform math (per enabled channel):
//   angle   : base_phase + channel phase offset, unsigned Q0.32 turns
//   sine    : quarter-wave LUT (1025 x Q1.17 entries = 4096 points per
//             cycle) with 12-bit linear interpolation between points.
//             Worst-case sine error is bounded by the table quantization
//             (2^-18 of full scale) plus the interpolation sagitta
//             ((2*pi/4096)^2 / 8 ~ 2.9e-7): spurs below -100 dBc, phase
//             resolution 2*pi/2^24. The legacy 8-bit-indexed table sat at
//             -48 dBc / 1.4 degrees, unusable for PF/phasor validation.
//   scale   : (peak * sine) >>> 17, arithmetic shift (floor), preserving
//             the legacy table's amplitude convention: peak counts map to
//             peak * 131071/131072 output counts.
//   dc      : signed DC offset counts added after scaling.
//   harmonics: up to four global slots, each adding fraction * peak *
//             sin(ratio * angle + slot phase) to the lanes its channel
//             mask selects (layout below). The Q16.16 frequency ratio is
//             an integer for harmonics and fractional for interharmonics;
//             the lane phase offset scales by that same ratio.
//   event   : a timed amplitude envelope from the VHDL event sequencer.
//             The Q16 scale multiplies the PEAK of every channel the
//             event mask selects, before the sine and before the
//             harmonic slots -- so injected distortion rides the dip the
//             way it does on a real grid, while DC offset and noise (ADC
//             artifacts, not grid quantities) are untouched. Unity scale
//             or an empty mask is exactly the pre-event datapath. The
//             sequencing (arm, half-cycle alignment, duration, repeat)
//             is deterministic infrastructure and stays in
//             adc_simulator.vhd; only the multiply is here.
//   noise   : uniform white fluctuation of +/- noise_level counts, so
//             simulated readings jitter like a real grid input instead of
//             sitting bit-flat. The noise word is a splitmix-style hash
//             of (frame_index, lane) -- deterministic and reproducible
//             bit-exactly by golden models, white across frames, and
//             uncorrelated between channels. noise_level is an unsigned
//             24-bit amplitude in counts; 0 disables the path. (The
//             uniform distribution's RMS is level / sqrt(3).)
//   clamp   : to the signed 24-bit rails [-8388608, 8388607]; a clamped
//             channel sets its saturation flag for the VHDL counter.
//   masked  : a channel with its valid-mask bit clear emits exactly 0 --
//             no sine, no DC, no noise, no saturation flag (frame
//             geometry is constant; disabled channels are zero beats,
//             never skipped).
//
// The engine is stateless: identical requests produce identical
// responses (noise randomness rides on the frame index the VHDL supplies,
// not on hidden PRNG state). All sequencing state (phase accumulator,
// packet framing, APPLY commits) stays in adc_simulator.vhd, so
// csim/cosim here verify pure math against a golden model: sine within a
// documented tolerance, noise/DC/clamp bit-exactly.

// ---------------------------------------------------------------------------
// Request beat: the ACTIVE configuration snapshot travelling with the
// frame's base phase. Every field is byte aligned; [MSB:LSB] positions
// are normative and adc_simulator.vhd mirrors them.
// ---------------------------------------------------------------------------
static const int SIM_WAVE_CHANNELS = 8;

static const int SIM_WAVE_REQ_BASE_PHASE_LSB  = 0;    // [31:0]     Q0.32 turns
static const int SIM_WAVE_REQ_VALID_MASK_LSB  = 32;   // [39:32]    channel enables
                                                      // [63:40]    reserved zero
static const int SIM_WAVE_REQ_FRAME_INDEX_LSB = 64;   // [95:64]    noise sequence input
                                                      // [127:96]   reserved zero
static const int SIM_WAVE_REQ_PEAK_LSB        = 128;  // [383:128]  8 x s24 in s32
static const int SIM_WAVE_REQ_PHASE_LSB       = 384;  // [639:384]  8 x Q0.32 turns
static const int SIM_WAVE_REQ_DC_LSB          = 640;  // [895:640]  8 x s24 in s32
static const int SIM_WAVE_REQ_NOISE_LSB       = 896;  // [1151:896] 8 x u24 in u32
// Four global harmonic/interharmonic slots (M16), each 96 bits / 3 words:
//   [31:0]  frequency/order ratio, unsigned Q16.16 (0 disables)
//   [39:32] channel mask (which lanes receive the tone)
//   [47:40] reserved zero
//   [63:48] amplitude as a Q16 fraction of the lane's fundamental peak
//   [95:64] phase offset, Q0.32 turns, on top of the physical rule below
// A tone's angle is ratio * (base_phase + lane phase) + slot phase. Integer
// order 3 therefore keeps the physical zero-sequence rule; ratio 3.1 creates
// an interharmonic whose lane relationship follows its actual frequency.
static const int SIM_WAVE_REQ_HARMONIC_LSB    = 1152;
static const int SIM_WAVE_HARMONIC_SLOTS      = 4;
// Event envelope (M12), one word:
//   [18:0]  unsigned Q16 amplitude scale, 0x10000 = unity, capped at 4.0
//   [23:19] reserved zero
//   [31:24] channel mask (which lanes the envelope multiplies)
// A unity scale or an empty mask leaves the frame bit-identical to the
// pre-event datapath, so a quiet simulator is unaffected by this field.
static const int SIM_WAVE_REQ_EVENT_LSB       = 1536;
static const int SIM_WAVE_REQ_EVENT_SCALE_LSB = 1536;
static const int SIM_WAVE_REQ_EVENT_MASK_LSB  = 1560;
static const int SIM_WAVE_EVENT_SCALE_UNITY   = 0x10000;
static const int SIM_WAVE_REQ_BITS            = 1568; // 196 bytes on AXIS

// Response beat: one converted frame.
static const int SIM_WAVE_RSP_SAMPLE_LSB     = 0;    // [255:0]   8 x s24 in s32
static const int SIM_WAVE_RSP_SATURATED_LSB  = 256;  // [263:256] per-channel clamp
static const int SIM_WAVE_RSP_BITS           = 264;  // 33 bytes on AXIS

typedef ap_uint<SIM_WAVE_REQ_BITS> sim_wave_request_t;
typedef ap_uint<SIM_WAVE_RSP_BITS> sim_wave_response_t;

// Signed 24-bit output rails (the ADC count range of the raw stream).
static const int SIM_WAVE_SAMPLE_MAX = 8388607;
static const int SIM_WAVE_SAMPLE_MIN = -8388608;

void hls_sim_wave_engine(hls::stream<sim_wave_request_t> &s_request,
                         hls::stream<sim_wave_response_t> &m_frame);

#endif  // SIM_WAVE_ENGINE_HPP
