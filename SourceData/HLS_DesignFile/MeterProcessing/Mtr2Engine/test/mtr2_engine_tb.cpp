#include <cstdio>
#include <vector>

#include "mtr2_engine.hpp"

// C testbench for hls_mtr2_engine -- the engine's primary bench.
//
// The twelve scenarios T1..T12 and their expected header/counter values
// originate from the retired RTL engine's unit test (git history:
// tb/meter_cycle_aggregator_tb.sv); the golden arithmetic is an
// independent binary-search floor square root, deliberately a different
// algorithm than the engine's restoring root. Because results are only
// observable as emitted MTR2-v2 records, expectations are checked in
// stream order after the full stimulus has been driven; "no aggregate may
// appear here" assertions from the RTL bench become exact-count plus
// first-sequence checks. The one intentional difference: the CH7 input
// lane carries junk to prove the engine ignores it (the RTL bench drove
// zeros there; the record's CH7 lane must be zero).
//
// Since the record-output revision every emitted aggregate is framing-
// checked (exactly MREC_WORDS beats, TLAST on the last, full TKEEP/TSTRB)
// and compared word-for-word: envelope, shape, folded sequence range,
// micro-unit RMS lanes (Q16 >> 16), frequency mean, and the diagnostic
// counters in words 33..35.
//
// The same source runs in C simulation and in C/RTL co-simulation, so a
// cosim pass certifies the generated RTL against exactly this contract.

namespace {

struct expected_aggregate_t {
  const char *label;
  ap_uint<32> sequence;
  ap_uint<32> generation;
  ap_uint<32> sample_rate;
  ap_uint<32> samples;
  ap_uint<8> valid_mask;
  ap_uint<8> nominal;
  ap_uint<16> cycles;
  ap_uint<1> arithmetic;
  ap_uint<1> freq_valid;
  ap_uint<32> first_seq;
  ap_uint<32> last_seq;
  ap_uint<32> freq_millihz;
  ap_uint<64> first_sample;
  ap_uint<64> rms[8];  // Q16 domain; the record carries rms >> 16
  ap_uint<32> reset_count;
  ap_uint<32> ineligible_count;
  ap_uint<32> continuity_count;
};

// Driver state mirroring the SV bench globals.
ap_uint<32> next_seq = 1;
ap_uint<64> next_first = 1000;
ap_uint<32> b_rate = 128000;
ap_uint<1> apply_level = 0;
int beats_sent = 0;

hls::stream<basic_result_beat_t> s_basic("s_basic");
hls::stream<record_axis_t> m_axis("m_axis");

// One Basic result event; rms_ch applies to CH0..CH6, CH7 carries junk.
void send_basic(const ap_uint<64> rms_ch[MET_ACTIVE_CHANNELS],
                ap_uint<32> generation, int nominal, ap_uint<32> sample_count,
                ap_uint<3> flags, ap_uint<32> freq_millihz, bool freq_valid,
                bool chain_first = true) {
  basic_result_t r;
  r.sequence = next_seq;
  r.generation = generation;
  r.sample_rate_hz = b_rate;
  r.sample_count = sample_count;
  r.valid_mask = 0x7f;
  r.flags = flags;
  r.cycle_count = (nominal == 50) ? ap_uint<8>(MET_GRID_CYCLES_50HZ)
                                  : ap_uint<8>(MET_GRID_CYCLES_60HZ);
  r.nominal_hz = nominal;
  r.status = 0;
  r.frequency_millihz = freq_millihz;
  r.frequency_valid = freq_valid ? 1 : 0;
  r.apply_toggle = apply_level;
  r.first_sample = next_first;
  for (int channel = 0; channel < MET_ACTIVE_CHANNELS; ++channel) {
    r.rms_q16[channel] = ap_int<64>(rms_ch[channel]);
  }
  // Junk in the unused CH7 lane: the engine must ignore it.
  r.rms_q16[7] = ap_int<64>(ap_uint<64>(0xDEADBEEFCAFEF00DULL));

  s_basic.write(pack_basic_result(r));
  beats_sent += 1;
  next_seq += 1;
  if (chain_first) {
    next_first += ap_uint<64>(sample_count);
  }
}

// Golden RMS aggregate: floor(sqrt(floor(sum(v_i^2)/15))) via the SV
// bench's binary-search root -- independent of the DUT's digit recurrence.
ap_uint<64> golden_rms(const ap_uint<64> values[MET_BASIC_BLOCKS_PER_AGGREGATE]) {
  ap_uint<132> acc = 0;
  for (int i = 0; i < MET_BASIC_BLOCKS_PER_AGGREGATE; ++i) {
    acc += ap_uint<132>(ap_uint<128>(values[i]) * values[i]);
  }
  const ap_uint<132> mean = acc / MET_BASIC_BLOCKS_PER_AGGREGATE;
  const ap_uint<128> radicand = mean.range(127, 0);
  ap_uint<64> low = 0;
  ap_uint<64> high = ~ap_uint<64>(0);
  for (int i = 0; i < 64; ++i) {
    const ap_uint<65> mid_sum = ap_uint<65>(low) + ap_uint<65>(high) + 1;
    const ap_uint<64> mid = mid_sum.range(64, 1);
    const ap_uint<128> square = ap_uint<128>(mid) * mid;
    if (square <= radicand) {
      low = mid;
    } else {
      high = mid - 1;
    }
  }
  return low;
}

int check_record(const ap_uint<32> word[MREC_WORDS],
                 const expected_aggregate_t &expected) {
  int errors = 0;
#define CHECK_WORD(name, index, want)                                         \
  do {                                                                        \
    const ap_uint<32> want_value = (want);                                    \
    if (word[(index)] != want_value) {                                        \
      std::printf("FAIL %s: %s (word %d) = 0x%08lx, expected 0x%08lx\n",      \
                  expected.label, name, (int)(index),                         \
                  (unsigned long)word[(index)].to_uint(),                     \
                  (unsigned long)want_value.to_uint());                       \
      errors += 1;                                                            \
    }                                                                         \
  } while (0)

  CHECK_WORD("magic", MREC_MAGIC_WORD, ap_uint<32>(MREC_MAGIC));
  CHECK_WORD("format", MREC_FORMAT_WORD, ap_uint<32>(MREC_FORMAT_MTR2_V2));
  CHECK_WORD("size", MREC_SIZE_WORD, ap_uint<32>(MREC_BYTES));
  CHECK_WORD("sequence", MREC_SEQUENCE_WORD, expected.sequence);
  CHECK_WORD("generation", MREC_GENERATION_WORD, expected.generation);
  CHECK_WORD("sample_rate", MREC_SAMPLE_RATE_WORD, expected.sample_rate);
  CHECK_WORD("samples", MREC_SAMPLE_COUNT_WORD, expected.samples);
  CHECK_WORD("valid_mask", MREC_VALID_MASK_WORD,
             ap_uint<32>(expected.valid_mask));
  CHECK_WORD("status", MREC_STATUS_WORD,
             (ap_uint<32>(expected.arithmetic) << MREC_STATUS_ARITHMETIC_BIT) |
                 (ap_uint<32>(1) << MTR2_STATUS_COMPLETE_BIT) |
                 (ap_uint<32>(expected.freq_valid) << MTR2_STATUS_FREQUENCY_BIT));
  CHECK_WORD("first_sample_low", MREC_FIRST_SAMPLE_LOW_WORD,
             ap_uint<32>(expected.first_sample.range(31, 0)));
  CHECK_WORD("first_sample_high", MREC_FIRST_SAMPLE_HIGH_WORD,
             ap_uint<32>(expected.first_sample.range(63, 32)));
  CHECK_WORD("emit_drops", MREC_EMIT_DROPS_WORD, ap_uint<32>(0));
  CHECK_WORD("result_drops", MREC_RESULT_DROPS_WORD, ap_uint<32>(0));
  CHECK_WORD("shape", MTR2_SHAPE_WORD,
             (ap_uint<32>(MET_BASIC_BLOCKS_PER_AGGREGATE)
              << MTR2_SHAPE_BLOCKS_LSB) |
                 (ap_uint<32>(expected.nominal) << MTR2_SHAPE_NOMINAL_LSB) |
                 (ap_uint<32>(expected.cycles) << MTR2_SHAPE_CYCLES_LSB));
  CHECK_WORD("first_seq", MTR2_FIRST_BASIC_SEQ_WORD, expected.first_seq);
  CHECK_WORD("last_seq", MTR2_LAST_BASIC_SEQ_WORD, expected.last_seq);
  for (int channel = 0; channel < MET_CHANNEL_LANES; ++channel) {
    char lane_name[24];
    const ap_uint<64> units = expected.rms[channel] >> 16;
    const int base = MTR2_CH_BASE_WORD + channel * MTR2_CH_STRIDE_WORDS;
    std::snprintf(lane_name, sizeof lane_name, "rms[%d].low", channel);
    CHECK_WORD(lane_name, base + 0, ap_uint<32>(units.range(31, 0)));
    std::snprintf(lane_name, sizeof lane_name, "rms[%d].high", channel);
    CHECK_WORD(lane_name, base + 1, ap_uint<32>(units.range(63, 32)));
  }
  CHECK_WORD("freq_millihz", MTR2_FREQUENCY_WORD, expected.freq_millihz);
  CHECK_WORD("reset_count", MTR2_RESET_COUNT_WORD, expected.reset_count);
  CHECK_WORD("ineligible_count", MTR2_INELIGIBLE_COUNT_WORD,
             expected.ineligible_count);
  CHECK_WORD("continuity_count", MTR2_CONTINUITY_COUNT_WORD,
             expected.continuity_count);
  for (int reserved = MTR2_CONTINUITY_COUNT_WORD + 1; reserved < MREC_WORDS;
       ++reserved) {
    CHECK_WORD("reserved", reserved, ap_uint<32>(0));
  }
#undef CHECK_WORD
  return errors;
}

const ap_uint<3> FLAGS_LOCKED = 0x1;    // locked, no fallback, not first
const ap_uint<3> FLAGS_FALLBACK = 0x2;  // free-run fallback: ineligible

}  // namespace

int main() {
  std::vector<expected_aggregate_t> expected;
  ap_uint<64> rms_in[MET_ACTIVE_CHANNELS];
  ap_uint<64> series[MET_BASIC_BLOCKS_PER_AGGREGATE];

  // Fills every non-counter expectation with this scenario's constants;
  // per-test code overrides the fields under test afterwards.
  auto base_expectation = [&](const char *label, ap_uint<32> generation,
                              int nominal, ap_uint<32> freq_millihz) {
    expected_aggregate_t e = {};
    e.label = label;
    e.sequence = ap_uint<32>(expected.size() + 1);
    e.generation = generation;
    e.sample_rate = b_rate;
    e.samples = 15 * 25600;
    e.valid_mask = 0x7f;
    e.nominal = nominal;
    e.cycles = (nominal == 50) ? 150 : 180;
    e.arithmetic = 0;
    e.freq_valid = 1;
    e.first_seq = next_seq;
    e.last_seq = next_seq + 14;
    e.freq_millihz = freq_millihz;
    e.first_sample = next_first;
    for (int channel = 0; channel < MET_ACTIVE_CHANNELS; ++channel) {
      e.rms[channel] = rms_in[channel];
    }
    e.rms[7] = 0;
    e.reset_count = expected.empty() ? ap_uint<32>(0)
                                     : expected.back().reset_count;
    e.ineligible_count = expected.empty() ? ap_uint<32>(0)
                                          : expected.back().ineligible_count;
    e.continuity_count = expected.empty() ? ap_uint<32>(0)
                                          : expected.back().continuity_count;
    return e;
  };

  // ---- T1: constant 60 Hz inputs -> aggregate equals the input ----------
  for (int c = 0; c < MET_ACTIVE_CHANNELS; ++c) {
    rms_in[c] = ap_uint<64>((c + 1) * 1000) << 16;
  }
  expected.push_back(base_expectation("T1", 7, 60, 60000));
  for (int b = 0; b < 15; ++b) {
    send_basic(rms_in, 7, 60, 25600, FLAGS_LOCKED, 60000, true);
  }

  // ---- T2: varying 50 Hz inputs with varying sample counts --------------
  {
    expected_aggregate_t e = base_expectation("T2", 8, 50, 0);
    ap_uint<64> freq_sum = 0;
    ap_uint<32> total = 0;
    for (int b = 0; b < 15; ++b) {
      freq_sum += ap_uint<64>(49990 + b);
      total += ap_uint<32>(25600 + b);
    }
    e.freq_millihz = ap_uint<32>(freq_sum / 15);
    e.samples = total;
    for (int b = 0; b < 15; ++b) {
      series[b] = ap_uint<64>((b + 1) * 1000) << 16;
    }
    e.rms[0] = golden_rms(series);
    for (int c = 1; c < MET_ACTIVE_CHANNELS; ++c) {
      e.rms[c] = ap_uint<64>(5000) << 16;
    }
    expected.push_back(e);
  }
  for (int b = 0; b < 15; ++b) {
    for (int c = 0; c < MET_ACTIVE_CHANNELS; ++c) {
      rms_in[c] = ap_uint<64>(5000) << 16;
    }
    rms_in[0] = ap_uint<64>((b + 1) * 1000) << 16;
    send_basic(rms_in, 8, 50, 25600 + b, FLAGS_LOCKED, 49990 + b, true);
  }

  // ---- T3: fallback input invalidates the running set -------------------
  for (int c = 0; c < MET_ACTIVE_CHANNELS; ++c) {
    rms_in[c] = ap_uint<64>(2000) << 16;
  }
  for (int b = 0; b < 7; ++b) {
    send_basic(rms_in, 9, 60, 25600, FLAGS_LOCKED, 60000, true);
  }
  // Fallback block: eligible=false, must reset and never seed.
  send_basic(rms_in, 9, 60, 25600, FLAGS_FALLBACK, 60000, true);
  {
    expected_aggregate_t e = base_expectation("T3", 9, 60, 60000);
    e.reset_count = e.reset_count + 1;         // partial reset by fallback
    e.ineligible_count = e.ineligible_count + 1;
    expected.push_back(e);
  }
  for (int b = 0; b < 15; ++b) {
    send_basic(rms_in, 9, 60, 25600, FLAGS_LOCKED, 60000, true);
  }

  // ---- T4: generation change mid-aggregate resets and reseeds -----------
  for (int b = 0; b < 8; ++b) {
    send_basic(rms_in, 10, 60, 25600, FLAGS_LOCKED, 60000, true);
  }
  {
    expected_aggregate_t e = base_expectation("T4", 11, 60, 60000);
    e.reset_count = e.reset_count + 1;
    expected.push_back(e);
  }
  for (int b = 0; b < 15; ++b) {
    send_basic(rms_in, 11, 60, 25600, FLAGS_LOCKED, 60000, true);
  }

  // ---- T5: nominal change mid-aggregate resets and reseeds --------------
  for (int b = 0; b < 8; ++b) {
    send_basic(rms_in, 12, 60, 25600, FLAGS_LOCKED, 60000, true);
  }
  {
    expected_aggregate_t e = base_expectation("T5", 12, 50, 50000);
    e.reset_count = e.reset_count + 1;
    expected.push_back(e);
  }
  for (int b = 0; b < 15; ++b) {
    send_basic(rms_in, 12, 50, 25600, FLAGS_LOCKED, 50000, true);
  }

  // ---- T6: sample discontinuity resets and reseeds -----------------------
  for (int b = 0; b < 8; ++b) {
    send_basic(rms_in, 13, 60, 25600, FLAGS_LOCKED, 60000, true);
  }
  next_first += 100;  // break the sample chain
  {
    expected_aggregate_t e = base_expectation("T6", 13, 60, 60000);
    e.reset_count = e.reset_count + 1;
    e.continuity_count = e.continuity_count + 1;
    expected.push_back(e);
  }
  for (int b = 0; b < 15; ++b) {
    send_basic(rms_in, 13, 60, 25600, FLAGS_LOCKED, 60000, true);
  }

  // ---- T7: APPLY terminates the partial aggregate ------------------------
  for (int b = 0; b < 8; ++b) {
    send_basic(rms_in, 14, 60, 25600, FLAGS_LOCKED, 60000, true);
  }
  apply_level = ~apply_level;  // APPLY between Basic results
  {
    expected_aggregate_t e = base_expectation("T7", 14, 60, 60000);
    e.reset_count = e.reset_count + 1;
    expected.push_back(e);
  }
  for (int b = 0; b < 15; ++b) {
    send_basic(rms_in, 14, 60, 25600, FLAGS_LOCKED, 60000, true);
  }

  // ---- T8: maximum-magnitude inputs cannot overflow -----------------------
  for (int c = 0; c < MET_ACTIVE_CHANNELS; ++c) {
    rms_in[c] = ap_uint<64>(0x7fffffffffffffffULL);
  }
  expected.push_back(base_expectation("T8", 15, 60, 60000));
  for (int b = 0; b < 15; ++b) {
    send_basic(rms_in, 15, 60, 25600, FLAGS_LOCKED, 60000, true);
  }

  // ---- T9: one invalid frequency input invalidates the mean --------------
  for (int c = 0; c < MET_ACTIVE_CHANNELS; ++c) {
    rms_in[c] = ap_uint<64>(3000) << 16;
  }
  {
    expected_aggregate_t e = base_expectation("T9", 16, 60, 0);
    e.freq_valid = 0;
    expected.push_back(e);
  }
  for (int b = 0; b < 15; ++b) {
    send_basic(rms_in, 16, 60, 25600, FLAGS_LOCKED, 60000, b != 7);
  }

  // ---- T10: Basic sequence gap resets, gapped block reseeds --------------
  for (int c = 0; c < MET_ACTIVE_CHANNELS; ++c) {
    rms_in[c] = ap_uint<64>(4000) << 16;
  }
  for (int b = 0; b < 8; ++b) {
    send_basic(rms_in, 17, 60, 25600, FLAGS_LOCKED, 60000, true);
  }
  next_seq += 1;  // lose one Basic result event; sample chain stays intact
  {
    expected_aggregate_t e = base_expectation("T10", 17, 60, 60000);
    e.reset_count = e.reset_count + 1;
    e.continuity_count = e.continuity_count + 1;
    expected.push_back(e);
  }
  for (int b = 0; b < 15; ++b) {
    send_basic(rms_in, 17, 60, 25600, FLAGS_LOCKED, 60000, true);
  }

  // ---- T11: uint32 sequence wrap stays consecutive ------------------------
  // 0xFFFFFFF8 .. 0x00000006 is 15 consecutive blocks modulo 2**32. The
  // jump itself lands on an empty aggregate, so no reset is counted.
  next_seq = 0xFFFFFFF8;
  expected.push_back(base_expectation("T11", 18, 60, 60000));
  for (int b = 0; b < 15; ++b) {
    send_basic(rms_in, 18, 60, 25600, FLAGS_LOCKED, 60000, true);
  }

  // ---- T12: sample-rate change mid-aggregate resets and reseeds ----------
  for (int b = 0; b < 8; ++b) {
    send_basic(rms_in, 19, 60, 25600, FLAGS_LOCKED, 60000, true);
  }
  b_rate = 32000;
  {
    expected_aggregate_t e = base_expectation("T12", 19, 60, 60000);
    e.reset_count = e.reset_count + 1;  // not a continuity error
    expected.push_back(e);
  }
  for (int b = 0; b < 15; ++b) {
    send_basic(rms_in, 19, 60, 25600, FLAGS_LOCKED, 60000, true);
  }

  // ---- Run the engine over the whole stimulus ----------------------------
  for (int call = 0; call < beats_sent; ++call) {
    hls_mtr2_engine(s_basic, m_axis);
  }

  // ---- Collect and check every record in stream order --------------------
  int errors = 0;
  std::size_t matched = 0;
  ap_uint<32> word[MREC_WORDS];
  int beat_index = 0;
  while (!m_axis.empty()) {
    const record_axis_t beat = m_axis.read();
    if (beat.keep != MREC_KEEP_ALL || beat.strb != MREC_KEEP_ALL) {
      std::printf("FAIL: beat %d keep/strb not full\n", beat_index);
      errors += 1;
    }
    if (beat_index < MREC_WORDS) {
      word[beat_index] = beat.data;
    }
    const bool expect_last = (beat_index == MREC_WORDS - 1);
    if ((beat.last == 1) != expect_last) {
      std::printf("FAIL: TLAST at beat %d\n", beat_index);
      errors += 1;
      break;
    }
    if (expect_last) {
      if (matched < expected.size()) {
        errors += check_record(word, expected[matched]);
      } else {
        std::printf("FAIL: unexpected extra record emitted\n");
        errors += 1;
      }
      matched += 1;
      beat_index = 0;
    } else {
      beat_index += 1;
    }
  }
  if (beat_index != 0) {
    std::printf("FAIL: trailing partial record (%d beats)\n", beat_index);
    errors += 1;
  }
  if (matched < expected.size()) {
    std::printf("FAIL: %s: record never emitted\n",
                expected[matched].label);
    errors += 1;
  }
  if (!s_basic.empty()) {
    std::printf("FAIL: engine did not consume every Basic result\n");
    errors += 1;
  }

  if (errors != 0) {
    std::printf("FAIL: mtr2_engine_tb, %d error(s)\n", errors);
    return 1;
  }
  std::printf("PASS: mtr2_engine_tb (%zu records)\n", matched);
  return 0;
}
