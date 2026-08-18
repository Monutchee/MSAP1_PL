// Testbench for the single-cycle measurement engine (M2: provenance).
//
// The engine is a deterministic window machine in this milestone, so the
// bench drives explicit frame sequences and checks exact expectations:
// result-beat fields, SCYC-v1 record words, 64-beat framing, and the
// window-clearing rules (APPLY, stale generation, malformed frames,
// unlocked cycle timing). The same source runs as csim and cosim.

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

int main() {
  static_assert(SCYC_IN_BITS == 1152, "input beat width is normative");
  static_assert(SCYC_BEAT_BITS == 5280, "result beat width is normative");

  Bench b;

  // --- Configure via APPLY, run one 5-frame cycle, check everything. ----
  FrameSpec f;
  f.sample_index = 1000;
  f.pl_tick = 50000;
  f.cycle_sequence = 7;
  b.send(b.applied(f));  // APPLY carrier; window starts on this frame
  for (int i = 1; i < 5; ++i) {
    FrameSpec g = b.leveled(f);
    g.sample_index = 1000 + i;
    g.pl_tick = 50000 + 10 * i;
    g.closes = (i == 4);
    b.send(g);
  }
  CHECK(b.m_result.size() == 1, "one cycle must yield one result beat");
  const single_cycle_result_t r =
      unpack_single_cycle_result(b.m_result.read());
  CHECK(r.sequence == 1, "first result carries sequence 1, got %u",
        (unsigned)r.sequence);
  CHECK(r.first_sample == 1000 && r.last_sample == 1004,
        "sample anchors must span the cycle (%llu..%llu)",
        (unsigned long long)r.first_sample, (unsigned long long)r.last_sample);
  CHECK(r.sample_count == 5, "five frames accumulated, got %u",
        (unsigned)r.sample_count);
  CHECK(r.cycle_sequence == 7 && r.nominal_hz == 60,
        "grid provenance must pass through");
  CHECK(r.valid_mask == 0x7F && r.flags == 0x1 && r.status == 0,
        "mask/flags/status provenance");
  CHECK(r.frequency_millihz == 60000 && r.frequency_valid == 1,
        "frequency provenance");
  CHECK(r.processing_tick == 50040,
        "processing tick is the closing beat's PL tick, got %llu",
        (unsigned long long)r.processing_tick);

  ap_uint<32> words[MREC_WORDS];
  take_record(b, words);
  CHECK(words[MREC_MAGIC_WORD] == MREC_MAGIC, "record magic");
  CHECK(words[MREC_FORMAT_WORD] == MREC_FORMAT_SCYC_V3, "record format");
  CHECK(words[MREC_SEQUENCE_WORD] == 1 && words[MREC_SAMPLE_COUNT_WORD] == 5,
        "record envelope sequence/count");
  CHECK(words[MREC_FIRST_SAMPLE_LOW_WORD] == 1000 &&
            words[MREC_FIRST_SAMPLE_HIGH_WORD] == 0,
        "record first-sample anchor");
  CHECK(words[SCYC_TIMING_WORD] == (60u | (1u << 8) | (0x1u << 16)),
        "record timing word, got 0x%08x", (unsigned)words[SCYC_TIMING_WORD]);
  CHECK(words[SCYC_CYCLE_SEQ_WORD] == 7, "record cycle sequence");
  CHECK(words[SCYC_LAST_SAMPLE_LOW_WORD] == 1004 &&
            words[SCYC_LAST_SAMPLE_HIGH_WORD] == 0,
        "record last-sample anchor");
  CHECK(words[SCYC_PROC_TICK_LOW_WORD] == 50040, "record processing tick");
  CHECK(words[SCYC_FREQ_VALUE_WORD] == 60000 &&
            words[SCYC_FREQ_STATUS_WORD] == 0x2,
        "record frequency words");

  // --- Gapless chaining: the next cycle starts at last + 1. -------------
  for (int i = 0; i < 3; ++i) {
    FrameSpec g = b.leveled(f);
    g.sample_index = 1005 + i;
    g.cycle_sequence = 8;
    g.closes = (i == 2);
    b.send(g);
  }
  const single_cycle_result_t r2 =
      unpack_single_cycle_result(b.m_result.read());
  CHECK(r2.sequence == 2 && r2.first_sample == 1005 && r2.last_sample == 1007,
        "cycles must chain gaplessly");
  take_record(b, words);

  // --- StatisticsCore: exact integer golden model over one cycle. -------
  {
    // Distinct deterministic samples: lane value = (i+1)*(lane+1) with
    // alternating sign; raw = lane value / 3. Small enough for exact
    // __int128 reference arithmetic.
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
    const int pi[3] = {MET_LANE_IA, MET_LANE_IB, MET_LANE_IC};
    const int minuend[MET_VLL_PAIRS] = {MET_LANE_VA, MET_LANE_VB, MET_LANE_VC};
    const int subtrahend[MET_VLL_PAIRS] = {MET_LANE_VB, MET_LANE_VC,
                                           MET_LANE_VA};
    for (int i = 0; i < frames; ++i) {
      FrameSpec g = b.leveled(f);
      g.sample_index = 6000 + i;
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
        g_power[phase] += (__int128)g.q16[pv[phase]] * g.q16[pi[phase]];
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

    // Record diagnostic RMS vs a double reference (dc_remove active).
    take_record(b, words);
    for (int lane = 0; lane < MET_ACTIVE_CHANNELS; ++lane) {
      const double mean = (double)(long long)g_sum[lane] / frames;
      const double mean_square = (double)g_square[lane] / frames;
      const double rms_q16 = std::sqrt(mean_square - mean * mean);
      const int base = SCYC_CH_BASE_WORD + lane * SCYC_CH_STRIDE_WORDS;
      const unsigned long long got =
          (unsigned long long)words[base] |
          ((unsigned long long)words[base + 1] << 32);
      const double expected_units = rms_q16 / 65536.0;
      CHECK((std::fabs((double)got - expected_units) <= 2.0),
            "lane %d record RMS: got %llu expected %.2f", lane, got,
            expected_units);
    }
    for (int pair = 0; pair < MET_VLL_PAIRS; ++pair) {
      const double mean_square = (double)g_vll_square[pair] / frames;
      const double rms_units = std::sqrt(mean_square) / 65536.0;
      const int base = SCYC_VLL_BASE_WORD + pair * SCYC_CH_STRIDE_WORDS;
      const unsigned long long got =
          (unsigned long long)words[base] |
          ((unsigned long long)words[base + 1] << 32);
      CHECK((std::fabs((double)got - rms_units) <= 2.0),
            "pair %d record VLL RMS: got %llu expected %.2f", pair, got,
            rms_units);
    }
  }

  // --- dc_remove semantics on a constant-DC lane. ------------------------
  {
    for (int pass = 0; pass < 2; ++pass) {
      const bool remove_dc = (pass == 0);
      FrameSpec g = f;
      g.dc_remove = remove_dc;
      g.sample_index = 7000 + pass * 10;
      b.send(b.applied(g));  // commit dc_remove; carrier rejected (stale? no:
                             // generation unchanged, so it accumulates)
      for (int i = 1; i < 4; ++i) {
        FrameSpec h = b.leveled(g);
        h.sample_index = 7000 + pass * 10 + i;
        for (int lane = 0; lane < MET_ACTIVE_CHANNELS; ++lane)
          h.q16[lane] = 65536 * 5;  // constant 5.0 in Q16
        h.closes = (i == 3);
        b.send(h);
      }
      (void)b.m_result.read();
      take_record(b, words);
      const unsigned long long got =
          (unsigned long long)words[SCYC_CH_BASE_WORD] |
          ((unsigned long long)words[SCYC_CH_BASE_WORD + 1] << 32);
      // First frame carries zeros, three frames carry 5.0: with dc_remove
      // the AC RMS is nonzero (a step is AC); without it total RMS is
      // sqrt(3/4)*5 ~ 4.33 units. Pin both against the double model.
      const double mean = (3.0 * 5.0) / 4.0;
      const double mean_square = (3.0 * 25.0) / 4.0;
      const double expected =
          remove_dc ? std::sqrt(mean_square - mean * mean) : std::sqrt(mean_square);
      CHECK((std::fabs((double)got - expected) <= 1.0),
            "dc_remove=%d RMS: got %llu expected %.3f", remove_dc ? 1 : 0, got,
            expected);
    }
  }

  // --- Square saturation sets the per-cycle flag and clamps. -------------
  {
    FrameSpec g = b.leveled(f);
    g.sample_index = 8000;
    for (int i = 0; i < 5; ++i) {
      FrameSpec h = b.leveled(g);
      h.sample_index = 8000 + i;
      h.q16[0] = 0x7FFFFFFFFFFFFFFFll;  // ~2^63: square ~2^126, x5 > 2^128
      h.closes = (i == 4);
      b.send(h);
    }
    const single_cycle_result_t rs =
        unpack_single_cycle_result(b.m_result.read());
    take_record(b, words);
    CHECK((rs.status & 1) == 1, "saturation must set the per-cycle flag");
    CHECK((rs.square[0] == ~ap_uint<128>(0)),
          "saturated square must clamp to all-ones");
    CHECK((rs.sum[0] == ap_int<128>(ap_int<64>(0x7FFFFFFFFFFFFFFFll)) * 5),
          "sum stays exact under square saturation");
  }

  // --- Reverse power: current anti-phase to voltage -> negative P. ------
  {
    const long long volts_q16[4] = {65536 * 100, -65536 * 100, 65536 * 50,
                                    -65536 * 50};
    __int128 g_power = 0;
    for (int i = 0; i < 4; ++i) {
      FrameSpec h = b.leveled(f);
      h.sample_index = 9000 + i;
      h.q16[MET_LANE_VA] = volts_q16[i];
      h.q16[MET_LANE_IA] = -volts_q16[i] / 20;  // export at PF 1
      g_power += (__int128)h.q16[MET_LANE_VA] * h.q16[MET_LANE_IA];
      h.closes = (i == 3);
      b.send(h);
    }
    const single_cycle_result_t rs =
        unpack_single_cycle_result(b.m_result.read());
    CHECK((rs.power_sum[0] < 0), "export must be negative (sign convention)");
    take_record(b, words);
    const long long got =
        (long long)((unsigned long long)words[SCYC_POWER_BASE_WORD] |
                    ((unsigned long long)words[SCYC_POWER_BASE_WORD + 1]
                     << 32));
    const double expected_pw = (double)g_power / 4.0 / 4294967296.0;
    CHECK((std::fabs((double)got - expected_pw) <= 1.0),
          "reverse power record: got %lld expected %.1f pW", got, expected_pw);
    CHECK(got < 0, "record power word must carry the export sign");
  }

  // --- A malformed frame clears the running window. ---------------------
  {
    FrameSpec g = b.leveled(f);
    g.sample_index = 2000;
    b.send(g);
    g.sample_index = 2001;
    g.malformed = true;
    b.send(g);
    // The window restarts on the next good frame.
    for (int i = 0; i < 2; ++i) {
      FrameSpec h = b.leveled(f);
      h.sample_index = 2002 + i;
      h.closes = (i == 1);
      b.send(h);
    }
    const single_cycle_result_t r3 =
        unpack_single_cycle_result(b.m_result.read());
    CHECK(r3.first_sample == 2002 && r3.sample_count == 2,
          "malformed frame must discard the running window");
    take_record(b, words);
  }

  // --- Unlocked cycle timing pauses single-cycle production. -------------
  {
    FrameSpec g = b.leveled(f);
    g.sample_index = 3000;
    b.send(g);
    g.sample_index = 3001;
    g.cycle_mode = false;
    g.closes = true;  // must be ignored without locked timing
    b.send(g);
    CHECK(b.m_result.empty() && b.m_axis.empty(),
          "no products without locked cycle timing");
  }

  // --- Stale generation after APPLY is rejected until it catches up. ----
  {
    FrameSpec g = f;
    g.cfg_generation = 2;
    g.sample_index = 4000;
    b.send(b.applied(g));  // carrier still tagged generation 1: stale
    for (int i = 0; i < 2; ++i) {
      FrameSpec h = b.leveled(g);
      h.generation = 2;
      h.sample_index = 4001 + i;
      h.closes = (i == 1);
      b.send(h);
    }
    const single_cycle_result_t r4 =
        unpack_single_cycle_result(b.m_result.read());
    CHECK(r4.generation == 2 && r4.first_sample == 4001 &&
              r4.sample_count == 2,
          "stale carrier must be rejected; new generation accumulates");
    take_record(b, words);
  }

  // --- Disable stops everything. -----------------------------------------
  {
    FrameSpec g = f;
    g.enable = false;
    g.generation = 2;
    g.cfg_generation = 2;
    g.sample_index = 5000;
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
