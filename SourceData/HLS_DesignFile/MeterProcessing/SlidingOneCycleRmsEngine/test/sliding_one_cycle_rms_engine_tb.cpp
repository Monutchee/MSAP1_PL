// Testbench for the sliding one-cycle RMS / PQ event engine (M12).
//
// Stimulus is CONSTANT per lane between transitions, which makes the
// golden exact with no tolerance anywhere: the zero-referenced RMS of a
// constant is the constant, and across a transition the sliding window
// is exactly sqrt((n_prev*Vprev^2 + n_curr*Vcurr^2)/(n_prev+n_curr)).
// The bench replicates that in __int128 and compares every published
// word bit for bit.
//
// Covered: window priming, steady-state Urms(1/2), the periodic
// heartbeat and its window extremes, sag detect/recover with residual
// and duration, hysteresis holding an event open, severity escalation
// from sag to interruption, swell, the polyphase begin/end rule,
// disarmed operation (reference 0 keeps snapshots and declares nothing),
// and APPLY abandoning an open event.

#include <cmath>
#include <cstdio>
#include <cstdlib>

#include "sliding_one_cycle_rms_engine.hpp"

static int failures = 0;

#define CHECK(cond, ...)                                                      \
  do {                                                                        \
    if (!(cond)) {                                                            \
      std::printf("FAIL: " __VA_ARGS__);                                      \
      std::printf("\n");                                                      \
      ++failures;                                                             \
    }                                                                         \
  } while (0)

// ---------------------------------------------------------------------------
// Exact integer golden of the sliding window.
// ---------------------------------------------------------------------------
static unsigned __int128 golden_isqrt(unsigned __int128 value) {
  unsigned __int128 root = 0;
  for (int bit = 63; bit >= 0; --bit) {
    const unsigned __int128 candidate = root | ((unsigned __int128)1 << bit);
    if (candidate * candidate <= value) root = candidate;
  }
  return root;
}

static const int PQ_LANES = 2 * PQ_PHASES;
static const int lane_of[PQ_LANES] = {MET_LANE_VA, MET_LANE_VB, MET_LANE_VC,
                                      MET_LANE_IA, MET_LANE_IB, MET_LANE_IC};

struct GoldenWindow {
  unsigned __int128 curr[PQ_LANES] = {};
  unsigned __int128 prev[PQ_LANES] = {};
  unsigned curr_count = 0;
  unsigned prev_count = 0;
  bool primed = false;
  unsigned long long urms[PQ_PHASES] = {};
  unsigned long long irms[PQ_PHASES] = {};

  void sample(const long long value[PQ_LANES]) {
    for (int i = 0; i < PQ_LANES; ++i) {
      const unsigned long long magnitude =
          (unsigned long long)(value[i] < 0 ? -value[i] : value[i]);
      curr[i] += (unsigned __int128)magnitude * magnitude;
    }
    ++curr_count;
  }
  /* Returns true when the boundary produced published values. */
  bool close_half() {
    const bool was_primed = primed;
    if (was_primed) {
      const unsigned count = prev_count + curr_count;
      for (int i = 0; i < PQ_LANES; ++i) {
        const unsigned __int128 total = prev[i] + curr[i];
        const unsigned __int128 variance =
            (total * count) / ((unsigned __int128)count * count);
        const unsigned long long root =
            (unsigned long long)golden_isqrt(variance);
        if (i < PQ_PHASES) urms[i] = root; else irms[i - PQ_PHASES] = root;
      }
    }
    for (int i = 0; i < PQ_LANES; ++i) { prev[i] = curr[i]; curr[i] = 0; }
    prev_count = curr_count;
    curr_count = 0;
    primed = true;
    return was_primed;
  }
  void reset() {
    for (int i = 0; i < PQ_LANES; ++i) { curr[i] = 0; prev[i] = 0; }
    curr_count = 0; prev_count = 0; primed = false;
  }
};

// ---------------------------------------------------------------------------
// Bench: drives frames and collects records.
// ---------------------------------------------------------------------------
static const int HALF_SAMPLES = 8;  // samples per half cycle (bench cadence)

struct Bench {
  hls::stream<pq_input_beat_t> s_frame{"s_frame"};
  hls::stream<record_axis_t> m_axis{"m_axis"};
  hls::stream<record_axis_t> m_pqe{"m_pqe"};
  bool apply_level = false;
  unsigned generation = 1;
  unsigned sample_rate = 32000;
  unsigned valid_mask = 0x7F;
  bool enable = true;
  bool locked = true;
  bool fallback = false;
  bool malformed = false;
  unsigned reference = 120000000u;  // 120 V in micro-volts
  unsigned sag = 9000, swell = 11000, interrupt = 1000, hysteresis = 200;
  unsigned long long sample_index = 1000;
  GoldenWindow golden;
  unsigned summary_count = 0;
  ap_uint<32> last_summary[PQE_PAYLOAD_WORDS] = {};

  void drain_summaries() {
    while (!m_pqe.empty()) {
      for (int word = 0; word < PQE_PAYLOAD_WORDS; ++word) {
        CHECK(!m_pqe.empty(), "PQE summary has all 64 beats");
        if (m_pqe.empty()) return;
        const record_axis_t output = m_pqe.read();
        last_summary[word] = output.data;
        CHECK(output.keep == MREC_KEEP_ALL && output.strb == MREC_KEEP_ALL,
              "PQE summary beat %d has full byte qualifiers", word);
        CHECK((output.last == 1) == (word == PQE_PAYLOAD_WORDS - 1),
              "PQE summary TLAST on beat 63 only (beat %d)", word);
      }
      ++summary_count;
    }
  }

  void send(const long long value[PQ_LANES], bool half,
            bool apply_toggles = false) {
    if (apply_toggles) apply_level = !apply_level;
    pq_input_beat_t beat = 0;
    for (int i = 0; i < PQ_LANES; ++i) {
      beat.range(PQIN_SAMPLES_LSB + lane_of[i] * MET_RMS_LANE_BITS +
                     MET_RMS_LANE_BITS - 1,
                 PQIN_SAMPLES_LSB + lane_of[i] * MET_RMS_LANE_BITS) =
          ap_uint<MET_RMS_LANE_BITS>(ap_int<MET_RMS_LANE_BITS>(value[i]));
    }
    beat.range(PQIN_FRAME_MASK_LSB + 7, PQIN_FRAME_MASK_LSB) = valid_mask;
    beat[PQIN_HALF_BIT] = half ? 1 : 0;
    beat[PQIN_MALFORMED_BIT] = malformed ? 1 : 0;
    beat[PQIN_LOCKED_BIT] = locked ? 1 : 0;
    beat[PQIN_FALLBACK_BIT] = fallback ? 1 : 0;
    beat[PQIN_APPLY_BIT] = apply_level ? 1 : 0;
    beat[PQIN_ENABLE_BIT] = enable ? 1 : 0;
    beat.range(PQIN_CFG_GEN_LSB + 31, PQIN_CFG_GEN_LSB) = generation;
    beat.range(PQIN_CFG_RATE_LSB + 31, PQIN_CFG_RATE_LSB) = sample_rate;
    beat.range(PQIN_CFG_MASK_LSB + 7, PQIN_CFG_MASK_LSB) = valid_mask;
    beat.range(PQIN_SAMPLE_IDX_LSB + 63, PQIN_SAMPLE_IDX_LSB) = sample_index;
    beat.range(PQIN_REFERENCE_LSB + 31, PQIN_REFERENCE_LSB) = reference;
    beat.range(PQIN_SAG_LSB + 15, PQIN_SAG_LSB) = sag;
    beat.range(PQIN_SWELL_LSB + 15, PQIN_SWELL_LSB) = swell;
    beat.range(PQIN_INTERRUPT_LSB + 15, PQIN_INTERRUPT_LSB) = interrupt;
    beat.range(PQIN_HYSTERESIS_LSB + 15, PQIN_HYSTERESIS_LSB) = hysteresis;
    s_frame.write(beat);
    hls_sliding_one_cycle_rms_engine(s_frame, m_axis, m_pqe);
    drain_summaries();
    if (!malformed && enable) {
      golden.sample(value);
      if (half) golden.close_half();
    }
    ++sample_index;
  }

  /* Drive one whole half cycle at a constant per-lane level. */
  void half_cycle(const long long value[PQ_LANES]) {
    for (int i = 0; i < HALF_SAMPLES; ++i)
      send(value, i == HALF_SAMPLES - 1);
  }

  bool take(ap_uint<32> (&words)[MREC_WORDS]) {
    if (m_axis.empty()) return false;
    int beats = 0;
    while (!m_axis.empty() && beats < MREC_WORDS) {
      const record_axis_t beat = m_axis.read();
      words[beats] = beat.data;
      CHECK(beat.keep == MREC_KEEP_ALL, "TKEEP full");
      CHECK((beat.last == 1) == (beats == MREC_WORDS - 1),
            "TLAST on beat 63 only (beat %d)", beats);
      ++beats;
    }
    CHECK(beats == MREC_WORDS, "record is 64 beats, got %d", beats);
    CHECK(words[MREC_FORMAT_WORD] == MREC_FORMAT_PQEVT_V1,
          "format %08x", (unsigned)words[MREC_FORMAT_WORD]);
    return true;
  }
  void drain() { ap_uint<32> w[MREC_WORDS]; while (take(w)) {} }
};

// Drive half cycles until a record appears, with a hard bound: an
// unbounded wait would hang cosim instead of failing it.
static bool wait_for_record(Bench &b, ap_uint<32> (&w)[MREC_WORDS],
                            const long long level[2 * PQ_PHASES],
                            int max_updates = 4 * PQ_PERIODIC_UPDATES) {
  for (int i = 0; i < max_updates; ++i) {
    if (b.take(w)) return true;
    b.half_cycle(level);
  }
  return b.take(w);
}

static unsigned kind_of(const ap_uint<32> (&w)[MREC_WORDS]) {
  return (unsigned)((w[PQ_KIND_WORD] >> PQ_KIND_LSB) & 0xFF);
}
static unsigned type_of(const ap_uint<32> (&w)[MREC_WORDS]) {
  return (unsigned)((w[PQ_KIND_WORD] >> PQ_KIND_EVENT_LSB) & 0xFF);
}
static unsigned phases_of(const ap_uint<32> (&w)[MREC_WORDS]) {
  return (unsigned)((w[PQ_KIND_WORD] >> PQ_KIND_PHASES_LSB) & 0x7);
}
static unsigned long long duration_of(const ap_uint<32> (&w)[MREC_WORDS]) {
  return (unsigned long long)w[PQ_DURATION_LOW_WORD] |
         ((unsigned long long)w[PQ_DURATION_HIGH_WORD] << 32);
}

int main() {
  static_assert(PQIN_BITS == 736, "input beat width is normative");

  // 120 V nominal expressed as a Q16 micro-unit sample level.
  const long long nominal = (long long)120000000 << 16;
  const auto level = [&](double fraction) {
    return (long long)((double)nominal * fraction);
  };
  long long steady[PQ_LANES];
  for (int i = 0; i < PQ_PHASES; ++i) steady[i] = nominal;
  for (int i = PQ_PHASES; i < PQ_LANES; ++i) steady[i] = nominal / 40;

  Bench b;
  ap_uint<32> w[MREC_WORDS];

  // --- Priming: the first half cycle publishes nothing. ------------------
  // The engine stays disabled until a configuration APPLY commits, like
  // every sibling engine, so the very first frame carries the toggle.
  {
    b.send(steady, false, /*apply_toggles=*/true);
    for (int i = 0; i < HALF_SAMPLES - 1; ++i)
      b.send(steady, i == HALF_SAMPLES - 2);
    b.send(steady, false);
    CHECK(b.m_axis.empty(), "no record before the window is primed");
  }

  // --- Steady state: Urms(1/2) is exact, no events. ----------------------
  {
    for (int i = 0; i < HALF_SAMPLES - 1; ++i) b.send(steady, false);
    b.send(steady, true);
    CHECK(b.m_axis.empty(), "steady state declares no event");
    CHECK((unsigned long long)b.golden.urms[0] ==
              (unsigned long long)nominal,
          "golden Urms of a constant is the constant (got %llu)",
          (unsigned long long)b.golden.urms[0]);
    CHECK(b.summary_count == 1, "one PQE1 payload per qualified half-cycle");
    CHECK(b.last_summary[PQE_SEQUENCE_WORD] == 1,
          "first PQE1 payload sequence is one");
    CHECK(b.last_summary[PQE_GENERATION_WORD] == b.generation &&
              b.last_summary[PQE_SAMPLE_RATE_WORD] == b.sample_rate,
          "PQE1 echoes generation and rate");
    CHECK(b.last_summary[PQE_VALID_PHASES_WORD] == 0x707,
          "PQE1 maps A/B/C voltage and current validity");
    const unsigned long long summary_first =
        (unsigned long long)b.last_summary[PQE_FIRST_SAMPLE_LOW_WORD] |
        ((unsigned long long)b.last_summary[PQE_FIRST_SAMPLE_HIGH_WORD] << 32);
    const unsigned long long summary_last =
        (unsigned long long)b.last_summary[PQE_LAST_SAMPLE_LOW_WORD] |
        ((unsigned long long)b.last_summary[PQE_LAST_SAMPLE_HIGH_WORD] << 32);
    CHECK(summary_last - summary_first + 1 ==
              (unsigned)b.last_summary[PQE_WINDOW_SAMPLES_WORD],
          "PQE1 sample anchors match the exact one-cycle sample count");
    CHECK((b.last_summary[PQE_STATUS_WORD] &
              (1u << PQE_STATUS_DISCONTINUITY_BIT)) != 0,
          "first PQE1 payload is marked discontinuous");
    for (int phase = 0; phase < PQ_PHASES; ++phase) {
      const unsigned long long urms =
          (unsigned long long)b.last_summary[
              PQE_URMS_Q16_BASE_WORD + phase * 2] |
          ((unsigned long long)b.last_summary[
              PQE_URMS_Q16_BASE_WORD + phase * 2 + 1] << 32);
      const unsigned long long irms =
          (unsigned long long)b.last_summary[
              PQE_IRMS_Q16_BASE_WORD + phase * 2] |
          ((unsigned long long)b.last_summary[
              PQE_IRMS_Q16_BASE_WORD + phase * 2 + 1] << 32);
      CHECK(urms == b.golden.urms[phase],
            "PQE1 phase %d Urms Q16 is byte exact", phase);
      CHECK(irms == b.golden.irms[phase],
            "PQE1 phase %d Irms Q16 is byte exact", phase);
    }
    for (int word = 30; word < PQE_PAYLOAD_WORDS; ++word)
      CHECK(b.last_summary[word] == 0,
            "PQE1 reserved word %d is zero", word);
  }

  // --- Periodic heartbeat after PQ_PERIODIC_UPDATES updates. -------------
  {
    CHECK(wait_for_record(b, w, steady), "heartbeat must arrive");
    CHECK(kind_of(w) == (unsigned)MET_PQ_KIND_PERIODIC,
          "heartbeat kind (got %u)", kind_of(w));
    CHECK(type_of(w) == (unsigned)MET_PQ_EVENT_NONE, "heartbeat has no type");
    CHECK(w[PQ_EVENT_SEQ_WORD] == 0, "heartbeat carries no event sequence");
    CHECK(w[PQ_UPDATES_WORD] == (unsigned)PQ_PERIODIC_UPDATES,
          "heartbeat spans the configured update count (got %u)",
          (unsigned)w[PQ_UPDATES_WORD]);
    for (int phase = 0; phase < PQ_PHASES; ++phase) {
      const unsigned expect = (unsigned)(b.golden.urms[phase] >> 16);
      CHECK((unsigned)w[PQ_URMS_BASE_WORD + phase] == expect,
            "phase %d Urms exact (got %u expected %u)", phase,
            (unsigned)w[PQ_URMS_BASE_WORD + phase], expect);
      CHECK((unsigned)w[PQ_URMS_MIN_BASE_WORD + phase] == expect &&
                (unsigned)w[PQ_URMS_MAX_BASE_WORD + phase] == expect,
            "phase %d steady extremes equal the level", phase);
      CHECK((unsigned)w[PQ_IRMS_BASE_WORD + phase] ==
                (unsigned)(b.golden.irms[phase] >> 16),
            "phase %d Irms exact", phase);
    }
    CHECK(w[PQ_REFERENCE_WORD] == 120000000u &&
              w[PQ_SAG_THRESHOLD_WORD] == 9000 &&
              w[PQ_SWELL_THRESHOLD_WORD] == 11000 &&
              w[PQ_INTERRUPT_THRESHOLD_WORD] == 1000 &&
              w[PQ_HYSTERESIS_WORD] == 200,
          "threshold configuration echoed into the record");
    CHECK((w[PQ_KIND_WORD] >> PQ_KIND_ARMED_BIT) & 1u, "armed bit set");
    for (int i = 37; i < 64; ++i)
      CHECK(w[i] == 0, "reserved word %d zero", i);
  }

  // --- Sag on phase A: start, hysteresis hold, end with residual. --------
  {
    b.drain();
    long long sag_level[PQ_LANES];
    for (int i = 0; i < PQ_LANES; ++i) sag_level[i] = steady[i];
    sag_level[0] = level(0.80);  // 96 V, below the 90 % threshold

    // The transition half blends old and new; the SECOND dipped half is
    // fully below the threshold. Detection may fire on either, so drive
    // until the start record appears.
    const unsigned long long start_index_before = b.sample_index;
    b.half_cycle(sag_level);
    bool started = b.take(w);
    if (!started) { b.half_cycle(sag_level); started = b.take(w); }
    CHECK(started, "a 20 %% dip declares an event");
    CHECK(kind_of(w) == (unsigned)MET_PQ_KIND_EVENT_START, "event-start kind");
    CHECK(type_of(w) == (unsigned)MET_PQ_EVENT_SAG, "type is sag (got %u)",
          type_of(w));
    CHECK(phases_of(w) == 0x1, "phase A only (got 0x%x)", phases_of(w));
    CHECK(w[PQ_EVENT_SEQ_WORD] == 1, "first event carries sequence 1");
    const unsigned long long event_start =
        (unsigned long long)w[MREC_FIRST_SAMPLE_LOW_WORD] |
        ((unsigned long long)w[MREC_FIRST_SAMPLE_HIGH_WORD] << 32);
    CHECK(event_start >= start_index_before,
          "event start anchors inside the dip");

    // Hysteresis: 91 % is above the 90 % threshold but below the 92 %
    // recovery level, so the event must stay open and emit nothing.
    long long hyst_level[PQ_LANES];
    for (int i = 0; i < PQ_LANES; ++i) hyst_level[i] = steady[i];
    hyst_level[0] = level(0.91);
    b.half_cycle(hyst_level);
    b.half_cycle(hyst_level);
    CHECK(b.m_axis.empty(), "hysteresis band keeps the event open");

    // Full recovery ends it.
    b.half_cycle(steady);
    b.half_cycle(steady);
    CHECK(b.take(w), "recovery ends the event");
    CHECK(kind_of(w) == (unsigned)MET_PQ_KIND_EVENT_END, "event-end kind");
    CHECK(type_of(w) == (unsigned)MET_PQ_EVENT_SAG, "end keeps the sag type");
    CHECK(w[PQ_EVENT_SEQ_WORD] == 1, "end ties to the same event sequence");
    CHECK(duration_of(w) > 0, "event has a nonzero sample duration");
    const unsigned residual = (unsigned)w[PQ_URMS_MIN_BASE_WORD];
    const unsigned expect_residual = (unsigned)(level(0.80) >> 16);
    CHECK(residual == expect_residual,
          "residual is the deepest Urms(1/2) reached (got %u expected %u)",
          residual, expect_residual);
    b.drain();
  }

  // --- Escalation: a dip that deepens reports as an interruption. --------
  {
    long long deep[PQ_LANES];
    for (int i = 0; i < PQ_LANES; ++i) deep[i] = steady[i];
    deep[1] = level(0.50);  // phase B sags
    b.half_cycle(deep);
    b.half_cycle(deep);
    CHECK(b.take(w) && kind_of(w) == (unsigned)MET_PQ_KIND_EVENT_START &&
              type_of(w) == (unsigned)MET_PQ_EVENT_SAG,
          "phase B dip starts as a sag");
    deep[1] = level(0.05);  // now an interruption
    b.half_cycle(deep);
    b.half_cycle(deep);
    for (int i = 0; i < PQ_LANES; ++i) deep[i] = steady[i];
    b.half_cycle(deep);
    b.half_cycle(deep);
    CHECK(b.take(w) && kind_of(w) == (unsigned)MET_PQ_KIND_EVENT_END,
          "the deepened event ends");
    CHECK(type_of(w) == (unsigned)MET_PQ_EVENT_INTERRUPTION,
          "severity escalates to interruption (got %u)", type_of(w));
    CHECK(phases_of(w) == 0x2, "phase B mask survives to the end record");
    b.drain();
  }

  // --- Swell. -------------------------------------------------------------
  {
    long long high[PQ_LANES];
    for (int i = 0; i < PQ_LANES; ++i) high[i] = steady[i];
    high[2] = level(1.15);
    b.half_cycle(high);
    b.half_cycle(high);
    CHECK(b.take(w) && type_of(w) == (unsigned)MET_PQ_EVENT_SWELL,
          "a 15 %% rise declares a swell");
    const unsigned peak = (unsigned)w[PQ_URMS_MAX_BASE_WORD + 2];
    CHECK(peak >= (unsigned)(level(1.10) >> 16), "swell peak is above 110 %%");
    for (int i = 0; i < PQ_LANES; ++i) high[i] = steady[i];
    b.half_cycle(high);
    b.half_cycle(high);
    CHECK(b.take(w) && kind_of(w) == (unsigned)MET_PQ_KIND_EVENT_END,
          "swell ends on recovery");
    b.drain();
  }

  // --- Polyphase: the event ends only when EVERY phase recovers. ---------
  {
    long long two[PQ_LANES];
    for (int i = 0; i < PQ_LANES; ++i) two[i] = steady[i];
    two[0] = level(0.70);
    two[1] = level(0.70);
    b.half_cycle(two);
    b.half_cycle(two);
    CHECK(b.take(w) && kind_of(w) == (unsigned)MET_PQ_KIND_EVENT_START,
          "two-phase dip starts an event");
    CHECK(phases_of(w) == 0x3, "both phases in the mask (got 0x%x)",
          phases_of(w));
    two[0] = steady[0];  // A recovers, B still dipped
    b.half_cycle(two);
    b.half_cycle(two);
    CHECK(b.m_axis.empty(),
          "one phase recovering must NOT end a polyphase event");
    two[1] = steady[1];
    b.half_cycle(two);
    b.half_cycle(two);
    CHECK(b.take(w) && kind_of(w) == (unsigned)MET_PQ_KIND_EVENT_END,
          "the event ends once every phase has recovered");
    CHECK(phases_of(w) == 0x3, "the end record keeps the union of phases");
    b.drain();
  }

  // --- Disarmed: reference 0 declares nothing but keeps snapshotting. ----
  {
    b.reference = 0;
    b.send(steady, false, /*apply_toggles=*/true);
    b.golden.reset();
    long long dead[PQ_LANES];
    for (int i = 0; i < PQ_LANES; ++i) dead[i] = steady[i];
    dead[0] = 0;  // a total collapse
    for (int i = 0; i < 6; ++i) b.half_cycle(dead);
    bool saw_event = false;
    while (b.take(w)) if (kind_of(w) != (unsigned)MET_PQ_KIND_PERIODIC)
      saw_event = true;
    CHECK(!saw_event, "a zero reference declares no event");
    CHECK(wait_for_record(b, w, dead), "disarmed heartbeat must arrive");
    CHECK(kind_of(w) == (unsigned)MET_PQ_KIND_PERIODIC &&
              ((w[PQ_KIND_WORD] >> PQ_KIND_ARMED_BIT) & 1u) == 0,
          "snapshots keep flowing with the armed bit clear");
    CHECK(w[PQ_URMS_BASE_WORD] == 0, "collapsed phase reports zero Urms");
    b.drain();
  }

  // --- APPLY abandons an open event. -------------------------------------
  {
    b.reference = 120000000u;
    b.send(steady, false, /*apply_toggles=*/true);
    b.golden.reset();
    for (int i = 0; i < 3; ++i) b.half_cycle(steady);
    b.drain();
    long long dip[PQ_LANES];
    for (int i = 0; i < PQ_LANES; ++i) dip[i] = steady[i];
    dip[0] = level(0.50);
    b.half_cycle(dip);
    b.half_cycle(dip);
    CHECK(b.take(w) && kind_of(w) == (unsigned)MET_PQ_KIND_EVENT_START,
          "dip opens an event before the APPLY");
    b.send(steady, false, /*apply_toggles=*/true);
    b.golden.reset();
    for (int i = 0; i < 4; ++i) b.half_cycle(steady);
    bool saw_end = false;
    while (b.take(w)) if (kind_of(w) == (unsigned)MET_PQ_KIND_EVENT_END)
      saw_end = true;
    CHECK(!saw_end, "APPLY abandons the open event instead of closing it");
  }

  // --- Disable stops everything. -----------------------------------------
  {
    b.enable = false;
    b.send(steady, true, /*apply_toggles=*/true);
    CHECK(b.m_axis.empty(), "disabled engine is silent");
  }

  if (failures != 0) {
    std::printf("FAILED: %d check(s)\n", failures);
    return EXIT_FAILURE;
  }
  std::printf("PASS: sliding_one_cycle_rms_engine_tb\n");
  return EXIT_SUCCESS;
}
