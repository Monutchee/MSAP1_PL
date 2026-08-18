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
      const ap_int<32> peak = request.range(peak_lsb + 31, peak_lsb);
      const ap_uint<32> phase_offset = request.range(phase_lsb + 31, phase_lsb);
      const ap_int<32> dc_offset = request.range(dc_lsb + 31, dc_lsb);
      const ap_uint<24> noise_level =
          request.range(noise_lsb + 23, noise_lsb);

      // Full 32-bit peak into the product so an out-of-range peak register
      // saturates at the rails instead of aliasing (legacy behaviour).
      // product is peak(32) x sine Q1.37(39) = 71 bits; >> 37 restores
      // integer counts with a single floor (arithmetic shift).
      const ap_uint<32> lane_angle = base_phase + phase_offset;
      const ap_int<39> sine = met_sin_q32(lane_angle);
      const ap_int<71> product = peak * sine;
      const ap_int<34> scaled = ap_int<34>(product >> 37);

      // Harmonic slots: fraction-of-fundamental amplitude, one floor per
      // slot after the combined peak*fraction*sine product (>> 16+37).
      // Four full-scale slots extend the pre-clamp sum by at most 3 bits.
      ap_int<37> harmonic_counts = 0;
harmonic_slots:
      for (int slot = 0; slot < SIM_WAVE_HARMONIC_SLOTS; ++slot) {
#pragma HLS PIPELINE off
        const int slot_lsb = SIM_WAVE_REQ_HARMONIC_LSB + slot * 64;
        const ap_uint<8> order = request.range(slot_lsb + 7, slot_lsb);
        const ap_uint<8> slot_mask = request.range(slot_lsb + 15, slot_lsb + 8);
        const ap_uint<16> fraction = request.range(slot_lsb + 31, slot_lsb + 16);
        const ap_uint<32> slot_phase =
            request.range(slot_lsb + 63, slot_lsb + 32);
        if (order == 0 || slot_mask[lane] == 0 || fraction == 0) {
          continue;
        }
        // order * angle wraps mod 2^32 = mod one turn: exact.
        const ap_uint<32> harmonic_angle =
            ap_uint<32>(order * lane_angle) + slot_phase;
        const ap_int<39> harmonic_sine = met_sin_q32(harmonic_angle);
        const ap_int<49> scaled_peak = peak * ap_int<17>(ap_uint<17>(fraction));
        const ap_int<88> harmonic_product = scaled_peak * harmonic_sine;
        harmonic_counts += ap_int<37>(harmonic_product >> 53);
      }

      // Uniform fluctuation in +/- noise_level counts: the mixed word's
      // top 24 bits are a signed uniform in +/- 2^23, scaled by the level
      // and floored back to counts.
      const ap_uint<32> noise_word =
          mix32(frame_index ^ ap_uint<32>(0x9e3779b9u * (unsigned)(lane + 1)));
      const ap_int<24> noise_uniform = ap_int<24>(noise_word.range(31, 8));
      const ap_int<49> noise_product = noise_uniform * ap_int<25>(noise_level);
      const ap_int<26> noise_counts = ap_int<26>(noise_product >> 23);

      const ap_int<39> with_dc = ap_int<39>(scaled) + ap_int<39>(dc_offset) +
                                 ap_int<39>(noise_counts) +
                                 ap_int<39>(harmonic_counts);
      if (with_dc > ap_int<39>(SIM_WAVE_SAMPLE_MAX)) {
        sample = SIM_WAVE_SAMPLE_MAX;
        saturated = 1;
      } else if (with_dc < ap_int<39>(SIM_WAVE_SAMPLE_MIN)) {
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
