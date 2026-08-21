#include "aggregation_engine.hpp"

#include "metrology_finalize.hpp"
#include "metrology_math.hpp"
#include "metrology_stats.hpp"
#include "metrology_trig.hpp"

// Cycle-block aggregation engine. Contract, topology, beat layout and
// tier rules: see aggregation_engine.hpp.
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

// Shared POWER payload (record words 16+). The 10/12 and 150/180 tiers have
// IDENTICAL payload maps for this record (M11), verified byte-for-byte
// before extraction, so one instance serves both; the envelope and the
// tier-specific words 13..15 stay with each caller.
static void fill_power_payload(const met_finalize_out_t &fin,
                            record_image_t &img) {
// INLINE, deliberately, after measurement: sharing these as real RTL
// modules (INLINE off + an allocation limit) cost -440 LUT but +1,565 FF,
// because the call interface has to carry a 2048-bit record_image_t and a
// ~5,740-bit met_finalize_out_t -- interface registers dwarfing the
// payload logic shared. Same mechanism that rules out a shared finalize
// IP (see the A1 notes). So: ONE definition in source, two instances in
// hardware, which is the pre-dedupe hardware at better source hygiene.
#pragma HLS INLINE
  fill_power_phases:
  for (int phase = 0; phase < MET_POWER_PHASES; ++phase) {
  #pragma HLS PIPELINE off
    const int base = POWER_PHASE_BASE_WORD + phase * POWER_PHASE_STRIDE;
    const ap_uint<64> p_bits = ap_uint<64>(fin.phase_p_pw[phase]);
    img.word[base + POWER_PHASE_P_LOW] = p_bits.range(31, 0);
    img.word[base + POWER_PHASE_P_HIGH] = p_bits.range(63, 32);
    img.word[base + POWER_PHASE_S_LOW] =
        fin.phase_s_pva[phase].range(31, 0);
    img.word[base + POWER_PHASE_S_HIGH] =
        fin.phase_s_pva[phase].range(63, 32);
    img.word[base + POWER_PHASE_PF] =
        ap_uint<32>(ap_int<32>(fin.phase_pf_e6[phase]));
  }
  const ap_uint<64> total_p_bits = ap_uint<64>(fin.total_p_pw);
  img.word[POWER_TOTAL_P_LOW_WORD] = total_p_bits.range(31, 0);
  img.word[POWER_TOTAL_P_HIGH_WORD] = total_p_bits.range(63, 32);
  img.word[POWER_TOTAL_S_LOW_WORD] = fin.total_s_pva.range(31, 0);
  img.word[POWER_TOTAL_S_HIGH_WORD] = fin.total_s_pva.range(63, 32);
  img.word[POWER_TOTAL_PF_WORD] =
      ap_uint<32>(ap_int<32>(fin.total_pf_e6));
  fill_power_crest:
  for (int lane = 0; lane < MET_ACTIVE_CHANNELS; ++lane) {
  #pragma HLS PIPELINE off
    img.word[POWER_CREST_BASE_WORD + lane] = fin.crest_e4[lane];
  }
}

// Shared PHASOR payload (record words 16+). The 10/12 and 150/180 tiers have
// IDENTICAL payload maps for this record (M11), verified byte-for-byte
// before extraction, so one instance serves both; the envelope and the
// tier-specific words 13..15 stay with each caller.
static void fill_phasor_payload(const met_finalize_out_t &fin,
                            record_image_t &img) {
// INLINE, deliberately, after measurement: sharing these as real RTL
// modules (INLINE off + an allocation limit) cost -440 LUT but +1,565 FF,
// because the call interface has to carry a 2048-bit record_image_t and a
// ~5,740-bit met_finalize_out_t -- interface registers dwarfing the
// payload logic shared. Same mechanism that rules out a shared finalize
// IP (see the A1 notes). So: ONE definition in source, two instances in
// hardware, which is the pre-dedupe hardware at better source hygiene.
#pragma HLS INLINE
  fill_phasor_lanes:
  for (int lane = 0; lane < MET_ACTIVE_CHANNELS; ++lane) {
  #pragma HLS PIPELINE off
    const int base = PHASOR_CH_BASE_WORD + lane * PHASOR_CH_STRIDE;
    img.word[base + PHASOR_CH_FUND_RMS] =
        ap_uint<64>(fin.fund_rms_q16[lane] >> 16).range(31, 0);
    const ap_int<32> rel_turns =
        fin.angle_turns[lane] - fin.angle_turns[MET_LANE_VA];
    img.word[base + PHASOR_CH_ANGLE] =
        ap_uint<32>(met_turns_to_millidegrees(rel_turns));
  }
  fill_phasor_pairs:
  for (int pair = 0; pair < MET_VLL_PAIRS; ++pair) {
  #pragma HLS PIPELINE off
    const int base = PHASOR_VLL_BASE_WORD + pair * PHASOR_VLL_STRIDE;
    img.word[base + PHASOR_CH_FUND_RMS] =
        ap_uint<64>(fin.vll_fund_rms_q16[pair] >> 16).range(31, 0);
    const ap_int<32> rel_turns =
        fin.vll_angle_turns[pair] - fin.angle_turns[MET_LANE_VA];
    img.word[base + PHASOR_CH_ANGLE] =
        ap_uint<32>(met_turns_to_millidegrees(rel_turns));
  }
  fill_phasor_phases:
  for (int phase = 0; phase < MET_POWER_PHASES; ++phase) {
  #pragma HLS PIPELINE off
    img.word[PHASOR_DISP_BASE_WORD + phase] =
        ap_uint<32>(met_turns_to_millidegrees(fin.disp_turns[phase]));
    const ap_uint<64> q1_bits = ap_uint<64>(fin.phase_q1_pvar[phase]);
    img.word[PHASOR_Q1_BASE_WORD + phase * 2] = q1_bits.range(31, 0);
    img.word[PHASOR_Q1_BASE_WORD + phase * 2 + 1] =
        q1_bits.range(63, 32);
    img.word[PHASOR_DPF_BASE_WORD + phase] =
        ap_uint<32>(ap_int<32>(fin.phase_dpf_e6[phase]));
    const ap_uint<64> p1_bits = ap_uint<64>(fin.phase_p1_pw[phase]);
    img.word[PHASOR_P1_BASE_WORD + phase * 2] = p1_bits.range(31, 0);
    img.word[PHASOR_P1_BASE_WORD + phase * 2 + 1] =
        p1_bits.range(63, 32);
  }
  const ap_uint<64> q1_total_bits = ap_uint<64>(fin.total_q1_pvar);
  img.word[PHASOR_Q1_TOTAL_LOW_WORD] = q1_total_bits.range(31, 0);
  img.word[PHASOR_Q1_TOTAL_HIGH_WORD] = q1_total_bits.range(63, 32);
  img.word[PHASOR_DPF_TOTAL_WORD] =
      ap_uint<32>(ap_int<32>(fin.total_dpf_e6));
  img.word[PHASOR_FLAGS_WORD] =
      (ap_uint<32>(fin.phase_nature[0]) << PHASOR_FLAGS_NATURE_A_LSB) |
      (ap_uint<32>(fin.phase_nature[1]) << PHASOR_FLAGS_NATURE_B_LSB) |
      (ap_uint<32>(fin.phase_nature[2]) << PHASOR_FLAGS_NATURE_C_LSB) |
      (ap_uint<32>(fin.total_nature) << PHASOR_FLAGS_NATURE_TOTAL_LSB) |
      (ap_uint<32>(fin.angle_ref_valid) << PHASOR_FLAGS_REF_VALID_BIT);
  const ap_uint<64> p1_total_bits = ap_uint<64>(fin.total_p1_pw);
  img.word[PHASOR_P1_TOTAL_LOW_WORD] = p1_total_bits.range(31, 0);
  img.word[PHASOR_P1_TOTAL_HIGH_WORD] = p1_total_bits.range(63, 32);
}

// Shared UNBAL payload (record words 16+). The 10/12 and 150/180 tiers have
// IDENTICAL payload maps for this record (M11), verified byte-for-byte
// before extraction, so one instance serves both; the envelope and the
// tier-specific words 13..15 stay with each caller.
static void fill_unbal_payload(const met_finalize_out_t &fin,
                            record_image_t &img) {
// INLINE, deliberately, after measurement: sharing these as real RTL
// modules (INLINE off + an allocation limit) cost -440 LUT but +1,565 FF,
// because the call interface has to carry a 2048-bit record_image_t and a
// ~5,740-bit met_finalize_out_t -- interface registers dwarfing the
// payload logic shared. Same mechanism that rules out a shared finalize
// IP (see the A1 notes). So: ONE definition in source, two instances in
// hardware, which is the pre-dedupe hardware at better source hygiene.
#pragma HLS INLINE
  fill_unbal_sets:
  for (int set = 0; set < 2; ++set) {
  #pragma HLS PIPELINE off
  fill_unbal_terms:
    for (int component = 0; component < 3; ++component) {
  #pragma HLS PIPELINE off
      const int base = ((set == 0) ? UNBAL_V_BASE_WORD : UNBAL_I_BASE_WORD) +
                       component * UNBAL_SEQ_STRIDE;
      img.word[base + UNBAL_SEQ_RMS] =
          ap_uint<64>(fin.seq_rms_q16[set][component] >> 16).range(31, 0);
      const ap_int<32> rel_turns = fin.seq_angle_turns[set][component] -
                                   fin.angle_turns[MET_LANE_VA];
      img.word[base + UNBAL_SEQ_ANGLE] =
          ap_uint<32>(met_turns_to_millidegrees(rel_turns));
    }
    const int zero_word =
        (set == 0) ? UNBAL_V_ZERO_RATIO_WORD : UNBAL_I_ZERO_RATIO_WORD;
    const int unbal_word =
        (set == 0) ? UNBAL_V_UNBALANCE_WORD : UNBAL_I_UNBALANCE_WORD;
    img.word[zero_word] = fin.seq_zero_ratio_e6[set];
    img.word[unbal_word] = fin.seq_unbal_ratio_e6[set];
  }
  img.word[UNBAL_FLAGS_WORD] =
      (ap_uint<32>(fin.seq_set_valid[0]) << UNBAL_FLAGS_V_VALID_BIT) |
      (ap_uint<32>(fin.seq_set_valid[1]) << UNBAL_FLAGS_I_VALID_BIT) |
      (ap_uint<32>(fin.angle_ref_valid) << UNBAL_FLAGS_REF_VALID_BIT);
}

void hls_aggregation_engine(hls::stream<agg_input_beat_t> &s_result,
                            hls::stream<record_axis_t> &m_basic,
                            hls::stream<record_axis_t> &m_agg) {
  // s_result unregistered (the shim registers its side); both record
  // masters keep boundary registers, because a raw HLS axis master gates
  // TVALID on TREADY, which is AXI-illegal. There is no third interface
  // any more: the block result the 150/180 tier consumes is a local
  // variable, so its 7072-bit AXIS pair and FIFO are gone.
#pragma HLS INTERFACE mode=axis port=s_result register_mode=off
#pragma HLS INTERFACE mode=axis port=m_basic
#pragma HLS INTERFACE mode=axis port=m_agg
#pragma HLS INTERFACE mode=ap_ctrl_none port=return

  // Committed configuration and block state; syn.rtl.reset=state re-zeroes
  // these on aresetn exactly like the sibling engines.
  static ap_uint<1> apply_seen = 0;
  // Set when a block close also completes an interval; the interval
  // finalize then runs on the following invocation.
  static ap_uint<1> interval_pending = 0;
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

  // Open-aggregate bookkeeping; syn.rtl.reset=state re-zeroes on aresetn.
  static ap_uint<1> a3s_apply_seen = 0;
  static ap_uint<5> a3s_blocks_accumulated = 0;
  static ap_uint<32> a3s_agg_generation = 0;
  static ap_uint<8> a3s_agg_nominal = 0;
  static ap_uint<32> a3s_agg_sample_rate = 0;
  static ap_uint<1> a3s_agg_dc_remove = 1;
  static ap_uint<64> a3s_agg_first_sample = 0;
  static ap_uint<64> a3s_agg_last_sample = 0;
  static ap_uint<32> a3s_agg_first_seq = 0;
  static ap_uint<32> a3s_agg_total_samples = 0;
  static ap_uint<16> a3s_agg_total_cycles = 0;
  static ap_uint<8> a3s_mask_and = 0;
  static ap_uint<36> a3s_freq_sum = 0;
  static ap_uint<1> a3s_freq_all_valid = 0;
  static ap_uint<1> a3s_arithmetic_flag = 0;
  static ap_uint<1> a3s_phasor_invalid_or = 0;
  // Unsigned arithmetic wraps at 2**32 / 2**64, so sequence and sample
  // continuity survive wraparound without special cases (Mtr2 rule).
  static ap_uint<32> a3s_expected_next_seq = 0;
  static ap_uint<64> a3s_expected_next_first = 0;
  static ap_uint<32> a3s_out_sequence = 0;

  // Diagnostics (record-carried, words 33..35 — the AGG_* register tap).
  static ap_uint<32> a3s_reset_count = 0;
  static ap_uint<32> a3s_ineligible_count = 0;
  static ap_uint<32> a3s_continuity_count = 0;

  // Interval accumulators: the 15 blocks' accumulators summed. Same
  // widths as the block tier — the width analysis in
  // agg_block_result.hpp covers the 15x sums.
  static ap_int<128> a3s_acc_sum[MET_ACTIVE_CHANNELS];
#pragma HLS BIND_STORAGE variable=a3s_acc_sum type=ram_s2p impl=lutram
  static ap_uint<128> a3s_acc_square[MET_ACTIVE_CHANNELS];
#pragma HLS BIND_STORAGE variable=a3s_acc_square type=ram_s2p impl=lutram
  static ap_int<64> a3s_acc_raw_sum[MET_ACTIVE_CHANNELS];
#pragma HLS BIND_STORAGE variable=a3s_acc_raw_sum type=ram_s2p impl=lutram
  static ap_uint<96> a3s_acc_raw_square[MET_ACTIVE_CHANNELS];
#pragma HLS BIND_STORAGE variable=a3s_acc_raw_square type=ram_s2p impl=lutram
  static ap_uint<128> a3s_acc_vll_square[MET_VLL_PAIRS];
#pragma HLS BIND_STORAGE variable=a3s_acc_vll_square type=ram_s2p impl=lutram
  static ap_int<128> a3s_acc_power[MET_POWER_PHASES];
#pragma HLS BIND_STORAGE variable=a3s_acc_power type=ram_s2p impl=lutram
  static ap_int<64> a3s_acc_minimum[MET_ACTIVE_CHANNELS];
#pragma HLS BIND_STORAGE variable=a3s_acc_minimum type=ram_s2p impl=lutram
  static ap_int<64> a3s_acc_maximum[MET_ACTIVE_CHANNELS];
#pragma HLS BIND_STORAGE variable=a3s_acc_maximum type=ram_s2p impl=lutram
  static ap_int<128> a3s_acc_phasor_re[MET_ACTIVE_CHANNELS];
#pragma HLS BIND_STORAGE variable=a3s_acc_phasor_re type=ram_s2p impl=lutram
  static ap_int<128> a3s_acc_phasor_im[MET_ACTIVE_CHANNELS];
#pragma HLS BIND_STORAGE variable=a3s_acc_phasor_im type=ram_s2p impl=lutram

  // ---- One tier per invocation (A1 latency fix) -------------------------
  // A block close and an interval close used to happen in the SAME
  // invocation: two finalizes plus eight records, 22,935 clocks worst
  // case against the 6,684 of the engine this replaced. That is 74x
  // inside the 1.67 M clocks between result beats at 60 Hz, so it was
  // never a product risk -- but the whole-chain stream bench feeds
  // samples far faster than real time, the single-cycle shim's 8-deep
  // FIFO overflowed, and the dropped beat surfaced as a spurious
  // first-after-gap mark on the third block. Deferring the interval to
  // the NEXT invocation restores the pipelining the two engines had for
  // free, and keeps the finalize at ONE call site.
  single_cycle_result_t cycle;
  // Only the shim-appended CONTEXT pass 0 needs for record words 56..63 is
  // hoisted, not the whole beat: hoisting all 7392 bits out of the
  // conditional cost ~7.4k FF (measured), where these seven words cost 224.
  ap_uint<32> ctx_freq_status = 0, ctx_freq_period = 0, ctx_freq_seq = 0;
  ap_uint<32> ctx_cap_frames = 0, ctx_cap_hdrerr = 0, ctx_cap_overflow = 0,
              ctx_cap_alerts = 0;
  ap_uint<8> result_mask = 0;
  ap_uint<32> count_now = 0;
  ap_uint<2> pass_armed = 0;             // bit 0 block, bit 1 interval

  if (interval_pending == 1) {
    // Deferred interval pass: consume NO beat this invocation. The
    // interval accumulators are static and nothing touches them until the
    // next block closes, so they are stable across the gap.
    interval_pending = 0;
    pass_armed = 2;
  } else {
    if (s_result.empty()) {
      return;
    }
    const agg_input_beat_t beat = s_result.read();
    ctx_freq_status =
        beat.range(AGG_IN_FREQ_STATUS_LSB + 31, AGG_IN_FREQ_STATUS_LSB);
    ctx_freq_period =
        beat.range(AGG_IN_FREQ_PERIOD_LSB + 31, AGG_IN_FREQ_PERIOD_LSB);
    ctx_freq_seq = beat.range(AGG_IN_FREQ_SEQ_LSB + 31, AGG_IN_FREQ_SEQ_LSB);
    ctx_cap_frames =
        beat.range(AGG_IN_CAP_FRAMES_LSB + 31, AGG_IN_CAP_FRAMES_LSB);
    ctx_cap_hdrerr =
        beat.range(AGG_IN_CAP_HDRERR_LSB + 31, AGG_IN_CAP_HDRERR_LSB);
    ctx_cap_overflow =
        beat.range(AGG_IN_CAP_OVERFLOW_LSB + 31, AGG_IN_CAP_OVERFLOW_LSB);
    ctx_cap_alerts =
        beat.range(AGG_IN_CAP_ALERTS_LSB + 31, AGG_IN_CAP_ALERTS_LSB);

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

    cycle = unpack_single_cycle_result(
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

    // ---- Shared finalize: ONE call site, up to two passes ----------------
    // pass 0 closes the 10/12-cycle block, pass 1 the 150/180-cycle
    // interval. Both tiers finalize through the SAME instance because there
    // is only one textual call, whatever the inliner decides. The pass's
    // accumulator set is selected by a ROLLED copy below rather than a
    // parallel mux across ten 896-bit arrays: one 128-bit 2:1 mux per array
    // instead of seven, ~1.3k LUT of selection instead of ~9k.
    //
    // Pass 1 is armed from inside pass 0, because the interval tier can only
    // know it has 15 blocks after the block result exists. The eligibility
    // returns inside the merge therefore end the invocation with the basic
    // quad already emitted, which is exactly the old two-engine behaviour.
    result_mask =
        (active_valid_mask & block_mask) & ap_uint<8>(0x7F);
    count_now = block_sample_count;
    sequence += 1;
    pass_armed = 1;
  }


  ap_int<128>  fin_sum[MET_ACTIVE_CHANNELS];
  ap_uint<128> fin_square[MET_ACTIVE_CHANNELS];
  ap_int<64>   fin_raw_sum[MET_ACTIVE_CHANNELS];
  ap_uint<96>  fin_raw_square[MET_ACTIVE_CHANNELS];
  ap_int<64>   fin_minimum[MET_ACTIVE_CHANNELS];
  ap_int<64>   fin_maximum[MET_ACTIVE_CHANNELS];
  ap_uint<128> fin_vll_square[MET_VLL_PAIRS];
  ap_int<128>  fin_power[MET_POWER_PHASES];
  ap_int<128>  fin_phasor_re[MET_ACTIVE_CHANNELS];
  ap_int<128>  fin_phasor_im[MET_ACTIVE_CHANNELS];
  met_finalize_out_t fin_out;
  // Set by the interval merge in pass 0, read by its emitter in pass 1 --
  // and since A1 deferred the interval pass to the NEXT invocation, this
  // MUST be static or it re-initialises to 0 in between. It read 0 in
  // every aggregate record's MTR2_LAST_BASIC_SEQ_WORD until the
  // differential harness caught it.
  static ap_uint<32> a3s_agg_last_seq = 0;

finalize_passes:
  for (int pass = 0; pass < 2; ++pass) {
#pragma HLS PIPELINE off
    if (pass_armed.bit(pass) == 0) {
      continue;
    }
    ap_uint<32> fin_count;
    ap_uint<1>  fin_dc;
    ap_uint<8>  fin_mask;
    ap_uint<1>  fin_ovf;
    if (pass == 0) {
      fin_count = count_now;
      fin_dc = active_dc_remove;
      fin_mask = result_mask;
      fin_ovf = arithmetic_overflow;
    } else {
      fin_count = a3s_agg_total_samples;
      fin_dc = a3s_agg_dc_remove;
      fin_mask = a3s_mask_and & ap_uint<8>(0x7F);
      fin_ovf = a3s_arithmetic_flag;
    }
  fin_select_lanes:
    for (int i = 0; i < MET_ACTIVE_CHANNELS; ++i) {
#pragma HLS PIPELINE off
      fin_sum[i]        = (pass == 0) ? acc_sum[i]        : a3s_acc_sum[i];
      fin_square[i]     = (pass == 0) ? acc_square[i]     : a3s_acc_square[i];
      fin_raw_sum[i]    = (pass == 0) ? acc_raw_sum[i]    : a3s_acc_raw_sum[i];
      fin_raw_square[i] = (pass == 0) ? acc_raw_square[i] : a3s_acc_raw_square[i];
      fin_minimum[i]    = (pass == 0) ? acc_minimum[i]    : a3s_acc_minimum[i];
      fin_maximum[i]    = (pass == 0) ? acc_maximum[i]    : a3s_acc_maximum[i];
      fin_phasor_re[i]  = (pass == 0) ? acc_phasor_re[i]  : a3s_acc_phasor_re[i];
      fin_phasor_im[i]  = (pass == 0) ? acc_phasor_im[i]  : a3s_acc_phasor_im[i];
    }
  fin_select_pairs:
    for (int p = 0; p < MET_VLL_PAIRS; ++p) {
#pragma HLS PIPELINE off
      fin_vll_square[p] =
          (pass == 0) ? acc_vll_square[p] : a3s_acc_vll_square[p];
    }
  fin_select_power:
    for (int p = 0; p < MET_POWER_PHASES; ++p) {
#pragma HLS PIPELINE off
      fin_power[p] = (pass == 0) ? acc_power[p] : a3s_acc_power[p];
    }

    met_finalize_interval(fin_sum, fin_square, fin_raw_sum, fin_raw_square,
                          fin_minimum, fin_maximum, fin_vll_square, fin_power,
                          fin_phasor_re, fin_phasor_im, fin_count, fin_dc,
                          fin_mask, fin_out, fin_ovf);

    // The finalize ORs into the flag it is given, so seed-and-write-back
    // keeps each tier's sticky arithmetic bit exactly as it was.
    if (pass == 0) {
      arithmetic_overflow = fin_ovf;
    } else {
      a3s_arithmetic_flag = fin_ovf;
    }

    if (pass == 0) {

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
        const ap_int<64> mean_units = fin_out.mean_q16[lane] >> 16;  // arithmetic
        const ap_uint<64> rms_units = fin_out.rms_q16[lane] >> 16;
        const int base = MTR1_CH_BASE_WORD + lane * MTR1_CH_STRIDE_WORDS;
        image.word[base + MTR1_CH_MEAN_LOW] =
            ap_uint<64>(mean_units).range(31, 0);
        image.word[base + MTR1_CH_MEAN_HIGH] =
            ap_uint<64>(mean_units).range(63, 32);
        image.word[base + MTR1_CH_RMS_COUNT] = fin_out.rms_count[lane];
        image.word[base + MTR1_CH_RMS_LOW] = rms_units.range(31, 0);
        image.word[base + MTR1_CH_RMS_HIGH] = rms_units.range(63, 32);
      }
    }
  record_pairs:
    for (int pair = 0; pair < MET_VLL_PAIRS; ++pair) {
  #pragma HLS PIPELINE off
      image.word[BASIC_VLL_BASE_WORD + pair] =
          ap_uint<64>(fin_out.vll_rms[pair] >> 16).range(31, 0);
    }
    image.word[MTR1_FREQUENCY_VALUE_WORD] = cycle.frequency_millihz;
    image.word[MTR1_FREQUENCY_STATUS_WORD] =
        ctx_freq_status;
    image.word[MTR1_FREQUENCY_PERIOD_WORD] =
        ctx_freq_period;
    image.word[MTR1_FREQUENCY_SEQUENCE_WORD] =
        ctx_freq_seq;
    image.word[MTR1_CAPTURE_FRAMES_WORD] =
        ctx_cap_frames;
    image.word[MTR1_HEADER_ERRORS_WORD] =
        ctx_cap_hdrerr;
    image.word[MTR1_FIFO_OVERFLOWS_WORD] =
        ctx_cap_overflow;
    image.word[MTR1_ADC_ALERTS_WORD] =
        ctx_cap_alerts;

    serialize_record<MREC_FORMAT_BASIC_V4>(image, m_basic);

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
    fill_power_payload(fin_out, power_image);
    serialize_record<MREC_FORMAT_POWER_V1>(power_image, m_basic);

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
    fill_phasor_payload(fin_out, phasor_image);
    serialize_record<MREC_FORMAT_PHASOR_V2>(phasor_image, m_basic);

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
    fill_unbal_payload(fin_out, unbal_image);
    serialize_record<MREC_FORMAT_UNBAL_V2>(unbal_image, m_basic);

    // ==== 150/180-cycle (3 s) interval tier ================================
    // Was Agg150_180CycleEngine. Its input is no longer an AXIS beat: the
    // block result is the local `result` built above, so the 7072-bit
    // inter-tier interface, its FIFO, and its shim are gone. Every rule
    // below is the retired engine's verbatim, statics prefixed a3s_ to
    // share one scope with the block tier.
    // A configuration APPLY between beats terminates any partially
    // accumulated aggregate before this beat is considered (Mtr2 rule).
    if (result.apply_toggle != a3s_apply_seen) {
      a3s_apply_seen = result.apply_toggle;
      if (a3s_blocks_accumulated != 0) {
        a3s_reset_count += 1;
      }
      a3s_blocks_accumulated = 0;
    }

    // Eligibility: identical predicate to the retired Mtr2 engine and the
    // APU's class_a_aggregation_eligible() rule.
    const bool a3s_nominal_known = (result.nominal_hz == 50) || (result.nominal_hz == 60);
    const bool a3s_input_eligible =
        result.flags.bit(MET_FLAG_LOCKED) == 1 &&
        result.flags.bit(MET_FLAG_FALLBACK) == 0 &&
        result.flags.bit(MET_FLAG_FIRST_BLOCK) == 0 && a3s_nominal_known &&
        result.cycle_count == met_expected_cycles(result.nominal_hz);

    if (!a3s_input_eligible) {
      // An ineligible block invalidates the running aggregate and never
      // seeds a new one: the 150/180-cycle interval must stay contiguous.
      a3s_ineligible_count += 1;
      if (a3s_blocks_accumulated != 0) {
        a3s_reset_count += 1;
      }
      a3s_blocks_accumulated = 0;
      return;
    }

    bool a3s_seed = (a3s_blocks_accumulated == 0);
    if (!a3s_seed) {
      if (result.generation != a3s_agg_generation || result.nominal_hz != a3s_agg_nominal ||
          result.sample_rate_hz != a3s_agg_sample_rate ||
          result.dc_remove != a3s_agg_dc_remove) {
        // Generation, nominal, sample-rate, or dc_remove change: discard
        // the partial aggregate; this block seeds the next one.
        a3s_reset_count += 1;
        a3s_seed = true;
      } else if (result.sequence != a3s_expected_next_seq ||
                 result.first_sample != a3s_expected_next_first) {
        // Lost/reordered block or a sample-domain discontinuity: the 15
        // inputs would not describe one contiguous interval.
        a3s_continuity_count += 1;
        a3s_reset_count += 1;
        a3s_seed = true;
      }
    }

    if (a3s_seed) {
      a3s_agg_generation = result.generation;
      a3s_agg_nominal = result.nominal_hz;
      a3s_agg_sample_rate = result.sample_rate_hz;
      a3s_agg_dc_remove = result.dc_remove;
      a3s_agg_first_sample = result.first_sample;
      a3s_agg_first_seq = result.sequence;
      a3s_agg_total_samples = result.sample_count;
      a3s_agg_total_cycles = result.cycle_count;
      a3s_mask_and = result.valid_mask;
      a3s_freq_sum = result.frequency_millihz;
      a3s_freq_all_valid = result.frequency_valid;
      a3s_arithmetic_flag = result.status.bit(MREC_STATUS_ARITHMETIC_BIT);
      a3s_phasor_invalid_or = result.status.bit(PHASOR_STATUS_INVALID_BIT);
      a3s_blocks_accumulated = 1;
    } else {
      a3s_agg_total_samples += result.sample_count;
      a3s_agg_total_cycles += result.cycle_count;
      a3s_mask_and &= result.valid_mask;
      a3s_freq_sum += result.frequency_millihz;
      a3s_freq_all_valid &= result.frequency_valid;
      a3s_arithmetic_flag |= result.status.bit(MREC_STATUS_ARITHMETIC_BIT);
      a3s_phasor_invalid_or |= result.status.bit(PHASOR_STATUS_INVALID_BIT);
      a3s_blocks_accumulated += 1;
    }
    a3s_agg_last_sample = result.last_sample;
      a3s_agg_last_seq = result.sequence;
    a3s_expected_next_seq = result.sequence + 1;
    a3s_expected_next_first = result.first_sample + result.sample_count;

    const bool a3s_first_block_fold = a3s_seed;
  a3s_merge_lanes:
    for (int lane = 0; lane < MET_ACTIVE_CHANNELS; ++lane) {
  #pragma HLS PIPELINE off
      const ap_int<128> sum_base =
          a3s_first_block_fold ? ap_int<128>(0) : a3s_acc_sum[lane];
      a3s_acc_sum[lane] = sum_base + result.sum[lane];
      const ap_uint<128> square_base =
          a3s_first_block_fold ? ap_uint<128>(0) : a3s_acc_square[lane];
      a3s_acc_square[lane] = met_add_square_saturating<128>(
          square_base, result.square[lane], a3s_arithmetic_flag);
      const ap_int<64> raw_sum_base =
          a3s_first_block_fold ? ap_int<64>(0) : a3s_acc_raw_sum[lane];
      a3s_acc_raw_sum[lane] = raw_sum_base + result.raw_sum[lane];
      const ap_uint<96> raw_square_base =
          a3s_first_block_fold ? ap_uint<96>(0) : a3s_acc_raw_square[lane];
      a3s_acc_raw_square[lane] = raw_square_base + result.raw_square[lane];
      if (a3s_first_block_fold || result.minimum[lane] < a3s_acc_minimum[lane]) {
        a3s_acc_minimum[lane] = result.minimum[lane];
      }
      if (a3s_first_block_fold || result.maximum[lane] > a3s_acc_maximum[lane]) {
        a3s_acc_maximum[lane] = result.maximum[lane];
      }
    }
  a3s_merge_power:
    for (int phase = 0; phase < MET_POWER_PHASES; ++phase) {
  #pragma HLS PIPELINE off
      const ap_int<128> power_base =
          a3s_first_block_fold ? ap_int<128>(0) : a3s_acc_power[phase];
      a3s_acc_power[phase] = met_add_signed_saturating<128>(
          power_base, result.power_sum[phase], a3s_arithmetic_flag);
    }
  a3s_merge_pairs:
    for (int pair = 0; pair < MET_VLL_PAIRS; ++pair) {
  #pragma HLS PIPELINE off
      const ap_uint<128> vll_base =
          a3s_first_block_fold ? ap_uint<128>(0) : a3s_acc_vll_square[pair];
      a3s_acc_vll_square[pair] = met_add_square_saturating<128>(
          vll_base, result.vll_square[pair], a3s_arithmetic_flag);
    }
  a3s_merge_phasor:
    for (int lane = 0; lane < MET_ACTIVE_CHANNELS; ++lane) {
  #pragma HLS PIPELINE off
      const ap_int<128> re_base =
          a3s_first_block_fold ? ap_int<128>(0) : a3s_acc_phasor_re[lane];
      a3s_acc_phasor_re[lane] = met_add_signed_saturating<128>(
          re_base, result.phasor_re[lane], a3s_arithmetic_flag);
      const ap_int<128> im_base =
          a3s_first_block_fold ? ap_int<128>(0) : a3s_acc_phasor_im[lane];
      a3s_acc_phasor_im[lane] = met_add_signed_saturating<128>(
          im_base, result.phasor_im[lane], a3s_arithmetic_flag);
    }

    if (a3s_blocks_accumulated != MET_BASIC_BLOCKS_PER_AGGREGATE) {
      return;
    }

    // Fifteenth eligible block: finalize the whole interval (the SHARED
    // arithmetic — one definition for both tiers) and emit the record quad.
      // Arming pass 1: reaching here means the merge accepted this block
      // and it was the fifteenth, so the interval closes on this beat too.
      // Do not run pass 1 now -- defer it to the next invocation.
      interval_pending = 1;
    } else {
      // Derived from the interval statics the merge just updated; these
      // used to sit immediately above the second finalize call.
      const ap_uint<8> a3s_result_mask = a3s_mask_and & ap_uint<8>(0x7F);
      const ap_uint<32> a3s_count_now = a3s_agg_total_samples;
      (void)a3s_result_mask;
    const ap_uint<36> a3s_freq_mean =
        floor_div_const<36, MET_BASIC_BLOCKS_PER_AGGREGATE>(a3s_freq_sum);

    a3s_out_sequence += 1;
    a3s_blocks_accumulated = 0;

    const ap_uint<32> a3s_shape_word =
        (ap_uint<32>(MET_BASIC_BLOCKS_PER_AGGREGATE) << MTR2_SHAPE_BLOCKS_LSB) |
        (ap_uint<32>(a3s_agg_nominal) << MTR2_SHAPE_NOMINAL_LSB) |
        (ap_uint<32>(a3s_agg_total_cycles) << MTR2_SHAPE_CYCLES_LSB);

    // ---- AGG-v3: the aggregate fundamental record (MTR2 interior + the
    // ---- documented additions; a3s_status keeps the MTR2 bit semantics). ----
    record_image_t a3s_image;
    clear_record(a3s_image);
    const ap_uint<32> agg_status =
        (ap_uint<32>(a3s_arithmetic_flag) << MREC_STATUS_ARITHMETIC_BIT) |
        (ap_uint<32>(1) << MTR2_STATUS_COMPLETE_BIT) |
        (ap_uint<32>(a3s_freq_all_valid) << MTR2_STATUS_FREQUENCY_BIT);
    fill_envelope(a3s_image, a3s_out_sequence, a3s_agg_generation, a3s_agg_sample_rate,
                  a3s_count_now, a3s_result_mask, agg_status, a3s_agg_first_sample);
    a3s_image.word[MTR2_SHAPE_WORD] = a3s_shape_word;
    a3s_image.word[MTR2_FIRST_BASIC_SEQ_WORD] = a3s_agg_first_seq;
    a3s_image.word[MTR2_LAST_BASIC_SEQ_WORD] = a3s_agg_last_seq;
  agg_record_lanes:
    for (int lane = 0; lane < MET_CHANNEL_LANES; ++lane) {
  #pragma HLS PIPELINE off
      if (lane < MET_ACTIVE_CHANNELS) {
        const ap_uint<64> rms_units = fin_out.rms_q16[lane] >> 16;
        const int base = MTR2_CH_BASE_WORD + lane * MTR2_CH_STRIDE_WORDS;
        a3s_image.word[base + 0] = rms_units.range(31, 0);
        a3s_image.word[base + 1] = rms_units.range(63, 32);
      }
    }
    a3s_image.word[MTR2_FREQUENCY_WORD] =
        (a3s_freq_all_valid == 1) ? ap_uint<32>(a3s_freq_mean.range(31, 0))
                              : ap_uint<32>(0);
    a3s_image.word[MTR2_RESET_COUNT_WORD] = a3s_reset_count;
    a3s_image.word[MTR2_INELIGIBLE_COUNT_WORD] = a3s_ineligible_count;
    a3s_image.word[MTR2_CONTINUITY_COUNT_WORD] = a3s_continuity_count;
    a3s_image.word[AGG_LAST_SAMPLE_LOW_WORD] = a3s_agg_last_sample.range(31, 0);
    a3s_image.word[AGG_LAST_SAMPLE_HIGH_WORD] = a3s_agg_last_sample.range(63, 32);
  agg_record_pairs:
    for (int pair = 0; pair < MET_VLL_PAIRS; ++pair) {
  #pragma HLS PIPELINE off
      a3s_image.word[AGG_VLL_BASE_WORD + pair] =
          ap_uint<64>(fin_out.vll_rms[pair] >> 16).range(31, 0);
    }
    serialize_record<MREC_FORMAT_AGG_V3>(a3s_image, m_agg);

    // Sibling a3s_status: common arithmetic bit, plus phasor-invalid (bit 1)
    // on the phasor-domain records — the basic-period siblings' semantics.
    const ap_uint<32> sibling_status =
        ap_uint<32>(a3s_arithmetic_flag) << MREC_STATUS_ARITHMETIC_BIT;
    const ap_uint<32> a3s_phasor_status =
        sibling_status |
        (ap_uint<32>(a3s_phasor_invalid_or) << PHASOR_STATUS_INVALID_BIT);

    // ---- AGG-POWER: payload map identical to POWER-v1. ------------------
    record_image_t a3s_power_image;
    clear_record(a3s_power_image);
    fill_envelope(a3s_power_image, a3s_out_sequence, a3s_agg_generation, a3s_agg_sample_rate,
                  a3s_count_now, a3s_result_mask, sibling_status, a3s_agg_first_sample);
    a3s_power_image.word[MTR2_SHAPE_WORD] = a3s_shape_word;
    a3s_power_image.word[MTR2_FIRST_BASIC_SEQ_WORD] = a3s_agg_first_seq;
    a3s_power_image.word[MTR2_LAST_BASIC_SEQ_WORD] = a3s_agg_last_seq;
    fill_power_payload(fin_out, a3s_power_image);
    serialize_record<MREC_FORMAT_AGG_POWER_V1>(a3s_power_image, m_agg);

    // ---- AGG-PHASOR: payload map identical to PHASOR-v1. ----------------
    record_image_t a3s_phasor_image;
    clear_record(a3s_phasor_image);
    fill_envelope(a3s_phasor_image, a3s_out_sequence, a3s_agg_generation, a3s_agg_sample_rate,
                  a3s_count_now, a3s_result_mask, a3s_phasor_status, a3s_agg_first_sample);
    a3s_phasor_image.word[MTR2_SHAPE_WORD] = a3s_shape_word;
    a3s_phasor_image.word[MTR2_FIRST_BASIC_SEQ_WORD] = a3s_agg_first_seq;
    a3s_phasor_image.word[MTR2_LAST_BASIC_SEQ_WORD] = a3s_agg_last_seq;
    fill_phasor_payload(fin_out, a3s_phasor_image);
    serialize_record<MREC_FORMAT_AGG_PHASOR_V2>(a3s_phasor_image, m_agg);

    // ---- AGG-UNBAL: payload map identical to UNBAL-v1. ------------------
    record_image_t a3s_unbal_image;
    clear_record(a3s_unbal_image);
    fill_envelope(a3s_unbal_image, a3s_out_sequence, a3s_agg_generation, a3s_agg_sample_rate,
                  a3s_count_now, a3s_result_mask, a3s_phasor_status, a3s_agg_first_sample);
    a3s_unbal_image.word[MTR2_SHAPE_WORD] = a3s_shape_word;
    a3s_unbal_image.word[MTR2_FIRST_BASIC_SEQ_WORD] = a3s_agg_first_seq;
    a3s_unbal_image.word[MTR2_LAST_BASIC_SEQ_WORD] = a3s_agg_last_seq;
    fill_unbal_payload(fin_out, a3s_unbal_image);
    serialize_record<MREC_FORMAT_AGG_UNBAL_V2>(a3s_unbal_image, m_agg);
    }
  }
}
