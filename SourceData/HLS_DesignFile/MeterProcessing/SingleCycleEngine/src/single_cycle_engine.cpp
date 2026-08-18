#include "single_cycle_engine.hpp"

// Free-running single-shot process (the CycleAggregator pattern shared by
// every packaged engine): one invocation consumes at most one sample
// beat; the invocation carrying a cycle close runs the finalize and both
// emissions inline. Finalization is a provenance copy in M2 — the
// statistics merge arrives with M3 and reuses metrology_stats.hpp.
void hls_single_cycle_engine(hls::stream<single_cycle_sample_beat_t> &s_sample,
                             hls::stream<record_axis_t> &m_axis,
                             hls::stream<single_cycle_beat_t> &m_result) {
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
  static ap_uint<32> sample_count = 0;
  static ap_uint<64> window_first_sample = 0;
  static ap_uint<32> sequence = 0;  // first emitted result carries 1

  if (s_sample.empty()) {
    return;
  }
  const single_cycle_sample_beat_t beat = s_sample.read();

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
    sample_count = 0;
  }

  if (active_enable == 0) {
    return;
  }

  const ap_uint<32> frame_generation =
      beat.range(SCYC_IN_FRAME_GEN_LSB + 31, SCYC_IN_FRAME_GEN_LSB);
  if (beat.bit(SCYC_IN_MALFORMED_BIT) == 1 ||
      frame_generation != active_generation) {
    sample_count = 0;
    return;
  }

  // No locked cycle timing, no cycle boundaries: single-cycle products
  // pause rather than free-running (the 10/12 tier's fallback window has
  // no per-cycle analogue).
  if (beat.bit(SCYC_IN_CYCLE_MODE_BIT) == 0) {
    sample_count = 0;
    return;
  }

  const ap_uint<64> sample_index =
      beat.range(SCYC_IN_SAMPLE_IDX_LSB + 63, SCYC_IN_SAMPLE_IDX_LSB);
  if (sample_count == 0) {
    window_first_sample = sample_index;
  }
  const ap_uint<32> count_now = sample_count + 1;

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
  const ap_uint<32> status = 0;  // arithmetic arrives with M3
  sequence += 1;

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
  m_result.write(pack_single_cycle_result(result));

  // SCYC-v1 diagnostic record.
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

  serialize_record<MREC_FORMAT_SCYC_V1>(image, m_axis);
}
