#include <cstdio>
#include <vector>

#include "cycle_aggregator.hpp"

// C testbench for hls_cycle_aggregator.
//
// This is a port of the RTL unit test
// (SourceData/DesignFile/MeterProcessing/tb/meter_cycle_aggregator_tb.sv):
// the same twelve scenarios T1..T12, the same golden arithmetic
// (an independent binary-search floor square root, exactly the SV bench's
// algorithm), and the same expected header/counter values. Because results
// are only observable as output beats, expectations are checked in stream
// order after the full stimulus has been driven; "no aggregate may appear
// here" assertions from the RTL bench become exact-count plus
// first-sequence checks. The one intentional difference: the CH7 input
// lane carries junk to prove the engine ignores it (the RTL bench drives
// zeros there; both engines must emit a zero CH7 lane).
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
  ap_uint<64> rms[8];
  ap_uint<32> record_count;
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

hls::stream<basic_beat_t> s_basic("s_basic");
hls::stream<aggregate_beat_t> m_aggregate("m_aggregate");

// One Basic result event; rms_ch applies to CH0..CH6, CH7 carries junk.
void send_basic(const ap_uint<64> rms_ch[CAGG_CHANNELS],
                ap_uint<32> generation, int nominal, ap_uint<32> sample_count,
                ap_uint<3> flags, ap_uint<32> freq_millihz, bool freq_valid,
                bool chain_first = true) {
  basic_beat_t beat = 0;
  beat.range(CAGG_IN_SEQUENCE_LSB + 31, CAGG_IN_SEQUENCE_LSB) = next_seq;
  beat.range(CAGG_IN_GENERATION_LSB + 31, CAGG_IN_GENERATION_LSB) = generation;
  beat.range(CAGG_IN_SAMPLE_RATE_LSB + 31, CAGG_IN_SAMPLE_RATE_LSB) = b_rate;
  beat.range(CAGG_IN_SAMPLE_COUNT_LSB + 31, CAGG_IN_SAMPLE_COUNT_LSB) =
      sample_count;
  beat.range(CAGG_IN_VALID_MASK_LSB + 7, CAGG_IN_VALID_MASK_LSB) = 0x7f;
  beat.range(CAGG_IN_FLAGS_LSB + 2, CAGG_IN_FLAGS_LSB) = flags;
  beat.range(CAGG_IN_CYCLE_COUNT_LSB + 7, CAGG_IN_CYCLE_COUNT_LSB) =
      (nominal == 50) ? CAGG_CYCLES_50HZ : CAGG_CYCLES_60HZ;
  beat.range(CAGG_IN_NOMINAL_HZ_LSB + 7, CAGG_IN_NOMINAL_HZ_LSB) = nominal;
  beat.range(CAGG_IN_STATUS_LSB + 31, CAGG_IN_STATUS_LSB) = 0;
  beat.range(CAGG_IN_FREQ_LSB + 31, CAGG_IN_FREQ_LSB) = freq_millihz;
  beat.bit(CAGG_IN_FREQ_VALID_BIT) = freq_valid ? 1 : 0;
  beat.bit(CAGG_IN_APPLY_TOGGLE_BIT) = apply_level;
  beat.range(CAGG_IN_FIRST_SAMPLE_LSB + 63, CAGG_IN_FIRST_SAMPLE_LSB) =
      next_first;
  for (int channel = 0; channel < CAGG_CHANNELS; ++channel) {
    beat.range(CAGG_IN_RMS_LSB + channel * 64 + 63,
               CAGG_IN_RMS_LSB + channel * 64) = rms_ch[channel];
  }
  // Junk in the unused CH7 lane: both engines must ignore it.
  beat.range(CAGG_IN_RMS_LSB + 7 * 64 + 63, CAGG_IN_RMS_LSB + 7 * 64) =
      ap_uint<64>(0xDEADBEEFCAFEF00DULL);

  s_basic.write(beat);
  beats_sent += 1;
  next_seq += 1;
  if (chain_first) {
    next_first += ap_uint<64>(sample_count);
  }
}

// Golden RMS aggregate: floor(sqrt(floor(sum(v_i^2)/15))) via the SV
// bench's binary-search root -- independent of the DUT's digit recurrence.
ap_uint<64> golden_rms(const ap_uint<64> values[CAGG_BASIC_BLOCKS]) {
  ap_uint<132> acc = 0;
  for (int i = 0; i < CAGG_BASIC_BLOCKS; ++i) {
    acc += ap_uint<132>(ap_uint<128>(values[i]) * values[i]);
  }
  const ap_uint<132> mean = acc / CAGG_BASIC_BLOCKS;
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

int check_aggregate(const aggregate_beat_t &beat,
                    const expected_aggregate_t &expected) {
  int errors = 0;
// Every compared field fits in 64 bits (RMS lanes exactly, headers less).
#define CHECK_FIELD(name, actual, want)                                       \
  do {                                                                        \
    const ap_uint<64> actual_value = (actual);                                \
    const ap_uint<64> want_value = (want);                                    \
    if (actual_value != want_value) {                                         \
      std::printf("FAIL %s: %s = 0x%016llx, expected 0x%016llx\n",            \
                  expected.label, name,                                       \
                  (unsigned long long)actual_value.to_uint64(),               \
                  (unsigned long long)want_value.to_uint64());                \
      errors += 1;                                                            \
    }                                                                         \
  } while (0)

  CHECK_FIELD("sequence",
              beat.range(CAGG_OUT_SEQUENCE_LSB + 31, CAGG_OUT_SEQUENCE_LSB),
              ap_uint<32>(expected.sequence));
  CHECK_FIELD(
      "generation",
      beat.range(CAGG_OUT_GENERATION_LSB + 31, CAGG_OUT_GENERATION_LSB),
      ap_uint<32>(expected.generation));
  CHECK_FIELD(
      "sample_rate",
      beat.range(CAGG_OUT_SAMPLE_RATE_LSB + 31, CAGG_OUT_SAMPLE_RATE_LSB),
      ap_uint<32>(expected.sample_rate));
  CHECK_FIELD("samples",
              beat.range(CAGG_OUT_SAMPLES_LSB + 31, CAGG_OUT_SAMPLES_LSB),
              ap_uint<32>(expected.samples));
  CHECK_FIELD("valid_mask",
              beat.range(CAGG_OUT_VALID_MASK_LSB + 7, CAGG_OUT_VALID_MASK_LSB),
              ap_uint<8>(expected.valid_mask));
  CHECK_FIELD("nominal",
              beat.range(CAGG_OUT_NOMINAL_HZ_LSB + 7, CAGG_OUT_NOMINAL_HZ_LSB),
              ap_uint<8>(expected.nominal));
  CHECK_FIELD("cycles",
              beat.range(CAGG_OUT_CYCLES_LSB + 15, CAGG_OUT_CYCLES_LSB),
              ap_uint<16>(expected.cycles));
  CHECK_FIELD("arithmetic",
              ap_uint<1>(beat.bit(CAGG_OUT_ARITHMETIC_BIT)),
              ap_uint<1>(expected.arithmetic));
  CHECK_FIELD("freq_valid",
              ap_uint<1>(beat.bit(CAGG_OUT_FREQ_VALID_BIT)),
              ap_uint<1>(expected.freq_valid));
  CHECK_FIELD("first_seq",
              beat.range(CAGG_OUT_FIRST_SEQ_LSB + 31, CAGG_OUT_FIRST_SEQ_LSB),
              ap_uint<32>(expected.first_seq));
  CHECK_FIELD("last_seq",
              beat.range(CAGG_OUT_LAST_SEQ_LSB + 31, CAGG_OUT_LAST_SEQ_LSB),
              ap_uint<32>(expected.last_seq));
  CHECK_FIELD("freq_millihz",
              beat.range(CAGG_OUT_FREQ_LSB + 31, CAGG_OUT_FREQ_LSB),
              ap_uint<32>(expected.freq_millihz));
  CHECK_FIELD(
      "first_sample",
      beat.range(CAGG_OUT_FIRST_SAMPLE_LSB + 63, CAGG_OUT_FIRST_SAMPLE_LSB),
      ap_uint<64>(expected.first_sample));
  for (int channel = 0; channel < 8; ++channel) {
    char lane_name[16];
    std::snprintf(lane_name, sizeof lane_name, "rms[%d]", channel);
    CHECK_FIELD(lane_name,
                beat.range(CAGG_OUT_RMS_LSB + channel * 64 + 63,
                           CAGG_OUT_RMS_LSB + channel * 64),
                ap_uint<64>(expected.rms[channel]));
  }
  CHECK_FIELD(
      "record_count",
      beat.range(CAGG_OUT_RECORD_CNT_LSB + 31, CAGG_OUT_RECORD_CNT_LSB),
      ap_uint<32>(expected.record_count));
  CHECK_FIELD("reset_count",
              beat.range(CAGG_OUT_RESET_CNT_LSB + 31, CAGG_OUT_RESET_CNT_LSB),
              ap_uint<32>(expected.reset_count));
  CHECK_FIELD(
      "ineligible_count",
      beat.range(CAGG_OUT_INELIG_CNT_LSB + 31, CAGG_OUT_INELIG_CNT_LSB),
      ap_uint<32>(expected.ineligible_count));
  CHECK_FIELD("continuity_count",
              beat.range(CAGG_OUT_CONT_CNT_LSB + 31, CAGG_OUT_CONT_CNT_LSB),
              ap_uint<32>(expected.continuity_count));
#undef CHECK_FIELD
  return errors;
}

const ap_uint<3> FLAGS_LOCKED = 0x1;    // locked, no fallback, not first
const ap_uint<3> FLAGS_FALLBACK = 0x2;  // free-run fallback: ineligible

}  // namespace

int main() {
  std::vector<expected_aggregate_t> expected;
  ap_uint<64> rms_in[CAGG_CHANNELS];
  ap_uint<64> series[CAGG_BASIC_BLOCKS];

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
    for (int channel = 0; channel < CAGG_CHANNELS; ++channel) {
      e.rms[channel] = rms_in[channel];
    }
    e.rms[7] = 0;
    e.record_count = ap_uint<32>(expected.size() + 1);
    e.reset_count = expected.empty() ? ap_uint<32>(0)
                                     : expected.back().reset_count;
    e.ineligible_count = expected.empty() ? ap_uint<32>(0)
                                          : expected.back().ineligible_count;
    e.continuity_count = expected.empty() ? ap_uint<32>(0)
                                          : expected.back().continuity_count;
    return e;
  };

  // ---- T1: constant 60 Hz inputs -> aggregate equals the input ----------
  for (int c = 0; c < CAGG_CHANNELS; ++c) {
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
    for (int c = 1; c < CAGG_CHANNELS; ++c) {
      e.rms[c] = ap_uint<64>(5000) << 16;
    }
    expected.push_back(e);
  }
  for (int b = 0; b < 15; ++b) {
    for (int c = 0; c < CAGG_CHANNELS; ++c) {
      rms_in[c] = ap_uint<64>(5000) << 16;
    }
    rms_in[0] = ap_uint<64>((b + 1) * 1000) << 16;
    send_basic(rms_in, 8, 50, 25600 + b, FLAGS_LOCKED, 49990 + b, true);
  }

  // ---- T3: fallback input invalidates the running set -------------------
  for (int c = 0; c < CAGG_CHANNELS; ++c) {
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
  for (int c = 0; c < CAGG_CHANNELS; ++c) {
    rms_in[c] = ap_uint<64>(0x7fffffffffffffffULL);
  }
  expected.push_back(base_expectation("T8", 15, 60, 60000));
  for (int b = 0; b < 15; ++b) {
    send_basic(rms_in, 15, 60, 25600, FLAGS_LOCKED, 60000, true);
  }

  // ---- T9: one invalid frequency input invalidates the mean --------------
  for (int c = 0; c < CAGG_CHANNELS; ++c) {
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
  for (int c = 0; c < CAGG_CHANNELS; ++c) {
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
    hls_cycle_aggregator(s_basic, m_aggregate);
  }

  // ---- Check every aggregate in stream order -----------------------------
  int errors = 0;
  for (std::size_t i = 0; i < expected.size(); ++i) {
    if (m_aggregate.empty()) {
      std::printf("FAIL %s: aggregate never emitted\n", expected[i].label);
      errors += 1;
      break;
    }
    const aggregate_beat_t beat = m_aggregate.read();
    errors += check_aggregate(beat, expected[i]);
  }
  while (!m_aggregate.empty()) {
    m_aggregate.read();
    std::printf("FAIL: unexpected extra aggregate emitted\n");
    errors += 1;
  }
  if (!s_basic.empty()) {
    std::printf("FAIL: engine did not consume every Basic result\n");
    errors += 1;
  }

  if (errors != 0) {
    std::printf("FAIL: cycle_aggregator_tb, %d error(s)\n", errors);
    return 1;
  }
  std::printf("PASS: cycle_aggregator_tb\n");
  return 0;
}
