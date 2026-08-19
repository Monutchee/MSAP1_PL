#include "agg10_12_cycle_engine.hpp"

#include "metrology_math.hpp"
#include "metrology_stats.hpp"

// 10/12-cycle basic measurement engine. Contract, beat layout, and block
// rules: see agg10_12_cycle_engine.hpp.
//
// Structure: one free-running single-shot process (the house pattern):
// each invocation consumes at most one result beat; the invocation
// closing a block runs the whole finalize + both emissions inline. Input
// cadence is one beat per grid cycle (~16-20 ms), four orders of
// magnitude slower than the sample-domain engines, so the brief finalize
// backpressure is absorbed by the AXIS register slices upstream.
//
// Arithmetic is shaped for area (rolled per-lane loops, PIPELINE off):
// the wide adders and the divider/root pipeline exist once each.

namespace {

// One lane's finalized results — the retired Mtr1 CALC_* sequence.
struct lane_result_t {
  ap_int<64> mean_q16;
  ap_uint<64> rms_q16;
  ap_uint<32> rms_count;
  ap_uint<1> overflow;
};

lane_result_t finalize_lane(const ap_int<128> sum, const ap_uint<128> square,
                            const ap_int<64> raw_sum,
                            const ap_uint<96> raw_square,
                            const ap_uint<32> count,
                            const ap_uint<1> dc_remove) {
#pragma HLS INLINE off
  lane_result_t r;
  r.overflow = 0;
  r.mean_q16 = met_floor_mean_signed<128, 64>(sum, count);
  r.rms_q16 = met_rms_from_accumulators<128, 128>(square, sum, count,
                                                  dc_remove, r.overflow);
  const ap_uint<64> raw_root = met_rms_from_accumulators<96, 64>(
      raw_square, raw_sum, count, dc_remove, r.overflow);
  r.rms_count = raw_root.range(31, 0);
  return r;
}

}  // namespace

void hls_agg10_12_cycle_engine(hls::stream<agg10_12_input_beat_t> &s_result,
                         hls::stream<record_axis_t> &m_axis,
                         hls::stream<basic_result_beat_t> &m_result) {
  // s_result unregistered (shim registers its side); both masters keep
  // boundary registers (a raw HLS axis master gates TVALID on TREADY —
  // AXI-illegal — and m_result feeds the Mtr2 shim directly).
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
  }
merge_pairs:
  for (int pair = 0; pair < MET_VLL_PAIRS; ++pair) {
#pragma HLS PIPELINE off
    const ap_uint<128> vll_base =
        first_cycle ? ap_uint<128>(0) : acc_vll_square[pair];
    acc_vll_square[pair] = met_add_square_saturating<128>(
        vll_base, cycle.vll_square[pair], arithmetic_overflow);
  }

  const ap_uint<8> cycles_now = cycles_in_block + 1;
  if (cycles_now < block_cycles_target) {
    cycles_in_block = cycles_now;
    return;
  }
  cycles_in_block = 0;

  // ---- Finalize this block inline --------------------------------------
  const ap_uint<8> result_mask =
      (active_valid_mask & block_mask) & ap_uint<8>(0x7F);
  const ap_uint<32> count_now = block_sample_count;
  sequence += 1;

  ap_int<64> mean_q16[MET_ACTIVE_CHANNELS];
#pragma HLS ARRAY_PARTITION variable=mean_q16 complete
  ap_uint<64> rms_q16[MET_ACTIVE_CHANNELS];
#pragma HLS ARRAY_PARTITION variable=rms_q16 complete
  ap_uint<32> rms_count[MET_ACTIVE_CHANNELS];
#pragma HLS ARRAY_PARTITION variable=rms_count complete
finalize_lanes:
  for (int lane = 0; lane < MET_ACTIVE_CHANNELS; ++lane) {
#pragma HLS PIPELINE off
    const lane_result_t lr =
        finalize_lane(acc_sum[lane], acc_square[lane], acc_raw_sum[lane],
                      acc_raw_square[lane], count_now, active_dc_remove);
    mean_q16[lane] = lr.mean_q16;
    rms_q16[lane] = lr.rms_q16;
    rms_count[lane] = lr.rms_count;
    arithmetic_overflow |= lr.overflow;
  }
  ap_uint<64> vll_rms[MET_VLL_PAIRS];
#pragma HLS ARRAY_PARTITION variable=vll_rms complete
finalize_pairs:
  for (int pair = 0; pair < MET_VLL_PAIRS; ++pair) {
#pragma HLS PIPELINE off
    vll_rms[pair] = met_rms_from_accumulators<128, 128>(
        acc_vll_square[pair], ap_int<128>(0), count_now, ap_uint<1>(0),
        arithmetic_overflow);
  }

  const ap_uint<1> first_block = disc_pending;
  disc_pending = 0;
  const ap_uint<32> status =
      ap_uint<32>(arithmetic_overflow) | (ap_uint<32>(first_block) << 2);
  ap_uint<3> flags = 0;
  flags[MET_FLAG_LOCKED] = block_locked_and;
  flags[MET_FLAG_FALLBACK] = block_fallback_or;
  flags[MET_FLAG_FIRST_BLOCK] = first_block;

  // Basic result beat for the 150/180-cycle aggregator (contract
  // unchanged: Mtr2Engine consumes these until M11).
  basic_result_t result;
  result.sequence = sequence;
  result.generation = active_generation;
  result.sample_rate_hz = active_sample_rate;
  result.sample_count = count_now;
  result.valid_mask = result_mask;
  result.flags = flags;
  result.cycle_count = block_cycles_target;
  result.nominal_hz = block_nominal;
  result.status = status;
  result.frequency_millihz = cycle.frequency_millihz;
  result.frequency_valid = cycle.frequency_valid;
  result.apply_toggle = apply_seen;
  result.first_sample = block_first_sample;
result_lanes:
  for (int lane = 0; lane < MET_CHANNEL_LANES; ++lane) {
#pragma HLS UNROLL
    result.rms_q16[lane] = (lane < MET_ACTIVE_CHANNELS)
                               ? ap_int<64>(rms_q16[lane])
                               : ap_int<64>(0);
  }
  m_result.write(pack_basic_result(result));

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
      const ap_int<64> mean_units = mean_q16[lane] >> 16;  // arithmetic
      const ap_uint<64> rms_units = rms_q16[lane] >> 16;
      const int base = MTR1_CH_BASE_WORD + lane * MTR1_CH_STRIDE_WORDS;
      image.word[base + MTR1_CH_MEAN_LOW] =
          ap_uint<64>(mean_units).range(31, 0);
      image.word[base + MTR1_CH_MEAN_HIGH] =
          ap_uint<64>(mean_units).range(63, 32);
      image.word[base + MTR1_CH_RMS_COUNT] = rms_count[lane];
      image.word[base + MTR1_CH_RMS_LOW] = rms_units.range(31, 0);
      image.word[base + MTR1_CH_RMS_HIGH] = rms_units.range(63, 32);
    }
  }
record_pairs:
  for (int pair = 0; pair < MET_VLL_PAIRS; ++pair) {
#pragma HLS PIPELINE off
    image.word[BASIC_VLL_BASE_WORD + pair] =
        ap_uint<64>(vll_rms[pair] >> 16).range(31, 0);
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
}
