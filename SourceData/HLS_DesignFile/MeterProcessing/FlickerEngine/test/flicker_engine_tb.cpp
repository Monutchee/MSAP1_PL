#include "flicker_engine.hpp"

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
  std::uint32_t word[FLK_PAYLOAD_WORDS]{};
};

flicker_input_beat_t make_frame(std::uint64_t index, bool apply,
                                std::uint32_t generation,
                                std::uint16_t lamp_voltage,
                                std::uint8_t nominal_hz,
                                std::uint32_t reference_microvolts,
                                double modulation_hz,
                                double modulation_percent,
                                bool malformed = false) {
  constexpr double pi = 3.14159265358979323846;
  flicker_input_beat_t beat = 0;
  const double time = static_cast<double>(index) / FLK_INTERNAL_RATE_HZ;
  for (int phase = 0; phase < FLK_PHASES; ++phase) {
    const double phase_angle = -2.0 * pi * static_cast<double>(phase) / 3.0;
    const double modulation =
        1.0 + modulation_percent * 0.01 *
                  std::sin(2.0 * pi * modulation_hz * time);
    const double sample_microvolts =
        static_cast<double>(reference_microvolts) * std::sqrt(2.0) *
        modulation *
        std::sin(2.0 * pi * static_cast<double>(nominal_hz) * time +
                 phase_angle);
    const std::int64_t sample_q16 =
        static_cast<std::int64_t>(std::llround(sample_microvolts * 65536.0));
    const int lane = phase == 0 ? MET_LANE_VA
                               : (phase == 1 ? MET_LANE_VB : MET_LANE_VC);
    beat.range(FLKIN_SAMPLES_LSB + lane * MET_RMS_LANE_BITS +
                   MET_RMS_LANE_BITS - 1,
               FLKIN_SAMPLES_LSB + lane * MET_RMS_LANE_BITS) =
        ap_uint<MET_RMS_LANE_BITS>(ap_int<MET_RMS_LANE_BITS>(sample_q16));
  }
  beat.range(FLKIN_FRAME_MASK_LSB + 7, FLKIN_FRAME_MASK_LSB) = 0x7f;
  beat.bit(FLKIN_MALFORMED_BIT) = malformed;
  beat.bit(FLKIN_APPLY_BIT) = apply;
  beat.bit(FLKIN_ENABLE_BIT) = 1;
  beat.bit(FLKIN_LOCKED_BIT) = 1;
  beat.bit(FLKIN_FALLBACK_BIT) = 0;
  beat.range(FLKIN_GENERATION_LSB + 31, FLKIN_GENERATION_LSB) = generation;
  beat.range(FLKIN_SAMPLE_RATE_LSB + 31, FLKIN_SAMPLE_RATE_LSB) =
      FLK_INTERNAL_RATE_HZ;
  beat.range(FLKIN_PHASE_MASK_LSB + 7, FLKIN_PHASE_MASK_LSB) = 0x7;
  beat.range(FLKIN_LAMP_VOLTAGE_LSB + 15, FLKIN_LAMP_VOLTAGE_LSB) =
      lamp_voltage;
  beat.range(FLKIN_NOMINAL_HZ_LSB + 7, FLKIN_NOMINAL_HZ_LSB) = nominal_hz;
  beat.range(FLKIN_LIVE_CADENCE_LSB + 31, FLKIN_LIVE_CADENCE_LSB) = 1000;
  // A short direct-HLS interval makes the lossless 512-bin transport
  // observable in cosim. R5C0 accepts only the normative 600-second value.
  beat.range(FLKIN_PST_INTERVAL_LSB + 31, FLKIN_PST_INTERVAL_LSB) = 2;
  beat.range(FLKIN_REFERENCE_UV_LSB + 31, FLKIN_REFERENCE_UV_LSB) =
      reference_microvolts;
  beat.range(FLKIN_SAMPLE_INDEX_LSB + 63, FLKIN_SAMPLE_INDEX_LSB) = index;
  return beat;
}

void drain(hls::stream<record_axis_t> &stream, std::vector<Packet> &packets) {
  while (!stream.empty()) {
    Packet packet{};
    for (int word = 0; word < FLK_PAYLOAD_WORDS; ++word) {
      CHECK(!stream.empty(), "FLK1 payload is never short");
      if (stream.empty()) return;
      const record_axis_t beat = stream.read();
      packet.word[word] = beat.data.to_uint();
      CHECK(beat.keep == 0xf && beat.strb == 0xf,
            "FLK1 payload has full byte strobes");
      CHECK(beat.last == (word == FLK_PAYLOAD_WORDS - 1),
            "FLK1 TLAST is positional");
    }
    packets.push_back(packet);
  }
}

std::vector<Packet> run_point(bool apply, std::uint32_t generation,
                              std::uint16_t lamp_voltage,
                              std::uint8_t nominal_hz,
                              double modulation_hz,
                              double modulation_percent,
                              std::uint64_t first_index,
                              std::uint32_t seconds,
                              hls::stream<flicker_input_beat_t> &input,
                              hls::stream<record_axis_t> &output) {
  std::vector<Packet> packets;
  const std::uint32_t frames = seconds * FLK_INTERNAL_RATE_HZ;
  for (std::uint32_t offset = 0; offset < frames; ++offset) {
    input.write(make_frame(first_index + offset, apply, generation,
                           lamp_voltage, nominal_hz,
                           static_cast<std::uint32_t>(lamp_voltage) * 1000000U,
                           modulation_hz, modulation_percent));
    hls_flicker_engine(input, output);
    drain(output, packets);
  }
  return packets;
}

void check_standard_point(const std::vector<Packet> &packets,
                          const char *description) {
  std::uint32_t settled_live = 0;
  for (const Packet &packet : packets) {
    if (packet.word[FLK_KIND_WORD] != FLK_KIND_LIVE ||
        (packet.word[FLK_STATUS_WORD] &
         (1U << FLK_STATUS_SETTLING_BIT)) != 0U)
      continue;
    ++settled_live;
    CHECK(packet.word[FLK_PHASE_MASK_WORD] == 0x7,
          "settled IEC vector keeps all phases valid");
    for (int phase = 0; phase < FLK_PHASES; ++phase) {
      const double peak =
          static_cast<double>(packet.word[FLK_PINST_BASE_WORD + phase]) /
          65536.0;
      if (!(peak > 0.70 && peak < 1.35)) {
        std::fprintf(stderr, "FAIL: %s phase %d Pinst=%f\n", description,
                     phase, peak);
        ++failures;
      }
    }
  }
  CHECK(settled_live >= 2, "standard point produces settled live Pinst");
}

}  // namespace

int main() {
  hls::stream<flicker_input_beat_t> input{"input"};
  hls::stream<record_axis_t> output{"output"};

  ap_uint<1> outside = 0;
  CHECK(flicker_histogram_bin_q16(1U << 8, outside) == 0 && outside == 0,
        "classifier lower boundary is exact");
  CHECK(flicker_histogram_bin_q16((1U << 24) - 1U, outside) == 511 &&
            outside == 0,
        "classifier upper interior boundary is exact");
  CHECK(flicker_histogram_bin_q16(0, outside) == 0 && outside == 1,
        "classifier clamps under-range values with provenance");

  // IEC 61000-4-15 sinusoidal-modulation points yielding Pinst,max = 1.
  // 120 V/60 Hz: 8.8 Hz at 0.321%; 230 V/50 Hz: 8.8 Hz at 0.250%.
  std::vector<Packet> point120 =
      run_point(true, 41, 120, 60, 8.8, 0.321, 0, 13, input, output);
  check_standard_point(point120, "120 V 8.8 Hz");

  std::size_t histogram_chunks = 0;
  std::uint64_t histogram_total[FLK_PHASES]{};
  for (const Packet &packet : point120) {
    if (packet.word[FLK_KIND_WORD] != FLK_KIND_HISTOGRAM) continue;
    ++histogram_chunks;
    const std::uint32_t base = packet.word[FLK_HISTOGRAM_BASE_WORD];
    CHECK(base == (histogram_chunks - 1) * FLK_BINS_PER_PACKET,
          "histogram chunks are ordered and gap free");
    for (int phase = 0; phase < FLK_PHASES; ++phase) {
      for (int offset = 0; offset < FLK_BINS_PER_PACKET; ++offset) {
        if (base + offset < FLK_CLASSIFIER_BINS)
          histogram_total[phase] +=
              packet.word[FLK_HISTOGRAM_WORD +
                          phase * FLK_BINS_PER_PACKET + offset];
      }
    }
  }
  CHECK(histogram_chunks == FLK_CLASSIFIER_CHUNKS,
        "one complete classifier emits exactly 35 FLK1 chunks");
  for (int phase = 0; phase < FLK_PHASES; ++phase)
    CHECK(histogram_total[phase] == 2U * FLK_INTERNAL_RATE_HZ,
          "lossless histogram reconstructs every classified sample");

  std::vector<Packet> point230 = run_point(
      false, 42, 230, 50, 8.8, 0.250,
      static_cast<std::uint64_t>(13) * FLK_INTERNAL_RATE_HZ, 13, input,
      output);
  check_standard_point(point230, "230 V 8.8 Hz");

  // A missing declared voltage reference cannot arm the fixed-point adapter.
  std::vector<Packet> no_reference;
  for (std::uint64_t index = 0; index < FLK_INTERNAL_RATE_HZ; ++index) {
    input.write(make_frame(index, true, 43, 230, 50, 0, 8.8, 0.250));
    hls_flicker_engine(input, output);
    drain(output, no_reference);
  }
  CHECK(no_reference.empty(), "missing reference emits no valid flicker data");

  // A sample-index gap resets every stateful filter and contaminates the
  // enclosing live interval instead of joining samples across the gap.
  std::vector<Packet> gap_packets;
  for (std::uint64_t offset = 0; offset < FLK_INTERNAL_RATE_HZ; ++offset) {
    const std::uint64_t index = offset < 200 ? offset : offset + 1;
    input.write(make_frame(index, false, 44, 120, 60, 120000000U, 8.8,
                           0.321));
    hls_flicker_engine(input, output);
    drain(output, gap_packets);
  }
  CHECK(!gap_packets.empty(), "recovered gap interval emits diagnostics");
  if (!gap_packets.empty()) {
    const std::uint32_t status = gap_packets.back().word[FLK_STATUS_WORD];
    CHECK((status & (1U << FLK_STATUS_DISCONTINUITY_BIT)) != 0U,
          "gap provenance reaches FLK1");
    CHECK((status & (1U << FLK_STATUS_CONTAMINATED_BIT)) != 0U,
          "gap contaminates the enclosing interval");
    CHECK((status & (1U << FLK_STATUS_SETTLING_BIT)) != 0U,
          "gap restarts the standard settling interval");
  }

  if (failures != 0) {
    std::fprintf(stderr, "%d FlickerEngine checks failed\n", failures);
    return 1;
  }
  std::puts("FlickerEngine IEC vectors and FLK1 transport checks passed");
  return 0;
}
