#ifndef MSAP1_BASIC_RESULT_BEAT_HPP
#define MSAP1_BASIC_RESULT_BEAT_HPP

// metering_types.hpp first: it raises AP_INT_MAX_W before ap_int.h.
#include "metering_types.hpp"

#include <ap_int.h>

// The Basic measurement result event — one beat per closed 10/12-cycle
// block, produced once by the MTR1 engine and consumed by every
// aggregation tier (today: the 150/180-cycle aggregator).
//
// This is the single normative definition of the beat (bit layout carried
// over unchanged from the aggregation engine's original local definition;
// the values are pinned by static_asserts in
// common/test/common_headers_test.cpp). Producer: the MTR1 engine's
// m_result stream. Consumer: the MTR2 aggregation engine's s_basic.
//
// Every field is byte aligned; [MSB:LSB] positions are normative. The
// APPLY configuration toggle is not a separate port: the producer samples
// the toggle level into every beat, and a level change between
// consecutive beats is the consumer's APPLY event.

static const int BASIC_BEAT_SEQUENCE_LSB     = 0;    // [31:0]   result_sequence
static const int BASIC_BEAT_GENERATION_LSB   = 32;   // [63:32]  config generation
static const int BASIC_BEAT_SAMPLE_RATE_LSB  = 64;   // [95:64]  sample_rate_hz
static const int BASIC_BEAT_SAMPLE_COUNT_LSB = 96;   // [127:96] samples in block
static const int BASIC_BEAT_VALID_MASK_LSB   = 128;  // [135:128] channel valid mask
static const int BASIC_BEAT_FLAGS_LSB        = 136;  // [138:136] MET_FLAG_* (in a byte)
static const int BASIC_BEAT_CYCLE_COUNT_LSB  = 144;  // [151:144] cycles in block
static const int BASIC_BEAT_NOMINAL_HZ_LSB   = 152;  // [159:152] declared nominal Hz
static const int BASIC_BEAT_STATUS_LSB       = 160;  // [191:160] engine status word
static const int BASIC_BEAT_FREQ_LSB         = 192;  // [223:192] frequency_millihz
static const int BASIC_BEAT_FREQ_VALID_BIT   = 224;  // frequency_valid
static const int BASIC_BEAT_APPLY_TOGGLE_BIT = 225;  // config APPLY toggle level
static const int BASIC_BEAT_FIRST_SAMPLE_LSB = 232;  // [295:232] first sample index
static const int BASIC_BEAT_RMS_LSB          = 296;  // [807:296] rms_q16, 8 x 64
static const int BASIC_BEAT_BITS             = 808;  // 101 bytes on AXIS

typedef ap_uint<BASIC_BEAT_BITS> basic_result_beat_t;

// ---------------------------------------------------------------------------
// Unpacked view. Engines work on named fields; the beat exists only on the
// wire. pack/unpack below are the explicit lane mapping (wired bit
// selects, no barrel shifting — the aggregation-trial area lesson).
// ---------------------------------------------------------------------------
struct basic_result_t {
  met_word32_t          sequence;          // basic-block result sequence
  met_word32_t          generation;        // committed config generation
  met_word32_t          sample_rate_hz;
  met_word32_t          sample_count;      // actual samples in the block
  ap_uint<8>            valid_mask;
  ap_uint<MET_FLAG_BITS> flags;            // MET_FLAG_* provenance bits
  ap_uint<8>            cycle_count;       // complete cycles in the block
  ap_uint<8>            nominal_hz;        // declared nominal (50/60)
  met_word32_t          status;            // RMS engine status word
  met_word32_t          frequency_millihz;
  ap_uint<1>            frequency_valid;
  ap_uint<1>            apply_toggle;      // sampled APPLY toggle level
  met_sample_index_t    first_sample;      // block's first conversion index
  met_q16_t             rms_q16[MET_CHANNEL_LANES];
};

inline basic_result_beat_t pack_basic_result(const basic_result_t &r) {
#pragma HLS INLINE
  basic_result_beat_t beat = 0;
  beat.range(BASIC_BEAT_SEQUENCE_LSB + 31, BASIC_BEAT_SEQUENCE_LSB)         = r.sequence;
  beat.range(BASIC_BEAT_GENERATION_LSB + 31, BASIC_BEAT_GENERATION_LSB)     = r.generation;
  beat.range(BASIC_BEAT_SAMPLE_RATE_LSB + 31, BASIC_BEAT_SAMPLE_RATE_LSB)   = r.sample_rate_hz;
  beat.range(BASIC_BEAT_SAMPLE_COUNT_LSB + 31, BASIC_BEAT_SAMPLE_COUNT_LSB) = r.sample_count;
  beat.range(BASIC_BEAT_VALID_MASK_LSB + 7, BASIC_BEAT_VALID_MASK_LSB)      = r.valid_mask;
  beat.range(BASIC_BEAT_FLAGS_LSB + MET_FLAG_BITS - 1, BASIC_BEAT_FLAGS_LSB) = r.flags;
  beat.range(BASIC_BEAT_CYCLE_COUNT_LSB + 7, BASIC_BEAT_CYCLE_COUNT_LSB)    = r.cycle_count;
  beat.range(BASIC_BEAT_NOMINAL_HZ_LSB + 7, BASIC_BEAT_NOMINAL_HZ_LSB)      = r.nominal_hz;
  beat.range(BASIC_BEAT_STATUS_LSB + 31, BASIC_BEAT_STATUS_LSB)             = r.status;
  beat.range(BASIC_BEAT_FREQ_LSB + 31, BASIC_BEAT_FREQ_LSB)                 = r.frequency_millihz;
  beat[BASIC_BEAT_FREQ_VALID_BIT]                                           = r.frequency_valid;
  beat[BASIC_BEAT_APPLY_TOGGLE_BIT]                                         = r.apply_toggle;
  beat.range(BASIC_BEAT_FIRST_SAMPLE_LSB + 63, BASIC_BEAT_FIRST_SAMPLE_LSB) = r.first_sample;
  for (int lane = 0; lane < MET_CHANNEL_LANES; ++lane) {
#pragma HLS UNROLL
    const int lsb = BASIC_BEAT_RMS_LSB + lane * MET_RMS_LANE_BITS;
    beat.range(lsb + MET_RMS_LANE_BITS - 1, lsb) = r.rms_q16[lane];
  }
  return beat;
}

inline basic_result_t unpack_basic_result(const basic_result_beat_t &beat) {
#pragma HLS INLINE
  basic_result_t r;
  r.sequence          = beat.range(BASIC_BEAT_SEQUENCE_LSB + 31, BASIC_BEAT_SEQUENCE_LSB);
  r.generation        = beat.range(BASIC_BEAT_GENERATION_LSB + 31, BASIC_BEAT_GENERATION_LSB);
  r.sample_rate_hz    = beat.range(BASIC_BEAT_SAMPLE_RATE_LSB + 31, BASIC_BEAT_SAMPLE_RATE_LSB);
  r.sample_count      = beat.range(BASIC_BEAT_SAMPLE_COUNT_LSB + 31, BASIC_BEAT_SAMPLE_COUNT_LSB);
  r.valid_mask        = beat.range(BASIC_BEAT_VALID_MASK_LSB + 7, BASIC_BEAT_VALID_MASK_LSB);
  r.flags             = beat.range(BASIC_BEAT_FLAGS_LSB + MET_FLAG_BITS - 1, BASIC_BEAT_FLAGS_LSB);
  r.cycle_count       = beat.range(BASIC_BEAT_CYCLE_COUNT_LSB + 7, BASIC_BEAT_CYCLE_COUNT_LSB);
  r.nominal_hz        = beat.range(BASIC_BEAT_NOMINAL_HZ_LSB + 7, BASIC_BEAT_NOMINAL_HZ_LSB);
  r.status            = beat.range(BASIC_BEAT_STATUS_LSB + 31, BASIC_BEAT_STATUS_LSB);
  r.frequency_millihz = beat.range(BASIC_BEAT_FREQ_LSB + 31, BASIC_BEAT_FREQ_LSB);
  r.frequency_valid   = beat[BASIC_BEAT_FREQ_VALID_BIT];
  r.apply_toggle      = beat[BASIC_BEAT_APPLY_TOGGLE_BIT];
  r.first_sample      = beat.range(BASIC_BEAT_FIRST_SAMPLE_LSB + 63, BASIC_BEAT_FIRST_SAMPLE_LSB);
  for (int lane = 0; lane < MET_CHANNEL_LANES; ++lane) {
#pragma HLS UNROLL
    const int lsb = BASIC_BEAT_RMS_LSB + lane * MET_RMS_LANE_BITS;
    r.rms_q16[lane] = beat.range(lsb + MET_RMS_LANE_BITS - 1, lsb);
  }
  return r;
}

#endif  // MSAP1_BASIC_RESULT_BEAT_HPP
