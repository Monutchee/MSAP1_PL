#include "single_cycle_engine.hpp"

#include "metrology_stats.hpp"
#include "phasor_core.hpp"
#include "power_core.hpp"
#include "statistics_core.hpp"

// Free-running single-shot process (the CycleAggregator pattern shared by
// every packaged engine): one invocation consumes at most one sample
// beat; the invocation carrying a cycle close runs the finalize and both
// emissions inline. StatisticsCore (statistics_core.hpp) accumulates on
// every accepted frame; the finalize computes the diagnostic RMS words
// with the shared met_rms_from_accumulators recurrence.
void hls_single_cycle_engine(hls::stream<single_cycle_sample_word_t> &s_sample,
                             hls::stream<record_axis_t> &m_axis,
                             hls::stream<single_cycle_word_t> &m_result) {
#pragma HLS INTERFACE mode=axis port=s_sample register_mode=off
#pragma HLS INTERFACE mode=axis port=m_result register_mode=both
#pragma HLS INTERFACE mode=axis port=m_axis
#pragma HLS INTERFACE mode=ap_ctrl_none port=return

  // Committed configuration and window state; syn.rtl.reset=state
  // re-zeroes these on aresetn exactly like the sibling engines.
  static ap_uint<1> apply_seen = 0;
  static ap_uint<32> active_generation = 0;
  static ap_uint<32> active_sample_rate = 32000;
  static ap_uint<8> active_valid_mask = 0;
  static ap_uint<1> active_enable = 0;
  static ap_uint<1> active_dc_remove = 1;
  static ap_uint<32> sample_count = 0;
  static ap_uint<64> window_first_sample = 0;
  static ap_uint<32> sequence = 0;  // first emitted result carries 1
  // Narrow input-packet assembler.  Consume one 32-bit word per top-level
  // invocation instead of asking HLS to schedule 32 blocking reads in one
  // control step.  All words are overwritten before packet_assembly is used,
  // so the wide datapath deliberately needs no reset mux; packet_word_index is
  // the only state that establishes validity after reset.
  static single_cycle_sample_beat_t packet_assembly = 0;
#pragma HLS reset variable=packet_assembly off
  static ap_uint<6> packet_word_index = 0;
  // Validity/generation contract (handover: no result may span a
  // discontinuity; the first result after one is marked). await_close
  // discards frames until a cycle boundary passes, so accumulation only
  // ever starts at a true cycle start -- partial windows after reset,
  // APPLY, malformed input, dropped beats, or timing loss are suppressed
  // rather than emitted. disc_* latch the pending mark and its causes
  // until the next emitted result carries them.
  static ap_uint<1> await_close = 1;
  static ap_uint<1> disc_pending = 1;  // reset: the very first result is marked
  static ap_uint<1> disc_malformed = 0;
  static ap_uint<1> disc_timing = 0;
  // In-window sample continuity: a shim FIFO drop would otherwise sum
  // across the hole silently. Tracks every accepted frame.
  static ap_uint<64> expected_sample = 0;
  static ap_uint<1> expected_valid = 0;
  // Per-cycle arithmetic flag: seeded clear with each window's first
  // frame (the seed-in-place idiom), so every clear point resets it.
  static ap_uint<1> window_overflow = 0;
  static cycle_statistics_t stats;
  static cycle_power_t power;
  static cycle_phasor_t phasor;
  // Fundamental correlation reference: theta restarts each cycle; the
  // per-sample increment and its validity latch at the cycle's first
  // frame from the MEASURED frequency (off-nominal tolerant).
  static ap_uint<32> phasor_theta = 0;
  static ap_uint<32> phasor_delta = 0;
  static ap_uint<1> phasor_valid = 0;

  if (s_sample.empty()) {
    return;
  }
  const single_cycle_sample_word_t packet_word = s_sample.read();
  // Words arrive least-significant first.  A constant right shift plus a
  // high-word insert forms the packet after 32 clocks without synthesizing a
  // 32-way dynamic part-select mux.
  single_cycle_sample_beat_t next_packet =
      packet_assembly >> SCYC_SAMPLE_PACKET_WORD_BITS;
  next_packet.range(SCYC_IN_BITS - 1,
                    SCYC_IN_BITS - SCYC_SAMPLE_PACKET_WORD_BITS) = packet_word;
  packet_assembly = next_packet;
  if (packet_word_index != SCYC_SAMPLE_PACKET_WORDS - 1) {
    packet_word_index = packet_word_index + 1;
    return;
  }

  // next_packet includes the just-read final word.  The asymmetric XPM FIFO
  // exposes a packet only after its complete 1,024-bit write has committed.
  const single_cycle_sample_beat_t beat = next_packet;
  packet_word_index = 0;

  const ap_uint<1> beat_apply = beat.bit(SCYC_IN_APPLY_BIT);
  if (beat_apply != apply_seen) {
    // APPLY commit: latch the shadow set and clear the window; the
    // carrying beat is then processed under the new configuration (the
    // stale-generation guard rejects it until its tag catches up).
    apply_seen = beat_apply;
    active_generation =
        beat.range(SCYC_IN_CFG_GEN_LSB + 31, SCYC_IN_CFG_GEN_LSB);
    active_sample_rate =
        beat.range(SCYC_IN_CFG_RATE_LSB + 31, SCYC_IN_CFG_RATE_LSB);
    active_valid_mask =
        beat.range(SCYC_IN_CFG_MASK_LSB + 7, SCYC_IN_CFG_MASK_LSB);
    active_enable = beat.bit(SCYC_IN_ENABLE_BIT);
    active_dc_remove = beat.bit(SCYC_IN_DC_REMOVE_BIT);
    sample_count = 0;
    await_close = 1;
    disc_pending = 1;
  }

  if (active_enable == 0) {
    return;
  }

  const ap_uint<32> frame_generation =
      beat.range(SCYC_IN_FRAME_GEN_LSB + 31, SCYC_IN_FRAME_GEN_LSB);
  if (beat.bit(SCYC_IN_MALFORMED_BIT) == 1) {
    sample_count = 0;
    await_close = 1;
    disc_pending = 1;
    disc_malformed = 1;
    expected_valid = 0;
    return;
  }
  // Stale tags are the expected transient while an APPLY's new generation
  // propagates down the pipe: a discontinuity, but not a malformed one.
  if (frame_generation != active_generation) {
    sample_count = 0;
    await_close = 1;
    disc_pending = 1;
    expected_valid = 0;
    return;
  }

  // No locked cycle timing, no cycle boundaries: single-cycle products
  // pause rather than free-running (the 10/12 tier's fallback window has
  // no per-cycle analogue).
  if (beat.bit(SCYC_IN_CYCLE_MODE_BIT) == 0) {
    sample_count = 0;
    await_close = 1;
    disc_pending = 1;
    disc_timing = 1;
    expected_valid = 0;
    return;
  }

  const ap_uint<64> sample_index =
      beat.range(SCYC_IN_SAMPLE_IDX_LSB + 63, SCYC_IN_SAMPLE_IDX_LSB);
  if (expected_valid == 1 && sample_index != expected_sample) {
    // Dropped beat(s): whatever accumulated would span the hole, and the
    // true cycle start may be inside it. Discard and resynchronize.
    sample_count = 0;
    await_close = 1;
    disc_pending = 1;
    disc_malformed = 1;
  }
  expected_sample = sample_index + 1;
  expected_valid = 1;

  if (await_close == 1) {
    // Discard until a boundary passes so the next window starts at a
    // true cycle start; the boundary-carrying frame belongs to the
    // discarded cycle.
    if (beat.bit(SCYC_IN_CLOSES_BIT) == 1) {
      await_close = 0;
    }
    sample_count = 0;
    return;
  }

  const bool first_frame = (sample_count == 0);
  if (first_frame) {
    window_first_sample = sample_index;
    window_overflow = 0;
    phasor_theta = 0;
    phasor_valid =
        beat.bit(SCYC_IN_FREQ_STATUS_LSB + SCYC_FREQ_STATUS_VALID_BIT);
    if (phasor_valid == 1) {
      phasor_delta = phasor_delta_q32(
          ap_uint<32>(beat.range(SCYC_IN_FREQ_MHZ_LSB + 31,
                                 SCYC_IN_FREQ_MHZ_LSB)),
          active_sample_rate);
    }
  }
  const ap_uint<32> count_now = sample_count + 1;

  // StatisticsCore accumulation on every accepted frame, closer included.
  met_q16_t q16[MET_ACTIVE_CHANNELS];
#pragma HLS ARRAY_PARTITION variable=q16 complete
  ap_int<32> raw[MET_ACTIVE_CHANNELS];
#pragma HLS ARRAY_PARTITION variable=raw complete
extract_lanes:
  for (int lane = 0; lane < MET_ACTIVE_CHANNELS; ++lane) {
#pragma HLS UNROLL
    q16[lane] = met_q16_t(ap_uint<MET_RMS_LANE_BITS>(
        beat.range(SCYC_IN_SAMPLES_LSB + lane * MET_RMS_LANE_BITS +
                       MET_RMS_LANE_BITS - 1,
                   SCYC_IN_SAMPLES_LSB + lane * MET_RMS_LANE_BITS)));
    raw[lane] = ap_int<32>(ap_uint<32>(
        beat.range(SCYC_IN_RAW_LSB + lane * 32 + 31,
                   SCYC_IN_RAW_LSB + lane * 32)));
  }
  accumulate_statistics(stats, q16, raw, first_frame, window_overflow);
  accumulate_power(power, q16, first_frame, window_overflow);
  if (phasor_valid == 1) {
    accumulate_phasor(phasor, q16, phasor_theta, first_frame,
                      window_overflow);
    phasor_theta += phasor_delta;
  }

  if (beat.bit(SCYC_IN_CLOSES_BIT) == 0) {
    sample_count = count_now;
    return;
  }
  sample_count = 0;

  // ---- Finalize this cycle inline -------------------------------------
  const ap_uint<8> result_mask =
      (active_valid_mask &
       beat.range(SCYC_IN_FRAME_MASK_LSB + 7, SCYC_IN_FRAME_MASK_LSB)) &
      ap_uint<8>(0x7F);
  sequence += 1;

  // Diagnostic one-cycle RMS (record words): the shared mean-corrected
  // recurrence per lane under the committed dc_remove, and the plain
  // difference RMS per line-line pair (its own DC belongs to the
  // difference; sum = 0 disables the correction term).
  ap_uint<64> lane_rms[MET_ACTIVE_CHANNELS];
#pragma HLS ARRAY_PARTITION variable=lane_rms complete
  ap_uint<64> vll_rms[MET_VLL_PAIRS];
#pragma HLS ARRAY_PARTITION variable=vll_rms complete
finalize_lanes:
  for (int lane = 0; lane < MET_ACTIVE_CHANNELS; ++lane) {
#pragma HLS PIPELINE off
    lane_rms[lane] = met_rms_from_accumulators<128, 128>(
        stats.square[lane], stats.sum[lane], count_now, active_dc_remove,
        window_overflow);
  }
finalize_pairs:
  for (int pair = 0; pair < MET_VLL_PAIRS; ++pair) {
#pragma HLS PIPELINE off
    vll_rms[pair] = met_rms_from_accumulators<128, 128>(
        stats.vll_square[pair], ap_int<128>(0), count_now, ap_uint<1>(0),
        window_overflow);
  }
  // Diagnostic active power: signed floor mean of the Q32 product sum
  // (full width, no truncation), then >> 32 to picowatts. Real values
  // stay far inside 64 bits; contract-max inputs are already flagged.
  ap_int<64> phase_power_pw[MET_POWER_PHASES];
#pragma HLS ARRAY_PARTITION variable=phase_power_pw complete
finalize_power:
  for (int phase = 0; phase < MET_POWER_PHASES; ++phase) {
#pragma HLS PIPELINE off
    const ap_int<128> mean_q32 =
        met_floor_mean_signed<128, 128>(power.power_sum[phase], count_now);
    phase_power_pw[phase] = ap_int<64>((mean_q32 >> 32).range(63, 0));
  }
  // Diagnostic fundamental RMS per lane; zero (and status bit 1) when
  // the frequency reference was unusable at cycle start.
  ap_uint<64> fund_rms[MET_ACTIVE_CHANNELS];
#pragma HLS ARRAY_PARTITION variable=fund_rms complete
finalize_fundamental:
  for (int lane = 0; lane < MET_ACTIVE_CHANNELS; ++lane) {
#pragma HLS PIPELINE off
    fund_rms[lane] =
        (phasor_valid == 1)
            ? phasor_fundamental_rms(phasor.re_sum[lane],
                                     phasor.im_sum[lane], count_now)
            : ap_uint<64>(0);
  }
  const ap_uint<32> status =
      (ap_uint<32>(window_overflow) << SCYC_STATUS_OVERFLOW_BIT) |
      (ap_uint<32>(phasor_valid == 0 ? 1 : 0)
       << SCYC_STATUS_PHASOR_INVALID_BIT) |
      (ap_uint<32>(disc_pending) << SCYC_STATUS_FIRST_AFTER_GAP_BIT) |
      (ap_uint<32>(disc_malformed) << SCYC_STATUS_GAP_MALFORMED_BIT) |
      (ap_uint<32>(disc_timing) << SCYC_STATUS_GAP_TIMING_BIT);
  disc_pending = 0;
  disc_malformed = 0;
  disc_timing = 0;

  single_cycle_result_t result;
  result.sequence = sequence;
  result.generation = active_generation;
  result.first_sample = window_first_sample;
  result.last_sample = sample_index;
  result.sample_count = count_now;
  result.cycle_sequence =
      beat.range(SCYC_IN_CYCLE_SEQ_LSB + 31, SCYC_IN_CYCLE_SEQ_LSB);
  result.nominal_hz =
      beat.range(SCYC_IN_NOMINAL_LSB + 7, SCYC_IN_NOMINAL_LSB);
  result.valid_mask = result_mask;
  result.flags =
      beat.range(SCYC_IN_FLAGS_LSB + MET_FLAG_BITS - 1, SCYC_IN_FLAGS_LSB);
  result.status = status;
  result.frequency_millihz =
      beat.range(SCYC_IN_FREQ_MHZ_LSB + 31, SCYC_IN_FREQ_MHZ_LSB);
  result.frequency_valid =
      beat.bit(SCYC_IN_FREQ_STATUS_LSB + SCYC_FREQ_STATUS_VALID_BIT);
  result.apply_toggle = apply_seen;
  result.processing_tick =
      beat.range(SCYC_IN_PL_TICK_LSB + 63, SCYC_IN_PL_TICK_LSB);
  export_statistics(stats, result);
  export_power(power, result);
  if (phasor_valid == 1) {
    export_phasor(phasor, result);
  } else {
zero_phasor:
    for (int lane = 0; lane < MET_ACTIVE_CHANNELS; ++lane) {
#pragma HLS UNROLL
      result.phasor_re[lane] = 0;
      result.phasor_im[lane] = 0;
    }
  }
  write_single_cycle_packet(result, m_result);

  // SCYC-v5 diagnostic record.
  record_image_t image;
  clear_record(image);
  fill_envelope(image, sequence, active_generation, active_sample_rate,
                count_now, result_mask, status, window_first_sample);
  image.word[SCYC_TIMING_WORD] =
      ap_uint<32>(result.nominal_hz) | (ap_uint<32>(1) << 8) |
      (ap_uint<32>(result.flags) << 16);
  image.word[SCYC_CYCLE_SEQ_WORD] = result.cycle_sequence;
  image.word[SCYC_LAST_SAMPLE_LOW_WORD] = sample_index.range(31, 0);
  image.word[SCYC_LAST_SAMPLE_HIGH_WORD] = sample_index.range(63, 32);
  image.word[SCYC_PROC_TICK_LOW_WORD] = result.processing_tick.range(31, 0);
  image.word[SCYC_PROC_TICK_HIGH_WORD] = result.processing_tick.range(63, 32);
  image.word[SCYC_FREQ_VALUE_WORD] = result.frequency_millihz;
  image.word[SCYC_FREQ_STATUS_WORD] =
      beat.range(SCYC_IN_FREQ_STATUS_LSB + 31, SCYC_IN_FREQ_STATUS_LSB);
record_lanes:
  for (int lane = 0; lane < MET_ACTIVE_CHANNELS; ++lane) {
#pragma HLS PIPELINE off
    const ap_uint<64> rms_units = lane_rms[lane] >> 16;  // micro-units
    const int base = SCYC_CH_BASE_WORD + lane * SCYC_CH_STRIDE_WORDS;
    image.word[base] = rms_units.range(31, 0);
    image.word[base + 1] = rms_units.range(63, 32);
  }
record_pairs:
  for (int pair = 0; pair < MET_VLL_PAIRS; ++pair) {
#pragma HLS PIPELINE off
    const ap_uint<64> rms_units = vll_rms[pair] >> 16;
    const int base = SCYC_VLL_BASE_WORD + pair * SCYC_CH_STRIDE_WORDS;
    image.word[base] = rms_units.range(31, 0);
    image.word[base + 1] = rms_units.range(63, 32);
  }
record_power:
  for (int phase = 0; phase < MET_POWER_PHASES; ++phase) {
#pragma HLS PIPELINE off
    const ap_uint<64> raw_bits = ap_uint<64>(phase_power_pw[phase]);
    const int base = SCYC_POWER_BASE_WORD + phase * SCYC_CH_STRIDE_WORDS;
    image.word[base] = raw_bits.range(31, 0);
    image.word[base + 1] = raw_bits.range(63, 32);
  }
record_fundamental:
  for (int lane = 0; lane < MET_ACTIVE_CHANNELS; ++lane) {
#pragma HLS PIPELINE off
    const ap_uint<64> rms_units = fund_rms[lane] >> 16;  // micro-units
    const int base = SCYC_FUND_BASE_WORD + lane * SCYC_CH_STRIDE_WORDS;
    image.word[base] = rms_units.range(31, 0);
    image.word[base + 1] = rms_units.range(63, 32);
  }

  serialize_record<MREC_FORMAT_SCYC_V5>(image, m_axis);
}
