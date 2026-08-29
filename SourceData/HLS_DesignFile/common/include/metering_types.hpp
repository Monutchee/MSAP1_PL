#ifndef MSAP1_METERING_TYPES_HPP
#define MSAP1_METERING_TYPES_HPP

// The widest logical packed test image is the 7072-bit SingleCycleResult,
// past ap_int's 1024-bit default ceiling. The synthesized inter-engine
// transport is an ordered 32-bit packet; this width remains for explicit
// golden/equivalence packing only.
// This must precede the first ap_int.h inclusion in every translation
// unit; each component's cflags also pass -DAP_INT_MAX_W sized for the
// beats it actually touches, so an unlucky include order cannot regress
// it (single_cycle_result.hpp additionally #errors below 8192).
#ifndef AP_INT_MAX_W
#define AP_INT_MAX_W 8192
#endif

#include <ap_int.h>

#include <cstdint>

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
// Every record and internal result carries eight RMS lanes. Lanes 0..3 are
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

// Power phases in A/B/C order; each pairs a voltage lane with its phase
// current (Va*Ia, Vb*Ib, Vc*Ic).
static const int MET_POWER_PHASES = 3;

// ---------------------------------------------------------------------------
// Sign conventions (normative for every power/energy quantity, PL and
// APU alike — the handover §16 rules, decided here once):
//
//   * Active power P:   import / consuming load is POSITIVE,
//                       export / generation is NEGATIVE.
//     P follows directly from the signed cross-product sum: with the
//     wiring convention that positive current flows INTO the load while
//     the voltage is positive, sum(v*i) > 0 is import.
//   * Reactive power Q (from M9): lagging / inductive is POSITIVE,
//                       leading / capacitive is NEGATIVE.
//   * Leading/lagging classification derives from the SIGN of Q, never
//     from a power-factor magnitude.
//   * Apparent power S (M8): per phase S = Vrms x Irms, UNSIGNED; the
//     total S is the ARITHMETIC sum of the phase values (4-wire
//     convention). No vector apparent power anywhere.
//   * True power factor PF (M8): P / S, sign follows P, published in
//     millionths. PF is UNDEFINED when S = 0 and the record then
//     carries 0 -- consumers must gate on S, never infer from PF alone.
//     The total PF is P_total / S_total; phase PFs are NEVER averaged.
//   * Crest factor (M8): peak / RMS per lane in ten-thousandths, with
//     peak = max(|min|, |max|) of the block's extrema and RMS as
//     finalized under the committed dc_remove; 0 when RMS = 0.
//   * Fundamental quantities (M9) come from the synchronous-correlation
//     phasors ONLY (phasor_core.hpp): P1/Q1/S1 are the fundamental
//     active/reactive/apparent powers, distinct from the M8 true
//     (all-harmonic) P/S. Q1 = V1 x I1 x sin(phi1) is computed as the
//     exact phasor cross product (no trig at finalize); lagging /
//     inductive current is POSITIVE Q1, leading / capacitive NEGATIVE.
//   * Displacement power factor (M9): cos(phi1) = P1 / S1, sign follows
//     P1, millionths, 0 = undefined when S1 = 0 -- the same gating rule
//     as the true PF, and the two are NEVER interchangeable (they
//     diverge under distortion; the divergence is an acceptance check).
//   * Load nature (M9): classified from the SIGN of Q1, never from a PF
//     magnitude: MET_NATURE_UNDEFINED when S1 = 0, else _UNITY (Q1 = 0),
//     _LAGGING (Q1 > 0, inductive), _LEADING (Q1 < 0, capacitive).
//   * Phase angles (M9; convention finalized with M11): PUBLISHED in
//     millidegrees in [0, 360000) — the industry display convention,
//     owned here in the PL — RELATIVE TO THE VA FUNDAMENTAL (VA reads
//     exactly 0; a 120-degree lag publishes as 240000). The raw
//     correlation reference (the grid-locked cycle start) is not a
//     specified quantity; only angle differences are. Records carry an
//     angle-reference-valid flag that clears when VA's fundamental is
//     absent (masked out or zero magnitude). INTERNAL angle values (the
//     Q0.32 turns domain) stay signed — wrapping subtraction is the
//     point — and map onto the positive circle only at publication.
//   * Symmetrical components (M10): from the fundamental phasors ONLY,
//     with the a-operator a = 1 at +120 degrees and the standard
//     ABC-rotation convention:
//       X0 = (Xa + Xb + Xc) / 3          (zero sequence)
//       X1 = (Xa + a.Xb + a^2.Xc) / 3    (positive sequence)
//       X2 = (Xa + a^2.Xb + a.Xc) / 3    (negative sequence)
//     A balanced ABC feed puts everything in X1; an ACB (reversed) feed
//     puts everything in X2 — that swap is the acceptance check.
//     Magnitudes publish as RMS micro-units like the fundamentals;
//     angles follow the M9 relative-to-VA convention.
//   * Unbalance ratios (M10): UNBL = |X2| / |X1| and the zero-sequence
//     ratio |X0| / |X1|, both in MILLIONTHS of the positive-sequence
//     magnitude (20000 = 2%). UNDEFINED (published 0 with the validity
//     flag clear) when |X1| = 0 — consumers gate on the flag, never on
//     the value. Voltage ratios use VA/VB/VC, current ratios IA/IB/IC
//     (never IN).
//
// Units through the chain: converted samples are Q16 micro-units
// (micro-volts / micro-amperes), so a v*i product is Q32 in
// micro-volt-micro-amperes = picowatts; record power words publish
// picowatts (product >> 32). Fundamental powers publish the same way:
// picowatts / picovars / pico-VA.
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Power-quality event conventions (M12, IEC 61000-4-30 section 5.4/5.5 —
// normative here, mirrored by pq_event_pkg.vhd and the APU decoder):
//
//   * Urms(1/2) is the RMS over ONE grid cycle refreshed every HALF cycle,
//     resynchronized to half-cycle boundaries. It is a DETECTION quantity,
//     never an aggregation input: the 10/12 and 150/180 tiers keep using
//     their own whole-cycle accumulators and are unaffected by events.
//   * Thresholds are fractions of a DECLARED reference voltage (Udin) in
//     units of 1e-4 (9000 = 90.00 %). A reference of 0 DISABLES detection:
//     periodic snapshots keep flowing but no event is ever declared, so an
//     unconfigured system cannot invent dips.
//   * Polyphase rule: an event BEGINS on the half-cycle update where ANY
//     monitored phase crosses its threshold, and ENDS only when EVERY
//     phase has recovered past the threshold plus the hysteresis. The
//     event carries the union of the phases it ever affected.
//   * Severity: a single event keeps the MOST SEVERE type it reached
//     (interruption outranks sag; swell is disjoint), so a dip that
//     deepens into an interruption is reported once, as an interruption.
//   * Residual/peak: a sag or interruption reports the MINIMUM Urms(1/2)
//     reached on any affected phase; a swell reports the MAXIMUM. Duration
//     is measured in the sample domain (first affected update to the first
//     fully recovered update), so it is exact, not a wall-clock estimate.
// ---------------------------------------------------------------------------
static const int MET_PQ_EVENT_NONE         = 0;
static const int MET_PQ_EVENT_SAG          = 1;
static const int MET_PQ_EVENT_SWELL        = 2;
static const int MET_PQ_EVENT_INTERRUPTION = 3;

// Record kinds carried in the PQ record's format-header word.
static const int MET_PQ_KIND_PERIODIC    = 0;  // heartbeat snapshot
static const int MET_PQ_KIND_EVENT_START = 1;  // event declared
static const int MET_PQ_KIND_EVENT_END   = 2;  // event characterized

// Load-nature codes (M9, record word values — APU mirror).
static const int MET_NATURE_UNDEFINED = 0;  // S1 = 0, nothing to classify
static const int MET_NATURE_UNITY     = 1;  // Q1 = 0 exactly
static const int MET_NATURE_LAGGING   = 2;  // Q1 > 0, inductive
static const int MET_NATURE_LEADING   = 3;  // Q1 < 0, capacitive

// Four-quadrant energy classification (M17).  Spell the enumerators out:
// "Q1" already means fundamental reactive power throughout the metrology
// contract and must never be overloaded to mean quadrant I.
enum class EnergyQuadrant : std::uint8_t {
  quadrant_i = 0,    // P >= 0, Q1 > 0: import, inductive/lagging
  quadrant_ii = 1,   // P < 0,  Q1 > 0: export, inductive/lagging
  quadrant_iii = 2,  // P < 0,  Q1 < 0: export, capacitive/leading
  quadrant_iv = 3,   // P >= 0, Q1 < 0: import, capacitive/leading
  none = 0xff,       // Q1 == 0: no reactive-energy contribution
};

constexpr inline EnergyQuadrant met_energy_quadrant(std::int64_t active_power,
                                                    std::int64_t reactive_power_q1) {
  if (reactive_power_q1 == 0) return EnergyQuadrant::none;
  if (reactive_power_q1 > 0) {
    return active_power < 0 ? EnergyQuadrant::quadrant_ii
                            : EnergyQuadrant::quadrant_i;
  }
  return active_power < 0 ? EnergyQuadrant::quadrant_iii
                          : EnergyQuadrant::quadrant_iv;
}

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

// One converted lane in the internal Q16 micro-unit domain.  Forty-eight
// signed bits retain 16 fractional bits and 31 magnitude bits: more than
// enough for every supported voltage/current front end, while materially
// reducing the high-rate stream, square, power, and phasor multipliers.
// Result accumulators and published quantities deliberately remain wider.
typedef ap_int<48> met_q16_t;
static const int MET_RMS_LANE_BITS  = 48;
static const int MET_RMS_LANES_BITS = MET_CHANNEL_LANES * MET_RMS_LANE_BITS;  // 384

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
