#include "agg150_180_cycle_engine.hpp"

#include "metrology_finalize.hpp"
#include "metrology_math.hpp"
#include "metrology_stats.hpp"
#include "metrology_trig.hpp"

// 150/180-cycle aggregation engine. Contract and rules: see
// agg150_180_cycle_engine.hpp. Structure mirrors the 10/12-cycle tier:
// one free-running single-shot process; the invocation folding the 15th
// block runs the shared finalize and all four emissions inline (input
// cadence ~200 ms dwarfs the finalize's microseconds).

void hls_agg150_180_cycle_engine(hls::stream<agg_block_beat_t> &s_block,
                                 hls::stream<record_axis_t> &m_axis) {
  // s_block unregistered (the producer's master and the shim register
  // their side); the exported record stream keeps the boundary register.
#pragma HLS INTERFACE mode=axis port=s_block register_mode=off
#pragma HLS INTERFACE mode=axis port=m_axis
#pragma HLS INTERFACE mode=ap_ctrl_none port=return

  // Open-aggregate bookkeeping; syn.rtl.reset=state re-zeroes on aresetn.
  static ap_uint<1> apply_seen = 0;
  static ap_uint<5> blocks_accumulated = 0;
  static ap_uint<32> agg_generation = 0;
  static ap_uint<8> agg_nominal = 0;
  static ap_uint<32> agg_sample_rate = 0;
  static ap_uint<1> agg_dc_remove = 1;
  static ap_uint<64> agg_first_sample = 0;
  static ap_uint<64> agg_last_sample = 0;
  static ap_uint<32> agg_first_seq = 0;
  static ap_uint<32> agg_total_samples = 0;
  static ap_uint<16> agg_total_cycles = 0;
  static ap_uint<8> mask_and = 0;
  static ap_uint<36> freq_sum = 0;
  static ap_uint<1> freq_all_valid = 0;
  static ap_uint<1> arithmetic_flag = 0;
  static ap_uint<1> phasor_invalid_or = 0;
  // Unsigned arithmetic wraps at 2**32 / 2**64, so sequence and sample
  // continuity survive wraparound without special cases (Mtr2 rule).
  static ap_uint<32> expected_next_seq = 0;
  static ap_uint<64> expected_next_first = 0;
  static ap_uint<32> out_sequence = 0;

  // Diagnostics (record-carried, words 33..35 — the AGG_* register tap).
  static ap_uint<32> reset_count = 0;
  static ap_uint<32> ineligible_count = 0;
  static ap_uint<32> continuity_count = 0;

  // Interval accumulators: the 15 blocks' accumulators summed. Same
  // widths as the block tier — the width analysis in
  // agg_block_result.hpp covers the 15x sums.
  static ap_int<128> acc_sum[MET_ACTIVE_CHANNELS];
#pragma HLS BIND_STORAGE variable=acc_sum type=ram_s2p impl=lutram
  static ap_uint<128> acc_square[MET_ACTIVE_CHANNELS];
#pragma HLS BIND_STORAGE variable=acc_square type=ram_s2p impl=lutram
  static ap_int<64> acc_raw_sum[MET_ACTIVE_CHANNELS];
#pragma HLS BIND_STORAGE variable=acc_raw_sum type=ram_s2p impl=lutram
  static ap_uint<96> acc_raw_square[MET_ACTIVE_CHANNELS];
#pragma HLS BIND_STORAGE variable=acc_raw_square type=ram_s2p impl=lutram
  static ap_uint<128> acc_vll_square[MET_VLL_PAIRS];
#pragma HLS BIND_STORAGE variable=acc_vll_square type=ram_s2p impl=lutram
  static ap_int<128> acc_power[MET_POWER_PHASES];
#pragma HLS BIND_STORAGE variable=acc_power type=ram_s2p impl=lutram
  static ap_int<64> acc_minimum[MET_ACTIVE_CHANNELS];
#pragma HLS BIND_STORAGE variable=acc_minimum type=ram_s2p impl=lutram
  static ap_int<64> acc_maximum[MET_ACTIVE_CHANNELS];
#pragma HLS BIND_STORAGE variable=acc_maximum type=ram_s2p impl=lutram
  static ap_int<128> acc_phasor_re[MET_ACTIVE_CHANNELS];
#pragma HLS BIND_STORAGE variable=acc_phasor_re type=ram_s2p impl=lutram
  static ap_int<128> acc_phasor_im[MET_ACTIVE_CHANNELS];
#pragma HLS BIND_STORAGE variable=acc_phasor_im type=ram_s2p impl=lutram

  if (s_block.empty()) {
    return;
  }
  const agg_block_result_t in = unpack_agg_block_result(s_block.read());

  // A configuration APPLY between beats terminates any partially
  // accumulated aggregate before this beat is considered (Mtr2 rule).
  if (in.apply_toggle != apply_seen) {
    apply_seen = in.apply_toggle;
    if (blocks_accumulated != 0) {
      reset_count += 1;
    }
    blocks_accumulated = 0;
  }

  // Eligibility: identical predicate to the retired Mtr2 engine and the
  // APU's class_a_aggregation_eligible() rule.
  const bool nominal_known = (in.nominal_hz == 50) || (in.nominal_hz == 60);
  const bool input_eligible =
      in.flags.bit(MET_FLAG_LOCKED) == 1 &&
      in.flags.bit(MET_FLAG_FALLBACK) == 0 &&
      in.flags.bit(MET_FLAG_FIRST_BLOCK) == 0 && nominal_known &&
      in.cycle_count == met_expected_cycles(in.nominal_hz);

  if (!input_eligible) {
    // An ineligible block invalidates the running aggregate and never
    // seeds a new one: the 150/180-cycle interval must stay contiguous.
    ineligible_count += 1;
    if (blocks_accumulated != 0) {
      reset_count += 1;
    }
    blocks_accumulated = 0;
    return;
  }

  bool seed = (blocks_accumulated == 0);
  if (!seed) {
    if (in.generation != agg_generation || in.nominal_hz != agg_nominal ||
        in.sample_rate_hz != agg_sample_rate ||
        in.dc_remove != agg_dc_remove) {
      // Generation, nominal, sample-rate, or dc_remove change: discard
      // the partial aggregate; this block seeds the next one.
      reset_count += 1;
      seed = true;
    } else if (in.sequence != expected_next_seq ||
               in.first_sample != expected_next_first) {
      // Lost/reordered block or a sample-domain discontinuity: the 15
      // inputs would not describe one contiguous interval.
      continuity_count += 1;
      reset_count += 1;
      seed = true;
    }
  }

  if (seed) {
    agg_generation = in.generation;
    agg_nominal = in.nominal_hz;
    agg_sample_rate = in.sample_rate_hz;
    agg_dc_remove = in.dc_remove;
    agg_first_sample = in.first_sample;
    agg_first_seq = in.sequence;
    agg_total_samples = in.sample_count;
    agg_total_cycles = in.cycle_count;
    mask_and = in.valid_mask;
    freq_sum = in.frequency_millihz;
    freq_all_valid = in.frequency_valid;
    arithmetic_flag = in.status.bit(MREC_STATUS_ARITHMETIC_BIT);
    phasor_invalid_or = in.status.bit(PHASOR_STATUS_INVALID_BIT);
    blocks_accumulated = 1;
  } else {
    agg_total_samples += in.sample_count;
    agg_total_cycles += in.cycle_count;
    mask_and &= in.valid_mask;
    freq_sum += in.frequency_millihz;
    freq_all_valid &= in.frequency_valid;
    arithmetic_flag |= in.status.bit(MREC_STATUS_ARITHMETIC_BIT);
    phasor_invalid_or |= in.status.bit(PHASOR_STATUS_INVALID_BIT);
    blocks_accumulated += 1;
  }
  agg_last_sample = in.last_sample;
  const ap_uint<32> agg_last_seq = in.sequence;
  expected_next_seq = in.sequence + 1;
  expected_next_first = in.first_sample + in.sample_count;

  const bool first_block_fold = seed;
merge_lanes:
  for (int lane = 0; lane < MET_ACTIVE_CHANNELS; ++lane) {
#pragma HLS PIPELINE off
    const ap_int<128> sum_base =
        first_block_fold ? ap_int<128>(0) : acc_sum[lane];
    acc_sum[lane] = sum_base + in.sum[lane];
    const ap_uint<128> square_base =
        first_block_fold ? ap_uint<128>(0) : acc_square[lane];
    acc_square[lane] = met_add_square_saturating<128>(
        square_base, in.square[lane], arithmetic_flag);
    const ap_int<64> raw_sum_base =
        first_block_fold ? ap_int<64>(0) : acc_raw_sum[lane];
    acc_raw_sum[lane] = raw_sum_base + in.raw_sum[lane];
    const ap_uint<96> raw_square_base =
        first_block_fold ? ap_uint<96>(0) : acc_raw_square[lane];
    acc_raw_square[lane] = raw_square_base + in.raw_square[lane];
    if (first_block_fold || in.minimum[lane] < acc_minimum[lane]) {
      acc_minimum[lane] = in.minimum[lane];
    }
    if (first_block_fold || in.maximum[lane] > acc_maximum[lane]) {
      acc_maximum[lane] = in.maximum[lane];
    }
  }
merge_power:
  for (int phase = 0; phase < MET_POWER_PHASES; ++phase) {
#pragma HLS PIPELINE off
    const ap_int<128> power_base =
        first_block_fold ? ap_int<128>(0) : acc_power[phase];
    acc_power[phase] = met_add_signed_saturating<128>(
        power_base, in.power_sum[phase], arithmetic_flag);
  }
merge_pairs:
  for (int pair = 0; pair < MET_VLL_PAIRS; ++pair) {
#pragma HLS PIPELINE off
    const ap_uint<128> vll_base =
        first_block_fold ? ap_uint<128>(0) : acc_vll_square[pair];
    acc_vll_square[pair] = met_add_square_saturating<128>(
        vll_base, in.vll_square[pair], arithmetic_flag);
  }
merge_phasor:
  for (int lane = 0; lane < MET_ACTIVE_CHANNELS; ++lane) {
#pragma HLS PIPELINE off
    const ap_int<128> re_base =
        first_block_fold ? ap_int<128>(0) : acc_phasor_re[lane];
    acc_phasor_re[lane] = met_add_signed_saturating<128>(
        re_base, in.phasor_re[lane], arithmetic_flag);
    const ap_int<128> im_base =
        first_block_fold ? ap_int<128>(0) : acc_phasor_im[lane];
    acc_phasor_im[lane] = met_add_signed_saturating<128>(
        im_base, in.phasor_im[lane], arithmetic_flag);
  }

  if (blocks_accumulated != MET_BASIC_BLOCKS_PER_AGGREGATE) {
    return;
  }

  // Fifteenth eligible block: finalize the whole interval (the SHARED
  // arithmetic — one definition for both tiers) and emit the record quad.
  const ap_uint<8> result_mask = mask_and & ap_uint<8>(0x7F);
  const ap_uint<32> count_now = agg_total_samples;

  met_finalize_out_t fin;
  met_finalize_interval(acc_sum, acc_square, acc_raw_sum, acc_raw_square,
                        acc_minimum, acc_maximum, acc_vll_square, acc_power,
                        acc_phasor_re, acc_phasor_im, count_now,
                        agg_dc_remove, result_mask, fin, arithmetic_flag);

  const ap_uint<36> freq_mean =
      floor_div_const<36, MET_BASIC_BLOCKS_PER_AGGREGATE>(freq_sum);

  out_sequence += 1;
  blocks_accumulated = 0;

  const ap_uint<32> shape_word =
      (ap_uint<32>(MET_BASIC_BLOCKS_PER_AGGREGATE) << MTR2_SHAPE_BLOCKS_LSB) |
      (ap_uint<32>(agg_nominal) << MTR2_SHAPE_NOMINAL_LSB) |
      (ap_uint<32>(agg_total_cycles) << MTR2_SHAPE_CYCLES_LSB);

  // ---- AGG-v3: the aggregate fundamental record (MTR2 interior + the
  // ---- documented additions; status keeps the MTR2 bit semantics). ----
  record_image_t image;
  clear_record(image);
  const ap_uint<32> agg_status =
      (ap_uint<32>(arithmetic_flag) << MREC_STATUS_ARITHMETIC_BIT) |
      (ap_uint<32>(1) << MTR2_STATUS_COMPLETE_BIT) |
      (ap_uint<32>(freq_all_valid) << MTR2_STATUS_FREQUENCY_BIT);
  fill_envelope(image, out_sequence, agg_generation, agg_sample_rate,
                count_now, result_mask, agg_status, agg_first_sample);
  image.word[MTR2_SHAPE_WORD] = shape_word;
  image.word[MTR2_FIRST_BASIC_SEQ_WORD] = agg_first_seq;
  image.word[MTR2_LAST_BASIC_SEQ_WORD] = agg_last_seq;
agg_record_lanes:
  for (int lane = 0; lane < MET_CHANNEL_LANES; ++lane) {
#pragma HLS PIPELINE off
    if (lane < MET_ACTIVE_CHANNELS) {
      const ap_uint<64> rms_units = fin.rms_q16[lane] >> 16;
      const int base = MTR2_CH_BASE_WORD + lane * MTR2_CH_STRIDE_WORDS;
      image.word[base + 0] = rms_units.range(31, 0);
      image.word[base + 1] = rms_units.range(63, 32);
    }
  }
  image.word[MTR2_FREQUENCY_WORD] =
      (freq_all_valid == 1) ? ap_uint<32>(freq_mean.range(31, 0))
                            : ap_uint<32>(0);
  image.word[MTR2_RESET_COUNT_WORD] = reset_count;
  image.word[MTR2_INELIGIBLE_COUNT_WORD] = ineligible_count;
  image.word[MTR2_CONTINUITY_COUNT_WORD] = continuity_count;
  image.word[AGG_LAST_SAMPLE_LOW_WORD] = agg_last_sample.range(31, 0);
  image.word[AGG_LAST_SAMPLE_HIGH_WORD] = agg_last_sample.range(63, 32);
agg_record_pairs:
  for (int pair = 0; pair < MET_VLL_PAIRS; ++pair) {
#pragma HLS PIPELINE off
    image.word[AGG_VLL_BASE_WORD + pair] =
        ap_uint<64>(fin.vll_rms[pair] >> 16).range(31, 0);
  }
  serialize_record<MREC_FORMAT_AGG_V3>(image, m_axis);

  // Sibling status: common arithmetic bit, plus phasor-invalid (bit 1)
  // on the phasor-domain records — the basic-period siblings' semantics.
  const ap_uint<32> sibling_status =
      ap_uint<32>(arithmetic_flag) << MREC_STATUS_ARITHMETIC_BIT;
  const ap_uint<32> phasor_status =
      sibling_status |
      (ap_uint<32>(phasor_invalid_or) << PHASOR_STATUS_INVALID_BIT);

  // ---- AGG-POWER: payload map identical to POWER-v1. ------------------
  record_image_t power_image;
  clear_record(power_image);
  fill_envelope(power_image, out_sequence, agg_generation, agg_sample_rate,
                count_now, result_mask, sibling_status, agg_first_sample);
  power_image.word[MTR2_SHAPE_WORD] = shape_word;
  power_image.word[MTR2_FIRST_BASIC_SEQ_WORD] = agg_first_seq;
  power_image.word[MTR2_LAST_BASIC_SEQ_WORD] = agg_last_seq;
agg_power_phases:
  for (int phase = 0; phase < MET_POWER_PHASES; ++phase) {
#pragma HLS PIPELINE off
    const int base = POWER_PHASE_BASE_WORD + phase * POWER_PHASE_STRIDE;
    const ap_uint<64> p_bits = ap_uint<64>(fin.phase_p_pw[phase]);
    power_image.word[base + POWER_PHASE_P_LOW] = p_bits.range(31, 0);
    power_image.word[base + POWER_PHASE_P_HIGH] = p_bits.range(63, 32);
    power_image.word[base + POWER_PHASE_S_LOW] =
        fin.phase_s_pva[phase].range(31, 0);
    power_image.word[base + POWER_PHASE_S_HIGH] =
        fin.phase_s_pva[phase].range(63, 32);
    power_image.word[base + POWER_PHASE_PF] =
        ap_uint<32>(ap_int<32>(fin.phase_pf_e6[phase]));
  }
  const ap_uint<64> total_p_bits = ap_uint<64>(fin.total_p_pw);
  power_image.word[POWER_TOTAL_P_LOW_WORD] = total_p_bits.range(31, 0);
  power_image.word[POWER_TOTAL_P_HIGH_WORD] = total_p_bits.range(63, 32);
  power_image.word[POWER_TOTAL_S_LOW_WORD] = fin.total_s_pva.range(31, 0);
  power_image.word[POWER_TOTAL_S_HIGH_WORD] = fin.total_s_pva.range(63, 32);
  power_image.word[POWER_TOTAL_PF_WORD] =
      ap_uint<32>(ap_int<32>(fin.total_pf_e6));
agg_power_crest:
  for (int lane = 0; lane < MET_ACTIVE_CHANNELS; ++lane) {
#pragma HLS PIPELINE off
    power_image.word[POWER_CREST_BASE_WORD + lane] = fin.crest_e4[lane];
  }
  serialize_record<MREC_FORMAT_AGG_POWER_V1>(power_image, m_axis);

  // ---- AGG-PHASOR: payload map identical to PHASOR-v1. ----------------
  record_image_t phasor_image;
  clear_record(phasor_image);
  fill_envelope(phasor_image, out_sequence, agg_generation, agg_sample_rate,
                count_now, result_mask, phasor_status, agg_first_sample);
  phasor_image.word[MTR2_SHAPE_WORD] = shape_word;
  phasor_image.word[MTR2_FIRST_BASIC_SEQ_WORD] = agg_first_seq;
  phasor_image.word[MTR2_LAST_BASIC_SEQ_WORD] = agg_last_seq;
agg_phasor_lanes:
  for (int lane = 0; lane < MET_ACTIVE_CHANNELS; ++lane) {
#pragma HLS PIPELINE off
    const int base = PHASOR_CH_BASE_WORD + lane * PHASOR_CH_STRIDE;
    phasor_image.word[base + PHASOR_CH_FUND_RMS] =
        ap_uint<64>(fin.fund_rms_q16[lane] >> 16).range(31, 0);
    const ap_int<32> rel_turns =
        fin.angle_turns[lane] - fin.angle_turns[MET_LANE_VA];
    phasor_image.word[base + PHASOR_CH_ANGLE] =
        ap_uint<32>(met_turns_to_millidegrees(rel_turns));
  }
agg_phasor_pairs:
  for (int pair = 0; pair < MET_VLL_PAIRS; ++pair) {
#pragma HLS PIPELINE off
    const int base = PHASOR_VLL_BASE_WORD + pair * PHASOR_VLL_STRIDE;
    phasor_image.word[base + PHASOR_CH_FUND_RMS] =
        ap_uint<64>(fin.vll_fund_rms_q16[pair] >> 16).range(31, 0);
    const ap_int<32> rel_turns =
        fin.vll_angle_turns[pair] - fin.angle_turns[MET_LANE_VA];
    phasor_image.word[base + PHASOR_CH_ANGLE] =
        ap_uint<32>(met_turns_to_millidegrees(rel_turns));
  }
agg_phasor_phases:
  for (int phase = 0; phase < MET_POWER_PHASES; ++phase) {
#pragma HLS PIPELINE off
    phasor_image.word[PHASOR_DISP_BASE_WORD + phase] =
        ap_uint<32>(met_turns_to_millidegrees(fin.disp_turns[phase]));
    const ap_uint<64> q1_bits = ap_uint<64>(fin.phase_q1_pvar[phase]);
    phasor_image.word[PHASOR_Q1_BASE_WORD + phase * 2] = q1_bits.range(31, 0);
    phasor_image.word[PHASOR_Q1_BASE_WORD + phase * 2 + 1] =
        q1_bits.range(63, 32);
    phasor_image.word[PHASOR_DPF_BASE_WORD + phase] =
        ap_uint<32>(ap_int<32>(fin.phase_dpf_e6[phase]));
    const ap_uint<64> p1_bits = ap_uint<64>(fin.phase_p1_pw[phase]);
    phasor_image.word[PHASOR_P1_BASE_WORD + phase * 2] = p1_bits.range(31, 0);
    phasor_image.word[PHASOR_P1_BASE_WORD + phase * 2 + 1] =
        p1_bits.range(63, 32);
  }
  const ap_uint<64> q1_total_bits = ap_uint<64>(fin.total_q1_pvar);
  phasor_image.word[PHASOR_Q1_TOTAL_LOW_WORD] = q1_total_bits.range(31, 0);
  phasor_image.word[PHASOR_Q1_TOTAL_HIGH_WORD] = q1_total_bits.range(63, 32);
  phasor_image.word[PHASOR_DPF_TOTAL_WORD] =
      ap_uint<32>(ap_int<32>(fin.total_dpf_e6));
  phasor_image.word[PHASOR_FLAGS_WORD] =
      (ap_uint<32>(fin.phase_nature[0]) << PHASOR_FLAGS_NATURE_A_LSB) |
      (ap_uint<32>(fin.phase_nature[1]) << PHASOR_FLAGS_NATURE_B_LSB) |
      (ap_uint<32>(fin.phase_nature[2]) << PHASOR_FLAGS_NATURE_C_LSB) |
      (ap_uint<32>(fin.total_nature) << PHASOR_FLAGS_NATURE_TOTAL_LSB) |
      (ap_uint<32>(fin.angle_ref_valid) << PHASOR_FLAGS_REF_VALID_BIT);
  const ap_uint<64> p1_total_bits = ap_uint<64>(fin.total_p1_pw);
  phasor_image.word[PHASOR_P1_TOTAL_LOW_WORD] = p1_total_bits.range(31, 0);
  phasor_image.word[PHASOR_P1_TOTAL_HIGH_WORD] = p1_total_bits.range(63, 32);
  serialize_record<MREC_FORMAT_AGG_PHASOR_V2>(phasor_image, m_axis);

  // ---- AGG-UNBAL: payload map identical to UNBAL-v1. ------------------
  record_image_t unbal_image;
  clear_record(unbal_image);
  fill_envelope(unbal_image, out_sequence, agg_generation, agg_sample_rate,
                count_now, result_mask, phasor_status, agg_first_sample);
  unbal_image.word[MTR2_SHAPE_WORD] = shape_word;
  unbal_image.word[MTR2_FIRST_BASIC_SEQ_WORD] = agg_first_seq;
  unbal_image.word[MTR2_LAST_BASIC_SEQ_WORD] = agg_last_seq;
agg_unbal_sets:
  for (int set = 0; set < 2; ++set) {
#pragma HLS PIPELINE off
  agg_unbal_terms:
    for (int component = 0; component < 3; ++component) {
#pragma HLS PIPELINE off
      const int base = ((set == 0) ? UNBAL_V_BASE_WORD : UNBAL_I_BASE_WORD) +
                       component * UNBAL_SEQ_STRIDE;
      unbal_image.word[base + UNBAL_SEQ_RMS] =
          ap_uint<64>(fin.seq_rms_q16[set][component] >> 16).range(31, 0);
      const ap_int<32> rel_turns = fin.seq_angle_turns[set][component] -
                                   fin.angle_turns[MET_LANE_VA];
      unbal_image.word[base + UNBAL_SEQ_ANGLE] =
          ap_uint<32>(met_turns_to_millidegrees(rel_turns));
    }
    const int zero_word =
        (set == 0) ? UNBAL_V_ZERO_RATIO_WORD : UNBAL_I_ZERO_RATIO_WORD;
    const int unbal_word =
        (set == 0) ? UNBAL_V_UNBALANCE_WORD : UNBAL_I_UNBALANCE_WORD;
    unbal_image.word[zero_word] = fin.seq_zero_ratio_e6[set];
    unbal_image.word[unbal_word] = fin.seq_unbal_ratio_e6[set];
  }
  unbal_image.word[UNBAL_FLAGS_WORD] =
      (ap_uint<32>(fin.seq_set_valid[0]) << UNBAL_FLAGS_V_VALID_BIT) |
      (ap_uint<32>(fin.seq_set_valid[1]) << UNBAL_FLAGS_I_VALID_BIT) |
      (ap_uint<32>(fin.angle_ref_valid) << UNBAL_FLAGS_REF_VALID_BIT);
  serialize_record<MREC_FORMAT_AGG_UNBAL_V2>(unbal_image, m_axis);
}
