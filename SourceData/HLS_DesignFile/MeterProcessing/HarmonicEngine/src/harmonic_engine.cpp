#include "harmonic_engine.hpp"

#include "metrology_math.hpp"
#include "metrology_trig.hpp"

namespace {

static const ap_uint<31> SQRT_TWO_Q30 = 1518500250u;

struct harmonic_context_fields_t {
  ap_uint<32> generation;
  ap_uint<32> sample_rate;
  ap_uint<32> sample_count;
  ap_uint<8> valid_mask;
  ap_uint<8> flags;
  ap_uint<8> nominal_hz;
  ap_uint<8> cycle_count;
  ap_uint<8> qualified_max;
  ap_uint<8> filter_profile;
  ap_uint<32> measured_millihz;
  ap_uint<64> first_sample;
  ap_uint<32> emit_drops;
  ap_uint<32> result_drops;
  ap_uint<32> scale_q16[HARMONIC_CHANNELS_V1];
};

void decode_context(const harmonic_context_t &word,
                    harmonic_context_fields_t &context) {
#pragma HLS INLINE off
  context.generation = word.range(HARMONIC_CTX_GENERATION_LSB + 31,
                                  HARMONIC_CTX_GENERATION_LSB);
  context.sample_rate = word.range(HARMONIC_CTX_SAMPLE_RATE_LSB + 31,
                                   HARMONIC_CTX_SAMPLE_RATE_LSB);
  context.sample_count = word.range(HARMONIC_CTX_SAMPLE_COUNT_LSB + 31,
                                    HARMONIC_CTX_SAMPLE_COUNT_LSB);
  context.valid_mask = word.range(HARMONIC_CTX_VALID_MASK_LSB + 7,
                                  HARMONIC_CTX_VALID_MASK_LSB);
  context.flags = word.range(HARMONIC_CTX_FLAGS_LSB + 7,
                             HARMONIC_CTX_FLAGS_LSB);
  context.nominal_hz = word.range(HARMONIC_CTX_NOMINAL_HZ_LSB + 7,
                                  HARMONIC_CTX_NOMINAL_HZ_LSB);
  context.cycle_count = word.range(HARMONIC_CTX_CYCLE_COUNT_LSB + 7,
                                   HARMONIC_CTX_CYCLE_COUNT_LSB);
  context.qualified_max = word.range(HARMONIC_CTX_QUALIFIED_MAX_LSB + 7,
                                     HARMONIC_CTX_QUALIFIED_MAX_LSB);
  context.filter_profile = word.range(HARMONIC_CTX_FILTER_PROFILE_LSB + 7,
                                      HARMONIC_CTX_FILTER_PROFILE_LSB);
  context.measured_millihz = word.range(
      HARMONIC_CTX_MEASURED_MILLIHZ_LSB + 31,
      HARMONIC_CTX_MEASURED_MILLIHZ_LSB);
  context.first_sample = word.range(HARMONIC_CTX_FIRST_SAMPLE_LSB + 63,
                                    HARMONIC_CTX_FIRST_SAMPLE_LSB);
  context.emit_drops = word.range(HARMONIC_CTX_EMIT_DROPS_LSB + 31,
                                  HARMONIC_CTX_EMIT_DROPS_LSB);
  context.result_drops = word.range(HARMONIC_CTX_RESULT_DROPS_LSB + 31,
                                    HARMONIC_CTX_RESULT_DROPS_LSB);
decode_scales:
  for (int channel = 0; channel < HARMONIC_CHANNELS_V1; ++channel) {
#pragma HLS PIPELINE II = 1
    const int lsb = HARMONIC_CTX_SCALE_LSB + channel * 32;
    context.scale_q16[channel] = word.range(lsb + 31, lsb);
  }
}

ap_uint<40> subgroup_magnitude(const ap_uint<50> energy,
                               const ap_uint<5> block_exponent,
                               const ap_uint<32> scale_q16,
                               ap_uint<1> &overflow) {
#pragma HLS INLINE off
  // XFFT BFP output is the DFT divided by 2^BLK_EXP.  A positive-frequency
  // complex coefficient becomes RMS counts through sqrt(2)/N.  Combining
  // the three subgroup bins before the root implements
  // sqrt(C[k-1]^2 + C[k]^2 + C[k+1]^2) with one root and one calibration.
  const ap_uint<128> root_input = ap_uint<128>(energy);
  const ap_uint<64> root = floor_sqrt_128(root_input);
  ap_uint<128> scaled = ap_uint<128>(root) * ap_uint<31>(SQRT_TWO_Q30);
  scaled *= ap_uint<32>(scale_q16);
  if (block_exponent < 32) {
    scaled <<= block_exponent;
  } else {
    overflow = 1;
  }
  // Q30 sqrt(2), Q16 calibration, and N=2^12.
  const ap_uint<128> micro_units = scaled >> 58;
  if (micro_units >= (ap_uint<128>(1) << HARMONIC_ENTRY_MAGNITUDE_BITS)) {
    overflow = 1;
    return ~ap_uint<40>(0);
  }
  return ap_uint<40>(micro_units);
}

ap_uint<64> pack_entry(const ap_uint<40> magnitude,
                       const ap_uint<20> angle_millidegrees,
                       const ap_uint<1> magnitude_valid,
                       const ap_uint<1> angle_valid) {
#pragma HLS INLINE
  ap_uint<64> entry = 0;
  entry.range(39, 0) = magnitude;
  entry.range(59, 40) = angle_millidegrees;
  entry[HARMONIC_ENTRY_MAGNITUDE_VALID_BIT] = magnitude_valid;
  entry[HARMONIC_ENTRY_ANGLE_VALID_BIT] = angle_valid;
  return entry;
}

}  // namespace

void hls_harmonic_engine(harmonic_context_stream_t &s_context,
                         harmonic_fft_axis_stream_t &s_fft,
                         record_axis_stream_t &m_records) {
#pragma HLS INTERFACE mode=axis port=s_context register_mode=off
#pragma HLS INTERFACE mode=axis port=s_fft register_mode=off
#pragma HLS INTERFACE mode=axis port=m_records register_mode=both
#pragma HLS INTERFACE mode=ap_ctrl_none port=return

  static ap_uint<32> family_sequence = 0;

  const harmonic_context_t context_word = s_context.read();
  harmonic_context_fields_t context{};
  decode_context(context_word, context);

  ap_uint<50> group_energy[HARMONIC_CHANNELS_V1][HARMONIC_MAX_ORDER_V1];
  ap_int<24> central_real[HARMONIC_CHANNELS_V1][HARMONIC_MAX_ORDER_V1];
  ap_int<24> central_imag[HARMONIC_CHANNELS_V1][HARMONIC_MAX_ORDER_V1];
  ap_uint<3> group_bins[HARMONIC_CHANNELS_V1][HARMONIC_MAX_ORDER_V1];
  ap_uint<64> packed_entries[HARMONIC_CHANNELS_V1][HARMONIC_MAX_ORDER_V1];
  ap_uint<5> block_exponent[HARMONIC_CHANNELS_V1];
  ap_uint<1> frame_error[HARMONIC_CHANNELS_V1];
#pragma HLS BIND_STORAGE variable=group_energy type=ram_2p impl=bram
#pragma HLS BIND_STORAGE variable=central_real type=ram_2p impl=bram
#pragma HLS BIND_STORAGE variable=central_imag type=ram_2p impl=bram
#pragma HLS BIND_STORAGE variable=group_bins type=ram_2p impl=bram
#pragma HLS BIND_STORAGE variable=packed_entries type=ram_2p impl=bram

clear_channels:
  for (int channel = 0; channel < HARMONIC_CHANNELS_V1; ++channel) {
    block_exponent[channel] = 0;
    frame_error[channel] = 0;
  clear_orders:
    for (int order = 0; order < HARMONIC_MAX_ORDER_V1; ++order) {
#pragma HLS PIPELINE II = 1
      group_energy[channel][order] = 0;
      central_real[channel][order] = 0;
      central_imag[channel][order] = 0;
      group_bins[channel][order] = 0;
    }
  }

read_channels:
  for (int channel = 0; channel < HARMONIC_CHANNELS_V1; ++channel) {
  read_fft_frame:
    for (int beat_index = 0; beat_index < HARMONIC_FFT_LENGTH; ++beat_index) {
#pragma HLS PIPELINE II = 1
      const harmonic_fft_axis_t beat = s_fft.read();
      const ap_uint<12> bin_index = beat.user.range(11, 0);
      const ap_uint<5> exponent = beat.user.range(
          HARMONIC_FFT_EXPONENT_LSB + HARMONIC_FFT_EXPONENT_BITS - 1,
          HARMONIC_FFT_EXPONENT_LSB);
      const ap_int<24> real = ap_int<24>(beat.data.range(23, 0));
      const ap_int<24> imag = ap_int<24>(beat.data.range(47, 24));

      if (beat_index == 0) {
        block_exponent[channel] = exponent;
      } else if (exponent != block_exponent[channel]) {
        frame_error[channel] = 1;
      }
      if ((beat.last != 0) != (beat_index == HARMONIC_FFT_LENGTH - 1)) {
        frame_error[channel] = 1;
      }
      if (bin_index >= HARMONIC_FFT_LENGTH) {
        frame_error[channel] = 1;
      }

      // The 4096-bin XFFT output may be bit-reversed, so XK_INDEX is the
      // authority. Directly map that index to its nearest 10/12-bin harmonic
      // center; scanning 127 candidate orders per beat would exceed the
      // 200 ms family cadence even at 100 MHz.
      const ap_uint<4> bin_spacing =
          context.cycle_count == 10 ? ap_uint<4>(10) : ap_uint<4>(12);
      const ap_uint<8> order = ap_uint<8>(
          (ap_uint<13>(bin_index) + (bin_spacing >> 1)) / bin_spacing);
      const ap_uint<13> center = ap_uint<13>(order) * bin_spacing;
      if (order >= 1 && order <= HARMONIC_MAX_ORDER_V1 &&
          bin_index + 1 >= center && bin_index <= center + 1) {
        const ap_uint<7> order_index = order - 1;
        const ap_uint<2> member = ap_uint<2>(bin_index + 1 - center);
        if (group_bins[channel][order_index][member]) {
          frame_error[channel] = 1;
        } else {
          group_bins[channel][order_index][member] = 1;
          const ap_int<48> real_square = real * real;
          const ap_int<48> imag_square = imag * imag;
          group_energy[channel][order_index] +=
              ap_uint<49>(real_square) + ap_uint<49>(imag_square);
          if (member == 1) {
            central_real[channel][order_index] = real;
            central_imag[channel][order_index] = imag;
          }
        }
      }
    }
  }

  const bool grid_locked = context.flags[HARMONIC_CTX_GRID_LOCKED_BIT] != 0;
  const bool conditioner_valid =
      context.flags[HARMONIC_CTX_CONDITIONER_VALID_BIT] != 0;
  const bool context_geometry_valid =
      (context.nominal_hz == 50 || context.nominal_hz == 60) &&
      ((context.nominal_hz == 50 && context.cycle_count == 10) ||
       (context.nominal_hz == 60 && context.cycle_count == 12)) &&
      context.sample_rate != 0 && context.sample_count != 0 &&
      context.qualified_max <= HARMONIC_MAX_ORDER_V1;

  bool all_fft_valid = context_geometry_valid;
check_frames:
  for (int channel = 0; channel < HARMONIC_CHANNELS_V1; ++channel) {
#pragma HLS PIPELINE off
    if (frame_error[channel]) {
      all_fft_valid = false;
    }
  }

  ap_int<32> reference_angle = 0;
  const bool reference_present =
      central_real[6][0] != 0 || central_imag[6][0] != 0;
  if (reference_present) {
    reference_angle = met_atan2_turns(ap_int<64>(central_imag[6][0]),
                                      ap_int<64>(central_real[6][0]));
  }

  bool arithmetic_overflow = false;
finalize_channels:
  for (int channel = 0; channel < HARMONIC_CHANNELS_V1; ++channel) {
  finalize_orders:
    for (int order_index = 0; order_index < HARMONIC_MAX_ORDER_V1;
         ++order_index) {
#pragma HLS PIPELINE off
      const bool channel_enabled = context.valid_mask[channel] != 0;
      const bool bins_complete = group_bins[channel][order_index] == 7;
      const bool magnitude_valid =
          channel_enabled && grid_locked && conditioner_valid &&
          all_fft_valid && bins_complete &&
          order_index + 1 <= context.qualified_max;
      ap_uint<1> overflow = 0;
      ap_uint<40> magnitude = 0;
      if (magnitude_valid) {
        magnitude = subgroup_magnitude(
            group_energy[channel][order_index], block_exponent[channel],
            context.scale_q16[channel], overflow);
      }
      arithmetic_overflow = arithmetic_overflow || overflow != 0;

      const bool central_present =
          central_real[channel][order_index] != 0 ||
          central_imag[channel][order_index] != 0;
      const bool angle_valid = magnitude_valid && !overflow &&
                               central_present && reference_present &&
                               context.valid_mask[6] != 0;
      ap_uint<20> angle_millidegrees = 0;
      if (angle_valid) {
        const ap_int<32> channel_angle = met_atan2_turns(
            ap_int<64>(central_imag[channel][order_index]),
            ap_int<64>(central_real[channel][order_index]));
        const ap_int<32> referenced =
            channel_angle - ap_int<32>(ap_uint<32>(reference_angle) *
                                       ap_uint<8>(order_index + 1));
        angle_millidegrees =
            ap_uint<20>(met_turns_to_millidegrees(referenced));
      }
      packed_entries[channel][order_index] =
          pack_entry(magnitude, angle_millidegrees,
                     magnitude_valid && !overflow, angle_valid);
    }
  }

  const ap_uint<32> sequence = family_sequence++;
emit_channels:
  for (int channel = 0; channel < HARMONIC_CHANNELS_V1; ++channel) {
  emit_chunks:
    for (int chunk = 0; chunk < HARMONIC_CHUNKS_PER_CHANNEL_V1; ++chunk) {
      record_image_t image;
      clear_record(image);

      const int first_order = chunk * HARMONIC_ORDERS_PER_RECORD + 1;
      const int remaining = HARMONIC_MAX_ORDER_V1 - first_order + 1;
      const int order_count =
          (remaining > HARMONIC_ORDERS_PER_RECORD)
              ? HARMONIC_ORDERS_PER_RECORD
              : remaining;

      ap_uint<32> status = 0;
      status[HARMONIC_STATUS_COMPLETE_BIT] = 1;
      status[HARMONIC_STATUS_GRID_LOCKED_BIT] = grid_locked;
      status[HARMONIC_STATUS_CONDITIONER_VALID_BIT] = conditioner_valid;
      status[HARMONIC_STATUS_FFT_VALID_BIT] = all_fft_valid;
      status[HARMONIC_STATUS_FULL_RANGE_BIT] =
          context.qualified_max == HARMONIC_MAX_ORDER_V1;
      status[HARMONIC_STATUS_FIRST_AFTER_DISCONTINUITY_BIT] =
          context.flags[HARMONIC_CTX_FIRST_AFTER_DISCONTINUITY_BIT];
      status[HARMONIC_STATUS_RATE_LIMITED_BIT] =
          context.flags[HARMONIC_CTX_RATE_LIMITED_BIT] ||
          context.qualified_max < HARMONIC_MAX_ORDER_V1;
      status[MREC_STATUS_ARITHMETIC_BIT] = arithmetic_overflow;

      fill_envelope(image, sequence, context.generation, context.sample_rate,
                    context.sample_count, context.valid_mask, status,
                    context.first_sample);
      image.word[MREC_EMIT_DROPS_WORD] = context.emit_drops;
      image.word[MREC_RESULT_DROPS_WORD] = context.result_drops;

      ap_uint<32> header = 0;
      header.range(2, 0) = channel;
      header.range(6, 3) = chunk;
      header.range(14, 7) = first_order;
      header.range(19, 15) = order_count;
      header.range(23, 20) = HARMONIC_CHUNKS_PER_CHANNEL_V1;
      header.range(31, 24) = HARMONIC_MAX_ORDER_V1;
      image.word[HARMONIC_HEADER_WORD] = header;
      image.word[HARMONIC_FREQUENCY_WORD] = context.measured_millihz;
      image.word[HARMONIC_METADATA_WORD] =
          ap_uint<32>(context.qualified_max) |
          (ap_uint<32>(context.nominal_hz) << 8) |
          (ap_uint<32>(context.cycle_count) << 16) |
          (ap_uint<32>(context.filter_profile) << 24);

    emit_entries:
      for (int entry_index = 0; entry_index < HARMONIC_ORDERS_PER_RECORD;
           ++entry_index) {
#pragma HLS PIPELINE off
        ap_uint<64> entry = 0;
        if (entry_index < order_count) {
          const int order_index = first_order + entry_index - 1;
          entry = packed_entries[channel][order_index];
        }
        image.word[HARMONIC_ENTRY_BASE_WORD + entry_index * 2] =
            entry.range(31, 0);
        image.word[HARMONIC_ENTRY_BASE_WORD + entry_index * 2 + 1] =
            entry.range(63, 32);
      }
      serialize_record<MREC_FORMAT_HARMONIC_V1>(image, m_records);
    }
  }
}
