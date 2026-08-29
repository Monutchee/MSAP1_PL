#include "mains_signal_engine.hpp"

#include <array>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <vector>

namespace {

int failures = 0;

#define CHECK(condition, message)                                           \
  do {                                                                      \
    if (!(condition)) {                                                     \
      std::fprintf(stderr, "FAIL: %s\n", message);                         \
      ++failures;                                                           \
    }                                                                       \
  } while (0)

struct Packet {
  std::uint32_t word[MCS_PAYLOAD_WORDS]{};
};

mains_signal_input_beat_t make_frame(
    std::uint64_t index, bool apply, std::uint32_t generation,
    std::uint32_t rate, double carrier_hz, double carrier_rms_uv,
    double adjacent_hz = 0.0, double adjacent_rms_uv = 0.0,
    bool malformed = false, std::uint8_t frame_mask = 0x7f) {
  constexpr double pi = 3.14159265358979323846;
  constexpr double fundamental_rms_uv = 120000000.0;
  const double time = static_cast<double>(index) / rate;
  mains_signal_input_beat_t beat = 0;
  for (int phase = 0; phase < MCS_PHASES; ++phase) {
    const double phase_angle = -2.0 * pi * static_cast<double>(phase) / 3.0;
    double sample_uv = fundamental_rms_uv * std::sqrt(2.0) *
        std::sin(2.0 * pi * 60.0 * time + phase_angle);
    sample_uv += carrier_rms_uv * std::sqrt(2.0) *
        std::sin(2.0 * pi * carrier_hz * time + 0.21);
    if (adjacent_hz > 0.0)
      sample_uv += adjacent_rms_uv * std::sqrt(2.0) *
          std::sin(2.0 * pi * adjacent_hz * time - 0.37);
    const std::int64_t sample_q16 =
        static_cast<std::int64_t>(std::llround(sample_uv * 65536.0));
    const int lane = phase == 0 ? MET_LANE_VA
                               : (phase == 1 ? MET_LANE_VB : MET_LANE_VC);
    beat.range(lane * MET_RMS_LANE_BITS + MET_RMS_LANE_BITS - 1,
               lane * MET_RMS_LANE_BITS) =
        ap_uint<MET_RMS_LANE_BITS>(ap_int<MET_RMS_LANE_BITS>(sample_q16));
  }
  beat.range(MCSIN_FRAME_MASK_LSB + 7, MCSIN_FRAME_MASK_LSB) = frame_mask;
  beat.bit(MCSIN_MALFORMED_BIT) = malformed;
  beat.bit(MCSIN_APPLY_BIT) = apply;
  beat.bit(MCSIN_ENABLE_BIT) = 1;
  beat.bit(MCSIN_LOCKED_BIT) = 1;
  beat.bit(MCSIN_FALLBACK_BIT) = 0;
  beat.range(MCSIN_GENERATION_LSB + 31, MCSIN_GENERATION_LSB) = generation;
  beat.range(MCSIN_SAMPLE_RATE_LSB + 31, MCSIN_SAMPLE_RATE_LSB) = rate;
  beat.range(MCSIN_PHASE_MASK_LSB + 7, MCSIN_PHASE_MASK_LSB) = 0x7;
  beat.range(MCSIN_CARRIER_MILLIHZ_LSB + 31,
             MCSIN_CARRIER_MILLIHZ_LSB) = 1000000U;
  beat.range(MCSIN_BANDWIDTH_MILLIHZ_LSB + 31,
             MCSIN_BANDWIDTH_MILLIHZ_LSB) = 20000U;
  beat.range(MCSIN_OBSERVATION_MS_LSB + 31,
             MCSIN_OBSERVATION_MS_LSB) = MCS_OBSERVATION_MS;
  beat.range(MCSIN_THRESHOLD_E4_LSB + 31, MCSIN_THRESHOLD_E4_LSB) = 50U;
  beat.range(MCSIN_REFERENCE_UV_LSB + 31, MCSIN_REFERENCE_UV_LSB) =
      120000000U;
  beat.range(MCSIN_SAMPLE_INDEX_LSB + 63, MCSIN_SAMPLE_INDEX_LSB) = index;
  return beat;
}

void drain(hls::stream<record_axis_t> &stream, std::vector<Packet> &packets) {
  while (!stream.empty()) {
    Packet packet{};
    for (int word = 0; word < MCS_PAYLOAD_WORDS; ++word) {
      CHECK(!stream.empty(), "MCS1 payload is never short");
      if (stream.empty())
        return;
      const record_axis_t beat = stream.read();
      packet.word[word] = beat.data.to_uint();
      CHECK(beat.keep == 0xf && beat.strb == 0xf,
            "MCS1 payload has full strobes");
      CHECK(beat.last == (word == MCS_PAYLOAD_WORDS - 1),
            "MCS1 TLAST is positional");
    }
    packets.push_back(packet);
  }
}

Packet run_window(std::uint32_t rate, bool apply, std::uint32_t generation,
                  double carrier_hz, double carrier_rms_uv,
                  double adjacent_hz, double adjacent_rms_uv,
                  std::uint64_t first,
                  hls::stream<mains_signal_input_beat_t> &input,
                  hls::stream<record_axis_t> &output) {
  std::vector<Packet> packets;
  const auto frames = rate / 5U;
  for (std::uint32_t offset = 0; offset < frames; ++offset) {
    input.write(make_frame(first + offset, apply, generation, rate,
                           carrier_hz, carrier_rms_uv,
                           adjacent_hz, adjacent_rms_uv));
    hls_mains_signal_engine(input, output);
    drain(output, packets);
  }
  CHECK(packets.size() == 1U, "one 200 ms window emits one MCS1 packet");
  return packets.empty() ? Packet{} : packets.front();
}

void check_detected(const Packet &packet, std::uint32_t rate,
                    std::uint32_t generation, std::uint64_t first,
                    std::uint32_t expected_millihz) {
  CHECK(packet.word[MCS_GENERATION_WORD] == generation, "generation echoed");
  CHECK(packet.word[MCS_SAMPLE_RATE_WORD] == rate, "sample rate echoed");
  CHECK(packet.word[MCS_PHASES_WORD] == 0x707U,
        "all configured phases are valid and detected");
  CHECK(packet.word[MCS_CONFIGURED_MILLIHZ_WORD] == 1000000U,
        "configured frequency echoed");
  const auto measured = packet.word[MCS_MEASURED_MILLIHZ_WORD];
  CHECK(measured + 1500U >= expected_millihz &&
            measured <= expected_millihz + 1500U,
        "measured carrier frequency is within 1.5 Hz");
  CHECK(packet.word[MCS_FIRST_SAMPLE_LOW_WORD] ==
            static_cast<std::uint32_t>(first),
        "first sample is exact");
  CHECK(packet.word[MCS_LAST_SAMPLE_LOW_WORD] ==
            static_cast<std::uint32_t>(first + rate / 5U - 1U),
        "last sample is exact");
  for (int phase = 0; phase < MCS_PHASES; ++phase) {
    const auto magnitude = packet.word[MCS_MAGNITUDE_UV_WORD + phase];
    CHECK(magnitude > 1170000U && magnitude < 1230000U,
          "carrier RMS magnitude is within 2.5 percent");
  }
}

}  // namespace

int main() {
  hls::stream<mains_signal_input_beat_t> input{"input"};
  hls::stream<record_axis_t> output{"output"};
  bool apply = false;
  std::uint32_t generation = 100U;
  std::uint64_t first = 0U;

  const std::array<std::uint32_t, 6> supported_rates =
      {4000U, 8000U, 16000U, 32000U, 64000U, 128000U};
  for (const auto rate : supported_rates) {
    apply = !apply;
    const auto packet = run_window(rate, apply, generation, 1000.0,
                                   1200000.0, 0.0, 0.0, first,
                                   input, output);
    check_detected(packet, rate, generation, first, 1000000U);
    first += rate / 5U;
    ++generation;
  }

  // A carrier one inner probe above the configured centre is recovered as
  // 1005 Hz rather than being folded into a general FFT bin.
  apply = !apply;
  auto detuned = run_window(32000U, apply, generation++, 1005.0,
                            1200000.0, 0.0, 0.0, first, input, output);
  check_detected(detuned, 32000U, generation - 1U, first, 1005000U);
  first += 6400U;

  // An adjacent +20 Hz tone is rejected from the configured passband and
  // appears at the dedicated background probe.
  apply = !apply;
  auto adjacent = run_window(32000U, apply, generation++, 0.0, 0.0,
                             1020.0, 2400000.0, first, input, output);
  CHECK((adjacent.word[MCS_PHASES_WORD] & 0x700U) == 0U,
        "adjacent tone does not satisfy the carrier threshold");
  for (int phase = 0; phase < MCS_PHASES; ++phase) {
    CHECK(adjacent.word[MCS_MAGNITUDE_UV_WORD + phase] < 50000U,
          "adjacent tone is rejected by the passband");
    CHECK(adjacent.word[MCS_BACKGROUND_UV_WORD + phase] > 2300000U,
          "adjacent tone reaches the background probe");
  }
  first += 6400U;

  // A discontinuity discards the partial observation and marks the first
  // subsequently complete window.
  apply = !apply;
  std::vector<Packet> gap_packets;
  for (std::uint32_t offset = 0; offset < 6500U; ++offset) {
    const auto index = first + offset + (offset >= 100U ? 1U : 0U);
    input.write(make_frame(index, apply, generation, 32000U,
                           1000.0, 1200000.0));
    hls_mains_signal_engine(input, output);
    drain(output, gap_packets);
  }
  CHECK(gap_packets.size() == 1U,
        "gap requires one complete replacement observation");
  if (!gap_packets.empty())
    CHECK((gap_packets.front().word[MCS_STATUS_WORD] &
           (1U << MCS_STATUS_DISCONTINUITY_BIT)) != 0U,
          "gap provenance reaches MCS1");

  // The default 1 kHz carrier is outside the strict Nyquist limit at 2 kSPS.
  apply = !apply;
  std::vector<Packet> invalid_rate;
  for (std::uint32_t offset = 0; offset < 400U; ++offset) {
    input.write(make_frame(offset, apply, generation + 1U, 2000U,
                           1000.0, 1200000.0));
    hls_mains_signal_engine(input, output);
    drain(output, invalid_rate);
  }
  CHECK(invalid_rate.empty(), "Nyquist-edge carrier is rejected");

  if (failures != 0) {
    std::fprintf(stderr, "%d MainsSignalEngine checks failed\n", failures);
    return 1;
  }
  std::puts("MainsSignalEngine per-rate, detuning, and rejection checks passed");
  return 0;
}
