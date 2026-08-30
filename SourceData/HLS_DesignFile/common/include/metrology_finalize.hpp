#ifndef MSAP1_METROLOGY_FINALIZE_HPP
#define MSAP1_METROLOGY_FINALIZE_HPP

// metering_types.hpp first: it raises AP_INT_MAX_W before ap_int.h.
#include "metering_types.hpp"

#include "metrology_math.hpp"
#include "metrology_stats.hpp"
#include "metrology_trig.hpp"

#include <ap_int.h>

// The interval finalize: every derived quantity the metrology redesign
// publishes for a merged interval — per-lane mean/RMS, line-line RMS,
// P/S/true-PF/crest (M8), fundamental phasors/angles/Q1/displacement-PF/
// load-nature (M9), and symmetrical components + unbalance ratios (M10)
// — computed from the interval's summed accumulators.
//
// Extracted VERBATIM from Agg10_12CycleEngine when the 150/180-cycle
// tier (M11) needed the identical chain over 15-block sums: one
// definition, two consumers, so the tiers cannot drift. The operation
// ORDER inside is normative — the 10/12 tier's golden benches pin it
// bit-for-bit. Record-word assembly stays with each engine (their maps
// differ); this header owns only the arithmetic.
//
// All loops are rolled with PIPELINE off (the house area shape): the
// finalize runs once per 200 ms / 3 s interval, so latency is free and
// the wide operators exist once. INLINE: each engine instantiates the
// datapath once at its single call site.

// Finalized values used to cross this arithmetic/record-format boundary as a
// ~5,740-bit aggregate.  HLS implemented that aggregate as thousands of
// independently enabled registers and a wide selection network.  The values
// are consumed only after finalization and at a cadence no faster than one
// Basic block, so an indexed 32-bit scratch RAM is the natural interface.
//
// The layout is deliberately private to the PL implementation.  It is not a
// record or software ABI; the accessors below are the only supported way to
// address it.  Every location read by a formatter is written by the preceding
// finalize pass, therefore RAM contents need no reset.
namespace met_finalize_layout {
static const int MEAN_Q16 = 0;
static const int RMS_Q16 = MEAN_Q16 + MET_ACTIVE_CHANNELS * 2;
static const int RMS_COUNT = RMS_Q16 + MET_ACTIVE_CHANNELS * 2;
static const int VLL_RMS = RMS_COUNT + MET_ACTIVE_CHANNELS;
static const int PHASE_P_PW = VLL_RMS + MET_VLL_PAIRS * 2;
static const int PHASE_S_PVA = PHASE_P_PW + MET_POWER_PHASES * 2;
static const int PHASE_PF_E6 = PHASE_S_PVA + MET_POWER_PHASES * 2;
static const int TOTAL_P_PW = PHASE_PF_E6 + MET_POWER_PHASES;
static const int TOTAL_S_PVA = TOTAL_P_PW + 2;
static const int TOTAL_PF_E6 = TOTAL_S_PVA + 2;
static const int CREST_E4 = TOTAL_PF_E6 + 1;
static const int PH_RE = CREST_E4 + MET_ACTIVE_CHANNELS;
static const int PH_IM = PH_RE + MET_ACTIVE_CHANNELS * 2;
static const int FUND_RMS_Q16 = PH_IM + MET_ACTIVE_CHANNELS * 2;
static const int ANGLE_TURNS = FUND_RMS_Q16 + MET_ACTIVE_CHANNELS * 2;
static const int VLL_FUND_RMS_Q16 = ANGLE_TURNS + MET_ACTIVE_CHANNELS;
static const int VLL_ANGLE_TURNS = VLL_FUND_RMS_Q16 + MET_VLL_PAIRS * 2;
static const int PHASE_P1_PW = VLL_ANGLE_TURNS + MET_VLL_PAIRS;
static const int PHASE_Q1_PVAR = PHASE_P1_PW + MET_POWER_PHASES * 2;
static const int PHASE_S1_PVA = PHASE_Q1_PVAR + MET_POWER_PHASES * 2;
static const int PHASE_DPF_E6 = PHASE_S1_PVA + MET_POWER_PHASES * 2;
static const int DISP_TURNS = PHASE_DPF_E6 + MET_POWER_PHASES;
static const int PHASE_NATURE = DISP_TURNS + MET_POWER_PHASES;
static const int TOTAL_P1_PW = PHASE_NATURE + MET_POWER_PHASES;
static const int TOTAL_Q1_PVAR = TOTAL_P1_PW + 2;
static const int TOTAL_S1_PVA = TOTAL_Q1_PVAR + 2;
static const int TOTAL_DPF_E6 = TOTAL_S1_PVA + 2;
static const int TOTAL_NATURE = TOTAL_DPF_E6 + 1;
static const int ANGLE_REF_VALID = TOTAL_NATURE + 1;
static const int SEQ_RMS_Q16 = ANGLE_REF_VALID + 1;
static const int SEQ_ANGLE_TURNS = SEQ_RMS_Q16 + 2 * 3 * 2;
static const int SEQ_ZERO_RATIO_E6 = SEQ_ANGLE_TURNS + 2 * 3;
static const int SEQ_UNBAL_RATIO_E6 = SEQ_ZERO_RATIO_E6 + 2;
static const int SEQ_SET_VALID = SEQ_UNBAL_RATIO_E6 + 2;
static const int WORDS = SEQ_SET_VALID + 2;
}  // namespace met_finalize_layout

// Keep the scratch object itself as an array.  Wrapping it in a struct lets
// HLS scalar-replacement split constant-looking fields back into individual
// registers before BIND_STORAGE is applied.  A direct indexed array retains
// one memory object and therefore one address/data interface.
typedef ap_uint<32>
    met_finalize_scratch_t[met_finalize_layout::WORDS];

inline void met_fin_store_u64(met_finalize_scratch_t &scratch, const int base,
                              const ap_uint<64> value) {
#pragma HLS INLINE
  scratch[base] = value.range(31, 0);
  scratch[base + 1] = value.range(63, 32);
}

inline ap_uint<64> met_fin_load_u64(const met_finalize_scratch_t &scratch,
                                    const int base) {
#pragma HLS INLINE
  ap_uint<64> value = 0;
  value.range(31, 0) = scratch[base];
  value.range(63, 32) = scratch[base + 1];
  return value;
}

inline void met_fin_store_i64(met_finalize_scratch_t &scratch, const int base,
                              const ap_int<64> value) {
#pragma HLS INLINE
  met_fin_store_u64(scratch, base, ap_uint<64>(value));
}

inline ap_int<64> met_fin_load_i64(const met_finalize_scratch_t &scratch,
                                   const int base) {
#pragma HLS INLINE
  return ap_int<64>(met_fin_load_u64(scratch, base));
}

inline void met_fin_store_u32(met_finalize_scratch_t &scratch, const int base,
                              const ap_uint<32> value) {
#pragma HLS INLINE
  scratch[base] = value;
}

inline ap_uint<32> met_fin_load_u32(const met_finalize_scratch_t &scratch,
                                    const int base) {
#pragma HLS INLINE
  return scratch[base];
}

inline void met_fin_store_i32(met_finalize_scratch_t &scratch, const int base,
                              const ap_int<32> value) {
#pragma HLS INLINE
  scratch[base] = ap_uint<32>(value);
}

inline ap_int<32> met_fin_load_i32(const met_finalize_scratch_t &scratch,
                                   const int base) {
#pragma HLS INLINE
  return ap_int<32>(scratch[base]);
}

// Typed scratch accessors keep record assembly independent from the private
// RAM layout.  The index arithmetic is intentionally simple and uniform so
// HLS implements one indexed read port rather than reconstructing the former
// wide aggregate interface.
inline ap_int<64> met_fin_mean_q16(const met_finalize_scratch_t &scratch,
                                  const int lane) {
#pragma HLS INLINE
  return met_fin_load_i64(scratch,
                          met_finalize_layout::MEAN_Q16 + lane * 2);
}

inline ap_uint<64> met_fin_rms_q16(const met_finalize_scratch_t &scratch,
                                   const int lane) {
#pragma HLS INLINE
  return met_fin_load_u64(scratch,
                          met_finalize_layout::RMS_Q16 + lane * 2);
}

inline ap_uint<32> met_fin_rms_count(const met_finalize_scratch_t &scratch,
                                     const int lane) {
#pragma HLS INLINE
  return met_fin_load_u32(scratch, met_finalize_layout::RMS_COUNT + lane);
}

inline ap_uint<64> met_fin_vll_rms(const met_finalize_scratch_t &scratch,
                                   const int pair) {
#pragma HLS INLINE
  return met_fin_load_u64(scratch,
                          met_finalize_layout::VLL_RMS + pair * 2);
}

inline ap_int<64> met_fin_phase_p_pw(const met_finalize_scratch_t &scratch,
                                     const int phase) {
#pragma HLS INLINE
  return met_fin_load_i64(scratch,
                          met_finalize_layout::PHASE_P_PW + phase * 2);
}

inline ap_uint<64> met_fin_phase_s_pva(const met_finalize_scratch_t &scratch,
                                       const int phase) {
#pragma HLS INLINE
  return met_fin_load_u64(scratch,
                          met_finalize_layout::PHASE_S_PVA + phase * 2);
}

inline ap_int<32> met_fin_phase_pf_e6(const met_finalize_scratch_t &scratch,
                                      const int phase) {
#pragma HLS INLINE
  return met_fin_load_i32(scratch,
                          met_finalize_layout::PHASE_PF_E6 + phase);
}

inline ap_int<64> met_fin_total_p_pw(const met_finalize_scratch_t &scratch) {
#pragma HLS INLINE
  return met_fin_load_i64(scratch, met_finalize_layout::TOTAL_P_PW);
}

inline ap_uint<64> met_fin_total_s_pva(
    const met_finalize_scratch_t &scratch) {
#pragma HLS INLINE
  return met_fin_load_u64(scratch, met_finalize_layout::TOTAL_S_PVA);
}

inline ap_int<32> met_fin_total_pf_e6(const met_finalize_scratch_t &scratch) {
#pragma HLS INLINE
  return met_fin_load_i32(scratch, met_finalize_layout::TOTAL_PF_E6);
}

inline ap_uint<32> met_fin_crest_e4(const met_finalize_scratch_t &scratch,
                                    const int lane) {
#pragma HLS INLINE
  return met_fin_load_u32(scratch, met_finalize_layout::CREST_E4 + lane);
}

inline ap_uint<64> met_fin_fund_rms_q16(
    const met_finalize_scratch_t &scratch, const int lane) {
#pragma HLS INLINE
  return met_fin_load_u64(scratch,
                          met_finalize_layout::FUND_RMS_Q16 + lane * 2);
}

inline ap_int<32> met_fin_angle_turns(const met_finalize_scratch_t &scratch,
                                      const int lane) {
#pragma HLS INLINE
  return met_fin_load_i32(scratch,
                          met_finalize_layout::ANGLE_TURNS + lane);
}

inline ap_uint<64> met_fin_vll_fund_rms_q16(
    const met_finalize_scratch_t &scratch, const int pair) {
#pragma HLS INLINE
  return met_fin_load_u64(
      scratch, met_finalize_layout::VLL_FUND_RMS_Q16 + pair * 2);
}

inline ap_int<32> met_fin_vll_angle_turns(
    const met_finalize_scratch_t &scratch, const int pair) {
#pragma HLS INLINE
  return met_fin_load_i32(scratch,
                          met_finalize_layout::VLL_ANGLE_TURNS + pair);
}

inline ap_int<64> met_fin_phase_p1_pw(const met_finalize_scratch_t &scratch,
                                      const int phase) {
#pragma HLS INLINE
  return met_fin_load_i64(scratch,
                          met_finalize_layout::PHASE_P1_PW + phase * 2);
}

inline ap_int<64> met_fin_phase_q1_pvar(
    const met_finalize_scratch_t &scratch, const int phase) {
#pragma HLS INLINE
  return met_fin_load_i64(
      scratch, met_finalize_layout::PHASE_Q1_PVAR + phase * 2);
}

inline ap_int<32> met_fin_phase_dpf_e6(
    const met_finalize_scratch_t &scratch, const int phase) {
#pragma HLS INLINE
  return met_fin_load_i32(scratch,
                          met_finalize_layout::PHASE_DPF_E6 + phase);
}

inline ap_int<32> met_fin_disp_turns(const met_finalize_scratch_t &scratch,
                                     const int phase) {
#pragma HLS INLINE
  return met_fin_load_i32(scratch,
                          met_finalize_layout::DISP_TURNS + phase);
}

inline ap_uint<2> met_fin_phase_nature(
    const met_finalize_scratch_t &scratch, const int phase) {
#pragma HLS INLINE
  return ap_uint<2>(met_fin_load_u32(
      scratch, met_finalize_layout::PHASE_NATURE + phase));
}

inline ap_int<64> met_fin_total_p1_pw(const met_finalize_scratch_t &scratch) {
#pragma HLS INLINE
  return met_fin_load_i64(scratch, met_finalize_layout::TOTAL_P1_PW);
}

inline ap_int<64> met_fin_total_q1_pvar(
    const met_finalize_scratch_t &scratch) {
#pragma HLS INLINE
  return met_fin_load_i64(scratch, met_finalize_layout::TOTAL_Q1_PVAR);
}

inline ap_int<32> met_fin_total_dpf_e6(
    const met_finalize_scratch_t &scratch) {
#pragma HLS INLINE
  return met_fin_load_i32(scratch, met_finalize_layout::TOTAL_DPF_E6);
}

inline ap_uint<2> met_fin_total_nature(
    const met_finalize_scratch_t &scratch) {
#pragma HLS INLINE
  return ap_uint<2>(
      met_fin_load_u32(scratch, met_finalize_layout::TOTAL_NATURE));
}

inline ap_uint<1> met_fin_angle_ref_valid(
    const met_finalize_scratch_t &scratch) {
#pragma HLS INLINE
  return ap_uint<1>(
      met_fin_load_u32(scratch, met_finalize_layout::ANGLE_REF_VALID));
}

inline ap_uint<64> met_fin_seq_rms_q16(
    const met_finalize_scratch_t &scratch, const int set,
    const int component) {
#pragma HLS INLINE
  const int term = set * 3 + component;
  return met_fin_load_u64(
      scratch, met_finalize_layout::SEQ_RMS_Q16 + term * 2);
}

inline ap_int<32> met_fin_seq_angle_turns(
    const met_finalize_scratch_t &scratch, const int set,
    const int component) {
#pragma HLS INLINE
  const int term = set * 3 + component;
  return met_fin_load_i32(
      scratch, met_finalize_layout::SEQ_ANGLE_TURNS + term);
}

inline ap_uint<32> met_fin_seq_zero_ratio_e6(
    const met_finalize_scratch_t &scratch, const int set) {
#pragma HLS INLINE
  return met_fin_load_u32(
      scratch, met_finalize_layout::SEQ_ZERO_RATIO_E6 + set);
}

inline ap_uint<32> met_fin_seq_unbal_ratio_e6(
    const met_finalize_scratch_t &scratch, const int set) {
#pragma HLS INLINE
  return met_fin_load_u32(
      scratch, met_finalize_layout::SEQ_UNBAL_RATIO_E6 + set);
}

inline ap_uint<1> met_fin_seq_set_valid(
    const met_finalize_scratch_t &scratch, const int set) {
#pragma HLS INLINE
  return ap_uint<1>(met_fin_load_u32(
      scratch, met_finalize_layout::SEQ_SET_VALID + set));
}

// One lane's Basic finalization — the retired engine's CALC_* sequence.
inline void met_finalize_lane(const ap_int<128> sum, const ap_uint<128> square,
                              const ap_int<64> raw_sum,
                              const ap_uint<96> raw_square,
                              const ap_uint<32> count,
                              const ap_uint<1> dc_remove, ap_int<64> &mean_q16,
                              ap_uint<64> &rms_q16, ap_uint<32> &rms_count,
                              ap_uint<1> &overflow) {
#pragma HLS INLINE off
  mean_q16 = met_floor_mean_signed<128, 64>(sum, count);
  rms_q16 = met_rms_from_accumulators<128, 128>(square, sum, count, dc_remove,
                                                overflow);
  const ap_uint<64> raw_root = met_rms_from_accumulators<96, 64>(
      raw_square, raw_sum, count, dc_remove, overflow);
  rms_count = raw_root.range(31, 0);
}

// Load nature from Q1's sign under the S1 = 0 gate (metering_types.hpp).
inline ap_uint<2> met_classify_nature(const ap_int<64> q1_pvar,
                                      const ap_uint<64> s1_pva) {
#pragma HLS INLINE
  if (s1_pva == 0) {
    return ap_uint<2>(MET_NATURE_UNDEFINED);
  }
  if (q1_pvar == 0) {
    return ap_uint<2>(MET_NATURE_UNITY);
  }
  return q1_pvar > 0 ? ap_uint<2>(MET_NATURE_LAGGING)
                     : ap_uint<2>(MET_NATURE_LEADING);
}

inline void met_finalize_interval(
    const ap_int<128> acc_sum[MET_ACTIVE_CHANNELS],
    const ap_uint<128> acc_square[MET_ACTIVE_CHANNELS],
    const ap_int<64> acc_raw_sum[MET_ACTIVE_CHANNELS],
    const ap_uint<96> acc_raw_square[MET_ACTIVE_CHANNELS],
    const ap_int<64> acc_minimum[MET_ACTIVE_CHANNELS],
    const ap_int<64> acc_maximum[MET_ACTIVE_CHANNELS],
    const ap_uint<128> acc_vll_square[MET_VLL_PAIRS],
    const ap_int<128> acc_power[MET_POWER_PHASES],
    const ap_int<128> acc_phasor_re[MET_ACTIVE_CHANNELS],
    const ap_int<128> acc_phasor_im[MET_ACTIVE_CHANNELS],
    const ap_uint<32> count, const ap_uint<1> dc_remove,
    const ap_uint<8> result_mask, met_finalize_scratch_t &out,
    ap_uint<1> &overflow) {
#pragma HLS INLINE
  static const int power_v[MET_POWER_PHASES] = {MET_LANE_VA, MET_LANE_VB,
                                                MET_LANE_VC};
  static const int power_i[MET_POWER_PHASES] = {MET_LANE_IA, MET_LANE_IB,
                                                MET_LANE_IC};

met_fin_lanes:
  for (int lane = 0; lane < MET_ACTIVE_CHANNELS; ++lane) {
#pragma HLS PIPELINE off
    ap_uint<1> lane_overflow = 0;
    ap_int<64> mean_q16 = 0;
    ap_uint<64> rms_q16 = 0;
    ap_uint<32> rms_count = 0;
    met_finalize_lane(acc_sum[lane], acc_square[lane], acc_raw_sum[lane],
                      acc_raw_square[lane], count, dc_remove, mean_q16,
                      rms_q16, rms_count, lane_overflow);
    met_fin_store_i64(out, met_finalize_layout::MEAN_Q16 + lane * 2,
                      mean_q16);
    met_fin_store_u64(out, met_finalize_layout::RMS_Q16 + lane * 2, rms_q16);
    met_fin_store_u32(out, met_finalize_layout::RMS_COUNT + lane, rms_count);
    overflow |= lane_overflow;
  }
met_fin_pairs:
  for (int pair = 0; pair < MET_VLL_PAIRS; ++pair) {
#pragma HLS PIPELINE off
    const ap_uint<64> vll_rms = met_rms_from_accumulators<128, 128>(
        acc_vll_square[pair], ap_int<128>(0), count, ap_uint<1>(0), overflow);
    met_fin_store_u64(out, met_finalize_layout::VLL_RMS + pair * 2, vll_rms);
  }

  // ---- Power (M8): P, S = Vrms*Irms, true PF --------------------------
met_fin_power:
  for (int phase = 0; phase < MET_POWER_PHASES; ++phase) {
#pragma HLS PIPELINE off
    const ap_int<128> mean_q32 =
        met_floor_mean_signed<128, 128>(acc_power[phase], count);
    const ap_int<64> phase_p_pw =
        ap_int<64>((mean_q32 >> 32).range(63, 0));
    const ap_uint<64> voltage_rms = met_fin_load_u64(
        out, met_finalize_layout::RMS_Q16 + power_v[phase] * 2);
    const ap_uint<64> current_rms = met_fin_load_u64(
        out, met_finalize_layout::RMS_Q16 + power_i[phase] * 2);
    const ap_uint<128> s_product =
        ap_uint<128>(voltage_rms) * current_rms;
    const ap_uint<64> phase_s_pva =
        ap_uint<64>((s_product >> 32).range(63, 0));
    const ap_int<32> phase_pf_e6 =
        met_power_factor_e6(phase_p_pw, phase_s_pva);
    met_fin_store_i64(out, met_finalize_layout::PHASE_P_PW + phase * 2,
                      phase_p_pw);
    met_fin_store_u64(out, met_finalize_layout::PHASE_S_PVA + phase * 2,
                      phase_s_pva);
    met_fin_store_i32(out, met_finalize_layout::PHASE_PF_E6 + phase,
                      phase_pf_e6);
  }
  ap_int<64> total_p_pw = 0;
  ap_uint<64> total_s_pva = 0;
met_fin_power_total:
  for (int phase = 0; phase < MET_POWER_PHASES; ++phase) {
#pragma HLS PIPELINE off
    total_p_pw += met_fin_load_i64(
        out, met_finalize_layout::PHASE_P_PW + phase * 2);
    total_s_pva += met_fin_load_u64(
        out, met_finalize_layout::PHASE_S_PVA + phase * 2);
  }
  met_fin_store_i64(out, met_finalize_layout::TOTAL_P_PW, total_p_pw);
  met_fin_store_u64(out, met_finalize_layout::TOTAL_S_PVA, total_s_pva);
  met_fin_store_i32(out, met_finalize_layout::TOTAL_PF_E6,
                    met_power_factor_e6(total_p_pw, total_s_pva));

  // Crest factors: peak / finalized RMS per lane, ten-thousandths.
met_fin_crest:
  for (int lane = 0; lane < MET_ACTIVE_CHANNELS; ++lane) {
#pragma HLS PIPELINE off
    const ap_uint<64> magnitude_min = met_abs<64>(acc_minimum[lane]);
    const ap_uint<64> magnitude_max = met_abs<64>(acc_maximum[lane]);
    const ap_uint<64> peak =
        magnitude_min > magnitude_max ? magnitude_min : magnitude_max;
    const ap_uint<64> lane_rms = met_fin_load_u64(
        out, met_finalize_layout::RMS_Q16 + lane * 2);
    ap_uint<32> crest_e4 = 0;
    if (lane_rms == 0) {
      crest_e4 = 0;
    } else {
      const ap_uint<128> scaled = ap_uint<128>(peak) * ap_uint<128>(10000);
      const ap_uint<128> ratio =
          floor_div<128>(scaled, ap_uint<128>(lane_rms));
      crest_e4 = ratio > ap_uint<128>(0xFFFFFFFFu)
                     ? ap_uint<32>(0xFFFFFFFFu)
                     : ap_uint<32>(ratio.range(31, 0));
    }
    met_fin_store_u32(out, met_finalize_layout::CREST_E4 + lane, crest_e4);
  }

  // ---- Phasor finalization (M9). Q1 needs no trig: V1*I1*sin(phi1) =
  // ---- 2*(im_V*re_I - re_V*im_I) exactly in the Q16 mean-phasor domain.
met_fin_phasor_lanes:
  for (int lane = 0; lane < MET_ACTIVE_CHANNELS; ++lane) {
#pragma HLS PIPELINE off
    const ap_int<64> ph_re = met_phasor_counts(acc_phasor_re[lane], count);
    const ap_int<64> ph_im = met_phasor_counts(acc_phasor_im[lane], count);
    met_fin_store_i64(out, met_finalize_layout::PH_RE + lane * 2, ph_re);
    met_fin_store_i64(out, met_finalize_layout::PH_IM + lane * 2, ph_im);
    met_fin_store_u64(out, met_finalize_layout::FUND_RMS_Q16 + lane * 2,
                      met_phasor_rms_q16(ph_re, ph_im));
    met_fin_store_i32(out, met_finalize_layout::ANGLE_TURNS + lane,
                      met_atan2_turns(ph_im, ph_re));
  }
  static const int vll_pos[MET_VLL_PAIRS] = {MET_LANE_VA, MET_LANE_VB,
                                             MET_LANE_VC};
  static const int vll_neg[MET_VLL_PAIRS] = {MET_LANE_VB, MET_LANE_VC,
                                             MET_LANE_VA};
met_fin_phasor_pairs:
  for (int pair = 0; pair < MET_VLL_PAIRS; ++pair) {
#pragma HLS PIPELINE off
    const ap_int<64> re =
        met_fin_load_i64(out, met_finalize_layout::PH_RE + vll_pos[pair] * 2) -
        met_fin_load_i64(out, met_finalize_layout::PH_RE + vll_neg[pair] * 2);
    const ap_int<64> im =
        met_fin_load_i64(out, met_finalize_layout::PH_IM + vll_pos[pair] * 2) -
        met_fin_load_i64(out, met_finalize_layout::PH_IM + vll_neg[pair] * 2);
    met_fin_store_u64(out,
                      met_finalize_layout::VLL_FUND_RMS_Q16 + pair * 2,
                      met_phasor_rms_q16(re, im));
    met_fin_store_i32(out, met_finalize_layout::VLL_ANGLE_TURNS + pair,
                      met_atan2_turns(im, re));
  }
met_fin_phasor_power:
  for (int phase = 0; phase < MET_POWER_PHASES; ++phase) {
#pragma HLS PIPELINE off
    const int v = power_v[phase];
    const int i = power_i[phase];
    const ap_int<64> v_re =
        met_fin_load_i64(out, met_finalize_layout::PH_RE + v * 2);
    const ap_int<64> v_im =
        met_fin_load_i64(out, met_finalize_layout::PH_IM + v * 2);
    const ap_int<64> i_re =
        met_fin_load_i64(out, met_finalize_layout::PH_RE + i * 2);
    const ap_int<64> i_im =
        met_fin_load_i64(out, met_finalize_layout::PH_IM + i * 2);
    const ap_int<128> dot =
        ap_int<128>(v_re * i_re) + ap_int<128>(v_im * i_im);
    const ap_int<128> cross =
        ap_int<128>(v_im * i_re) - ap_int<128>(v_re * i_im);
    const ap_int<64> phase_p1_pw = ap_int<64>((dot >> 31).range(63, 0));
    const ap_int<64> phase_q1_pvar =
        ap_int<64>((cross >> 31).range(63, 0));
    const ap_uint<64> v_fund = met_fin_load_u64(
        out, met_finalize_layout::FUND_RMS_Q16 + v * 2);
    const ap_uint<64> i_fund = met_fin_load_u64(
        out, met_finalize_layout::FUND_RMS_Q16 + i * 2);
    const ap_uint<128> s1_product =
        ap_uint<128>(v_fund) * i_fund;
    const ap_uint<64> phase_s1_pva =
        ap_uint<64>((s1_product >> 32).range(63, 0));
    met_fin_store_i64(out, met_finalize_layout::PHASE_P1_PW + phase * 2,
                      phase_p1_pw);
    met_fin_store_i64(out,
                      met_finalize_layout::PHASE_Q1_PVAR + phase * 2,
                      phase_q1_pvar);
    met_fin_store_u64(out,
                      met_finalize_layout::PHASE_S1_PVA + phase * 2,
                      phase_s1_pva);
    met_fin_store_i32(out, met_finalize_layout::PHASE_DPF_E6 + phase,
                      met_power_factor_e6(phase_p1_pw, phase_s1_pva));
    const ap_int<32> disp_turns =
        met_fin_load_i32(out, met_finalize_layout::ANGLE_TURNS + v) -
        met_fin_load_i32(out, met_finalize_layout::ANGLE_TURNS + i);
    met_fin_store_i32(out, met_finalize_layout::DISP_TURNS + phase,
                      disp_turns);
    met_fin_store_u32(out, met_finalize_layout::PHASE_NATURE + phase,
                      met_classify_nature(phase_q1_pvar, phase_s1_pva));
  }
  ap_int<64> total_p1_pw = 0;
  ap_int<64> total_q1_pvar = 0;
  ap_uint<64> total_s1_pva = 0;
met_fin_phasor_total:
  for (int phase = 0; phase < MET_POWER_PHASES; ++phase) {
#pragma HLS PIPELINE off
    total_p1_pw += met_fin_load_i64(
        out, met_finalize_layout::PHASE_P1_PW + phase * 2);
    total_q1_pvar += met_fin_load_i64(
        out, met_finalize_layout::PHASE_Q1_PVAR + phase * 2);
    total_s1_pva += met_fin_load_u64(
        out, met_finalize_layout::PHASE_S1_PVA + phase * 2);
  }
  met_fin_store_i64(out, met_finalize_layout::TOTAL_P1_PW, total_p1_pw);
  met_fin_store_i64(out, met_finalize_layout::TOTAL_Q1_PVAR, total_q1_pvar);
  met_fin_store_u64(out, met_finalize_layout::TOTAL_S1_PVA, total_s1_pva);
  met_fin_store_i32(out, met_finalize_layout::TOTAL_DPF_E6,
                    met_power_factor_e6(total_p1_pw, total_s1_pva));
  met_fin_store_u32(out, met_finalize_layout::TOTAL_NATURE,
                    met_classify_nature(total_q1_pvar, total_s1_pva));
  const ap_uint<1> angle_ref_valid =
      (result_mask.bit(MET_LANE_VA) == 1 &&
       met_fin_load_u64(out, met_finalize_layout::FUND_RMS_Q16 +
                                MET_LANE_VA * 2) != 0)
          ? 1
          : 0;
  met_fin_store_u32(out, met_finalize_layout::ANGLE_REF_VALID,
                    angle_ref_valid);

  // ---- Symmetrical components + unbalance ratios (M10) ----------------
met_fin_sequence_sets:
  for (int set = 0; set < 2; ++set) {
#pragma HLS PIPELINE off
    const int lane_a = (set == 0) ? MET_LANE_VA : MET_LANE_IA;
    const int lane_b = (set == 0) ? MET_LANE_VB : MET_LANE_IB;
    const int lane_c = (set == 0) ? MET_LANE_VC : MET_LANE_IC;
    ap_int<64> set_re[3];
    ap_int<64> set_im[3];
    ap_int<64> seq_re[3];
    ap_int<64> seq_im[3];
    set_re[0] = met_fin_load_i64(out, met_finalize_layout::PH_RE + lane_a * 2);
    set_im[0] = met_fin_load_i64(out, met_finalize_layout::PH_IM + lane_a * 2);
    set_re[1] = met_fin_load_i64(out, met_finalize_layout::PH_RE + lane_b * 2);
    set_im[1] = met_fin_load_i64(out, met_finalize_layout::PH_IM + lane_b * 2);
    set_re[2] = met_fin_load_i64(out, met_finalize_layout::PH_RE + lane_c * 2);
    set_im[2] = met_fin_load_i64(out, met_finalize_layout::PH_IM + lane_c * 2);
    met_sequence_components(set_re, set_im, seq_re, seq_im);
  met_fin_sequence_terms:
    for (int component = 0; component < 3; ++component) {
#pragma HLS PIPELINE off
      const int term = set * 3 + component;
      met_fin_store_u64(out, met_finalize_layout::SEQ_RMS_Q16 + term * 2,
                        met_phasor_rms_q16(seq_re[component],
                                           seq_im[component]));
      met_fin_store_i32(out, met_finalize_layout::SEQ_ANGLE_TURNS + term,
                        met_atan2_turns(seq_im[component],
                                       seq_re[component]));
    }
    const ap_uint<64> zero = met_fin_load_u64(
        out, met_finalize_layout::SEQ_RMS_Q16 + (set * 3 + 0) * 2);
    const ap_uint<64> positive = met_fin_load_u64(
        out, met_finalize_layout::SEQ_RMS_Q16 + (set * 3 + 1) * 2);
    const ap_uint<64> negative = met_fin_load_u64(
        out, met_finalize_layout::SEQ_RMS_Q16 + (set * 3 + 2) * 2);
    met_fin_store_u32(out, met_finalize_layout::SEQ_ZERO_RATIO_E6 + set,
                      met_ratio_e6(zero, positive));
    met_fin_store_u32(out, met_finalize_layout::SEQ_UNBAL_RATIO_E6 + set,
                      met_ratio_e6(negative, positive));
    met_fin_store_u32(out, met_finalize_layout::SEQ_SET_VALID + set,
                      positive != 0 ? ap_uint<32>(1) : ap_uint<32>(0));
  }
}

#endif  // MSAP1_METROLOGY_FINALIZE_HPP
