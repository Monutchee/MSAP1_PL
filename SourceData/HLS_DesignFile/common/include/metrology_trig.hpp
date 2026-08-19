#ifndef MSAP1_METROLOGY_TRIG_HPP
#define MSAP1_METROLOGY_TRIG_HPP

// metering_types.hpp first: it raises AP_INT_MAX_W before ap_int.h.
#include "metering_types.hpp"

#include "metrology_sine_lut.hpp"

#include <ap_int.h>

// Shared fixed-point trigonometry: the quarter-wave Q1.17 table (4096
// points per cycle) with 20-bit linear interpolation, carried at full
// Q1.37 precision so the single floor happens in the CALLER's product.
// Sine error is bounded by the table quantization (2^-18 of full scale)
// plus the interpolation sagitta (~2.9e-7): spurs below -100 dBc, phase
// resolution 2*pi/2^24.
//
// Extracted from the ADC simulator's waveform engine (bit-identical to
// its private original) when PhasorCore needed the same evaluation for
// the synchronous correlation. Golden models deliberately use libm
// doubles, never this table, so producer and measurement sharing one
// sine cannot mask a systematic error in verification.

// Sine of one 12-bit point index folded onto the 1025-entry quarter-wave
// table; the +1 neighbour for interpolation goes through the same fold.
inline ap_int<18> met_sine_point(const ap_uint<12> point) {
#pragma HLS INLINE
  const ap_uint<2> quadrant = point.range(11, 10);
  const ap_uint<10> q = point.range(9, 0);
  const ap_uint<11> idx =
      (quadrant[0] == 0) ? ap_uint<11>(q) : ap_uint<11>(1024 - ap_uint<11>(q));
  const ap_int<18> value = ap_int<18>(MET_SINE_QLUT[idx]);
  return (quadrant[1] == 0) ? value : ap_int<18>(-value);
}

// Q0.32 turns -> Q1.37 sine (Q1.17 table value carrying the full 20-bit
// interpolation fraction; no floor here — see the header comment).
inline ap_int<39> met_sin_q32(const ap_uint<32> phase) {
#pragma HLS INLINE
  const ap_uint<12> point = phase.range(31, 20);
  const ap_uint<20> frac = phase.range(19, 0);
  const ap_int<18> s0 = met_sine_point(point);
  const ap_int<18> s1 = met_sine_point(ap_uint<12>(point + 1));
  const ap_int<19> diff = ap_int<19>(s1) - ap_int<19>(s0);
  const ap_int<41> step = diff * ap_int<22>(ap_uint<21>(frac));
  return ap_int<39>((ap_int<39>(s0) << 20) + ap_int<39>(step));
}

// Q0.32 turns -> Q1.37 cosine (a quarter-turn lead; Q0.32 wraps freely).
inline ap_int<39> met_cos_q32(const ap_uint<32> phase) {
#pragma HLS INLINE
  return met_sin_q32(ap_uint<32>(phase + ap_uint<32>(0x40000000u)));
}

// ---------------------------------------------------------------------------
// atan2 by CORDIC vectoring (metrology M9): angles in SIGNED Q0.32 turns,
// so subtraction of two angles wraps modulo one turn for free (two's
// complement IS the circle). 30 iterations leave a sub-LSB algorithmic
// residual; the datapath normalizes the operands to ~44 significant bits
// first, so the angle error is < 0.001 millidegree at every input scale
// — negligible against the millidegree publication unit.
//
// Rolled and INLINE off on purpose: one instance serves every angle in a
// finalize pass (the engines call it ~10 times per 200 ms block; the
// ~120-state latency is invisible at that cadence).
// ---------------------------------------------------------------------------

// atan(2^-i) / 2*pi in Q0.32 turns, i = 0..29 (i = 0 is exactly 1/8 turn).
static const ap_uint<30> MET_CORDIC_ATAN_TURNS[30] = {
    536870912, 316933406, 167458907, 85004756, 42667331, 21354465,
    10679838,  5340245,   2670163,   1335087,  667544,   333772,
    166886,    83443,     41722,     20861,    10430,    5215,
    2608,      1304,      652,       326,      163,      81,
    41,        20,        10,        5,        3,        1};

// Angle of the vector (re, im) in signed Q0.32 turns; 0 when both are 0.
// atan2(0, negative) returns -half turn (the published range is
// [-180000, 180000) millidegrees, so +180 degrees does not exist).
inline ap_int<32> met_atan2_turns(const ap_int<64> im, const ap_int<64> re) {
#pragma HLS INLINE off
  if (im == 0 && re == 0) {
    return 0;
  }
  // One guard bit so the most negative s64 input negates cleanly.
  ap_int<66> x = re;
  ap_int<66> y = im;
  // Pre-rotate the left half plane by a half turn; +1/2 and -1/2 turn
  // are the same Q0.32 code, so no quadrant case split is needed.
  ap_int<32> angle = 0;
  if (x < 0) {
    x = -x;
    y = -y;
    angle = ap_int<32>(0x80000000u);
  }
  // Normalize the dominant magnitude into [2^44, 2^45): fixed precision
  // for the shifts below regardless of the caller's scale. Serial by a
  // bit per state — this runs a handful of times per 200 ms.
  ap_uint<66> mx = (x < 0) ? ap_uint<66>(-x) : ap_uint<66>(x);
  ap_uint<66> my = (y < 0) ? ap_uint<66>(-y) : ap_uint<66>(y);
  ap_uint<66> mag = (mx > my) ? mx : my;
met_atan2_norm_up:
  for (int i = 0; i < 45; ++i) {
#pragma HLS PIPELINE off
    if (mag < (ap_uint<66>(1) << 44)) {
      mag <<= 1;
      x <<= 1;
      y <<= 1;
    }
  }
met_atan2_norm_down:
  for (int i = 0; i < 21; ++i) {
#pragma HLS PIPELINE off
    if (mag >= (ap_uint<66>(1) << 45)) {
      mag >>= 1;
      x >>= 1;
      y >>= 1;
    }
  }
  // Vectoring: drive y to zero, accumulating the rotation. The datapath
  // peaks below 2^47 (normalized < 2^45, CORDIC gain 1.647, plus one
  // add), so 48 signed bits hold it.
  ap_int<48> cx = ap_int<48>(x);
  ap_int<48> cy = ap_int<48>(y);
met_atan2_vector:
  for (int i = 0; i < 30; ++i) {
#pragma HLS PIPELINE off
    const ap_int<48> xs = cx >> i;
    const ap_int<48> ys = cy >> i;
    if (cy >= 0) {
      cx += ys;
      cy -= xs;
      angle += ap_int<32>(MET_CORDIC_ATAN_TURNS[i]);
    } else {
      cx -= ys;
      cy += xs;
      angle -= ap_int<32>(MET_CORDIC_ATAN_TURNS[i]);
    }
  }
  return angle;
}

// Signed Q0.32 turns -> millidegrees in [-180000, 180000), floor.
inline ap_int<32> met_turns_to_millidegrees(const ap_int<32> turns) {
#pragma HLS INLINE off
  const ap_int<52> scaled = ap_int<52>(turns) * ap_int<20>(360000);
  return ap_int<32>((scaled >> 32).range(31, 0));
}

#endif  // MSAP1_METROLOGY_TRIG_HPP
