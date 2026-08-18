#ifndef MSAP1_MEASUREMENT_RECORD_HPP
#define MSAP1_MEASUREMENT_RECORD_HPP

// metering_types.hpp first: it raises AP_INT_MAX_W before ap_int.h.
#include "metering_types.hpp"

#include <ap_axi_sdata.h>
#include <ap_int.h>
#include <hls_stream.h>

#include <cstdint>

// The measurement record: the one wire format every metrology producer
// emits and the APU decodes.
//
// >>> STATUS: the common envelope (words 0..12) and the MTR1-v3 / MTR2-v2
// >>> interior maps below are the PROPOSED cleaned layouts of the HLS
// >>> rewrite (plan §13 Q4). They must be reviewed against the APU
// >>> decoder (MSAP1_APU common/msap1/meter/meter_record.hpp) and both
// >>> sides updated in the SAME release before any RTL/engine work
// >>> consumes them. Until that review, the deployed v2/v1 maps in
// >>> measurement_record_bus_pkg.vhd remain what the hardware emits.
//
// Framing is positional and fixed: the kernel maps one cyclic-DMA period
// to exactly one 256-byte record (msap1_dma_meter.c) and detects no
// boundary in-band. A short packet leaves stale bytes in the slot
// silently; a long packet phase-shifts the ring permanently. Therefore:
// every record is exactly MREC_WORDS beats of 32 bits, TLAST on the last
// beat, TKEEP always full — no producer may emit anything else, ever.
// serialize_record() below makes that true by construction.

// ---------------------------------------------------------------------------
// Geometry (fixed by the kernel DMA contract — not tunable).
// ---------------------------------------------------------------------------
static const int MREC_WORDS = 64;
static const int MREC_BYTES = 256;

// ---------------------------------------------------------------------------
// Format words (record word 1): record type in [31:16], version in [15:0].
//
// Reservation table — allocate here, never ad hoc, and mirror in the APU's
// meter_record.hpp so PL and software can never race for a format word:
//   0x0001 basic (MTR1)      0x0004 demand
//   0x0002 aggregate (MTR2)  0x0005 harmonics
//   0x0003 energy            0x0006 PQ event
// ---------------------------------------------------------------------------
// Plain integer constants so they can parameterize serialize_record<>.
static const uint32_t MREC_MAGIC = 0x3152544Du;  // ASCII "MTR1", little-endian

static const uint32_t MREC_FORMAT_MTR1_V3 = 0x00010003u;  // proposed (deployed: v2 0x00010002)
static const uint32_t MREC_FORMAT_MTR2_V2 = 0x00020002u;  // proposed (deployed: v1 0x00020001)

// ---------------------------------------------------------------------------
// Common envelope — words 0..12 mean the same thing in EVERY format, so
// the APU needs exactly one accessor set for provenance, continuity and
// transport health regardless of record type.
// ---------------------------------------------------------------------------
static const int MREC_MAGIC_WORD             = 0;   // MREC_MAGIC
static const int MREC_FORMAT_WORD            = 1;   // type/version, table above
static const int MREC_SIZE_WORD              = 2;   // always MREC_BYTES
static const int MREC_SEQUENCE_WORD          = 3;   // per-producer, monotone, wraps mod 2^32
static const int MREC_GENERATION_WORD        = 4;   // committed config generation
static const int MREC_SAMPLE_RATE_WORD       = 5;   // frames/s
static const int MREC_SAMPLE_COUNT_WORD      = 6;   // actual samples this record covers
static const int MREC_VALID_MASK_WORD        = 7;   // [7:0] channel valid mask
static const int MREC_STATUS_WORD            = 8;   // bit 0 common, rest format-defined
static const int MREC_FIRST_SAMPLE_LOW_WORD  = 9;   // 64-bit first-sample timestamp,
static const int MREC_FIRST_SAMPLE_HIGH_WORD = 10;  //   conversion-domain (met_sample_index_t)
static const int MREC_EMIT_DROPS_WORD        = 11;  // records lost between engine and transport
static const int MREC_RESULT_DROPS_WORD      = 12;  // windows the engine missed (must stay 0)

// Words 13..15 are the format-specific header extension; payload starts at
// word 16. Reserved words are zero (clear_record() guarantees it).
static const int MREC_FORMAT_HEADER_WORD = 13;
static const int MREC_PAYLOAD_WORD       = 16;

// Common status bit (both formats today).
static const int MREC_STATUS_ARITHMETIC_BIT = 0;  // any arithmetic overflow

// ---------------------------------------------------------------------------
// MTR1-v3 interior: per-channel basic measurements, frequency block,
// capture diagnostics.
// ---------------------------------------------------------------------------

// Word 13: basic-block timing/provenance word.
static const int MTR1_TIMING_WORD        = 13;
static const int MTR1_TIMING_NOMINAL_LSB = 0;   // [7:0]  declared nominal Hz
static const int MTR1_TIMING_CYCLES_LSB  = 8;   // [15:8] complete cycles in block
static const int MTR1_TIMING_FLAGS_LSB   = 16;  // [18:16] MET_FLAG_* (locked/fallback/first)

// Words 16..55: MET_CHANNEL_LANES x 5 words per channel.
static const int MTR1_CH_BASE_WORD    = MREC_PAYLOAD_WORD;
static const int MTR1_CH_STRIDE_WORDS = 5;
static const int MTR1_CH_MEAN_LOW     = 0;  // signed mean micro-units, low word
static const int MTR1_CH_MEAN_HIGH    = 1;  //   high word
static const int MTR1_CH_RMS_COUNT    = 2;  // unsigned raw ADC RMS counts
static const int MTR1_CH_RMS_LOW      = 3;  // signed RMS micro-units, low word
static const int MTR1_CH_RMS_HIGH     = 4;  //   high word

// Words 56..59: VLA frequency block, sampled at the result event. Bit
// layouts of the status word belong to meter_frequency (FREQUENCY_STATUS
// register) and are not restated here.
static const int MTR1_FREQUENCY_VALUE_WORD    = 56;  // millihertz
static const int MTR1_FREQUENCY_STATUS_WORD   = 57;
static const int MTR1_FREQUENCY_PERIOD_WORD   = 58;  // averaged Q16 period
static const int MTR1_FREQUENCY_SEQUENCE_WORD = 59;  // measurement sequence

// Words 60..63: capture diagnostics, latched at block close.
static const int MTR1_CAPTURE_FRAMES_WORD  = 60;
static const int MTR1_HEADER_ERRORS_WORD   = 61;
static const int MTR1_FIFO_OVERFLOWS_WORD  = 62;
static const int MTR1_ADC_ALERTS_WORD      = 63;

// ---------------------------------------------------------------------------
// MTR2-v2 interior: the 150/180-cycle fundamental aggregate.
// ---------------------------------------------------------------------------

// Word 13: interval shape.
static const int MTR2_SHAPE_WORD        = 13;
static const int MTR2_SHAPE_BLOCKS_LSB  = 0;   // [7:0]  basic blocks folded (15)
static const int MTR2_SHAPE_NOMINAL_LSB = 8;   // [15:8] nominal Hz
static const int MTR2_SHAPE_CYCLES_LSB  = 16;  // [31:16] total cycles (150/180)

// Words 14/15: the folded basic-sequence range, making the MTR1/MTR2
// stream relationship explicit.
static const int MTR2_FIRST_BASIC_SEQ_WORD = 14;
static const int MTR2_LAST_BASIC_SEQ_WORD  = 15;

// Words 16..31: MET_CHANNEL_LANES x 2 words of aggregate RMS in signed
// 64-bit micro-units.
static const int MTR2_CH_BASE_WORD    = MREC_PAYLOAD_WORD;
static const int MTR2_CH_STRIDE_WORDS = 2;

// Word 32: arithmetic mean of the 15 sampled frequencies, millihertz
// (diagnostic only — the Class A frequency product has its own interval
// and is not implemented in this tier).
static const int MTR2_FREQUENCY_WORD = 32;

// Both channel blocks span exactly the eight record lanes.
static_assert(MTR1_CH_BASE_WORD + MET_CHANNEL_LANES * MTR1_CH_STRIDE_WORDS ==
                  MTR1_FREQUENCY_VALUE_WORD,
              "MTR1 channel block must abut the frequency block");
static_assert(MTR2_CH_BASE_WORD + MET_CHANNEL_LANES * MTR2_CH_STRIDE_WORDS ==
                  MTR2_FREQUENCY_WORD,
              "MTR2 channel block must abut the frequency word");

// Words 33..35: engine diagnostics as of this emit (the counters that
// also back the AGG_* AXI-Lite registers).
static const int MTR2_RESET_COUNT_WORD      = 33;  // partial aggregates discarded
static const int MTR2_INELIGIBLE_COUNT_WORD = 34;  // basic inputs rejected
static const int MTR2_CONTINUITY_COUNT_WORD = 35;  // sequence/sample-range breaks

// MTR2 status bits (word 8), beyond the common arithmetic bit.
static const int MTR2_STATUS_COMPLETE_BIT  = 1;  // always set — only complete aggregates emit
static const int MTR2_STATUS_FREQUENCY_BIT = 2;  // all 15 frequency inputs were valid

// ---------------------------------------------------------------------------
// Record image and AXIS serialization.
// ---------------------------------------------------------------------------

// A record under construction: engines fill named words, then hand the
// image to serialize_record(). Cheap to hold — one per producer, built
// once per record period (>= 200 ms).
struct record_image_t {
  ap_uint<32> word[MREC_WORDS];
};

// One 32-bit AXIS beat. This must be the hls::axis side-channel type
// (ap_axiu), NOT a plain struct: on an `#pragma HLS INTERFACE axis` port a
// plain aggregate is packed wholesale into TDATA, which would smear
// keep/last into the data bits. ap_axiu<32,0,0,0> maps data/keep/strb/last
// onto TDATA/TKEEP/TSTRB/TLAST. Records are never sparse, so keep and strb
// are constant full.
typedef ap_axiu<32, 0, 0, 0> record_axis_t;
static const ap_uint<4> MREC_KEEP_ALL = 0xF;

typedef hls::stream<record_axis_t> record_axis_stream_t;

// Zero every word. Call before filling so reserved words are zero by
// construction rather than by author discipline.
// Fill the format-independent envelope words (3..10) every producer
// writes identically: sequence, generation, sample rate, sample count,
// valid mask, status, and the 64-bit first-sample timestamp. Words 0..2
// (magic/format/size) are stamped by serialize_record; words 11/12
// (emit/result drops) stay with the producer -- their semantics are
// per-engine even when the value is constant zero.
inline void fill_envelope(record_image_t &image, const ap_uint<32> sequence,
                          const ap_uint<32> generation,
                          const ap_uint<32> sample_rate_hz,
                          const ap_uint<32> sample_count,
                          const ap_uint<8> valid_mask,
                          const ap_uint<32> status,
                          const ap_uint<64> first_sample) {
#pragma HLS INLINE
  image.word[MREC_SEQUENCE_WORD] = sequence;
  image.word[MREC_GENERATION_WORD] = generation;
  image.word[MREC_SAMPLE_RATE_WORD] = sample_rate_hz;
  image.word[MREC_SAMPLE_COUNT_WORD] = sample_count;
  image.word[MREC_VALID_MASK_WORD] = ap_uint<32>(valid_mask);
  image.word[MREC_STATUS_WORD] = status;
  image.word[MREC_FIRST_SAMPLE_LOW_WORD] = first_sample.range(31, 0);
  image.word[MREC_FIRST_SAMPLE_HIGH_WORD] = first_sample.range(63, 32);
}

inline void clear_record(record_image_t &image) {
#pragma HLS INLINE
mrec_clear:
  for (int w = 0; w < MREC_WORDS; ++w) {
#pragma HLS PIPELINE II = 1
    image.word[w] = 0;
  }
}

// Emit one complete record as exactly MREC_WORDS beats, TLAST on the last
// beat, TKEEP full — the DMA-ring framing invariant made structural. The
// magic/format/size envelope words are stamped here from the template
// parameter, so a buggy builder cannot emit a record that mis-identifies
// itself (INV-2 of the verification plan, by construction).
//
// Blocking writes: call this only from an emit process that is decoupled
// from measurement by an internal result stream (the never-backpressure
// rule, plan §5.2). A mid-record stall then bounds at the transport FIFO
// drain time and can never reach the accumulation side.
template <uint32_t FORMAT>
void serialize_record(record_image_t &image, record_axis_stream_t &m_axis) {
  image.word[MREC_MAGIC_WORD]  = MREC_MAGIC;
  image.word[MREC_FORMAT_WORD] = ap_uint<32>(FORMAT);
  image.word[MREC_SIZE_WORD]   = MREC_BYTES;
mrec_serialize:
  for (int w = 0; w < MREC_WORDS; ++w) {
#pragma HLS PIPELINE II = 1
    record_axis_t beat;
    beat.data = image.word[w];
    beat.keep = MREC_KEEP_ALL;
    beat.strb = MREC_KEEP_ALL;
    beat.last = (w == MREC_WORDS - 1) ? ap_uint<1>(1) : ap_uint<1>(0);
    m_axis.write(beat);
  }
}

#endif  // MSAP1_MEASUREMENT_RECORD_HPP
