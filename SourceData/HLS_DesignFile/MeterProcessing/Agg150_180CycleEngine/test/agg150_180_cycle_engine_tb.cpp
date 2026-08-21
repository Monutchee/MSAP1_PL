// Testbench for the 150/180-cycle aggregation engine (M11, replaces
// Mtr2Engine). The bench synthesizes 10/12-cycle block beats the way the
// Agg10_12CycleEngine emits them (block accumulators built from explicit
// per-sample values, packed into agg_block_result beats), tracks the
// same interval accumulation in exact __int128 goldens, and checks the
// emitted record quad EXACTLY (the finalize is the shared
// metrology_finalize.hpp chain, already pinned exhaustively by the 10/12
// tier's bench — here the aggregate-specific paths are pinned: the
// 15-block merge, the aggregation rules, and the four AGG record maps).
//
// Aggregation rules covered (the retired Mtr2 12-scenario table, ported):
// eligibility (fallback / first-block / unknown nominal / short cycle
// count), APPLY discard, generation/nominal/rate/dc_remove reseed,
// sequence and sample-index continuity, frequency-valid reduction,
// phasor-invalid fold (M11 extension), only-complete emission, and the
// diagnostics counters (record words 33..35 — the AGG register tap).

#include <cmath>
#include <cstdio>
#include <cstdlib>

#include "agg150_180_cycle_engine.hpp"

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
// Exact integer goldens (the same replicas the 10/12 bench uses).
// ---------------------------------------------------------------------------
static unsigned __int128 golden_isqrt(unsigned __int128 value) {
  unsigned __int128 root = 0;
  for (int bit = 63; bit >= 0; --bit) {
    const unsigned __int128 candidate = root | ((unsigned __int128)1 << bit);
    if (candidate * candidate <= value) root = candidate;
  }
  return root;
}
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
static long long golden_p_pw(__int128 power_sum, unsigned count) {
  const bool negative = power_sum < 0;
  const unsigned __int128 magnitude =
      (unsigned __int128)(negative ? -power_sum : power_sum);
  __int128 mean = (__int128)(magnitude / count);
  if (negative) mean = -mean;
  return (long long)(mean >> 32);
}
static unsigned long long golden_s_pw(unsigned long long v_rms_q16,
                                      unsigned long long i_rms_q16) {
  return (unsigned long long)(((unsigned __int128)v_rms_q16 * i_rms_q16) >> 32);
}
static long long golden_pf_e6(long long p_pw, unsigned long long s_pw) {
  if (p_pw == 0 || s_pw == 0) return 0;
  const unsigned __int128 magnitude =
      (unsigned __int128)(p_pw < 0 ? -p_pw : p_pw);
  unsigned __int128 ratio = magnitude * 1000000u / s_pw;
  if (ratio > 1000000u) ratio = 1000000u;
  return p_pw < 0 ? -(long long)ratio : (long long)ratio;
}
static long long golden_phasor_counts(__int128 sum, unsigned count) {
  const bool negative = sum < 0;
  const unsigned __int128 magnitude =
      (unsigned __int128)(negative ? -sum : sum);
  __int128 mean = (__int128)(magnitude / count);
  if (negative) mean = -mean;
  return (long long)(mean >> 37);
}
static unsigned long long golden_fund_rms_q16(long long re_c, long long im_c) {
  const unsigned __int128 sq = (unsigned __int128)((__int128)re_c * re_c) +
                               (unsigned __int128)((__int128)im_c * im_c);
  return (unsigned long long)((golden_isqrt(sq) * 92682u) >> 16);
}
static long long golden_q1_pvar(long long re_v, long long im_v, long long re_i,
                                long long im_i) {
  const __int128 cross = (__int128)im_v * re_i - (__int128)re_v * im_i;
  return (long long)(cross >> 31);
}
static unsigned long long golden_ratio_e6(unsigned long long numerator,
                                          unsigned long long denominator) {
  if (denominator == 0) return 0;
  const unsigned __int128 ratio =
      (unsigned __int128)numerator * 1000000u / denominator;
  return ratio > 0xFFFFFFFFu ? 0xFFFFFFFFull : (unsigned long long)ratio;
}
static void golden_rotate(bool a_squared, long long re, long long im,
                          long long &out_re, long long &out_im) {
  const __int128 sq3h = 929887697;
  const __int128 re_half = ((__int128)re) << 29;
  const __int128 im_half = ((__int128)im) << 29;
  const __int128 re_s3 = (__int128)re * sq3h;
  const __int128 im_s3 = (__int128)im * sq3h;
  if (!a_squared) {
    out_re = (long long)((-re_half - im_s3) >> 30);
    out_im = (long long)((re_s3 - im_half) >> 30);
  } else {
    out_re = (long long)((-re_half + im_s3) >> 30);
    out_im = (long long)((-re_s3 - im_half) >> 30);
  }
}
static long long golden_div3(long long value) {
  return value < 0 ? -(long long)((-(__int128)value) / 3)
                   : (long long)((__int128)value / 3);
}
static void golden_sequence(const long long re[3], const long long im[3],
                            long long seq_re[3], long long seq_im[3]) {
  long long ba_r, ba_i, ba2_r, ba2_i, ca_r, ca_i, ca2_r, ca2_i;
  golden_rotate(false, re[1], im[1], ba_r, ba_i);
  golden_rotate(true, re[1], im[1], ba2_r, ba2_i);
  golden_rotate(false, re[2], im[2], ca_r, ca_i);
  golden_rotate(true, re[2], im[2], ca2_r, ca2_i);
  seq_re[0] = golden_div3(re[0] + re[1] + re[2]);
  seq_im[0] = golden_div3(im[0] + im[1] + im[2]);
  seq_re[1] = golden_div3(re[0] + ba_r + ca2_r);
  seq_im[1] = golden_div3(im[0] + ba_i + ca2_i);
  seq_re[2] = golden_div3(re[0] + ba2_r + ca_r);
  seq_im[2] = golden_div3(im[0] + ba2_i + ca_i);
}

// ---------------------------------------------------------------------------
// Block synthesis: one 10/12-cycle block beat from explicit per-sample
// values (the same pattern the 10/12 bench feeds its cycles).
// ---------------------------------------------------------------------------
struct GoldenAgg {
  __int128 sum[MET_ACTIVE_CHANNELS] = {};
  unsigned __int128 square[MET_ACTIVE_CHANNELS] = {};
  long long raw_sum[MET_ACTIVE_CHANNELS] = {};
  unsigned __int128 raw_square[MET_ACTIVE_CHANNELS] = {};
  unsigned __int128 vll_square[MET_VLL_PAIRS] = {};
  __int128 power[MET_POWER_PHASES] = {};
  long long minimum[MET_ACTIVE_CHANNELS] = {};
  long long maximum[MET_ACTIVE_CHANNELS] = {};
  __int128 ph_re[MET_ACTIVE_CHANNELS] = {};
  __int128 ph_im[MET_ACTIVE_CHANNELS] = {};
  bool seeded = false;
  unsigned count = 0;
  unsigned long long freq_sum = 0;
};

struct BlockSpec {
  unsigned sequence = 1;
  unsigned generation = 1;
  unsigned long long first_sample = 1000;
  unsigned samples = 8;          // per block, kept tiny for cosim speed
  unsigned nominal = 60;
  unsigned cycle_count = 12;
  unsigned status = 0;
  unsigned valid_mask = 0x7F;
  unsigned flags = 0x1;          // locked
  unsigned freq_mhz = 60012;
  unsigned freq_valid = 1;
  unsigned dc_remove = 1;
  unsigned apply_level = 0;
  long long seed = 500000001;
  double ph_amp[MET_ACTIVE_CHANNELS] = {5.0e10, 5.0e10, 5.0e10, 0.0,
                                        1.0e12, 1.0e12, 1.0e12};
  double ph_deg[MET_ACTIVE_CHANNELS] = {-10.0, -130.0, 110.0, 0.0,
                                        120.0, -120.0, 0.0};
};

static agg_block_beat_t make_block(const BlockSpec &c, GoldenAgg &g,
                                   bool fold_golden = true) {
  agg_block_result_t r = {};
  __int128 sum[MET_ACTIVE_CHANNELS] = {};
  unsigned __int128 square[MET_ACTIVE_CHANNELS] = {};
  long long raw_sum[MET_ACTIVE_CHANNELS] = {};
  unsigned __int128 raw_square[MET_ACTIVE_CHANNELS] = {};
  unsigned __int128 vll_square[MET_VLL_PAIRS] = {};
  __int128 power[MET_POWER_PHASES] = {};
  long long lane_min[MET_ACTIVE_CHANNELS] = {};
  long long lane_max[MET_ACTIVE_CHANNELS] = {};
  const int minuend[MET_VLL_PAIRS] = {MET_LANE_VA, MET_LANE_VB, MET_LANE_VC};
  const int subtrahend[MET_VLL_PAIRS] = {MET_LANE_VB, MET_LANE_VC,
                                         MET_LANE_VA};
  static const int pv[MET_POWER_PHASES] = {MET_LANE_VA, MET_LANE_VB,
                                           MET_LANE_VC};
  static const int pi_[MET_POWER_PHASES] = {MET_LANE_IA, MET_LANE_IB,
                                            MET_LANE_IC};
  for (unsigned s = 0; s < c.samples; ++s) {
    long long lane_value[MET_ACTIVE_CHANNELS];
    for (int lane = 0; lane < MET_ACTIVE_CHANNELS; ++lane) {
      const long long value = ((s % 2 == 0) ? 1 : -1) *
                              c.seed * (lane + 1) * (long long)(s + 1);
      lane_value[lane] = value;
      sum[lane] += value;
      square[lane] += (unsigned __int128)((__int128)value * value);
      raw_sum[lane] += value / 5;
      raw_square[lane] +=
          (unsigned __int128)((__int128)(value / 5) * (value / 5));
      if (s == 0 || value < lane_min[lane]) lane_min[lane] = value;
      if (s == 0 || value > lane_max[lane]) lane_max[lane] = value;
    }
    for (int pair = 0; pair < MET_VLL_PAIRS; ++pair) {
      const long long diff =
          lane_value[minuend[pair]] - lane_value[subtrahend[pair]];
      vll_square[pair] += (unsigned __int128)((__int128)diff * diff);
    }
    for (int phase = 0; phase < MET_POWER_PHASES; ++phase) {
      power[phase] += (__int128)lane_value[pv[phase]] * lane_value[pi_[phase]];
    }
  }
  for (int lane = 0; lane < MET_ACTIVE_CHANNELS; ++lane) {
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
    r.minimum[lane] = ap_int<64>(lane_min[lane]);
    r.maximum[lane] = ap_int<64>(lane_max[lane]);
    // Phasor sums: llround'd mean components back-scaled exactly.
    const double rad = c.ph_deg[lane] * M_PI / 180.0;
    const long long re_c = (long long)llround(c.ph_amp[lane] / 2.0 * sin(rad));
    const long long im_c = (long long)llround(-c.ph_amp[lane] / 2.0 * cos(rad));
    const __int128 re_sum = ((__int128)re_c << 37) * (long long)c.samples;
    const __int128 im_sum = ((__int128)im_c << 37) * (long long)c.samples;
    unsigned __int128 re_image = (unsigned __int128)re_sum;
    r.phasor_re[lane].range(63, 0) = ap_uint<64>((unsigned long long)re_image);
    r.phasor_re[lane].range(127, 64) =
        ap_uint<64>((unsigned long long)(re_image >> 64));
    unsigned __int128 im_image = (unsigned __int128)im_sum;
    r.phasor_im[lane].range(63, 0) = ap_uint<64>((unsigned long long)im_image);
    r.phasor_im[lane].range(127, 64) =
        ap_uint<64>((unsigned long long)(im_image >> 64));
    if (fold_golden) {
      g.sum[lane] += sum[lane];
      g.square[lane] += square[lane];
      g.raw_sum[lane] += raw_sum[lane];
      g.raw_square[lane] += raw_square[lane];
      g.ph_re[lane] += re_sum;
      g.ph_im[lane] += im_sum;
      if (!g.seeded) {
        g.minimum[lane] = lane_min[lane];
        g.maximum[lane] = lane_max[lane];
      } else {
        if (lane_min[lane] < g.minimum[lane]) g.minimum[lane] = lane_min[lane];
        if (lane_max[lane] > g.maximum[lane]) g.maximum[lane] = lane_max[lane];
      }
    }
  }
  for (int pair = 0; pair < MET_VLL_PAIRS; ++pair) {
    unsigned __int128 vsq = vll_square[pair];
    r.vll_square[pair].range(63, 0) = ap_uint<64>((unsigned long long)vsq);
    r.vll_square[pair].range(127, 64) =
        ap_uint<64>((unsigned long long)(vsq >> 64));
    if (fold_golden) g.vll_square[pair] += vll_square[pair];
  }
  for (int phase = 0; phase < MET_POWER_PHASES; ++phase) {
    unsigned __int128 image = (unsigned __int128)power[phase];
    r.power_sum[phase].range(63, 0) = ap_uint<64>((unsigned long long)image);
    r.power_sum[phase].range(127, 64) =
        ap_uint<64>((unsigned long long)(image >> 64));
    if (fold_golden) g.power[phase] += power[phase];
  }
  if (fold_golden) {
    g.seeded = true;
    g.count += c.samples;
    g.freq_sum += c.freq_mhz;
  }

  r.sequence = c.sequence;
  r.generation = c.generation;
  r.first_sample = c.first_sample;
  r.last_sample = c.first_sample + c.samples - 1;
  r.sample_count = c.samples;
  r.sample_rate_hz = 32000;
  r.nominal_hz = c.nominal;
  r.valid_mask = c.valid_mask;
  r.flags = c.flags;
  r.cycle_count = c.cycle_count;
  r.status = c.status;
  r.frequency_millihz = c.freq_mhz;
  r.frequency_valid = c.freq_valid;
  r.apply_toggle = c.apply_level;
  r.dc_remove = c.dc_remove;
  return pack_agg_block_result(r);
}

struct Bench {
  hls::stream<agg_block_beat_t> s_block{"s_block"};
  hls::stream<record_axis_t> m_axis{"m_axis"};
  void send(const agg_block_beat_t &beat) {
    s_block.write(beat);
    hls_agg150_180_cycle_engine(s_block, m_axis);
  }
};

static void take_record(Bench &b, ap_uint<32> (&words)[MREC_WORDS],
                        unsigned expected_format) {
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
  CHECK(words[MREC_FORMAT_WORD] == expected_format,
        "record format: got %08x expected %08x",
        (unsigned)words[MREC_FORMAT_WORD], expected_format);
}

static long long read_s64(const ap_uint<32> (&words)[MREC_WORDS], int low) {
  return (long long)((unsigned long long)words[low] |
                     ((unsigned long long)words[low + 1] << 32));
}

// Drive `blocks` consecutive eligible blocks.
static void run_blocks(Bench &b, BlockSpec &c, unsigned blocks, GoldenAgg &g) {
  for (unsigned i = 0; i < blocks; ++i) {
    b.send(make_block(c, g));
    c.sequence += 1;
    c.first_sample += c.samples;
    c.seed += 1;
  }
}

int main() {
  Bench b;
  BlockSpec c;
  ap_uint<32> words[MREC_WORDS];

  // Commit the configuration: first beat toggles APPLY (level 1).
  c.apply_level = 1;

  // --- 15 eligible blocks: one aggregate, all four records exact. --------
  {
    GoldenAgg g;
    run_blocks(b, c, 15, g);
    CHECK(!b.m_axis.empty(), "15 eligible blocks emit the aggregate");

    take_record(b, words, MREC_FORMAT_AGG_V3);
    CHECK(words[MREC_SEQUENCE_WORD] == 1 && words[MREC_GENERATION_WORD] == 1 &&
              words[MREC_SAMPLE_RATE_WORD] == 32000 &&
              words[MREC_SAMPLE_COUNT_WORD] == g.count &&
              words[MREC_VALID_MASK_WORD] == 0x7F,
          "aggregate envelope");
    CHECK(words[MREC_STATUS_WORD] == ((1u << 1) | (1u << 2)),
          "status: complete + all frequencies valid, got 0x%x",
          (unsigned)words[MREC_STATUS_WORD]);
    CHECK(words[MREC_FIRST_SAMPLE_LOW_WORD] == 1000,
          "interval first-sample anchor");
    CHECK(words[MTR2_SHAPE_WORD] ==
              (15u | (60u << MTR2_SHAPE_NOMINAL_LSB) |
               (180u << MTR2_SHAPE_CYCLES_LSB)),
          "shape word: 15 blocks, 60 Hz, 180 cycles");
    CHECK(words[MTR2_FIRST_BASIC_SEQ_WORD] == 1 &&
              words[MTR2_LAST_BASIC_SEQ_WORD] == 15,
          "folded basic-sequence range");
    for (int lane = 0; lane < MET_ACTIVE_CHANNELS; ++lane) {
      const unsigned long long rms =
          golden_rms_q16(g.square[lane], g.sum[lane], g.count, true) >> 16;
      const int base = MTR2_CH_BASE_WORD + lane * MTR2_CH_STRIDE_WORDS;
      CHECK((unsigned long long)words[base] == (rms & 0xFFFFFFFFull) &&
                words[base + 1] == (unsigned)(rms >> 32),
            "lane %d aggregate RMS exact (whole-interval accumulators)",
            lane);
    }
    CHECK(words[MTR2_FREQUENCY_WORD] == g.freq_sum / 15,
          "mean frequency over the 15 blocks");
    CHECK(words[MTR2_RESET_COUNT_WORD] == 0 &&
              words[MTR2_INELIGIBLE_COUNT_WORD] == 0 &&
              words[MTR2_CONTINUITY_COUNT_WORD] == 0,
          "clean diagnostics");
    CHECK((unsigned long long)read_s64(words, AGG_LAST_SAMPLE_LOW_WORD) ==
              1000ull + g.count - 1,
          "interval last-sample anchor");
    for (int pair = 0; pair < MET_VLL_PAIRS; ++pair) {
      const unsigned long long vll =
          golden_rms_q16(g.vll_square[pair], 0, g.count, false) >> 16;
      CHECK((unsigned long long)words[AGG_VLL_BASE_WORD + pair] ==
                (vll & 0xFFFFFFFFull),
            "pair %d aggregate VLL exact", pair);
    }

    // AGG-POWER: phase A exact.
    take_record(b, words, MREC_FORMAT_AGG_POWER_V1);
    CHECK(words[MREC_SEQUENCE_WORD] == 1 &&
              words[MTR2_FIRST_BASIC_SEQ_WORD] == 1 &&
              words[MTR2_LAST_BASIC_SEQ_WORD] == 15,
          "power sibling correlation fields");
    {
      const long long p = golden_p_pw(g.power[0], g.count);
      const unsigned long long s = golden_s_pw(
          golden_rms_q16(g.square[MET_LANE_VA], g.sum[MET_LANE_VA], g.count,
                         true),
          golden_rms_q16(g.square[MET_LANE_IA], g.sum[MET_LANE_IA], g.count,
                         true));
      CHECK(read_s64(words, POWER_PHASE_BASE_WORD + POWER_PHASE_P_LOW) == p,
            "aggregate P_A exact");
      CHECK((unsigned long long)read_s64(
                words, POWER_PHASE_BASE_WORD + POWER_PHASE_S_LOW) == s,
            "aggregate S_A exact");
      CHECK((long long)(int)words[POWER_PHASE_BASE_WORD + POWER_PHASE_PF] ==
                golden_pf_e6(p, s),
            "aggregate PF_A exact");
    }

    // AGG-PHASOR: VA reference + phase A Q1 exact.
    take_record(b, words, MREC_FORMAT_AGG_PHASOR_V2);
    {
      long long re_c[MET_ACTIVE_CHANNELS], im_c[MET_ACTIVE_CHANNELS];
      for (int lane = 0; lane < MET_ACTIVE_CHANNELS; ++lane) {
        re_c[lane] = golden_phasor_counts(g.ph_re[lane], g.count);
        im_c[lane] = golden_phasor_counts(g.ph_im[lane], g.count);
      }
      const int va_base = PHASOR_CH_BASE_WORD + MET_LANE_VA * PHASOR_CH_STRIDE;
      CHECK((unsigned long long)words[va_base + PHASOR_CH_FUND_RMS] ==
                (golden_fund_rms_q16(re_c[MET_LANE_VA], im_c[MET_LANE_VA]) >>
                 16),
            "aggregate VA fundamental exact");
      CHECK(words[va_base + PHASOR_CH_ANGLE] == 0,
            "VA reference angle exactly 0");
      CHECK(read_s64(words, PHASOR_Q1_BASE_WORD) ==
                golden_q1_pvar(re_c[MET_LANE_VA], im_c[MET_LANE_VA],
                               re_c[MET_LANE_IA], im_c[MET_LANE_IA]),
            "aggregate Q1_A exact");
      CHECK((words[PHASOR_FLAGS_WORD] >> PHASOR_FLAGS_REF_VALID_BIT) & 1u,
            "aggregate angle reference valid");

      // AGG-UNBAL: V unbalance ratio exact.
      take_record(b, words, MREC_FORMAT_AGG_UNBAL_V2);
      const long long in_re[3] = {re_c[MET_LANE_VA], re_c[MET_LANE_VB],
                                  re_c[MET_LANE_VC]};
      const long long in_im[3] = {im_c[MET_LANE_VA], im_c[MET_LANE_VB],
                                  im_c[MET_LANE_VC]};
      long long sre[3], sim[3];
      golden_sequence(in_re, in_im, sre, sim);
      CHECK((unsigned long long)words[UNBAL_V_UNBALANCE_WORD] ==
                golden_ratio_e6(golden_fund_rms_q16(sre[2], sim[2]),
                                golden_fund_rms_q16(sre[1], sim[1])),
            "aggregate voltage unbalance exact");
      CHECK((words[UNBAL_FLAGS_WORD] & 0x3u) == 0x3u,
            "both sequence sets valid");
    }
    CHECK(b.m_axis.empty(), "exactly four records per aggregate");
  }

  // --- Second aggregate chains cleanly (sequence 2). ----------------------
  {
    GoldenAgg g;
    run_blocks(b, c, 15, g);
    take_record(b, words, MREC_FORMAT_AGG_V3);
    CHECK(words[MREC_SEQUENCE_WORD] == 2 &&
              words[MTR2_FIRST_BASIC_SEQ_WORD] == 16 &&
              words[MTR2_LAST_BASIC_SEQ_WORD] == 30,
          "second aggregate chains");
    take_record(b, words, MREC_FORMAT_AGG_POWER_V1);
    take_record(b, words, MREC_FORMAT_AGG_PHASOR_V2);
    take_record(b, words, MREC_FORMAT_AGG_UNBAL_V2);
  }

  // --- Ineligible inputs: fallback flag, first-block flag, short count. ---
  {
    GoldenAgg scratch;
    run_blocks(b, c, 5, scratch);  // partial (5 blocks in)
    BlockSpec bad = c;
    bad.flags = 0x3;  // locked + fallback
    b.send(make_block(bad, scratch, false));
    c.sequence += 1;
    c.first_sample += c.samples;
    BlockSpec first_flagged = c;
    first_flagged.flags = 0x5;  // locked + first-after-discontinuity
    b.send(make_block(first_flagged, scratch, false));
    c.sequence += 1;
    c.first_sample += c.samples;
    BlockSpec short_count = c;
    short_count.cycle_count = 11;  // not met_expected_cycles(60)
    b.send(make_block(short_count, scratch, false));
    c.sequence += 1;
    c.first_sample += c.samples;
    CHECK(b.m_axis.empty(), "ineligible inputs never emit");

    // Rebuild a full aggregate; its diagnostics must show the damage:
    // 3 ineligible inputs, 1 reset (the discarded 5-block partial).
    GoldenAgg g;
    run_blocks(b, c, 15, g);
    take_record(b, words, MREC_FORMAT_AGG_V3);
    CHECK(words[MTR2_INELIGIBLE_COUNT_WORD] == 3 &&
              words[MTR2_RESET_COUNT_WORD] == 1 &&
              words[MTR2_CONTINUITY_COUNT_WORD] == 0,
          "ineligible/reset accounting (got %u/%u/%u)",
          (unsigned)words[MTR2_INELIGIBLE_COUNT_WORD],
          (unsigned)words[MTR2_RESET_COUNT_WORD],
          (unsigned)words[MTR2_CONTINUITY_COUNT_WORD]);
    take_record(b, words, MREC_FORMAT_AGG_POWER_V1);
    take_record(b, words, MREC_FORMAT_AGG_PHASOR_V2);
    take_record(b, words, MREC_FORMAT_AGG_UNBAL_V2);
  }

  // --- Sequence break mid-aggregate: continuity + reset, reseed. ---------
  {
    GoldenAgg scratch;
    run_blocks(b, c, 7, scratch);
    c.sequence += 2;  // lost block
    GoldenAgg g;
    run_blocks(b, c, 15, g);
    take_record(b, words, MREC_FORMAT_AGG_V3);
    CHECK(words[MTR2_CONTINUITY_COUNT_WORD] == 1 &&
              words[MTR2_RESET_COUNT_WORD] == 2,
          "sequence break: continuity 1, resets 2 (got %u/%u)",
          (unsigned)words[MTR2_CONTINUITY_COUNT_WORD],
          (unsigned)words[MTR2_RESET_COUNT_WORD]);
    take_record(b, words, MREC_FORMAT_AGG_POWER_V1);
    take_record(b, words, MREC_FORMAT_AGG_PHASOR_V2);
    take_record(b, words, MREC_FORMAT_AGG_UNBAL_V2);
  }

  // --- APPLY mid-aggregate discards the partial. --------------------------
  {
    GoldenAgg scratch;
    run_blocks(b, c, 4, scratch);
    c.apply_level ^= 1;  // config APPLY between beats
    GoldenAgg g;
    run_blocks(b, c, 15, g);
    take_record(b, words, MREC_FORMAT_AGG_V3);
    CHECK(words[MTR2_RESET_COUNT_WORD] == 3,
          "APPLY discard adds a reset (got %u)",
          (unsigned)words[MTR2_RESET_COUNT_WORD]);
    take_record(b, words, MREC_FORMAT_AGG_POWER_V1);
    take_record(b, words, MREC_FORMAT_AGG_PHASOR_V2);
    take_record(b, words, MREC_FORMAT_AGG_UNBAL_V2);
  }

  // --- Nominal change reseeds; 50 Hz aggregate carries 150 cycles. -------
  {
    GoldenAgg scratch;
    run_blocks(b, c, 6, scratch);
    c.nominal = 50;
    c.cycle_count = 10;
    GoldenAgg g;
    run_blocks(b, c, 15, g);
    take_record(b, words, MREC_FORMAT_AGG_V3);
    CHECK(words[MTR2_SHAPE_WORD] ==
              (15u | (50u << MTR2_SHAPE_NOMINAL_LSB) |
               (150u << MTR2_SHAPE_CYCLES_LSB)),
          "50 Hz shape word (150 cycles)");
    CHECK(words[MTR2_RESET_COUNT_WORD] == 4, "nominal change adds a reset");
    take_record(b, words, MREC_FORMAT_AGG_POWER_V1);
    take_record(b, words, MREC_FORMAT_AGG_PHASOR_V2);
    take_record(b, words, MREC_FORMAT_AGG_UNBAL_V2);
  }

  // --- Frequency-invalid and phasor-invalid blocks fold into status. -----
  {
    GoldenAgg g;
    for (unsigned i = 0; i < 15; ++i) {
      BlockSpec blk = c;
      if (i == 6) {
        blk.freq_valid = 0;
        blk.status = 1u << PHASOR_STATUS_INVALID_BIT;
      }
      b.send(make_block(blk, g));
      c.sequence += 1;
      c.first_sample += c.samples;
      c.seed += 1;
    }
    take_record(b, words, MREC_FORMAT_AGG_V3);
    CHECK((words[MREC_STATUS_WORD] & (1u << 2)) == 0 &&
              words[MTR2_FREQUENCY_WORD] == 0,
          "one invalid frequency clears the mean (status 0x%x)",
          (unsigned)words[MREC_STATUS_WORD]);
    take_record(b, words, MREC_FORMAT_AGG_POWER_V1);
    CHECK((words[MREC_STATUS_WORD] & 0x2u) == 0,
          "power sibling does not carry phasor-invalid");
    take_record(b, words, MREC_FORMAT_AGG_PHASOR_V2);
    CHECK((words[MREC_STATUS_WORD] & 0x2u) != 0,
          "phasor sibling carries the phasor-invalid fold");
    take_record(b, words, MREC_FORMAT_AGG_UNBAL_V2);
    CHECK((words[MREC_STATUS_WORD] & 0x2u) != 0,
          "unbalance sibling carries the phasor-invalid fold");
  }

  // --- 14 blocks then a discontinuity: nothing is ever emitted. ----------
  {
    GoldenAgg scratch;
    run_blocks(b, c, 14, scratch);
    c.sequence += 5;  // break before the 15th
    GoldenAgg g;
    run_blocks(b, c, 15, g);
    take_record(b, words, MREC_FORMAT_AGG_V3);
    CHECK(words[MREC_SAMPLE_COUNT_WORD] == g.count,
          "only the complete 15-block interval emits");
    take_record(b, words, MREC_FORMAT_AGG_POWER_V1);
    take_record(b, words, MREC_FORMAT_AGG_PHASOR_V2);
    take_record(b, words, MREC_FORMAT_AGG_UNBAL_V2);
    CHECK(b.m_axis.empty(), "no partial aggregate ever emitted");
  }

  if (failures != 0) {
    std::printf("FAILED: %d check(s)\n", failures);
    return EXIT_FAILURE;
  }
  std::printf("PASS: agg150_180_cycle_engine_tb\n");
  return EXIT_SUCCESS;
}
