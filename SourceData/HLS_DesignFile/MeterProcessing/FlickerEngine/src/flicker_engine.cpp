#include "flicker_engine.hpp"

// The fixed-point implementation follows the functional block diagram in
// IEC 61000-4-15:2010.  Coefficients below are bilinear transforms at the
// engine's fixed 2 kSPS rate.  The 64-bit Q2.30 state is deliberately wider
// than the coefficients: transients saturate and set provenance instead of
// wrapping into a plausible Pinst value.

namespace {

using q30_t = ap_int<64>;

struct BiquadCoefficients {
  ap_int<64> b0;
  ap_int<64> b1;
  ap_int<64> b2;
  ap_int<64> a1;
  ap_int<64> a2;
};

static const BiquadCoefficients k230VoltCoefficients[7] = {
    {1073657499LL, -1073657499LL, 0LL, -1073573174LL, 0LL},
    {3152648LL, 6305296LL, 3152648LL, -2075566063LL, 1014434831LL},
    {3008728LL, 6017457LL, 3008728LL, -1980815729LL, 919108819LL},
    {2931466LL, 5862932LL, 2931466LL, -1929949505LL, 867933545LL},
    {26645808LL, 0LL, -26645808LL, -2119567684LL, 1046702695LL},
    {19224623LL, 137199LL, -19087424LL, -2071940580LL, 998473154LL},
    {894040LL, 894040LL, 0LL, -1071953744LL, 0LL}};

static const BiquadCoefficients k120VoltCoefficients[7] = {
    {1073657499LL, -1073657499LL, 0LL, -1073573174LL, 0LL},
    {4513006LL, 9026012LL, 4513006LL, -2058714883LL, 1003025083LL},
    {4269489LL, 8538978LL, 4269489LL, -1947628912LL, 890965045LL},
    {4140500LL, 8280999LL, 4140500LL, -1888787185LL, 831607359LL},
    {24713697LL, 0LL, -24713697LL, -2118875559LL, 1045995452LL},
    {13518150LL, 124279LL, -13393871LL, -2085928193LL, 1012434928LL},
    {894040LL, 894040LL, 0LL, -1071953744LL, 0LL}};

static const ap_uint<64> k230CalibrationQ16 = 5072324577ULL;
static const ap_uint<64> k120CalibrationQ16 = 5040534274ULL;
static const int kVoltageLane[FLK_PHASES] = {
    MET_LANE_VA, MET_LANE_VB, MET_LANE_VC};

inline q30_t saturate_q30(ap_int<128> value, ap_uint<1> &overflow) {
#pragma HLS INLINE
  const ap_int<128> maximum = (ap_int<128>(1) << 63) - 1;
  const ap_int<128> minimum = -(ap_int<128>(1) << 63);
  if (value > maximum) {
    overflow = 1;
    return q30_t(maximum);
  }
  if (value < minimum) {
    overflow = 1;
    return q30_t(minimum);
  }
  return q30_t(value);
}

inline q30_t multiply_q30(q30_t lhs, ap_int<64> rhs,
                          ap_uint<1> &overflow) {
#pragma HLS INLINE
  const ap_int<128> product = ap_int<128>(lhs) * ap_int<128>(rhs);
  const ap_int<128> half = ap_int<128>(1) << 29;
  ap_int<128> rounded;
  if (product < 0) {
    const ap_int<128> magnitude = -product;
    rounded = -ap_int<128>((magnitude + half) >> 30);
  } else {
    rounded = ap_int<128>((product + half) >> 30);
  }
  return saturate_q30(rounded, overflow);
}

inline q30_t run_biquad(q30_t input, const BiquadCoefficients &coefficient,
                        q30_t &z1, q30_t &z2, ap_uint<1> &overflow) {
#pragma HLS INLINE
  const q30_t output = saturate_q30(
      ap_int<128>(multiply_q30(input, coefficient.b0, overflow)) + z1,
      overflow);
  const q30_t next_z1 = saturate_q30(
      ap_int<128>(multiply_q30(input, coefficient.b1, overflow)) -
          multiply_q30(output, coefficient.a1, overflow) + z2,
      overflow);
  const q30_t next_z2 = saturate_q30(
      ap_int<128>(multiply_q30(input, coefficient.b2, overflow)) -
          multiply_q30(output, coefficient.a2, overflow),
      overflow);
  z1 = next_z1;
  z2 = next_z2;
  return output;
}

inline void emit_payload(const ap_uint<32> payload[FLK_PAYLOAD_WORDS],
                         hls::stream<record_axis_t> &output) {
#pragma HLS INLINE off
emit_words:
  for (int word = 0; word < FLK_PAYLOAD_WORDS; ++word) {
#pragma HLS PIPELINE II=1
    record_axis_t beat{};
    beat.data = payload[word];
    beat.keep = MREC_KEEP_ALL;
    beat.strb = MREC_KEEP_ALL;
    beat.last = (word == FLK_PAYLOAD_WORDS - 1) ? ap_uint<1>(1)
                                                : ap_uint<1>(0);
    output.write(beat);
  }
}

inline ap_uint<32> status_word(ap_uint<1> enabled, ap_uint<1> locked,
                               ap_uint<1> fallback,
                               ap_uint<1> discontinuity,
                               ap_uint<1> arithmetic,
                               ap_uint<1> classifier_overflow,
                               ap_uint<1> contaminated,
                               ap_uint<1> settling) {
#pragma HLS INLINE
  return (ap_uint<32>(enabled) << FLK_STATUS_ENABLED_BIT) |
         (ap_uint<32>(locked) << FLK_STATUS_LOCKED_BIT) |
         (ap_uint<32>(fallback) << FLK_STATUS_FALLBACK_BIT) |
         (ap_uint<32>(discontinuity) << FLK_STATUS_DISCONTINUITY_BIT) |
         (ap_uint<32>(arithmetic) << FLK_STATUS_ARITHMETIC_BIT) |
         (ap_uint<32>(classifier_overflow)
          << FLK_STATUS_CLASSIFIER_OVERFLOW_BIT) |
         (ap_uint<32>(contaminated) << FLK_STATUS_CONTAMINATED_BIT) |
         (ap_uint<32>(settling) << FLK_STATUS_SETTLING_BIT);
}

}  // namespace

void hls_flicker_engine(hls::stream<flicker_input_beat_t> &s_frame,
                        hls::stream<record_axis_t> &m_flk) {
#pragma HLS INTERFACE mode=axis port=s_frame register_mode=off
#pragma HLS INTERFACE mode=axis port=m_flk
#pragma HLS INTERFACE mode=ap_ctrl_none port=return

  static ap_uint<1> apply_seen = 0;
  static ap_uint<1> configured_enable = 0;
  static ap_uint<1> engine_ready = 0;
  static ap_uint<32> generation = 0;
  static ap_uint<32> sample_rate_hz = 32000;
  static ap_uint<8> phase_mask = 0;
  static ap_uint<16> lamp_voltage = 230;
  static ap_uint<8> nominal_hz = 50;
  static ap_uint<32> live_cadence_ms = 1000;
  static ap_uint<32> pst_interval_seconds = 600;
  static ap_uint<32> reference_microvolts = 0;
  static ap_uint<16> decimation_divisor = 16;
  static ap_uint<64> reference_reciprocal_q46 = 0;

  static ap_uint<128> raw_square_sum[FLK_PHASES];
#pragma HLS ARRAY_PARTITION variable=raw_square_sum complete
  static ap_uint<3> raw_valid = 0;
  static ap_uint<16> raw_count = 0;

  static ap_uint<64> adapter_q32[FLK_PHASES];
#pragma HLS ARRAY_PARTITION variable=adapter_q32 complete
  static ap_uint<64> adapter_reciprocal_q30[FLK_PHASES];
#pragma HLS ARRAY_PARTITION variable=adapter_reciprocal_q30 complete
  static q30_t filter_z1[FLK_PHASES][7];
  static q30_t filter_z2[FLK_PHASES][7];
#pragma HLS ARRAY_PARTITION variable=filter_z1 complete dim=1
#pragma HLS ARRAY_PARTITION variable=filter_z2 complete dim=1

  static ap_uint<32> live_peak_q16[FLK_PHASES];
#pragma HLS ARRAY_PARTITION variable=live_peak_q16 complete
  static ap_uint<32> live_valid_count[FLK_PHASES];
#pragma HLS ARRAY_PARTITION variable=live_valid_count complete
  static ap_uint<32> live_ticks = 0;
  static ap_uint<64> live_first_sample = 0;
  static ap_uint<1> live_discontinuity = 1;
  static ap_uint<1> live_contaminated = 1;
  static ap_uint<1> live_classifier_overflow = 0;

  static ap_uint<32> histogram[2][FLK_PHASES][FLK_CLASSIFIER_BINS];
#pragma HLS BIND_STORAGE variable=histogram type=ram_t2p impl=bram
  static ap_uint<1> active_histogram_bank = 0;
  static ap_uint<32> interval_ticks = 0;
  static ap_uint<32> interval_valid_count[FLK_PHASES];
#pragma HLS ARRAY_PARTITION variable=interval_valid_count complete
  static ap_uint<32> interval_peak_q16[FLK_PHASES];
#pragma HLS ARRAY_PARTITION variable=interval_peak_q16 complete
  static ap_uint<64> interval_first_sample = 0;
  static ap_uint<1> interval_discontinuity = 1;
  static ap_uint<1> interval_contaminated = 1;
  static ap_uint<1> interval_classifier_overflow = 0;

  static ap_uint<1> histogram_emit_active = 0;
  static ap_uint<1> histogram_emit_bank = 0;
  static ap_uint<6> histogram_emit_chunk = 0;
  static ap_uint<32> histogram_emit_valid_count[FLK_PHASES];
#pragma HLS ARRAY_PARTITION variable=histogram_emit_valid_count complete
  static ap_uint<32> histogram_emit_peak_q16[FLK_PHASES];
#pragma HLS ARRAY_PARTITION variable=histogram_emit_peak_q16 complete
  static ap_uint<64> histogram_emit_first_sample = 0;
  static ap_uint<64> histogram_emit_last_sample = 0;
  static ap_uint<32> histogram_emit_status = 0;
  static ap_uint<3> histogram_emit_phase_mask = 0;

  static ap_uint<32> settling_ticks = FLK_INTERNAL_RATE_HZ *
                                      FLK_SETTLING_SECONDS;
  static ap_uint<32> adapter_reciprocal_ticks = 0;
  static ap_uint<32> sequence = 0;
  static ap_uint<64> last_input_sample = 0;
  static ap_uint<1> have_last_input_sample = 0;
  static ap_uint<1> arithmetic_overflow = 0;
  static ap_uint<1> locked = 0;
  static ap_uint<1> fallback = 0;

  if (s_frame.empty()) {
    return;
  }
  const flicker_input_beat_t input = s_frame.read();

  const ap_uint<1> input_apply = input.bit(FLKIN_APPLY_BIT);
  if (input_apply != apply_seen) {
    apply_seen = input_apply;
    configured_enable = input.bit(FLKIN_ENABLE_BIT);
    generation = input.range(FLKIN_GENERATION_LSB + 31,
                             FLKIN_GENERATION_LSB);
    sample_rate_hz = input.range(FLKIN_SAMPLE_RATE_LSB + 31,
                                 FLKIN_SAMPLE_RATE_LSB);
    phase_mask = input.range(FLKIN_PHASE_MASK_LSB + 7,
                             FLKIN_PHASE_MASK_LSB);
    lamp_voltage = input.range(FLKIN_LAMP_VOLTAGE_LSB + 15,
                               FLKIN_LAMP_VOLTAGE_LSB);
    nominal_hz = input.range(FLKIN_NOMINAL_HZ_LSB + 7,
                             FLKIN_NOMINAL_HZ_LSB);
    live_cadence_ms = input.range(FLKIN_LIVE_CADENCE_LSB + 31,
                                  FLKIN_LIVE_CADENCE_LSB);
    pst_interval_seconds = input.range(FLKIN_PST_INTERVAL_LSB + 31,
                                       FLKIN_PST_INTERVAL_LSB);
    reference_microvolts = input.range(FLKIN_REFERENCE_UV_LSB + 31,
                                       FLKIN_REFERENCE_UV_LSB);
    engine_ready = configured_enable == 1 && reference_microvolts != 0 &&
                   sample_rate_hz >= FLK_INTERNAL_RATE_HZ &&
                   sample_rate_hz % FLK_INTERNAL_RATE_HZ == 0 &&
                   (lamp_voltage == 120 || lamp_voltage == 230) &&
                   (nominal_hz == 50 || nominal_hz == 60);
    decimation_divisor = engine_ready
                             ? ap_uint<16>(sample_rate_hz /
                                           FLK_INTERNAL_RATE_HZ)
                             : ap_uint<16>(1);
    reference_reciprocal_q46 =
        reference_microvolts == 0
            ? ap_uint<64>(0)
            : ap_uint<64>((ap_uint<96>(1) << 46) /
                          reference_microvolts);
    raw_count = 0;
    raw_valid = 0;
    active_histogram_bank = 0;
    interval_ticks = 0;
    live_ticks = 0;
    histogram_emit_active = 0;
    settling_ticks = FLK_INTERNAL_RATE_HZ * FLK_SETTLING_SECONDS;
    adapter_reciprocal_ticks = 0;
    have_last_input_sample = 0;
    arithmetic_overflow = 0;
    live_discontinuity = 1;
    live_contaminated = 0;
    live_classifier_overflow = 0;
    interval_discontinuity = 1;
    interval_contaminated = 0;
    interval_classifier_overflow = 0;
reset_phase_state:
    for (int phase = 0; phase < FLK_PHASES; ++phase) {
#pragma HLS UNROLL
      raw_square_sum[phase] = 0;
      adapter_q32[phase] = ap_uint<64>(1) << 32;
      adapter_reciprocal_q30[phase] = ap_uint<64>(1) << 30;
      live_peak_q16[phase] = 0;
      live_valid_count[phase] = 0;
      interval_valid_count[phase] = 0;
      interval_peak_q16[phase] = 0;
      histogram_emit_valid_count[phase] = 0;
      histogram_emit_peak_q16[phase] = 0;
      for (int stage = 0; stage < 7; ++stage) {
#pragma HLS UNROLL
        filter_z1[phase][stage] = 0;
        filter_z2[phase][stage] = 0;
      }
    }
reset_histogram:
    for (int bank = 0; bank < 2; ++bank) {
      for (int phase = 0; phase < FLK_PHASES; ++phase) {
        for (int bin = 0; bin < FLK_CLASSIFIER_BINS; ++bin) {
#pragma HLS PIPELINE II=1
          histogram[bank][phase][bin] = 0;
        }
      }
    }
  }

  locked = input.bit(FLKIN_LOCKED_BIT);
  fallback = input.bit(FLKIN_FALLBACK_BIT);
  if (configured_enable == 0 || engine_ready == 0) {
    return;
  }

  const ap_uint<64> sample_index = input.range(FLKIN_SAMPLE_INDEX_LSB + 63,
                                               FLKIN_SAMPLE_INDEX_LSB);
  const ap_uint<1> malformed = input.bit(FLKIN_MALFORMED_BIT);
  const ap_uint<1> sequence_gap =
      have_last_input_sample == 1 &&
      sample_index != ap_uint<64>(last_input_sample + 1);
  last_input_sample = sample_index;
  have_last_input_sample = 1;
  if (malformed == 1 || sequence_gap == 1) {
    raw_count = 0;
    raw_valid = 0;
    settling_ticks = FLK_INTERNAL_RATE_HZ * FLK_SETTLING_SECONDS;
    live_discontinuity = 1;
    live_contaminated = 1;
    interval_discontinuity = 1;
    interval_contaminated = 1;
reset_gap_filters:
    for (int phase = 0; phase < FLK_PHASES; ++phase) {
#pragma HLS UNROLL
      raw_square_sum[phase] = 0;
      adapter_q32[phase] = ap_uint<64>(1) << 32;
      adapter_reciprocal_q30[phase] = ap_uint<64>(1) << 30;
      for (int stage = 0; stage < 7; ++stage) {
#pragma HLS UNROLL
        filter_z1[phase][stage] = 0;
        filter_z2[phase][stage] = 0;
      }
    }
    if (malformed == 1) {
      return;
    }
  }

  const ap_uint<8> frame_mask = input.range(FLKIN_FRAME_MASK_LSB + 7,
                                            FLKIN_FRAME_MASK_LSB);
  if (raw_count == 0) {
    raw_valid = 0x7;
  }
accumulate_decimation:
  for (int phase = 0; phase < FLK_PHASES; ++phase) {
#pragma HLS UNROLL
    const ap_uint<1> phase_valid = phase_mask[phase] &&
                                   frame_mask[kVoltageLane[phase]];
    raw_valid[phase] = raw_valid[phase] && phase_valid;
    if (phase_valid == 1) {
      const met_q16_t sample = met_q16_t(
          ap_uint<MET_RMS_LANE_BITS>(input.range(
              FLKIN_SAMPLES_LSB + kVoltageLane[phase] * MET_RMS_LANE_BITS +
                  MET_RMS_LANE_BITS - 1,
              FLKIN_SAMPLES_LSB + kVoltageLane[phase] * MET_RMS_LANE_BITS)));
      ap_int<112> normalized_wide =
          ap_int<112>(sample) * ap_int<112>(reference_reciprocal_q46);
      normalized_wide >>= 46;
      const ap_int<64> normalized_limit = ap_int<64>(8) << 16;
      ap_int<64> normalized_q16;
      if (normalized_wide > normalized_limit) {
        normalized_q16 = normalized_limit;
        arithmetic_overflow = 1;
      } else if (normalized_wide < -normalized_limit) {
        normalized_q16 = -normalized_limit;
        arithmetic_overflow = 1;
      } else {
        normalized_q16 = ap_int<64>(normalized_wide);
      }
      const ap_uint<64> magnitude = normalized_q16 < 0
                                        ? ap_uint<64>(-normalized_q16)
                                        : ap_uint<64>(normalized_q16);
      const ap_uint<128> square = ap_uint<128>(magnitude) * magnitude;
      const ap_uint<128> sum = raw_square_sum[phase] + square;
      if (sum < raw_square_sum[phase]) {
        raw_square_sum[phase] = ~ap_uint<128>(0);
        arithmetic_overflow = 1;
      } else {
        raw_square_sum[phase] = sum;
      }
    }
  }
  raw_count += 1;
  if (raw_count < decimation_divisor) {
    return;
  }

  const ap_uint<64> decimated_first_sample =
      sample_index - decimation_divisor + 1;
  if (live_ticks == 0) {
    live_first_sample = decimated_first_sample;
  }
  if (interval_ticks == 0) {
    interval_first_sample = decimated_first_sample;
  }

  const ap_uint<1> was_settling = settling_ticks != 0;
  if (settling_ticks != 0) {
    settling_ticks -= 1;
  }
  adapter_reciprocal_ticks += 1;

process_phases:
  for (int phase = 0; phase < FLK_PHASES; ++phase) {
#pragma HLS PIPELINE off
    ap_uint<32> pinst_q16 = 0;
    if (raw_valid[phase] == 1) {
      const ap_uint<64> mean_square_q32 =
          ap_uint<64>(raw_square_sum[phase] / decimation_divisor);
      const ap_int<65> adapter_difference =
          ap_int<65>(mean_square_q32) - ap_int<65>(adapter_q32[phase]);
      const ap_int<65> adapter_step = adapter_difference / 54600;
      ap_int<66> adapter_next =
          ap_int<66>(adapter_q32[phase]) + adapter_step;
      if (adapter_next < ap_int<66>(1) << 16) {
        adapter_next = ap_int<66>(1) << 16;
        arithmetic_overflow = 1;
      }
      adapter_q32[phase] = ap_uint<64>(adapter_next);
      if (adapter_reciprocal_ticks >= FLK_INTERNAL_RATE_HZ) {
        adapter_reciprocal_q30[phase] = ap_uint<64>(
            (ap_uint<128>(1) << 62) / adapter_q32[phase]);
      }
      const ap_uint<128> ratio_product =
          ap_uint<128>(mean_square_q32) *
          adapter_reciprocal_q30[phase];
      q30_t filtered = q30_t(ap_uint<64>(ratio_product >> 32)) -
                       (q30_t(1) << 30);
    carrier_and_weighting:
      for (int stage = 0; stage < 6; ++stage) {
#pragma HLS PIPELINE off
        const BiquadCoefficients &coefficient =
            lamp_voltage == 120 ? k120VoltCoefficients[stage]
                                : k230VoltCoefficients[stage];
        filtered = run_biquad(filtered, coefficient,
                              filter_z1[phase][stage],
                              filter_z2[phase][stage], arithmetic_overflow);
      }
      const ap_int<128> perceptibility_square =
          ap_int<128>(filtered) * ap_int<128>(filtered);
      const q30_t squared_q30 = saturate_q30(
          (perceptibility_square + (ap_int<128>(1) << 29)) >> 30,
          arithmetic_overflow);
      const BiquadCoefficients &memory_coefficient =
          lamp_voltage == 120 ? k120VoltCoefficients[6]
                              : k230VoltCoefficients[6];
      q30_t memory_q30 = run_biquad(
          squared_q30, memory_coefficient, filter_z1[phase][6],
          filter_z2[phase][6], arithmetic_overflow);
      if (memory_q30 < 0) {
        memory_q30 = 0;
      }
      const ap_uint<128> calibrated =
          ap_uint<128>(memory_q30) *
          (lamp_voltage == 120 ? k120CalibrationQ16
                               : k230CalibrationQ16);
      const ap_uint<128> calibrated_q16 = calibrated >> 30;
      if (calibrated_q16 > 0xffffffffULL) {
        pinst_q16 = 0xffffffffU;
        arithmetic_overflow = 1;
      } else {
        pinst_q16 = ap_uint<32>(calibrated_q16);
      }
      live_valid_count[phase] += 1;
      if (pinst_q16 > live_peak_q16[phase]) {
        live_peak_q16[phase] = pinst_q16;
      }
      if (was_settling == 0) {
        interval_valid_count[phase] += 1;
        if (pinst_q16 > interval_peak_q16[phase]) {
          interval_peak_q16[phase] = pinst_q16;
        }
        ap_uint<1> outside = 0;
        const ap_uint<9> bin = flicker_histogram_bin_q16(pinst_q16, outside);
        if (outside == 1) {
          interval_classifier_overflow = 1;
          live_classifier_overflow = 1;
        }
        const ap_uint<32> old_count =
            histogram[active_histogram_bank][phase][bin];
        if (old_count == 0xffffffffU) {
          interval_classifier_overflow = 1;
          live_classifier_overflow = 1;
        } else {
          histogram[active_histogram_bank][phase][bin] = old_count + 1;
        }
      }
    } else {
      live_contaminated = 1;
      interval_contaminated = 1;
    }
  }
  if (adapter_reciprocal_ticks >= FLK_INTERNAL_RATE_HZ) {
    adapter_reciprocal_ticks = 0;
  }
  raw_count = 0;
  raw_valid = 0;
clear_raw_sums:
  for (int phase = 0; phase < FLK_PHASES; ++phase) {
#pragma HLS UNROLL
    raw_square_sum[phase] = 0;
  }

  live_ticks += 1;
  if (was_settling == 0) {
    interval_ticks += 1;
  }

  const ap_uint<32> configured_live_ticks =
      live_cadence_ms * (FLK_INTERNAL_RATE_HZ / 1000);
  if (live_ticks >= configured_live_ticks && configured_live_ticks != 0) {
    ap_uint<32> payload[FLK_PAYLOAD_WORDS];
#pragma HLS ARRAY_PARTITION variable=payload cyclic factor=4
  clear_live_payload:
    for (int word = 0; word < FLK_PAYLOAD_WORDS; ++word) {
#pragma HLS PIPELINE II=1
      payload[word] = 0;
    }
    sequence += 1;
    ap_uint<3> live_phase_valid = 0;
  live_validity:
    for (int phase = 0; phase < FLK_PHASES; ++phase) {
#pragma HLS UNROLL
      if (phase_mask[phase] == 1 && live_valid_count[phase] == live_ticks) {
        live_phase_valid[phase] = 1;
      }
      payload[FLK_VALID_COUNT_BASE_WORD + phase] =
          live_valid_count[phase];
      payload[FLK_PINST_BASE_WORD + phase] = live_peak_q16[phase];
      live_peak_q16[phase] = 0;
      live_valid_count[phase] = 0;
    }
    payload[FLK_SEQUENCE_WORD] = sequence;
    payload[FLK_GENERATION_WORD] = generation;
    payload[FLK_SAMPLE_RATE_WORD] = sample_rate_hz;
    payload[FLK_STATUS_WORD] = status_word(
        engine_ready, locked, fallback, live_discontinuity,
        arithmetic_overflow, live_classifier_overflow, live_contaminated,
        settling_ticks != 0);
    payload[FLK_PHASE_MASK_WORD] = live_phase_valid;
    payload[FLK_KIND_WORD] = FLK_KIND_LIVE;
    payload[FLK_MODEL_WORD] = ap_uint<32>(lamp_voltage) |
                              (ap_uint<32>(nominal_hz) << 16);
    payload[FLK_TIMING_WORD] =
        ap_uint<32>(live_cadence_ms.range(15, 0)) |
        (ap_uint<32>(pst_interval_seconds.range(15, 0)) << 16);
    payload[FLK_FIRST_SAMPLE_LOW_WORD] = live_first_sample.range(31, 0);
    payload[FLK_FIRST_SAMPLE_HIGH_WORD] = live_first_sample.range(63, 32);
    payload[FLK_LAST_SAMPLE_LOW_WORD] = sample_index.range(31, 0);
    payload[FLK_LAST_SAMPLE_HIGH_WORD] = sample_index.range(63, 32);
    emit_payload(payload, m_flk);
    live_ticks = 0;
    live_discontinuity = 0;
    live_contaminated = 0;
    live_classifier_overflow = 0;
  }

  const ap_uint<32> configured_interval_ticks =
      pst_interval_seconds * FLK_INTERNAL_RATE_HZ;
  if (interval_ticks >= configured_interval_ticks &&
      configured_interval_ticks != 0) {
    // A complete bank is immutable until its 35 chunks have left m_flk.  A
    // second interval cannot complete in that time, nevertheless the guard
    // makes corruption impossible if a hostile downstream stalls for 10 min.
    if (histogram_emit_active == 0) {
      histogram_emit_active = 1;
      histogram_emit_bank = active_histogram_bank;
      histogram_emit_chunk = 0;
      histogram_emit_first_sample = interval_first_sample;
      histogram_emit_last_sample = sample_index;
      histogram_emit_status = status_word(
          engine_ready, locked, fallback, interval_discontinuity,
          arithmetic_overflow, interval_classifier_overflow,
          interval_contaminated, 0);
      histogram_emit_phase_mask = 0;
    snapshot_interval:
      for (int phase = 0; phase < FLK_PHASES; ++phase) {
#pragma HLS UNROLL
        histogram_emit_valid_count[phase] = interval_valid_count[phase];
        histogram_emit_peak_q16[phase] = interval_peak_q16[phase];
        if (phase_mask[phase] == 1 &&
            interval_valid_count[phase] == configured_interval_ticks &&
            interval_contaminated == 0) {
          histogram_emit_phase_mask[phase] = 1;
        }
        interval_valid_count[phase] = 0;
        interval_peak_q16[phase] = 0;
      }
      active_histogram_bank = !active_histogram_bank;
      interval_ticks = 0;
      interval_discontinuity = 0;
      interval_contaminated = 0;
      interval_classifier_overflow = 0;
    } else {
      interval_contaminated = 1;
      interval_ticks = 0;
    }
  }

  if (histogram_emit_active == 1) {
    ap_uint<32> payload[FLK_PAYLOAD_WORDS];
#pragma HLS ARRAY_PARTITION variable=payload cyclic factor=4
  clear_histogram_payload:
    for (int word = 0; word < FLK_PAYLOAD_WORDS; ++word) {
#pragma HLS PIPELINE II=1
      payload[word] = 0;
    }
    sequence += 1;
    const ap_uint<10> base = histogram_emit_chunk * FLK_BINS_PER_PACKET;
    payload[FLK_SEQUENCE_WORD] = sequence;
    payload[FLK_GENERATION_WORD] = generation;
    payload[FLK_SAMPLE_RATE_WORD] = sample_rate_hz;
    payload[FLK_STATUS_WORD] = histogram_emit_status;
    payload[FLK_PHASE_MASK_WORD] = histogram_emit_phase_mask;
    payload[FLK_KIND_WORD] = FLK_KIND_HISTOGRAM;
    payload[FLK_MODEL_WORD] = ap_uint<32>(lamp_voltage) |
                              (ap_uint<32>(nominal_hz) << 16);
    payload[FLK_TIMING_WORD] =
        ap_uint<32>(live_cadence_ms.range(15, 0)) |
        (ap_uint<32>(pst_interval_seconds.range(15, 0)) << 16);
    payload[FLK_HISTOGRAM_BASE_WORD] = base;
  histogram_metadata:
    for (int phase = 0; phase < FLK_PHASES; ++phase) {
#pragma HLS UNROLL
      payload[FLK_VALID_COUNT_BASE_WORD + phase] =
          histogram_emit_valid_count[phase];
      payload[FLK_PINST_BASE_WORD + phase] =
          histogram_emit_peak_q16[phase];
    }
    payload[FLK_FIRST_SAMPLE_LOW_WORD] =
        histogram_emit_first_sample.range(31, 0);
    payload[FLK_FIRST_SAMPLE_HIGH_WORD] =
        histogram_emit_first_sample.range(63, 32);
    payload[FLK_LAST_SAMPLE_LOW_WORD] =
        histogram_emit_last_sample.range(31, 0);
    payload[FLK_LAST_SAMPLE_HIGH_WORD] =
        histogram_emit_last_sample.range(63, 32);
  histogram_words:
    for (int phase = 0; phase < FLK_PHASES; ++phase) {
      for (int offset = 0; offset < FLK_BINS_PER_PACKET; ++offset) {
#pragma HLS PIPELINE II=1
        const ap_uint<10> bin = base + offset;
        const int word = FLK_HISTOGRAM_WORD +
                         phase * FLK_BINS_PER_PACKET + offset;
        if (bin < FLK_CLASSIFIER_BINS) {
          payload[word] = histogram[histogram_emit_bank][phase][bin];
          histogram[histogram_emit_bank][phase][bin] = 0;
        }
      }
    }
    emit_payload(payload, m_flk);
    if (histogram_emit_chunk == FLK_CLASSIFIER_CHUNKS - 1) {
      histogram_emit_active = 0;
      histogram_emit_chunk = 0;
    } else {
      histogram_emit_chunk += 1;
    }
  }
}
