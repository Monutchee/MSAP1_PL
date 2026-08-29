#include "flicker_engine.hpp"

#include <algorithm>
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
  std::uint32_t word[FLK_PAYLOAD_WORDS]{};
};

struct DoubleBiquad {
  double b0;
  double b1;
  double b2;
  double a1;
  double a2;
};

class DoubleFlickerReference {
 public:
  explicit DoubleFlickerReference(std::uint16_t lamp_voltage)
      : coefficients_(lamp_voltage == 120 ? k120Coefficients
                                          : k230Coefficients),
        calibration_(lamp_voltage == 120 ? 76912.44924926758
                                         : 77397.53077697754) {
    adapter_.fill(1.0);
    adapter_reciprocal_.fill(1.0);
  }

  bool process(std::uint64_t index, std::uint8_t nominal_hz,
               double modulation_hz, double modulation_percent,
               std::array<double, FLK_PHASES> &completed_peak) {
    constexpr double pi = 3.14159265358979323846;
    const double time = static_cast<double>(index) / FLK_INTERNAL_RATE_HZ;
    ++adapter_reciprocal_ticks_;
    for (int phase = 0; phase < FLK_PHASES; ++phase) {
      const double phase_angle =
          -2.0 * pi * static_cast<double>(phase) / 3.0;
      const double modulation =
          1.0 + modulation_percent * 0.01 *
                    std::sin(2.0 * pi * modulation_hz * time);
      const double normalized = std::sqrt(2.0) * modulation *
          std::sin(2.0 * pi * static_cast<double>(nominal_hz) * time +
                   phase_angle);
      const double mean_square = normalized * normalized;
      adapter_[phase] += (mean_square - adapter_[phase]) / 54600.0;
      if (adapter_reciprocal_ticks_ >= FLK_INTERNAL_RATE_HZ)
        adapter_reciprocal_[phase] = 1.0 / adapter_[phase];

      double filtered =
          mean_square * adapter_reciprocal_[phase] - 1.0;
      for (int stage = 0; stage < 6; ++stage)
        filtered = run_biquad(filtered, coefficients_[stage],
                              state_[phase][stage]);
      filtered *= filtered;
      const double memory = run_biquad(
          filtered, coefficients_[6], state_[phase][6]);
      const double pinst = std::max(0.0, memory) * calibration_;
      live_peak_[phase] = std::max(live_peak_[phase], pinst);
    }
    if (adapter_reciprocal_ticks_ >= FLK_INTERNAL_RATE_HZ)
      adapter_reciprocal_ticks_ = 0;
    if (++live_ticks_ < FLK_INTERNAL_RATE_HZ)
      return false;
    completed_peak = live_peak_;
    live_peak_.fill(0.0);
    live_ticks_ = 0;
    return true;
  }

 private:
  static double run_biquad(double input, const DoubleBiquad &coefficient,
                           std::array<double, 2> &state) {
    const double output = coefficient.b0 * input + state[0];
    const double next_z1 = coefficient.b1 * input -
        coefficient.a1 * output + state[1];
    const double next_z2 = coefficient.b2 * input -
        coefficient.a2 * output;
    state = {next_z1, next_z2};
    return output;
  }

  // Independently evaluated double-precision forms of the pinned IEC
  // 61000-4-15 bilinear sections. They deliberately do not call fixed-point
  // design helpers, so quantization/state regressions remain observable.
  static constexpr std::array<DoubleBiquad, 7> k230Coefficients{{
      {0.999921466223896, -0.999921466223896, 0.0,
       -0.999842932447791, 0.0},
      {0.00293613225221634, 0.00587226450443268,
       0.00293613225221634, -1.93302152957767, 0.944766058586538},
      {0.00280209630727768, 0.00560419354587793,
       0.00280209630727768, -1.84477840457112, 0.855986791662872},
      {0.00273014046251774, 0.00546028092503548,
       0.00273014046251774, -1.79740554187447, 0.808326103724539},
      {0.0248158425092697, 0.0, -0.0248158425092697,
       -1.97400123253465, 0.97481784876436},
      {0.0179043253883719, 0.000127776525914669,
       -0.0177765488624573, -1.92964503541589, 0.929900588467717},
      {0.000832639634609222, 0.000832639634609222, 0.0,
       -0.998334720730782, 0.0},
  }};
  static constexpr std::array<DoubleBiquad, 7> k120Coefficients{{
      {0.999921466223896, -0.999921466223896, 0.0,
       -0.999842932447791, 0.0},
      {0.0042030643671751, 0.0084061287343502,
       0.0042030643671751, -1.91732764523476, 0.934139902703464},
      {0.00397627148777246, 0.00795254297554493,
       0.00397627148777246, -1.81387077271938, 0.829775859601796},
      {0.00385614112019539, 0.0077122813090682,
       0.00385614112019539, -1.75907014403492, 0.774494706653059},
      {0.0230164239183068, 0.0, -0.0230164239183068,
       -1.97335664089769, 0.974159177392721},
      {0.0125897582620382, 0.000115743838250637,
       -0.0124740144237876, -1.94267201516777, 0.942903503775597},
      {0.000832639634609222, 0.000832639634609222, 0.0,
       -0.998334720730782, 0.0},
  }};

  const std::array<DoubleBiquad, 7> &coefficients_;
  double calibration_;
  std::array<double, FLK_PHASES> adapter_{};
  std::array<double, FLK_PHASES> adapter_reciprocal_{};
  std::array<double, FLK_PHASES> live_peak_{};
  std::array<std::array<std::array<double, 2>, 7>, FLK_PHASES> state_{};
  std::uint32_t adapter_reciprocal_ticks_ = 0;
  std::uint32_t live_ticks_ = 0;
};

struct PointResult {
  std::vector<Packet> packets;
  std::vector<std::array<double, FLK_PHASES>> reference_live_peak;
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

PointResult run_point(bool apply, std::uint32_t generation,
                      std::uint16_t lamp_voltage,
                      std::uint8_t nominal_hz,
                      double modulation_hz,
                      double modulation_percent,
                      std::uint64_t first_index,
                      std::uint32_t seconds,
                      hls::stream<flicker_input_beat_t> &input,
                      hls::stream<record_axis_t> &output) {
  PointResult result;
  DoubleFlickerReference reference(lamp_voltage);
  const std::uint32_t frames = seconds * FLK_INTERNAL_RATE_HZ;
  for (std::uint32_t offset = 0; offset < frames; ++offset) {
    const auto index = first_index + offset;
    input.write(make_frame(index, apply, generation,
                           lamp_voltage, nominal_hz,
                           static_cast<std::uint32_t>(lamp_voltage) * 1000000U,
                           modulation_hz, modulation_percent));
    hls_flicker_engine(input, output);
    drain(output, result.packets);
    std::array<double, FLK_PHASES> peak{};
    if (reference.process(index, nominal_hz, modulation_hz,
                          modulation_percent, peak))
      result.reference_live_peak.push_back(peak);
  }
  return result;
}

void check_reference_point(const PointResult &point, const char *description,
                           bool published_unity_point) {
  std::uint32_t settled_live = 0;
  std::size_t live_index = 0;
  for (const Packet &packet : point.packets) {
    if (packet.word[FLK_KIND_WORD] != FLK_KIND_LIVE)
      continue;
    CHECK(live_index < point.reference_live_peak.size(),
          "double flicker oracle retained every live interval");
    if (live_index >= point.reference_live_peak.size())
      break;
    const auto &reference = point.reference_live_peak[live_index++];
    if ((packet.word[FLK_STATUS_WORD] &
         (1U << FLK_STATUS_SETTLING_BIT)) != 0U)
      continue;
    ++settled_live;
    CHECK(packet.word[FLK_PHASE_MASK_WORD] == 0x7,
          "settled IEC vector keeps all phases valid");
    for (int phase = 0; phase < FLK_PHASES; ++phase) {
      const double actual =
          static_cast<double>(packet.word[FLK_PINST_BASE_WORD + phase]) /
          65536.0;
      const double tolerance = 0.003 + 0.02 * reference[phase];
      if (std::abs(actual - reference[phase]) > tolerance) {
        std::fprintf(stderr,
                     "FAIL: %s phase %d Pinst=%f reference=%f tolerance=%f\n",
                     description, phase, actual, reference[phase], tolerance);
        ++failures;
      }
      if (published_unity_point &&
          !(reference[phase] > 0.98 && reference[phase] < 1.02)) {
        std::fprintf(stderr,
                     "FAIL: %s phase %d published reference=%f\n",
                     description, phase, reference[phase]);
        ++failures;
      }
    }
  }
  CHECK(live_index == point.reference_live_peak.size(),
        "HLS and double oracle emitted the same live interval count");
  CHECK(settled_live >= 2, "standard point produces settled live Pinst");
}

}  // namespace

int main() {
  hls::stream<flicker_input_beat_t> input{"input"};
  hls::stream<record_axis_t> output{"output"};
  bool apply = false;

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
  apply = !apply;
  PointResult point120 =
      run_point(apply, 41, 120, 60, 8.8, 0.321, 0, 13, input, output);
  check_reference_point(point120, "120 V 8.8 Hz", true);

  std::size_t histogram_chunks = 0;
  std::uint64_t histogram_total[FLK_PHASES]{};
  for (const Packet &packet : point120.packets) {
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

  apply = !apply;
  PointResult point230 = run_point(
      apply, 42, 230, 50, 8.8, 0.250,
      static_cast<std::uint64_t>(13) * FLK_INTERNAL_RATE_HZ, 13, input,
      output);
  check_reference_point(point230, "230 V 8.8 Hz", true);

  // Off-peak response points prevent a calibration-only implementation from
  // passing both published unity vectors. The independent double model pins
  // the complete weighting shape on either side of 8.8 Hz.
  apply = !apply;
  const auto point120_4hz = run_point(
      apply, 43, 120, 60, 4.0, 0.321,
      static_cast<std::uint64_t>(26) * FLK_INTERNAL_RATE_HZ, 13, input,
      output);
  check_reference_point(point120_4hz, "120 V 4.0 Hz", false);
  apply = !apply;
  const auto point230_12hz = run_point(
      apply, 44, 230, 50, 12.0, 0.250,
      static_cast<std::uint64_t>(39) * FLK_INTERNAL_RATE_HZ, 13, input,
      output);
  check_reference_point(point230_12hz, "230 V 12.0 Hz", false);

  // A missing declared voltage reference cannot arm the fixed-point adapter.
  std::vector<Packet> no_reference;
  apply = !apply;
  for (std::uint64_t index = 0; index < FLK_INTERNAL_RATE_HZ; ++index) {
    input.write(make_frame(index, apply, 45, 230, 50, 0, 8.8, 0.250));
    hls_flicker_engine(input, output);
    drain(output, no_reference);
  }
  CHECK(no_reference.empty(), "missing reference emits no valid flicker data");

  // A sample-index gap resets every stateful filter and contaminates the
  // enclosing live interval instead of joining samples across the gap.
  std::vector<Packet> gap_packets;
  apply = !apply;
  for (std::uint64_t offset = 0; offset < FLK_INTERNAL_RATE_HZ; ++offset) {
    const std::uint64_t index = offset < 200 ? offset : offset + 1;
    input.write(make_frame(index, apply, 46, 120, 60, 120000000U, 8.8,
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
  std::puts("FlickerEngine double-reference IEC and FLK1 checks passed");
  return 0;
}
