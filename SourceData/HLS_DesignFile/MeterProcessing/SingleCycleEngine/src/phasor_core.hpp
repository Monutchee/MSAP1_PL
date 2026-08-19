#ifndef SINGLE_CYCLE_PHASOR_CORE_HPP
#define SINGLE_CYCLE_PHASOR_CORE_HPP

#include "metering_types.hpp"
#include "metrology_math.hpp"
#include "metrology_stats.hpp"
#include "metrology_trig.hpp"
#include "single_cycle_result.hpp"

// PhasorCore: fundamental complex extraction by synchronous correlation
// (metrology roadmap M5, handover §8). A separate C++ module inside the
// single-cycle engine, like StatisticsCore and PowerCore.
//
// Method: one shared reference angle theta starts at 0 on the cycle's
// first accepted frame and advances by delta = floor(f * 2^32 / fs) per
// sample, with f the MEASURED frequency (millihertz) latched at cycle
// start — the correlation tracks the actual grid, never assumes a
// nominal (handover: "do not assume exactly 50.000000 Hz"). Per lane:
//
//   re_sum += x[n] * cos(theta[n])     im_sum -= x[n] * sin(theta[n])
//
// accumulated in the RAW Q1.37 trig domain (products up to 2^102, sums
// below 2^116 at every supported rate): no per-term floor, a single
// floor at finalize. The 128-bit signed saturating sums merge across
// cycles by pure addition (each cycle's reference starts at its own
// grid-locked zero crossing, so cycle frames share the reference
// orientation to within the off-nominal drift of one cycle).
//
// For x = A*sin(theta + phi), the mean over whole cycles gives
// re = (A/2)*sin(phi), im = -(A/2)*cos(phi)... i.e. |mean| = A/2: the
// finalized fundamental amplitude is 2*|mean| and the fundamental RMS
// is |mean| * sqrt(2) — the record diagnostic. Angles (atan2) arrive
// with the M9 finalizer; the beat carries exact Re/Im sums until then.

struct cycle_phasor_t {
  ap_int<128> re_sum[MET_ACTIVE_CHANNELS];
  ap_int<128> im_sum[MET_ACTIVE_CHANNELS];
};

// Per-sample reference increment from the measured frequency:
// floor(f_mHz * 2^32 / (1000 * fs)). Serial divide, once per cycle.
inline ap_uint<32> phasor_delta_q32(const ap_uint<32> frequency_millihz,
                                    const ap_uint<32> sample_rate_hz) {
#pragma HLS INLINE off
  const ap_uint<64> numerator = ap_uint<64>(frequency_millihz) << 32;
  const ap_uint<64> denominator = ap_uint<64>(sample_rate_hz) * 1000;
  return ap_uint<32>(floor_div<64>(numerator, denominator).range(31, 0));
}

// Accumulate one accepted frame at reference angle theta (seed-in-place
// on first_frame; saturation raises the shared sticky flag).
inline void accumulate_phasor(cycle_phasor_t &acc,
                              const ap_int<64> q16[MET_ACTIVE_CHANNELS],
                              const ap_uint<32> theta,
                              const bool first_frame,
                              ap_uint<1> &sticky_overflow) {
#pragma HLS INLINE
  const ap_int<39> cosine = met_cos_q32(theta);
  const ap_int<39> sine = met_sin_q32(theta);
phasor_lanes:
  for (int lane = 0; lane < MET_ACTIVE_CHANNELS; ++lane) {
#pragma HLS PIPELINE off
    const ap_int<128> re_term = ap_int<128>(q16[lane]) * cosine;
    const ap_int<128> im_term = ap_int<128>(q16[lane]) * sine;
    const ap_int<128> re_base =
        first_frame ? ap_int<128>(0) : acc.re_sum[lane];
    const ap_int<128> im_base =
        first_frame ? ap_int<128>(0) : acc.im_sum[lane];
    acc.re_sum[lane] =
        met_add_signed_saturating<128>(re_base, re_term, sticky_overflow);
    acc.im_sum[lane] =
        met_add_signed_saturating<128>(im_base, ap_int<128>(-im_term),
                                       sticky_overflow);
  }
}

inline void export_phasor(const cycle_phasor_t &acc,
                          single_cycle_result_t &result) {
#pragma HLS INLINE
export_lanes:
  for (int lane = 0; lane < MET_ACTIVE_CHANNELS; ++lane) {
#pragma HLS UNROLL
    result.phasor_re[lane] = acc.re_sum[lane];
    result.phasor_im[lane] = acc.im_sum[lane];
  }
}

// Diagnostic fundamental RMS in Q16 counts: |mean phasor| * sqrt(2).
// The arithmetic moved to common (metrology_stats.hpp) when the M9
// finalizer needed the identical chain; this composition is bit-exact to
// the original in-place form (same mean, >> 37 floor, square, root, and
// Q16 sqrt(2) constant).
inline ap_uint<64> phasor_fundamental_rms(const ap_int<128> re_sum,
                                          const ap_int<128> im_sum,
                                          const ap_uint<32> count) {
#pragma HLS INLINE off
  const ap_int<64> re_counts = met_phasor_counts(re_sum, count);
  const ap_int<64> im_counts = met_phasor_counts(im_sum, count);
  return met_phasor_rms_q16(re_counts, im_counts);
}

#endif  // SINGLE_CYCLE_PHASOR_CORE_HPP
