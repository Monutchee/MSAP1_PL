#ifndef SIM_WAVE_ENGINE_HPP
#define SIM_WAVE_ENGINE_HPP

// The request beat is 1152 bits, past ap_int's 1024 default; raise the
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
static const int SIM_WAVE_REQ_BITS            = 1152; // 144 bytes on AXIS

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
