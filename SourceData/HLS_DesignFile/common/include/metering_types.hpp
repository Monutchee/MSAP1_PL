#ifndef MSAP1_METERING_TYPES_HPP
#define MSAP1_METERING_TYPES_HPP

// The widest shared beat is the 4896-bit SingleCycleResult (provenance +
// the M3 statistics sections), past ap_int's 1024-bit default ceiling.
// This must precede the first ap_int.h inclusion in every translation
// unit; each component's cflags also pass -DAP_INT_MAX_W sized for the
// beats it actually touches, so an unlucky include order cannot regress
// it (single_cycle_result.hpp additionally #errors below 8192).
#ifndef AP_INT_MAX_W
#define AP_INT_MAX_W 8192
#endif

#include <ap_int.h>

// Shared metering geometry and scalar types for every MSAP1 HLS engine.
//
// This header is the single C++ definition of quantities that used to be
// declared per language and per module (metering_pkg.vhd,
// measurement_record_bus_pkg.vhd, per-engine headers). An HLS component
// must include this header instead of restating any value below; the VHDL
// packages keep mirrored constants only while VHDL consumers still exist,
// and the mirror is documented at each VHDL site.
//
// Everything here is a contract, not an implementation detail: the values
// bind the record wire format, the APU decoder (MSAP1_APU
// common/msap1/meter/meter_record.hpp) and the IEC 61000-4-30 measurement
// definitions. Change nothing here without updating the APU side in the
// same release.

// ---------------------------------------------------------------------------
// Channel geometry.
//
// Every record and result beat carries eight RMS lanes. Lanes 0..3 are
// current channels, lanes 4..6 voltage channels, lane 7 is reserved and
// reads zero/invalid in the default configuration (CH7 exists in capture
// but is not a metering channel today).
// ---------------------------------------------------------------------------
static const int MET_CHANNEL_LANES   = 8;
static const int MET_ACTIVE_CHANNELS = 7;   // CH0..CH6

// Semantic lane roles (the sensor-board channel order; note the REVERSED
// voltage order — Va is lane 6). Arithmetic must reference these, never
// bare indices, so the mapping stays centralized (handover §6).
static const int MET_LANE_IA = 0;
static const int MET_LANE_IB = 1;
static const int MET_LANE_IC = 2;
static const int MET_LANE_IN = 3;
static const int MET_LANE_VC = 4;
static const int MET_LANE_VB = 5;
static const int MET_LANE_VA = 6;

// Line-line voltage pair order used by every VLL statistic and record
// lane: 0 = Vab, 1 = Vbc, 2 = Vca.
static const int MET_VLL_PAIRS = 3;

// ---------------------------------------------------------------------------
// IEC 61000-4-30 block geometry.
//
// A basic measurement block is 10 complete grid cycles at a declared 50 Hz
// nominal, 12 at 60 Hz (~200 ms, tracking the actual grid frequency;
// grid_cycle_timing.vhd owns the boundary decision). A 150/180-cycle
// aggregate is formed from exactly 15 consecutive eligible basic results —
// never a wall-clock timer, never a second RMS pass over raw samples.
// ---------------------------------------------------------------------------
static const int MET_GRID_CYCLES_50HZ           = 10;
static const int MET_GRID_CYCLES_60HZ           = 12;
static const int MET_BASIC_BLOCKS_PER_AGGREGATE = 15;

// Complete grid cycles in one IEC 61000-4-30 basic measurement block for
// a declared nominal frequency. Callers guarantee nominal is 50 or 60
// (the eligibility predicates reject everything else).
inline ap_uint<8> met_expected_cycles(const ap_uint<8> nominal_hz) {
  return (nominal_hz == 50) ? ap_uint<8>(MET_GRID_CYCLES_50HZ)
                            : ap_uint<8>(MET_GRID_CYCLES_60HZ);
}

// Block provenance flags (grid_timing_pkg.vhd bit positions, carried in
// basic result beats and in the MTR1 timing word).
static const int MET_FLAG_LOCKED      = 0;  // block closed on a counted crossing
static const int MET_FLAG_FALLBACK    = 1;  // block closed on the fallback window
static const int MET_FLAG_FIRST_BLOCK = 2;  // first block after APPLY
static const int MET_FLAG_BITS        = 3;

// ---------------------------------------------------------------------------
// Scalar types.
// ---------------------------------------------------------------------------

// One converted sample: 24-bit ADC value sign-extended into 32 bits by the
// conversion stage.
typedef ap_int<32> met_sample_t;

// One RMS lane in the internal Q16 domain: signed 64-bit, magnitude < 2^63.
// The aggregation arithmetic contract (squares, 132-bit accumulators,
// floor mean, floor root) is stated where it is implemented; the lane type
// is fixed here.
typedef ap_int<64> met_q16_t;
static const int MET_RMS_LANE_BITS  = 64;
static const int MET_RMS_LANES_BITS = MET_CHANNEL_LANES * MET_RMS_LANE_BITS;  // 512

// Signed micro-unit quantities as published in records (mean, RMS).
typedef ap_int<64> met_micro_units_t;

// The 64-bit free-running conversion sample index. It is the measurement
// timebase: never reset on configuration apply, never stepped for time
// synchronization (AGENTS.md). Records reference it as the first-sample
// timestamp; the APU maps it to UTC via the waveform correlation block.
typedef ap_uint<64> met_sample_index_t;

// Plain 32-bit register/word quantity (word32_t in metering_pkg.vhd).
typedef ap_uint<32> met_word32_t;

#endif  // MSAP1_METERING_TYPES_HPP
