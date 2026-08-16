// Golden testbench for the MTR1 basic measurement engine. Runs unchanged
// as C simulation and C/RTL co-simulation (the CycleAggregator workflow).
//
// Verification strategy
// ---------------------
// The golden model is an independent implementation of the contract in
// mtr1_engine.hpp (meter_rms.vhd semantics): it shares no code with the
// engine — e.g. its square root is the RTL's 64-step binary search while
// the engine synthesizes a restoring root — so a systematic error cannot
// cancel out.
//
// Timing-dependent behaviour (the calc-busy window drop) differs between
// csim (never busy) and cosim (really busy), so records are verified
// content-addressed, not positionally:
//   - every closed window's expected record image is computed and keyed
//     by its unique first-sample index (words 9/10);
//   - every delivered record must match its window word-for-word (word 3
//     sequence and word 12 result_drops are checked structurally instead:
//     sequences must be exactly 1,2,3,... and conservation must hold);
//   - windows marked must_deliver are paced so finalization is provably
//     idle (>= 520 spacer frames) and are required to arrive;
//   - conservation: delivered + final record's result_drops == closes.
// Every record is additionally framing-checked (64 beats, TLAST at 63,
// full TKEEP/TSTRB, envelope words), and every basic-result beat is
// cross-checked against its record.

#include <cstdio>
#include <cstdlib>
#include <vector>

#include "mtr1_engine.hpp"

// ---------------------------------------------------------------------------
// Failure accounting.
// ---------------------------------------------------------------------------
static int failures = 0;

#define CHECK(cond, ...)                     \
  do {                                       \
    if (!(cond)) {                           \
      std::printf("FAIL line %d: ", __LINE__); \
      std::printf(__VA_ARGS__);              \
      std::printf("\n");                     \
      ++failures;                            \
    }                                        \
  } while (0)

// ---------------------------------------------------------------------------
// Stimulus description.
// ---------------------------------------------------------------------------
struct FrameSpec {
  long long samples[MTR_CHANNEL_LANES];  // converted Q16, signed 64-bit
  int raw[MTR_CHANNEL_LANES];            // raw ADC, signed 32-bit
  unsigned frame_mask;
  unsigned frame_generation;
  bool malformed;
  bool closes;
  bool cycle_mode;
  bool apply_toggle;
  // Shadow configuration sampled with the beat (latched at APPLY).
  bool enable, dc_remove;
  unsigned cfg_generation, cfg_rate, cfg_window, cfg_mask;
  // Close-latched context.
  unsigned long long first_sample;
  unsigned cycle_count, nominal_hz, block_flags;
  unsigned freq_millihz, freq_status, freq_period, freq_sequence;
  unsigned cap_frames, cap_headers, cap_overflows, cap_alerts;
};

static mtr1_sample_beat_t pack_frame(const FrameSpec &f) {
  mtr1_sample_beat_t beat = 0;
  for (int lane = 0; lane < MTR_CHANNEL_LANES; ++lane) {
    beat.range(MTR1_IN_SAMPLES_LSB + lane * 64 + 63,
               MTR1_IN_SAMPLES_LSB + lane * 64) = ap_uint<64>(f.samples[lane]);
    beat.range(MTR1_IN_RAW_LSB + lane * 32 + 31, MTR1_IN_RAW_LSB + lane * 32) =
        ap_uint<32>(f.raw[lane]);
  }
  beat.range(MTR1_IN_FRAME_MASK_LSB + 7, MTR1_IN_FRAME_MASK_LSB) = f.frame_mask;
  beat.range(MTR1_IN_FRAME_GEN_LSB + 31, MTR1_IN_FRAME_GEN_LSB) =
      f.frame_generation;
  beat.bit(MTR1_IN_MALFORMED_BIT) = f.malformed;
  beat.bit(MTR1_IN_CLOSES_BIT) = f.closes;
  beat.bit(MTR1_IN_CYCLE_MODE_BIT) = f.cycle_mode;
  beat.bit(MTR1_IN_APPLY_BIT) = f.apply_toggle;
  beat.bit(MTR1_IN_ENABLE_BIT) = f.enable;
  beat.bit(MTR1_IN_DC_REMOVE_BIT) = f.dc_remove;
  beat.range(MTR1_IN_CFG_GEN_LSB + 31, MTR1_IN_CFG_GEN_LSB) = f.cfg_generation;
  beat.range(MTR1_IN_CFG_RATE_LSB + 31, MTR1_IN_CFG_RATE_LSB) = f.cfg_rate;
  beat.range(MTR1_IN_CFG_WINDOW_LSB + 31, MTR1_IN_CFG_WINDOW_LSB) = f.cfg_window;
  beat.range(MTR1_IN_CFG_MASK_LSB + 7, MTR1_IN_CFG_MASK_LSB) = f.cfg_mask;
  beat.range(MTR1_IN_FIRST_SAMPLE_LSB + 63, MTR1_IN_FIRST_SAMPLE_LSB) =
      ap_uint<64>(f.first_sample);
  beat.range(MTR1_IN_CYCLE_COUNT_LSB + 7, MTR1_IN_CYCLE_COUNT_LSB) =
      f.cycle_count;
  beat.range(MTR1_IN_NOMINAL_LSB + 7, MTR1_IN_NOMINAL_LSB) = f.nominal_hz;
  beat.range(MTR1_IN_BLOCK_FLAGS_LSB + MTR_FLAG_BITS - 1,
             MTR1_IN_BLOCK_FLAGS_LSB) = f.block_flags;
  beat.range(MTR1_IN_FREQ_MHZ_LSB + 31, MTR1_IN_FREQ_MHZ_LSB) = f.freq_millihz;
  beat.range(MTR1_IN_FREQ_STATUS_LSB + 31, MTR1_IN_FREQ_STATUS_LSB) =
      f.freq_status;
  beat.range(MTR1_IN_FREQ_PERIOD_LSB + 31, MTR1_IN_FREQ_PERIOD_LSB) =
      f.freq_period;
  beat.range(MTR1_IN_FREQ_SEQ_LSB + 31, MTR1_IN_FREQ_SEQ_LSB) = f.freq_sequence;
  beat.range(MTR1_IN_CAP_FRAMES_LSB + 31, MTR1_IN_CAP_FRAMES_LSB) = f.cap_frames;
  beat.range(MTR1_IN_CAP_HDRERR_LSB + 31, MTR1_IN_CAP_HDRERR_LSB) =
      f.cap_headers;
  beat.range(MTR1_IN_CAP_OVERFLOW_LSB + 31, MTR1_IN_CAP_OVERFLOW_LSB) =
      f.cap_overflows;
  beat.range(MTR1_IN_CAP_ALERTS_LSB + 31, MTR1_IN_CAP_ALERTS_LSB) = f.cap_alerts;
  return beat;
}

// ---------------------------------------------------------------------------
// Golden model (independent implementation of the mtr1_engine.hpp contract).
// ---------------------------------------------------------------------------

// The RTL's 64-step binary-search floor square root (deliberately NOT the
// engine's restoring recurrence).
static ap_uint<64> golden_sqrt(ap_uint<128> radicand) {
  ap_uint<64> low = 0;
  ap_uint<64> high = ~ap_uint<64>(0);
  for (int iteration = 0; iteration < 64; ++iteration) {
    const ap_uint<64> mid =
        ap_uint<64>((ap_uint<65>(low) + ap_uint<65>(high) + 1) >> 1);
    const ap_uint<128> mid_square = ap_uint<128>(mid) * mid;
    if (mid_square <= radicand) {
      low = mid;
    } else {
      high = mid - 1;
    }
  }
  return low;
}

struct GoldenWindow {
  unsigned long long first_sample;  // match key (unique per window)
  ap_uint<32> expected_word[MREC_WORDS];  // all words; 3 and 12 structural
  basic_result_t expected_result;         // sequence field checked structurally
  bool must_deliver;
  bool delivered;
};

struct Golden {
  // Committed configuration (engine reset defaults).
  bool apply_seen = false;
  unsigned generation = 0;
  unsigned rate = 32000;
  unsigned window = 6400;
  unsigned mask = 0;
  bool enable = false;
  bool dc_remove = true;

  ap_int<128> sum[MTR_ACTIVE_CHANNELS];
  ap_uint<128> square[MTR_ACTIVE_CHANNELS];
  ap_int<64> raw_sum[MTR_ACTIVE_CHANNELS];
  ap_uint<96> raw_square[MTR_ACTIVE_CHANNELS];
  unsigned count = 0;
  bool acc_overflow = false;   // sticky until APPLY
  bool calc_overflow = false;  // sticky until APPLY (deterministic windows only)
  unsigned total_closes = 0;

  std::vector<GoldenWindow> windows;

  Golden() {
    for (int lane = 0; lane < MTR_ACTIVE_CHANNELS; ++lane) {
      sum[lane] = 0;
      square[lane] = 0;
      raw_sum[lane] = 0;
      raw_square[lane] = 0;
    }
  }

  void clear_accumulators() {
    for (int lane = 0; lane < MTR_ACTIVE_CHANNELS; ++lane) {
      sum[lane] = 0;
      square[lane] = 0;
      raw_sum[lane] = 0;
      raw_square[lane] = 0;
    }
    count = 0;
  }

  // floor(numerator/denominator) on 128 bits via ap arithmetic.
  static ap_uint<128> div128(ap_uint<128> numerator, ap_uint<128> denominator) {
    return numerator / denominator;  // ap_uint division is exact floor
  }

  void feed(const FrameSpec &f, bool must_deliver_window) {
    if (f.apply_toggle != apply_seen) {
      apply_seen = f.apply_toggle;
      generation = f.cfg_generation;
      rate = f.cfg_rate;
      window = f.cfg_window;
      mask = f.cfg_mask;
      enable = f.enable;
      dc_remove = f.dc_remove;
      clear_accumulators();
      acc_overflow = false;
      calc_overflow = false;
      // Fall through: the carrying frame is processed under the NEW
      // configuration (accumulates only if its generation tag matches).
    }
    if (!enable) {
      return;
    }
    if (f.malformed || f.frame_generation != generation) {
      clear_accumulators();
      return;
    }

    for (int lane = 0; lane < MTR_ACTIVE_CHANNELS; ++lane) {
      const ap_int<64> sample = ap_int<64>(f.samples[lane]);
      sum[lane] += sample;
      const ap_uint<129> extended =
          ap_uint<129>(square[lane]) + ap_uint<129>(ap_uint<128>(sample * sample));
      if (extended.bit(128)) {
        square[lane] = ~ap_uint<128>(0);
        acc_overflow = true;
      } else {
        square[lane] = extended.range(127, 0);
      }
      const ap_int<32> raw = ap_int<32>(f.raw[lane]);
      raw_sum[lane] += raw;
      raw_square[lane] += ap_uint<96>(ap_uint<64>(ap_int<64>(raw) * raw));
    }
    count += 1;

    const bool closes = (f.cycle_mode && f.closes) ||
                        (!f.cycle_mode && window != 0 && count >= window);
    if (!closes) {
      return;
    }
    total_closes += 1;
    finalize_window(f, must_deliver_window);
    clear_accumulators();
  }

  void finalize_window(const FrameSpec &f, bool must_deliver_window) {
    GoldenWindow w;
    w.first_sample = f.first_sample;
    w.must_deliver = must_deliver_window;
    w.delivered = false;

    const unsigned result_mask = mask & f.frame_mask & 0x7Fu;
    bool overflow = acc_overflow || calc_overflow;

    ap_int<64> mean_q16[MTR_CHANNEL_LANES];
    ap_uint<64> rms_q16[MTR_CHANNEL_LANES];
    ap_uint<32> rms_count[MTR_CHANNEL_LANES];
    for (int lane = 0; lane < MTR_CHANNEL_LANES; ++lane) {
      mean_q16[lane] = 0;
      rms_q16[lane] = 0;
      rms_count[lane] = 0;
    }

    const ap_uint<128> n128 = ap_uint<128>(count);
    const ap_uint<128> denominator =
        ap_uint<128>(ap_uint<64>(ap_uint<64>(count) * count));
    for (int lane = 0; lane < MTR_ACTIVE_CHANNELS; ++lane) {
      const bool negative = (sum[lane] < 0);
      const ap_uint<128> abs_sum =
          negative ? ap_uint<128>(-sum[lane]) : ap_uint<128>(sum[lane]);
      const ap_uint<64> mean_mag = div128(abs_sum, n128).range(63, 0);
      mean_q16[lane] = negative ? ap_int<64>(-ap_int<64>(mean_mag))
                                : ap_int<64>(mean_mag);

      // Converted-domain variance.
      {
        const ap_uint<160> product = ap_uint<160>(square[lane]) * count;
        ap_uint<128> numerator;
        if (product.range(159, 128) != 0) {
          overflow = true;
          numerator = ~ap_uint<128>(0);
        } else {
          numerator = product.range(127, 0);
        }
        if (dc_remove) {
          if (abs_sum.range(127, 64) != 0) {
            overflow = true;
            numerator = 0;
          } else {
            const ap_uint<128> sum_square =
                ap_uint<128>(abs_sum.range(63, 0)) * abs_sum.range(63, 0);
            if (numerator >= sum_square) {
              numerator -= sum_square;
            } else {
              numerator = 0;
              overflow = true;
            }
          }
        }
        rms_q16[lane] = golden_sqrt(div128(numerator, denominator));
      }

      // Raw-count variance.
      {
        const ap_uint<160> product = ap_uint<160>(raw_square[lane]) * count;
        ap_uint<128> numerator;
        if (product.range(159, 128) != 0) {
          overflow = true;
          numerator = ~ap_uint<128>(0);
        } else {
          numerator = product.range(127, 0);
        }
        if (dc_remove) {
          const ap_uint<64> abs_raw = (raw_sum[lane] < 0)
                                          ? ap_uint<64>(-raw_sum[lane])
                                          : ap_uint<64>(raw_sum[lane]);
          const ap_uint<128> sum_square = ap_uint<128>(abs_raw) * abs_raw;
          if (numerator >= sum_square) {
            numerator -= sum_square;
          } else {
            numerator = 0;
            overflow = true;
          }
        }
        rms_count[lane] = golden_sqrt(div128(numerator, denominator)).range(31, 0);
      }
    }
    calc_overflow = overflow;

    // Expected record image (words 3 and 12 filled with 0, checked
    // structurally by the scoreboard).
    for (int wi = 0; wi < MREC_WORDS; ++wi) {
      w.expected_word[wi] = 0;
    }
    w.expected_word[MREC_MAGIC_WORD] = MREC_MAGIC;
    w.expected_word[MREC_FORMAT_WORD] = MREC_FORMAT_MTR1_V3;
    w.expected_word[MREC_SIZE_WORD] = MREC_BYTES;
    w.expected_word[MREC_GENERATION_WORD] = generation;
    w.expected_word[MREC_SAMPLE_RATE_WORD] = rate;
    w.expected_word[MREC_SAMPLE_COUNT_WORD] = count;
    w.expected_word[MREC_VALID_MASK_WORD] = result_mask;
    w.expected_word[MREC_STATUS_WORD] = overflow ? 1 : 0;
    w.expected_word[MREC_FIRST_SAMPLE_LOW_WORD] =
        ap_uint<32>(f.first_sample & 0xFFFFFFFFull);
    w.expected_word[MREC_FIRST_SAMPLE_HIGH_WORD] =
        ap_uint<32>(f.first_sample >> 32);
    w.expected_word[MTR1_TIMING_WORD] =
        (ap_uint<32>(f.nominal_hz) << MTR1_TIMING_NOMINAL_LSB) |
        (ap_uint<32>(f.cycle_count) << MTR1_TIMING_CYCLES_LSB) |
        (ap_uint<32>(f.block_flags) << MTR1_TIMING_FLAGS_LSB);
    for (int lane = 0; lane < MTR_ACTIVE_CHANNELS; ++lane) {
      const ap_int<64> mean_units = mean_q16[lane] >> 16;
      const ap_uint<64> rms_units = rms_q16[lane] >> 16;
      const int base = MTR1_CH_BASE_WORD + lane * MTR1_CH_STRIDE_WORDS;
      w.expected_word[base + MTR1_CH_MEAN_LOW] =
          ap_uint<64>(mean_units).range(31, 0);
      w.expected_word[base + MTR1_CH_MEAN_HIGH] =
          ap_uint<64>(mean_units).range(63, 32);
      w.expected_word[base + MTR1_CH_RMS_COUNT] = rms_count[lane];
      w.expected_word[base + MTR1_CH_RMS_LOW] = rms_units.range(31, 0);
      w.expected_word[base + MTR1_CH_RMS_HIGH] = rms_units.range(63, 32);
    }
    w.expected_word[MTR1_FREQUENCY_VALUE_WORD] = f.freq_millihz;
    w.expected_word[MTR1_FREQUENCY_STATUS_WORD] = f.freq_status;
    w.expected_word[MTR1_FREQUENCY_PERIOD_WORD] = f.freq_period;
    w.expected_word[MTR1_FREQUENCY_SEQUENCE_WORD] = f.freq_sequence;
    w.expected_word[MTR1_CAPTURE_FRAMES_WORD] = f.cap_frames;
    w.expected_word[MTR1_HEADER_ERRORS_WORD] = f.cap_headers;
    w.expected_word[MTR1_FIFO_OVERFLOWS_WORD] = f.cap_overflows;
    w.expected_word[MTR1_ADC_ALERTS_WORD] = f.cap_alerts;

    // Expected basic-result beat (sequence checked structurally).
    basic_result_t &r = w.expected_result;
    r.sequence = 0;
    r.generation = generation;
    r.sample_rate_hz = rate;
    r.sample_count = count;
    r.valid_mask = result_mask;
    r.flags = f.block_flags;
    r.cycle_count = f.cycle_count;
    r.nominal_hz = f.nominal_hz;
    r.status = overflow ? 1 : 0;
    r.frequency_millihz = f.freq_millihz;
    r.frequency_valid = (f.freq_status >> MTR1_FREQ_STATUS_VALID_BIT) & 1u;
    r.apply_toggle = apply_seen;
    r.first_sample = ap_uint<64>(f.first_sample);
    for (int lane = 0; lane < MTR_CHANNEL_LANES; ++lane) {
      r.rms_q16[lane] = (lane < MTR_ACTIVE_CHANNELS)
                            ? ap_int<64>(rms_q16[lane])
                            : ap_int<64>(0);
    }
    windows.push_back(w);
  }
};

// ---------------------------------------------------------------------------
// Scoreboard: framing, content-addressed matching, sequence discipline.
// ---------------------------------------------------------------------------
struct Scoreboard {
  Golden &golden;
  unsigned delivered = 0;
  unsigned last_result_drops = 0;
  std::vector<basic_result_t> results;

  explicit Scoreboard(Golden &g) : golden(g) {}

  GoldenWindow *find_window(unsigned long long first_sample) {
    for (auto &w : golden.windows) {
      if (w.first_sample == first_sample && !w.delivered) {
        return &w;
      }
    }
    return nullptr;
  }

  void take_record(const std::vector<record_axis_t> &beats) {
    CHECK(beats.size() == (size_t)MREC_WORDS, "record has %zu beats",
          beats.size());
    if (beats.size() != (size_t)MREC_WORDS) return;
    ap_uint<32> word[MREC_WORDS];
    for (int i = 0; i < MREC_WORDS; ++i) {
      const record_axis_t &b = beats[i];
      word[i] = b.data;
      CHECK(b.keep == MREC_KEEP_ALL && b.strb == MREC_KEEP_ALL,
            "beat %d keep/strb", i);
      CHECK(b.last == (i == MREC_WORDS - 1 ? 1 : 0), "beat %d last", i);
    }
    delivered += 1;

    const unsigned long long first_sample =
        ((unsigned long long)(uint32_t)word[MREC_FIRST_SAMPLE_HIGH_WORD] << 32) |
        (uint32_t)word[MREC_FIRST_SAMPLE_LOW_WORD];
    GoldenWindow *w = find_window(first_sample);
    CHECK(w != nullptr, "record #%u: no expected window for first_sample %llu",
          delivered, first_sample);
    if (w != nullptr) {
      w->delivered = true;
      for (int i = 0; i < MREC_WORDS; ++i) {
        if (i == MREC_SEQUENCE_WORD || i == MREC_RESULT_DROPS_WORD) continue;
        CHECK(word[i] == w->expected_word[i],
              "record (fs=%llu) word %d: got 0x%08lx expected 0x%08lx",
              first_sample, i, (unsigned long)(uint32_t)word[i],
              (unsigned long)(uint32_t)w->expected_word[i]);
      }
    }
    // Sequence discipline: delivered records carry exactly 1,2,3,...
    CHECK((uint32_t)word[MREC_SEQUENCE_WORD] == delivered,
          "record sequence %u expected %u",
          (unsigned)(uint32_t)word[MREC_SEQUENCE_WORD], delivered);
    // Both drop words are reserved-zero in this implementation: emission
    // is blocking and every closed window is finalized (single-shot).
    CHECK((uint32_t)word[MREC_RESULT_DROPS_WORD] == 0, "result_drops nonzero");
    last_result_drops = (uint32_t)word[MREC_RESULT_DROPS_WORD];
    CHECK((uint32_t)word[MREC_EMIT_DROPS_WORD] == 0, "emit_drops nonzero");

    // Remember the delivered identity; result-beat pairing happens in
    // finish() because cosim does not guarantee cross-stream arrival order.
    delivered_records.push_back(
        {first_sample, (uint32_t)word[MREC_SEQUENCE_WORD]});
  }

  struct DeliveredRecord {
    unsigned long long first_sample;
    uint32_t sequence;
  };
  std::vector<DeliveredRecord> delivered_records;

  void finish() {
    // Single-shot engine: every closed window is finalized and delivered.
    CHECK(delivered == golden.total_closes,
          "conservation: delivered %u != closes %u", delivered,
          golden.total_closes);
    for (const auto &w : golden.windows) {
      CHECK(w.delivered, "window (fs=%llu) never delivered", w.first_sample);
    }
    CHECK(results.size() == delivered, "result/record count mismatch: %zu vs %u",
          results.size(), delivered);

    // Pair every delivered record with its basic-result beat and check the
    // beat against the golden window, content-addressed by first_sample.
    for (const auto &d : delivered_records) {
      const basic_result_t *got = nullptr;
      for (const auto &r : results) {
        if (r.first_sample == ap_uint<64>(d.first_sample)) {
          got = &r;
          break;
        }
      }
      CHECK(got != nullptr, "no result beat for record fs=%llu",
            d.first_sample);
      const GoldenWindow *w = nullptr;
      for (const auto &gw : golden.windows) {
        if (gw.first_sample == d.first_sample) {
          w = &gw;
          break;
        }
      }
      if (got == nullptr || w == nullptr) continue;
      const basic_result_t &exp = w->expected_result;
      CHECK(got->sequence == d.sequence, "result sequence != record word 3");
      CHECK(got->generation == exp.generation, "result generation");
      CHECK(got->sample_rate_hz == exp.sample_rate_hz, "result rate");
      CHECK(got->sample_count == exp.sample_count, "result count");
      CHECK(got->valid_mask == exp.valid_mask, "result mask");
      CHECK(got->flags == exp.flags, "result flags");
      CHECK(got->cycle_count == exp.cycle_count, "result cycles");
      CHECK(got->nominal_hz == exp.nominal_hz, "result nominal");
      CHECK(got->status == exp.status, "result status");
      CHECK(got->frequency_millihz == exp.frequency_millihz, "result freq");
      CHECK(got->frequency_valid == exp.frequency_valid, "result freq_valid");
      for (int lane = 0; lane < MTR_CHANNEL_LANES; ++lane) {
        CHECK(got->rms_q16[lane] == exp.rms_q16[lane], "result rms lane %d",
              lane);
      }
    }
  }
};

// ---------------------------------------------------------------------------
// Driver.
// ---------------------------------------------------------------------------
struct Bench {
  hls::stream<mtr1_sample_beat_t> s_sample{"s_sample"};
  hls::stream<record_axis_t> m_axis{"m_axis"};
  hls::stream<basic_result_beat_t> m_result{"m_result"};
  Golden golden;
  Scoreboard board{golden};
  std::vector<record_axis_t> partial_record;
  FrameSpec base = {};
  unsigned long long next_first_sample = 1000;

  void drain() {
    while (!m_result.empty()) {
      board.results.push_back(unpack_basic_result(m_result.read()));
    }
    while (!m_axis.empty()) {
      partial_record.push_back(m_axis.read());
      if (partial_record.back().last == 1) {
        board.take_record(partial_record);
        partial_record.clear();
      }
    }
  }

  void step(const FrameSpec &f, bool must_deliver_window = false) {
    golden.feed(f, must_deliver_window);
    s_sample.write(pack_frame(f));
    hls_mtr1_engine(s_sample, m_axis, m_result);
    drain();
  }

  void flush(int calls = 8) {
    for (int i = 0; i < calls; ++i) {
      hls_mtr1_engine(s_sample, m_axis, m_result);
      drain();
    }
  }

  // Configure the base frame's shadow-config fields and toggle APPLY on
  // the next frame sent.
  void apply(unsigned generation, unsigned rate, unsigned window,
             unsigned mask, bool enable, bool dc_remove) {
    base.cfg_generation = generation;
    base.cfg_rate = rate;
    base.cfg_window = window;
    base.cfg_mask = mask;
    base.enable = enable;
    base.dc_remove = dc_remove;
    base.apply_toggle = !base.apply_toggle;
    FrameSpec f = base;  // the APPLY-carrying frame is not accumulated
    step(f);
  }

  // Feed one whole cycle-mode window of identical frames (plus a distinct
  // closing frame) and close it. Context fields are derived from the
  // window index so every window is unique and content-addressable.
  void run_window(unsigned frames, const long long *samples, const int *raw,
                  unsigned frame_mask, bool must_deliver,
                  unsigned block_flags = (1u << MTR_FLAG_LOCKED),
                  unsigned nominal = 50, unsigned cycles = 10) {
    FrameSpec f = base;
    f.frame_mask = frame_mask;
    f.frame_generation = base.cfg_generation;
    f.cycle_mode = true;
    for (int lane = 0; lane < MTR_CHANNEL_LANES; ++lane) {
      f.samples[lane] = samples[lane];
      f.raw[lane] = raw[lane];
    }
    const unsigned long long fs = next_first_sample;
    next_first_sample += frames + 7;  // unique, gapless not required here
    f.first_sample = fs;
    f.cycle_count = cycles;
    f.nominal_hz = nominal;
    f.block_flags = block_flags;
    f.freq_millihz = 49987 + (unsigned)(fs & 0xFF);
    f.freq_status = 0x2 | 0x30;  // VALID bit set + arbitrary mode bits
    f.freq_period = 0x00140000 + (unsigned)(fs & 0xFF);
    f.freq_sequence = 77 + (unsigned)(fs & 0xFF);
    f.cap_frames = 100000 + (unsigned)fs;
    f.cap_headers = 3;
    f.cap_overflows = 4;
    f.cap_alerts = 5;
    for (unsigned i = 0; i + 1 < frames; ++i) {
      f.closes = false;
      step(f);
    }
    f.closes = true;
    step(f, must_deliver);
  }
};

static const long long kZeroSamples[MTR_CHANNEL_LANES] = {0, 0, 0, 0,
                                                          0, 0, 0, 0};
static const int kZeroRaw[MTR_CHANNEL_LANES] = {0, 0, 0, 0, 0, 0, 0, 0};

int main() {
  Bench bench;
  // Base frame defaults (shadow config fields start at engine defaults so
  // pre-APPLY beats carry a consistent picture).
  bench.base.cfg_generation = 0;
  bench.base.cfg_rate = 32000;
  bench.base.cfg_window = 6400;
  bench.base.cfg_mask = 0;
  bench.base.enable = false;
  bench.base.dc_remove = true;
  bench.base.frame_mask = 0x7F;

  // S0: frames before any APPLY are ignored (engine resets disabled).
  {
    FrameSpec f = bench.base;
    f.cycle_mode = true;
    f.closes = true;  // even a "closing" frame must do nothing
    f.samples[0] = 1234;
    for (int i = 0; i < 5; ++i) bench.step(f);
  }

  // S1: constant DC, dc_remove on -> mean = DC, both RMS ~ 0.
  bench.apply(/*gen=*/1, /*rate=*/32000, /*window=*/6400, /*mask=*/0x7F,
              /*enable=*/true, /*dc=*/true);
  {
    long long samples[MTR_CHANNEL_LANES];
    int raw[MTR_CHANNEL_LANES];
    for (int lane = 0; lane < MTR_CHANNEL_LANES; ++lane) {
      samples[lane] = (long long)(lane + 1) << 16;  // (lane+1).0 in Q16
      raw[lane] = (lane + 1) * 100;
    }
    bench.run_window(520, samples, raw, 0x7F, /*must_deliver=*/true);
  }

  // S2: alternating +/-A around an offset (AC content, dc on).
  {
    FrameSpec f = bench.base;
    f.frame_mask = 0x7F;
    f.frame_generation = 1;
    f.cycle_mode = true;
    f.first_sample = bench.next_first_sample;
    bench.next_first_sample += 1000;
    f.cycle_count = 10;
    f.nominal_hz = 50;
    f.block_flags = 1u << MTR_FLAG_LOCKED;
    f.freq_millihz = 50011;
    f.freq_status = 0x2;
    f.freq_period = 0x00140001;
    f.freq_sequence = 501;
    f.cap_frames = 42;
    f.cap_headers = 0;
    f.cap_overflows = 0;
    f.cap_alerts = 0;
    for (unsigned i = 0; i < 520; ++i) {
      for (int lane = 0; lane < MTR_CHANNEL_LANES; ++lane) {
        const long long amplitude = ((long long)(lane + 3) << 16) / 2;
        const long long offset = (long long)(lane) << 12;
        f.samples[lane] = offset + ((i & 1) ? amplitude : -amplitude);
        f.raw[lane] = (int)(((i & 1) ? 1 : -1) * (lane + 1) * 321 + 17);
      }
      f.closes = (i == 519);
      bench.step(f, f.closes);
    }
  }

  // S3: dc_remove OFF (new generation) -> zero-referenced RMS.
  bench.apply(2, 32000, 6400, 0x7F, true, /*dc=*/false);
  {
    long long samples[MTR_CHANNEL_LANES];
    int raw[MTR_CHANNEL_LANES];
    for (int lane = 0; lane < MTR_CHANNEL_LANES; ++lane) {
      samples[lane] = ((long long)(lane + 2) << 16) + 12345;
      raw[lane] = -(lane + 1) * 4567;
    }
    bench.base.cfg_generation = 2;  // keep base coherent for run_window
    bench.run_window(520, samples, raw, 0x7F, true);
  }

  // S4: legacy sample-count mode, two back-to-back windows of 520.
  bench.apply(3, 32000, /*window=*/520, 0x7F, true, true);
  {
    FrameSpec f = bench.base;
    f.frame_generation = 3;
    f.frame_mask = 0x7F;
    f.cycle_mode = false;
    f.closes = false;  // legacy mode ignores the marker
    for (int lane = 0; lane < MTR_CHANNEL_LANES; ++lane) {
      f.samples[lane] = (long long)(lane * 7 + 1) << 14;
      f.raw[lane] = lane * 11 + 5;
    }
    for (int window_index = 0; window_index < 2; ++window_index) {
      f.first_sample = bench.next_first_sample;
      bench.next_first_sample += 600;
      f.cycle_count = 0;
      f.nominal_hz = 0;
      f.block_flags = 0;
      f.freq_millihz = 60000 + window_index;
      f.freq_status = 0;
      f.freq_period = 1;
      f.freq_sequence = 9 + window_index;
      f.cap_frames = 7 + window_index;
      f.cap_headers = 1;
      f.cap_overflows = 2;
      f.cap_alerts = 3;
      // In cosim the golden can't see the engine's close, so mark
      // must_deliver on the frame that closes per the golden's own count.
      for (unsigned i = 0; i < 520; ++i) {
        bench.step(f, /*must_deliver=*/i == 519);
      }
    }
  }

  // S5: mask interaction — active mask AND closing frame's mask AND 0x7F.
  bench.apply(4, 32000, 6400, /*mask=*/0xB5, true, true);
  {
    FrameSpec f = bench.base;
    f.frame_generation = 4;
    f.cycle_mode = true;
    for (int lane = 0; lane < MTR_CHANNEL_LANES; ++lane) {
      f.samples[lane] = (long long)(lane + 1) * 3 << 15;
      f.raw[lane] = (lane + 1) * 9;
    }
    f.first_sample = bench.next_first_sample;
    bench.next_first_sample += 600;
    f.cycle_count = 12;
    f.nominal_hz = 60;
    f.block_flags = 1u << MTR_FLAG_LOCKED;
    f.freq_millihz = 59993;
    f.freq_status = 0x2;
    f.freq_period = 2;
    f.freq_sequence = 1;
    f.cap_frames = 1;
    f.cap_headers = 0;
    f.cap_overflows = 0;
    f.cap_alerts = 0;
    f.frame_mask = 0x6F;  // mid-window mask (ignored: only close matters)
    for (unsigned i = 0; i < 519; ++i) bench.step(f);
    f.frame_mask = 0x2F;  // closing frame mask -> word7 = 0xB5 & 0x2F & 0x7F
    f.closes = true;
    bench.step(f, true);
  }

  // S6: defensive clears — malformed then stale-generation mid-window.
  {
    FrameSpec f = bench.base;
    f.frame_generation = 4;
    f.frame_mask = 0x7F;
    f.cycle_mode = true;
    for (int lane = 0; lane < MTR_CHANNEL_LANES; ++lane) {
      f.samples[lane] = 999999 + lane;
      f.raw[lane] = 100 + lane;
    }
    // Garbage that must be discarded by the clears.
    for (int i = 0; i < 10; ++i) bench.step(f);
    FrameSpec bad = f;
    bad.malformed = true;
    bench.step(bad);  // clears the 10 accumulated frames
    for (int i = 0; i < 10; ++i) bench.step(f);
    FrameSpec stale = f;
    stale.frame_generation = 1;  // stale generation
    bench.step(stale);           // clears again
    // Now a clean, fully-checked window.
    f.first_sample = bench.next_first_sample;
    bench.next_first_sample += 600;
    f.cycle_count = 12;
    f.nominal_hz = 60;
    f.block_flags = (1u << MTR_FLAG_LOCKED) | (1u << MTR_FLAG_FIRST_BLOCK);
    f.freq_millihz = 60002;
    f.freq_status = 0x2;
    f.freq_period = 3;
    f.freq_sequence = 2;
    f.cap_frames = 2;
    f.cap_headers = 0;
    f.cap_overflows = 1;
    f.cap_alerts = 0;
    for (unsigned i = 0; i < 519; ++i) bench.step(f);
    f.closes = true;
    bench.step(f, true);
  }

  // S7: saturation/overflow paths, then stickiness across the next window.
  bench.apply(5, 32000, 6400, 0x7F, true, true);
  {
    FrameSpec f = bench.base;
    f.frame_generation = 5;
    f.frame_mask = 0x7F;
    f.cycle_mode = true;
    f.first_sample = bench.next_first_sample;
    bench.next_first_sample += 600;
    f.cycle_count = 10;
    f.nominal_hz = 50;
    f.block_flags = 1u << MTR_FLAG_LOCKED;
    f.freq_millihz = 50000;
    f.freq_status = 0x2;
    f.freq_period = 4;
    f.freq_sequence = 3;
    f.cap_frames = 3;
    f.cap_headers = 0;
    f.cap_overflows = 0;
    f.cap_alerts = 0;
    // Eight max-magnitude frames saturate the square accumulators (each
    // square ~ 2^126; the fifth addition carries out) and push |sum| past
    // 64 bits (too-wide rule).
    for (int i = 0; i < 8; ++i) {
      for (int lane = 0; lane < MTR_CHANNEL_LANES; ++lane) {
        f.samples[lane] = 0x7FFFFFFFFFFFFFFFll;
        f.raw[lane] = 1000;
      }
      bench.step(f);
    }
    // Pad with zeros (saturated accumulators stay saturated) and close.
    for (int lane = 0; lane < MTR_CHANNEL_LANES; ++lane) {
      f.samples[lane] = 0;
      f.raw[lane] = 1000;
    }
    for (unsigned i = 0; i < 511; ++i) bench.step(f);
    f.closes = true;
    bench.step(f, true);

    // Next window: benign values, but status bit 0 must STILL be set
    // (sticky until APPLY).
    long long samples[MTR_CHANNEL_LANES];
    int raw[MTR_CHANNEL_LANES];
    for (int lane = 0; lane < MTR_CHANNEL_LANES; ++lane) {
      samples[lane] = 1 << 16;
      raw[lane] = 1;
    }
    bench.base.cfg_generation = 5;
    bench.run_window(520, samples, raw, 0x7F, true);
  }

  // S8: negative mean truncation toward zero (|sum| not divisible by N).
  bench.apply(6, 32000, 6400, 0x7F, true, true);
  {
    FrameSpec f = bench.base;
    f.frame_generation = 6;
    f.frame_mask = 0x7F;
    f.cycle_mode = true;
    f.first_sample = bench.next_first_sample;
    bench.next_first_sample += 600;
    f.cycle_count = 10;
    f.nominal_hz = 50;
    f.block_flags = 1u << MTR_FLAG_LOCKED;
    f.freq_millihz = 49999;
    f.freq_status = 0x0;  // frequency INVALID this window
    f.freq_period = 5;
    f.freq_sequence = 4;
    f.cap_frames = 4;
    f.cap_headers = 0;
    f.cap_overflows = 0;
    f.cap_alerts = 0;
    const long long v = -((7ll << 16) + 3);  // negative, non-round
    for (int lane = 0; lane < MTR_CHANNEL_LANES; ++lane) {
      f.samples[lane] = v;
      f.raw[lane] = -3;
    }
    for (unsigned i = 0; i < 519; ++i) bench.step(f);
    // Distinct closing frame makes |sum| non-divisible by N.
    for (int lane = 0; lane < MTR_CHANNEL_LANES; ++lane) {
      f.samples[lane] = v - 1;
    }
    f.closes = true;
    bench.step(f, true);
  }

  // S9: drop stress (legacy window=4) then a big window carrying the
  // final drop count for conservation.
  bench.apply(7, 32000, /*window=*/4, 0x7F, true, true);
  {
    FrameSpec f = bench.base;
    f.frame_generation = 7;
    f.frame_mask = 0x7F;
    f.cycle_mode = false;
    for (int lane = 0; lane < MTR_CHANNEL_LANES; ++lane) {
      f.samples[lane] = (lane + 1) << 10;
      f.raw[lane] = lane + 1;
    }
    for (int burst_window = 0; burst_window < 10; ++burst_window) {
      f.first_sample = bench.next_first_sample;
      bench.next_first_sample += 10;
      f.cycle_count = 0;
      f.nominal_hz = 0;
      f.block_flags = 0;
      f.freq_millihz = 1;
      f.freq_status = 0;
      f.freq_period = 6;
      f.freq_sequence = 5;
      f.cap_frames = 5;
      f.cap_headers = 0;
      f.cap_overflows = 0;
      f.cap_alerts = 0;
      for (int i = 0; i < 4; ++i) bench.step(f);
    }
  }
  bench.apply(8, 32000, /*window=*/520, 0x7F, true, true);
  {
    FrameSpec f = bench.base;
    f.frame_generation = 8;
    f.frame_mask = 0x7F;
    f.cycle_mode = false;
    for (int lane = 0; lane < MTR_CHANNEL_LANES; ++lane) {
      f.samples[lane] = (lane + 1) << 9;
      f.raw[lane] = lane;
    }
    f.first_sample = bench.next_first_sample;
    bench.next_first_sample += 600;
    f.cycle_count = 0;
    f.nominal_hz = 0;
    f.block_flags = 0;
    f.freq_millihz = 2;
    f.freq_status = 0;
    f.freq_period = 7;
    f.freq_sequence = 6;
    f.cap_frames = 6;
    f.cap_headers = 0;
    f.cap_overflows = 0;
    f.cap_alerts = 0;
    for (unsigned i = 0; i < 520; ++i) {
      bench.step(f, /*must_deliver=*/i == 519);
    }
  }

  bench.flush(64);
  bench.board.finish();

  if (failures) {
    std::printf("mtr1_engine_tb: %d FAILURE(S)\n", failures);
    return EXIT_FAILURE;
  }
  std::printf("mtr1_engine_tb: PASS (%u windows closed, %u delivered)\n",
              bench.golden.total_closes, bench.board.delivered);
  return EXIT_SUCCESS;
}
