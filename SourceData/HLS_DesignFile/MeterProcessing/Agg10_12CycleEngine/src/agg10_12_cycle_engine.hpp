#ifndef AGG10_12_CYCLE_ENGINE_HPP
#define AGG10_12_CYCLE_ENGINE_HPP

#include <hls_stream.h>

#include "basic_result_beat.hpp"
#include "measurement_record.hpp"
#include "metering_types.hpp"
#include "single_cycle_result.hpp"

// The 10/12-cycle basic measurement engine (normative source) — the
// canonical ~200 ms finalized tier of the metrology redesign. It CONSUMES
// SingleCycleResult beats (whole grid cycles of merge-safe sufficient
// statistics, SCYC-v5 contract) and never raw samples: 10 cycles @ 50 Hz
// or 12 @ 60 Hz merge by pure addition into exactly the block
// accumulators the retired Mtr1Engine built sample by sample — the
// single-cycle accumulator widths were chosen for this (sum s128,
// saturating square u128, raw s64/u96) — and the finalize runs the same
// shared primitives, so for identical stimulus the finalized values are
// identical. That equivalence is the Mtr1 retirement proof, pinned by
// this component's golden bench.
//
//   s_result : one beat per whole grid cycle plus the config/context the
//              hosting shim appends (layout below).
//   m_axis   : three complete records per finalized block, back to back
//              on the one stream, each MREC_WORDS x 32 beats with TLAST
//              on the last and the same correlation fields (sequence,
//              generation, anchors, block status):
//                BASIC-v4  (0x00010004) — MTR1-v3 interior plus the
//                          last-sample anchor (words 14/15) and merged
//                          line-line RMS (words 51..53);
//                POWER-v1  (0x00070001) — P/S/true-PF/crest (M8);
//                PHASOR-v1 (0x00080001) — fundamental magnitudes/angles,
//                          Q1, displacement PF, load nature (M9); only
//                          this record carries the phasor-invalid status
//                          bit (bit 1).
//   m_result : one basic_result_beat_t per finalized block — the 150/180
//              tier's input contract, emitted here UNCHANGED so
//              Mtr2Engine keeps producing until M11 replaces it.
//
// Block rules (the handover's validity/generation contract, one tier up):
//   - a block is N = met_expected_cycles(nominal) CONSECUTIVE whole
//     cycles: result sequence and grid cycle sequence must each advance
//     by exactly one, under the active generation, with a constant
//     nominal. Any break discards the partial block; the breaking cycle
//     (a whole cycle itself) starts the next one.
//   - a cycle carrying the SCYC first-after-gap mark starts a new block
//     the same way (the upstream tier already discarded the torn cycle).
//   - APPLY latches the shadow config, clears the block and the sticky
//     arithmetic flag; the first block finalized after any of the above
//     is marked first-after-gap (status bit 2) and carries
//     MET_FLAG_FIRST_BLOCK, so downstream tiers never aggregate across a
//     discontinuity silently.
//   - lock/fallback provenance is reduced across the block's cycles from
//     the LIVE grid view the shim samples with each beat (locked = AND,
//     fallback = OR); grid_cycle_timing keeps cycle boundaries running
//     synthetically at nominal cadence while unlocked, so this tier keeps
//     flowing flagged results on a dead reference exactly like the
//     retired sample-domain fallback window did.
//   - the sticky arithmetic flag ORs the cycles' overflow bits and any
//     saturation during the merge itself, and survives until APPLY
//     (record status bit 0) — the Mtr1 semantics.
//
// Frequency/capture context (record words 56..63) is sampled by the shim
// with each result beat and latched from the CLOSING beat, the same
// one-update skew Mtr1 already tolerated (its accepted divergence #1).

// ---------------------------------------------------------------------------
// Input beat: the SingleCycleResult verbatim plus shim-appended config
// and context. Every field is byte aligned unless noted; [MSB:LSB]
// positions are normative and meter_agg10_12_cycle_hls_shim.vhd mirrors them.
// ---------------------------------------------------------------------------
static const int AGG_IN_RESULT_LSB       = 0;     // [7071:0] SCYC result beat
static const int AGG_IN_CFG_GEN_LSB      = 7072;  // [7103:7072] shadow generation
static const int AGG_IN_CFG_RATE_LSB     = 7104;  // [7135:7104] shadow sample rate
static const int AGG_IN_CFG_MASK_LSB     = 7136;  // [7143:7136] shadow valid mask
static const int AGG_IN_ENABLE_BIT       = 7144;  // shadow enable
static const int AGG_IN_DC_REMOVE_BIT    = 7145;  // shadow dc_remove
static const int AGG_IN_APPLY_BIT        = 7146;  // config APPLY toggle (level)
static const int AGG_IN_LOCKED_BIT       = 7147;  // live grid lock at arrival
static const int AGG_IN_FALLBACK_BIT     = 7148;  // live fallback view
static const int AGG_IN_FREQ_STATUS_LSB  = 7168;  // [7199:7168] frequency status word
static const int AGG_IN_FREQ_PERIOD_LSB  = 7200;  // [7231:7200] averaged Q16 period
static const int AGG_IN_FREQ_SEQ_LSB     = 7232;  // [7263:7232] frequency meas. sequence
static const int AGG_IN_CAP_FRAMES_LSB   = 7264;  // [7295:7264] capture frame count
static const int AGG_IN_CAP_HDRERR_LSB   = 7296;  // [7327:7296] capture header errors
static const int AGG_IN_CAP_OVERFLOW_LSB = 7328;  // [7359:7328] capture FIFO overflows
static const int AGG_IN_CAP_ALERTS_LSB   = 7360;  // [7391:7360] ADC alert count
static const int AGG_IN_BITS             = 7392;  // 924 bytes on AXIS

typedef ap_uint<AGG_IN_BITS> agg10_12_input_beat_t;

void hls_agg10_12_cycle_engine(hls::stream<agg10_12_input_beat_t> &s_result,
                         hls::stream<record_axis_t> &m_axis,
                         hls::stream<basic_result_beat_t> &m_result);

#endif  // AGG10_12_CYCLE_ENGINE_HPP
