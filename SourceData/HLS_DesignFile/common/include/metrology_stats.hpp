#ifndef MSAP1_METROLOGY_STATS_HPP
#define MSAP1_METROLOGY_STATS_HPP

// metering_types.hpp first: it raises AP_INT_MAX_W before ap_int.h.
#include "metering_types.hpp"

#include "metrology_math.hpp"

#include <ap_int.h>

// Shared statistical primitives for the MSAP1 HLS engines: the
// accumulate-then-finalize idioms that every measurement tier repeats.
// Extracted verbatim from the MTR1 basic engine (which itself pinned them
// to the retired meter_rms.vhd), so the semantics below are normative and
// bit-exact:
//
//   * magnitudes and means use sign-magnitude arithmetic with floor
//     division; a truncation to the output width happens BEFORE the sign
//     is restored (truncation toward zero);
//   * square accumulators saturate to all-ones with a sticky overflow
//     flag on carry-out — never wrap;
//   * mean-corrected variance clamps and flags rather than truncating:
//     square*count overflowing 128 bits saturates the numerator, a
//     |sum| too wide to square exactly zeroes it, and a subtraction
//     that would go negative clamps to zero — each with the flag set;
//   * roots are exact floors (floor_sqrt_128).

// |value| as an unsigned of the same width (sign-magnitude splits).
template <int WIDTH>
ap_uint<WIDTH> met_abs(const ap_int<WIDTH> value) {
#pragma HLS INLINE
  return (value < 0) ? ap_uint<WIDTH>(-value) : ap_uint<WIDTH>(value);
}

// base + square, saturating to all-ones with the sticky flag on
// carry-out (the meter_rms square-accumulator rule). Callers seed with
// base = 0 on a window's first sample (seed-in-place: no clear pass).
template <int ACC_WIDTH>
ap_uint<ACC_WIDTH> met_add_square_saturating(const ap_uint<ACC_WIDTH> base,
                                             const ap_uint<ACC_WIDTH> square,
                                             ap_uint<1> &sticky_overflow) {
#pragma HLS INLINE
  const ap_uint<ACC_WIDTH + 1> extended =
      ap_uint<ACC_WIDTH + 1>(base) + ap_uint<ACC_WIDTH + 1>(square);
  if (extended.bit(ACC_WIDTH) == 1) {
    sticky_overflow = 1;
    return ~ap_uint<ACC_WIDTH>(0);
  }
  return extended.range(ACC_WIDTH - 1, 0);
}

// base + addend, saturating at BOTH signed rails with the sticky flag
// (the signed sibling of met_add_square_saturating, for accumulators
// whose terms can be negative — power cross-products). Callers seed with
// base = 0 on a window's first sample.
template <int ACC_WIDTH>
ap_int<ACC_WIDTH> met_add_signed_saturating(const ap_int<ACC_WIDTH> base,
                                            const ap_int<ACC_WIDTH> addend,
                                            ap_uint<1> &sticky_overflow) {
#pragma HLS INLINE
  const ap_int<ACC_WIDTH + 1> extended =
      ap_int<ACC_WIDTH + 1>(base) + ap_int<ACC_WIDTH + 1>(addend);
  const ap_int<ACC_WIDTH + 1> maximum =
      ap_int<ACC_WIDTH + 1>((ap_uint<ACC_WIDTH>(1) << (ACC_WIDTH - 1)) - 1);
  if (extended > maximum) {
    sticky_overflow = 1;
    return ap_int<ACC_WIDTH>(maximum);
  }
  if (extended < -maximum - 1) {
    sticky_overflow = 1;
    return ap_int<ACC_WIDTH>(-maximum - 1);
  }
  return ap_int<ACC_WIDTH>(extended);
}

// Signed mean: floor(|sum| / count) truncated to OUT_WIDTH bits, THEN
// negated when the sum was negative. The truncation-before-negation
// order is normative (meter_rms CALC_MEAN_* states).
template <int SUM_WIDTH, int OUT_WIDTH>
ap_int<OUT_WIDTH> met_floor_mean_signed(const ap_int<SUM_WIDTH> sum,
                                        const ap_uint<32> count) {
#pragma HLS INLINE
  const bool negative = (sum < 0);
  const ap_uint<SUM_WIDTH> magnitude = met_abs<SUM_WIDTH>(sum);
  const ap_uint<SUM_WIDTH> quotient =
      floor_div<SUM_WIDTH>(magnitude, ap_uint<SUM_WIDTH>(count));
  const ap_uint<OUT_WIDTH> truncated = quotient.range(OUT_WIDTH - 1, 0);
  return negative ? ap_int<OUT_WIDTH>(-ap_int<OUT_WIDTH>(truncated))
                  : ap_int<OUT_WIDTH>(truncated);
}

// Mean-corrected RMS from a window's accumulators:
//
//   variance = (square*count [saturate+flag above 2**128]
//               - |sum|**2 when dc_remove [flag+clamp rules])
//              / count**2, floor
//   rms      = floor(sqrt(variance))
//
// The |sum|-too-wide rule (RTL variance_sum_too_wide): a magnitude that
// does not fit 64 bits cannot be squared exactly in 128, so the
// numerator zeroes with the flag. Accumulators whose sums cannot exceed
// 64 bits (SUM_WIDTH <= 64, e.g. the raw-count path) can never trip it,
// preserving that path's behaviour without a separate variant.
template <int SQUARE_WIDTH, int SUM_WIDTH>
ap_uint<64> met_rms_from_accumulators(const ap_uint<SQUARE_WIDTH> square,
                                      const ap_int<SUM_WIDTH> sum,
                                      const ap_uint<32> count,
                                      const ap_uint<1> dc_remove,
                                      ap_uint<1> &overflow) {
#pragma HLS INLINE off
  static_assert(SQUARE_WIDTH <= 128, "square accumulator exceeds the recurrence");
  static_assert(SUM_WIDTH <= 128, "sum accumulator exceeds the recurrence");
  const ap_uint<160> product = ap_uint<160>(square) * count;
  ap_uint<128> numerator;
  if (product.range(159, 128) != 0) {
    overflow = 1;
    numerator = ~ap_uint<128>(0);
  } else {
    numerator = product.range(127, 0);
  }
  if (dc_remove == 1) {
    const ap_uint<SUM_WIDTH> magnitude = met_abs<SUM_WIDTH>(sum);
    // Shifts of >= the operand width yield zero, so a <= 64-bit sum
    // reduces this to the plain subtract-with-clamp path.
    const ap_uint<SUM_WIDTH> high = magnitude >> 64;
    if (high != 0) {
      overflow = 1;
      numerator = 0;
    } else {
      const ap_uint<64> low = magnitude.range(
          (SUM_WIDTH > 64 ? 64 : SUM_WIDTH) - 1, 0);
      const ap_uint<128> sum_square = ap_uint<128>(low) * low;
      if (numerator >= sum_square) {
        numerator -= sum_square;
      } else {
        numerator = 0;
        overflow = 1;
      }
    }
  }
  const ap_uint<128> denominator = ap_uint<128>(ap_uint<64>(count) * count);
  return floor_sqrt_128(floor_div<128>(numerator, denominator));
}


// ---------------------------------------------------------------------------
// Fundamental-phasor finalization (M5 single-cycle diagnostic, M9 tier
// finalizer — one definition so the two stay bit-identical).
// ---------------------------------------------------------------------------

// Mean phasor component in signed Q16 counts: floor mean of the Q1.37
// correlation sum (phasor_core.hpp), then the single >> 37 trig-domain
// floor. Truncation to 64 bits is exact under the sample contract
// (components stay below 2^40); a saturated flagged sum can exceed it,
// and that divergence is confined to overflow-flagged results.
inline ap_int<64> met_phasor_counts(const ap_int<128> sum,
                                    const ap_uint<32> count) {
#pragma HLS INLINE off
  const ap_int<128> mean = met_floor_mean_signed<128, 128>(sum, count);
  return ap_int<64>((mean >> 37).range(63, 0));
}

// Fundamental RMS in Q16 counts from the mean phasor components:
// |(re, im)| * sqrt(2) (amplitude = 2|mean|, RMS = amplitude / sqrt(2)).
// sqrt(2) is the Q16 constant 92682 — a documented ~1.2e-6 high bias;
// the exact sums stay on the beat for the authoritative tiers.
inline ap_uint<64> met_phasor_rms_q16(const ap_int<64> re_counts,
                                      const ap_int<64> im_counts) {
#pragma HLS INLINE off
  const ap_uint<128> magnitude_square =
      ap_uint<128>(re_counts * re_counts) +
      ap_uint<128>(im_counts * im_counts);
  const ap_uint<64> magnitude = floor_sqrt_128(magnitude_square);
  return ap_uint<64>((ap_uint<81>(magnitude) * 92682) >> 16);
}

// True power factor in millionths (M8, shared with the later displacement
// and energy tiers): floor(|P| * 1e6 / S) carrying P's sign. Clamped to
// +/-1e6 -- Cauchy-Schwarz bounds |P| <= S mathematically, but the two
// values reach here through different floor chains and the ratio can
// land a hair above one. Returns 0 when either input is 0: PF is
// UNDEFINED there and consumers must gate on S, never on PF alone.
inline ap_int<32> met_power_factor_e6(const ap_int<64> active_pw,
                                      const ap_uint<64> apparent_pw) {
#pragma HLS INLINE off
  if (active_pw == 0 || apparent_pw == 0) {
    return 0;
  }
  const ap_uint<64> magnitude = met_abs<64>(active_pw);
  const ap_uint<128> scaled =
      ap_uint<128>(magnitude) * ap_uint<128>(1000000);
  const ap_uint<128> ratio =
      floor_div<128>(scaled, ap_uint<128>(apparent_pw));
  const ap_uint<32> clamped = ratio > ap_uint<128>(1000000)
                                  ? ap_uint<32>(1000000)
                                  : ap_uint<32>(ratio.range(31, 0));
  return active_pw < 0 ? ap_int<32>(-ap_int<33>(clamped))
                       : ap_int<32>(clamped);
}

#endif  // MSAP1_METROLOGY_STATS_HPP
