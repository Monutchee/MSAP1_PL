#include "mains_signal_engine.hpp"

#include "metrology_stats.hpp"
#include "metrology_trig.hpp"

namespace {

static const int kVoltageLane[MCS_PHASES] = {
    MET_LANE_VA, MET_LANE_VB, MET_LANE_VC};

inline bool supported_sample_rate(ap_uint<32> rate) {
#pragma HLS INLINE
  return rate == 2000U || rate == 4000U || rate == 8000U ||
         rate == 16000U || rate == 32000U || rate == 64000U ||
         rate == 128000U;
}

inline ap_uint<32> phase_step_q32(ap_uint<32> carrier_millihz,
                                  ap_uint<32> bandwidth_millihz,
                                  int offset_quarters,
                                  ap_uint<32> sample_rate_hz) {
#pragma HLS INLINE off
  const ap_int<67> frequency_quarter_millihz =
      ap_int<67>(carrier_millihz) * 4 +
      ap_int<67>(bandwidth_millihz) * offset_quarters;
  if (frequency_quarter_millihz <= 0 || sample_rate_hz == 0)
    return 0;
  const ap_uint<100> numerator =
      ap_uint<100>(frequency_quarter_millihz) << 32;
  const ap_uint<64> denominator = ap_uint<64>(sample_rate_hz) * 4000U;
  return ap_uint<32>((numerator + denominator / 2U) / denominator);
}

inline ap_uint<32> magnitude_microvolts(ap_int<104> re_sum,
                                        ap_int<104> im_sum,
                                        ap_uint<32> count,
                                        ap_uint<1> &overflow) {
#pragma HLS INLINE off
  const ap_int<64> re_q16 = met_phasor_counts(ap_int<128>(re_sum), count);
  const ap_int<64> im_q16 = met_phasor_counts(ap_int<128>(im_sum), count);
  const ap_uint<64> rms_q16 = met_phasor_rms_q16(re_q16, im_q16);
  const ap_uint<65> rounded = ap_uint<65>(rms_q16) + 0x8000U;
  const ap_uint<49> microvolts = rounded >> 16;
  if ((microvolts >> 32) != 0U) {
    overflow = 1;
    return 0xffffffffU;
  }
  return ap_uint<32>(microvolts);
}

inline void emit_payload(const ap_uint<32> payload[MCS_PAYLOAD_WORDS],
                         hls::stream<record_axis_t> &output) {
#pragma HLS INLINE off
emit_words:
  for (int word = 0; word < MCS_PAYLOAD_WORDS; ++word) {
#pragma HLS PIPELINE II=1
    record_axis_t beat{};
    beat.data = payload[word];
    beat.keep = MREC_KEEP_ALL;
    beat.strb = MREC_KEEP_ALL;
    beat.last = word == MCS_PAYLOAD_WORDS - 1 ? ap_uint<1>(1)
                                               : ap_uint<1>(0);
    output.write(beat);
  }
}

inline ap_uint<32> status_word(ap_uint<1> enabled, ap_uint<1> locked,
                               ap_uint<1> fallback,
                               ap_uint<1> discontinuity,
                               ap_uint<1> arithmetic,
                               ap_uint<1> background_dominant) {
#pragma HLS INLINE
  return (ap_uint<32>(enabled) << MCS_STATUS_ENABLED_BIT) |
         (ap_uint<32>(locked) << MCS_STATUS_LOCKED_BIT) |
         (ap_uint<32>(fallback) << MCS_STATUS_FALLBACK_BIT) |
         (ap_uint<32>(discontinuity) << MCS_STATUS_DISCONTINUITY_BIT) |
         (ap_uint<32>(arithmetic) << MCS_STATUS_ARITHMETIC_BIT) |
         (ap_uint<32>(background_dominant)
          << MCS_STATUS_BACKGROUND_DOMINANT_BIT);
}

}  // namespace

void hls_mains_signal_engine(hls::stream<mains_signal_input_beat_t> &s_frame,
                             hls::stream<record_axis_t> &m_mcs) {
#pragma HLS INTERFACE mode=axis port=s_frame register_mode=off
#pragma HLS INTERFACE mode=axis port=m_mcs
#pragma HLS INTERFACE mode=ap_ctrl_none port=return

  static ap_uint<1> apply_seen = 0;
  static ap_uint<1> configured_enable = 0;
  static ap_uint<1> engine_ready = 0;
  static ap_uint<32> generation = 0;
  static ap_uint<32> sample_rate_hz = 0;
  static ap_uint<3> configured_phase_mask = 0;
  static ap_uint<32> carrier_millihz = 0;
  static ap_uint<32> bandwidth_millihz = 0;
  static ap_uint<32> observation_ms = MCS_OBSERVATION_MS;
  static ap_uint<32> threshold_e4 = 0;
  static ap_uint<32> reference_microvolts = 0;
  static ap_uint<32> observation_samples = 0;

  static ap_uint<32> probe_phase[MCS_PROBES];
  static ap_uint<32> probe_step[MCS_PROBES];
#pragma HLS ARRAY_PARTITION variable=probe_phase complete
#pragma HLS ARRAY_PARTITION variable=probe_step complete
  static ap_int<104> re_sum[MCS_PHASES][MCS_PROBES];
  static ap_int<104> im_sum[MCS_PHASES][MCS_PROBES];
#pragma HLS ARRAY_PARTITION variable=re_sum complete dim=1
#pragma HLS ARRAY_PARTITION variable=im_sum complete dim=1
  static ap_uint<32> window_count = 0;
  static ap_uint<3> window_valid_mask = 0;
  static ap_uint<1> window_locked = 1;
  static ap_uint<1> window_fallback = 0;
  static ap_uint<64> window_first_sample = 0;
  static ap_uint<64> last_input_sample = 0;
  static ap_uint<1> have_last_input_sample = 0;
  static ap_uint<1> pending_discontinuity = 1;
  static ap_uint<32> sequence = 0;

  if (s_frame.empty())
    return;
  const mains_signal_input_beat_t input = s_frame.read();

  const ap_uint<1> input_apply = input.bit(MCSIN_APPLY_BIT);
  if (input_apply != apply_seen) {
    apply_seen = input_apply;
    configured_enable = input.bit(MCSIN_ENABLE_BIT);
    generation = input.range(MCSIN_GENERATION_LSB + 31,
                             MCSIN_GENERATION_LSB);
    sample_rate_hz = input.range(MCSIN_SAMPLE_RATE_LSB + 31,
                                 MCSIN_SAMPLE_RATE_LSB);
    configured_phase_mask = input.range(MCSIN_PHASE_MASK_LSB + 2,
                                        MCSIN_PHASE_MASK_LSB);
    carrier_millihz = input.range(MCSIN_CARRIER_MILLIHZ_LSB + 31,
                                  MCSIN_CARRIER_MILLIHZ_LSB);
    bandwidth_millihz = input.range(MCSIN_BANDWIDTH_MILLIHZ_LSB + 31,
                                    MCSIN_BANDWIDTH_MILLIHZ_LSB);
    observation_ms = input.range(MCSIN_OBSERVATION_MS_LSB + 31,
                                 MCSIN_OBSERVATION_MS_LSB);
    threshold_e4 = input.range(MCSIN_THRESHOLD_E4_LSB + 31,
                               MCSIN_THRESHOLD_E4_LSB);
    reference_microvolts = input.range(MCSIN_REFERENCE_UV_LSB + 31,
                                       MCSIN_REFERENCE_UV_LSB);
    const ap_uint<64> nyquist_millihz =
        ap_uint<64>(sample_rate_hz) * 500U;
    engine_ready = configured_enable == 1 && generation != 0 &&
                   supported_sample_rate(sample_rate_hz) &&
                   configured_phase_mask != 0 && carrier_millihz != 0 &&
                   bandwidth_millihz >= 4 &&
                   bandwidth_millihz < carrier_millihz &&
                   ap_uint<64>(carrier_millihz) + bandwidth_millihz <
                       nyquist_millihz &&
                   ap_uint<64>(carrier_millihz) + bandwidth_millihz <
                       12500000U &&
                   observation_ms == MCS_OBSERVATION_MS &&
                   threshold_e4 <= 0xffffU && reference_microvolts != 0;
    observation_samples = sample_rate_hz / 5U;
    window_count = 0;
    window_valid_mask = configured_phase_mask;
    window_locked = 1;
    window_fallback = 0;
    have_last_input_sample = 0;
    pending_discontinuity = 1;
reset_apply_probes:
    for (int probe = 0; probe < MCS_PROBES; ++probe) {
#pragma HLS UNROLL
      probe_phase[probe] = 0;
      probe_step[probe] = phase_step_q32(
          carrier_millihz, bandwidth_millihz,
          MCS_PROBE_OFFSET_QUARTERS[probe], sample_rate_hz);
      for (int phase = 0; phase < MCS_PHASES; ++phase) {
#pragma HLS UNROLL
        re_sum[phase][probe] = 0;
        im_sum[phase][probe] = 0;
      }
    }
  }

  if (configured_enable == 0 || engine_ready == 0)
    return;

  const ap_uint<64> sample_index = input.range(MCSIN_SAMPLE_INDEX_LSB + 63,
                                               MCSIN_SAMPLE_INDEX_LSB);
  const ap_uint<1> malformed = input.bit(MCSIN_MALFORMED_BIT);
  const ap_uint<1> sequence_gap = have_last_input_sample == 1 &&
      sample_index != ap_uint<64>(last_input_sample + 1);
  last_input_sample = sample_index;
  have_last_input_sample = 1;
  if (malformed == 1 || sequence_gap == 1) {
    window_count = 0;
    window_valid_mask = configured_phase_mask;
    window_locked = 1;
    window_fallback = 0;
    pending_discontinuity = 1;
reset_gap_probes:
    for (int probe = 0; probe < MCS_PROBES; ++probe) {
#pragma HLS UNROLL
      probe_phase[probe] = 0;
      for (int phase = 0; phase < MCS_PHASES; ++phase) {
#pragma HLS UNROLL
        re_sum[phase][probe] = 0;
        im_sum[phase][probe] = 0;
      }
    }
    if (malformed == 1)
      return;
  }

  if (window_count == 0)
    window_first_sample = sample_index;
  const ap_uint<8> frame_mask = input.range(MCSIN_FRAME_MASK_LSB + 7,
                                            MCSIN_FRAME_MASK_LSB);
  window_locked = window_locked && input.bit(MCSIN_LOCKED_BIT);
  window_fallback = window_fallback || input.bit(MCSIN_FALLBACK_BIT);

accumulate_probes:
  for (int probe = 0; probe < MCS_PROBES; ++probe) {
#pragma HLS PIPELINE off
    const ap_int<39> cosine = met_cos_q32(probe_phase[probe]);
    const ap_int<39> sine = met_sin_q32(probe_phase[probe]);
    for (int phase = 0; phase < MCS_PHASES; ++phase) {
#pragma HLS PIPELINE off
      const bool phase_valid = configured_phase_mask[phase] == 1 &&
          frame_mask[kVoltageLane[phase]] == 1;
      if (!phase_valid) {
        window_valid_mask[phase] = 0;
        continue;
      }
      const int lsb = kVoltageLane[phase] * MET_RMS_LANE_BITS;
      const met_q16_t sample = met_q16_t(
          ap_uint<MET_RMS_LANE_BITS>(input.range(
              lsb + MET_RMS_LANE_BITS - 1, lsb)));
      re_sum[phase][probe] += ap_int<87>(sample) * cosine;
      im_sum[phase][probe] -= ap_int<87>(sample) * sine;
    }
    probe_phase[probe] += probe_step[probe];
  }

  window_count += 1;
  if (window_count < observation_samples)
    return;

  ap_uint<32> magnitude[MCS_PHASES][MCS_PROBES];
#pragma HLS ARRAY_PARTITION variable=magnitude complete dim=1
  ap_uint<1> arithmetic_overflow = 0;
finalize_magnitudes:
  for (int phase = 0; phase < MCS_PHASES; ++phase) {
    for (int probe = 0; probe < MCS_PROBES; ++probe) {
#pragma HLS PIPELINE off
      magnitude[phase][probe] = magnitude_microvolts(
          re_sum[phase][probe], im_sum[phase][probe], window_count,
          arithmetic_overflow);
    }
  }

  ap_uint<32> carrier_magnitude[MCS_PHASES];
  ap_uint<32> background_magnitude[MCS_PHASES];
#pragma HLS ARRAY_PARTITION variable=carrier_magnitude complete
#pragma HLS ARRAY_PARTITION variable=background_magnitude complete
  ap_uint<64> probe_weight[5];
#pragma HLS ARRAY_PARTITION variable=probe_weight complete
clear_weights:
  for (int inner = 0; inner < 5; ++inner) {
#pragma HLS UNROLL
    probe_weight[inner] = 0;
  }
  ap_uint<1> background_dominant = 0;
select_magnitudes:
  for (int phase = 0; phase < MCS_PHASES; ++phase) {
#pragma HLS UNROLL
    ap_uint<32> maximum = 0;
    for (int inner = 0; inner < 5; ++inner) {
#pragma HLS UNROLL
      const ap_uint<32> value = magnitude[phase][inner + 1];
      if (value > maximum)
        maximum = value;
      if (window_valid_mask[phase] == 1)
        probe_weight[inner] += value;
    }
    carrier_magnitude[phase] = maximum;
    background_magnitude[phase] =
        magnitude[phase][0] > magnitude[phase][6]
            ? magnitude[phase][0] : magnitude[phase][6];
    if (window_valid_mask[phase] == 1 &&
        background_magnitude[phase] > carrier_magnitude[phase])
      background_dominant = 1;
  }

  ap_uint<3> detected_mask = 0;
  const ap_uint<64> threshold_microvolts =
      (ap_uint<64>(reference_microvolts) * threshold_e4 + 9999U) / 10000U;
detect_phases:
  for (int phase = 0; phase < MCS_PHASES; ++phase) {
#pragma HLS UNROLL
    if (window_valid_mask[phase] == 1 &&
        carrier_magnitude[phase] >= threshold_microvolts)
      detected_mask[phase] = 1;
  }

  ap_uint<32> measured_millihz = carrier_millihz;
  ap_uint<67> weight_total = 0;
  ap_int<100> weighted_offset = 0;
frequency_centroid:
  for (int inner = 0; inner < 5; ++inner) {
#pragma HLS UNROLL
    weight_total += probe_weight[inner];
    weighted_offset += ap_int<100>(probe_weight[inner]) *
        ap_int<4>(inner - 2) * ap_int<33>(bandwidth_millihz);
  }
  if (detected_mask != 0 && weight_total != 0) {
    const ap_int<100> divisor = ap_int<100>(weight_total) * 4;
    const ap_int<100> offset = weighted_offset / divisor;
    const ap_int<65> measured = ap_int<65>(carrier_millihz) + offset;
    if (measured < 0) {
      measured_millihz = 0;
      arithmetic_overflow = 1;
    } else if (measured > 0xffffffffLL) {
      measured_millihz = 0xffffffffU;
      arithmetic_overflow = 1;
    } else {
      measured_millihz = ap_uint<32>(measured);
    }
  }

  ap_uint<32> payload[MCS_PAYLOAD_WORDS];
#pragma HLS ARRAY_PARTITION variable=payload complete
clear_payload:
  for (int word = 0; word < MCS_PAYLOAD_WORDS; ++word) {
#pragma HLS UNROLL
    payload[word] = 0;
  }
  sequence += 1;
  payload[MCS_SEQUENCE_WORD] = sequence;
  payload[MCS_GENERATION_WORD] = generation;
  payload[MCS_SAMPLE_RATE_WORD] = sample_rate_hz;
  payload[MCS_STATUS_WORD] = status_word(
      engine_ready, window_locked, window_fallback, pending_discontinuity,
      arithmetic_overflow, background_dominant);
  payload[MCS_PHASES_WORD] = ap_uint<32>(window_valid_mask) |
                             (ap_uint<32>(detected_mask) << 8);
  payload[MCS_CONFIGURED_MILLIHZ_WORD] = carrier_millihz;
  payload[MCS_MEASURED_MILLIHZ_WORD] = measured_millihz;
  payload[MCS_BANDWIDTH_MILLIHZ_WORD] = bandwidth_millihz;
  payload[MCS_OBSERVATION_MS_WORD] = observation_ms;
  payload[MCS_FIRST_SAMPLE_LOW_WORD] = window_first_sample.range(31, 0);
  payload[MCS_FIRST_SAMPLE_HIGH_WORD] = window_first_sample.range(63, 32);
  payload[MCS_LAST_SAMPLE_LOW_WORD] = sample_index.range(31, 0);
  payload[MCS_LAST_SAMPLE_HIGH_WORD] = sample_index.range(63, 32);
copy_results:
  for (int phase = 0; phase < MCS_PHASES; ++phase) {
#pragma HLS UNROLL
    payload[MCS_MAGNITUDE_UV_WORD + phase] = carrier_magnitude[phase];
    payload[MCS_BACKGROUND_UV_WORD + phase] = background_magnitude[phase];
  }
  payload[MCS_THRESHOLD_E4_WORD] = threshold_e4;
  emit_payload(payload, m_mcs);

  window_count = 0;
  window_valid_mask = configured_phase_mask;
  window_locked = 1;
  window_fallback = 0;
  pending_discontinuity = 0;
clear_window:
  for (int phase = 0; phase < MCS_PHASES; ++phase) {
    for (int probe = 0; probe < MCS_PROBES; ++probe) {
#pragma HLS UNROLL
      re_sum[phase][probe] = 0;
      im_sum[phase][probe] = 0;
    }
  }
}
