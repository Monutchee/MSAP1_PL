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

#endif  // MSAP1_METROLOGY_TRIG_HPP
