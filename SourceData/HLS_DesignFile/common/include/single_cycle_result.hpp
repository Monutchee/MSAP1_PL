#ifndef MSAP1_SINGLE_CYCLE_RESULT_HPP
#define MSAP1_SINGLE_CYCLE_RESULT_HPP

// metering_types.hpp first: it raises AP_INT_MAX_W before ap_int.h.
#include "metering_types.hpp"

#include <ap_int.h>

#if AP_INT_MAX_W < 8192
#error "single_cycle_result.hpp needs AP_INT_MAX_W >= 8192 (7072-bit logical image)"
#endif

// The single-cycle measurement result — one value per complete,
// non-overlapping grid cycle, produced by the single-cycle engine and
// consumed by the R5C1 interval service. This is the reusable-primitive
// contract of the metrology redesign: higher tiers merge these sufficient
// statistics; they never re-derive them from samples.
//
// M2 defined the timing/provenance section (bits 0..511); M3 appends the
// statistics sections below. Power (M4) and phasor (M5) sections APPEND
// after SCYC_BEAT_BITS in the same way. SCYC_BEAT_BITS describes the logical
// packed image retained for golden/equivalence tests. The physical HLS-to-HLS
// boundary is the ordered 32-bit packet in single_cycle_packet.hpp, so growing
// this value is a lock-step internal-contract change, not an external wire ABI
// change.
//
// STATISTICS WIDTH ANALYSIS (normative — the M3 "do not guess" rule).
// The per-lane accumulators use the LEGACY BLOCK widths on purpose:
// sum ap_int<128>, square ap_uint<128> (saturating, sticky flag),
// raw_sum ap_int<64>, raw_square ap_uint<96>. The 10/12-cycle tier (M7)
// merges cycles by plain addition, and integer addition of per-cycle
// accumulators reconstructs the legacy Basic block accumulators exactly:
// that bit identity is the acceptance proof for the current engine.
// A per-cycle square CAN saturate only in configurations where the block
// accumulator would saturate too; both paths raise the sticky arithmetic
// flag, so any divergence is confined to already-flagged results.
// Line-line differences: Va-Vb of two 64-bit Q16 samples needs 65 bits;
// the difference is defensively clamped to the 64-bit rails (flagging),
// unreachable with real 24-bit-derived samples, keeping the square in
// the same 128-bit saturating domain as the phase lanes.
//
// Timestamps (handover §3): first/last_sample anchor the measurement to
// the conversion-domain sample index (the measurement timebase — never
// reset, never stepped); processing_tick is the free-running PL tick at
// emission, the same counter the waveform correlation block maps to UTC.
// measurement != processing by design.
//
// The APPLY convention matches basic_result_beat.hpp: the producer
// samples the config APPLY toggle level into every beat; a level change
// between consecutive beats is the consumer's APPLY event.

// Engine status word bits (the beat's status field and record word 8).
// Bits 2..4 are the handover's validity/generation contract: results
// never span a discontinuity, and the first WHOLE cycle emitted after
// one says so, with its cause. A window interrupted by reset, APPLY,
// malformed input, a sample-index jump (dropped beat), or cycle-timing
// loss is discarded, never emitted.
static const int SCYC_STATUS_OVERFLOW_BIT        = 0;  // accumulator clamped
static const int SCYC_STATUS_PHASOR_INVALID_BIT  = 1;  // no frequency reference
static const int SCYC_STATUS_FIRST_AFTER_GAP_BIT = 2;  // first result after a discontinuity
static const int SCYC_STATUS_GAP_MALFORMED_BIT   = 3;  // cause included malformed/dropped frames
static const int SCYC_STATUS_GAP_TIMING_BIT      = 4;  // cause included cycle-timing loss

static const int SCYC_SEQUENCE_LSB     = 0;    // [31:0]    result sequence
static const int SCYC_GENERATION_LSB   = 32;   // [63:32]   config generation
static const int SCYC_FIRST_SAMPLE_LSB = 64;   // [127:64]  cycle's first index
static const int SCYC_LAST_SAMPLE_LSB  = 128;  // [191:128] cycle's last index
static const int SCYC_SAMPLE_COUNT_LSB = 192;  // [223:192] samples in the cycle
static const int SCYC_CYCLE_SEQ_LSB    = 224;  // [255:224] grid cycle sequence
static const int SCYC_NOMINAL_HZ_LSB   = 256;  // [263:256] declared nominal
static const int SCYC_VALID_MASK_LSB   = 264;  // [271:264] channel enablement
static const int SCYC_FLAGS_LSB        = 272;  // [274:272] MET_FLAG_* (in a byte)
static const int SCYC_STATUS_LSB       = 288;  // [319:288] engine status word
static const int SCYC_FREQ_LSB         = 320;  // [351:320] frequency, millihertz
static const int SCYC_FREQ_VALID_BIT   = 352;  // frequency_valid
static const int SCYC_APPLY_TOGGLE_BIT = 353;  // config APPLY toggle level
static const int SCYC_PROC_TICK_LSB    = 384;  // [447:384] PL tick at emission
                                               // [511:448] reserved zero

// --- M3 statistics sections (per-lane arrays over MET_ACTIVE_CHANNELS,
// --- stride = the field width; VLL arrays over MET_VLL_PAIRS) ----------
static const int SCYC_STAT_SUM_LSB        = 512;   // 7 x s128 Q16 sum
static const int SCYC_STAT_SQUARE_LSB     = 1408;  // 7 x u128 Q32 square sum
static const int SCYC_STAT_RAW_SUM_LSB    = 2304;  // 7 x s64 raw sum
static const int SCYC_STAT_RAW_SQUARE_LSB = 2752;  // 7 x u96 raw square sum
static const int SCYC_STAT_MIN_LSB        = 3424;  // 7 x s64 Q16 minimum
static const int SCYC_STAT_MAX_LSB        = 3872;  // 7 x s64 Q16 maximum
static const int SCYC_STAT_VLL_SQUARE_LSB = 4320;  // 3 x u128 diff square sum
static const int SCYC_STAT_VLL_PEAK_LSB   = 4704;  // 3 x u64 peak |diff|

// --- M4 power section (phases A/B/C; see the sign conventions and the
// --- Q32/picowatt unit chain in metering_types.hpp). The 128-bit signed
// --- saturating sum mirrors the square accumulator's analysis: a single
// --- contract-max product occupies 126 bits, real products stay below
// --- 2^80, and the 10/12-cycle merge stays a pure addition. -------------
static const int SCYC_POWER_SUM_LSB       = 4896;  // 3 x s128 sum(v*i) Q32

// --- M5 phasor section: fundamental correlation sums in the raw Q1.37
// --- trig domain (see phasor_core.hpp; products <= 2^102, cycle sums
// --- < 2^116, so the 128-bit signed saturating width has >= 11 bits of
// --- headroom and the 10/12-cycle merge stays a pure addition). --------
static const int SCYC_PHASOR_RE_LSB       = 5280;  // 7 x s128
static const int SCYC_PHASOR_IM_LSB       = 6176;  // 7 x s128
static const int SCYC_BEAT_BITS           = 7072;  // 884-byte logical image

typedef ap_uint<SCYC_BEAT_BITS> single_cycle_beat_t;

// Unpacked view; pack/unpack are explicit wired bit selects (the
// aggregation-trial area lesson — no barrel shifting).
struct single_cycle_result_t {
  met_word32_t       sequence;
  met_word32_t       generation;
  met_sample_index_t first_sample;
  met_sample_index_t last_sample;
  met_word32_t       sample_count;
  met_word32_t       cycle_sequence;
  ap_uint<8>         nominal_hz;
  ap_uint<8>         valid_mask;
  ap_uint<MET_FLAG_BITS> flags;
  met_word32_t       status;
  met_word32_t       frequency_millihz;
  ap_uint<1>         frequency_valid;
  ap_uint<1>         apply_toggle;
  ap_uint<64>        processing_tick;
  ap_int<128>        sum[MET_ACTIVE_CHANNELS];
  ap_uint<128>       square[MET_ACTIVE_CHANNELS];
  ap_int<64>         raw_sum[MET_ACTIVE_CHANNELS];
  ap_uint<96>        raw_square[MET_ACTIVE_CHANNELS];
  ap_int<64>         minimum[MET_ACTIVE_CHANNELS];
  ap_int<64>         maximum[MET_ACTIVE_CHANNELS];
  ap_uint<128>       vll_square[MET_VLL_PAIRS];
  ap_uint<64>        vll_peak[MET_VLL_PAIRS];
  ap_int<128>        power_sum[MET_POWER_PHASES];
  ap_int<128>        phasor_re[MET_ACTIVE_CHANNELS];
  ap_int<128>        phasor_im[MET_ACTIVE_CHANNELS];
};

inline single_cycle_beat_t pack_single_cycle_result(const single_cycle_result_t &r) {
#pragma HLS INLINE
  single_cycle_beat_t beat = 0;
  beat.range(SCYC_SEQUENCE_LSB + 31, SCYC_SEQUENCE_LSB)         = r.sequence;
  beat.range(SCYC_GENERATION_LSB + 31, SCYC_GENERATION_LSB)     = r.generation;
  beat.range(SCYC_FIRST_SAMPLE_LSB + 63, SCYC_FIRST_SAMPLE_LSB) = r.first_sample;
  beat.range(SCYC_LAST_SAMPLE_LSB + 63, SCYC_LAST_SAMPLE_LSB)   = r.last_sample;
  beat.range(SCYC_SAMPLE_COUNT_LSB + 31, SCYC_SAMPLE_COUNT_LSB) = r.sample_count;
  beat.range(SCYC_CYCLE_SEQ_LSB + 31, SCYC_CYCLE_SEQ_LSB)       = r.cycle_sequence;
  beat.range(SCYC_NOMINAL_HZ_LSB + 7, SCYC_NOMINAL_HZ_LSB)      = r.nominal_hz;
  beat.range(SCYC_VALID_MASK_LSB + 7, SCYC_VALID_MASK_LSB)      = r.valid_mask;
  beat.range(SCYC_FLAGS_LSB + MET_FLAG_BITS - 1, SCYC_FLAGS_LSB) = r.flags;
  beat.range(SCYC_STATUS_LSB + 31, SCYC_STATUS_LSB)             = r.status;
  beat.range(SCYC_FREQ_LSB + 31, SCYC_FREQ_LSB)                 = r.frequency_millihz;
  beat[SCYC_FREQ_VALID_BIT]                                     = r.frequency_valid;
  beat[SCYC_APPLY_TOGGLE_BIT]                                   = r.apply_toggle;
  beat.range(SCYC_PROC_TICK_LSB + 63, SCYC_PROC_TICK_LSB)       = r.processing_tick;
  for (int lane = 0; lane < MET_ACTIVE_CHANNELS; ++lane) {
#pragma HLS UNROLL
    beat.range(SCYC_STAT_SUM_LSB + lane * 128 + 127,
               SCYC_STAT_SUM_LSB + lane * 128) = r.sum[lane];
    beat.range(SCYC_STAT_SQUARE_LSB + lane * 128 + 127,
               SCYC_STAT_SQUARE_LSB + lane * 128) = r.square[lane];
    beat.range(SCYC_STAT_RAW_SUM_LSB + lane * 64 + 63,
               SCYC_STAT_RAW_SUM_LSB + lane * 64) = r.raw_sum[lane];
    beat.range(SCYC_STAT_RAW_SQUARE_LSB + lane * 96 + 95,
               SCYC_STAT_RAW_SQUARE_LSB + lane * 96) = r.raw_square[lane];
    beat.range(SCYC_STAT_MIN_LSB + lane * 64 + 63,
               SCYC_STAT_MIN_LSB + lane * 64) = r.minimum[lane];
    beat.range(SCYC_STAT_MAX_LSB + lane * 64 + 63,
               SCYC_STAT_MAX_LSB + lane * 64) = r.maximum[lane];
  }
  for (int pair = 0; pair < MET_VLL_PAIRS; ++pair) {
#pragma HLS UNROLL
    beat.range(SCYC_STAT_VLL_SQUARE_LSB + pair * 128 + 127,
               SCYC_STAT_VLL_SQUARE_LSB + pair * 128) = r.vll_square[pair];
    beat.range(SCYC_STAT_VLL_PEAK_LSB + pair * 64 + 63,
               SCYC_STAT_VLL_PEAK_LSB + pair * 64) = r.vll_peak[pair];
  }
  for (int phase = 0; phase < MET_POWER_PHASES; ++phase) {
#pragma HLS UNROLL
    beat.range(SCYC_POWER_SUM_LSB + phase * 128 + 127,
               SCYC_POWER_SUM_LSB + phase * 128) = r.power_sum[phase];
  }
  for (int lane = 0; lane < MET_ACTIVE_CHANNELS; ++lane) {
#pragma HLS UNROLL
    beat.range(SCYC_PHASOR_RE_LSB + lane * 128 + 127,
               SCYC_PHASOR_RE_LSB + lane * 128) = r.phasor_re[lane];
    beat.range(SCYC_PHASOR_IM_LSB + lane * 128 + 127,
               SCYC_PHASOR_IM_LSB + lane * 128) = r.phasor_im[lane];
  }
  return beat;
}

inline single_cycle_result_t unpack_single_cycle_result(const single_cycle_beat_t &beat) {
#pragma HLS INLINE
  single_cycle_result_t r;
  r.sequence          = beat.range(SCYC_SEQUENCE_LSB + 31, SCYC_SEQUENCE_LSB);
  r.generation        = beat.range(SCYC_GENERATION_LSB + 31, SCYC_GENERATION_LSB);
  r.first_sample      = beat.range(SCYC_FIRST_SAMPLE_LSB + 63, SCYC_FIRST_SAMPLE_LSB);
  r.last_sample       = beat.range(SCYC_LAST_SAMPLE_LSB + 63, SCYC_LAST_SAMPLE_LSB);
  r.sample_count      = beat.range(SCYC_SAMPLE_COUNT_LSB + 31, SCYC_SAMPLE_COUNT_LSB);
  r.cycle_sequence    = beat.range(SCYC_CYCLE_SEQ_LSB + 31, SCYC_CYCLE_SEQ_LSB);
  r.nominal_hz        = beat.range(SCYC_NOMINAL_HZ_LSB + 7, SCYC_NOMINAL_HZ_LSB);
  r.valid_mask        = beat.range(SCYC_VALID_MASK_LSB + 7, SCYC_VALID_MASK_LSB);
  r.flags             = beat.range(SCYC_FLAGS_LSB + MET_FLAG_BITS - 1, SCYC_FLAGS_LSB);
  r.status            = beat.range(SCYC_STATUS_LSB + 31, SCYC_STATUS_LSB);
  r.frequency_millihz = beat.range(SCYC_FREQ_LSB + 31, SCYC_FREQ_LSB);
  r.frequency_valid   = beat[SCYC_FREQ_VALID_BIT];
  r.apply_toggle      = beat[SCYC_APPLY_TOGGLE_BIT];
  r.processing_tick   = beat.range(SCYC_PROC_TICK_LSB + 63, SCYC_PROC_TICK_LSB);
  for (int lane = 0; lane < MET_ACTIVE_CHANNELS; ++lane) {
#pragma HLS UNROLL
    r.sum[lane] = beat.range(SCYC_STAT_SUM_LSB + lane * 128 + 127,
                             SCYC_STAT_SUM_LSB + lane * 128);
    r.square[lane] = beat.range(SCYC_STAT_SQUARE_LSB + lane * 128 + 127,
                                SCYC_STAT_SQUARE_LSB + lane * 128);
    r.raw_sum[lane] = beat.range(SCYC_STAT_RAW_SUM_LSB + lane * 64 + 63,
                                 SCYC_STAT_RAW_SUM_LSB + lane * 64);
    r.raw_square[lane] = beat.range(SCYC_STAT_RAW_SQUARE_LSB + lane * 96 + 95,
                                    SCYC_STAT_RAW_SQUARE_LSB + lane * 96);
    r.minimum[lane] = beat.range(SCYC_STAT_MIN_LSB + lane * 64 + 63,
                                 SCYC_STAT_MIN_LSB + lane * 64);
    r.maximum[lane] = beat.range(SCYC_STAT_MAX_LSB + lane * 64 + 63,
                                 SCYC_STAT_MAX_LSB + lane * 64);
  }
  for (int pair = 0; pair < MET_VLL_PAIRS; ++pair) {
#pragma HLS UNROLL
    r.vll_square[pair] =
        beat.range(SCYC_STAT_VLL_SQUARE_LSB + pair * 128 + 127,
                   SCYC_STAT_VLL_SQUARE_LSB + pair * 128);
    r.vll_peak[pair] = beat.range(SCYC_STAT_VLL_PEAK_LSB + pair * 64 + 63,
                                  SCYC_STAT_VLL_PEAK_LSB + pair * 64);
  }
  for (int phase = 0; phase < MET_POWER_PHASES; ++phase) {
#pragma HLS UNROLL
    r.power_sum[phase] = beat.range(SCYC_POWER_SUM_LSB + phase * 128 + 127,
                                    SCYC_POWER_SUM_LSB + phase * 128);
  }
  for (int lane = 0; lane < MET_ACTIVE_CHANNELS; ++lane) {
#pragma HLS UNROLL
    r.phasor_re[lane] = beat.range(SCYC_PHASOR_RE_LSB + lane * 128 + 127,
                                   SCYC_PHASOR_RE_LSB + lane * 128);
    r.phasor_im[lane] = beat.range(SCYC_PHASOR_IM_LSB + lane * 128 + 127,
                                   SCYC_PHASOR_IM_LSB + lane * 128);
  }
  return r;
}

#endif  // MSAP1_SINGLE_CYCLE_RESULT_HPP
