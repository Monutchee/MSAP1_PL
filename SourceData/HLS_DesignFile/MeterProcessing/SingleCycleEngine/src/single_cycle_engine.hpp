#ifndef SINGLE_CYCLE_ENGINE_HPP
#define SINGLE_CYCLE_ENGINE_HPP

#include <hls_stream.h>

#include "measurement_record.hpp"
#include "metering_types.hpp"
#include "single_cycle_result.hpp"

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
//   s_sample : one beat per accepted converted frame (layout below),
//              assembled by meter_single_cycle_hls_shim.vhd in lock step.
//   m_axis   : SCYC-v2 diagnostic records (measurement_record.hpp), one
//              per completed cycle — the observability path until the
//              10/12-cycle tier consumes the result stream (M7). The
//              per-lane and line-line RMS words are diagnostics; the
//              mergeable statistics on m_result stay authoritative.
//   m_result : one single_cycle_beat_t per completed cycle — the input
//              contract of Agg10_12MeasurementEngine.
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

// ---------------------------------------------------------------------------
// Input beat. Every field is byte aligned; [MSB:LSB] positions are
// normative and meter_single_cycle_hls_shim.vhd mirrors them. The sample
// lanes are carried from M2 onward but consumed only from M3 (statistics
// accumulation) — the shim wiring does not change when the math lands.
// ---------------------------------------------------------------------------
static const int SCYC_IN_SAMPLES_LSB      = 0;     // [511:0]    8 x 64b Q16
static const int SCYC_IN_RAW_LSB          = 512;   // [767:512]  8 x 32b raw
static const int SCYC_IN_FRAME_MASK_LSB   = 768;   // [775:768]  frame valid mask
static const int SCYC_IN_FRAME_GEN_LSB    = 776;   // [807:776]  frame generation
static const int SCYC_IN_MALFORMED_BIT    = 808;   // TKEEP was not all-ones
static const int SCYC_IN_CLOSES_BIT       = 809;   // frame completes a cycle
static const int SCYC_IN_CYCLE_MODE_BIT   = 810;   // cycle timing locked (level)
static const int SCYC_IN_APPLY_BIT        = 811;   // config APPLY toggle (level)
static const int SCYC_IN_ENABLE_BIT       = 812;   // shadow enable
static const int SCYC_IN_DC_REMOVE_BIT    = 813;   // shadow dc_remove (M3)
static const int SCYC_IN_CFG_GEN_LSB      = 816;   // [847:816]  shadow generation
static const int SCYC_IN_CFG_RATE_LSB     = 848;   // [879:848]  shadow sample rate
static const int SCYC_IN_CFG_MASK_LSB     = 880;   // [887:880]  shadow valid mask
static const int SCYC_IN_CYCLE_SEQ_LSB    = 896;   // [927:896]  grid cycle sequence
static const int SCYC_IN_NOMINAL_LSB      = 928;   // [935:928]  declared nominal Hz
static const int SCYC_IN_FLAGS_LSB        = 936;   // [938:936]  MET_FLAG_*
static const int SCYC_IN_SAMPLE_IDX_LSB   = 960;   // [1023:960] frame's sample index
static const int SCYC_IN_PL_TICK_LSB      = 1024;  // [1087:1024] free-running PL tick
static const int SCYC_IN_FREQ_MHZ_LSB     = 1088;  // [1119:1088] frequency millihertz
static const int SCYC_IN_FREQ_STATUS_LSB  = 1120;  // [1151:1120] frequency status word
static const int SCYC_IN_BITS             = 1152;  // 144 bytes on AXIS

typedef ap_uint<SCYC_IN_BITS> single_cycle_sample_beat_t;

// FREQUENCY_STATUS bit consumed for frequency_valid (meter_frequency_pkg
// FREQUENCY_STATUS_VALID) — same convention as the mtr1 engine.
static const int SCYC_FREQ_STATUS_VALID_BIT = 1;

void hls_single_cycle_engine(hls::stream<single_cycle_sample_beat_t> &s_sample,
                             hls::stream<record_axis_t> &m_axis,
                             hls::stream<single_cycle_beat_t> &m_result);

#endif  // SINGLE_CYCLE_ENGINE_HPP
