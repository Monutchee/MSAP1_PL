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

#include "agg_block_result.hpp"
#include "measurement_record.hpp"
#include "metering_types.hpp"
#include "metrology_math.hpp"
#include "metrology_stats.hpp"
#include "metrology_trig.hpp"

// ---------------------------------------------------------------------------
// 1. Compile-time pins.
// ---------------------------------------------------------------------------

// Pin the M11 block-result beat: the accumulator sections must stay
// bit-congruent with the single-cycle beat (agg_block_result.hpp is
// normative; the 150/180 shim mirrors the width).
static_assert(AGGB_SUM_LSB == 512 && AGGB_SQUARE_LSB == 1408 &&
                  AGGB_RAW_SUM_LSB == 2304 && AGGB_RAW_SQUARE_LSB == 2752 &&
                  AGGB_MIN_LSB == 3424 && AGGB_MAX_LSB == 3872 &&
                  AGGB_VLL_SQUARE_LSB == 4320 && AGGB_POWER_SUM_LSB == 4896 &&
                  AGGB_PHASOR_RE_LSB == 5280 && AGGB_PHASOR_IM_LSB == 6176 &&
                  AGGB_BEAT_BITS == 7072,
              "block-result sections must stay congruent with the SCYC beat");

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

static void test_agg_block_round_trip() {
  agg_block_result_t in = unpack_agg_block_result(agg_block_beat_t(0));
  in.sequence = 0xDEADBEEF;
  in.generation = 7;
  in.first_sample = ap_uint<64>(0x123456789ABCDEF0ULL);
  in.last_sample = ap_uint<64>(0x123456789ABD0000ULL);
  in.sample_count = 25600;
  in.sample_rate_hz = 128000;
  in.nominal_hz = 60;
  in.valid_mask = 0x7F;
  in.flags = (1u << MET_FLAG_LOCKED);
  in.cycle_count = MET_GRID_CYCLES_60HZ;
  in.status = 0x5;
  in.frequency_millihz = 59987;
  in.frequency_valid = 1;
  in.apply_toggle = 1;
  in.dc_remove = 1;
  for (int lane = 0; lane < MET_ACTIVE_CHANNELS; ++lane) {
    in.sum[lane] = ap_int<128>(-1234567891234LL) * (lane + 1);
    in.square[lane] = (ap_uint<128>(1) << 96) + lane;
    in.raw_sum[lane] = -1000000LL - lane;
    in.raw_square[lane] = (ap_uint<96>(1) << 80) + lane;
    in.minimum[lane] = -42 - lane;
    in.maximum[lane] = 42 + lane;
    in.phasor_re[lane] = ap_int<128>(1) << (100 + lane % 4);
    in.phasor_im[lane] = -(ap_int<128>(1) << (99 + lane % 4));
  }
  for (int pair = 0; pair < MET_VLL_PAIRS; ++pair)
    in.vll_square[pair] = (ap_uint<128>(3) << 90) + pair;
  for (int phase = 0; phase < MET_POWER_PHASES; ++phase)
    in.power_sum[phase] = -(ap_int<128>(5) << 88) - phase;

  const agg_block_result_t out =
      unpack_agg_block_result(pack_agg_block_result(in));
  CHECK(out.sequence == in.sequence && out.generation == in.generation &&
            out.first_sample == in.first_sample &&
            out.last_sample == in.last_sample &&
            out.sample_count == in.sample_count &&
            out.sample_rate_hz == in.sample_rate_hz &&
            out.nominal_hz == in.nominal_hz &&
            out.valid_mask == in.valid_mask && out.flags == in.flags &&
            out.cycle_count == in.cycle_count && out.status == in.status &&
            out.frequency_millihz == in.frequency_millihz &&
            out.frequency_valid == in.frequency_valid &&
            out.apply_toggle == in.apply_toggle &&
            out.dc_remove == in.dc_remove,
        "block-beat provenance round-trips");
  bool arrays_ok = true;
  for (int lane = 0; lane < MET_ACTIVE_CHANNELS; ++lane)
    arrays_ok = arrays_ok && out.sum[lane] == in.sum[lane] &&
                out.square[lane] == in.square[lane] &&
                out.raw_sum[lane] == in.raw_sum[lane] &&
                out.raw_square[lane] == in.raw_square[lane] &&
                out.minimum[lane] == in.minimum[lane] &&
                out.maximum[lane] == in.maximum[lane] &&
                out.phasor_re[lane] == in.phasor_re[lane] &&
                out.phasor_im[lane] == in.phasor_im[lane];
  for (int pair = 0; pair < MET_VLL_PAIRS; ++pair)
    arrays_ok = arrays_ok && out.vll_square[pair] == in.vll_square[pair];
  for (int phase = 0; phase < MET_POWER_PHASES; ++phase)
    arrays_ok = arrays_ok && out.power_sum[phase] == in.power_sum[phase];
  CHECK(arrays_ok, "block-beat accumulators round-trip");

  // Field independence: one field set, everything else zero.
  agg_block_result_t lone = unpack_agg_block_result(agg_block_beat_t(0));
  lone.frequency_millihz = 0xFFFFFFFF;
  const agg_block_result_t lone_out =
      unpack_agg_block_result(pack_agg_block_result(lone));
  CHECK(lone_out.frequency_millihz == 0xFFFFFFFF &&
            lone_out.sequence == 0 && lone_out.status == 0 &&
            lone_out.first_sample == 0 && lone_out.sum[0] == 0 &&
            lone_out.phasor_im[6] == 0,
        "no block-beat field overlap");
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

  // Regression: valid 10-minute and 2-hour engineering accumulators need a
  // wider finalize numerator even though both stored accumulators fit their
  // existing 128-bit fields.  The old 128-bit square*count intermediate set
  // overflow for both of these ordinary 120 V windows.
  const ap_uint<64> volts_120_q16 = ap_uint<64>(7864320000000ULL);
  const ap_uint<32> long_counts[] = {ap_uint<32>(76799997U),
                                     ap_uint<32>(921599963U)};
  for (const auto &long_count : long_counts) {
    const ap_int<128> long_sum =
        ap_int<128>(volts_120_q16) * ap_int<128>(long_count);
    ap_uint<128> long_square =
        ap_uint<128>(volts_120_q16) * ap_uint<128>(volts_120_q16);
    long_square *= long_count;

    overflow = 0;
    CHECK((met_rms_from_accumulators<128, 128>(
               long_square, long_sum, long_count, 0, overflow) ==
               volts_120_q16 &&
           overflow == 0),
          "long-window total RMS must not report false saturation");

    overflow = 0;
    CHECK((met_rms_from_accumulators<128, 128>(
               long_square, long_sum, long_count, 1, overflow) ==
               ap_uint<64>(0) &&
           overflow == 0),
          "long-window DC correction must retain the full-width numerator");
  }
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
        (long long)(unsigned)met_turns_to_millidegrees(turns);
    long double ref =
        atan2l((long double)v[0], (long double)v[1]) / M_PI * 180000.0L;
    if (ref < 0.0L) ref += 360000.0L;  // publish convention: [0, 360000)
    const long long ref_mdeg = (long long)llroundl(ref) % 360000;
    long long diff = mdeg - ref_mdeg;
    if (diff > 180000) diff -= 360000;
    if (diff < -180000) diff += 360000;
    CHECK(diff >= -1 && diff <= 1, "CORDIC atan2 within one millidegree");
  }
  CHECK((met_atan2_turns(ap_int<64>(0), ap_int<64>(0)) == 0),
        "atan2(0,0) defined as zero");
  // Angle differences wrap modulo one turn: 170 - (-170) = -20 degrees,
  // publishing as 340 in the [0, 360) convention.
  const ap_int<32> a = met_atan2_turns(ap_int<64>(17365), ap_int<64>(-98481));
  const ap_int<32> b = met_atan2_turns(ap_int<64>(-17365), ap_int<64>(-98481));
  const long long wrapped =
      (long long)(unsigned)met_turns_to_millidegrees(ap_int<32>(a - b));
  CHECK(wrapped >= 339998 && wrapped <= 340002,
        "turns subtraction must wrap across the seam");

  // The phasor finalization helpers agree with a plain-integer model.
  const ap_int<64> re = met_phasor_counts(
      ap_int<128>(ap_int<64>(3000000) ) << 37, ap_uint<32>(4));
  CHECK((re == ap_int<64>(750000)), "phasor counts mean + Q1.37 floor");
  const ap_uint<64> rms = met_phasor_rms_q16(ap_int<64>(300000), ap_int<64>(-400000));
  // |(3e5, -4e5)| = 5e5; * 92682 >> 16
  CHECK((rms == ap_uint<64>((500000ULL * 92682ULL) >> 16)),
        "phasor magnitude times sqrt(2)");
}

// Symmetrical-component primitives against libm (independent golden) and
// the documented gating/clamping rules.
static void test_sequence_components() {
  // Rotation accuracy: a and a^2 against long-double rotation at a
  // realistic magnitude; floor quantization allows +/-1 LSB per output.
  const long long re = 549755813888LL / 2;  // 2^39 / ... arbitrary large
  const long long im = -123456789012LL;
  ap_int<64> ar, ai, a2r, a2i;
  met_rotate_a(ap_int<64>(re), ap_int<64>(im), ar, ai);
  met_rotate_a2(ap_int<64>(re), ap_int<64>(im), a2r, a2i);
  // Tolerance: the Q30 sqrt(3)/2 constant sits ~0.31 LSB above the real
  // value, which scales to ~0.31*|p|/2^30 output LSBs (plus the floor)
  // — about 3e-10 relative, invisible at the micro-unit grain. 512
  // covers every contract-legal magnitude.
  const long double c = -0.5L, s = 0.86602540378443864676L;
  CHECK(llabs((long long)ar - llroundl(re * c - im * s)) <= 512 &&
            llabs((long long)ai - llroundl(re * s + im * c)) <= 512,
        "a-operator rotates by +120 degrees");
  CHECK(llabs((long long)a2r - llroundl(re * c + im * s)) <= 512 &&
            llabs((long long)a2i - llroundl(-re * s + im * c)) <= 512,
        "a^2 operator rotates by +240 degrees");

  // Balanced ABC triple: everything lands in the positive sequence.
  // Construct b = a^2 * a_phasor, c = a * a_phasor exactly through the
  // same fixed-point operators so the residuals stay at the LSB level.
  ap_int<64> pre[3], pim[3], sre[3], sim[3];
  pre[0] = 400000000000LL;
  pim[0] = -250000000000LL;
  met_rotate_a2(pre[0], pim[0], pre[1], pim[1]);  // B lags A by 120
  met_rotate_a(pre[0], pim[0], pre[2], pim[2]);   // C leads A by 120
  met_sequence_components(pre, pim, sre, sim);
  CHECK(llabs((long long)sre[0]) <= 512 && llabs((long long)sim[0]) <= 512 &&
            llabs((long long)sre[2]) <= 512 && llabs((long long)sim[2]) <= 512,
        "balanced ABC: zero and negative sequences vanish");
  CHECK(llabs((long long)sre[1] - (long long)pre[0]) <= 512 &&
            llabs((long long)sim[1] - (long long)pim[0]) <= 512,
        "balanced ABC: positive sequence equals phase A");

  // Reversed rotation (swap B and C): everything moves to the negative
  // sequence — the M10 acceptance property.
  ap_int<64> rre[3] = {pre[0], pre[2], pre[1]};
  ap_int<64> rim[3] = {pim[0], pim[2], pim[1]};
  met_sequence_components(rre, rim, sre, sim);
  CHECK(llabs((long long)sre[1]) <= 512 && llabs((long long)sim[1]) <= 512,
        "ACB: positive sequence vanishes");
  CHECK(llabs((long long)sre[2] - (long long)pre[0]) <= 512 &&
            llabs((long long)sim[2] - (long long)pim[0]) <= 512,
        "ACB: negative sequence equals phase A");

  CHECK((met_ratio_e6(ap_uint<64>(20000), ap_uint<64>(1000000)) ==
         ap_uint<32>(20000)),
        "ratio: 2 percent reads 20000 millionths");
  CHECK((met_ratio_e6(ap_uint<64>(123), ap_uint<64>(0)) == ap_uint<32>(0)),
        "ratio: zero denominator is undefined-as-0");
  CHECK((met_ratio_e6(ap_uint<64>(1) << 60, ap_uint<64>(1)) ==
         ap_uint<32>(0xFFFFFFFFu)),
        "ratio: clamps at the u32 rail");
}

int main() {
  test_agg_block_round_trip();
  test_serialize_record_framing();
  test_metrology_primitives();
  test_cordic_atan2();
  test_sequence_components();
  if (failures) {
    std::printf("common_headers_test: %d FAILURE(S)\n", failures);
    return EXIT_FAILURE;
  }
  std::printf("common_headers_test: PASS\n");
  return EXIT_SUCCESS;
}
