#ifndef MSAP1_SINGLE_CYCLE_PACKET_HPP
#define MSAP1_SINGLE_CYCLE_PACKET_HPP

#include <hls_stream.h>

#include "single_cycle_result.hpp"

// Internal HLS-to-HLS transport for one complete single-cycle result.
//
// The original implementation exposed the complete 7,072-bit result as one
// AXI4-Stream beat and then widened it to 7,488 bits in RTL to append live
// context.  That interface forced thousands of unrelated fields through one
// register/enables/mux boundary and spread the design across almost every
// physical CLB.  The measurement contract is unchanged here: the exact same
// fields are transferred in the exact same little-endian word order, but as a
// fixed packet of 32-bit words.  At 100 MHz the 221-word transfer occupies
// 2.21 us, far below the approximately 16.7 ms cycle cadence at 60 Hz.

using single_cycle_word_t = ap_uint<32>;

static const int SCYC_PACKET_WORD_BITS = 32;
static const int SCYC_PACKET_WORDS = SCYC_BEAT_BITS / SCYC_PACKET_WORD_BITS;
static_assert((SCYC_BEAT_BITS % SCYC_PACKET_WORD_BITS) == 0,
              "single-cycle result must be an integral number of words");
static_assert(SCYC_PACKET_WORDS == 221,
              "single-cycle packet layout changed; update both endpoints");

inline void scyc_write_u64(hls::stream<single_cycle_word_t> &output,
                           const ap_uint<64> value) {
#pragma HLS INLINE
  output.write(value.range(31, 0));
  output.write(value.range(63, 32));
}

inline void scyc_write_u96(hls::stream<single_cycle_word_t> &output,
                           const ap_uint<96> value) {
#pragma HLS INLINE
  output.write(value.range(31, 0));
  output.write(value.range(63, 32));
  output.write(value.range(95, 64));
}

inline void scyc_write_u128(hls::stream<single_cycle_word_t> &output,
                            const ap_uint<128> value) {
#pragma HLS INLINE
  output.write(value.range(31, 0));
  output.write(value.range(63, 32));
  output.write(value.range(95, 64));
  output.write(value.range(127, 96));
}

inline ap_uint<64> scyc_read_u64(hls::stream<single_cycle_word_t> &input) {
#pragma HLS INLINE
  ap_uint<64> value = 0;
  value.range(31, 0) = input.read();
  value.range(63, 32) = input.read();
  return value;
}

inline ap_uint<96> scyc_read_u96(hls::stream<single_cycle_word_t> &input) {
#pragma HLS INLINE
  ap_uint<96> value = 0;
  value.range(31, 0) = input.read();
  value.range(63, 32) = input.read();
  value.range(95, 64) = input.read();
  return value;
}

inline ap_uint<128> scyc_read_u128(
    hls::stream<single_cycle_word_t> &input) {
#pragma HLS INLINE
  ap_uint<128> value = 0;
  value.range(31, 0) = input.read();
  value.range(63, 32) = input.read();
  value.range(95, 64) = input.read();
  value.range(127, 96) = input.read();
  return value;
}

inline void write_single_cycle_packet(
    const single_cycle_result_t &result,
    hls::stream<single_cycle_word_t> &output) {
#pragma HLS INLINE
  output.write(result.sequence);                                      // 0
  output.write(result.generation);                                    // 1
  scyc_write_u64(output, result.first_sample);                        // 2..3
  scyc_write_u64(output, result.last_sample);                         // 4..5
  output.write(result.sample_count);                                  // 6
  output.write(result.cycle_sequence);                                // 7
  output.write(ap_uint<32>(result.nominal_hz) |
               (ap_uint<32>(result.valid_mask) << 8) |
               (ap_uint<32>(result.flags) << 16));                    // 8
  output.write(result.status);                                        // 9
  output.write(result.frequency_millihz);                             // 10
  output.write(ap_uint<32>(result.frequency_valid) |
               (ap_uint<32>(result.apply_toggle) << 1));              // 11
  scyc_write_u64(output, result.processing_tick);                     // 12..13
  output.write(0);                                                     // 14 reserved
  output.write(0);                                                     // 15 reserved

write_sum:
  for (int lane = 0; lane < MET_ACTIVE_CHANNELS; ++lane) {
#pragma HLS PIPELINE off
    scyc_write_u128(output, ap_uint<128>(result.sum[lane]));           // 16..43
  }
write_square:
  for (int lane = 0; lane < MET_ACTIVE_CHANNELS; ++lane) {
#pragma HLS PIPELINE off
    scyc_write_u128(output, result.square[lane]);                      // 44..71
  }
write_raw_sum:
  for (int lane = 0; lane < MET_ACTIVE_CHANNELS; ++lane) {
#pragma HLS PIPELINE off
    scyc_write_u64(output, ap_uint<64>(result.raw_sum[lane]));         // 72..85
  }
write_raw_square:
  for (int lane = 0; lane < MET_ACTIVE_CHANNELS; ++lane) {
#pragma HLS PIPELINE off
    scyc_write_u96(output, result.raw_square[lane]);                   // 86..106
  }
write_minimum:
  for (int lane = 0; lane < MET_ACTIVE_CHANNELS; ++lane) {
#pragma HLS PIPELINE off
    scyc_write_u64(output, ap_uint<64>(result.minimum[lane]));         // 107..120
  }
write_maximum:
  for (int lane = 0; lane < MET_ACTIVE_CHANNELS; ++lane) {
#pragma HLS PIPELINE off
    scyc_write_u64(output, ap_uint<64>(result.maximum[lane]));         // 121..134
  }
write_vll_square:
  for (int pair = 0; pair < MET_VLL_PAIRS; ++pair) {
#pragma HLS PIPELINE off
    scyc_write_u128(output, result.vll_square[pair]);                  // 135..146
  }
write_vll_peak:
  for (int pair = 0; pair < MET_VLL_PAIRS; ++pair) {
#pragma HLS PIPELINE off
    scyc_write_u64(output, result.vll_peak[pair]);                     // 147..152
  }
write_power:
  for (int phase = 0; phase < MET_POWER_PHASES; ++phase) {
#pragma HLS PIPELINE off
    scyc_write_u128(output, ap_uint<128>(result.power_sum[phase]));    // 153..164
  }
write_phasor_re:
  for (int lane = 0; lane < MET_ACTIVE_CHANNELS; ++lane) {
#pragma HLS PIPELINE off
    scyc_write_u128(output, ap_uint<128>(result.phasor_re[lane]));     // 165..192
  }
write_phasor_im:
  for (int lane = 0; lane < MET_ACTIVE_CHANNELS; ++lane) {
#pragma HLS PIPELINE off
    scyc_write_u128(output, ap_uint<128>(result.phasor_im[lane]));     // 193..220
  }
}

inline single_cycle_result_t read_single_cycle_packet(
    hls::stream<single_cycle_word_t> &input) {
#pragma HLS INLINE
  single_cycle_result_t result;
  result.sequence = input.read();
  result.generation = input.read();
  result.first_sample = scyc_read_u64(input);
  result.last_sample = scyc_read_u64(input);
  result.sample_count = input.read();
  result.cycle_sequence = input.read();
  const single_cycle_word_t identity = input.read();
  result.nominal_hz = identity.range(7, 0);
  result.valid_mask = identity.range(15, 8);
  result.flags = identity.range(16 + MET_FLAG_BITS - 1, 16);
  result.status = input.read();
  result.frequency_millihz = input.read();
  const single_cycle_word_t controls = input.read();
  result.frequency_valid = controls.bit(0);
  result.apply_toggle = controls.bit(1);
  result.processing_tick = scyc_read_u64(input);
  (void)input.read();  // reserved word 14
  (void)input.read();  // reserved word 15

read_sum:
  for (int lane = 0; lane < MET_ACTIVE_CHANNELS; ++lane) {
#pragma HLS PIPELINE off
    result.sum[lane] = ap_int<128>(scyc_read_u128(input));
  }
read_square:
  for (int lane = 0; lane < MET_ACTIVE_CHANNELS; ++lane) {
#pragma HLS PIPELINE off
    result.square[lane] = scyc_read_u128(input);
  }
read_raw_sum:
  for (int lane = 0; lane < MET_ACTIVE_CHANNELS; ++lane) {
#pragma HLS PIPELINE off
    result.raw_sum[lane] = ap_int<64>(scyc_read_u64(input));
  }
read_raw_square:
  for (int lane = 0; lane < MET_ACTIVE_CHANNELS; ++lane) {
#pragma HLS PIPELINE off
    result.raw_square[lane] = scyc_read_u96(input);
  }
read_minimum:
  for (int lane = 0; lane < MET_ACTIVE_CHANNELS; ++lane) {
#pragma HLS PIPELINE off
    result.minimum[lane] = ap_int<64>(scyc_read_u64(input));
  }
read_maximum:
  for (int lane = 0; lane < MET_ACTIVE_CHANNELS; ++lane) {
#pragma HLS PIPELINE off
    result.maximum[lane] = ap_int<64>(scyc_read_u64(input));
  }
read_vll_square:
  for (int pair = 0; pair < MET_VLL_PAIRS; ++pair) {
#pragma HLS PIPELINE off
    result.vll_square[pair] = scyc_read_u128(input);
  }
read_vll_peak:
  for (int pair = 0; pair < MET_VLL_PAIRS; ++pair) {
#pragma HLS PIPELINE off
    result.vll_peak[pair] = scyc_read_u64(input);
  }
read_power:
  for (int phase = 0; phase < MET_POWER_PHASES; ++phase) {
#pragma HLS PIPELINE off
    result.power_sum[phase] = ap_int<128>(scyc_read_u128(input));
  }
read_phasor_re:
  for (int lane = 0; lane < MET_ACTIVE_CHANNELS; ++lane) {
#pragma HLS PIPELINE off
    result.phasor_re[lane] = ap_int<128>(scyc_read_u128(input));
  }
read_phasor_im:
  for (int lane = 0; lane < MET_ACTIVE_CHANNELS; ++lane) {
#pragma HLS PIPELINE off
    result.phasor_im[lane] = ap_int<128>(scyc_read_u128(input));
  }
  return result;
}

#endif  // MSAP1_SINGLE_CYCLE_PACKET_HPP
