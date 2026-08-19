#ifndef MSAP1_AGG_BLOCK_RESULT_HPP
#define MSAP1_AGG_BLOCK_RESULT_HPP

// metering_types.hpp first: it raises AP_INT_MAX_W before ap_int.h.
#include "metering_types.hpp"

#include <ap_int.h>

#if AP_INT_MAX_W < 8192
#error "agg_block_result.hpp needs AP_INT_MAX_W >= 8192 (7072-bit beat)"
#endif

// The 10/12-cycle block result — one beat per finalized basic block,
// produced by Agg10_12CycleEngine and consumed by the 150/180-cycle
// aggregation tier (Agg150_180CycleEngine, roadmap M11). It replaces the
// retired 808-bit basic_result_beat: instead of finalized per-lane RMS
// values, it carries the block's MERGE-SAFE ACCUMULATORS, so the
// aggregate tier keeps the redesign's one rule — higher tiers merge
// sufficient statistics by pure addition, they never re-derive and never
// average finalized values. The width analysis is inherited from
// single_cycle_result.hpp and holds with 15x block sums:
//   square u128: 96000 samples x (2^40)^2 products < 2^97 (saturating);
//   power  s128: < 2^97 real, saturating at contract-max;
//   phasor s128: < 2^94 real, saturating at contract-max.
//
// The accumulator sections sit at the SAME bit offsets as the
// single-cycle beat's (SCYC_STAT_* / SCYC_POWER_* / SCYC_PHASOR_*), and
// the beat is the same 7072 bits — deliberate: one wire shape for both
// merge boundaries. Only the provenance section (bits 0..511) differs.
//
// Provenance carries everything the aggregation rules need, INCLUDING
// the committed configuration (generation, sample rate, dc_remove) and
// the APPLY toggle level — so the hosting shim is pure hosting with no
// config ports, exactly like the retired mtr2 shim.
//
// This beat has exactly one producer and one consumer inside this
// repository: growing it is a lock-step header change, never a
// wire-compatibility event.

static const int AGGB_SEQUENCE_LSB     = 0;    // [31:0]    block sequence
static const int AGGB_GENERATION_LSB   = 32;   // [63:32]   committed generation
static const int AGGB_FIRST_SAMPLE_LSB = 64;   // [127:64]  block's first index
static const int AGGB_LAST_SAMPLE_LSB  = 128;  // [191:128] block's last index
static const int AGGB_SAMPLE_COUNT_LSB = 192;  // [223:192] samples in the block
static const int AGGB_SAMPLE_RATE_LSB  = 224;  // [255:224] committed frames/s
static const int AGGB_NOMINAL_HZ_LSB   = 256;  // [263:256] declared nominal
static const int AGGB_VALID_MASK_LSB   = 264;  // [271:264] block channel mask
static const int AGGB_FLAGS_LSB        = 272;  // [274:272] MET_FLAG_* (in a byte)
static const int AGGB_CYCLE_COUNT_LSB  = 280;  // [287:280] cycles in the block
static const int AGGB_STATUS_LSB       = 288;  // [319:288] block status word
static const int AGGB_FREQ_LSB         = 320;  // [351:320] frequency, millihertz
static const int AGGB_FREQ_VALID_BIT   = 352;  // block-close frequency valid
static const int AGGB_APPLY_TOGGLE_BIT = 353;  // config APPLY toggle (level)
static const int AGGB_DC_REMOVE_BIT    = 354;  // committed dc_remove
                                               // [511:355] reserved zero

// --- Accumulator sections: bit-for-bit the single-cycle beat's offsets
// --- (single_cycle_result.hpp is normative for the interior layouts). --
static const int AGGB_SUM_LSB        = 512;   // 7 x s128 Q16 sum
static const int AGGB_SQUARE_LSB     = 1408;  // 7 x u128 Q32 square sum
static const int AGGB_RAW_SUM_LSB    = 2304;  // 7 x s64 raw sum
static const int AGGB_RAW_SQUARE_LSB = 2752;  // 7 x u96 raw square sum
static const int AGGB_MIN_LSB        = 3424;  // 7 x s64 Q16 minimum
static const int AGGB_MAX_LSB        = 3872;  // 7 x s64 Q16 maximum
static const int AGGB_VLL_SQUARE_LSB = 4320;  // 3 x u128 diff square sum
static const int AGGB_VLL_PEAK_LSB   = 4704;  // 3 x u64 peak |diff| (unused
                                              //   by the aggregate; kept so
                                              //   the offsets stay congruent)
static const int AGGB_POWER_SUM_LSB  = 4896;  // 3 x s128 sum(v*i) Q32
static const int AGGB_PHASOR_RE_LSB  = 5280;  // 7 x s128
static const int AGGB_PHASOR_IM_LSB  = 6176;  // 7 x s128
static const int AGGB_BEAT_BITS      = 7072;  // 884 bytes on AXIS

typedef ap_uint<AGGB_BEAT_BITS> agg_block_beat_t;

// Unpacked view; pack/unpack are explicit wired bit selects.
struct agg_block_result_t {
  met_word32_t       sequence;
  met_word32_t       generation;
  met_sample_index_t first_sample;
  met_sample_index_t last_sample;
  met_word32_t       sample_count;
  met_word32_t       sample_rate_hz;
  ap_uint<8>         nominal_hz;
  ap_uint<8>         valid_mask;
  ap_uint<MET_FLAG_BITS> flags;
  ap_uint<8>         cycle_count;
  met_word32_t       status;
  met_word32_t       frequency_millihz;
  ap_uint<1>         frequency_valid;
  ap_uint<1>         apply_toggle;
  ap_uint<1>         dc_remove;
  ap_int<128>        sum[MET_ACTIVE_CHANNELS];
  ap_uint<128>       square[MET_ACTIVE_CHANNELS];
  ap_int<64>         raw_sum[MET_ACTIVE_CHANNELS];
  ap_uint<96>        raw_square[MET_ACTIVE_CHANNELS];
  ap_int<64>         minimum[MET_ACTIVE_CHANNELS];
  ap_int<64>         maximum[MET_ACTIVE_CHANNELS];
  ap_uint<128>       vll_square[MET_VLL_PAIRS];
  ap_int<128>        power_sum[MET_POWER_PHASES];
  ap_int<128>        phasor_re[MET_ACTIVE_CHANNELS];
  ap_int<128>        phasor_im[MET_ACTIVE_CHANNELS];
};

inline agg_block_beat_t pack_agg_block_result(const agg_block_result_t &r) {
#pragma HLS INLINE
  agg_block_beat_t beat = 0;
  beat.range(AGGB_SEQUENCE_LSB + 31, AGGB_SEQUENCE_LSB)         = r.sequence;
  beat.range(AGGB_GENERATION_LSB + 31, AGGB_GENERATION_LSB)     = r.generation;
  beat.range(AGGB_FIRST_SAMPLE_LSB + 63, AGGB_FIRST_SAMPLE_LSB) = r.first_sample;
  beat.range(AGGB_LAST_SAMPLE_LSB + 63, AGGB_LAST_SAMPLE_LSB)   = r.last_sample;
  beat.range(AGGB_SAMPLE_COUNT_LSB + 31, AGGB_SAMPLE_COUNT_LSB) = r.sample_count;
  beat.range(AGGB_SAMPLE_RATE_LSB + 31, AGGB_SAMPLE_RATE_LSB)   = r.sample_rate_hz;
  beat.range(AGGB_NOMINAL_HZ_LSB + 7, AGGB_NOMINAL_HZ_LSB)      = r.nominal_hz;
  beat.range(AGGB_VALID_MASK_LSB + 7, AGGB_VALID_MASK_LSB)      = r.valid_mask;
  beat.range(AGGB_FLAGS_LSB + MET_FLAG_BITS - 1, AGGB_FLAGS_LSB) = r.flags;
  beat.range(AGGB_CYCLE_COUNT_LSB + 7, AGGB_CYCLE_COUNT_LSB)    = r.cycle_count;
  beat.range(AGGB_STATUS_LSB + 31, AGGB_STATUS_LSB)             = r.status;
  beat.range(AGGB_FREQ_LSB + 31, AGGB_FREQ_LSB)                 = r.frequency_millihz;
  beat[AGGB_FREQ_VALID_BIT]                                     = r.frequency_valid;
  beat[AGGB_APPLY_TOGGLE_BIT]                                   = r.apply_toggle;
  beat[AGGB_DC_REMOVE_BIT]                                      = r.dc_remove;
  for (int lane = 0; lane < MET_ACTIVE_CHANNELS; ++lane) {
#pragma HLS UNROLL
    beat.range(AGGB_SUM_LSB + lane * 128 + 127, AGGB_SUM_LSB + lane * 128) =
        r.sum[lane];
    beat.range(AGGB_SQUARE_LSB + lane * 128 + 127,
               AGGB_SQUARE_LSB + lane * 128) = r.square[lane];
    beat.range(AGGB_RAW_SUM_LSB + lane * 64 + 63,
               AGGB_RAW_SUM_LSB + lane * 64) = r.raw_sum[lane];
    beat.range(AGGB_RAW_SQUARE_LSB + lane * 96 + 95,
               AGGB_RAW_SQUARE_LSB + lane * 96) = r.raw_square[lane];
    beat.range(AGGB_MIN_LSB + lane * 64 + 63, AGGB_MIN_LSB + lane * 64) =
        r.minimum[lane];
    beat.range(AGGB_MAX_LSB + lane * 64 + 63, AGGB_MAX_LSB + lane * 64) =
        r.maximum[lane];
    beat.range(AGGB_PHASOR_RE_LSB + lane * 128 + 127,
               AGGB_PHASOR_RE_LSB + lane * 128) = r.phasor_re[lane];
    beat.range(AGGB_PHASOR_IM_LSB + lane * 128 + 127,
               AGGB_PHASOR_IM_LSB + lane * 128) = r.phasor_im[lane];
  }
  for (int pair = 0; pair < MET_VLL_PAIRS; ++pair) {
#pragma HLS UNROLL
    beat.range(AGGB_VLL_SQUARE_LSB + pair * 128 + 127,
               AGGB_VLL_SQUARE_LSB + pair * 128) = r.vll_square[pair];
  }
  for (int phase = 0; phase < MET_POWER_PHASES; ++phase) {
#pragma HLS UNROLL
    beat.range(AGGB_POWER_SUM_LSB + phase * 128 + 127,
               AGGB_POWER_SUM_LSB + phase * 128) = r.power_sum[phase];
  }
  return beat;
}

inline agg_block_result_t unpack_agg_block_result(const agg_block_beat_t &beat) {
#pragma HLS INLINE
  agg_block_result_t r;
  r.sequence       = beat.range(AGGB_SEQUENCE_LSB + 31, AGGB_SEQUENCE_LSB);
  r.generation     = beat.range(AGGB_GENERATION_LSB + 31, AGGB_GENERATION_LSB);
  r.first_sample   = beat.range(AGGB_FIRST_SAMPLE_LSB + 63, AGGB_FIRST_SAMPLE_LSB);
  r.last_sample    = beat.range(AGGB_LAST_SAMPLE_LSB + 63, AGGB_LAST_SAMPLE_LSB);
  r.sample_count   = beat.range(AGGB_SAMPLE_COUNT_LSB + 31, AGGB_SAMPLE_COUNT_LSB);
  r.sample_rate_hz = beat.range(AGGB_SAMPLE_RATE_LSB + 31, AGGB_SAMPLE_RATE_LSB);
  r.nominal_hz     = beat.range(AGGB_NOMINAL_HZ_LSB + 7, AGGB_NOMINAL_HZ_LSB);
  r.valid_mask     = beat.range(AGGB_VALID_MASK_LSB + 7, AGGB_VALID_MASK_LSB);
  r.flags = beat.range(AGGB_FLAGS_LSB + MET_FLAG_BITS - 1, AGGB_FLAGS_LSB);
  r.cycle_count    = beat.range(AGGB_CYCLE_COUNT_LSB + 7, AGGB_CYCLE_COUNT_LSB);
  r.status         = beat.range(AGGB_STATUS_LSB + 31, AGGB_STATUS_LSB);
  r.frequency_millihz = beat.range(AGGB_FREQ_LSB + 31, AGGB_FREQ_LSB);
  r.frequency_valid = beat[AGGB_FREQ_VALID_BIT];
  r.apply_toggle   = beat[AGGB_APPLY_TOGGLE_BIT];
  r.dc_remove      = beat[AGGB_DC_REMOVE_BIT];
  for (int lane = 0; lane < MET_ACTIVE_CHANNELS; ++lane) {
#pragma HLS UNROLL
    r.sum[lane] = beat.range(AGGB_SUM_LSB + lane * 128 + 127,
                             AGGB_SUM_LSB + lane * 128);
    r.square[lane] = beat.range(AGGB_SQUARE_LSB + lane * 128 + 127,
                                AGGB_SQUARE_LSB + lane * 128);
    r.raw_sum[lane] = beat.range(AGGB_RAW_SUM_LSB + lane * 64 + 63,
                                 AGGB_RAW_SUM_LSB + lane * 64);
    r.raw_square[lane] = beat.range(AGGB_RAW_SQUARE_LSB + lane * 96 + 95,
                                    AGGB_RAW_SQUARE_LSB + lane * 96);
    r.minimum[lane] = beat.range(AGGB_MIN_LSB + lane * 64 + 63,
                                 AGGB_MIN_LSB + lane * 64);
    r.maximum[lane] = beat.range(AGGB_MAX_LSB + lane * 64 + 63,
                                 AGGB_MAX_LSB + lane * 64);
    r.phasor_re[lane] = beat.range(AGGB_PHASOR_RE_LSB + lane * 128 + 127,
                                   AGGB_PHASOR_RE_LSB + lane * 128);
    r.phasor_im[lane] = beat.range(AGGB_PHASOR_IM_LSB + lane * 128 + 127,
                                   AGGB_PHASOR_IM_LSB + lane * 128);
  }
  for (int pair = 0; pair < MET_VLL_PAIRS; ++pair) {
#pragma HLS UNROLL
    r.vll_square[pair] = beat.range(AGGB_VLL_SQUARE_LSB + pair * 128 + 127,
                                    AGGB_VLL_SQUARE_LSB + pair * 128);
  }
  for (int phase = 0; phase < MET_POWER_PHASES; ++phase) {
#pragma HLS UNROLL
    r.power_sum[phase] = beat.range(AGGB_POWER_SUM_LSB + phase * 128 + 127,
                                    AGGB_POWER_SUM_LSB + phase * 128);
  }
  return r;
}

#endif  // MSAP1_AGG_BLOCK_RESULT_HPP
