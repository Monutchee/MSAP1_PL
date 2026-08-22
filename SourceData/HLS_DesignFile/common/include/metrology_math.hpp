#ifndef MSAP1_METROLOGY_MATH_HPP
#define MSAP1_METROLOGY_MATH_HPP

// metering_types.hpp first: it raises AP_INT_MAX_W before ap_int.h.
#include "metering_types.hpp"

#include <ap_int.h>

// Shared serial arithmetic for the MSAP1 HLS engines.
//
// Every routine here is deliberately bit-serial (one result bit per loop
// iteration, PIPELINE off) — the area shaping proven in the
// CycleAggregator trial: at metering rates latency is free and the rolled
// loops keep each algorithm on one small hardware copy instead of the
// unrolled/reciprocal forms HLS schedules by default.
//
// Semantics are pinned to the retired VHDL engines: floor everywhere,
// explicit saturation where the RTL saturated, nothing rounds.

// floor(dividend / divisor) by restoring long division, one quotient bit
// per iteration — the meter_rms.vhd divider strategy (CALC_DIVIDE_*
// states). divisor = 0 yields an all-ones quotient (the restoring
// recurrence never subtracts), which the callers exclude by contract:
// meter_rms divides by the sample count (>= 1 at any window close) and by
// its square.
template <int WIDTH>
ap_uint<WIDTH> floor_div(ap_uint<WIDTH> dividend, ap_uint<WIDTH> divisor) {
  ap_uint<WIDTH> quotient = 0;
  ap_uint<WIDTH + 1> remainder = 0;
div_bits:
  for (int bit = WIDTH - 1; bit >= 0; --bit) {
#pragma HLS PIPELINE off
    remainder = (remainder << 1) | ap_uint<WIDTH + 1>(dividend.bit(bit));
    if (remainder >= ap_uint<WIDTH + 1>(divisor)) {
      remainder -= ap_uint<WIDTH + 1>(divisor);
      quotient.bit(bit) = 1;
    }
  }
  return quotient;
}

// floor(dividend / divisor) when the divisor is narrower than the dividend.
// The restoring remainder is always below the divisor before the shift and
// below 2*divisor afterwards, so DIVISOR_WIDTH+1 bits are sufficient.  This is
// particularly important for long metrology windows: their variance numerator
// is 160 bits, but count^2 remains 64 bits.  Carrying a 161-bit remainder and
// comparator through all 160 serial steps would add area without changing one
// result bit.
template <int DIVIDEND_WIDTH, int DIVISOR_WIDTH>
ap_uint<DIVIDEND_WIDTH> floor_div_narrow(
    ap_uint<DIVIDEND_WIDTH> dividend,
    ap_uint<DIVISOR_WIDTH> divisor) {
  static_assert(DIVISOR_WIDTH <= DIVIDEND_WIDTH,
                "narrow divisor cannot exceed the dividend width");
  ap_uint<DIVIDEND_WIDTH> quotient = 0;
  ap_uint<DIVISOR_WIDTH + 1> remainder = 0;
div_narrow_bits:
  for (int bit = DIVIDEND_WIDTH - 1; bit >= 0; --bit) {
#pragma HLS PIPELINE off
    remainder = (remainder << 1) |
                ap_uint<DIVISOR_WIDTH + 1>(dividend.bit(bit));
    if (remainder >= ap_uint<DIVISOR_WIDTH + 1>(divisor)) {
      remainder -= ap_uint<DIVISOR_WIDTH + 1>(divisor);
      quotient.bit(bit) = 1;
    }
  }
  return quotient;
}

// Smallest bit count that can represent VALUE (met_bit_width<29>::value
// is 5). Used to size compile-time-known remainders exactly.
template <unsigned long long VALUE>
struct met_bit_width {
  static const int value = 1 + met_bit_width<(VALUE >> 1)>::value;
};
template <>
struct met_bit_width<0ULL> {
  static const int value = 0;
};

// floor(dividend / DIVISOR) for a compile-time divisor, by the same
// restoring recurrence as floor_div. The remainder before each subtract
// is at most 2*DIVISOR - 1, so it is sized exactly for the divisor
// instead of carrying a full-width remainder for nothing (generalized
// from the aggregation engine's private floor_div_15; DIVISOR = 15 is
// bit-identical to it).
template <int WIDTH, int DIVISOR>
ap_uint<WIDTH> floor_div_const(ap_uint<WIDTH> dividend) {
  static_assert(DIVISOR >= 2, "a constant divisor below 2 divides nothing");
  ap_uint<WIDTH> quotient = 0;
  ap_uint<met_bit_width<2ULL * DIVISOR - 1ULL>::value> remainder = 0;
div_bits:
  for (int bit = WIDTH - 1; bit >= 0; --bit) {
#pragma HLS PIPELINE off
    remainder = (remainder << 1) | decltype(remainder)(dividend.bit(bit));
    if (remainder >= DIVISOR) {
      remainder -= DIVISOR;
      quotient.bit(bit) = 1;
    }
  }
  return quotient;
}

// floor(sqrt(radicand)) by binary digit recurrence (restoring): exact for
// the full 128-bit radicand range, no multiplier. meter_rms.vhd reaches
// the same floor value through a 64-step binary search with a 64x64
// multiply (CALC_SQRT_* states) and the result range never clips: any
// 128-bit radicand has a floor root below 2**64. Shared by both engines.
inline ap_uint<64> floor_sqrt_128(ap_uint<128> radicand) {
  ap_uint<64> root = 0;
  ap_uint<66> remainder = 0;
sqrt_digits:
  for (int step = 0; step < 64; ++step) {
#pragma HLS PIPELINE off
    remainder = (remainder << 2) |
                radicand.range(127 - 2 * step, 126 - 2 * step);
    const ap_uint<66> trial = (ap_uint<66>(root) << 2) | 1;
    if (remainder >= trial) {
      remainder -= trial;
      root = (root << 1) | 1;
    } else {
      root = root << 1;
    }
  }
  return root;
}

#endif  // MSAP1_METROLOGY_MATH_HPP
