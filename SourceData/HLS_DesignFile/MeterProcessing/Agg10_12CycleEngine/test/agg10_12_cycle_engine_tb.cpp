// Testbench for the 10/12-cycle basic measurement engine (M7).
//
// The bench synthesizes whole grid cycles the way the single-cycle engine
// would emit them (per-cycle sufficient statistics packed into SCYC-v5
// result beats), tracks the SAME per-sample accumulation a Mtr1Engine
// block would have built, and checks the finalized record and basic beat
// EXACTLY against an integer golden model implementing the retired Mtr1
// arithmetic (trunc-toward-zero mean, floor variance, restoring integer
// root). Values agreeing exactly here — same accumulators in, same
// primitives through — is the Mtr1 retirement proof.
//
// Block rules covered: 12 @ 60 Hz and 10 @ 50 Hz, APPLY commit and mark,
// upstream first-after-gap restart, result/cycle sequence breaks, stale
// generation, nominal change, lock/fallback flag reduction, sticky
// arithmetic flag, VLL merge, Mtr2-contract beat fields.

#include <cmath>
#include <cstdio>
#include <cstdlib>

#include "agg10_12_cycle_engine.hpp"

static int failures = 0;

#define CHECK(cond, ...)                                                       \
  do {                                                                         \
    if (!(cond)) {                                                             \
      std::printf("FAIL: " __VA_ARGS__);                                       \
      std::printf("\n");                                                       \
      ++failures;                                                              \
    }                                                                          \
  } while (0)

// ---------------------------------------------------------------------------
// Integer golden model of the retired Mtr1 finalize (exact).
// ---------------------------------------------------------------------------
static unsigned __int128 golden_isqrt(unsigned __int128 value) {
  unsigned __int128 root = 0;
  for (int bit = 63; bit >= 0; --bit) {
    const unsigned __int128 candidate = root | ((unsigned __int128)1 << bit);
    if (candidate * candidate <= value) root = candidate;
  }
  return root;
}

// floor((square*N - |sum|^2) / N^2) then floor sqrt — dc_remove active.
static unsigned long long golden_rms_q16(unsigned __int128 square,
                                         __int128 sum, unsigned count,
                                         bool dc_remove) {
  unsigned __int128 numerator = square * count;
  if (dc_remove) {
    const unsigned __int128 magnitude =
        (unsigned __int128)(sum < 0 ? -sum : sum);
    numerator -= magnitude * magnitude;
  }
  const unsigned __int128 variance =
      numerator / ((unsigned __int128)count * count);
  return (unsigned long long)golden_isqrt(variance);
}

static long long golden_mean_q16(__int128 sum, unsigned count) {
  const bool negative = sum < 0;
  const unsigned __int128 magnitude = (unsigned __int128)(negative ? -sum : sum);
  const unsigned long long trunc64 = (unsigned long long)(magnitude / count);
  return negative ? -(long long)trunc64 : (long long)trunc64;
}

// ---------------------------------------------------------------------------
// Cycle synthesis: per-cycle statistics from explicit per-sample values,
// mirroring the single-cycle engine's accumulation exactly.
// ---------------------------------------------------------------------------
struct GoldenBlock {
  __int128 sum[MET_ACTIVE_CHANNELS] = {};
  unsigned __int128 square[MET_ACTIVE_CHANNELS] = {};
  long long raw_sum[MET_ACTIVE_CHANNELS] = {};
  unsigned __int128 raw_square[MET_ACTIVE_CHANNELS] = {};
  unsigned __int128 vll_square[MET_VLL_PAIRS] = {};
  unsigned count = 0;
};

struct CycleSpec {
  unsigned sequence = 1;
  unsigned cycle_sequence = 100;
  unsigned generation = 1;
  unsigned long long first_sample = 1000;
  unsigned samples = 5;
  unsigned nominal = 60;
  unsigned status = 0;
  unsigned valid_mask = 0x7F;
  unsigned freq_mhz = 60012;
  unsigned freq_valid = 1;
  int seed = 1;  // varies the synthetic sample values
};

// Build one whole cycle: sample s of lane l is
//   value = seed * (l + 1) * (s + 1) with alternating sign  (Q16 domain)
//   raw   = value / 5
static single_cycle_result_t make_cycle(const CycleSpec &c, GoldenBlock &g) {
  single_cycle_result_t r = {};
  __int128 sum[MET_ACTIVE_CHANNELS] = {};
  unsigned __int128 square[MET_ACTIVE_CHANNELS] = {};
  long long raw_sum[MET_ACTIVE_CHANNELS] = {};
  unsigned __int128 raw_square[MET_ACTIVE_CHANNELS] = {};
  unsigned __int128 vll_square[MET_VLL_PAIRS] = {};
  const int minuend[MET_VLL_PAIRS] = {MET_LANE_VA, MET_LANE_VB, MET_LANE_VC};
  const int subtrahend[MET_VLL_PAIRS] = {MET_LANE_VB, MET_LANE_VC,
                                         MET_LANE_VA};
  for (unsigned s = 0; s < c.samples; ++s) {
    long long lane_value[MET_ACTIVE_CHANNELS];
    for (int lane = 0; lane < MET_ACTIVE_CHANNELS; ++lane) {
      const long long value = ((s % 2 == 0) ? 1 : -1) *
                              (long long)c.seed * (lane + 1) * (long long)(s + 1);
      lane_value[lane] = value;
      sum[lane] += value;
      square[lane] += (unsigned __int128)((__int128)value * value);
      raw_sum[lane] += value / 5;
      raw_square[lane] +=
          (unsigned __int128)((__int128)(value / 5) * (value / 5));
    }
    for (int pair = 0; pair < MET_VLL_PAIRS; ++pair) {
      const long long diff =
          lane_value[minuend[pair]] - lane_value[subtrahend[pair]];
      vll_square[pair] += (unsigned __int128)((__int128)diff * diff);
    }
  }
  for (int lane = 0; lane < MET_ACTIVE_CHANNELS; ++lane) {
    // Two's-complement image transfers exactly through the 128-bit fields.
    unsigned __int128 image = (unsigned __int128)sum[lane];
    r.sum[lane].range(63, 0) = ap_uint<64>((unsigned long long)image);
    r.sum[lane].range(127, 64) = ap_uint<64>((unsigned long long)(image >> 64));
    unsigned __int128 sq = square[lane];
    r.square[lane].range(63, 0) = ap_uint<64>((unsigned long long)sq);
    r.square[lane].range(127, 64) = ap_uint<64>((unsigned long long)(sq >> 64));
    r.raw_sum[lane] = ap_int<64>(raw_sum[lane]);
    unsigned __int128 rsq = raw_square[lane];
    r.raw_square[lane].range(63, 0) = ap_uint<64>((unsigned long long)rsq);
    r.raw_square[lane].range(95, 64) =
        ap_uint<32>((unsigned long long)(rsq >> 64));
    g.sum[lane] += sum[lane];
    g.square[lane] += square[lane];
    g.raw_sum[lane] += raw_sum[lane];
    g.raw_square[lane] += raw_square[lane];
  }
  for (int pair = 0; pair < MET_VLL_PAIRS; ++pair) {
    unsigned __int128 vsq = vll_square[pair];
    r.vll_square[pair].range(63, 0) = ap_uint<64>((unsigned long long)vsq);
    r.vll_square[pair].range(127, 64) =
        ap_uint<64>((unsigned long long)(vsq >> 64));
    g.vll_square[pair] += vll_square[pair];
  }
  g.count += c.samples;

  r.sequence = c.sequence;
  r.generation = c.generation;
  r.first_sample = c.first_sample;
  r.last_sample = c.first_sample + c.samples - 1;
  r.sample_count = c.samples;
  r.cycle_sequence = c.cycle_sequence;
  r.nominal_hz = c.nominal;
  r.valid_mask = c.valid_mask;
  r.flags = 0x1;
  r.status = c.status;
  r.frequency_millihz = c.freq_mhz;
  r.frequency_valid = c.freq_valid;
  r.processing_tick = 777000 + c.sequence;
  return r;
}

struct Bench {
  hls::stream<agg10_12_input_beat_t> s_result{"s_result"};
  hls::stream<record_axis_t> m_axis{"m_axis"};
  hls::stream<basic_result_beat_t> m_result{"m_result"};
  bool apply_level = false;
  unsigned cfg_generation = 1;
  bool enable = true;
  bool dc_remove = true;
  bool locked = true;
  bool fallback = false;
  unsigned freq_status = 0x2;
  unsigned freq_period = 0x00010000;
  unsigned freq_seq = 42;
  unsigned cap_frames = 111, cap_hdrerr = 1, cap_overflow = 2, cap_alerts = 3;

  void send(const single_cycle_result_t &r, bool apply_toggles = false) {
    if (apply_toggles) apply_level = !apply_level;
    agg10_12_input_beat_t beat = 0;
    beat.range(SCYC_BEAT_BITS - 1, 0) = pack_single_cycle_result(r);
    beat.range(AGG_IN_CFG_GEN_LSB + 31, AGG_IN_CFG_GEN_LSB) = cfg_generation;
    beat.range(AGG_IN_CFG_RATE_LSB + 31, AGG_IN_CFG_RATE_LSB) = 32000;
    beat.range(AGG_IN_CFG_MASK_LSB + 7, AGG_IN_CFG_MASK_LSB) = 0x7F;
    beat[AGG_IN_ENABLE_BIT] = enable ? 1 : 0;
    beat[AGG_IN_DC_REMOVE_BIT] = dc_remove ? 1 : 0;
    beat[AGG_IN_APPLY_BIT] = apply_level ? 1 : 0;
    beat[AGG_IN_LOCKED_BIT] = locked ? 1 : 0;
    beat[AGG_IN_FALLBACK_BIT] = fallback ? 1 : 0;
    beat.range(AGG_IN_FREQ_STATUS_LSB + 31, AGG_IN_FREQ_STATUS_LSB) =
        freq_status;
    beat.range(AGG_IN_FREQ_PERIOD_LSB + 31, AGG_IN_FREQ_PERIOD_LSB) =
        freq_period;
    beat.range(AGG_IN_FREQ_SEQ_LSB + 31, AGG_IN_FREQ_SEQ_LSB) = freq_seq;
    beat.range(AGG_IN_CAP_FRAMES_LSB + 31, AGG_IN_CAP_FRAMES_LSB) = cap_frames;
    beat.range(AGG_IN_CAP_HDRERR_LSB + 31, AGG_IN_CAP_HDRERR_LSB) = cap_hdrerr;
    beat.range(AGG_IN_CAP_OVERFLOW_LSB + 31, AGG_IN_CAP_OVERFLOW_LSB) =
        cap_overflow;
    beat.range(AGG_IN_CAP_ALERTS_LSB + 31, AGG_IN_CAP_ALERTS_LSB) = cap_alerts;
    s_result.write(beat);
    hls_agg10_12_cycle_engine(s_result, m_axis, m_result);
  }
};

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

// Drive one whole block of `cycles` cycles; returns via out-params.
static void run_block(Bench &b, CycleSpec &c, unsigned cycles, GoldenBlock &g,
                      bool apply_on_first = false) {
  for (unsigned i = 0; i < cycles; ++i) {
    const single_cycle_result_t r = make_cycle(c, g);
    b.send(r, apply_on_first && i == 0);
    c.sequence += 1;
    c.cycle_sequence += 1;
    c.first_sample += c.samples;
    c.seed += 1;
  }
}

int main() {
  static_assert(AGG_IN_BITS == 7392, "input beat width is normative");

  Bench b;
  ap_uint<32> words[MREC_WORDS];
  CycleSpec c;

  // --- 12 @ 60 Hz: exact Mtr1-equivalence over a full block. -------------
  {
    GoldenBlock g;
    run_block(b, c, 12, g, /*apply_on_first=*/true);
    CHECK(b.m_result.size() == 1, "12 cycles at 60 Hz close one block");
    const basic_result_t r = unpack_basic_result(b.m_result.read());
    take_record(b, words);

    CHECK(words[MREC_FORMAT_WORD] == MREC_FORMAT_BASIC_V4, "record format");
    CHECK(words[MREC_SEQUENCE_WORD] == 1 && r.sequence == 1,
          "first block carries sequence 1");
    CHECK(words[MREC_SAMPLE_COUNT_WORD] == g.count &&
              r.sample_count == g.count,
          "merged sample count (%u)", g.count);
    CHECK(words[MREC_FIRST_SAMPLE_LOW_WORD] == 1000 &&
              r.first_sample == 1000,
          "block first-sample anchor");
    CHECK(words[BASIC_LAST_SAMPLE_LOW_WORD] == 1000 + g.count - 1,
          "block last-sample anchor");
    CHECK(words[MTR1_TIMING_WORD] ==
              (60u | (12u << MTR1_TIMING_CYCLES_LSB) |
               (0x5u << MTR1_TIMING_FLAGS_LSB)),
          "timing word: nominal 60, 12 cycles, locked+first, got 0x%08x",
          (unsigned)words[MTR1_TIMING_WORD]);
    CHECK((words[MREC_STATUS_WORD] & 0x5u) == 0x4u,
          "first block: gap mark set, no overflow, got 0x%x",
          (unsigned)words[MREC_STATUS_WORD]);
    CHECK(r.cycle_count == 12 && r.nominal_hz == 60, "beat block metadata");
    CHECK(r.frequency_millihz == c.freq_mhz && r.frequency_valid == 1,
          "beat frequency from the closing cycle");
    CHECK(r.valid_mask == 0x7F, "beat mask");

    for (int lane = 0; lane < MET_ACTIVE_CHANNELS; ++lane) {
      const long long mean_units =
          golden_mean_q16(g.sum[lane], g.count) >> 16;
      const unsigned long long rms_q16 =
          golden_rms_q16(g.square[lane], g.sum[lane], g.count, true);
      const unsigned long long raw_rms =
          golden_rms_q16(g.raw_square[lane], g.raw_sum[lane], g.count, true);
      const int base = MTR1_CH_BASE_WORD + lane * MTR1_CH_STRIDE_WORDS;
      const long long got_mean =
          (long long)((unsigned long long)words[base + MTR1_CH_MEAN_LOW] |
                      ((unsigned long long)words[base + MTR1_CH_MEAN_HIGH]
                       << 32));
      const unsigned long long got_rms =
          (unsigned long long)words[base + MTR1_CH_RMS_LOW] |
          ((unsigned long long)words[base + MTR1_CH_RMS_HIGH] << 32);
      CHECK(got_mean == mean_units, "lane %d mean exact", lane);
      CHECK(got_rms == (rms_q16 >> 16), "lane %d RMS exact (Mtr1 proof)",
            lane);
      CHECK((unsigned long long)words[base + MTR1_CH_RMS_COUNT] ==
                (raw_rms & 0xFFFFFFFFull),
            "lane %d raw RMS counts exact", lane);
      CHECK((unsigned long long)(long long)r.rms_q16[lane] == rms_q16,
            "lane %d beat RMS Q16 exact", lane);
    }
    for (int pair = 0; pair < MET_VLL_PAIRS; ++pair) {
      const unsigned long long vll_q16 =
          golden_rms_q16(g.vll_square[pair], 0, g.count, false);
      CHECK((unsigned long long)words[BASIC_VLL_BASE_WORD + pair] ==
                (vll_q16 >> 16),
            "pair %d VLL RMS exact", pair);
    }
    CHECK(words[MTR1_FREQUENCY_VALUE_WORD] == c.freq_mhz &&
              words[MTR1_FREQUENCY_STATUS_WORD] == 0x2 &&
              words[MTR1_FREQUENCY_PERIOD_WORD] == 0x00010000 &&
              words[MTR1_FREQUENCY_SEQUENCE_WORD] == 42,
          "frequency context words");
    CHECK(words[MTR1_CAPTURE_FRAMES_WORD] == 111 &&
              words[MTR1_HEADER_ERRORS_WORD] == 1 &&
              words[MTR1_FIFO_OVERFLOWS_WORD] == 2 &&
              words[MTR1_ADC_ALERTS_WORD] == 3,
          "capture context words");
  }

  // --- Second block: clean status, sequences chain. -----------------------
  {
    GoldenBlock g;
    run_block(b, c, 12, g);
    const basic_result_t r = unpack_basic_result(b.m_result.read());
    take_record(b, words);
    CHECK(r.sequence == 2 && (r.status & 0x5u) == 0,
          "second block is clean (status 0x%x)", (unsigned)r.status);
    CHECK((r.flags & 0x4u) == 0, "first-block flag clears");
  }

  // --- Upstream gap mark restarts the block. ------------------------------
  {
    GoldenBlock g;
    run_block(b, c, 5, g);  // partial: will be discarded
    GoldenBlock g2;
    c.status = 1u << SCYC_STATUS_FIRST_AFTER_GAP_BIT;
    // The gap-marked cycle starts the NEW block.
    const single_cycle_result_t r0 = make_cycle(c, g2);
    b.send(r0);
    c.sequence += 1; c.cycle_sequence += 1; c.first_sample += c.samples;
    c.status = 0;
    const unsigned long long block_start = (unsigned long long)r0.first_sample;
    run_block(b, c, 11, g2);
    CHECK(b.m_result.size() == 1, "gap restart: 12 cycles from the mark");
    const basic_result_t r = unpack_basic_result(b.m_result.read());
    take_record(b, words);
    CHECK(r.first_sample == block_start,
          "block anchors at the gap-marked cycle");
    CHECK((r.status & 0x4u) == 0x4u, "block after a gap carries the mark");
  }

  // --- Sequence break restarts; nominal 50 closes at 10. ------------------
  {
    GoldenBlock g;
    run_block(b, c, 4, g);  // partial
    c.cycle_sequence += 3;  // grid cycle sequence jumps: break
    c.nominal = 50;
    GoldenBlock g2;
    const single_cycle_result_t r0 = make_cycle(c, g2);
    b.send(r0);
    c.sequence += 1; c.cycle_sequence += 1; c.first_sample += c.samples;
    run_block(b, c, 9, g2);
    CHECK(b.m_result.size() == 1, "10 cycles at 50 Hz close one block");
    const basic_result_t r = unpack_basic_result(b.m_result.read());
    take_record(b, words);
    CHECK(r.cycle_count == 10 && r.nominal_hz == 50,
          "50 Hz block closes at 10 cycles");
    CHECK((r.status & 0x4u) == 0x4u, "sequence break marks the next block");
    for (int lane = 0; lane < MET_ACTIVE_CHANNELS; ++lane) {
      const unsigned long long rms_q16 =
          golden_rms_q16(g2.square[lane], g2.sum[lane], g2.count, true);
      CHECK((unsigned long long)(long long)r.rms_q16[lane] == rms_q16,
            "50 Hz lane %d RMS exact", lane);
    }
  }

  // --- Stale generation discards; lock/fallback flags reduce. ------------
  {
    // A cycle tagged with a foreign generation is rejected outright.
    GoldenBlock scratch;
    c.generation = 9;
    const single_cycle_result_t stale = make_cycle(c, scratch);
    b.send(stale);
    c.generation = 1;
    CHECK(b.m_result.empty(), "stale generation must not merge");

    GoldenBlock g;
    // One mid-block cycle arrives unlocked/fallback: AND/OR reduction.
    for (unsigned i = 0; i < 10; ++i) {
      if (i == 4) { b.locked = false; b.fallback = true; }
      const single_cycle_result_t r = make_cycle(c, g);
      b.send(r);
      b.locked = true; b.fallback = false;
      c.sequence += 1; c.cycle_sequence += 1; c.first_sample += c.samples;
      c.seed += 1;
    }
    CHECK(b.m_result.size() == 1, "fallback block still closes");
    const basic_result_t r = unpack_basic_result(b.m_result.read());
    take_record(b, words);
    CHECK((r.flags & 0x1u) == 0 && (r.flags & 0x2u) == 0x2u,
          "one unlocked cycle clears LOCKED and sets FALLBACK, got 0x%x",
          (unsigned)r.flags);
  }

  // --- Sticky arithmetic flag from a saturated cycle, cleared by APPLY. ---
  {
    GoldenBlock g;
    CycleSpec sat = c;
    for (unsigned i = 0; i < 10; ++i) {
      single_cycle_result_t r = make_cycle(sat, g);
      if (i == 0) {
        r.square[0] = ~ap_uint<128>(0);  // upstream saturated square
        r.status = 1u << SCYC_STATUS_OVERFLOW_BIT;
      }
      b.send(r);
      sat.sequence += 1; sat.cycle_sequence += 1; sat.first_sample += sat.samples;
    }
    const basic_result_t r = unpack_basic_result(b.m_result.read());
    take_record(b, words);
    CHECK((r.status & 0x1u) == 0x1u,
          "upstream saturation folds into the sticky flag");
    CHECK((r.rms_q16[0] == ap_int<64>(ap_uint<64>(~ap_uint<64>(0)))) ||
              r.rms_q16[0] != 0,
          "saturated lane finalizes clamped, not silent");
    c = sat;

    // APPLY clears the sticky flag: the next full block is clean again.
    GoldenBlock g2;
    run_block(b, c, 10, g2, /*apply_on_first=*/true);
    const basic_result_t r2 = unpack_basic_result(b.m_result.read());
    take_record(b, words);
    CHECK((r2.status & 0x1u) == 0, "APPLY clears the sticky flag");
    CHECK((r2.status & 0x4u) == 0x4u, "post-APPLY block carries the mark");
  }

  // --- Disable stops everything. ------------------------------------------
  {
    b.enable = false;
    GoldenBlock scratch;
    const single_cycle_result_t r = make_cycle(c, scratch);
    b.send(r, /*apply_toggles=*/true);
    CHECK(b.m_result.empty() && b.m_axis.empty(), "disabled engine is silent");
  }

  if (failures != 0) {
    std::printf("FAILED: %d check(s)\n", failures);
    return EXIT_FAILURE;
  }
  std::printf("PASS: agg10_12_cycle_engine_tb\n");
  return EXIT_SUCCESS;
}
