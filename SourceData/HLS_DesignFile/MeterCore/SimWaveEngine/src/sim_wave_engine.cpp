#include "sim_wave_engine.hpp"

#include "metrology_trig.hpp"

// splitmix32-style finalizing mixer: a bijective avalanche over 32 bits.
// Seeded per (frame_index, lane) it yields white, channel-uncorrelated
// noise words that any golden model reproduces bit-exactly -- randomness
// without hidden PRNG state.
static ap_uint<32> mix32(ap_uint<32> value) {
#pragma HLS INLINE
  value ^= value >> 16;
  value *= 0x7feb352du;
  value ^= value >> 15;
  value *= 0x846ca68bu;
  value ^= value >> 16;
  return value;
}

// Free-running single-shot process, one invocation per request beat: the
// engine is stateless, so there is nothing to reset and no window
// bookkeeping -- every response is a pure function of its request.
void hls_sim_wave_engine(hls::stream<sim_wave_request_t> &s_request,
                         hls::stream<sim_wave_response_t> &m_frame) {
#pragma HLS INTERFACE mode=axis port=s_request register_mode=off
#pragma HLS INTERFACE mode=axis port=m_frame register_mode=both
#pragma HLS INTERFACE mode=ap_ctrl_none port=return

  if (s_request.empty()) {
    return;
  }
  const sim_wave_request_t request = s_request.read();

  const ap_uint<32> base_phase =
      request.range(SIM_WAVE_REQ_BASE_PHASE_LSB + 31, SIM_WAVE_REQ_BASE_PHASE_LSB);
  const ap_uint<8> valid_mask =
      request.range(SIM_WAVE_REQ_VALID_MASK_LSB + 7, SIM_WAVE_REQ_VALID_MASK_LSB);
  const ap_uint<32> frame_index =
      request.range(SIM_WAVE_REQ_FRAME_INDEX_LSB + 31, SIM_WAVE_REQ_FRAME_INDEX_LSB);
  const ap_uint<19> event_scale = request.range(
      SIM_WAVE_REQ_EVENT_SCALE_LSB + 18, SIM_WAVE_REQ_EVENT_SCALE_LSB);
  const ap_uint<8> event_mask = request.range(
      SIM_WAVE_REQ_EVENT_MASK_LSB + 7, SIM_WAVE_REQ_EVENT_MASK_LSB);

  sim_wave_response_t response = 0;

channel_lanes:
  for (int lane = 0; lane < SIM_WAVE_CHANNELS; ++lane) {
    // Rolled on purpose: one shared sine/multiply datapath. The frame
    // budget is hundreds of clocks even at the 128 kSPS capture ceiling,
    // so latency is free and area stays minimal (the aggregation-trial
    // lesson).
#pragma HLS PIPELINE off
    ap_int<32> sample = 0;
    ap_uint<1> saturated = 0;
    if (valid_mask[lane]) {
      const int peak_lsb = SIM_WAVE_REQ_PEAK_LSB + lane * 32;
      const int phase_lsb = SIM_WAVE_REQ_PHASE_LSB + lane * 32;
      const int dc_lsb = SIM_WAVE_REQ_DC_LSB + lane * 32;
      const int noise_lsb = SIM_WAVE_REQ_NOISE_LSB + lane * 32;
      const ap_int<32> peak_register = request.range(peak_lsb + 31, peak_lsb);
      const ap_uint<32> phase_offset = request.range(phase_lsb + 31, phase_lsb);
      const ap_int<32> dc_offset = request.range(dc_lsb + 31, dc_lsb);
      const ap_uint<24> noise_level =
          request.range(noise_lsb + 23, noise_lsb);

      // Event envelope: one floor after peak x Q16 scale. Applied to the
      // peak (not the finished sample) so the dip carries the harmonic
      // content with it. A 32-bit peak register times the 4.0 cap needs
      // 35 bits, so the enveloped peak is 36 and the datapath below is
      // sized from it -- an out-of-range peak still saturates at the
      // sample rails instead of aliasing (legacy behaviour).
      ap_int<36> peak = peak_register;
      if (event_mask[lane] && event_scale != ap_uint<19>(SIM_WAVE_EVENT_SCALE_UNITY)) {
        const ap_int<52> enveloped = peak_register * ap_int<20>(event_scale);
        peak = ap_int<36>(enveloped >> 16);
      }

      // product is peak(36) x sine Q1.37(39) = 75 bits; >> 37 restores
      // integer counts with a single floor (arithmetic shift).
      const ap_uint<32> lane_angle = base_phase + phase_offset;
      const ap_int<39> sine = met_sin_q32(lane_angle);
      const ap_int<75> product = peak * sine;
      const ap_int<38> scaled = ap_int<38>(product >> 37);

      // Harmonic slots: fraction-of-fundamental amplitude, one floor per
      // slot after the combined peak*fraction*sine product (>> 16+37).
      // Four full-scale slots extend the pre-clamp sum by at most 3 bits.
      ap_int<41> harmonic_counts = 0;
harmonic_slots:
      for (int slot = 0; slot < SIM_WAVE_HARMONIC_SLOTS; ++slot) {
#pragma HLS PIPELINE off
        const int slot_lsb = SIM_WAVE_REQ_HARMONIC_LSB + slot * 96;
        const ap_uint<32> ratio_q16 = request.range(slot_lsb + 31, slot_lsb);
        const ap_uint<8> slot_mask = request.range(slot_lsb + 39, slot_lsb + 32);
        const ap_uint<16> fraction = request.range(slot_lsb + 63, slot_lsb + 48);
        const ap_uint<32> slot_phase =
            request.range(slot_lsb + 95, slot_lsb + 64);
        if (ratio_q16 == 0 || slot_mask[lane] == 0 || fraction == 0) {
          continue;
        }
        // Q16.16 ratio * Q0.32 turns, floored back to Q0.32; retaining
        // the low 32 bits is modulo one turn. Integer ratios are exact.
        const ap_uint<64> ratio_product = ratio_q16 * lane_angle;
        const ap_uint<32> harmonic_angle =
            ap_uint<32>(ratio_product >> 16) + slot_phase;
        const ap_int<39> harmonic_sine = met_sin_q32(harmonic_angle);
        const ap_int<53> scaled_peak = peak * ap_int<17>(ap_uint<17>(fraction));
        const ap_int<92> harmonic_product = scaled_peak * harmonic_sine;
        harmonic_counts += ap_int<41>(harmonic_product >> 53);
      }

      // Uniform fluctuation in +/- noise_level counts: the mixed word's
      // top 24 bits are a signed uniform in +/- 2^23, scaled by the level
      // and floored back to counts.
      const ap_uint<32> noise_word =
          mix32(frame_index ^ ap_uint<32>(0x9e3779b9u * (unsigned)(lane + 1)));
      const ap_int<24> noise_uniform = ap_int<24>(noise_word.range(31, 8));
      const ap_int<49> noise_product = noise_uniform * ap_int<25>(noise_level);
      const ap_int<26> noise_counts = ap_int<26>(noise_product >> 23);

      const ap_int<43> with_dc = ap_int<43>(scaled) + ap_int<43>(dc_offset) +
                                 ap_int<43>(noise_counts) +
                                 ap_int<43>(harmonic_counts);
      if (with_dc > ap_int<43>(SIM_WAVE_SAMPLE_MAX)) {
        sample = SIM_WAVE_SAMPLE_MAX;
        saturated = 1;
      } else if (with_dc < ap_int<43>(SIM_WAVE_SAMPLE_MIN)) {
        sample = SIM_WAVE_SAMPLE_MIN;
        saturated = 1;
      } else {
        sample = ap_int<32>(with_dc);
      }
    }
    const int sample_lsb = SIM_WAVE_RSP_SAMPLE_LSB + lane * 32;
    response.range(sample_lsb + 31, sample_lsb) = ap_uint<32>(sample);
    response[SIM_WAVE_RSP_SATURATED_LSB + lane] = saturated;
  }

  m_frame.write(response);
}
