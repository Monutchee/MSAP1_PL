// Unit test for the common HLS headers. Plain C++ (g++ + the Vitis
// include tree, csim style) — no HLS tool run needed. Checks three
// things:
//
//   1. Layout pins: the basic-result beat here is byte-identical to the
//      CycleAggregator's local CAGG_IN_* definition it will replace, so
//      the two cannot drift apart during the migration window.
//   2. pack/unpack round-trips every field, including negative Q16 lanes.
//   3. serialize_record obeys the DMA framing invariant: exactly 64
//      beats, TKEEP full on all, TLAST on beat 63 only, envelope words
//      stamped even when the builder wrote garbage over them.

#include <cmath>
#include <cstdio>
#include <cstdlib>

#include "basic_result_beat.hpp"
#include "measurement_record.hpp"
#include "metering_types.hpp"
#include "metrology_math.hpp"
#include "metrology_stats.hpp"
#include "metrology_trig.hpp"

// ---------------------------------------------------------------------------
// 1. Compile-time pins.
// ---------------------------------------------------------------------------

// Pin the beat layout to the values in CycleAggregator/src/
// cycle_aggregator.hpp (CAGG_IN_*). If either side changes, this file
// stops compiling — update BOTH normative comments, the VHDL shim, and
// the equivalence bench together.
static_assert(BASIC_BEAT_SEQUENCE_LSB == 0, "layout pin");
static_assert(BASIC_BEAT_GENERATION_LSB == 32, "layout pin");
static_assert(BASIC_BEAT_SAMPLE_RATE_LSB == 64, "layout pin");
static_assert(BASIC_BEAT_SAMPLE_COUNT_LSB == 96, "layout pin");
static_assert(BASIC_BEAT_VALID_MASK_LSB == 128, "layout pin");
static_assert(BASIC_BEAT_FLAGS_LSB == 136, "layout pin");
static_assert(BASIC_BEAT_CYCLE_COUNT_LSB == 144, "layout pin");
static_assert(BASIC_BEAT_NOMINAL_HZ_LSB == 152, "layout pin");
static_assert(BASIC_BEAT_STATUS_LSB == 160, "layout pin");
static_assert(BASIC_BEAT_FREQ_LSB == 192, "layout pin");
static_assert(BASIC_BEAT_FREQ_VALID_BIT == 224, "layout pin");
static_assert(BASIC_BEAT_APPLY_TOGGLE_BIT == 225, "layout pin");
static_assert(BASIC_BEAT_FIRST_SAMPLE_LSB == 232, "layout pin");
static_assert(BASIC_BEAT_RMS_LSB == 296, "layout pin");
static_assert(BASIC_BEAT_BITS == 808, "layout pin");
static_assert(BASIC_BEAT_RMS_LSB + MET_RMS_LANES_BITS == BASIC_BEAT_BITS,
              "RMS lanes must end exactly at the beat MSB");

// Record geometry is fixed by the kernel DMA contract.
static_assert(MREC_WORDS == 64 && MREC_BYTES == 256, "DMA framing contract");
static_assert(MREC_WORDS * 4 == MREC_BYTES, "words/bytes coherence");

// Interior maps must stay inside the record and clear of each other.
static_assert(MTR1_CH_BASE_WORD + MET_CHANNEL_LANES * MTR1_CH_STRIDE_WORDS ==
                  MTR1_FREQUENCY_VALUE_WORD,
              "MTR1 channel block must abut the frequency block");
static_assert(MTR1_ADC_ALERTS_WORD == MREC_WORDS - 1, "MTR1 map fills the record");
static_assert(MTR2_CH_BASE_WORD + MET_CHANNEL_LANES * MTR2_CH_STRIDE_WORDS ==
                  MTR2_FREQUENCY_WORD,
              "MTR2 channel block must abut the frequency word");
static_assert(MTR2_CONTINUITY_COUNT_WORD < MREC_WORDS, "MTR2 map in bounds");
static_assert(MREC_FORMAT_HEADER_WORD > MREC_RESULT_DROPS_WORD &&
                  MREC_PAYLOAD_WORD > MREC_FORMAT_HEADER_WORD,
              "envelope / format header / payload ordering");

// ---------------------------------------------------------------------------
// Run-time checks.
// ---------------------------------------------------------------------------
static int failures = 0;

#define CHECK(cond, what)                                        \
  do {                                                           \
    if (!(cond)) {                                               \
      std::printf("FAIL %s:%d  %s\n", __FILE__, __LINE__, what); \
      ++failures;                                                \
    }                                                            \
  } while (0)

static void test_basic_result_round_trip() {
  basic_result_t in;
  in.sequence = 0xDEADBEEF;
  in.generation = 7;
  in.sample_rate_hz = 32000;
  in.sample_count = 6379;             // cycle mode: not the configured window
  in.valid_mask = 0x7F;               // CH0..CH6
  in.flags = (1u << MET_FLAG_LOCKED); // locked, no fallback, not first
  in.cycle_count = MET_GRID_CYCLES_60HZ;
  in.nominal_hz = 60;
  in.status = 0;
  in.frequency_millihz = 59987;
  in.frequency_valid = 1;
  in.apply_toggle = 1;
  in.first_sample = ap_uint<64>(0x123456789ABCDEF0ULL);
  for (int lane = 0; lane < MET_CHANNEL_LANES; ++lane)
    in.rms_q16[lane] = (lane == 3) ? met_q16_t(-1234567891234LL)
                                   : met_q16_t(0x0123456700000000LL + lane);

  const basic_result_t out = unpack_basic_result(pack_basic_result(in));

  CHECK(out.sequence == in.sequence, "sequence");
  CHECK(out.generation == in.generation, "generation");
  CHECK(out.sample_rate_hz == in.sample_rate_hz, "sample_rate");
  CHECK(out.sample_count == in.sample_count, "sample_count");
  CHECK(out.valid_mask == in.valid_mask, "valid_mask");
  CHECK(out.flags == in.flags, "flags");
  CHECK(out.cycle_count == in.cycle_count, "cycle_count");
  CHECK(out.nominal_hz == in.nominal_hz, "nominal_hz");
  CHECK(out.status == in.status, "status");
  CHECK(out.frequency_millihz == in.frequency_millihz, "frequency_millihz");
  CHECK(out.frequency_valid == in.frequency_valid, "frequency_valid");
  CHECK(out.apply_toggle == in.apply_toggle, "apply_toggle");
  CHECK(out.first_sample == in.first_sample, "first_sample");
  for (int lane = 0; lane < MET_CHANNEL_LANES; ++lane)
    CHECK(out.rms_q16[lane] == in.rms_q16[lane], "rms lane");

  // Field independence: a beat with exactly one field set must read back
  // zero everywhere else (catches overlapping ranges). Note ap_uint's
  // default constructor does NOT zero the value, so unpacking an
  // explicitly zero beat is the reliable way to get an all-zero struct.
  basic_result_t lone = unpack_basic_result(basic_result_beat_t(0));
  lone.frequency_millihz = 0xFFFFFFFF;
  const basic_result_t lone_out = unpack_basic_result(pack_basic_result(lone));
  CHECK(lone_out.frequency_millihz == 0xFFFFFFFF, "lone field survives");
  CHECK(lone_out.sequence == 0 && lone_out.status == 0 &&
            lone_out.first_sample == 0 && lone_out.frequency_valid == 0 &&
            lone_out.rms_q16[0] == 0,
        "no field overlap");
}

static void test_serialize_record_framing() {
  record_image_t image;
  clear_record(image);
  for (int w = 0; w < MREC_WORDS; ++w)
    CHECK(image.word[w] == 0, "clear_record zeroes");

  // Deliberately corrupt the envelope words a builder must not own, fill
  // a recognizable payload, then serialize.
  image.word[MREC_MAGIC_WORD] = 0xBADBAD00;
  image.word[MREC_FORMAT_WORD] = 0xBADBAD01;
  image.word[MREC_SIZE_WORD] = 0xBADBAD02;
  image.word[MREC_SEQUENCE_WORD] = 1053;
  image.word[MTR1_TIMING_WORD] =
      (50u << MTR1_TIMING_NOMINAL_LSB) | (10u << MTR1_TIMING_CYCLES_LSB) |
      (1u << (MTR1_TIMING_FLAGS_LSB + MET_FLAG_LOCKED));
  for (int w = MREC_PAYLOAD_WORD; w < MREC_WORDS; ++w)
    image.word[w] = 0xA0000000u + w;

  record_axis_stream_t stream("m_axis");
  serialize_record<0x00010003>(image, stream);

  int beats = 0;
  while (!stream.empty()) {
    const record_axis_t beat = stream.read();
    CHECK(beat.keep == MREC_KEEP_ALL, "TKEEP full on every beat");
    CHECK(beat.last == (beats == MREC_WORDS - 1 ? 1 : 0),
          "TLAST on beat 63 only");
    if (beats == MREC_MAGIC_WORD) CHECK(beat.data == MREC_MAGIC, "magic stamped");
    if (beats == MREC_FORMAT_WORD)
      CHECK(beat.data == MREC_FORMAT_MTR1_V3, "format stamped from template");
    if (beats == MREC_SIZE_WORD) CHECK(beat.data == MREC_BYTES, "size stamped");
    if (beats == MREC_SEQUENCE_WORD) CHECK(beat.data == 1053, "sequence carried");
    if (beats >= MREC_PAYLOAD_WORD)
      CHECK(beat.data == 0xA0000000u + beats, "payload word carried");
    ++beats;
  }
  CHECK(beats == MREC_WORDS, "exactly 64 beats per record");
}

// The shared math/stat primitives against plain integer references:
// floor semantics, the divide-by-15 specialization, saturation, and the
// truncate-before-negate mean order (all normative, see the headers).
static void test_metrology_primitives() {
  static_assert(met_bit_width<29ULL>::value == 5,
                "bit width helper must size the div-15 remainder at 5");

  const unsigned long long vectors[] = {0ULL, 1ULL, 14ULL, 15ULL, 16ULL,
                                        1000ULL, 0xFFFFFFFFFFFFULL};
  for (const auto value : vectors) {
    const ap_uint<64> divided = floor_div_const<64, 15>(ap_uint<64>(value));
    CHECK((divided == ap_uint<64>(value / 15ULL)),
          "floor_div_const<15> must floor-divide exactly");
    const ap_uint<64> generic =
        floor_div<64>(ap_uint<64>(value), ap_uint<64>(15));
    CHECK((divided == generic),
          "constant and generic dividers must agree bit for bit");
  }

  // Saturating square accumulation: carry-out clamps and sets the flag.
  ap_uint<1> sticky = 0;
  const ap_uint<128> near_full = ~ap_uint<128>(0) - 10;
  CHECK((met_add_square_saturating<128>(near_full, ap_uint<128>(5), sticky) ==
             near_full + 5 && sticky == 0),
        "in-range square accumulation must not saturate");
  CHECK((met_add_square_saturating<128>(near_full, ap_uint<128>(50), sticky) ==
             ~ap_uint<128>(0) && sticky == 1),
        "carry-out must clamp to all-ones with the sticky flag");

  // Mean: truncate to the output width BEFORE negation (normative order).
  CHECK((met_floor_mean_signed<128, 64>(ap_int<128>(-7), 2) == ap_int<64>(-3)),
        "negative mean must truncate toward zero");
  CHECK((met_floor_mean_signed<128, 64>(ap_int<128>(7), 2) == ap_int<64>(3)),
        "positive mean must floor");

  // RMS recurrence: a pure-DC window with dc_remove yields zero; without
  // it, the RMS of a constant c over N samples is |c|.
  ap_uint<1> overflow = 0;
  const ap_uint<32> count = 4;
  const ap_int<128> sum = ap_int<128>(4) * 1000;      // four samples of 1000
  const ap_uint<128> square = ap_uint<128>(4) * (1000ULL * 1000ULL);
  CHECK((met_rms_from_accumulators<128, 128>(square, sum, count, 1, overflow) ==
             ap_uint<64>(0) && overflow == 0),
        "constant signal with dc_remove must have zero AC RMS");
  CHECK((met_rms_from_accumulators<128, 128>(square, sum, count, 0, overflow) ==
             ap_uint<64>(1000)),
        "constant signal without dc_remove must report its magnitude");
  CHECK((met_expected_cycles(50) == MET_GRID_CYCLES_50HZ &&
             met_expected_cycles(60) == MET_GRID_CYCLES_60HZ),
        "nominal-to-cycles mapping");
}

// CORDIC atan2 against libm long-double (the independent-golden rule):
// tolerance one millidegree — the algorithmic residual is < 0.001 mdeg,
// so a real defect cannot hide inside the tolerance. Also pins the wrap
// conventions: turns subtraction is modulo one turn, and atan2 of the
// negative real axis is -half turn (the published range excludes +180).
static void test_cordic_atan2() {
  const long long vectors[][2] = {
      // {im, re} — axes, quadrants, extreme scales, near-degenerate.
      {0, 1},        {1, 0},          {0, -1},       {-1, 0},
      {1, 1},        {1, -1},         {-1, -1},      {-1, 1},
      {3, 4},        {-3, 4},         {12345, -678}, {-99999, -12},
      {1LL << 40, 3},{3, 1LL << 40},  {(1LL << 40), -(1LL << 40)},
      {-(1LL << 20), (1LL << 41)},    {7, 9},        {-1000000, 1},
  };
  for (const auto &v : vectors) {
    const ap_int<32> turns =
        met_atan2_turns(ap_int<64>(v[0]), ap_int<64>(v[1]));
    const long long mdeg =
        (long long)ap_int<32>(met_turns_to_millidegrees(turns));
    long double ref =
        atan2l((long double)v[0], (long double)v[1]) / M_PI * 180000.0L;
    if (ref >= 180000.0L - 0.5L) ref -= 360000.0L;  // +180 -> -180
    const long long ref_mdeg = (long long)llroundl(ref);
    long long diff = mdeg - ref_mdeg;
    if (diff > 180000) diff -= 360000;
    if (diff < -180000) diff += 360000;
    CHECK(diff >= -1 && diff <= 1, "CORDIC atan2 within one millidegree");
  }
  CHECK((met_atan2_turns(ap_int<64>(0), ap_int<64>(0)) == 0),
        "atan2(0,0) defined as zero");
  // Angle differences wrap modulo one turn: 170 - (-170) = -20 degrees.
  const ap_int<32> a = met_atan2_turns(ap_int<64>(17365), ap_int<64>(-98481));
  const ap_int<32> b = met_atan2_turns(ap_int<64>(-17365), ap_int<64>(-98481));
  const long long wrapped =
      (long long)ap_int<32>(met_turns_to_millidegrees(ap_int<32>(a - b)));
  CHECK(wrapped >= -20002 && wrapped <= -19998,
        "turns subtraction must wrap across the +/-180 seam");

  // The phasor finalization helpers agree with a plain-integer model.
  const ap_int<64> re = met_phasor_counts(
      ap_int<128>(ap_int<64>(3000000) ) << 37, ap_uint<32>(4));
  CHECK((re == ap_int<64>(750000)), "phasor counts mean + Q1.37 floor");
  const ap_uint<64> rms = met_phasor_rms_q16(ap_int<64>(300000), ap_int<64>(-400000));
  // |(3e5, -4e5)| = 5e5; * 92682 >> 16
  CHECK((rms == ap_uint<64>((500000ULL * 92682ULL) >> 16)),
        "phasor magnitude times sqrt(2)");
}

int main() {
  test_basic_result_round_trip();
  test_serialize_record_framing();
  test_metrology_primitives();
  test_cordic_atan2();
  if (failures) {
    std::printf("common_headers_test: %d FAILURE(S)\n", failures);
    return EXIT_FAILURE;
  }
  std::printf("common_headers_test: PASS\n");
  return EXIT_SUCCESS;
}
