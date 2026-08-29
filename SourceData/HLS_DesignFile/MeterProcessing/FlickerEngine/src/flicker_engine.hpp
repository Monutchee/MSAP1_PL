#ifndef MSAP1_FLICKER_ENGINE_HPP
#define MSAP1_FLICKER_ENGINE_HPP

#include <hls_stream.h>

#include "measurement_record.hpp"
#include "metering_types.hpp"

// IEC 61000-4-15:2010 flickermeter front end (M18).
//
// The engine observes converted voltage frames independently of the ordinary
// RMS path. It performs the voltage adaptation, square demodulation, carrier
// rejection, lamp/eye/brain weighting, squaring, and 300 ms memory filter at
// a fixed 2 kSPS internal rate. R5C1 owns the time-at-level percentile, Pst,
// and Plt finalization. No ordinary RMS record is used as a flicker input.
//
// FLK1 is a bounded sufficient-statistic transport. Live packets carry the
// one-second peak Pinst for A/B/C. A completed ten-minute classifier is sent
// as 35 chunks of 15 bins per phase; together those chunks reproduce all 512
// logarithmically arranged classes without approximation at the PL/R5 split.

// Input beat mirrored by meter_flicker_hls_shim.vhd.
static const int FLKIN_SAMPLES_LSB = 0;       // [383:0], 8 x 48-bit Q16
static const int FLKIN_FRAME_MASK_LSB = 384;  // [391:384]
static const int FLKIN_MALFORMED_BIT = 392;
static const int FLKIN_APPLY_BIT = 393;
static const int FLKIN_ENABLE_BIT = 394;
static const int FLKIN_LOCKED_BIT = 395;
static const int FLKIN_FALLBACK_BIT = 396;
static const int FLKIN_GENERATION_LSB = 400;
static const int FLKIN_SAMPLE_RATE_LSB = 432;
static const int FLKIN_PHASE_MASK_LSB = 464;
static const int FLKIN_LAMP_VOLTAGE_LSB = 472;
static const int FLKIN_NOMINAL_HZ_LSB = 488;
static const int FLKIN_LIVE_CADENCE_LSB = 496;
static const int FLKIN_PST_INTERVAL_LSB = 528;
static const int FLKIN_REFERENCE_UV_LSB = 560;
static const int FLKIN_SAMPLE_INDEX_LSB = 592;
static const int FLKIN_BITS = 656;

typedef ap_uint<FLKIN_BITS> flicker_input_beat_t;

static const int FLK_PHASES = 3;
static const int FLK_INTERNAL_RATE_HZ = 2000;
static const int FLK_SETTLING_SECONDS = 10;
static const int FLK_CLASSIFIER_BINS = 512;
static const int FLK_BINS_PER_PACKET = 15;
static const int FLK_CLASSIFIER_CHUNKS =
    (FLK_CLASSIFIER_BINS + FLK_BINS_PER_PACKET - 1) /
    FLK_BINS_PER_PACKET;
static const int FLK_PAYLOAD_WORDS = 64;

static const int FLK_SEQUENCE_WORD = 0;
static const int FLK_GENERATION_WORD = 1;
static const int FLK_SAMPLE_RATE_WORD = 2;
static const int FLK_STATUS_WORD = 3;
static const int FLK_PHASE_MASK_WORD = 4;
static const int FLK_KIND_WORD = 5;
static const int FLK_MODEL_WORD = 6;  // lamp volts [15:0], nominal Hz [23:16]
static const int FLK_TIMING_WORD = 7; // cadence ms [15:0], Pst seconds [31:16]
static const int FLK_HISTOGRAM_BASE_WORD = 8;
static const int FLK_VALID_COUNT_BASE_WORD = 9;
static const int FLK_FIRST_SAMPLE_LOW_WORD = 12;
static const int FLK_FIRST_SAMPLE_HIGH_WORD = 13;
static const int FLK_LAST_SAMPLE_LOW_WORD = 14;
static const int FLK_LAST_SAMPLE_HIGH_WORD = 15;
static const int FLK_PINST_BASE_WORD = 16;
static const int FLK_HISTOGRAM_WORD = 19;

static const int FLK_KIND_LIVE = 0;
static const int FLK_KIND_HISTOGRAM = 1;

static const int FLK_STATUS_ENABLED_BIT = 0;
static const int FLK_STATUS_LOCKED_BIT = 1;
static const int FLK_STATUS_FALLBACK_BIT = 2;
static const int FLK_STATUS_DISCONTINUITY_BIT = 3;
static const int FLK_STATUS_ARITHMETIC_BIT = 4;
static const int FLK_STATUS_CLASSIFIER_OVERFLOW_BIT = 5;
static const int FLK_STATUS_CONTAMINATED_BIT = 6;
static const int FLK_STATUS_SETTLING_BIT = 7;

// 512 monotone, quasi-logarithmic classes: 32 mantissa buckets in each
// octave from Pinst=2^-8 through 2^8. Values outside the classifier are
// clamped and explicitly reported in the packet status.
inline ap_uint<9> flicker_histogram_bin_q16(ap_uint<32> pinst_q16,
                                            ap_uint<1> &outside) {
#pragma HLS INLINE
  outside = 0;
  if (pinst_q16 < ap_uint<32>(1U << 8)) {
    outside = 1;
    return 0;
  }
  if (pinst_q16 >= ap_uint<32>(1U << 24)) {
    outside = 1;
    return FLK_CLASSIFIER_BINS - 1;
  }
  ap_uint<6> msb = 0;
find_msb:
  for (int bit = 0; bit < 32; ++bit) {
#pragma HLS UNROLL
    if (pinst_q16[bit] == 1)
      msb = bit;
  }
  const ap_uint<5> fraction =
      ap_uint<5>((pinst_q16 >> (msb - 5)) & 0x1fU);
  return ap_uint<9>((msb - 8) * 32 + fraction);
}

void hls_flicker_engine(hls::stream<flicker_input_beat_t> &s_frame,
                        hls::stream<record_axis_t> &m_flk);

#endif  // MSAP1_FLICKER_ENGINE_HPP
