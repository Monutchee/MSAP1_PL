#ifndef SINGLE_CYCLE_POWER_CORE_HPP
#define SINGLE_CYCLE_POWER_CORE_HPP

#include "metering_types.hpp"
#include "metrology_stats.hpp"
#include "single_cycle_result.hpp"

// PowerCore: the single-cycle engine's power sufficient statistics
// (metrology roadmap M4, handover §7). A separate C++ module inside the
// same IP, like StatisticsCore.
//
// It collects exactly the per-phase cross-product sums sum(v[n] * i[n])
// for A/B/C — nothing is finalized here beyond the record's diagnostic
// active-power words. Ten/twelve-cycle P, S, and PF derive from MERGED
// sums in the 10/12-cycle tier; averaging finalized one-cycle P or PF
// values is forbidden (handover §7: sample counts vary per cycle).
//
// Units and signs are normative in metering_types.hpp: Q16 micro-unit
// samples make each product Q32 picowatts; import is positive. The
// 128-bit signed saturating accumulator mirrors the square accumulator's
// width analysis: a full-scale 48x48 product is exactly 96 bits, normal
// products are much smaller, and the downstream merge remains a pure
// addition.

struct cycle_power_t {
  ap_int<128> power_sum[MET_POWER_PHASES];
};

// (voltage, current) lane per phase, in A/B/C order.
static const int MET_POWER_VOLTAGE[MET_POWER_PHASES] = {MET_LANE_VA,
                                                        MET_LANE_VB,
                                                        MET_LANE_VC};
static const int MET_POWER_CURRENT[MET_POWER_PHASES] = {MET_LANE_IA,
                                                        MET_LANE_IB,
                                                        MET_LANE_IC};

// Accumulate one accepted frame (seed-in-place on first_frame, like
// every window accumulator; saturation raises the shared sticky flag).
inline void accumulate_power(cycle_power_t &acc,
                             const met_q16_t q16[MET_ACTIVE_CHANNELS],
                             const bool first_frame,
                             ap_uint<1> &sticky_overflow) {
#pragma HLS INLINE
power_phases:
  for (int phase = 0; phase < MET_POWER_PHASES; ++phase) {
#pragma HLS PIPELINE off
    const ap_int<96> product_narrow =
        q16[MET_POWER_VOLTAGE[phase]] * q16[MET_POWER_CURRENT[phase]];
    const ap_int<128> product = product_narrow;
    const ap_int<128> base =
        first_frame ? ap_int<128>(0) : acc.power_sum[phase];
    acc.power_sum[phase] =
        met_add_signed_saturating<128>(base, product, sticky_overflow);
  }
}

inline void export_power(const cycle_power_t &acc,
                         single_cycle_result_t &result) {
#pragma HLS INLINE
export_phases:
  for (int phase = 0; phase < MET_POWER_PHASES; ++phase) {
#pragma HLS UNROLL
    result.power_sum[phase] = acc.power_sum[phase];
  }
}

#endif  // SINGLE_CYCLE_POWER_CORE_HPP
