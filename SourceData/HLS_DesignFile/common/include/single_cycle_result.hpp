#ifndef MSAP1_SINGLE_CYCLE_RESULT_HPP
#define MSAP1_SINGLE_CYCLE_RESULT_HPP

// metering_types.hpp first: it raises AP_INT_MAX_W before ap_int.h.
#include "metering_types.hpp"

#include <ap_int.h>

// The single-cycle measurement result — one beat per complete,
// non-overlapping grid cycle, produced by the single-cycle engine and
// consumed by the 10/12-cycle tier (Agg10_12MeasurementEngine, roadmap
// M7). This is the reusable-primitive contract of the metrology
// redesign: higher tiers merge these, they never re-derive from samples.
//
// M2 defines the timing/provenance section only. The statistics (M3),
// power (M4), and phasor (M5) sufficient-statistic sections APPEND after
// SCYC_BEAT_BITS with their own normative constants once their
// accumulator widths are derived (never guessed) — the beat has exactly
// one producer and one consumer inside this repository, so growing it is
// a lock-step header+shim change, not a wire-compatibility event.
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
static const int SCYC_BEAT_BITS        = 512;  // 64 bytes on AXIS (M2 extent)

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
  return r;
}

#endif  // MSAP1_SINGLE_CYCLE_RESULT_HPP
