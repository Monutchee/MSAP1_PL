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

struct met_finalize_out_t {
  ap_int<64>  mean_q16[MET_ACTIVE_CHANNELS];
  ap_uint<64> rms_q16[MET_ACTIVE_CHANNELS];
  ap_uint<32> rms_count[MET_ACTIVE_CHANNELS];
  ap_uint<64> vll_rms[MET_VLL_PAIRS];
  ap_int<64>  phase_p_pw[MET_POWER_PHASES];
  ap_uint<64> phase_s_pva[MET_POWER_PHASES];
  ap_int<32>  phase_pf_e6[MET_POWER_PHASES];
  ap_int<64>  total_p_pw;
  ap_uint<64> total_s_pva;
  ap_int<32>  total_pf_e6;
  ap_uint<32> crest_e4[MET_ACTIVE_CHANNELS];
  ap_int<64>  ph_re[MET_ACTIVE_CHANNELS];
  ap_int<64>  ph_im[MET_ACTIVE_CHANNELS];
  ap_uint<64> fund_rms_q16[MET_ACTIVE_CHANNELS];
  ap_int<32>  angle_turns[MET_ACTIVE_CHANNELS];
  ap_uint<64> vll_fund_rms_q16[MET_VLL_PAIRS];
  ap_int<32>  vll_angle_turns[MET_VLL_PAIRS];
  ap_int<64>  phase_p1_pw[MET_POWER_PHASES];
  ap_int<64>  phase_q1_pvar[MET_POWER_PHASES];
  ap_uint<64> phase_s1_pva[MET_POWER_PHASES];
  ap_int<32>  phase_dpf_e6[MET_POWER_PHASES];
  ap_int<32>  disp_turns[MET_POWER_PHASES];
  ap_uint<2>  phase_nature[MET_POWER_PHASES];
  ap_int<64>  total_p1_pw;
  ap_int<64>  total_q1_pvar;
  ap_uint<64> total_s1_pva;
  ap_int<32>  total_dpf_e6;
  ap_uint<2>  total_nature;
  ap_uint<1>  angle_ref_valid;
  // Symmetrical components: set 0 = voltage (VA/VB/VC), set 1 = current
  // (IA/IB/IC); component order zero/positive/negative.
  ap_uint<64> seq_rms_q16[2][3];
  ap_int<32>  seq_angle_turns[2][3];
  ap_uint<32> seq_zero_ratio_e6[2];
  ap_uint<32> seq_unbal_ratio_e6[2];
  ap_uint<1>  seq_set_valid[2];
};

// One lane's basic finalization — the retired Mtr1 CALC_* sequence.
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
    const ap_uint<8> result_mask, met_finalize_out_t &out,
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
    met_finalize_lane(acc_sum[lane], acc_square[lane], acc_raw_sum[lane],
                      acc_raw_square[lane], count, dc_remove,
                      out.mean_q16[lane], out.rms_q16[lane],
                      out.rms_count[lane], lane_overflow);
    overflow |= lane_overflow;
  }
met_fin_pairs:
  for (int pair = 0; pair < MET_VLL_PAIRS; ++pair) {
#pragma HLS PIPELINE off
    out.vll_rms[pair] = met_rms_from_accumulators<128, 128>(
        acc_vll_square[pair], ap_int<128>(0), count, ap_uint<1>(0), overflow);
  }

  // ---- Power (M8): P, S = Vrms*Irms, true PF --------------------------
met_fin_power:
  for (int phase = 0; phase < MET_POWER_PHASES; ++phase) {
#pragma HLS PIPELINE off
    const ap_int<128> mean_q32 =
        met_floor_mean_signed<128, 128>(acc_power[phase], count);
    out.phase_p_pw[phase] = ap_int<64>((mean_q32 >> 32).range(63, 0));
    const ap_uint<128> s_product =
        ap_uint<128>(out.rms_q16[power_v[phase]]) * out.rms_q16[power_i[phase]];
    out.phase_s_pva[phase] = ap_uint<64>((s_product >> 32).range(63, 0));
    out.phase_pf_e6[phase] =
        met_power_factor_e6(out.phase_p_pw[phase], out.phase_s_pva[phase]);
  }
  out.total_p_pw = 0;
  out.total_s_pva = 0;
met_fin_power_total:
  for (int phase = 0; phase < MET_POWER_PHASES; ++phase) {
#pragma HLS PIPELINE off
    out.total_p_pw += out.phase_p_pw[phase];
    out.total_s_pva += out.phase_s_pva[phase];
  }
  out.total_pf_e6 = met_power_factor_e6(out.total_p_pw, out.total_s_pva);

  // Crest factors: peak / finalized RMS per lane, ten-thousandths.
met_fin_crest:
  for (int lane = 0; lane < MET_ACTIVE_CHANNELS; ++lane) {
#pragma HLS PIPELINE off
    const ap_uint<64> magnitude_min = met_abs<64>(acc_minimum[lane]);
    const ap_uint<64> magnitude_max = met_abs<64>(acc_maximum[lane]);
    const ap_uint<64> peak =
        magnitude_min > magnitude_max ? magnitude_min : magnitude_max;
    if (out.rms_q16[lane] == 0) {
      out.crest_e4[lane] = 0;
    } else {
      const ap_uint<128> scaled = ap_uint<128>(peak) * ap_uint<128>(10000);
      const ap_uint<128> ratio =
          floor_div<128>(scaled, ap_uint<128>(out.rms_q16[lane]));
      out.crest_e4[lane] = ratio > ap_uint<128>(0xFFFFFFFFu)
                               ? ap_uint<32>(0xFFFFFFFFu)
                               : ap_uint<32>(ratio.range(31, 0));
    }
  }

  // ---- Phasor finalization (M9). Q1 needs no trig: V1*I1*sin(phi1) =
  // ---- 2*(im_V*re_I - re_V*im_I) exactly in the Q16 mean-phasor domain.
met_fin_phasor_lanes:
  for (int lane = 0; lane < MET_ACTIVE_CHANNELS; ++lane) {
#pragma HLS PIPELINE off
    out.ph_re[lane] = met_phasor_counts(acc_phasor_re[lane], count);
    out.ph_im[lane] = met_phasor_counts(acc_phasor_im[lane], count);
    out.fund_rms_q16[lane] =
        met_phasor_rms_q16(out.ph_re[lane], out.ph_im[lane]);
    out.angle_turns[lane] =
        met_atan2_turns(out.ph_im[lane], out.ph_re[lane]);
  }
  static const int vll_pos[MET_VLL_PAIRS] = {MET_LANE_VA, MET_LANE_VB,
                                             MET_LANE_VC};
  static const int vll_neg[MET_VLL_PAIRS] = {MET_LANE_VB, MET_LANE_VC,
                                             MET_LANE_VA};
met_fin_phasor_pairs:
  for (int pair = 0; pair < MET_VLL_PAIRS; ++pair) {
#pragma HLS PIPELINE off
    const ap_int<64> re = out.ph_re[vll_pos[pair]] - out.ph_re[vll_neg[pair]];
    const ap_int<64> im = out.ph_im[vll_pos[pair]] - out.ph_im[vll_neg[pair]];
    out.vll_fund_rms_q16[pair] = met_phasor_rms_q16(re, im);
    out.vll_angle_turns[pair] = met_atan2_turns(im, re);
  }
met_fin_phasor_power:
  for (int phase = 0; phase < MET_POWER_PHASES; ++phase) {
#pragma HLS PIPELINE off
    const int v = power_v[phase];
    const int i = power_i[phase];
    const ap_int<128> dot = ap_int<128>(out.ph_re[v] * out.ph_re[i]) +
                            ap_int<128>(out.ph_im[v] * out.ph_im[i]);
    const ap_int<128> cross = ap_int<128>(out.ph_im[v] * out.ph_re[i]) -
                              ap_int<128>(out.ph_re[v] * out.ph_im[i]);
    out.phase_p1_pw[phase] = ap_int<64>((dot >> 31).range(63, 0));
    out.phase_q1_pvar[phase] = ap_int<64>((cross >> 31).range(63, 0));
    const ap_uint<128> s1_product =
        ap_uint<128>(out.fund_rms_q16[v]) * out.fund_rms_q16[i];
    out.phase_s1_pva[phase] = ap_uint<64>((s1_product >> 32).range(63, 0));
    out.phase_dpf_e6[phase] =
        met_power_factor_e6(out.phase_p1_pw[phase], out.phase_s1_pva[phase]);
    out.disp_turns[phase] = out.angle_turns[v] - out.angle_turns[i];
    out.phase_nature[phase] =
        met_classify_nature(out.phase_q1_pvar[phase], out.phase_s1_pva[phase]);
  }
  out.total_p1_pw = 0;
  out.total_q1_pvar = 0;
  out.total_s1_pva = 0;
met_fin_phasor_total:
  for (int phase = 0; phase < MET_POWER_PHASES; ++phase) {
#pragma HLS PIPELINE off
    out.total_p1_pw += out.phase_p1_pw[phase];
    out.total_q1_pvar += out.phase_q1_pvar[phase];
    out.total_s1_pva += out.phase_s1_pva[phase];
  }
  out.total_dpf_e6 = met_power_factor_e6(out.total_p1_pw, out.total_s1_pva);
  out.total_nature = met_classify_nature(out.total_q1_pvar, out.total_s1_pva);
  out.angle_ref_valid =
      (result_mask.bit(MET_LANE_VA) == 1 &&
       out.fund_rms_q16[MET_LANE_VA] != 0)
          ? 1
          : 0;

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
    set_re[0] = out.ph_re[lane_a];
    set_im[0] = out.ph_im[lane_a];
    set_re[1] = out.ph_re[lane_b];
    set_im[1] = out.ph_im[lane_b];
    set_re[2] = out.ph_re[lane_c];
    set_im[2] = out.ph_im[lane_c];
    met_sequence_components(set_re, set_im, seq_re, seq_im);
  met_fin_sequence_terms:
    for (int component = 0; component < 3; ++component) {
#pragma HLS PIPELINE off
      out.seq_rms_q16[set][component] =
          met_phasor_rms_q16(seq_re[component], seq_im[component]);
      out.seq_angle_turns[set][component] =
          met_atan2_turns(seq_im[component], seq_re[component]);
    }
    out.seq_zero_ratio_e6[set] =
        met_ratio_e6(out.seq_rms_q16[set][0], out.seq_rms_q16[set][1]);
    out.seq_unbal_ratio_e6[set] =
        met_ratio_e6(out.seq_rms_q16[set][2], out.seq_rms_q16[set][1]);
    out.seq_set_valid[set] = (out.seq_rms_q16[set][1] != 0) ? 1 : 0;
  }
}

#endif  // MSAP1_METROLOGY_FINALIZE_HPP
