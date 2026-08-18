// Testbench for the single-cycle measurement engine (M2: provenance).
//
// The engine is a deterministic window machine in this milestone, so the
// bench drives explicit frame sequences and checks exact expectations:
// result-beat fields, SCYC-v1 record words, 64-beat framing, and the
// window-clearing rules (APPLY, stale generation, malformed frames,
// unlocked cycle timing). The same source runs as csim and cosim.

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
  static_assert(SCYC_BEAT_BITS == 512, "result beat width is normative");

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
  CHECK(words[MREC_FORMAT_WORD] == MREC_FORMAT_SCYC_V1, "record format");
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
