// Golden-model testbench for the ADC simulator waveform engine.
//
// Strategy: the DUT is stateless (one response per request, a pure
// function of the beat), so verification is a direct sweep against an
// independent golden model:
//
//   ideal = peak * sin(2*pi * (base_phase + phase_offset) / 2^32) *
//           (131071 / 131072)                       [double, tolerance]
//         + dc                                       [exact]
//         + noise(frame_index, lane, level)          [exact integer]
//
// The sine tolerance comes from the implementation's documented error
// budget: table quantization (0.5 LSB of Q1.17), the interpolation
// sagitta, and the single floor after the peak multiply. The noise path
// is replicated bit-exactly (the mixer is spec, not approximation), as
// are DC offsets, masked-channel zeros, rail clamps, saturation flags,
// and repeatability.
//
// The same source runs as C simulation and C/RTL co-simulation.

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>

#include "sim_wave_engine.hpp"

static int failures = 0;

#define CHECK(cond, ...)                                                       \
  do {                                                                         \
    if (!(cond)) {                                                             \
      std::printf("FAIL: " __VA_ARGS__);                                       \
      std::printf("\n");                                                       \
      ++failures;                                                              \
    }                                                                          \
  } while (0)

struct ChannelSpec {
  long peak;
  unsigned long phase;
  long dc;
  unsigned long noise;
  bool enabled;
};

// Global harmonic slots for the request under test (zero = disabled).
struct HarmonicSpec {
  unsigned order = 0;
  unsigned mask = 0;
  unsigned fraction_q16 = 0;
  unsigned long phase = 0;
};
static HarmonicSpec g_harmonics[SIM_WAVE_HARMONIC_SLOTS];

static sim_wave_request_t pack_request(unsigned long base_phase,
                                       unsigned long frame_index,
                                       const ChannelSpec (&ch)[SIM_WAVE_CHANNELS]) {
  sim_wave_request_t request = 0;
  request.range(SIM_WAVE_REQ_BASE_PHASE_LSB + 31, SIM_WAVE_REQ_BASE_PHASE_LSB) =
      ap_uint<32>(base_phase);
  request.range(SIM_WAVE_REQ_FRAME_INDEX_LSB + 31, SIM_WAVE_REQ_FRAME_INDEX_LSB) =
      ap_uint<32>(frame_index);
  ap_uint<8> mask = 0;
  for (int lane = 0; lane < SIM_WAVE_CHANNELS; ++lane) {
    mask[lane] = ch[lane].enabled ? 1 : 0;
    const int peak_lsb = SIM_WAVE_REQ_PEAK_LSB + lane * 32;
    const int phase_lsb = SIM_WAVE_REQ_PHASE_LSB + lane * 32;
    const int dc_lsb = SIM_WAVE_REQ_DC_LSB + lane * 32;
    const int noise_lsb = SIM_WAVE_REQ_NOISE_LSB + lane * 32;
    request.range(peak_lsb + 31, peak_lsb) = ap_uint<32>(ap_int<32>(ch[lane].peak));
    request.range(phase_lsb + 31, phase_lsb) = ap_uint<32>(ch[lane].phase);
    request.range(dc_lsb + 31, dc_lsb) = ap_uint<32>(ap_int<32>(ch[lane].dc));
    request.range(noise_lsb + 31, noise_lsb) = ap_uint<32>(ch[lane].noise);
  }
  request.range(SIM_WAVE_REQ_VALID_MASK_LSB + 7, SIM_WAVE_REQ_VALID_MASK_LSB) = mask;
  for (int slot = 0; slot < SIM_WAVE_HARMONIC_SLOTS; ++slot) {
    const int lsb = SIM_WAVE_REQ_HARMONIC_LSB + slot * 64;
    request.range(lsb + 7, lsb) = g_harmonics[slot].order;
    request.range(lsb + 15, lsb + 8) = g_harmonics[slot].mask;
    request.range(lsb + 31, lsb + 16) = g_harmonics[slot].fraction_q16;
    request.range(lsb + 63, lsb + 32) = ap_uint<32>(g_harmonics[slot].phase);
  }
  return request;
}

static sim_wave_response_t run_beat(const sim_wave_request_t &request) {
  hls::stream<sim_wave_request_t> s_request("s_request");
  hls::stream<sim_wave_response_t> m_frame("m_frame");
  s_request.write(request);
  // A second invocation proves the empty-stream early-out is silent.
  hls_sim_wave_engine(s_request, m_frame);
  hls_sim_wave_engine(s_request, m_frame);
  CHECK(m_frame.size() == 1, "expected exactly one response, got %u",
        (unsigned)m_frame.size());
  return m_frame.read();
}

static long response_sample(const sim_wave_response_t &response, int lane) {
  const int lsb = SIM_WAVE_RSP_SAMPLE_LSB + lane * 32;
  return (long)ap_int<32>(response.range(lsb + 31, lsb));
}

static bool response_saturated(const sim_wave_response_t &response, int lane) {
  return response[SIM_WAVE_RSP_SATURATED_LSB + lane] != 0;
}

// Bit-exact model of the engine's noise path (the mixer is normative).
static uint32_t mix32_model(uint32_t value) {
  value ^= value >> 16;
  value *= 0x7feb352du;
  value ^= value >> 15;
  value *= 0x846ca68bu;
  value ^= value >> 16;
  return value;
}

static long noise_counts_model(unsigned long frame_index, int lane,
                               unsigned long level) {
  const uint32_t word = mix32_model((uint32_t)frame_index ^
                                    (uint32_t)(0x9e3779b9u * (unsigned)(lane + 1)));
  const int32_t uniform = (int32_t)word >> 8;  // top 24 bits, signed
  const long long product = (long long)uniform * (long long)(level & 0xFFFFFFul);
  return (long)(product >> 23);
}

// The sine + harmonics + DC + noise model with the implementation's gain
// convention; pre-clamp, so callers can also predict the saturation flags.
static double golden_unclamped(unsigned long base_phase, unsigned long frame_index,
                               int lane, const ChannelSpec &ch) {
  const unsigned long angle = (base_phase + ch.phase) & 0xFFFFFFFFul;
  const double turns = (double)angle / 4294967296.0;
  const double sine = std::sin(2.0 * M_PI * turns) * (131071.0 / 131072.0);
  double value = (double)ch.peak * sine + (double)ch.dc +
                 (double)noise_counts_model(frame_index, lane, ch.noise);
  for (int slot = 0; slot < SIM_WAVE_HARMONIC_SLOTS; ++slot) {
    const HarmonicSpec &h = g_harmonics[slot];
    if (h.order == 0 || ((h.mask >> lane) & 1u) == 0 || h.fraction_q16 == 0)
      continue;
    const unsigned long harmonic_angle =
        (unsigned long)(((unsigned long long)h.order * angle + h.phase) &
                        0xFFFFFFFFull);
    const double harmonic_turns = (double)harmonic_angle / 4294967296.0;
    value += (double)ch.peak * ((double)h.fraction_q16 / 65536.0) *
             std::sin(2.0 * M_PI * harmonic_turns) * (131071.0 / 131072.0);
  }
  return value;
}

// Extra tolerance per active harmonic slot on this lane (its own table
// quantization, sagitta, and floor).
static double harmonic_tolerance(int lane, long peak) {
  double extra = 0.0;
  for (int slot = 0; slot < SIM_WAVE_HARMONIC_SLOTS; ++slot) {
    const HarmonicSpec &h = g_harmonics[slot];
    if (h.order == 0 || ((h.mask >> lane) & 1u) == 0 || h.fraction_q16 == 0)
      continue;
    const double component =
        std::fabs((double)peak) * ((double)h.fraction_q16 / 65536.0);
    extra += component / 262144.0 + component * 2.9e-7 + 1.0;
  }
  return extra;
}

// Error budget, in output counts, for a channel of the given peak: the
// table quantization (0.5 LSB of Q1.17), the interpolation sagitta, and
// the single floor after the peak multiply (plus one count of margin).
// The full 20-bit phase fraction rides through the multiply, so there is
// no phase-truncation term; DC and noise contributions are exact.
static double tolerance_counts(long peak) {
  const double fs = std::fabs((double)peak);
  const double table_quant = fs / 262144.0;  // 0.5 LSB of Q1.17
  const double sagitta = fs * 2.9e-7;        // lerp curvature bound
  return table_quant + sagitta + 2.0;        // + the one floor + margin
}

static void check_frame(const char *what, unsigned long base_phase,
                        unsigned long frame_index,
                        const ChannelSpec (&ch)[SIM_WAVE_CHANNELS]) {
  const sim_wave_response_t response =
      run_beat(pack_request(base_phase, frame_index, ch));
  for (int lane = 0; lane < SIM_WAVE_CHANNELS; ++lane) {
    const long got = response_sample(response, lane);
    const bool saturated = response_saturated(response, lane);
    if (!ch[lane].enabled) {
      CHECK(got == 0 && !saturated,
            "%s: masked lane %d must be exactly zero, got %ld (sat %d)", what,
            lane, got, saturated ? 1 : 0);
      continue;
    }
    const double ideal = golden_unclamped(base_phase, frame_index, lane, ch[lane]);
    const double tol =
        tolerance_counts(ch[lane].peak) + harmonic_tolerance(lane, ch[lane].peak);
    if (ideal > (double)SIM_WAVE_SAMPLE_MAX + tol) {
      CHECK(got == SIM_WAVE_SAMPLE_MAX && saturated,
            "%s: lane %d should clamp high, got %ld (sat %d)", what, lane, got,
            saturated ? 1 : 0);
    } else if (ideal < (double)SIM_WAVE_SAMPLE_MIN - tol) {
      CHECK(got == SIM_WAVE_SAMPLE_MIN && saturated,
            "%s: lane %d should clamp low, got %ld (sat %d)", what, lane, got,
            saturated ? 1 : 0);
    } else if (ideal < (double)SIM_WAVE_SAMPLE_MAX - tol &&
               ideal > (double)SIM_WAVE_SAMPLE_MIN + tol) {
      // Comfortably inside the rails: value within tolerance, no flag.
      CHECK(std::fabs((double)got - ideal) <= tol,
            "%s: lane %d off golden: got %ld ideal %.3f tol %.3f", what, lane,
            got, ideal, tol);
      CHECK(!saturated, "%s: lane %d spurious saturation flag", what, lane);
    }
    // Within one tolerance of a rail either outcome is legitimate; the
    // value check still applies to unclamped outputs.
    if (!saturated) {
      CHECK(std::fabs((double)got - ideal) <= tol,
            "%s: lane %d off golden near rail: got %ld ideal %.3f", what, lane,
            got, ideal);
    }
  }
}

int main() {
  static_assert(SIM_WAVE_REQ_BITS == 1408, "request beat width is normative");
  static_assert(SIM_WAVE_RSP_BITS == 264, "response beat width is normative");
  static_assert(SIM_WAVE_REQ_FRAME_INDEX_LSB == 64 &&
                    SIM_WAVE_REQ_PEAK_LSB == 128 &&
                    SIM_WAVE_REQ_PHASE_LSB == 384 &&
                    SIM_WAVE_REQ_DC_LSB == 640 && SIM_WAVE_REQ_NOISE_LSB == 896,
                "request lane bases are normative");

  // --- Zero request: all lanes zero, no flags. --------------------------
  {
    ChannelSpec ch[SIM_WAVE_CHANNELS] = {};
    for (int lane = 0; lane < SIM_WAVE_CHANNELS; ++lane) ch[lane].enabled = true;
    const sim_wave_response_t response = run_beat(pack_request(0, 0, ch));
    CHECK(response == 0, "zero request must produce an all-zero response");
  }

  // --- Cardinal points at a modest amplitude (legacy TB values). --------
  {
    ChannelSpec ch[SIM_WAVE_CHANNELS] = {};
    ch[0] = {1000, 0x00000000ul, 0, 0, true};
    const long expected[4] = {0, 999, 0, -1000};
    for (int quarter = 0; quarter < 4; ++quarter) {
      const unsigned long base = (unsigned long)quarter << 30;
      const sim_wave_response_t response = run_beat(pack_request(base, 0, ch));
      CHECK(response_sample(response, 0) == expected[quarter],
            "cardinal point %d: got %ld expected %ld", quarter,
            response_sample(response, 0), expected[quarter]);
    }
  }

  // --- Dense sweep: 7 enabled channels, distinct amplitude/phase/dc/ ----
  // --- noise, 512 base phases covering all quadrants and wraparound. ----
  {
    ChannelSpec ch[SIM_WAVE_CHANNELS] = {};
    const long peaks[7] = {8388607, 4194304, 1000000, 123456, 1000, -8388607, 3};
    const unsigned long phases[7] = {0x00000000ul, 0xAAAAAAABul, 0x40000000ul,
                                     0xC0000001ul, 0x12345678ul, 0x87654321ul,
                                     0xFFFFFFFFul};
    const long dcs[7] = {0, 1000, -1000, 500000, -500000, 0, 8388600};
    const unsigned long noises[7] = {0, 5000, 0, 250, 10, 1000, 0};
    for (int lane = 0; lane < 7; ++lane) {
      ch[lane] = {peaks[lane], phases[lane], dcs[lane], noises[lane], true};
    }
    ch[7] = {8388607, 0, 8388607, 8388607, false};  // masked lane carries junk
    for (int step = 0; step < 512; ++step) {
      const unsigned long base = (unsigned long)step * 0x00800801ul;  // odd stride
      check_frame("sweep", base, (unsigned long)step, ch);
    }
  }

  // --- DC-only lanes are exact (peak 0 disables the sine path). ---------
  {
    ChannelSpec ch[SIM_WAVE_CHANNELS] = {};
    ch[0] = {0, 0, 12345, 0, true};
    ch[1] = {0, 0, -12345, 0, true};
    ch[2] = {0, 0, SIM_WAVE_SAMPLE_MAX, 0, true};
    ch[3] = {0, 0, SIM_WAVE_SAMPLE_MIN, 0, true};
    const sim_wave_response_t response =
        run_beat(pack_request(0x13579BDFul, 77, ch));
    CHECK(response_sample(response, 0) == 12345, "dc-only lane 0");
    CHECK(response_sample(response, 1) == -12345, "dc-only lane 1");
    CHECK(response_sample(response, 2) == SIM_WAVE_SAMPLE_MAX, "dc rail lane 2");
    CHECK(response_sample(response, 3) == SIM_WAVE_SAMPLE_MIN, "dc rail lane 3");
    for (int lane = 0; lane < 4; ++lane) {
      CHECK(!response_saturated(response, lane),
            "dc at or inside the rails must not flag lane %d", lane);
    }
  }

  // --- Noise-only lanes: bit-exact vs the model, bounded, and alive. ----
  {
    const unsigned long level = 100000;
    ChannelSpec ch[SIM_WAVE_CHANNELS] = {};
    ch[0] = {0, 0, 0, level, true};
    ch[1] = {0, 0, 0, level, true};
    long minimum = SIM_WAVE_SAMPLE_MAX, maximum = SIM_WAVE_SAMPLE_MIN;
    double mean_acc = 0.0;
    bool lanes_differ = false;
    const int frames = 512;
    for (int frame = 0; frame < frames; ++frame) {
      const sim_wave_response_t response =
          run_beat(pack_request(0, (unsigned long)frame, ch));
      for (int lane = 0; lane < 2; ++lane) {
        const long got = response_sample(response, lane);
        const long expected = noise_counts_model((unsigned long)frame, lane, level);
        CHECK(got == expected,
              "noise frame %d lane %d: got %ld expected %ld (bit-exact)", frame,
              lane, got, expected);
        CHECK(got >= -(long)level && got <= (long)level,
              "noise frame %d lane %d out of bounds: %ld", frame, lane, got);
      }
      const long s0 = response_sample(response, 0);
      if (s0 < minimum) minimum = s0;
      if (s0 > maximum) maximum = s0;
      mean_acc += (double)s0;
      if (s0 != response_sample(response, 1)) lanes_differ = true;
    }
    CHECK(maximum > minimum, "noise must actually fluctuate");
    CHECK(lanes_differ, "channels must draw uncorrelated noise");
    CHECK(std::fabs(mean_acc / frames) < (double)level / 10.0,
          "noise mean %.1f is implausibly biased for level %lu",
          mean_acc / frames, level);
  }

  // --- Harmonics: 5% 3rd + 3% 5th on the three voltage lanes, against ---
  // --- the double model (which itself encodes the physical rule that a --
  // --- balanced set's 3rd harmonic lands zero-sequence). -----------------
  {
    g_harmonics[0] = {3, 0x70, (unsigned)(0.05 * 65536), 0};
    g_harmonics[1] = {5, 0x70, (unsigned)(0.03 * 65536), 0x20000000ul};
    ChannelSpec ch[SIM_WAVE_CHANNELS] = {};
    ch[4] = {4000000, 0x55555555ul, 0, 0, true};   // Vc at +120 deg
    ch[5] = {4000000, 0xAAAAAAABul, 0, 0, true};   // Vb at -120 deg
    ch[6] = {4000000, 0x00000000ul, 0, 0, true};   // Va at 0 deg
    ch[0] = {1000000, 0x00000000ul, 0, 0, true};   // Ia: no harmonics (mask)
    for (int step = 0; step < 64; ++step) {
      const unsigned long base = (unsigned long)step * 0x03000001ul;
      check_frame("harmonics", base, (unsigned long)step, ch);
    }
    g_harmonics[0] = {};
    g_harmonics[1] = {};
  }

  // --- Saturation: sine + dc past each rail clamps and flags, per lane. -
  {
    ChannelSpec ch[SIM_WAVE_CHANNELS] = {};
    ch[0] = {8388607, 0x40000000ul, 1000000, 0, true};   // high rail
    ch[1] = {8388607, 0xC0000000ul, -1000000, 0, true};  // low rail
    ch[2] = {1000, 0x40000000ul, 0, 0, true};            // untouched neighbour
    ch[3] = {0x01000000l, 0x40000000ul, 0, 0, true};     // out-of-range peak reg
    const sim_wave_response_t response = run_beat(pack_request(0, 0, ch));
    CHECK(response_sample(response, 0) == SIM_WAVE_SAMPLE_MAX &&
              response_saturated(response, 0),
          "high-rail clamp lane 0: got %ld", response_sample(response, 0));
    CHECK(response_sample(response, 1) == SIM_WAVE_SAMPLE_MIN &&
              response_saturated(response, 1),
          "low-rail clamp lane 1: got %ld", response_sample(response, 1));
    CHECK(!response_saturated(response, 2), "lane 2 must not inherit flags");
    CHECK(response_sample(response, 3) == SIM_WAVE_SAMPLE_MAX &&
              response_saturated(response, 3),
          "oversized peak register must clamp, got %ld",
          response_sample(response, 3));
  }

  // --- Determinism: identical requests give identical responses, noise --
  // --- included (frame_index is the only randomness source). ------------
  {
    ChannelSpec ch[SIM_WAVE_CHANNELS] = {};
    for (int lane = 0; lane < 7; ++lane) {
      ch[lane] = {1000000 + lane, 0x2468ACE0ul * (lane + 1), lane * 7,
                  (unsigned long)(lane * 333), true};
    }
    const sim_wave_request_t request = pack_request(0xDEADBEEFul, 42, ch);
    const sim_wave_response_t first = run_beat(request);
    const sim_wave_response_t second = run_beat(request);
    CHECK(first == second, "engine must be stateless and repeatable");
  }

  // --- Phase fidelity: a 0.01-degree offset at the zero crossing must ----
  // --- resolve at full scale. The legacy 8-bit-indexed table quantized ---
  // --- phase to 1.40625 degrees, making this exact case invisible. -------
  {
    ChannelSpec ch[SIM_WAVE_CHANNELS] = {};
    const unsigned long hundredth_degree = 119305;  // 0.01/360 * 2^32
    ch[0] = {8388607, 0x00000000ul, 0, 0, true};
    ch[1] = {8388607, hundredth_degree, 0, 0, true};
    const sim_wave_response_t response = run_beat(pack_request(0, 0, ch));
    const long delta = response_sample(response, 1) - response_sample(response, 0);
    const double ideal_delta =
        8388607.0 * std::sin(2.0 * M_PI * (double)hundredth_degree / 4294967296.0);
    CHECK(delta > 0, "0.01 degrees at the zero crossing must be visible");
    CHECK(std::fabs((double)delta - ideal_delta) <= tolerance_counts(8388607),
          "0.01-degree step off golden: delta %ld ideal %.3f", delta,
          ideal_delta);
  }

  if (failures != 0) {
    std::printf("FAILED: %d check(s)\n", failures);
    return EXIT_FAILURE;
  }
  std::printf("PASS: sim_wave_engine_tb\n");
  return EXIT_SUCCESS;
}
