#include "cycle_aggregator.hpp"

// IEC 61000-4-30 150/180-cycle aggregator, HLS trial implementation.
// Behavioural contract and beat layout: see cycle_aggregator.hpp.
//
// The arithmetic is stated at C level but shaped for area, not latency:
// Basic results arrive every ~200 ms, so a finalize that takes tens of
// microseconds costs nothing, while the default HLS schedule (unrolled
// square root, divide-by-15 as a 132x134 reciprocal multiplier) costs
// ~25k LUT / 84 DSP. The PIPELINE-off loops below keep every serial
// algorithm rolled onto one hardware copy, mirroring the bit-serial
// strategy of the hand-written RTL FSM.

namespace {

// floor(dividend / 15) by restoring long division, one quotient bit per
// loop iteration (the RTL engine's divider strategy). The remainder never
// exceeds 29, so five bits hold it at every width.
template <int WIDTH>
ap_uint<WIDTH> floor_div_15(ap_uint<WIDTH> dividend) {
  ap_uint<WIDTH> quotient = 0;
  ap_uint<5> remainder = 0;
div_bits:
  for (int bit = WIDTH - 1; bit >= 0; --bit) {
#pragma HLS PIPELINE off
    remainder = (remainder << 1) | ap_uint<5>(dividend.bit(bit));
    if (remainder >= CAGG_BASIC_BLOCKS) {
      remainder -= CAGG_BASIC_BLOCKS;
      quotient.bit(bit) = 1;
    }
  }
  return quotient;
}

// floor(sqrt(radicand)) by binary digit recurrence (restoring): exact for
// the full 128-bit radicand range, no multiplier. The RTL reaches the same
// floor value through a 64-step binary search with a 64x64 multiply; any
// correct floor square root is equivalence-preserving.
ap_uint<64> floor_sqrt_128(ap_uint<128> radicand) {
  ap_uint<64> root = 0;
  ap_uint<66> remainder = 0;
sqrt_digits:
  for (int step = 0; step < 64; ++step) {
#pragma HLS PIPELINE off
    remainder = (remainder << 2) |
                radicand.range(127 - 2 * step, 126 - 2 * step);
    const ap_uint<66> trial = (ap_uint<66>(root) << 2) | 1;
    if (remainder >= trial) {
      remainder -= trial;
      root = (root << 1) | 1;
    } else {
      root = root << 1;
    }
  }
  return root;
}

ap_uint<8> expected_cycles(ap_uint<8> nominal_hz) {
  return (nominal_hz == 50) ? ap_uint<8>(CAGG_CYCLES_50HZ)
                            : ap_uint<8>(CAGG_CYCLES_60HZ);
}

}  // namespace

void hls_cycle_aggregator(hls::stream<basic_beat_t> &s_basic,
                          hls::stream<aggregate_beat_t> &m_aggregate) {
  // register_mode=off: the beats are wide (808/968 bits) and stay inside
  // the MeterCore fabric at 100 MHz, so boundary skid buffers would spend
  // ~3.5k flip-flops for nothing. The integration shim registers the event
  // on its side of both interfaces.
#pragma HLS INTERFACE mode=axis port=s_basic register_mode=off
#pragma HLS INTERFACE mode=axis port=m_aggregate register_mode=off
#pragma HLS INTERFACE mode=ap_ctrl_none port=return

  // Open-aggregate bookkeeping (mirrors the RTL signal set). syn.rtl.reset
  // is configured to `state` so ap_rst_n re-zeroes these exactly like the
  // RTL engine's aresetn.
  static ap_uint<1> apply_seen = 0;
  static ap_uint<5> blocks_accumulated = 0;
  static ap_uint<32> agg_generation = 0;
  static ap_uint<8> agg_nominal = 0;
  static ap_uint<32> agg_sample_rate = 0;
  static ap_uint<64> agg_first_sample = 0;
  static ap_uint<32> agg_first_seq = 0;
  static ap_uint<32> agg_total_samples = 0;
  static ap_uint<16> agg_total_cycles = 0;
  static ap_uint<8> mask_and = 0;
  static ap_uint<36> freq_sum = 0;
  static ap_uint<1> freq_all_valid = 0;
  static ap_uint<1> arithmetic_flag = 0;
  // Unsigned arithmetic wraps at 2**32 / 2**64, so sequence and sample
  // continuity survive wraparound without special cases (RTL identical).
  static ap_uint<32> expected_next_seq = 0;
  static ap_uint<64> expected_next_first = 0;
  // Distributed RAM: seven-deep arrays otherwise cost whole RAMB36 blocks
  // for under two kilobits of state (the RTL engine keeps these in
  // registers).
  static ap_uint<CAGG_ACC_BITS> square_acc[CAGG_CHANNELS];
#pragma HLS BIND_STORAGE variable=square_acc type=ram_s2p impl=lutram
  static ap_uint<32> out_sequence = 0;

  // Diagnostics (beat-carried; see header for APPLY-race caveats).
  static ap_uint<32> record_count = 0;
  static ap_uint<32> reset_count = 0;
  static ap_uint<32> ineligible_count = 0;
  static ap_uint<32> continuity_count = 0;

  if (s_basic.empty()) {
    return;
  }
  const basic_beat_t beat = s_basic.read();

  // Unpack the event.
  const ap_uint<32> in_sequence =
      beat.range(CAGG_IN_SEQUENCE_LSB + 31, CAGG_IN_SEQUENCE_LSB);
  const ap_uint<32> in_generation =
      beat.range(CAGG_IN_GENERATION_LSB + 31, CAGG_IN_GENERATION_LSB);
  const ap_uint<32> in_sample_rate =
      beat.range(CAGG_IN_SAMPLE_RATE_LSB + 31, CAGG_IN_SAMPLE_RATE_LSB);
  const ap_uint<32> in_sample_count =
      beat.range(CAGG_IN_SAMPLE_COUNT_LSB + 31, CAGG_IN_SAMPLE_COUNT_LSB);
  const ap_uint<8> in_valid_mask =
      beat.range(CAGG_IN_VALID_MASK_LSB + 7, CAGG_IN_VALID_MASK_LSB);
  const ap_uint<3> in_flags =
      beat.range(CAGG_IN_FLAGS_LSB + 2, CAGG_IN_FLAGS_LSB);
  const ap_uint<8> in_cycle_count =
      beat.range(CAGG_IN_CYCLE_COUNT_LSB + 7, CAGG_IN_CYCLE_COUNT_LSB);
  const ap_uint<8> in_nominal_hz =
      beat.range(CAGG_IN_NOMINAL_HZ_LSB + 7, CAGG_IN_NOMINAL_HZ_LSB);
  const ap_uint<32> in_status =
      beat.range(CAGG_IN_STATUS_LSB + 31, CAGG_IN_STATUS_LSB);
  const ap_uint<32> in_frequency =
      beat.range(CAGG_IN_FREQ_LSB + 31, CAGG_IN_FREQ_LSB);
  const ap_uint<1> in_freq_valid = beat.bit(CAGG_IN_FREQ_VALID_BIT);
  const ap_uint<1> in_apply_toggle = beat.bit(CAGG_IN_APPLY_TOGGLE_BIT);
  const ap_uint<64> in_first_sample =
      beat.range(CAGG_IN_FIRST_SAMPLE_LSB + 63, CAGG_IN_FIRST_SAMPLE_LSB);

  // A configuration APPLY between beats terminates any partially
  // accumulated aggregate before this beat is considered: the new
  // generation's first block seeds afresh (RTL rule, level-sampled here).
  if (in_apply_toggle != apply_seen) {
    apply_seen = in_apply_toggle;
    if (blocks_accumulated != 0) {
      reset_count += 1;
    }
    blocks_accumulated = 0;
  }

  // Eligibility: identical predicate to the RTL engine and the APU's
  // class_a_aggregation_eligible() rule.
  const bool nominal_known = (in_nominal_hz == 50) || (in_nominal_hz == 60);
  const bool input_eligible =
      in_flags.bit(CAGG_FLAG_LOCKED) == 1 &&
      in_flags.bit(CAGG_FLAG_FALLBACK) == 0 &&
      in_flags.bit(CAGG_FLAG_FIRST_BLOCK) == 0 && nominal_known &&
      in_cycle_count == expected_cycles(in_nominal_hz);

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
    if (in_generation != agg_generation || in_nominal_hz != agg_nominal ||
        in_sample_rate != agg_sample_rate) {
      // Generation, nominal, or sample-rate change: discard the partial
      // aggregate; this block seeds the next one.
      reset_count += 1;
      seed = true;
    } else if (in_sequence != expected_next_seq ||
               in_first_sample != expected_next_first) {
      // Lost/reordered Basic result or a sample-domain discontinuity:
      // the 15 inputs would not describe one contiguous interval.
      continuity_count += 1;
      reset_count += 1;
      seed = true;
    }
  }

  if (seed) {
    agg_generation = in_generation;
    agg_nominal = in_nominal_hz;
    agg_sample_rate = in_sample_rate;
    agg_first_sample = in_first_sample;
    agg_first_seq = in_sequence;
    agg_total_samples = in_sample_count;
    agg_total_cycles = in_cycle_count;
    mask_and = in_valid_mask;
    freq_sum = in_frequency;
    freq_all_valid = in_freq_valid;
    arithmetic_flag = in_status.bit(0);
    blocks_accumulated = 1;
  } else {
    agg_total_samples += in_sample_count;
    agg_total_cycles += in_cycle_count;
    mask_and &= in_valid_mask;
    freq_sum += in_frequency;
    freq_all_valid &= in_freq_valid;
    arithmetic_flag |= in_status.bit(0);
    blocks_accumulated += 1;
  }
  const ap_uint<32> agg_last_seq = in_sequence;
  expected_next_seq = in_sequence + 1;
  expected_next_first = in_first_sample + in_sample_count;

  // Split the 512-bit RMS field into per-channel words with compile-time
  // slice positions (wiring); the sequential loops below then index a
  // small register array instead of barrel-shifting the wide beat.
  // Registers, not RAM: the unpack loop writes all seven lanes in one
  // cycle, so this can never satisfy a one-write-port memory.
  ap_uint<64> rms_lane[CAGG_CHANNELS];
#pragma HLS ARRAY_PARTITION variable=rms_lane complete
unpack_lanes:
  for (int channel = 0; channel < CAGG_CHANNELS; ++channel) {
#pragma HLS UNROLL
    rms_lane[channel] = beat.range(CAGG_IN_RMS_LSB + channel * 64 + 63,
                                   CAGG_IN_RMS_LSB + channel * 64);
  }

  // Square and accumulate this block's RMS lanes. RMS magnitudes are
  // non-negative; the signed lane is normalized defensively (RTL rule).
square_lanes:
  for (int channel = 0; channel < CAGG_CHANNELS; ++channel) {
#pragma HLS PIPELINE off
    const ap_int<64> lane = ap_int<64>(rms_lane[channel]);
    const ap_uint<64> magnitude =
        (lane < 0) ? ap_uint<64>(-lane) : ap_uint<64>(lane);
    const ap_uint<128> square = ap_uint<128>(magnitude) * magnitude;
    square_acc[channel] =
        (seed ? ap_uint<CAGG_ACC_BITS>(0) : square_acc[channel]) + square;
  }

  if (blocks_accumulated != CAGG_BASIC_BLOCKS) {
    return;
  }

  // Fifteenth eligible block: finalize and emit one aggregate beat.
  // Registers, not RAM: the pack loop below reads all seven results in
  // one cycle.
  ap_uint<64> rms_result[CAGG_CHANNELS];
#pragma HLS ARRAY_PARTITION variable=rms_result complete
finalize_lanes:
  for (int channel = 0; channel < CAGG_CHANNELS; ++channel) {
#pragma HLS PIPELINE off
    // 15 squares of 63-bit magnitudes stay below 2**130; the mean stays
    // below 2**127, so the 128-bit radicand cannot truncate (RTL rule).
    const ap_uint<CAGG_ACC_BITS> mean =
        floor_div_15<CAGG_ACC_BITS>(square_acc[channel]);
    rms_result[channel] = floor_sqrt_128(mean.range(127, 0));
  }

  const ap_uint<36> freq_mean = floor_div_15<36>(freq_sum);

  aggregate_beat_t out = 0;
pack_lanes:
  for (int channel = 0; channel < CAGG_CHANNELS; ++channel) {
#pragma HLS UNROLL
    out.range(CAGG_OUT_RMS_LSB + channel * 64 + 63,
              CAGG_OUT_RMS_LSB + channel * 64) = rms_result[channel];
  }

  record_count += 1;
  out_sequence += 1;
  blocks_accumulated = 0;

  out.range(CAGG_OUT_SEQUENCE_LSB + 31, CAGG_OUT_SEQUENCE_LSB) = out_sequence;
  out.range(CAGG_OUT_GENERATION_LSB + 31, CAGG_OUT_GENERATION_LSB) =
      agg_generation;
  out.range(CAGG_OUT_SAMPLE_RATE_LSB + 31, CAGG_OUT_SAMPLE_RATE_LSB) =
      agg_sample_rate;
  out.range(CAGG_OUT_SAMPLES_LSB + 31, CAGG_OUT_SAMPLES_LSB) =
      agg_total_samples;
  out.range(CAGG_OUT_VALID_MASK_LSB + 7, CAGG_OUT_VALID_MASK_LSB) = mask_and;
  out.range(CAGG_OUT_NOMINAL_HZ_LSB + 7, CAGG_OUT_NOMINAL_HZ_LSB) =
      agg_nominal;
  out.range(CAGG_OUT_CYCLES_LSB + 15, CAGG_OUT_CYCLES_LSB) = agg_total_cycles;
  out.bit(CAGG_OUT_ARITHMETIC_BIT) = arithmetic_flag;
  out.bit(CAGG_OUT_FREQ_VALID_BIT) = freq_all_valid;
  out.range(CAGG_OUT_FIRST_SEQ_LSB + 31, CAGG_OUT_FIRST_SEQ_LSB) =
      agg_first_seq;
  out.range(CAGG_OUT_LAST_SEQ_LSB + 31, CAGG_OUT_LAST_SEQ_LSB) = agg_last_seq;
  out.range(CAGG_OUT_FREQ_LSB + 31, CAGG_OUT_FREQ_LSB) =
      (freq_all_valid == 1) ? ap_uint<32>(freq_mean.range(31, 0))
                            : ap_uint<32>(0);
  out.range(CAGG_OUT_FIRST_SAMPLE_LSB + 63, CAGG_OUT_FIRST_SAMPLE_LSB) =
      agg_first_sample;
  out.range(CAGG_OUT_RECORD_CNT_LSB + 31, CAGG_OUT_RECORD_CNT_LSB) =
      record_count;
  out.range(CAGG_OUT_RESET_CNT_LSB + 31, CAGG_OUT_RESET_CNT_LSB) = reset_count;
  out.range(CAGG_OUT_INELIG_CNT_LSB + 31, CAGG_OUT_INELIG_CNT_LSB) =
      ineligible_count;
  out.range(CAGG_OUT_CONT_CNT_LSB + 31, CAGG_OUT_CONT_CNT_LSB) =
      continuity_count;

  m_aggregate.write(out);
}
