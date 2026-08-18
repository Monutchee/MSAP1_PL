#include "mtr2_engine.hpp"

#include "metrology_math.hpp"

// IEC 61000-4-30 150/180-cycle aggregator. Behavioural contract and
// interface: see mtr2_engine.hpp. The aggregation rules and
// arithmetic are unchanged from the compared-deployment engine; this
// revision swapped the I/O boundary onto the shared contracts
// (basic_result_beat.hpp in, serialize_record<MTR2_V2> out) so the
// aggregator consumes the MTR1 engine's result stream directly and owns
// its record end-to-end -- no VHDL event conversion or record assembler
// remains between the arithmetic and the DMA stream.
//
// The arithmetic is stated at C level but shaped for area, not latency:
// Basic results arrive every ~200 ms, so a finalize that takes tens of
// microseconds costs nothing, while the default HLS schedule (unrolled
// square root, divide-by-15 as a reciprocal multiplier) cost ~25k LUT /
// 84 DSP in the first trial. The PIPELINE-off loops below keep every
// serial algorithm rolled onto one hardware copy.

// Divide-by-15 and the nominal->cycles mapping moved to the shared
// headers (metrology_math.hpp floor_div_const, metering_types.hpp
// met_expected_cycles) -- both bit-identical to the private versions
// they replace.
template <int WIDTH>
static ap_uint<WIDTH> floor_div_15(ap_uint<WIDTH> dividend) {
#pragma HLS INLINE
  return floor_div_const<WIDTH, MET_BASIC_BLOCKS_PER_AGGREGATE>(dividend);
}

void hls_mtr2_engine(hls::stream<basic_result_beat_t> &s_basic,
                          hls::stream<record_axis_t> &m_axis) {
  // register_mode=off on the wide fabric-internal input (the producer
  // registers its side); the exported 32-bit record stream keeps the
  // default boundary register toward the block design.
#pragma HLS INTERFACE mode=axis port=s_basic register_mode=off
#pragma HLS INTERFACE mode=axis port=m_axis
#pragma HLS INTERFACE mode=ap_ctrl_none port=return

  // Open-aggregate bookkeeping (mirrors the retired RTL signal set).
  // syn.rtl.reset is configured to `state` so ap_rst_n re-zeroes these
  // exactly like the RTL engine's aresetn.
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
  // for under two kilobits of state (the RTL engine kept these in
  // registers).
  static ap_uint<MTR2_ACC_BITS> square_acc[MET_ACTIVE_CHANNELS];
#pragma HLS BIND_STORAGE variable=square_acc type=ram_s2p impl=lutram
  static ap_uint<32> out_sequence = 0;

  // Diagnostics (record-carried, words 33..35; see header).
  static ap_uint<32> reset_count = 0;
  static ap_uint<32> ineligible_count = 0;
  static ap_uint<32> continuity_count = 0;

  if (s_basic.empty()) {
    return;
  }
  const basic_result_t in = unpack_basic_result(s_basic.read());

  // A configuration APPLY between beats terminates any partially
  // accumulated aggregate before this beat is considered: the new
  // generation's first block seeds afresh (RTL rule, level-sampled here).
  if (in.apply_toggle != apply_seen) {
    apply_seen = in.apply_toggle;
    if (blocks_accumulated != 0) {
      reset_count += 1;
    }
    blocks_accumulated = 0;
  }

  // Eligibility: identical predicate to the retired RTL engine and the
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
        in.sample_rate_hz != agg_sample_rate) {
      // Generation, nominal, or sample-rate change: discard the partial
      // aggregate; this block seeds the next one.
      reset_count += 1;
      seed = true;
    } else if (in.sequence != expected_next_seq ||
               in.first_sample != expected_next_first) {
      // Lost/reordered Basic result or a sample-domain discontinuity:
      // the 15 inputs would not describe one contiguous interval.
      continuity_count += 1;
      reset_count += 1;
      seed = true;
    }
  }

  if (seed) {
    agg_generation = in.generation;
    agg_nominal = in.nominal_hz;
    agg_sample_rate = in.sample_rate_hz;
    agg_first_sample = in.first_sample;
    agg_first_seq = in.sequence;
    agg_total_samples = in.sample_count;
    agg_total_cycles = in.cycle_count;
    mask_and = in.valid_mask;
    freq_sum = in.frequency_millihz;
    freq_all_valid = in.frequency_valid;
    arithmetic_flag = in.status.bit(0);
    blocks_accumulated = 1;
  } else {
    agg_total_samples += in.sample_count;
    agg_total_cycles += in.cycle_count;
    mask_and &= in.valid_mask;
    freq_sum += in.frequency_millihz;
    freq_all_valid &= in.frequency_valid;
    arithmetic_flag |= in.status.bit(0);
    blocks_accumulated += 1;
  }
  const ap_uint<32> agg_last_seq = in.sequence;
  expected_next_seq = in.sequence + 1;
  expected_next_first = in.first_sample + in.sample_count;

  // Square and accumulate this block's RMS lanes. RMS magnitudes are
  // non-negative; the signed lane is normalized defensively (RTL rule).
square_lanes:
  for (int channel = 0; channel < MET_ACTIVE_CHANNELS; ++channel) {
#pragma HLS PIPELINE off
    const ap_int<64> lane = in.rms_q16[channel];
    const ap_uint<64> magnitude =
        (lane < 0) ? ap_uint<64>(-lane) : ap_uint<64>(lane);
    const ap_uint<128> square = ap_uint<128>(magnitude) * magnitude;
    square_acc[channel] =
        (seed ? ap_uint<MTR2_ACC_BITS>(0) : square_acc[channel]) + square;
  }

  if (blocks_accumulated != MET_BASIC_BLOCKS_PER_AGGREGATE) {
    return;
  }

  // Fifteenth eligible block: finalize and emit one MTR2-v2 record.
  // Registers, not RAM: the record packing below reads all seven results.
  ap_uint<64> rms_result[MET_ACTIVE_CHANNELS];
#pragma HLS ARRAY_PARTITION variable=rms_result complete
finalize_lanes:
  for (int channel = 0; channel < MET_ACTIVE_CHANNELS; ++channel) {
#pragma HLS PIPELINE off
    // 15 squares of 63-bit magnitudes stay below 2**130; the mean stays
    // below 2**127, so the 128-bit radicand cannot truncate (RTL rule).
    const ap_uint<MTR2_ACC_BITS> mean =
        floor_div_15<MTR2_ACC_BITS>(square_acc[channel]);
    rms_result[channel] = floor_sqrt_128(mean.range(127, 0));
  }

  const ap_uint<36> freq_mean = floor_div_15<36>(freq_sum);

  out_sequence += 1;
  blocks_accumulated = 0;

  record_image_t image;
  clear_record(image);
  const ap_uint<32> record_status =
      (ap_uint<32>(arithmetic_flag) << MREC_STATUS_ARITHMETIC_BIT) |
      // Only complete 15-block aggregates are ever emitted.
      (ap_uint<32>(1) << MTR2_STATUS_COMPLETE_BIT) |
      (ap_uint<32>(freq_all_valid) << MTR2_STATUS_FREQUENCY_BIT);
  fill_envelope(image, out_sequence, agg_generation, agg_sample_rate,
                agg_total_samples, mask_and, record_status, agg_first_sample);
  // Words 11/12 (emit/result drops) stay zero: emission is blocking and
  // the engine consumes every input beat.
  image.word[MTR2_SHAPE_WORD] =
      (ap_uint<32>(MET_BASIC_BLOCKS_PER_AGGREGATE) << MTR2_SHAPE_BLOCKS_LSB) |
      (ap_uint<32>(agg_nominal) << MTR2_SHAPE_NOMINAL_LSB) |
      (ap_uint<32>(agg_total_cycles) << MTR2_SHAPE_CYCLES_LSB);
  image.word[MTR2_FIRST_BASIC_SEQ_WORD] = agg_first_seq;
  image.word[MTR2_LAST_BASIC_SEQ_WORD] = agg_last_seq;
pack_lanes:
  for (int channel = 0; channel < MET_CHANNEL_LANES; ++channel) {
#pragma HLS PIPELINE off
    // Aggregate RMS leaves the internal Q16 domain here, in the same
    // micro-unit convention as the Basic record; lane 7 stays zero.
    if (channel < MET_ACTIVE_CHANNELS) {
      const ap_uint<64> rms_units = rms_result[channel] >> 16;
      const int base = MTR2_CH_BASE_WORD + channel * MTR2_CH_STRIDE_WORDS;
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

  serialize_record<MREC_FORMAT_MTR2_V2>(image, m_axis);
}
