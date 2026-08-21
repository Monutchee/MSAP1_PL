// Testbench for the single-cycle measurement engine (M6: the handover's
// initial SingleCycle test list, plus the validity/generation contract).
//
// The engine is a deterministic window machine, so the bench drives
// explicit frame sequences and checks exact expectations: result-beat
// fields, SCYC-v5 record words, 64-beat framing, whole-cycle-only
// emission, and the discontinuity marking rules (reset, APPLY, malformed
// frames, dropped beats, stale generations, unlocked cycle timing). The
// waveform matrix covers the handover scenario list -- balanced/reverse
// sequence, unequal amplitudes, the PF sweep both directions, reverse
// power, zero/DC signals, zero current/voltage, 50 Hz and off-nominal --
// against goldens computed from the exact integer samples sent (sums,
// squares, cross-products in __int128) and analytic fundamentals. The
// same source runs as csim and cosim.

#include <cmath>
#include <cstdio>
#include <cstdlib>

#include "single_cycle_engine.hpp"

static int failures = 0;

#define CHECK(cond, ...)                                                       \
  do {                                                                         \
    if (!(cond)) {                                                             \
      std::printf("FAIL: " __VA_ARGS__);                                       \
      std::printf("\n");                                                       \
      ++failures;                                                              \
    }                                                                          \
  } while (0)

struct FrameSpec {
  long long q16[MET_ACTIVE_CHANNELS] = {0, 0, 0, 0, 0, 0, 0};
  int raw[MET_ACTIVE_CHANNELS] = {0, 0, 0, 0, 0, 0, 0};
  bool dc_remove = true;
  unsigned long long sample_index = 0;
  unsigned long long pl_tick = 0;
  unsigned generation = 1;
  unsigned cfg_generation = 1;
  unsigned cfg_rate = 32000;
  unsigned cfg_mask = 0x7F;
  unsigned frame_mask = 0x7F;
  unsigned cycle_sequence = 0;
  unsigned nominal = 60;
  unsigned flags = 0x1;  // MET_FLAG_LOCKED
  unsigned freq_mhz = 60000;
  unsigned freq_status = 0x2;  // FREQUENCY_STATUS_VALID
  bool malformed = false;
  bool closes = false;
  bool cycle_mode = true;
  bool apply = false;
  bool enable = true;
};

static single_cycle_sample_beat_t pack_frame(const FrameSpec &f) {
  single_cycle_sample_beat_t beat = 0;
  beat.range(SCYC_IN_FRAME_MASK_LSB + 7, SCYC_IN_FRAME_MASK_LSB) = f.frame_mask;
  beat.range(SCYC_IN_FRAME_GEN_LSB + 31, SCYC_IN_FRAME_GEN_LSB) = f.generation;
  beat[SCYC_IN_MALFORMED_BIT] = f.malformed ? 1 : 0;
  beat[SCYC_IN_CLOSES_BIT] = f.closes ? 1 : 0;
  beat[SCYC_IN_CYCLE_MODE_BIT] = f.cycle_mode ? 1 : 0;
  beat[SCYC_IN_APPLY_BIT] = f.apply ? 1 : 0;
  beat[SCYC_IN_ENABLE_BIT] = f.enable ? 1 : 0;
  beat[SCYC_IN_DC_REMOVE_BIT] = f.dc_remove ? 1 : 0;
  for (int lane = 0; lane < MET_ACTIVE_CHANNELS; ++lane) {
    beat.range(SCYC_IN_SAMPLES_LSB + lane * 64 + 63,
               SCYC_IN_SAMPLES_LSB + lane * 64) =
        ap_uint<64>(ap_int<64>(f.q16[lane]));
    beat.range(SCYC_IN_RAW_LSB + lane * 32 + 31, SCYC_IN_RAW_LSB + lane * 32) =
        ap_uint<32>(ap_int<32>(f.raw[lane]));
  }
  beat.range(SCYC_IN_CFG_GEN_LSB + 31, SCYC_IN_CFG_GEN_LSB) = f.cfg_generation;
  beat.range(SCYC_IN_CFG_RATE_LSB + 31, SCYC_IN_CFG_RATE_LSB) = f.cfg_rate;
  beat.range(SCYC_IN_CFG_MASK_LSB + 7, SCYC_IN_CFG_MASK_LSB) = f.cfg_mask;
  beat.range(SCYC_IN_CYCLE_SEQ_LSB + 31, SCYC_IN_CYCLE_SEQ_LSB) = f.cycle_sequence;
  beat.range(SCYC_IN_NOMINAL_LSB + 7, SCYC_IN_NOMINAL_LSB) = f.nominal;
  beat.range(SCYC_IN_FLAGS_LSB + MET_FLAG_BITS - 1, SCYC_IN_FLAGS_LSB) = f.flags;
  beat.range(SCYC_IN_SAMPLE_IDX_LSB + 63, SCYC_IN_SAMPLE_IDX_LSB) =
      ap_uint<64>(f.sample_index);
  beat.range(SCYC_IN_PL_TICK_LSB + 63, SCYC_IN_PL_TICK_LSB) =
      ap_uint<64>(f.pl_tick);
  beat.range(SCYC_IN_FREQ_MHZ_LSB + 31, SCYC_IN_FREQ_MHZ_LSB) = f.freq_mhz;
  beat.range(SCYC_IN_FREQ_STATUS_LSB + 31, SCYC_IN_FREQ_STATUS_LSB) =
      f.freq_status;
  return beat;
}

struct Bench {
  hls::stream<single_cycle_sample_beat_t> s_sample{"s_sample"};
  hls::stream<record_axis_t> m_axis{"m_axis"};
  hls::stream<single_cycle_beat_t> m_result{"m_result"};
  bool apply_level = false;

  void send(const FrameSpec &f) {
    s_sample.write(pack_frame(f));
    hls_single_cycle_engine(s_sample, m_axis, m_result);
  }
  // Toggle APPLY on the next frame (level convention).
  FrameSpec applied(FrameSpec f) {
    apply_level = !apply_level;
    f.apply = apply_level;
    return f;
  }
  FrameSpec leveled(FrameSpec f) {
    f.apply = apply_level;
    return f;
  }
};

// Drain and validate one 64-beat record; returns the words.
static void take_record(Bench &b, ap_uint<32> (&words)[MREC_WORDS]) {
  int beats = 0;
  while (!b.m_axis.empty() && beats < MREC_WORDS) {
    const record_axis_t beat = b.m_axis.read();
    words[beats] = beat.data;
    CHECK(beat.keep == MREC_KEEP_ALL, "record TKEEP must be full");
    CHECK((beat.last == 1) == (beats == MREC_WORDS - 1),
          "record TLAST must mark beat 63 only (beat %d)", beats);
    ++beats;
  }
  CHECK(beats == MREC_WORDS, "record must be exactly 64 beats, got %d", beats);
}

// Jump to a new sample region and leave the engine clean: the index jump
// aborts anything running, two frames re-arm the boundary, and one
// throwaway cycle absorbs the pending discontinuity mark. Returns the
// first sample index after the settle (the next window's start).
static unsigned long long settle(Bench &b, const FrameSpec &f,
                                 unsigned long long base) {
  for (int i = 0; i < 4; ++i) {
    FrameSpec g = b.leveled(f);
    g.sample_index = base + i;
    g.closes = (i == 1) || (i == 3);
    b.send(g);
  }
  CHECK(b.m_result.size() == 1, "settle must emit exactly one throwaway");
  const single_cycle_result_t r = unpack_single_cycle_result(b.m_result.read());
  CHECK(((r.status >> SCYC_STATUS_FIRST_AFTER_GAP_BIT) & 1) == 1,
        "the settle throwaway must carry the first-after-gap mark");
  ap_uint<32> words[MREC_WORDS];
  take_record(b, words);
  return base + 4;
}

static unsigned long long record_u64(const ap_uint<32> (&words)[MREC_WORDS],
                                     int base) {
  return (unsigned long long)words[base] |
         ((unsigned long long)words[base + 1] << 32);
}

// ---------------------------------------------------------------------------
// Waveform matrix runner: one whole cycle of per-lane sinusoids
//   lane(i) = amp * sin(2*pi*i/samples + phase) + dc     (Q16 units)
// with goldens computed from the EXACT integers sent (sums, squares,
// cross-products in __int128) and the fundamental checked analytically.
// The engine must already be settled and contiguous at `base`.
// ---------------------------------------------------------------------------
struct WaveSpec {
  double amp[MET_ACTIVE_CHANNELS] = {0, 0, 0, 0, 0, 0, 0};        // Q16 units
  double phase_deg[MET_ACTIVE_CHANNELS] = {0, 0, 0, 0, 0, 0, 0};  // degrees
  double dc[MET_ACTIVE_CHANNELS] = {0, 0, 0, 0, 0, 0, 0};         // Q16 units
  int samples = 640;          // whole cycle: fs / f exactly
  unsigned freq_mhz = 50000;  // 32 kHz / 50 Hz = 640
  unsigned expected_status = 0;
  bool check_phase = true;
};

static single_cycle_result_t run_wave(Bench &b, const FrameSpec &base_frame,
                                      const WaveSpec &w,
                                      unsigned long long base,
                                      const char *name) {
  __int128 g_sum[MET_ACTIVE_CHANNELS] = {};
  unsigned __int128 g_square[MET_ACTIVE_CHANNELS] = {};
  unsigned __int128 g_vll_square[MET_VLL_PAIRS] = {};
  __int128 g_power[MET_POWER_PHASES] = {};
  const int pv[3] = {MET_LANE_VA, MET_LANE_VB, MET_LANE_VC};
  const int pi_[3] = {MET_LANE_IA, MET_LANE_IB, MET_LANE_IC};
  const int minuend[MET_VLL_PAIRS] = {MET_LANE_VA, MET_LANE_VB, MET_LANE_VC};
  const int subtrahend[MET_VLL_PAIRS] = {MET_LANE_VB, MET_LANE_VC, MET_LANE_VA};

  for (int i = 0; i < w.samples; ++i) {
    FrameSpec g = b.leveled(base_frame);
    g.sample_index = base + i;
    g.freq_mhz = w.freq_mhz;
    g.closes = (i == w.samples - 1);
    for (int lane = 0; lane < MET_ACTIVE_CHANNELS; ++lane) {
      const double theta = 2.0 * M_PI * i / w.samples +
                           w.phase_deg[lane] * M_PI / 180.0;
      const double value =
          w.amp[lane] * 65536.0 * std::sin(theta) + w.dc[lane] * 65536.0;
      g.q16[lane] = (long long)std::llround(value);
      g_sum[lane] += g.q16[lane];
      g_square[lane] +=
          (unsigned __int128)((__int128)g.q16[lane] * g.q16[lane]);
    }
    for (int pair = 0; pair < MET_VLL_PAIRS; ++pair) {
      const long long diff = g.q16[minuend[pair]] - g.q16[subtrahend[pair]];
      g_vll_square[pair] += (unsigned __int128)((__int128)diff * diff);
    }
    for (int phase = 0; phase < MET_POWER_PHASES; ++phase)
      g_power[phase] += (__int128)g.q16[pv[phase]] * g.q16[pi_[phase]];
    b.send(g);
  }

  CHECK(b.m_result.size() == 1, "%s: one cycle must yield one result", name);
  const single_cycle_result_t r = unpack_single_cycle_result(b.m_result.read());
  CHECK(r.status == w.expected_status, "%s: status 0x%x expected 0x%x", name,
        (unsigned)r.status, w.expected_status);
  CHECK(r.sample_count == (unsigned)w.samples && r.first_sample == base &&
            r.last_sample == base + w.samples - 1,
        "%s: whole-cycle provenance", name);
  ap_uint<32> words[MREC_WORDS];
  take_record(b, words);
  CHECK(words[MREC_FORMAT_WORD] == MREC_FORMAT_SCYC_V5, "%s: record format",
        name);
  CHECK(words[8] == w.expected_status, "%s: record status word", name);

  // Per-lane RMS (dc_remove active in base_frame unless overridden).
  for (int lane = 0; lane < MET_ACTIVE_CHANNELS; ++lane) {
    const double mean = (double)(long long)(g_sum[lane] / w.samples);
    const double mean_sq = (double)g_square[lane] / w.samples;
    const double variance = base_frame.dc_remove
                                ? mean_sq - ((double)g_sum[lane] / w.samples) *
                                                ((double)g_sum[lane] / w.samples)
                                : mean_sq;
    (void)mean;
    const double expected_units = std::sqrt(variance > 0 ? variance : 0) / 65536.0;
    const unsigned long long got = record_u64(
        words, SCYC_CH_BASE_WORD + lane * SCYC_CH_STRIDE_WORDS);
    CHECK((std::fabs((double)got - expected_units) <= 2.0),
          "%s: lane %d RMS got %llu expected %.2f", name, lane, got,
          expected_units);
  }
  // Line-line RMS.
  for (int pair = 0; pair < MET_VLL_PAIRS; ++pair) {
    const double expected_units =
        std::sqrt((double)g_vll_square[pair] / w.samples) / 65536.0;
    const unsigned long long got = record_u64(
        words, SCYC_VLL_BASE_WORD + pair * SCYC_CH_STRIDE_WORDS);
    CHECK((std::fabs((double)got - expected_units) <= 2.0),
          "%s: pair %d VLL RMS got %llu expected %.2f", name, pair, got,
          expected_units);
  }
  // Per-phase active power (picowatt words, signed).
  for (int phase = 0; phase < MET_POWER_PHASES; ++phase) {
    const double expected_pw =
        (double)g_power[phase] / w.samples / 4294967296.0;
    const long long got = (long long)record_u64(
        words, SCYC_POWER_BASE_WORD + phase * SCYC_CH_STRIDE_WORDS);
    CHECK((std::fabs((double)got - expected_pw) <=
           std::fabs(expected_pw) * 0.002 + 2.0),
          "%s: phase %d P got %lld expected %.1f pW", name, phase, got,
          expected_pw);
  }
  // Fundamental magnitude (analytic: amp/sqrt(2)) and phase recovery.
  for (int lane = 0; lane < MET_ACTIVE_CHANNELS; ++lane) {
    const double expected_fund = w.amp[lane] / std::sqrt(2.0) * 65536.0 / 65536.0;
    const unsigned long long got = record_u64(
        words, SCYC_FUND_BASE_WORD + lane * SCYC_CH_STRIDE_WORDS);
    CHECK((std::fabs((double)got - expected_fund) <=
           expected_fund * 0.002 + 2.0),
          "%s: lane %d fundamental got %llu expected %.2f", name, lane, got,
          expected_fund);
    if (w.check_phase && w.amp[lane] >= 1.0) {
      const double re = (double)(long long)ap_int<64>(
          (r.phasor_re[lane] >> 37).range(63, 0));
      const double im = (double)(long long)ap_int<64>(
          (r.phasor_im[lane] >> 37).range(63, 0));
      double phi = std::atan2(re, -im) * 180.0 / M_PI;
      double want = w.phase_deg[lane];
      double delta = phi - want;
      while (delta > 180.0) delta -= 360.0;
      while (delta < -180.0) delta += 360.0;
      CHECK((std::fabs(delta) <= 0.05),
            "%s: lane %d phase got %.3f expected %.1f", name, lane, phi, want);
    }
  }
  return r;
}

int main() {
  static_assert(SCYC_IN_BITS == 1152, "input beat width is normative");
  static_assert(SCYC_BEAT_BITS == 7072, "result beat width is normative");

  Bench b;
  FrameSpec f;
  ap_uint<32> words[MREC_WORDS];

  // --- Configure via APPLY; whole-cycle-only emission + provenance. ------
  // The APPLY (and reset) discard everything up to the next boundary, so
  // the first RESULT is the first WHOLE cycle after it, marked
  // first-after-gap.
  {
    FrameSpec g = f;
    g.sample_index = 1000;
    b.send(b.applied(g));  // carrier: discarded (await boundary)
    for (int i = 1; i < 5; ++i) {
      FrameSpec h = b.leveled(f);
      h.sample_index = 1000 + i;
      h.closes = (i == 4);  // boundary of the discarded partial cycle
      b.send(h);
    }
    CHECK(b.m_result.empty() && b.m_axis.empty(),
          "no partial-cycle products after APPLY");
    for (int i = 0; i < 5; ++i) {
      FrameSpec h = b.leveled(f);
      h.sample_index = 1005 + i;
      h.pl_tick = 50000 + 10 * i;
      h.cycle_sequence = 7;
      h.closes = (i == 4);
      b.send(h);
    }
    CHECK(b.m_result.size() == 1, "one cycle must yield one result beat");
    const single_cycle_result_t r =
        unpack_single_cycle_result(b.m_result.read());
    CHECK(r.sequence == 1, "first result carries sequence 1, got %u",
          (unsigned)r.sequence);
    CHECK(r.first_sample == 1005 && r.last_sample == 1009,
          "sample anchors must span the whole cycle (%llu..%llu)",
          (unsigned long long)r.first_sample,
          (unsigned long long)r.last_sample);
    CHECK(r.sample_count == 5, "five frames accumulated, got %u",
          (unsigned)r.sample_count);
    CHECK(r.cycle_sequence == 7 && r.nominal_hz == 60,
          "grid provenance must pass through");
    CHECK(r.valid_mask == 0x7F && r.flags == 0x1,
          "mask/flags provenance");
    CHECK(r.status == (1u << SCYC_STATUS_FIRST_AFTER_GAP_BIT),
          "first result after APPLY carries only the gap mark, got 0x%x",
          (unsigned)r.status);
    CHECK(r.frequency_millihz == 60000 && r.frequency_valid == 1,
          "frequency provenance");
    CHECK(r.processing_tick == 50040,
          "processing tick is the closing beat's PL tick, got %llu",
          (unsigned long long)r.processing_tick);

    take_record(b, words);
    CHECK(words[MREC_MAGIC_WORD] == MREC_MAGIC, "record magic");
    CHECK(words[MREC_FORMAT_WORD] == MREC_FORMAT_SCYC_V5, "record format");
    CHECK(words[MREC_SEQUENCE_WORD] == 1 && words[MREC_SAMPLE_COUNT_WORD] == 5,
          "record envelope sequence/count");
    CHECK(words[MREC_FIRST_SAMPLE_LOW_WORD] == 1005 &&
              words[MREC_FIRST_SAMPLE_HIGH_WORD] == 0,
          "record first-sample anchor");
    CHECK(words[SCYC_TIMING_WORD] == (60u | (1u << 8) | (0x1u << 16)),
          "record timing word, got 0x%08x", (unsigned)words[SCYC_TIMING_WORD]);
    CHECK(words[SCYC_CYCLE_SEQ_WORD] == 7, "record cycle sequence");
    CHECK(words[SCYC_LAST_SAMPLE_LOW_WORD] == 1009 &&
              words[SCYC_LAST_SAMPLE_HIGH_WORD] == 0,
          "record last-sample anchor");
    CHECK(words[SCYC_PROC_TICK_LOW_WORD] == 50040, "record processing tick");
    CHECK(words[SCYC_FREQ_VALUE_WORD] == 60000 &&
              words[SCYC_FREQ_STATUS_WORD] == 0x2,
          "record frequency words");

    // Gapless chaining: the next cycle starts at last + 1, mark cleared.
    for (int i = 0; i < 3; ++i) {
      FrameSpec h = b.leveled(f);
      h.sample_index = 1010 + i;
      h.cycle_sequence = 8;
      h.closes = (i == 2);
      b.send(h);
    }
    const single_cycle_result_t r2 =
        unpack_single_cycle_result(b.m_result.read());
    CHECK(r2.sequence == 2 && r2.first_sample == 1010 &&
              r2.last_sample == 1012 && r2.status == 0,
          "cycles must chain gaplessly with a clean status");
    take_record(b, words);
  }

  // --- StatisticsCore: exact integer golden model over one cycle. -------
  {
    unsigned long long base = settle(b, f, 6000);
    const int frames = 6;
    __int128 g_sum[MET_ACTIVE_CHANNELS] = {};
    unsigned __int128 g_square[MET_ACTIVE_CHANNELS] = {};
    long long g_raw_sum[MET_ACTIVE_CHANNELS] = {};
    unsigned __int128 g_raw_square[MET_ACTIVE_CHANNELS] = {};
    long long g_min[MET_ACTIVE_CHANNELS], g_max[MET_ACTIVE_CHANNELS];
    unsigned __int128 g_vll_square[MET_VLL_PAIRS] = {};
    unsigned long long g_vll_peak[MET_VLL_PAIRS] = {};
    __int128 g_power[3] = {};
    const int pv[3] = {MET_LANE_VA, MET_LANE_VB, MET_LANE_VC};
    const int pi_[3] = {MET_LANE_IA, MET_LANE_IB, MET_LANE_IC};
    const int minuend[MET_VLL_PAIRS] = {MET_LANE_VA, MET_LANE_VB, MET_LANE_VC};
    const int subtrahend[MET_VLL_PAIRS] = {MET_LANE_VB, MET_LANE_VC,
                                           MET_LANE_VA};
    for (int i = 0; i < frames; ++i) {
      FrameSpec g = b.leveled(f);
      g.sample_index = base + i;
      g.closes = (i == frames - 1);
      for (int lane = 0; lane < MET_ACTIVE_CHANNELS; ++lane) {
        const long long value =
            ((i % 2 == 0) ? 1 : -1) * (long long)((i + 1) * (lane + 1) * 1000);
        g.q16[lane] = value;
        g.raw[lane] = (int)(value / 3);
        g_sum[lane] += value;
        g_square[lane] += (unsigned __int128)((__int128)value * value);
        g_raw_sum[lane] += value / 3;
        g_raw_square[lane] +=
            (unsigned __int128)((__int128)(value / 3) * (value / 3));
        if (i == 0 || value < g_min[lane]) g_min[lane] = value;
        if (i == 0 || value > g_max[lane]) g_max[lane] = value;
      }
      for (int pair = 0; pair < MET_VLL_PAIRS; ++pair) {
        const long long diff = g.q16[minuend[pair]] - g.q16[subtrahend[pair]];
        g_vll_square[pair] += (unsigned __int128)((__int128)diff * diff);
        const unsigned long long mag =
            (unsigned long long)(diff < 0 ? -diff : diff);
        if (i == 0 || mag > g_vll_peak[pair]) g_vll_peak[pair] = mag;
      }
      for (int phase = 0; phase < 3; ++phase)
        g_power[phase] += (__int128)g.q16[pv[phase]] * g.q16[pi_[phase]];
      b.send(g);
    }
    const single_cycle_result_t rs =
        unpack_single_cycle_result(b.m_result.read());
    CHECK(rs.sample_count == (unsigned)frames && rs.status == 0,
          "statistics cycle count/status");
    for (int lane = 0; lane < MET_ACTIVE_CHANNELS; ++lane) {
      CHECK((rs.sum[lane] == ap_int<128>((long long)g_sum[lane])),
            "lane %d sum mismatch", lane);
      CHECK((rs.square[lane] ==
             (ap_uint<128>(ap_uint<64>(
                  (unsigned long long)(g_square[lane] >> 64)))
                  << 64) +
                 ap_uint<64>((unsigned long long)g_square[lane])),
            "lane %d square mismatch", lane);
      CHECK((rs.raw_sum[lane] == ap_int<64>(g_raw_sum[lane])),
            "lane %d raw sum mismatch", lane);
      CHECK((rs.raw_square[lane] ==
             ap_uint<96>(ap_uint<64>((unsigned long long)g_raw_square[lane]))),
            "lane %d raw square mismatch", lane);
      CHECK((rs.minimum[lane] == ap_int<64>(g_min[lane]) &&
             rs.maximum[lane] == ap_int<64>(g_max[lane])),
            "lane %d min/max mismatch", lane);
    }
    for (int pair = 0; pair < MET_VLL_PAIRS; ++pair) {
      CHECK((rs.vll_square[pair] ==
             ap_uint<128>(ap_uint<64>((unsigned long long)g_vll_square[pair]))),
            "pair %d vll square mismatch", pair);
      CHECK((rs.vll_peak[pair] == ap_uint<64>(g_vll_peak[pair])),
            "pair %d vll peak mismatch", pair);
    }
    for (int phase = 0; phase < 3; ++phase) {
      const bool negative = g_power[phase] < 0;
      const unsigned __int128 mag =
          (unsigned __int128)(negative ? -g_power[phase] : g_power[phase]);
      ap_int<128> expected =
          (ap_int<128>(ap_uint<64>((unsigned long long)(mag >> 64))) << 64) |
          ap_int<128>(ap_uint<64>((unsigned long long)mag));
      if (negative) expected = -expected;
      CHECK((rs.power_sum[phase] == expected), "phase %d power sum mismatch",
            phase);
    }
    take_record(b, words);
  }

  // --- The handover waveform matrix (whole-cycle golden scenarios). ------
  {
    unsigned long long base = settle(b, f, 40000);

    // Balanced ABC at 50 Hz, unity PF: VLL = sqrt(3)*VLN, P = V*I.
    WaveSpec balanced;
    const int vlanes[3] = {MET_LANE_VA, MET_LANE_VB, MET_LANE_VC};
    const int ilanes[3] = {MET_LANE_IA, MET_LANE_IB, MET_LANE_IC};
    const double abc[3] = {0.0, -120.0, 120.0};
    for (int p = 0; p < 3; ++p) {
      balanced.amp[vlanes[p]] = 120.0;
      balanced.phase_deg[vlanes[p]] = abc[p];
      balanced.amp[ilanes[p]] = 5.0;
      balanced.phase_deg[ilanes[p]] = abc[p];
    }
    base = 40000 + 4;
    run_wave(b, f, balanced, base, "balanced-abc-50hz");
    base += balanced.samples;

    // Reverse sequence ACB: swap the Vb/Vc (and Ib/Ic) phases.
    WaveSpec acb = balanced;
    acb.phase_deg[MET_LANE_VB] = 120.0;
    acb.phase_deg[MET_LANE_VC] = -120.0;
    acb.phase_deg[MET_LANE_IB] = 120.0;
    acb.phase_deg[MET_LANE_IC] = -120.0;
    run_wave(b, f, acb, base, "reverse-acb");
    base += acb.samples;

    // Unequal amplitudes (and a served neutral-ish small In stays 0).
    WaveSpec unequal = balanced;
    unequal.amp[MET_LANE_VA] = 100.0;
    unequal.amp[MET_LANE_VB] = 120.0;
    unequal.amp[MET_LANE_VC] = 80.0;
    unequal.amp[MET_LANE_IA] = 5.0;
    unequal.amp[MET_LANE_IB] = 3.0;
    unequal.amp[MET_LANE_IC] = 1.0;
    run_wave(b, f, unequal, base, "unequal-amplitudes");
    base += unequal.samples;

    // PF sweep at an off-nominal 62.5 Hz (512 samples): lagging and
    // leading 30/60/90 plus reverse power (180) and unity.
    const double sweep[8] = {0.0, -30.0, -60.0, -90.0, 30.0, 60.0, 90.0, 180.0};
    for (int step = 0; step < 8; ++step) {
      WaveSpec pf;
      pf.samples = 512;
      pf.freq_mhz = 62500;
      pf.amp[MET_LANE_VA] = 120.0;
      pf.amp[MET_LANE_IA] = 5.0;
      pf.phase_deg[MET_LANE_IA] = sweep[step];
      char name[48];
      std::snprintf(name, sizeof(name), "pf-sweep-%d", (int)sweep[step]);
      run_wave(b, f, pf, base, name);
      base += pf.samples;
    }

    // Zero current / zero voltage: power is exactly zero either way.
    WaveSpec zero_i;
    zero_i.amp[MET_LANE_VA] = 120.0;
    run_wave(b, f, zero_i, base, "zero-current");
    base += zero_i.samples;
    WaveSpec zero_v;
    zero_v.amp[MET_LANE_IA] = 5.0;
    run_wave(b, f, zero_v, base, "zero-voltage");
    base += zero_v.samples;

    // Zero signal: everything zero, status clean.
    WaveSpec silent;
    silent.check_phase = false;
    run_wave(b, f, silent, base, "zero-signal");
    base += silent.samples;

    // DC-only signal with dc_remove: AC RMS and fundamental stay zero.
    WaveSpec dc_only;
    dc_only.dc[MET_LANE_VA] = 3.0;
    dc_only.check_phase = false;
    const single_cycle_result_t rdc =
        run_wave(b, f, dc_only, base, "dc-only");
    CHECK((rdc.minimum[MET_LANE_VA] == 3 * 65536 &&
           rdc.maximum[MET_LANE_VA] == 3 * 65536),
          "dc-only min/max must both sit at the DC level");
    base += dc_only.samples;
  }

  // --- dc_remove semantics on a constant-DC lane. ------------------------
  {
    for (int pass = 0; pass < 2; ++pass) {
      const bool remove_dc = (pass == 0);
      FrameSpec g = f;
      g.dc_remove = remove_dc;
      // Contiguous run-up so the APPLY is the ONLY discontinuity: the
      // measured result must then carry the plain gap mark, no causes.
      unsigned long long base = settle(b, f, 70000ull + pass * 100);
      {
        FrameSpec carrier = b.applied(g);
        carrier.sample_index = base;
        b.send(carrier);  // commit dc_remove; discarded (await boundary)
      }
      // Boundary for the discarded window, then the measured cycle.
      {
        FrameSpec h = b.leveled(g);
        h.sample_index = base + 1;
        h.closes = true;
        b.send(h);
      }
      for (int i = 0; i < 4; ++i) {
        FrameSpec h = b.leveled(g);
        h.sample_index = base + 2 + i;
        for (int lane = 0; lane < MET_ACTIVE_CHANNELS; ++lane)
          h.q16[lane] = 65536 * 5;  // constant 5.0 in Q16
        h.closes = (i == 3);
        b.send(h);
      }
      const single_cycle_result_t rs =
          unpack_single_cycle_result(b.m_result.read());
      CHECK(rs.status == (1u << SCYC_STATUS_FIRST_AFTER_GAP_BIT),
            "dc_remove pass %d: only the APPLY gap mark, got 0x%x", pass,
            (unsigned)rs.status);
      take_record(b, words);
      const unsigned long long got = record_u64(words, SCYC_CH_BASE_WORD);
      // A constant has no AC content: with dc_remove the RMS is 0; without
      // it the total RMS is the DC level itself.
      const double expected = remove_dc ? 0.0 : 5.0;
      CHECK((std::fabs((double)got - expected) <= 1.0),
            "dc_remove=%d RMS: got %llu expected %.3f", remove_dc ? 1 : 0, got,
            expected);
    }
  }

  // --- Square saturation sets the per-cycle flag and clamps. -------------
  {
    unsigned long long base = settle(b, f, 80000);
    for (int i = 0; i < 5; ++i) {
      FrameSpec h = b.leveled(f);
      h.sample_index = base + i;
      h.q16[0] = 0x7FFFFFFFFFFFFFFFll;  // ~2^63: square ~2^126, x5 > 2^128
      h.closes = (i == 4);
      b.send(h);
    }
    const single_cycle_result_t rs =
        unpack_single_cycle_result(b.m_result.read());
    take_record(b, words);
    CHECK(rs.status == (1u << SCYC_STATUS_OVERFLOW_BIT),
          "saturation must set exactly the per-cycle flag, got 0x%x",
          (unsigned)rs.status);
    CHECK((rs.square[0] == ~ap_uint<128>(0)),
          "saturated square must clamp to all-ones");
    CHECK((rs.sum[0] == ap_int<128>(ap_int<64>(0x7FFFFFFFFFFFFFFFll)) * 5),
          "sum stays exact under square saturation");
  }

  // --- PhasorCore: harmonic rejection at 64 Hz (500 samples). ------------
  {
    unsigned long long base = settle(b, f, 90000);
    const int cycle_samples = 500;
    const double amplitude = 65536.0 * 100.0;
    const double ia_amplitude = 65536.0 * 10.0;
    const double phi_ia = -60.0 * M_PI / 180.0;
    for (int pass = 0; pass < 2; ++pass) {
      const bool with_harmonic = (pass == 1);
      for (int i = 0; i < cycle_samples; ++i) {
        FrameSpec h = b.leveled(f);
        h.freq_mhz = 64000;
        h.sample_index = base + i;
        const double theta = 2.0 * M_PI * i / cycle_samples;
        double va = amplitude * std::sin(theta);
        if (with_harmonic) va += 0.1 * amplitude * std::sin(3.0 * theta);
        h.q16[MET_LANE_VA] = (long long)std::llround(va);
        h.q16[MET_LANE_IA] =
            (long long)std::llround(ia_amplitude * std::sin(theta + phi_ia));
        h.closes = (i == cycle_samples - 1);
        b.send(h);
      }
      base += cycle_samples;
      const single_cycle_result_t rs =
          unpack_single_cycle_result(b.m_result.read());
      CHECK(rs.status == 0, "phasor pass %d: clean status, got 0x%x", pass,
            (unsigned)rs.status);
      take_record(b, words);

      const double expected_fund = amplitude / std::sqrt(2.0) / 65536.0;
      const unsigned long long got_fund = record_u64(
          words, SCYC_FUND_BASE_WORD + MET_LANE_VA * SCYC_CH_STRIDE_WORDS);
      CHECK((std::fabs((double)got_fund - expected_fund) <=
             expected_fund * 0.002 + 2.0),
            "pass %d Va fundamental RMS: got %llu expected %.1f", pass,
            got_fund, expected_fund);

      const unsigned long long got_total = record_u64(
          words, SCYC_CH_BASE_WORD + MET_LANE_VA * SCYC_CH_STRIDE_WORDS);
      const double expected_total =
          with_harmonic ? expected_fund * std::sqrt(1.01) : expected_fund;
      CHECK((std::fabs((double)got_total - expected_total) <=
             expected_total * 0.002 + 2.0),
            "pass %d Va total RMS: got %llu expected %.1f", pass, got_total,
            expected_total);

      const double re = (double)(long long)ap_int<64>(
          (rs.phasor_re[MET_LANE_IA] >> 37).range(63, 0));
      const double im = (double)(long long)ap_int<64>(
          (rs.phasor_im[MET_LANE_IA] >> 37).range(63, 0));
      const double phi = std::atan2(re, -im) * 180.0 / M_PI;
      CHECK((std::fabs(phi - (-60.0)) <= 0.05),
            "pass %d Ia phase: got %.3f deg expected -60", pass, phi);
    }
  }

  // --- Invalid frequency reference: phasor gated, flagged, zeroed. -------
  {
    unsigned long long base = settle(b, f, 95000);
    for (int i = 0; i < 4; ++i) {
      FrameSpec h = b.leveled(f);
      h.freq_status = 0;  // FREQUENCY_STATUS_VALID clear
      h.sample_index = base + i;
      h.q16[MET_LANE_VA] = 65536 * 10;
      h.closes = (i == 3);
      b.send(h);
    }
    const single_cycle_result_t rs =
        unpack_single_cycle_result(b.m_result.read());
    take_record(b, words);
    CHECK(rs.status == (1u << SCYC_STATUS_PHASOR_INVALID_BIT),
          "invalid reference must set exactly status bit 1, got 0x%x",
          (unsigned)rs.status);
    CHECK((rs.phasor_re[MET_LANE_VA] == 0 && rs.phasor_im[MET_LANE_VA] == 0),
          "phasor sections must zero without a reference");
    CHECK(words[SCYC_FUND_BASE_WORD + MET_LANE_VA * SCYC_CH_STRIDE_WORDS] == 0,
          "fundamental RMS words must zero without a reference");
  }

  // --- Timing fallback flag passes through untouched. ---------------------
  {
    unsigned long long base = settle(b, f, 96000);
    for (int i = 0; i < 3; ++i) {
      FrameSpec h = b.leveled(f);
      h.flags = 0x2;  // MET_FLAG_FALLBACK
      h.sample_index = base + i;
      h.closes = (i == 2);
      b.send(h);
    }
    const single_cycle_result_t rs =
        unpack_single_cycle_result(b.m_result.read());
    take_record(b, words);
    CHECK(rs.flags == 0x2 && ((words[SCYC_TIMING_WORD] >> 16) & 0x7) == 0x2,
          "fallback flag must propagate to beat and record");
  }

  // --- Invalid channel: the committed mask gates the result mask. --------
  {
    // Commit a configuration whose mask excludes Ic (lane 2).
    FrameSpec g = f;
    g.cfg_mask = 0x7B;
    unsigned long long base = 97000;
    {
      FrameSpec carrier = b.applied(g);
      carrier.sample_index = base;
      b.send(carrier);
    }
    {
      FrameSpec h = b.leveled(g);
      h.sample_index = base + 1;
      h.closes = true;
      b.send(h);
    }
    for (int i = 0; i < 3; ++i) {
      FrameSpec h = b.leveled(g);
      h.sample_index = base + 2 + i;
      h.closes = (i == 2);
      b.send(h);
    }
    const single_cycle_result_t rs =
        unpack_single_cycle_result(b.m_result.read());
    take_record(b, words);
    CHECK(rs.valid_mask == 0x7B,
          "committed mask must gate the result mask, got 0x%x",
          (unsigned)rs.valid_mask);
    // Restore the full mask for the scenarios below.
    FrameSpec restore = f;
    unsigned long long rbase = base + 5;
    {
      FrameSpec carrier = b.applied(restore);
      carrier.sample_index = rbase;
      b.send(carrier);
    }
    {
      FrameSpec h = b.leveled(restore);
      h.sample_index = rbase + 1;
      h.closes = true;
      b.send(h);
    }
  }

  // --- Malformed frame: window discarded, next WHOLE cycle marked. -------
  {
    unsigned long long base = settle(b, f, 98000);
    FrameSpec g = b.leveled(f);
    g.sample_index = base;
    b.send(g);
    g = b.leveled(f);
    g.sample_index = base + 1;
    g.malformed = true;
    b.send(g);
    // These frames belong to the interrupted cycle: discarded up to and
    // including the boundary.
    for (int i = 0; i < 2; ++i) {
      FrameSpec h = b.leveled(f);
      h.sample_index = base + 2 + i;
      h.closes = (i == 1);
      b.send(h);
    }
    CHECK(b.m_result.empty() && b.m_axis.empty(),
          "no partial-cycle products after a malformed frame");
    for (int i = 0; i < 2; ++i) {
      FrameSpec h = b.leveled(f);
      h.sample_index = base + 4 + i;
      h.closes = (i == 1);
      b.send(h);
    }
    const single_cycle_result_t r3 =
        unpack_single_cycle_result(b.m_result.read());
    CHECK(r3.first_sample == base + 4 && r3.sample_count == 2,
          "the next whole cycle follows the discarded one");
    CHECK(r3.status == ((1u << SCYC_STATUS_FIRST_AFTER_GAP_BIT) |
                        (1u << SCYC_STATUS_GAP_MALFORMED_BIT)),
          "malformed gap must mark first-after-gap + malformed, got 0x%x",
          (unsigned)r3.status);
    take_record(b, words);
  }

  // --- Dropped beat (sample-index jump) inside a window. ------------------
  {
    unsigned long long base = settle(b, f, 99000);
    FrameSpec g = b.leveled(f);
    g.sample_index = base;
    b.send(g);
    // The next beat vanished: the following frame jumps by 2.
    g = b.leveled(f);
    g.sample_index = base + 2;
    g.closes = true;  // boundary of the interrupted cycle: still discarded
    b.send(g);
    CHECK(b.m_result.empty() && b.m_axis.empty(),
          "no products across a sample-index hole");
    for (int i = 0; i < 2; ++i) {
      FrameSpec h = b.leveled(f);
      h.sample_index = base + 3 + i;
      h.closes = (i == 1);
      b.send(h);
    }
    const single_cycle_result_t rs =
        unpack_single_cycle_result(b.m_result.read());
    CHECK(rs.first_sample == base + 3 && rs.sample_count == 2,
          "accumulation restarts after the hole's boundary");
    CHECK(rs.status == ((1u << SCYC_STATUS_FIRST_AFTER_GAP_BIT) |
                        (1u << SCYC_STATUS_GAP_MALFORMED_BIT)),
          "a dropped beat must mark first-after-gap + malformed, got 0x%x",
          (unsigned)rs.status);
    take_record(b, words);
  }

  // --- Unlocked cycle timing pauses production and marks the cause. ------
  {
    unsigned long long base = settle(b, f, 100000);
    FrameSpec g = b.leveled(f);
    g.sample_index = base;
    b.send(g);
    g = b.leveled(f);
    g.sample_index = base + 1;
    g.cycle_mode = false;
    g.closes = true;  // must be ignored without locked timing
    b.send(g);
    CHECK(b.m_result.empty() && b.m_axis.empty(),
          "no products without locked cycle timing");
    // Relock: boundary discarded, then a whole cycle marked with the cause.
    {
      FrameSpec h = b.leveled(f);
      h.sample_index = base + 2;
      h.closes = true;
      b.send(h);
    }
    for (int i = 0; i < 2; ++i) {
      FrameSpec h = b.leveled(f);
      h.sample_index = base + 3 + i;
      h.closes = (i == 1);
      b.send(h);
    }
    const single_cycle_result_t rs =
        unpack_single_cycle_result(b.m_result.read());
    CHECK(rs.status == ((1u << SCYC_STATUS_FIRST_AFTER_GAP_BIT) |
                        (1u << SCYC_STATUS_GAP_TIMING_BIT)),
          "timing loss must mark first-after-gap + timing, got 0x%x",
          (unsigned)rs.status);
    take_record(b, words);
  }

  // --- Stale generation after APPLY: rejected, marked as a plain gap. ----
  {
    FrameSpec g = f;
    g.cfg_generation = 2;
    unsigned long long base = 101000;
    {
      FrameSpec carrier = b.applied(g);
      carrier.sample_index = base;
      b.send(carrier);  // carrier still tagged generation 1: stale
    }
    for (int i = 0; i < 2; ++i) {
      FrameSpec h = b.leveled(g);
      h.generation = 2;
      h.sample_index = base + 1 + i;
      h.closes = (i == 1);
      b.send(h);
    }
    CHECK(b.m_result.empty(), "the catch-up cycle is discarded, not emitted");
    for (int i = 0; i < 2; ++i) {
      FrameSpec h = b.leveled(g);
      h.generation = 2;
      h.sample_index = base + 3 + i;
      h.closes = (i == 1);
      b.send(h);
    }
    const single_cycle_result_t r4 =
        unpack_single_cycle_result(b.m_result.read());
    CHECK(r4.generation == 2 && r4.first_sample == base + 3 &&
              r4.sample_count == 2,
          "stale carrier must be rejected; new generation accumulates");
    CHECK(r4.status == (1u << SCYC_STATUS_FIRST_AFTER_GAP_BIT),
          "an APPLY transition is a plain gap (no malformed bit), got 0x%x",
          (unsigned)r4.status);
    take_record(b, words);
  }

  // --- Disable stops everything. -----------------------------------------
  {
    FrameSpec g = f;
    g.enable = false;
    g.generation = 2;
    g.cfg_generation = 2;
    g.sample_index = 102000;
    g.closes = true;
    b.send(b.applied(g));
    CHECK(b.m_result.empty() && b.m_axis.empty(), "disabled engine is silent");
  }

  if (failures != 0) {
    std::printf("FAILED: %d check(s)\n", failures);
    return EXIT_FAILURE;
  }
  std::printf("PASS: single_cycle_engine_tb\n");
  return EXIT_SUCCESS;
}
