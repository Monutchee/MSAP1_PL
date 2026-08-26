#ifndef SINGLE_CYCLE_ENGINE_HPP
#define SINGLE_CYCLE_ENGINE_HPP

#include <hls_stream.h>

#include "measurement_record.hpp"
#include "metering_types.hpp"
#include "single_cycle_packet.hpp"
#include "single_cycle_sample_packet.hpp"

// The single-cycle measurement engine (normative source): the foundation
// tier of the metrology redesign. It reduces the accepted converted-frame
// stream to one result per complete, non-overlapping grid cycle:
// timing/provenance (M2) plus the StatisticsCore sufficient statistics
// (M3, statistics_core.hpp — sums, saturating square sums, raw-count
// accumulators, min/max, and instantaneous line-line difference
// statistics). Status word bit 0 is the PER-CYCLE arithmetic flag
// (square saturation, defensive clamps, finalize overflow); unlike the
// legacy block engine's sticky-until-APPLY flag it clears with each
// window, and the 10/12-cycle tier reconstructs stickiness by ORing. grid_cycle_timing remains the one timing
// authority: the engine never re-derives cycle boundaries, it registers
// the per-cycle close marker travelling with each frame.
//
//   s_sample : one fixed SCYC_SAMPLE_PACKET_WORDS x 32-bit packet per
//              accepted converted frame, assembled by
//              meter_single_cycle_hls_shim.vhd in lock step. The engine
//              accepts one word per invocation and processes the frame only
//              after the complete packet has arrived.
//   m_axis   : SCYC-v2 diagnostic records (measurement_record.hpp), one
//              per completed cycle — the observability path until the
//              10/12-cycle tier consumes the result stream (M7). The
//              per-lane and line-line RMS words are diagnostics; the
//              mergeable statistics on m_result stay authoritative.
//   m_result : one fixed SCYC_PACKET_WORDS x 32-bit packet per completed
//              cycle -- the private input contract of the R5C1 interval
//              service. The
//              narrow stream avoids a 7,072-bit physical interface while
//              preserving every field of single_cycle_result_t.
//
// Window rules (the mtr1 conventions, applied per cycle):
//   - a cycle closes on the beat whose closes_cycle flag is set;
//     grid_cycle_timing decides. While cycle timing is not locked
//     (cycle_mode low) there are no cycle boundaries and no single-cycle
//     products: the running window clears. The free-run fallback that
//     keeps 10/12-cycle records flowing has no per-cycle analogue.
//   - configuration commits when the beat-sampled APPLY toggle changes:
//     the window clears and the carrying beat is processed under the new
//     configuration (the stale-generation guard rejects it until its tag
//     catches up), keeping cycle accounting aligned with the grid.
//   - a malformed or stale-generation frame discards the running window.
//   - emission is blocking and finalization is a provenance copy, so
//     nothing here can drop a cycle; the shim FIFO absorbs the record
//     serialization latency.

// FREQUENCY_STATUS bit consumed for frequency_valid (meter_frequency_pkg
// FREQUENCY_STATUS_VALID) — same convention as the mtr1 engine.
static const int SCYC_FREQ_STATUS_VALID_BIT = 1;

void hls_single_cycle_engine(hls::stream<single_cycle_sample_word_t> &s_sample,
                             hls::stream<record_axis_t> &m_axis,
                             hls::stream<single_cycle_word_t> &m_result);

#endif  // SINGLE_CYCLE_ENGINE_HPP
