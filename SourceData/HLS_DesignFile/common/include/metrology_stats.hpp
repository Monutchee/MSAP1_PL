#ifndef MSAP1_METROLOGY_STATS_HPP
#define MSAP1_METROLOGY_STATS_HPP

// metering_types.hpp first: it raises AP_INT_MAX_W before ap_int.h.
#include "metering_types.hpp"

#include "metrology_math.hpp"

#include <ap_int.h>

// Shared statistical primitives for the MSAP1 HLS engines: the
// accumulate-then-finalize idioms that every measurement tier repeats.
// Extracted verbatim from the original Basic engine (which itself pinned them
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
//   variance = (square*count - |sum|**2 when dc_remove [clamp rules])
//              / count**2, floor
//   rms      = floor(sqrt(variance))
//
// The numerator width is derived from the accumulator width plus the complete
// 32-bit sample count.  This is not optional headroom: at 120 V Q16 a valid
// 10-minute result needs about 139 numerator bits and a 2-hour result needs
// about 146.  The former 128-bit intermediate therefore reported a false
// arithmetic saturation even though the stored 128-bit square accumulator was
// still in range.
//
// At most half the numerator width is available to |sum| before squaring.  A
// narrower caller keeps its declared sum width: the engineering path uses 80
// bits (enough for the supported 2-hour interval), while the raw-count and
// sliding-window paths retain their existing 64-bit sums.  A true value
// outside those declared bounds still sets the sticky arithmetic flag.
template <int SQUARE_WIDTH, int SUM_WIDTH,
          int NUMERATOR_WIDTH = SQUARE_WIDTH + 32>
ap_uint<64> met_rms_from_accumulators(const ap_uint<SQUARE_WIDTH> square,
                                      const ap_int<SUM_WIDTH> sum,
                                      const ap_uint<32> count,
                                      const ap_uint<1> dc_remove,
                                      ap_uint<1> &overflow) {
#pragma HLS INLINE off
  static_assert(SQUARE_WIDTH <= 128, "square accumulator exceeds the recurrence");
  static_assert(SUM_WIDTH <= 128, "sum accumulator exceeds the recurrence");
  static_assert(NUMERATOR_WIDTH == SQUARE_WIDTH + 32,
                "numerator must retain every square*count product bit");
  static_assert((NUMERATOR_WIDTH % 2) == 0,
                "mean-correction square root width must be integral");
  static const int SUM_MAGNITUDE_WIDTH =
      (SUM_WIDTH < (NUMERATOR_WIDTH / 2)) ? SUM_WIDTH
                                          : (NUMERATOR_WIDTH / 2);

  ap_uint<NUMERATOR_WIDTH> numerator =
      ap_uint<NUMERATOR_WIDTH>(square) * ap_uint<32>(count);
  if (dc_remove == 1) {
    const ap_uint<SUM_WIDTH> magnitude = met_abs<SUM_WIDTH>(sum);
    const ap_uint<SUM_WIDTH> high = magnitude >> SUM_MAGNITUDE_WIDTH;
    if (high != 0) {
      overflow = 1;
      numerator = 0;
    } else {
      const ap_uint<SUM_MAGNITUDE_WIDTH> low =
          magnitude.range(SUM_MAGNITUDE_WIDTH - 1, 0);
      const ap_uint<2 * SUM_MAGNITUDE_WIDTH> sum_square_narrow = low * low;
      const ap_uint<NUMERATOR_WIDTH> sum_square = sum_square_narrow;
      if (numerator >= sum_square) {
        numerator -= sum_square;
      } else {
        numerator = 0;
        overflow = 1;
      }
    }
  }
  const ap_uint<64> denominator = ap_uint<64>(count) * count;
  const ap_uint<NUMERATOR_WIDTH> mean_square =
      floor_div_narrow<NUMERATOR_WIDTH, 64>(numerator, denominator);

  // The public result is a 64-bit Q16 magnitude, so its squared value must fit
  // 128 bits.  Clamp only genuine out-of-contract magnitudes here; supported
  // long windows have a wide numerator but their divided mean square is small.
  if ((mean_square >> 128) != 0) {
    overflow = 1;
    return ~ap_uint<64>(0);
  }
  return floor_sqrt_128(ap_uint<128>(mean_square));
}


// ---------------------------------------------------------------------------
// Fundamental-phasor finalization (M5 single-cycle diagnostic, M9 tier
// finalizer — one definition so the two stay bit-identical).
// ---------------------------------------------------------------------------

// Mean phasor component in signed Q16 counts: floor mean of the Q1.37
// correlation sum (phasor_core.hpp), then the single >> 37 trig-domain
// floor. A mean phasor component cannot exceed the sample magnitude,
// which adc_conversion already saturates into signed 64 bits, so the
// truncation is exact for every real input; a saturated flagged sum can
// exceed it, and that divergence stays confined to results the
// arithmetic flag already marks.
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

// ---------------------------------------------------------------------------
// Symmetrical components (M10) — the a-operator on mean phasors, and the
// unbalance ratio. Conventions are normative in metering_types.hpp.
// ---------------------------------------------------------------------------

// round(sqrt(3)/2 * 2^30): the only irrational the a-operator needs.
// Q30 keeps the constant's relative error ~5e-10, far below the
// micro-unit publication grain at every contract-legal magnitude.
static const ap_int<31> MET_SQRT3_HALF_Q30 = 929887697;

// Rotate a mean-phasor vector by either +120 degrees (the 'a' operator) or
// +240 degrees ('a squared').  One direction-selectable function is
// intentional: the interval algorithm invokes the rotations sequentially,
// so HLS can time-share one pair of constant multipliers instead of creating
// separate +120 and +240 degree datapaths.  This trades a few cycles at the
// low-rate interval finalizer for substantially less placed arithmetic.
//
// a:  re' = -re/2 - im*sqrt(3)/2, im' =  re*sqrt(3)/2 - im/2
// a2: re' = -re/2 + im*sqrt(3)/2, im' = -re*sqrt(3)/2 - im/2
//
// Floor semantics come from the arithmetic >> 30. Components stay below
// 2^41 for contract-max inputs, so the 64-bit outputs cannot wrap outside
// already-flagged results.
inline void met_rotate_120(const ap_int<64> re, const ap_int<64> im,
                           const bool squared,
                           ap_int<64> &out_re, ap_int<64> &out_im) {
#pragma HLS INLINE off
  const ap_int<96> re_half = ap_int<96>(re) << 29;
  const ap_int<96> im_half = ap_int<96>(im) << 29;
  const ap_int<96> re_s3 = ap_int<96>(ap_int<96>(re) * MET_SQRT3_HALF_Q30);
  const ap_int<96> im_s3 = ap_int<96>(ap_int<96>(im) * MET_SQRT3_HALF_Q30);
  const ap_int<96> rotated_re =
      squared ? ap_int<96>(-re_half + im_s3)
              : ap_int<96>(-re_half - im_s3);
  const ap_int<96> rotated_im =
      squared ? ap_int<96>(-re_s3 - im_half)
              : ap_int<96>( re_s3 - im_half);
  out_re = ap_int<64>((rotated_re >> 30).range(63, 0));
  out_im = ap_int<64>((rotated_im >> 30).range(63, 0));
}

// Symmetrical components of three mean phasors given in A/B/C order:
// out index 0 = zero sequence, 1 = positive, 2 = negative. Each division
// by 3 uses the house trunc-toward-zero mean.
inline void met_sequence_components(const ap_int<64> re[3],
                                    const ap_int<64> im[3],
                                    ap_int<64> seq_re[3],
                                    ap_int<64> seq_im[3]) {
#pragma HLS INLINE off
  ap_int<64> b_a_re, b_a_im, b_a2_re, b_a2_im;
  ap_int<64> c_a_re, c_a_im, c_a2_re, c_a2_im;
  met_rotate_120(re[1], im[1], false, b_a_re, b_a_im);
  met_rotate_120(re[1], im[1], true, b_a2_re, b_a2_im);
  met_rotate_120(re[2], im[2], false, c_a_re, c_a_im);
  met_rotate_120(re[2], im[2], true, c_a2_re, c_a2_im);
  const ap_uint<32> three = 3;
  seq_re[0] = met_floor_mean_signed<66, 64>(
      ap_int<66>(re[0]) + re[1] + re[2], three);
  seq_im[0] = met_floor_mean_signed<66, 64>(
      ap_int<66>(im[0]) + im[1] + im[2], three);
  seq_re[1] = met_floor_mean_signed<66, 64>(
      ap_int<66>(re[0]) + b_a_re + c_a2_re, three);
  seq_im[1] = met_floor_mean_signed<66, 64>(
      ap_int<66>(im[0]) + b_a_im + c_a2_im, three);
  seq_re[2] = met_floor_mean_signed<66, 64>(
      ap_int<66>(re[0]) + b_a2_re + c_a_re, three);
  seq_im[2] = met_floor_mean_signed<66, 64>(
      ap_int<66>(im[0]) + b_a2_im + c_a_im, three);
}

// Unsigned ratio in millionths: floor(numerator * 1e6 / denominator),
// clamped to the 32-bit rail (a reversed-rotation feed makes |X2|/|X1|
// astronomically large). Returns 0 when the denominator is 0: the ratio
// is UNDEFINED there and consumers must gate on the validity flag.
inline ap_uint<32> met_ratio_e6(const ap_uint<64> numerator,
                                const ap_uint<64> denominator) {
#pragma HLS INLINE off
  if (denominator == 0) {
    return 0;
  }
  const ap_uint<128> scaled =
      ap_uint<128>(numerator) * ap_uint<128>(1000000);
  const ap_uint<128> ratio = floor_div<128>(scaled, ap_uint<128>(denominator));
  return ratio > ap_uint<128>(0xFFFFFFFFu) ? ap_uint<32>(0xFFFFFFFFu)
                                           : ap_uint<32>(ratio.range(31, 0));
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
