#ifndef MTR2_ENGINE_HPP
#define MTR2_ENGINE_HPP

#include <hls_stream.h>

#include "basic_result_beat.hpp"
#include "measurement_record.hpp"
#include "metering_types.hpp"

// The IEC 61000-4-30 150/180-cycle aggregation engine (normative source;
// it replaced the hand-written RTL engine after a compared deployment --
// meter_cycle_aggregator.vhd in git history).
//
// Functional contract: the aggregate is formed from exactly
// MTR_BASIC_BLOCKS_PER_AGGREGATE (15) consecutive eligible Basic
// measurement results -- never a wall-clock timer, never a second RMS
// engine over raw samples. Aggregation arithmetic is pinned:
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
// Interface contract: one basic_result_beat_t (common
// basic_result_beat.hpp -- produced by the MTR1 engine) per Basic result,
// and one complete MTR2-v2 record on m_axis per finished aggregate:
// exactly MREC_WORDS x 32-bit beats, TLAST on the last beat
// (serialize_record). The engine's diagnostic counters ride inside the
// record (words 33..35 and the sequence word); the AXI-Lite AGG_*
// registers are taps on those words, "as of the last emitted aggregate".
// The design is ap_ctrl_none (free running) and can never backpressure
// measurement: a transport stall parks the serialize loop while incoming
// Basic results queue in the input stream (worst case one per ~200 ms
// against a microsecond-scale drain).
//
// The configuration APPLY toggle is not a separate port: the producer
// samples the toggle level into every beat (basic_result_t.apply_toggle).
// A level change between consecutive beats terminates the partial
// aggregate before the carrying beat is folded in, matching the RTL
// behaviour for every stimulus in which APPLY does not race the Basic
// result event itself. Known divergence, accepted since the trial: if
// APPLY toggles in the exact aclk cycle of a Basic result event the
// retired RTL discarded that event, while this engine resets and then
// lets the same event seed the next aggregate; and a double APPLY with no
// intervening Basic result is invisible here (the level returns
// unchanged) so reset_count can undercount by one per occurrence. Both
// need sub-200-ms APPLY races the product never performs.

// Aggregation accumulator geometry (mirrored by
// measurement_record_bus_pkg.vhd AGGREGATE_ACCUMULATOR_BITS):
//   input:        |RMS| as signed 64-bit Q16 (magnitude < 2^63)
//   square:       unsigned 126 bits
//   accumulator:  unsigned 132 bits (15 x 2^126 < 2^130, 2 bits margin)
//   mean:         floor(acc / 15), serial restoring division
//   aggregate:    floor(sqrt(mean)), restoring root
// All rounding is floor; no stage can overflow by construction, so no
// implicit truncation or saturation participates in the result.
static const int MTR2_ACC_BITS = 132;

void hls_mtr2_engine(hls::stream<basic_result_beat_t> &s_basic,
                          hls::stream<record_axis_t> &m_axis);

#endif  // MTR2_ENGINE_HPP
