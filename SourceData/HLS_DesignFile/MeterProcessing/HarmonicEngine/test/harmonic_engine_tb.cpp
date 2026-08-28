#include "harmonic_engine.hpp"

#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <string>
#include <vector>

namespace {

void require(bool condition, const std::string &message) {
  if (!condition) {
    std::cerr << "FAIL: " << message << '\n';
    std::exit(1);
  }
}

harmonic_context_t make_context(unsigned qualified_max = 127) {
  harmonic_context_t context = 0;
  context.range(HARMONIC_CTX_GENERATION_LSB + 31,
                HARMONIC_CTX_GENERATION_LSB) = 0x12345678u;
  context.range(HARMONIC_CTX_SAMPLE_RATE_LSB + 31,
                HARMONIC_CTX_SAMPLE_RATE_LSB) = 128000u;
  context.range(HARMONIC_CTX_SAMPLE_COUNT_LSB + 31,
                HARMONIC_CTX_SAMPLE_COUNT_LSB) = 25600u;
  context.range(HARMONIC_CTX_VALID_MASK_LSB + 7,
                HARMONIC_CTX_VALID_MASK_LSB) = 0x7fu;
  context[HARMONIC_CTX_FLAGS_LSB + HARMONIC_CTX_GRID_LOCKED_BIT] = 1;
  context[HARMONIC_CTX_FLAGS_LSB + HARMONIC_CTX_CONDITIONER_VALID_BIT] = 1;
  context.range(HARMONIC_CTX_NOMINAL_HZ_LSB + 7,
                HARMONIC_CTX_NOMINAL_HZ_LSB) = 50u;
  context.range(HARMONIC_CTX_CYCLE_COUNT_LSB + 7,
                HARMONIC_CTX_CYCLE_COUNT_LSB) = 10u;
  context.range(HARMONIC_CTX_QUALIFIED_MAX_LSB + 7,
                HARMONIC_CTX_QUALIFIED_MAX_LSB) = qualified_max;
  context.range(HARMONIC_CTX_FILTER_PROFILE_LSB + 7,
                HARMONIC_CTX_FILTER_PROFILE_LSB) = 1u;
  context.range(HARMONIC_CTX_MEASURED_MILLIHZ_LSB + 31,
                HARMONIC_CTX_MEASURED_MILLIHZ_LSB) = 50000u;
  context.range(HARMONIC_CTX_FIRST_SAMPLE_LSB + 63,
                HARMONIC_CTX_FIRST_SAMPLE_LSB) = 0x0000001200003456ull;
  for (int channel = 0; channel < HARMONIC_CHANNELS_V1; ++channel) {
    const int lsb = HARMONIC_CTX_SCALE_LSB + channel * 32;
    context.range(lsb + 31, lsb) = 0x00010000u;  // 1 micro-unit/count
  }
  return context;
}

void write_fft_frames(harmonic_fft_axis_stream_t &stream,
                      bool inject_structural_fault = false) {
  for (int channel = 0; channel < HARMONIC_CHANNELS_V1; ++channel) {
    for (int bin = 0; bin < HARMONIC_FFT_LENGTH; ++bin) {
      harmonic_fft_axis_t beat;
      beat.data = 0;
      beat.user = 0;
      beat.user.range(11, 0) = bin;
      beat.user.range(HARMONIC_FFT_EXPONENT_LSB +
                          HARMONIC_FFT_EXPONENT_BITS - 1,
                      HARMONIC_FFT_EXPONENT_LSB) = 0;
      if (inject_structural_fault && channel == 0 && bin == 0) {
        beat.user[HARMONIC_FFT_FAULT_BIT] = 1;
      }
      beat.last = bin == HARMONIC_FFT_LENGTH - 1;

      // Every fundamental is +30 degrees; Va (CH6) is the global reference.
      // CH0's third line is absolute 180 degrees, hence +90 after subtracting
      // 3*Va1. CH1's third is absolute zero, hence 270 degrees after the same
      // wrapped subtraction.
      ap_int<24> real = 0;
      ap_int<24> imag = 0;
      if (bin == 10) {
        real = 2508269;
        imag = 1448150;
      }
      if (channel == 0 && bin == 30) {
        real = -1448150;
        imag = 0;
      }
      if (channel == 1 && bin == 30) {
        real = 1448150;
        imag = 0;
      }
      if (channel == 0 && bin == 29) {
        real = 1448150;
      }
      beat.data.range(23, 0) = ap_uint<24>(real);
      beat.data.range(47, 24) = ap_uint<24>(imag);
      stream.write(beat);
    }
  }
}

std::vector<std::uint32_t> run_family(unsigned qualified_max = 127,
                                      bool inject_structural_fault = false) {
  harmonic_context_stream_t context_stream;
  harmonic_fft_axis_stream_t fft_stream;
  record_axis_stream_t record_stream;
  context_stream.write(make_context(qualified_max));
  write_fft_frames(fft_stream, inject_structural_fault);
  hls_harmonic_engine(context_stream, fft_stream, record_stream);

  std::vector<std::uint32_t> words;
  while (!record_stream.empty()) {
    const record_axis_t beat = record_stream.read();
    require(beat.keep == 0xf && beat.strb == 0xf, "record byte enables");
    require((beat.last != 0) == (words.size() % 64 == 63),
            "TLAST position");
    words.push_back(static_cast<std::uint32_t>(beat.data));
  }
  return words;
}

std::uint64_t entry_at(const std::vector<std::uint32_t> &words,
                       unsigned record, unsigned entry) {
  const std::size_t base = record * 64 + 16 + entry * 2;
  return std::uint64_t(words[base]) | (std::uint64_t(words[base + 1]) << 32);
}

}  // namespace

int main() {
  const auto words = run_family();
  require(words.size() == 42u * 64u, "42 fixed records per family");
  for (unsigned record = 0; record < 42; ++record) {
    const std::size_t base = record * 64;
    require(words[base] == MREC_MAGIC, "record magic");
    require(words[base + 1] == MREC_FORMAT_HARMONIC_V1, "record format");
    require(words[base + 2] == MREC_BYTES, "record size");
    require(words[base + 3] == 0, "shared family sequence");
    require(words[base + 4] == 0x12345678u, "generation");
    require(words[base + 14] == 50000u, "measured frequency");
  }

  const std::uint32_t first_header = words[13];
  require((first_header & 0x7u) == 0u, "first channel");
  require(((first_header >> 7) & 0xffu) == 1u, "first order");
  require(((first_header >> 15) & 0x1fu) == 24u, "full chunk count");
  require(((first_header >> 20) & 0xfu) == 6u, "family chunk count");
  require((first_header >> 24) == 127u, "maximum order");

  const std::uint64_t fundamental = entry_at(words, 0, 0);
  require(((fundamental >> 60) & 1u) != 0u, "fundamental magnitude valid");
  require(((fundamental >> 61) & 1u) != 0u, "fundamental angle valid");
  require(((fundamental >> 40) & 0xfffffu) == 0u,
          "CH0 fundamental references Va");
  const auto fundamental_magnitude = fundamental & ((1ull << 40) - 1ull);
  require(fundamental_magnitude >= 999u && fundamental_magnitude <= 1000u,
          "fundamental RMS normalization");

  const std::uint64_t third = entry_at(words, 0, 2);
  require(((third >> 60) & 1u) != 0u, "third subgroup magnitude valid");
  require(((third >> 61) & 1u) != 0u, "third central angle valid");
  const auto third_angle = (third >> 40) & 0xfffffu;
  require(third_angle >= 89999u && third_angle <= 90001u,
          "third angle is +90 degrees");
  const auto third_magnitude = third & ((1ull << 40) - 1ull);
  require(third_magnitude >= 706u && third_magnitude <= 708u,
          "subgroup combines center and adjacent energy");

  const std::uint64_t wrapped_third = entry_at(words, 6, 2);
  require(((wrapped_third >> 61) & 1u) != 0u,
          "CH1 third central angle valid");
  const auto wrapped_angle = (wrapped_third >> 40) & 0xfffffu;
  require(wrapped_angle >= 269999u && wrapped_angle <= 270001u,
          "negative referenced phase wraps onto [0,360)");

  const auto limited = run_family(2);
  const std::uint64_t limited_third = entry_at(limited, 0, 2);
  require(((limited_third >> 60) & 1u) == 0u,
          "order above qualified passband is unavailable");
  require((limited[8] & (1u << HARMONIC_STATUS_RATE_LIMITED_BIT)) != 0u,
          "rate-limited family status");
  require(limited[3] == 1u, "sequence increments once per family");

  const auto faulted = run_family(127, true);
  require((faulted[8] & (1u << HARMONIC_STATUS_FFT_VALID_BIT)) == 0u,
          "MeterCore/XFFT structural fault invalidates the family");
  require(((entry_at(faulted, 0, 0) >> 60) & 1u) == 0u,
          "faulted FFT cannot publish a magnitude");

  std::cout << "HarmonicEngine contract and subgroup golden PASS\n";
  return 0;
}
