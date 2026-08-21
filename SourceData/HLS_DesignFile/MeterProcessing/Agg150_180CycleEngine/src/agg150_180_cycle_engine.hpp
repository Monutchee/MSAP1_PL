#ifndef AGG150_180_CYCLE_ENGINE_HPP
#define AGG150_180_CYCLE_ENGINE_HPP

#include <hls_stream.h>

#include "agg_block_result.hpp"
#include "measurement_record.hpp"
#include "metering_types.hpp"

// The IEC 61000-4-30 150/180-cycle aggregation engine (M11, replaces
// Mtr2Engine and the 808-bit basic_result_beat). It consumes
// Agg10_12Result block beats — each carrying the block's provenance and
// its MERGE-SAFE ACCUMULATORS (agg_block_result.hpp) — and folds exactly
// MET_BASIC_BLOCKS_PER_AGGREGATE (15) consecutive eligible blocks by
// pure addition, the redesign's one rule all the way up. The finalize is
// the SAME shared arithmetic the 10/12 tier runs
// (common/metrology_finalize.hpp), over the whole interval's summed
// accumulators — mean-corrected, sample-weighted, mathematically exact —
// so the aggregate tier publishes the full quantity set: RMS, VLL,
// P/S/true-PF/crest, fundamental phasors/Q1/displacement-PF, and
// symmetrical components / unbalance.
//
//   s_block : one agg_block_beat_t per finalized 10/12-cycle block; the
//             hosting shim is pure hosting (all context rides the beat).
//   m_axis  : four records per completed aggregate, back to back:
//             AGG-v3 (0x00020003), AGG-POWER (0x00100001), AGG-PHASOR
//             (0x00110002), AGG-UNBAL (0x00120002) — maps normative in
//             measurement_record.hpp.
//
// Aggregation rules (ported verbatim from the retired Mtr2Engine — the
// eligibility predicate, reset/continuity accounting, and record-carried
// diagnostics words 33..35 are unchanged so the AGG_* register tap keeps
// working):
//   - eligible input: locked, not fallback, not first-after-discontinuity,
//     known nominal, full cycle count. An ineligible block discards any
//     partial aggregate and never seeds one.
//   - generation / nominal / sample-rate change: discard partial, reseed.
//   - block-sequence or sample-index discontinuity: discard, count, reseed.
//   - a configuration APPLY between beats discards any partial aggregate.
//   - only complete 15-block aggregates are ever emitted.
//
// SEMANTIC upgrade vs Mtr2 (pre-production, golden equivalence not
// bit-identity): per-lane RMS comes from the summed raw accumulators
// over ~96000 samples, no longer sqrt(mean of 15 block-RMS squares).

void hls_agg150_180_cycle_engine(hls::stream<agg_block_beat_t> &s_block,
                                 hls::stream<record_axis_t> &m_axis);

#endif  // AGG150_180_CYCLE_ENGINE_HPP
