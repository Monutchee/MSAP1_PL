#include "sliding_one_cycle_rms_engine.hpp"

#include "metrology_math.hpp"
#include "metrology_stats.hpp"

// Sliding one-cycle RMS / PQ event engine. Contract, beat layout, and
// detection rules: see sliding_one_cycle_rms_engine.hpp.
//
// One free-running single-shot process (the house pattern): each
// invocation consumes at most one frame. The per-frame path is only six
// squaring accumulations; the half-cycle path (six roots plus the
// detection comparisons) runs once per ~10 ms, four orders of magnitude
// apart, so its latency is invisible and the hosting shim's small FIFO
// absorbs it exactly like the single-cycle shim does.

namespace {

// Monitored lanes: voltages first (detection), then phase currents
// (fault context). Index order is A, B, C within each set.
static const int pq_lane[2 * PQ_PHASES] = {
    MET_LANE_VA, MET_LANE_VB, MET_LANE_VC,
    MET_LANE_IA, MET_LANE_IB, MET_LANE_IC};

// Threshold comparisons are done by CROSS MULTIPLICATION, never by
// dividing the reference: `urms * 10000` against `reference_q16 * e4` is
// exact, has no divider, and keeps the whole comparison in integers.
inline ap_uint<96> pq_scaled_urms(const ap_uint<64> urms_q16) {
#pragma HLS INLINE
  return ap_uint<96>(urms_q16) * ap_uint<14>(10000);
}

inline ap_uint<96> pq_level(const ap_uint<64> reference_q16,
                            const ap_uint<18> fraction_e4) {
#pragma HLS INLINE
  return ap_uint<96>(reference_q16) * fraction_e4;
}

}  // namespace

void hls_sliding_one_cycle_rms_engine(hls::stream<pq_input_beat_t> &s_frame,
                                      hls::stream<record_axis_t> &m_axis) {
  // s_frame unregistered (the shim registers its side); the exported
  // record stream keeps its boundary register toward the block design.
#pragma HLS INTERFACE mode=axis port=s_frame register_mode=off
#pragma HLS INTERFACE mode=axis port=m_axis
#pragma HLS INTERFACE mode=ap_ctrl_none port=return

  // Committed configuration; syn.rtl.reset=state re-zeroes these on
  // aresetn exactly like every sibling engine.
  static ap_uint<1> apply_seen = 0;
  static ap_uint<32> active_generation = 0;
  static ap_uint<32> active_sample_rate = 32000;
  static ap_uint<8> active_valid_mask = 0;
  static ap_uint<1> active_enable = 0;
  static ap_uint<32> active_reference = 0;  // micro-volts; 0 disarms
  static ap_uint<16> active_sag = 9000;
  static ap_uint<16> active_swell = 11000;
  static ap_uint<16> active_interrupt = 1000;
  static ap_uint<16> active_hysteresis = 200;
  static ap_uint<1> arithmetic_overflow = 0;
  static ap_uint<1> disc_pending = 1;
  static ap_uint<32> sequence = 0;

  // Sliding window: the half being filled and the previous half. Widths
  // match every other engine's square accumulator (u128, saturating with
  // the sticky flag): the conversion stage saturates converted samples to
  // the full signed 64-bit rail, so no narrower product is safe.
  static ap_uint<128> curr_square[2 * PQ_PHASES];
#pragma HLS BIND_STORAGE variable=curr_square type=ram_s2p impl=lutram
  static ap_uint<128> prev_square[2 * PQ_PHASES];
#pragma HLS BIND_STORAGE variable=prev_square type=ram_s2p impl=lutram
  static ap_uint<32> curr_count = 0;
  static ap_uint<32> prev_count = 0;
  static ap_uint<1> window_primed = 0;

  // Latest published half-cycle values and the periodic window's extremes.
  static ap_uint<64> urms_q16[PQ_PHASES];
#pragma HLS ARRAY_PARTITION variable=urms_q16 complete
  static ap_uint<64> irms_q16[PQ_PHASES];
#pragma HLS ARRAY_PARTITION variable=irms_q16 complete
  static ap_uint<64> win_min[PQ_PHASES];
#pragma HLS ARRAY_PARTITION variable=win_min complete
  static ap_uint<64> win_max[PQ_PHASES];
#pragma HLS ARRAY_PARTITION variable=win_max complete
  static ap_uint<32> win_updates = 0;
  static ap_uint<64> win_first_sample = 0;
  static ap_uint<1> win_seeded = 0;

  // Event state.
  static ap_uint<1> event_active = 0;
  static ap_uint<2> event_type = 0;
  static ap_uint<3> event_phases = 0;
  static ap_uint<32> event_sequence = 0;
  static ap_uint<64> event_first_sample = 0;
  static ap_uint<32> event_updates = 0;
  static ap_uint<64> evt_min[PQ_PHASES];
#pragma HLS ARRAY_PARTITION variable=evt_min complete
  static ap_uint<64> evt_max[PQ_PHASES];
#pragma HLS ARRAY_PARTITION variable=evt_max complete

  if (s_frame.empty()) {
    return;
  }
  const pq_input_beat_t beat = s_frame.read();

  const ap_uint<1> beat_apply = beat.bit(PQIN_APPLY_BIT);
  if (beat_apply != apply_seen) {
    apply_seen = beat_apply;
    active_generation = beat.range(PQIN_CFG_GEN_LSB + 31, PQIN_CFG_GEN_LSB);
    active_sample_rate = beat.range(PQIN_CFG_RATE_LSB + 31, PQIN_CFG_RATE_LSB);
    active_valid_mask = beat.range(PQIN_CFG_MASK_LSB + 7, PQIN_CFG_MASK_LSB);
    active_enable = beat.bit(PQIN_ENABLE_BIT);
    active_reference =
        beat.range(PQIN_REFERENCE_LSB + 31, PQIN_REFERENCE_LSB);
    active_sag = beat.range(PQIN_SAG_LSB + 15, PQIN_SAG_LSB);
    active_swell = beat.range(PQIN_SWELL_LSB + 15, PQIN_SWELL_LSB);
    active_interrupt = beat.range(PQIN_INTERRUPT_LSB + 15, PQIN_INTERRUPT_LSB);
    active_hysteresis =
        beat.range(PQIN_HYSTERESIS_LSB + 15, PQIN_HYSTERESIS_LSB);
    arithmetic_overflow = 0;
    // A configuration commit abandons the half-cycle window and any open
    // event: thresholds and the reference may have moved, so nothing
    // measured before the commit may characterize an event after it.
    curr_count = 0;
    prev_count = 0;
    window_primed = 0;
    win_seeded = 0;
    event_active = 0;
    disc_pending = 1;
  }

  if (active_enable == 0) {
    return;
  }

  // A malformed frame cannot contribute samples; it also breaks the
  // window, because a partial half cycle would bias the next root.
  if (beat.bit(PQIN_MALFORMED_BIT) == 1) {
    curr_count = 0;
    prev_count = 0;
    window_primed = 0;
    disc_pending = 1;
    return;
  }

  const ap_uint<64> sample_index =
      beat.range(PQIN_SAMPLE_IDX_LSB + 63, PQIN_SAMPLE_IDX_LSB);

  // ---- Per-frame accumulation ------------------------------------------
  // The house square-accumulator idiom: seed in place on the half's first
  // sample, saturate at the 128-bit rail with the sticky arithmetic flag,
  // never wrap. The exact 48x48 product is widened into that accumulator.
  const ap_uint<32> count_now = curr_count + 1;
accumulate_lanes:
  for (int index = 0; index < 2 * PQ_PHASES; ++index) {
#pragma HLS PIPELINE off
    const met_q16_t sample = met_q16_t(ap_uint<MET_RMS_LANE_BITS>(beat.range(
        PQIN_SAMPLES_LSB + pq_lane[index] * MET_RMS_LANE_BITS +
            MET_RMS_LANE_BITS - 1,
        PQIN_SAMPLES_LSB + pq_lane[index] * MET_RMS_LANE_BITS)));
    const ap_uint<MET_RMS_LANE_BITS> magnitude =
        met_abs<MET_RMS_LANE_BITS>(sample);
    const ap_uint<96> square_narrow = magnitude * magnitude;
    const ap_uint<128> square = square_narrow;
    const ap_uint<128> base = (curr_count == 0) ? ap_uint<128>(0)
                                                : curr_square[index];
    curr_square[index] =
        met_add_square_saturating<128>(base, square, arithmetic_overflow);
  }
  curr_count = count_now;

  if (beat.bit(PQIN_HALF_BIT) == 0) {
    return;
  }

  // ---- Half-cycle boundary: refresh Urms(1/2) ---------------------------
  const ap_uint<32> window_samples = prev_count + count_now;
  const ap_uint<1> primed = window_primed;
  if (primed == 1) {
  finalize_lanes:
    for (int index = 0; index < 2 * PQ_PHASES; ++index) {
#pragma HLS PIPELINE off
      const ap_uint<128> total = met_add_square_saturating<128>(
          prev_square[index], curr_square[index], arithmetic_overflow);
      // Zero-referenced RMS: the detection quantity is the plain RMS of
      // the cycle, never mean-corrected — a dip is a change in the total
      // voltage, and removing a DC estimate would mask a real offset.
      const ap_uint<64> root = met_rms_from_accumulators<128, 64>(
          total, ap_int<64>(0), window_samples, ap_uint<1>(0),
          arithmetic_overflow);
      if (index < PQ_PHASES) {
        urms_q16[index] = root;
      } else {
        irms_q16[index - PQ_PHASES] = root;
      }
    }
  }
rotate_lanes:
  for (int index = 0; index < 2 * PQ_PHASES; ++index) {
#pragma HLS PIPELINE off
    prev_square[index] = curr_square[index];
  }
  prev_count = count_now;
  curr_count = 0;
  window_primed = 1;
  if (primed == 0) {
    // First half cycle after a break only primes the window.
    return;
  }

  const ap_uint<1> locked = beat.bit(PQIN_LOCKED_BIT);
  const ap_uint<1> fallback = beat.bit(PQIN_FALLBACK_BIT);
  const ap_uint<1> armed = (active_reference != 0) ? 1 : 0;

  // Window extremes (periodic heartbeat span).
  if (win_seeded == 0) {
    win_first_sample = sample_index;
    win_updates = 0;
  }
window_extremes:
  for (int phase = 0; phase < PQ_PHASES; ++phase) {
#pragma HLS PIPELINE off
    if (win_seeded == 0 || urms_q16[phase] < win_min[phase]) {
      win_min[phase] = urms_q16[phase];
    }
    if (win_seeded == 0 || urms_q16[phase] > win_max[phase]) {
      win_max[phase] = urms_q16[phase];
    }
  }
  win_seeded = 1;
  win_updates += 1;

  // ---- Detection --------------------------------------------------------
  const ap_uint<64> reference_q16 = ap_uint<64>(active_reference) << 16;
  ap_uint<3> below_sag = 0;
  ap_uint<3> below_interrupt = 0;
  ap_uint<3> above_swell = 0;
  ap_uint<3> outside = 0;      // outside the band under START thresholds
  ap_uint<3> unrecovered = 0;  // still outside under RECOVERY thresholds
  if (armed == 1) {
  detect_phases:
    for (int phase = 0; phase < PQ_PHASES; ++phase) {
#pragma HLS PIPELINE off
      if ((active_valid_mask.bit(pq_lane[phase])) == 0) {
        continue;
      }
      const ap_uint<96> value = pq_scaled_urms(urms_q16[phase]);
      const ap_uint<96> sag_level = pq_level(reference_q16, active_sag);
      const ap_uint<96> swell_level = pq_level(reference_q16, active_swell);
      const ap_uint<96> interrupt_level =
          pq_level(reference_q16, active_interrupt);
      const ap_uint<96> sag_recover = pq_level(
          reference_q16, ap_uint<18>(active_sag) + active_hysteresis);
      const ap_uint<96> swell_recover =
          pq_level(reference_q16,
                   (active_swell > active_hysteresis)
                       ? ap_uint<18>(ap_uint<18>(active_swell) -
                                     active_hysteresis)
                       : ap_uint<18>(0));
      if (value < sag_level) below_sag[phase] = 1;
      if (value < interrupt_level) below_interrupt[phase] = 1;
      if (value > swell_level) above_swell[phase] = 1;
      if (value < sag_level || value > swell_level) outside[phase] = 1;
      if (value < sag_recover || value > swell_recover) unrecovered[phase] = 1;
    }
  }

  // Severity of this update: interruption outranks sag; swell is disjoint.
  ap_uint<2> update_type = MET_PQ_EVENT_NONE;
  if (below_interrupt != 0) {
    update_type = MET_PQ_EVENT_INTERRUPTION;
  } else if (below_sag != 0) {
    update_type = MET_PQ_EVENT_SAG;
  } else if (above_swell != 0) {
    update_type = MET_PQ_EVENT_SWELL;
  }

  ap_uint<2> emit_kind = 3;  // 3 = nothing to emit
  ap_uint<64> emit_first = 0;
  ap_uint<32> emit_updates = 0;
  ap_uint<64> emit_duration = 0;
  ap_uint<2> emit_type = MET_PQ_EVENT_NONE;
  ap_uint<3> emit_phases = 0;
  ap_uint<32> emit_event_seq = 0;
  ap_uint<64> emit_min[PQ_PHASES];
#pragma HLS ARRAY_PARTITION variable=emit_min complete
  ap_uint<64> emit_max[PQ_PHASES];
#pragma HLS ARRAY_PARTITION variable=emit_max complete

  if (event_active == 0) {
    if (outside != 0) {
      // Event declared on this update: ANY phase outside its band.
      event_active = 1;
      event_type = update_type;
      event_phases = outside;
      event_first_sample = sample_index;
      event_updates = 1;
      event_sequence += 1;
    event_seed:
      for (int phase = 0; phase < PQ_PHASES; ++phase) {
#pragma HLS UNROLL
        evt_min[phase] = urms_q16[phase];
        evt_max[phase] = urms_q16[phase];
      }
      emit_kind = MET_PQ_KIND_EVENT_START;
      emit_first = event_first_sample;
      emit_updates = 1;
      emit_type = event_type;
      emit_phases = event_phases;
      emit_event_seq = event_sequence;
    emit_seed:
      for (int phase = 0; phase < PQ_PHASES; ++phase) {
#pragma HLS UNROLL
        emit_min[phase] = urms_q16[phase];
        emit_max[phase] = urms_q16[phase];
      }
    }
  } else {
    event_updates += 1;
    event_phases |= outside;
    if (update_type > event_type && update_type != MET_PQ_EVENT_NONE) {
      // Interruption outranks sag; a swell never downgrades a dip.
      if (!(event_type == MET_PQ_EVENT_SWELL)) {
        event_type = update_type;
      }
    }
  event_extremes:
    for (int phase = 0; phase < PQ_PHASES; ++phase) {
#pragma HLS PIPELINE off
      if (urms_q16[phase] < evt_min[phase]) evt_min[phase] = urms_q16[phase];
      if (urms_q16[phase] > evt_max[phase]) evt_max[phase] = urms_q16[phase];
    }
    if (unrecovered == 0) {
      // Every phase has re-entered its band past the hysteresis.
      event_active = 0;
      emit_kind = MET_PQ_KIND_EVENT_END;
      emit_first = event_first_sample;
      emit_updates = event_updates;
      emit_duration = sample_index - event_first_sample;
      emit_type = event_type;
      emit_phases = event_phases;
      emit_event_seq = event_sequence;
    emit_event_extremes:
      for (int phase = 0; phase < PQ_PHASES; ++phase) {
#pragma HLS UNROLL
        emit_min[phase] = evt_min[phase];
        emit_max[phase] = evt_max[phase];
      }
    }
  }

  // Periodic heartbeat, only when no event record is already going out on
  // this update (an event record supersedes the snapshot and carries the
  // same latest values).
  if (emit_kind == 3 && win_updates >= PQ_PERIODIC_UPDATES) {
    emit_kind = MET_PQ_KIND_PERIODIC;
    emit_first = win_first_sample;
    emit_updates = win_updates;
    emit_type = MET_PQ_EVENT_NONE;
    emit_phases = 0;
    emit_event_seq = 0;
  emit_window:
    for (int phase = 0; phase < PQ_PHASES; ++phase) {
#pragma HLS UNROLL
      emit_min[phase] = win_min[phase];
      emit_max[phase] = win_max[phase];
    }
  }
  if (win_updates >= PQ_PERIODIC_UPDATES) {
    win_seeded = 0;  // start a fresh extremes window
  }

  if (emit_kind == 3) {
    return;
  }

  // ---- Emit one PQEVT-v1 record -----------------------------------------
  sequence += 1;
  const ap_uint<1> first_record = disc_pending;
  disc_pending = 0;
  const ap_uint<32> status =
      ap_uint<32>(arithmetic_overflow) | (ap_uint<32>(first_record) << 2);

  record_image_t image;
  clear_record(image);
  fill_envelope(image, sequence, active_generation, active_sample_rate,
                ap_uint<32>(sample_index - emit_first + 1),
                active_valid_mask & ap_uint<8>(0x7F), status, emit_first);
  image.word[PQ_KIND_WORD] =
      (ap_uint<32>(emit_kind) << PQ_KIND_LSB) |
      (ap_uint<32>(emit_type) << PQ_KIND_EVENT_LSB) |
      (ap_uint<32>(emit_phases) << PQ_KIND_PHASES_LSB) |
      (ap_uint<32>(locked) << PQ_KIND_LOCKED_BIT) |
      (ap_uint<32>(fallback) << PQ_KIND_FALLBACK_BIT) |
      (ap_uint<32>(armed) << PQ_KIND_ARMED_BIT);
  image.word[PQ_LAST_SAMPLE_LOW_WORD] = sample_index.range(31, 0);
  image.word[PQ_LAST_SAMPLE_HIGH_WORD] = sample_index.range(63, 32);
record_phases:
  for (int phase = 0; phase < PQ_PHASES; ++phase) {
#pragma HLS PIPELINE off
    image.word[PQ_URMS_BASE_WORD + phase] =
        ap_uint<64>(urms_q16[phase] >> 16).range(31, 0);
    image.word[PQ_URMS_MIN_BASE_WORD + phase] =
        ap_uint<64>(emit_min[phase] >> 16).range(31, 0);
    image.word[PQ_URMS_MAX_BASE_WORD + phase] =
        ap_uint<64>(emit_max[phase] >> 16).range(31, 0);
    image.word[PQ_IRMS_BASE_WORD + phase] =
        ap_uint<64>(irms_q16[phase] >> 16).range(31, 0);
  }
  image.word[PQ_EVENT_SEQ_WORD] = emit_event_seq;
  image.word[PQ_DURATION_LOW_WORD] = emit_duration.range(31, 0);
  image.word[PQ_DURATION_HIGH_WORD] = emit_duration.range(63, 32);
  image.word[PQ_UPDATES_WORD] = emit_updates;
  image.word[PQ_REFERENCE_WORD] = active_reference;
  image.word[PQ_SAG_THRESHOLD_WORD] = ap_uint<32>(active_sag);
  image.word[PQ_SWELL_THRESHOLD_WORD] = ap_uint<32>(active_swell);
  image.word[PQ_INTERRUPT_THRESHOLD_WORD] = ap_uint<32>(active_interrupt);
  image.word[PQ_HYSTERESIS_WORD] = ap_uint<32>(active_hysteresis);
  serialize_record<MREC_FORMAT_PQEVT_V1>(image, m_axis);
}
