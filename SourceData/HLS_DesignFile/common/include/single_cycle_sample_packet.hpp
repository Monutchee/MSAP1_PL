#ifndef SINGLE_CYCLE_SAMPLE_PACKET_HPP
#define SINGLE_CYCLE_SAMPLE_PACKET_HPP

#include <hls_stream.h>

#include "metering_types.hpp"

// Converted-frame input contract for SingleCycleEngine.
//
// The logical payload remains 1,024 bits so all samples, raw counts, timing,
// and configuration provenance survive unchanged.  Its physical HLS AXI4-
// Stream interface is deliberately 32 bits wide.  The RTL shim uses an AMD
// asymmetric XPM FIFO to accept one complete 1,024-bit frame atomically and
// emit these 32 ordered words.  This removes a wide routed interface while
// retaining burst buffering and exact field compatibility.
//
// Words are little-endian by significance: word zero carries beat[31:0].
// The producer only exposes a packet after its complete wide FIFO write.  The
// HLS top consumes one word per invocation and keeps an explicit packet-word
// index, avoiding a wide, parallel input interface and a 32-read scheduler.
static const int SCYC_SAMPLE_PACKET_WORD_BITS = 32;
static const int SCYC_SAMPLE_PACKET_WORDS = 32;
static const int SCYC_IN_BITS =
    SCYC_SAMPLE_PACKET_WORD_BITS * SCYC_SAMPLE_PACKET_WORDS;

typedef ap_uint<SCYC_IN_BITS> single_cycle_sample_beat_t;
typedef ap_uint<SCYC_SAMPLE_PACKET_WORD_BITS> single_cycle_sample_word_t;

// Input beat fields. Every field is byte aligned; [MSB:LSB] positions are
// normative and meter_single_cycle_hls_shim.vhd mirrors them in lock step.
static const int SCYC_IN_SAMPLES_LSB      = 0;     // [383:0]    8 x 48b Q16
static const int SCYC_IN_RAW_LSB          = 384;   // [639:384]  8 x 32b raw
static const int SCYC_IN_FRAME_MASK_LSB   = 640;   // [647:640]  frame valid mask
static const int SCYC_IN_FRAME_GEN_LSB    = 648;   // [679:648]  frame generation
static const int SCYC_IN_MALFORMED_BIT    = 680;   // TKEEP was not all-ones
static const int SCYC_IN_CLOSES_BIT       = 681;   // frame completes a cycle
static const int SCYC_IN_CYCLE_MODE_BIT   = 682;   // cycle timing locked (level)
static const int SCYC_IN_APPLY_BIT        = 683;   // config APPLY toggle (level)
static const int SCYC_IN_ENABLE_BIT       = 684;   // shadow enable
static const int SCYC_IN_DC_REMOVE_BIT    = 685;   // shadow dc_remove
static const int SCYC_IN_CFG_GEN_LSB      = 688;   // [719:688]  shadow generation
static const int SCYC_IN_CFG_RATE_LSB     = 720;   // [751:720]  shadow sample rate
static const int SCYC_IN_CFG_MASK_LSB     = 752;   // [759:752]  shadow valid mask
static const int SCYC_IN_CYCLE_SEQ_LSB    = 768;   // [799:768]  grid cycle sequence
static const int SCYC_IN_NOMINAL_LSB      = 800;   // [807:800]  declared nominal Hz
static const int SCYC_IN_FLAGS_LSB        = 808;   // [810:808]  MET_FLAG_*
static const int SCYC_IN_SAMPLE_IDX_LSB   = 832;   // [895:832]  sample index
static const int SCYC_IN_PL_TICK_LSB      = 896;   // [959:896]  free-running PL tick
static const int SCYC_IN_FREQ_MHZ_LSB     = 960;   // [991:960]  frequency mHz
static const int SCYC_IN_FREQ_STATUS_LSB  = 992;   // [1023:992] frequency status

inline void write_single_cycle_sample_packet(
    const single_cycle_sample_beat_t &beat,
    hls::stream<single_cycle_sample_word_t> &output) {
#pragma HLS INLINE
write_sample_words:
  for (int word = 0; word < SCYC_SAMPLE_PACKET_WORDS; ++word) {
#pragma HLS PIPELINE off
    output.write(beat.range((word + 1) * SCYC_SAMPLE_PACKET_WORD_BITS - 1,
                            word * SCYC_SAMPLE_PACKET_WORD_BITS));
  }
}

#endif  // SINGLE_CYCLE_SAMPLE_PACKET_HPP
