#include "agg10_12_cycle_engine.hpp"

#include "metrology_finalize.hpp"
#include "metrology_math.hpp"
#include "metrology_stats.hpp"
#include "metrology_trig.hpp"

// 10/12-cycle basic measurement engine. Contract, beat layout, and block
// rules: see agg10_12_cycle_engine.hpp.
//
// Structure: one free-running single-shot process (the house pattern):
// each invocation consumes at most one result beat; the invocation
// closing a block runs the whole finalize + every emission inline. Input
// cadence is one beat per grid cycle (~16-20 ms), four orders of
// magnitude slower than the sample-domain engines, so the brief finalize
// backpressure is absorbed by the AXIS register slices upstream.
//
// The derived-quantity arithmetic lives in the shared
// metrology_finalize.hpp (one definition for this tier and the 150/180
// tier); this file owns the block rules, the merge, the block-result
// beat, and the record-word assembly.

void hls_agg10_12_cycle_engine(hls::stream<agg10_12_input_beat_t> &s_result,
                         hls::stream<record_axis_t> &m_axis,
                         hls::stream<agg_block_beat_t> &m_result) {
  // s_result unregistered (shim registers its side); both masters keep
  // boundary registers (a raw HLS axis master gates TVALID on TREADY --
  // AXI-illegal -- and m_result feeds the 150/180 tier's shim directly).
#pragma HLS INTERFACE mode=axis port=s_result register_mode=off
#pragma HLS INTERFACE mode=axis port=m_result register_mode=both
#pragma HLS INTERFACE mode=axis port=m_axis
#pragma HLS INTERFACE mode=ap_ctrl_none port=return

  // Committed configuration and block state; syn.rtl.reset=state re-zeroes
  // these on aresetn exactly like the sibling engines.
  static ap_uint<1> apply_seen = 0;
  static ap_uint<32> active_generation = 0;
  static ap_uint<32> active_sample_rate = 32000;
  static ap_uint<8> active_valid_mask = 0;
  static ap_uint<1> active_enable = 0;
  static ap_uint<1> active_dc_remove = 1;
  static ap_uint<1> arithmetic_overflow = 0;  // sticky until APPLY
  static ap_uint<32> sequence = 0;            // first emitted result carries 1

  // Block assembly state.
  static ap_uint<8> cycles_in_block = 0;
  static ap_uint<8> block_cycles_target = 12;
  static ap_uint<8> block_nominal = 60;
  static ap_uint<32> block_sample_count = 0;
  static ap_uint<64> block_first_sample = 0;
  static ap_uint<8> block_mask = 0x7F;
  static ap_uint<1> block_locked_and = 1;
  static ap_uint<1> block_fallback_or = 0;
  static ap_uint<32> expected_result_seq = 0;
  static ap_uint<32> expected_cycle_seq = 0;
  static ap_uint<1> have_expectation = 0;
  // First finalized block after reset/APPLY/any discard carries the mark.
  static ap_uint<1> disc_pending = 1;
  // Any merged cycle without a usable frequency reference poisons the
  // block's phasor products (PHASOR/UNBAL record status bit 1).
  static ap_uint<1> block_phasor_invalid = 0;

  // Merged block accumulators — bit-identical to the retired Mtr1 block
  // accumulators by construction (same widths, same saturation rules).
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

  if (s_result.empty()) {
    return;
  }
  const agg10_12_input_beat_t beat = s_result.read();

  const ap_uint<1> beat_apply = beat.bit(AGG_IN_APPLY_BIT);
  if (beat_apply != apply_seen) {
    apply_seen = beat_apply;
    active_generation =
        beat.range(AGG_IN_CFG_GEN_LSB + 31, AGG_IN_CFG_GEN_LSB);
    active_sample_rate =
        beat.range(AGG_IN_CFG_RATE_LSB + 31, AGG_IN_CFG_RATE_LSB);
    active_valid_mask =
        beat.range(AGG_IN_CFG_MASK_LSB + 7, AGG_IN_CFG_MASK_LSB);
    active_enable = beat.bit(AGG_IN_ENABLE_BIT);
    active_dc_remove = beat.bit(AGG_IN_DC_REMOVE_BIT);
    arithmetic_overflow = 0;
    cycles_in_block = 0;
    have_expectation = 0;
    disc_pending = 1;
  }

  if (active_enable == 0) {
    return;
  }

  const single_cycle_result_t cycle = unpack_single_cycle_result(
      ap_uint<SCYC_BEAT_BITS>(beat.range(SCYC_BEAT_BITS - 1, 0)));

  // Generation boundary: results of another generation never merge.
  if (cycle.generation != active_generation) {
    cycles_in_block = 0;
    have_expectation = 0;
    disc_pending = 1;
    return;
  }

  // Continuity: an upstream gap mark, a break in either sequence, or a
  // nominal change discards the partial block; the carrying cycle is a
  // whole valid cycle and starts the next block.
  const bool upstream_gap =
      cycle.status.bit(SCYC_STATUS_FIRST_AFTER_GAP_BIT) == 1;
  const bool sequence_break =
      have_expectation == 1 && (cycle.sequence != expected_result_seq ||
                                cycle.cycle_sequence != expected_cycle_seq);
  const bool nominal_change =
      cycles_in_block != 0 && cycle.nominal_hz != block_nominal;
  if (upstream_gap || sequence_break || nominal_change) {
    cycles_in_block = 0;
    disc_pending = 1;
  }
  expected_result_seq = cycle.sequence + 1;
  expected_cycle_seq = cycle.cycle_sequence + 1;
  have_expectation = 1;

  // The cycles' own arithmetic flags fold into the sticky block flag.
  arithmetic_overflow |= cycle.status.bit(SCYC_STATUS_OVERFLOW_BIT);

  const bool first_cycle = (cycles_in_block == 0);
  if (first_cycle) {
    block_nominal = cycle.nominal_hz;
    block_cycles_target = met_expected_cycles(cycle.nominal_hz);
    block_first_sample = cycle.first_sample;
    block_sample_count = 0;
    block_mask = 0x7F;
    block_locked_and = 1;
    block_fallback_or = 0;
  }
  block_sample_count += cycle.sample_count;
  block_mask &= cycle.valid_mask;
  block_locked_and &= beat.bit(AGG_IN_LOCKED_BIT);
  block_fallback_or |= beat.bit(AGG_IN_FALLBACK_BIT);
  const ap_uint<1> cycle_phasor_invalid =
      cycle.status.bit(SCYC_STATUS_PHASOR_INVALID_BIT);
  block_phasor_invalid =
      first_cycle ? cycle_phasor_invalid
                  : ap_uint<1>(block_phasor_invalid | cycle_phasor_invalid);

merge_lanes:
  for (int lane = 0; lane < MET_ACTIVE_CHANNELS; ++lane) {
#pragma HLS PIPELINE off
    const ap_int<128> sum_base = first_cycle ? ap_int<128>(0) : acc_sum[lane];
    acc_sum[lane] = sum_base + cycle.sum[lane];
    const ap_uint<128> square_base =
        first_cycle ? ap_uint<128>(0) : acc_square[lane];
    acc_square[lane] = met_add_square_saturating<128>(
        square_base, cycle.square[lane], arithmetic_overflow);
    const ap_int<64> raw_sum_base =
        first_cycle ? ap_int<64>(0) : acc_raw_sum[lane];
    acc_raw_sum[lane] = raw_sum_base + cycle.raw_sum[lane];
    const ap_uint<96> raw_square_base =
        first_cycle ? ap_uint<96>(0) : acc_raw_square[lane];
    acc_raw_square[lane] = raw_square_base + cycle.raw_square[lane];
    if (first_cycle || cycle.minimum[lane] < acc_minimum[lane]) {
      acc_minimum[lane] = cycle.minimum[lane];
    }
    if (first_cycle || cycle.maximum[lane] > acc_maximum[lane]) {
      acc_maximum[lane] = cycle.maximum[lane];
    }
  }
merge_power:
  for (int phase = 0; phase < MET_POWER_PHASES; ++phase) {
#pragma HLS PIPELINE off
    const ap_int<128> power_base =
        first_cycle ? ap_int<128>(0) : acc_power[phase];
    acc_power[phase] = met_add_signed_saturating<128>(
        power_base, cycle.power_sum[phase], arithmetic_overflow);
  }
merge_pairs:
  for (int pair = 0; pair < MET_VLL_PAIRS; ++pair) {
#pragma HLS PIPELINE off
    const ap_uint<128> vll_base =
        first_cycle ? ap_uint<128>(0) : acc_vll_square[pair];
    acc_vll_square[pair] = met_add_square_saturating<128>(
        vll_base, cycle.vll_square[pair], arithmetic_overflow);
  }
merge_phasor:
  for (int lane = 0; lane < MET_ACTIVE_CHANNELS; ++lane) {
#pragma HLS PIPELINE off
    const ap_int<128> re_base =
        first_cycle ? ap_int<128>(0) : acc_phasor_re[lane];
    acc_phasor_re[lane] = met_add_signed_saturating<128>(
        re_base, cycle.phasor_re[lane], arithmetic_overflow);
    const ap_int<128> im_base =
        first_cycle ? ap_int<128>(0) : acc_phasor_im[lane];
    acc_phasor_im[lane] = met_add_signed_saturating<128>(
        im_base, cycle.phasor_im[lane], arithmetic_overflow);
  }

  const ap_uint<8> cycles_now = cycles_in_block + 1;
  if (cycles_now < block_cycles_target) {
    cycles_in_block = cycles_now;
    return;
  }
  cycles_in_block = 0;

  // ---- Finalize this block inline (shared arithmetic) ------------------
  const ap_uint<8> result_mask =
      (active_valid_mask & block_mask) & ap_uint<8>(0x7F);
  const ap_uint<32> count_now = block_sample_count;
  sequence += 1;

  met_finalize_out_t fin;
  met_finalize_interval(acc_sum, acc_square, acc_raw_sum, acc_raw_square,
                        acc_minimum, acc_maximum, acc_vll_square, acc_power,
                        acc_phasor_re, acc_phasor_im, count_now,
                        active_dc_remove, result_mask, fin,
                        arithmetic_overflow);

  const ap_uint<1> first_block = disc_pending;
  disc_pending = 0;
  const ap_uint<32> status =
      ap_uint<32>(arithmetic_overflow) | (ap_uint<32>(first_block) << 2);
  ap_uint<3> flags = 0;
  flags[MET_FLAG_LOCKED] = block_locked_and;
  flags[MET_FLAG_FALLBACK] = block_fallback_or;
  flags[MET_FLAG_FIRST_BLOCK] = first_block;

  // Block-result beat for the 150/180-cycle aggregator: the block's
  // provenance plus its MERGE-SAFE ACCUMULATORS (agg_block_result.hpp) —
  // the higher tier merges by pure addition, never re-derives.
  agg_block_result_t result;
  result.sequence = sequence;
  result.generation = active_generation;
  result.first_sample = block_first_sample;
  result.last_sample = cycle.last_sample;
  result.sample_count = count_now;
  result.sample_rate_hz = active_sample_rate;
  result.nominal_hz = block_nominal;
  result.valid_mask = result_mask;
  result.flags = flags;
  result.cycle_count = block_cycles_target;
  result.status =
      status | (ap_uint<32>(block_phasor_invalid) << PHASOR_STATUS_INVALID_BIT);
  result.frequency_millihz = cycle.frequency_millihz;
  result.frequency_valid = cycle.frequency_valid;
  result.apply_toggle = apply_seen;
  result.dc_remove = active_dc_remove;
result_accumulators:
  for (int lane = 0; lane < MET_ACTIVE_CHANNELS; ++lane) {
#pragma HLS PIPELINE off
    result.sum[lane] = acc_sum[lane];
    result.square[lane] = acc_square[lane];
    result.raw_sum[lane] = acc_raw_sum[lane];
    result.raw_square[lane] = acc_raw_square[lane];
    result.minimum[lane] = acc_minimum[lane];
    result.maximum[lane] = acc_maximum[lane];
    result.phasor_re[lane] = acc_phasor_re[lane];
    result.phasor_im[lane] = acc_phasor_im[lane];
  }
result_pairs:
  for (int pair = 0; pair < MET_VLL_PAIRS; ++pair) {
#pragma HLS PIPELINE off
    result.vll_square[pair] = acc_vll_square[pair];
  }
result_power:
  for (int phase = 0; phase < MET_POWER_PHASES; ++phase) {
#pragma HLS PIPELINE off
    result.power_sum[phase] = acc_power[phase];
  }
  m_result.write(pack_agg_block_result(result));

  // BASIC-v4 record (MTR1-v3 interior plus the documented additions).
  record_image_t image;
  clear_record(image);
  fill_envelope(image, sequence, active_generation, active_sample_rate,
                count_now, result_mask, status, block_first_sample);
  image.word[MTR1_TIMING_WORD] =
      (ap_uint<32>(block_nominal) << MTR1_TIMING_NOMINAL_LSB) |
      (ap_uint<32>(block_cycles_target) << MTR1_TIMING_CYCLES_LSB) |
      (ap_uint<32>(flags) << MTR1_TIMING_FLAGS_LSB);
  image.word[BASIC_LAST_SAMPLE_LOW_WORD] = cycle.last_sample.range(31, 0);
  image.word[BASIC_LAST_SAMPLE_HIGH_WORD] = cycle.last_sample.range(63, 32);
record_lanes:
  for (int lane = 0; lane < MET_CHANNEL_LANES; ++lane) {
#pragma HLS PIPELINE off
    if (lane < MET_ACTIVE_CHANNELS) {
      const ap_int<64> mean_units = fin.mean_q16[lane] >> 16;  // arithmetic
      const ap_uint<64> rms_units = fin.rms_q16[lane] >> 16;
      const int base = MTR1_CH_BASE_WORD + lane * MTR1_CH_STRIDE_WORDS;
      image.word[base + MTR1_CH_MEAN_LOW] =
          ap_uint<64>(mean_units).range(31, 0);
      image.word[base + MTR1_CH_MEAN_HIGH] =
          ap_uint<64>(mean_units).range(63, 32);
      image.word[base + MTR1_CH_RMS_COUNT] = fin.rms_count[lane];
      image.word[base + MTR1_CH_RMS_LOW] = rms_units.range(31, 0);
      image.word[base + MTR1_CH_RMS_HIGH] = rms_units.range(63, 32);
    }
  }
record_pairs:
  for (int pair = 0; pair < MET_VLL_PAIRS; ++pair) {
#pragma HLS PIPELINE off
    image.word[BASIC_VLL_BASE_WORD + pair] =
        ap_uint<64>(fin.vll_rms[pair] >> 16).range(31, 0);
  }
  image.word[MTR1_FREQUENCY_VALUE_WORD] = cycle.frequency_millihz;
  image.word[MTR1_FREQUENCY_STATUS_WORD] =
      beat.range(AGG_IN_FREQ_STATUS_LSB + 31, AGG_IN_FREQ_STATUS_LSB);
  image.word[MTR1_FREQUENCY_PERIOD_WORD] =
      beat.range(AGG_IN_FREQ_PERIOD_LSB + 31, AGG_IN_FREQ_PERIOD_LSB);
  image.word[MTR1_FREQUENCY_SEQUENCE_WORD] =
      beat.range(AGG_IN_FREQ_SEQ_LSB + 31, AGG_IN_FREQ_SEQ_LSB);
  image.word[MTR1_CAPTURE_FRAMES_WORD] =
      beat.range(AGG_IN_CAP_FRAMES_LSB + 31, AGG_IN_CAP_FRAMES_LSB);
  image.word[MTR1_HEADER_ERRORS_WORD] =
      beat.range(AGG_IN_CAP_HDRERR_LSB + 31, AGG_IN_CAP_HDRERR_LSB);
  image.word[MTR1_FIFO_OVERFLOWS_WORD] =
      beat.range(AGG_IN_CAP_OVERFLOW_LSB + 31, AGG_IN_CAP_OVERFLOW_LSB);
  image.word[MTR1_ADC_ALERTS_WORD] =
      beat.range(AGG_IN_CAP_ALERTS_LSB + 31, AGG_IN_CAP_ALERTS_LSB);

  serialize_record<MREC_FORMAT_BASIC_V4>(image, m_axis);

  // POWER-v1 record on the same stream, describing the same block (same
  // sequence, generation, anchors, status).
  record_image_t power_image;
  clear_record(power_image);
  fill_envelope(power_image, sequence, active_generation, active_sample_rate,
                count_now, result_mask, status, block_first_sample);
  power_image.word[MTR1_TIMING_WORD] = image.word[MTR1_TIMING_WORD];
  power_image.word[BASIC_LAST_SAMPLE_LOW_WORD] =
      image.word[BASIC_LAST_SAMPLE_LOW_WORD];
  power_image.word[BASIC_LAST_SAMPLE_HIGH_WORD] =
      image.word[BASIC_LAST_SAMPLE_HIGH_WORD];
power_record_phases:
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
power_record_crest:
  for (int lane = 0; lane < MET_ACTIVE_CHANNELS; ++lane) {
#pragma HLS PIPELINE off
    power_image.word[POWER_CREST_BASE_WORD + lane] = fin.crest_e4[lane];
  }
  serialize_record<MREC_FORMAT_POWER_V1>(power_image, m_axis);

  // PHASOR-v1 record, third on the stream for the same block. Only the
  // PHASOR and UNBAL records carry the block phasor-invalid status bit.
  record_image_t phasor_image;
  clear_record(phasor_image);
  const ap_uint<32> phasor_status =
      status |
      (ap_uint<32>(block_phasor_invalid) << PHASOR_STATUS_INVALID_BIT);
  fill_envelope(phasor_image, sequence, active_generation, active_sample_rate,
                count_now, result_mask, phasor_status, block_first_sample);
  phasor_image.word[MTR1_TIMING_WORD] = image.word[MTR1_TIMING_WORD];
  phasor_image.word[BASIC_LAST_SAMPLE_LOW_WORD] =
      image.word[BASIC_LAST_SAMPLE_LOW_WORD];
  phasor_image.word[BASIC_LAST_SAMPLE_HIGH_WORD] =
      image.word[BASIC_LAST_SAMPLE_HIGH_WORD];
phasor_record_lanes:
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
phasor_record_pairs:
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
phasor_record_phases:
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
  serialize_record<MREC_FORMAT_PHASOR_V2>(phasor_image, m_axis);

  // UNBALANCE-v1 record, fourth on the stream (M10).
  record_image_t unbal_image;
  clear_record(unbal_image);
  fill_envelope(unbal_image, sequence, active_generation, active_sample_rate,
                count_now, result_mask, phasor_status, block_first_sample);
  unbal_image.word[MTR1_TIMING_WORD] = image.word[MTR1_TIMING_WORD];
  unbal_image.word[BASIC_LAST_SAMPLE_LOW_WORD] =
      image.word[BASIC_LAST_SAMPLE_LOW_WORD];
  unbal_image.word[BASIC_LAST_SAMPLE_HIGH_WORD] =
      image.word[BASIC_LAST_SAMPLE_HIGH_WORD];
unbal_record_sets:
  for (int set = 0; set < 2; ++set) {
#pragma HLS PIPELINE off
  unbal_record_terms:
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
  serialize_record<MREC_FORMAT_UNBAL_V2>(unbal_image, m_axis);
}
