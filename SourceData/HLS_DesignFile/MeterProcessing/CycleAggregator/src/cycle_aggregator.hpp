#ifndef CYCLE_AGGREGATOR_HPP
#define CYCLE_AGGREGATOR_HPP

#include <ap_int.h>
#include <hls_stream.h>

// The IEC 61000-4-30 150/180-cycle aggregation engine (normative source;
// it replaced the hand-written RTL engine after a compared deployment --
// meter_cycle_aggregator.vhd in git history).
//
// Functional contract: the aggregate is formed from exactly
// CAGG_BASIC_BLOCKS (15) consecutive eligible Basic measurement results
// -- never a wall-clock timer, never a second RMS engine over raw
// samples. Aggregation arithmetic is pinned:
//   RMS lanes:  agg = floor(sqrt(floor(sum(x_i^2) / 15))), Q16 domain
//   frequency:  floor(sum(f_i) / 15), published only when all 15 valid
// A Basic result enters an aggregate only when cycle-locked, not in
// free-run fallback, not the first block after APPLY, carrying the
// nominal's exact cycle count (50 Hz -> 10, 60 Hz -> 12), matching the
// open aggregate's generation, nominal, and sample rate, with
// consecutive result sequences (modulo 2**32) and gapless sample ranges;
// any violation discards the partial aggregate (counted per cause), an
// eligible violator seeds afresh, an ineligible block never seeds. This
// mirrors the APU's class_a_aggregation_eligible() rule.
//
// Interface contract: one AXI4-Stream input beat per Basic result event and
// one AXI4-Stream output beat per completed aggregate. The design is
// ap_ctrl_none (free running) and can never backpressure measurement; the
// integration shim (meter_cycle_aggregator_hls_shim.vhd) holds at most one
// pending event and counts drops if the core were ever not ready (at real
// block rates -- one event per ~200 ms against a microsecond-scale busy
// window -- a drop is impossible).
//
// The configuration APPLY toggle is not a separate port: the shim samples
// the toggle level into every input beat (CAGG_IN_APPLY_TOGGLE). A level
// change between consecutive beats terminates the partial aggregate before
// the carrying beat is folded in, matching the RTL behaviour for every
// stimulus in which APPLY does not race the Basic result event itself.
// Known divergence, accepted for the trial: if APPLY toggles in the exact
// aclk cycle of a Basic result event the RTL discards that event, while
// this engine resets and then lets the same event seed the next aggregate;
// and a double APPLY with no intervening Basic result is invisible here
// (the level returns unchanged) so reset_count can undercount by one per
// occurrence. Both need sub-200-ms APPLY races the product never performs.
//
// The bit layout below is the single normative definition of both beats.
// meter_cycle_aggregator_hls_shim.vhd mirrors these offsets; keep them in
// lock step (the equivalence testbench catches any drift).

// ---------------------------------------------------------------------------
// Geometry shared with the RTL design (measurement_record_bus_pkg.vhd).
// ---------------------------------------------------------------------------
static const int CAGG_BASIC_BLOCKS = 15;   // AGGREGATE_BASIC_BLOCKS
static const int CAGG_CHANNELS     = 7;    // CH0..CH6 aggregated, CH7 zero
static const int CAGG_ACC_BITS     = 132;  // AGGREGATE_ACCUMULATOR_BITS

static const int CAGG_CYCLES_50HZ  = 10;   // GRID_CYCLES_50HZ
static const int CAGG_CYCLES_60HZ  = 12;   // GRID_CYCLES_60HZ

// grid_timing_pkg block flag bit positions inside the flags field.
static const int CAGG_FLAG_LOCKED      = 0;
static const int CAGG_FLAG_FALLBACK    = 1;
static const int CAGG_FLAG_FIRST_BLOCK = 2;

// ---------------------------------------------------------------------------
// Input beat: one Basic measurement result event (shim-packed, 808 bits).
// Every field is byte aligned; [MSB:LSB] positions are normative.
// ---------------------------------------------------------------------------
static const int CAGG_IN_SEQUENCE_LSB     = 0;    // [31:0]   result_sequence
static const int CAGG_IN_GENERATION_LSB   = 32;   // [63:32]  generation
static const int CAGG_IN_SAMPLE_RATE_LSB  = 64;   // [95:64]  sample_rate_hz
static const int CAGG_IN_SAMPLE_COUNT_LSB = 96;   // [127:96] sample_count
static const int CAGG_IN_VALID_MASK_LSB   = 128;  // [135:128] valid_mask
static const int CAGG_IN_FLAGS_LSB        = 136;  // [138:136] flags (in a byte)
static const int CAGG_IN_CYCLE_COUNT_LSB  = 144;  // [151:144] cycle_count
static const int CAGG_IN_NOMINAL_HZ_LSB   = 152;  // [159:152] nominal_hz
static const int CAGG_IN_STATUS_LSB       = 160;  // [191:160] status
static const int CAGG_IN_FREQ_LSB         = 192;  // [223:192] frequency_millihz
static const int CAGG_IN_FREQ_VALID_BIT   = 224;  // frequency_valid
static const int CAGG_IN_APPLY_TOGGLE_BIT = 225;  // config APPLY toggle level
static const int CAGG_IN_FIRST_SAMPLE_LSB = 232;  // [295:232] first_sample
static const int CAGG_IN_RMS_LSB          = 296;  // [807:296] rms_q16, 8x64
static const int CAGG_IN_BITS             = 808;  // 101 bytes on AXIS

typedef ap_uint<CAGG_IN_BITS> basic_beat_t;

// ---------------------------------------------------------------------------
// Output beat: one completed 150/180-cycle aggregate plus the engine's
// diagnostic counters as of the emit (968 bits).
// ---------------------------------------------------------------------------
static const int CAGG_OUT_SEQUENCE_LSB     = 0;    // [31:0]   aggregate sequence
static const int CAGG_OUT_GENERATION_LSB   = 32;   // [63:32]  generation
static const int CAGG_OUT_SAMPLE_RATE_LSB  = 64;   // [95:64]  sample_rate_hz
static const int CAGG_OUT_SAMPLES_LSB      = 96;   // [127:96] total samples
static const int CAGG_OUT_VALID_MASK_LSB   = 128;  // [135:128] AND of masks
static const int CAGG_OUT_NOMINAL_HZ_LSB   = 136;  // [143:136] nominal Hz
static const int CAGG_OUT_CYCLES_LSB       = 144;  // [159:144] total cycles
static const int CAGG_OUT_ARITHMETIC_BIT   = 160;  // OR of status bit 0
static const int CAGG_OUT_FREQ_VALID_BIT   = 161;  // all 15 frequencies valid
static const int CAGG_OUT_FIRST_SEQ_LSB    = 168;  // [199:168] first Basic seq
static const int CAGG_OUT_LAST_SEQ_LSB     = 200;  // [231:200] last Basic seq
static const int CAGG_OUT_FREQ_LSB         = 232;  // [263:232] mean millihertz
static const int CAGG_OUT_FIRST_SAMPLE_LSB = 264;  // [327:264] first sample
static const int CAGG_OUT_RMS_LSB          = 328;  // [839:328] rms_q16, 8x64
static const int CAGG_OUT_RECORD_CNT_LSB   = 840;  // [871:840] record_count
static const int CAGG_OUT_RESET_CNT_LSB    = 872;  // [903:872] reset_count
static const int CAGG_OUT_INELIG_CNT_LSB   = 904;  // [935:904] ineligible_count
static const int CAGG_OUT_CONT_CNT_LSB     = 936;  // [967:936] continuity_count
static const int CAGG_OUT_BITS             = 968;  // 121 bytes on AXIS

typedef ap_uint<CAGG_OUT_BITS> aggregate_beat_t;

void hls_cycle_aggregator(hls::stream<basic_beat_t> &s_basic,
                          hls::stream<aggregate_beat_t> &m_aggregate);

#endif  // CYCLE_AGGREGATOR_HPP
