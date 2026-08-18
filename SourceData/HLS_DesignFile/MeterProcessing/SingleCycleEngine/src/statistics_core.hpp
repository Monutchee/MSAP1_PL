#ifndef SINGLE_CYCLE_STATISTICS_CORE_HPP
#define SINGLE_CYCLE_STATISTICS_CORE_HPP

#include "metering_types.hpp"
#include "metrology_stats.hpp"
#include "single_cycle_result.hpp"

// StatisticsCore: the single-cycle engine's sample-domain accumulation
// (metrology roadmap M3, handover §6). A separate C++ module, not a
// separate FPGA IP — it synthesizes into the single-cycle engine.
//
// Everything here is a mergeable sufficient statistic: the 10/12-cycle
// tier adds these across cycles and finalizes from the merged values
// (never from per-cycle finalized readings). Widths and the saturation/
// clamp rules are normative in single_cycle_result.hpp; the arithmetic
// primitives come from metrology_stats.hpp so this module restates no
// accumulator behaviour.
//
// Semantic lane mapping is centralized in metering_types.hpp
// (MET_LANE_*); the line-line pair order is Vab, Vbc, Vca (MET_VLL_PAIRS
// order), computed on INSTANTANEOUS differences — never sqrt(3)*VLN,
// which is invalid for unbalanced or distorted systems (handover §6).

struct cycle_statistics_t {
  ap_int<128> sum[MET_ACTIVE_CHANNELS];
  ap_uint<128> square[MET_ACTIVE_CHANNELS];
  ap_int<64> raw_sum[MET_ACTIVE_CHANNELS];
  ap_uint<96> raw_square[MET_ACTIVE_CHANNELS];
  ap_int<64> minimum[MET_ACTIVE_CHANNELS];
  ap_int<64> maximum[MET_ACTIVE_CHANNELS];
  ap_uint<128> vll_square[MET_VLL_PAIRS];
  ap_uint<64> vll_peak[MET_VLL_PAIRS];
};

// The three line-line pairs as (minuend, subtrahend) lane roles.
static const int MET_VLL_MINUEND[MET_VLL_PAIRS] = {MET_LANE_VA, MET_LANE_VB,
                                                   MET_LANE_VC};
static const int MET_VLL_SUBTRAHEND[MET_VLL_PAIRS] = {MET_LANE_VB, MET_LANE_VC,
                                                      MET_LANE_VA};

// Accumulate one accepted frame. first_frame seeds every field in place
// (the house seed-in-place idiom: no separate clear pass, so the window
// clears wherever sample_count resets). sticky_overflow reports square
// saturation and the defensive line-line clamp.
inline void accumulate_statistics(cycle_statistics_t &acc,
                                  const ap_int<64> q16[MET_ACTIVE_CHANNELS],
                                  const ap_int<32> raw[MET_ACTIVE_CHANNELS],
                                  const bool first_frame,
                                  ap_uint<1> &sticky_overflow) {
#pragma HLS INLINE
stat_lanes:
  for (int lane = 0; lane < MET_ACTIVE_CHANNELS; ++lane) {
#pragma HLS PIPELINE off
    const ap_int<64> sample = q16[lane];
    const ap_int<128> sum_base = first_frame ? ap_int<128>(0) : acc.sum[lane];
    acc.sum[lane] = sum_base + sample;

    const ap_uint<128> square = ap_uint<128>(sample * sample);
    const ap_uint<128> square_base =
        first_frame ? ap_uint<128>(0) : acc.square[lane];
    acc.square[lane] =
        met_add_square_saturating<128>(square_base, square, sticky_overflow);

    const ap_int<64> raw_sum_base =
        first_frame ? ap_int<64>(0) : acc.raw_sum[lane];
    acc.raw_sum[lane] = raw_sum_base + raw[lane];
    const ap_uint<96> raw_square_base =
        first_frame ? ap_uint<96>(0) : acc.raw_square[lane];
    acc.raw_square[lane] =
        raw_square_base + ap_uint<96>(ap_uint<64>(raw[lane] * raw[lane]));

    if (first_frame || sample < acc.minimum[lane]) {
      acc.minimum[lane] = sample;
    }
    if (first_frame || sample > acc.maximum[lane]) {
      acc.maximum[lane] = sample;
    }
  }

vll_pairs:
  for (int pair = 0; pair < MET_VLL_PAIRS; ++pair) {
#pragma HLS PIPELINE off
    // Instantaneous difference; 65 bits exact, defensively clamped to the
    // 64-bit rails (unreachable with real 24-bit-derived samples) so the
    // square stays in the shared 128-bit saturating domain.
    const ap_int<65> difference = ap_int<65>(q16[MET_VLL_MINUEND[pair]]) -
                                  ap_int<65>(q16[MET_VLL_SUBTRAHEND[pair]]);
    ap_int<64> clamped;
    if (difference > ap_int<65>(ap_int<64>(0x7FFFFFFFFFFFFFFFll))) {
      clamped = ap_int<64>(0x7FFFFFFFFFFFFFFFll);
      sticky_overflow = 1;
    } else if (difference < ap_int<65>(-ap_int<65>(1) << 63)) {
      clamped = ap_int<64>(ap_uint<64>(1) << 63);
      sticky_overflow = 1;
    } else {
      clamped = ap_int<64>(difference);
    }

    const ap_uint<128> square = ap_uint<128>(clamped * clamped);
    const ap_uint<128> square_base =
        first_frame ? ap_uint<128>(0) : acc.vll_square[pair];
    acc.vll_square[pair] =
        met_add_square_saturating<128>(square_base, square, sticky_overflow);

    const ap_uint<64> magnitude = met_abs<64>(clamped);
    if (first_frame || magnitude > acc.vll_peak[pair]) {
      acc.vll_peak[pair] = magnitude;
    }
  }
}

// Copy the cycle's statistics into the result beat sections.
inline void export_statistics(const cycle_statistics_t &acc,
                              single_cycle_result_t &result) {
#pragma HLS INLINE
export_lanes:
  for (int lane = 0; lane < MET_ACTIVE_CHANNELS; ++lane) {
#pragma HLS UNROLL
    result.sum[lane] = acc.sum[lane];
    result.square[lane] = acc.square[lane];
    result.raw_sum[lane] = acc.raw_sum[lane];
    result.raw_square[lane] = acc.raw_square[lane];
    result.minimum[lane] = acc.minimum[lane];
    result.maximum[lane] = acc.maximum[lane];
  }
export_pairs:
  for (int pair = 0; pair < MET_VLL_PAIRS; ++pair) {
#pragma HLS UNROLL
    result.vll_square[pair] = acc.vll_square[pair];
    result.vll_peak[pair] = acc.vll_peak[pair];
  }
}

#endif  // SINGLE_CYCLE_STATISTICS_CORE_HPP
