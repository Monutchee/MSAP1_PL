#include "mtr1_engine.hpp"

#include "mtr_math.hpp"

// MTR1 basic measurement engine. Contract, beat layout, and accepted
// divergences: see mtr1_engine.hpp.
//
// Structure: one free-running single-shot process (the CycleAggregator
// pattern, proven through C/RTL co-simulation and hardware): each
// invocation consumes at most one sample beat; the invocation that
// carries a block close runs the whole finalize + record emission inline.
// During those ~15 us the engine does not accept beats, so the VHDL shim
// in front buffers incoming frames (an 8-deep beat FIFO covers the
// worst-case finalize even at the capture path's 128 kSPS ceiling) and
// counts a drop if it ever overflows — the same never-backpressure
// arrangement the aggregator shim used, one stage earlier. Consequences:
//   - every closed window is finalized; the RTL's calc-busy window drop
//     has no equivalent, so result_drops (record word 12) is constant 0;
//   - a transport stall parks the serialize loop; sample beats then queue
//     in the shim FIFO, and sustained backpressure surfaces as counted
//     shim drops, never as a stall of measurement.
//
// An earlier two-process DATAFLOW revision decoupled accumulation from
// finalization but deadlocked ap_ctrl_none co-simulation (wedged at the
// same drop-stress window at snapshot depths 1 and 2); the single-shot
// form is the one this project has hardware hours on.
//
// Arithmetic is shaped for area, not latency (the CycleAggregator trial
// lesson): the per-lane loops are serial (PIPELINE off) so the wide
// adders, multipliers, divider, and root exist once each; a full
// finalize measures ~200 cycles per lane (csynth), ~1.5k cycles ~ 15 us
// per record against a ~200 ms block cadence.

namespace {

// One lane's finalized results.
struct lane_result_t {
  ap_int<64> mean_q16;
  ap_uint<64> rms_q16;
  ap_uint<32> rms_count;
  ap_uint<1> overflow;
};

// Finalize one lane: mean, converted-domain RMS, raw-count RMS — the
// retired meter_rms CALC_* state sequence as straight-line C.
lane_result_t finalize_lane(const ap_int<128> sum, const ap_uint<128> square,
                            const ap_int<64> raw_sum,
                            const ap_uint<96> raw_square,
                            const ap_uint<32> count,
                            const ap_uint<1> dc_remove) {
#pragma HLS INLINE off
  lane_result_t r;
  r.overflow = 0;

  // Mean: floor(|sum|/N), truncate to 64 bits, then restore the sign
  // (truncation toward zero; the 64-bit truncation precedes negation).
  const bool sum_negative = (sum < 0);
  const ap_uint<128> abs_sum =
      sum_negative ? ap_uint<128>(-sum) : ap_uint<128>(sum);
  const ap_uint<128> mean_q = floor_div<128>(abs_sum, ap_uint<128>(count));
  const ap_uint<64> mean_mag = mean_q.range(63, 0);
  r.mean_q16 =
      sum_negative ? ap_int<64>(-ap_int<64>(mean_mag)) : ap_int<64>(mean_mag);

  // Converted-domain variance and root.
  {
    const ap_uint<160> product = ap_uint<160>(square) * count;
    ap_uint<128> numerator;
    if (product.range(159, 128) != 0) {
      r.overflow = 1;
      numerator = ~ap_uint<128>(0);
    } else {
      numerator = product.range(127, 0);
    }
    if (dc_remove == 1) {
      if (abs_sum.range(127, 64) != 0) {
        // |sum| exceeds 64 bits: the sum-square would truncate (RTL
        // variance_sum_too_wide rule).
        r.overflow = 1;
        numerator = 0;
      } else {
        const ap_uint<128> sum_square =
            ap_uint<128>(abs_sum.range(63, 0)) * abs_sum.range(63, 0);
        if (numerator >= sum_square) {
          numerator -= sum_square;
        } else {
          numerator = 0;
          r.overflow = 1;
        }
      }
    }
    const ap_uint<128> denominator = ap_uint<128>(ap_uint<64>(count) * count);
    r.rms_q16 = floor_sqrt_128(floor_div<128>(numerator, denominator));
  }

  // Raw-count variance and root (same recurrence on the raw accumulators;
  // the 64-bit raw sum can never trip the too-wide rule).
  {
    const ap_uint<160> product = ap_uint<160>(raw_square) * count;
    ap_uint<128> numerator;
    if (product.range(159, 128) != 0) {
      r.overflow = 1;
      numerator = ~ap_uint<128>(0);
    } else {
      numerator = product.range(127, 0);
    }
    if (dc_remove == 1) {
      const ap_uint<64> abs_raw =
          (raw_sum < 0) ? ap_uint<64>(-raw_sum) : ap_uint<64>(raw_sum);
      const ap_uint<128> sum_square = ap_uint<128>(abs_raw) * abs_raw;
      if (numerator >= sum_square) {
        numerator -= sum_square;
      } else {
        numerator = 0;
        r.overflow = 1;
      }
    }
    const ap_uint<128> denominator = ap_uint<128>(ap_uint<64>(count) * count);
    const ap_uint<64> root =
        floor_sqrt_128(floor_div<128>(numerator, denominator));
    r.rms_count = root.range(31, 0);
  }
  return r;
}

}  // namespace

void hls_mtr1_engine(hls::stream<mtr1_sample_beat_t> &s_sample,
                     hls::stream<record_axis_t> &m_axis,
                     hls::stream<basic_result_beat_t> &m_result) {
  // s_sample stays unregistered (a raw HLS axis SLAVE gates TREADY on
  // TVALID, which is AXI-legal, and the shim registers its side). The
  // m_result MASTER must keep its boundary register: a raw HLS axis
  // master gates TVALID on TREADY — illegal AXI — and wired directly to
  // the aggregator's TVALID-gated TREADY it deadlocks the whole engine
  // (found in the record-stream integration bench; the old VHDL shim
  // masked this by being the compliant middleman). m_axis keeps the
  // default boundary register toward the block design for the same
  // reason.
#pragma HLS INTERFACE mode=axis port=s_sample register_mode=off
#pragma HLS INTERFACE mode=axis port=m_result register_mode=both
#pragma HLS INTERFACE mode=axis port=m_axis
#pragma HLS INTERFACE mode=ap_ctrl_none port=return

  // Committed configuration (meter_rms reset defaults) and window state.
  // syn.rtl.reset=state re-zeroes/re-initializes these on aresetn.
  static ap_uint<1> apply_seen = 0;
  static ap_uint<32> active_generation = 0;
  static ap_uint<32> active_sample_rate = 32000;
  static ap_uint<32> active_window_samples = 6400;
  static ap_uint<8> active_valid_mask = 0;
  static ap_uint<1> active_enable = 0;
  static ap_uint<1> active_dc_remove = 1;
  static ap_uint<32> sample_count = 0;
  static ap_uint<1> arithmetic_overflow = 0;  // sticky until APPLY
  static ap_uint<32> sequence = 0;            // first emitted result carries 1
  static ap_uint<32> emit_drops = 0;          // reserved: emission is blocking
  static ap_uint<32> result_drops = 0;        // reserved: every close finalizes

  // One R/W per lane per beat: distributed RAM, not block RAM.
  static ap_int<128> acc_sum[MTR_ACTIVE_CHANNELS];
#pragma HLS BIND_STORAGE variable=acc_sum type=ram_s2p impl=lutram
  static ap_uint<128> acc_square[MTR_ACTIVE_CHANNELS];
#pragma HLS BIND_STORAGE variable=acc_square type=ram_s2p impl=lutram
  static ap_int<64> acc_raw_sum[MTR_ACTIVE_CHANNELS];
#pragma HLS BIND_STORAGE variable=acc_raw_sum type=ram_s2p impl=lutram
  static ap_uint<96> acc_raw_square[MTR_ACTIVE_CHANNELS];
#pragma HLS BIND_STORAGE variable=acc_raw_square type=ram_s2p impl=lutram

  if (s_sample.empty()) {
    return;
  }
  const mtr1_sample_beat_t beat = s_sample.read();

  const ap_uint<1> beat_apply = beat.bit(MTR1_IN_APPLY_BIT);

  // APPLY commit: latch the shadow configuration carried by this beat and
  // clear the window and the sticky flag. The carrying beat's frame is
  // then processed under the NEW configuration: grid_cycle_timing counts
  // every accepted frame, so discarding the carrier would skew the first
  // post-APPLY block by one frame against the grid's block accounting
  // (caught by the MeterCore integration bench). A frame whose generation
  // tag has not caught up yet is rejected by the stale-generation guard
  // below, exactly as any other stale frame.
  if (beat_apply != apply_seen) {
    apply_seen = beat_apply;
    active_generation =
        beat.range(MTR1_IN_CFG_GEN_LSB + 31, MTR1_IN_CFG_GEN_LSB);
    active_sample_rate =
        beat.range(MTR1_IN_CFG_RATE_LSB + 31, MTR1_IN_CFG_RATE_LSB);
    active_window_samples =
        beat.range(MTR1_IN_CFG_WINDOW_LSB + 31, MTR1_IN_CFG_WINDOW_LSB);
    active_valid_mask =
        beat.range(MTR1_IN_CFG_MASK_LSB + 7, MTR1_IN_CFG_MASK_LSB);
    active_enable = beat.bit(MTR1_IN_ENABLE_BIT);
    active_dc_remove = beat.bit(MTR1_IN_DC_REMOVE_BIT);
    sample_count = 0;
    arithmetic_overflow = 0;
  }

  if (active_enable == 0) {
    return;
  }

  const ap_uint<32> frame_generation =
      beat.range(MTR1_IN_FRAME_GEN_LSB + 31, MTR1_IN_FRAME_GEN_LSB);

  // Defensive clear: a malformed or stale-generation frame invalidates the
  // running window so one result can never mix configurations (RTL rule).
  if (beat.bit(MTR1_IN_MALFORMED_BIT) == 1 ||
      frame_generation != active_generation) {
    sample_count = 0;
    return;
  }

  const bool first_frame = (sample_count == 0);
accumulate_lanes:
  for (int lane = 0; lane < MTR_ACTIVE_CHANNELS; ++lane) {
#pragma HLS PIPELINE off
    const ap_int<64> sample = ap_int<64>(ap_uint<64>(
        beat.range(MTR1_IN_SAMPLES_LSB + lane * 64 + 63,
                   MTR1_IN_SAMPLES_LSB + lane * 64)));
    const ap_int<32> raw = ap_int<32>(ap_uint<32>(
        beat.range(MTR1_IN_RAW_LSB + lane * 32 + 31,
                   MTR1_IN_RAW_LSB + lane * 32)));

    const ap_int<128> sum_base = first_frame ? ap_int<128>(0) : acc_sum[lane];
    acc_sum[lane] = sum_base + sample;

    // Saturating square accumulation with the sticky flag (RTL rule).
    const ap_uint<128> square = ap_uint<128>(sample * sample);
    const ap_uint<128> square_base =
        first_frame ? ap_uint<128>(0) : acc_square[lane];
    const ap_uint<129> square_extended =
        ap_uint<129>(square_base) + ap_uint<129>(square);
    if (square_extended.bit(128) == 1) {
      acc_square[lane] = ~ap_uint<128>(0);
      arithmetic_overflow = 1;
    } else {
      acc_square[lane] = square_extended.range(127, 0);
    }

    const ap_int<64> raw_sum_base =
        first_frame ? ap_int<64>(0) : acc_raw_sum[lane];
    acc_raw_sum[lane] = raw_sum_base + raw;
    const ap_uint<96> raw_square_base =
        first_frame ? ap_uint<96>(0) : acc_raw_square[lane];
    acc_raw_square[lane] =
        raw_square_base + ap_uint<96>(ap_uint<64>(raw * raw));
  }
  const ap_uint<32> count_now = sample_count + 1;

  // Window close: the cycle-mode marker travels with this frame; legacy
  // mode closes on the configured count (RTL predicate verbatim).
  const bool closes =
      (beat.bit(MTR1_IN_CYCLE_MODE_BIT) == 1 &&
       beat.bit(MTR1_IN_CLOSES_BIT) == 1) ||
      (beat.bit(MTR1_IN_CYCLE_MODE_BIT) == 0 && active_window_samples != 0 &&
       count_now >= active_window_samples);
  if (!closes) {
    sample_count = count_now;
    return;
  }
  sample_count = 0;

  // ---- Finalize this window inline -----------------------------------
  const ap_uint<8> result_mask =
      (active_valid_mask &
       beat.range(MTR1_IN_FRAME_MASK_LSB + 7, MTR1_IN_FRAME_MASK_LSB)) &
      ap_uint<8>(0x7F);

  // Registers, not RAM: the record/beat packing below reads all lanes.
  ap_int<64> mean_q16[MTR_ACTIVE_CHANNELS];
#pragma HLS ARRAY_PARTITION variable=mean_q16 complete
  ap_uint<64> rms_q16[MTR_ACTIVE_CHANNELS];
#pragma HLS ARRAY_PARTITION variable=rms_q16 complete
  ap_uint<32> rms_count[MTR_ACTIVE_CHANNELS];
#pragma HLS ARRAY_PARTITION variable=rms_count complete

finalize_lanes:
  for (int lane = 0; lane < MTR_ACTIVE_CHANNELS; ++lane) {
#pragma HLS PIPELINE off
    const lane_result_t lr =
        finalize_lane(acc_sum[lane], acc_square[lane], acc_raw_sum[lane],
                      acc_raw_square[lane], count_now, active_dc_remove);
    mean_q16[lane] = lr.mean_q16;
    rms_q16[lane] = lr.rms_q16;
    rms_count[lane] = lr.rms_count;
    arithmetic_overflow |= lr.overflow;
  }

  const ap_uint<32> status = ap_uint<32>(arithmetic_overflow);
  sequence += 1;

  // Basic result beat for the 150/180-cycle aggregator.
  basic_result_t result;
  result.sequence = sequence;
  result.generation = active_generation;
  result.sample_rate_hz = active_sample_rate;
  result.sample_count = count_now;
  result.valid_mask = result_mask;
  result.flags = beat.range(MTR1_IN_BLOCK_FLAGS_LSB + MTR_FLAG_BITS - 1,
                            MTR1_IN_BLOCK_FLAGS_LSB);
  result.cycle_count =
      beat.range(MTR1_IN_CYCLE_COUNT_LSB + 7, MTR1_IN_CYCLE_COUNT_LSB);
  result.nominal_hz = beat.range(MTR1_IN_NOMINAL_LSB + 7, MTR1_IN_NOMINAL_LSB);
  result.status = status;
  result.frequency_millihz =
      beat.range(MTR1_IN_FREQ_MHZ_LSB + 31, MTR1_IN_FREQ_MHZ_LSB);
  result.frequency_valid =
      beat.bit(MTR1_IN_FREQ_STATUS_LSB + MTR1_FREQ_STATUS_VALID_BIT);
  result.apply_toggle = apply_seen;
  result.first_sample =
      beat.range(MTR1_IN_FIRST_SAMPLE_LSB + 63, MTR1_IN_FIRST_SAMPLE_LSB);
result_lanes:
  for (int lane = 0; lane < MTR_CHANNEL_LANES; ++lane) {
#pragma HLS UNROLL
    result.rms_q16[lane] = (lane < MTR_ACTIVE_CHANNELS)
                               ? ap_int<64>(rms_q16[lane])
                               : ap_int<64>(0);
  }
  m_result.write(pack_basic_result(result));

  // MTR1-v3 record.
  record_image_t image;
  clear_record(image);
  image.word[MREC_SEQUENCE_WORD] = sequence;
  image.word[MREC_GENERATION_WORD] = active_generation;
  image.word[MREC_SAMPLE_RATE_WORD] = active_sample_rate;
  image.word[MREC_SAMPLE_COUNT_WORD] = count_now;
  image.word[MREC_VALID_MASK_WORD] = ap_uint<32>(result_mask);
  image.word[MREC_STATUS_WORD] = status;
  image.word[MREC_FIRST_SAMPLE_LOW_WORD] =
      beat.range(MTR1_IN_FIRST_SAMPLE_LSB + 31, MTR1_IN_FIRST_SAMPLE_LSB);
  image.word[MREC_FIRST_SAMPLE_HIGH_WORD] =
      beat.range(MTR1_IN_FIRST_SAMPLE_LSB + 63, MTR1_IN_FIRST_SAMPLE_LSB + 32);
  image.word[MREC_EMIT_DROPS_WORD] = emit_drops;
  image.word[MREC_RESULT_DROPS_WORD] = result_drops;
  image.word[MTR1_TIMING_WORD] =
      (ap_uint<32>(result.nominal_hz) << MTR1_TIMING_NOMINAL_LSB) |
      (ap_uint<32>(result.cycle_count) << MTR1_TIMING_CYCLES_LSB) |
      (ap_uint<32>(result.flags) << MTR1_TIMING_FLAGS_LSB);
record_lanes:
  for (int lane = 0; lane < MTR_CHANNEL_LANES; ++lane) {
#pragma HLS PIPELINE off
    // Lanes beyond the active channels stay zero (clear_record).
    if (lane < MTR_ACTIVE_CHANNELS) {
      const ap_int<64> mean_units = mean_q16[lane] >> 16;  // arithmetic
      const ap_uint<64> rms_units = rms_q16[lane] >> 16;
      const int base = MTR1_CH_BASE_WORD + lane * MTR1_CH_STRIDE_WORDS;
      image.word[base + MTR1_CH_MEAN_LOW] =
          ap_uint<64>(mean_units).range(31, 0);
      image.word[base + MTR1_CH_MEAN_HIGH] =
          ap_uint<64>(mean_units).range(63, 32);
      image.word[base + MTR1_CH_RMS_COUNT] = rms_count[lane];
      image.word[base + MTR1_CH_RMS_LOW] = rms_units.range(31, 0);
      image.word[base + MTR1_CH_RMS_HIGH] = rms_units.range(63, 32);
    }
  }
  image.word[MTR1_FREQUENCY_VALUE_WORD] =
      beat.range(MTR1_IN_FREQ_MHZ_LSB + 31, MTR1_IN_FREQ_MHZ_LSB);
  image.word[MTR1_FREQUENCY_STATUS_WORD] =
      beat.range(MTR1_IN_FREQ_STATUS_LSB + 31, MTR1_IN_FREQ_STATUS_LSB);
  image.word[MTR1_FREQUENCY_PERIOD_WORD] =
      beat.range(MTR1_IN_FREQ_PERIOD_LSB + 31, MTR1_IN_FREQ_PERIOD_LSB);
  image.word[MTR1_FREQUENCY_SEQUENCE_WORD] =
      beat.range(MTR1_IN_FREQ_SEQ_LSB + 31, MTR1_IN_FREQ_SEQ_LSB);
  image.word[MTR1_CAPTURE_FRAMES_WORD] =
      beat.range(MTR1_IN_CAP_FRAMES_LSB + 31, MTR1_IN_CAP_FRAMES_LSB);
  image.word[MTR1_HEADER_ERRORS_WORD] =
      beat.range(MTR1_IN_CAP_HDRERR_LSB + 31, MTR1_IN_CAP_HDRERR_LSB);
  image.word[MTR1_FIFO_OVERFLOWS_WORD] =
      beat.range(MTR1_IN_CAP_OVERFLOW_LSB + 31, MTR1_IN_CAP_OVERFLOW_LSB);
  image.word[MTR1_ADC_ALERTS_WORD] =
      beat.range(MTR1_IN_CAP_ALERTS_LSB + 31, MTR1_IN_CAP_ALERTS_LSB);

  serialize_record<MREC_FORMAT_MTR1_V3>(image, m_axis);
}
