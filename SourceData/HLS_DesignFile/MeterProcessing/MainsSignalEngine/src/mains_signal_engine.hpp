#ifndef MSAP1_MAINS_SIGNAL_ENGINE_HPP
#define MSAP1_MAINS_SIGNAL_ENGINE_HPP

#include <hls_stream.h>

#include "measurement_record.hpp"
#include "metering_types.hpp"

// M18 dedicated mains-signalling estimator. The engine evaluates one
// configured absolute-frequency carrier on voltage phases A/B/C without
// instantiating or reusing the general harmonic FFT. Seven synchronous
// correlation probes cover the configured band and its two adjacent
// background points over the fixed 200 ms observation interval.

static const int MCSIN_SAMPLES_LSB = 0;       // [383:0], 8 x 48-bit Q16
static const int MCSIN_FRAME_MASK_LSB = 384;  // [391:384]
static const int MCSIN_MALFORMED_BIT = 392;
static const int MCSIN_APPLY_BIT = 393;
static const int MCSIN_ENABLE_BIT = 394;
static const int MCSIN_LOCKED_BIT = 395;
static const int MCSIN_FALLBACK_BIT = 396;
static const int MCSIN_GENERATION_LSB = 400;
static const int MCSIN_SAMPLE_RATE_LSB = 432;
static const int MCSIN_PHASE_MASK_LSB = 464;
static const int MCSIN_CARRIER_MILLIHZ_LSB = 472;
static const int MCSIN_BANDWIDTH_MILLIHZ_LSB = 504;
static const int MCSIN_OBSERVATION_MS_LSB = 536;
static const int MCSIN_THRESHOLD_E4_LSB = 568;
static const int MCSIN_REFERENCE_UV_LSB = 600;
static const int MCSIN_SAMPLE_INDEX_LSB = 632;
static const int MCSIN_BITS = 696;

typedef ap_uint<MCSIN_BITS> mains_signal_input_beat_t;

static const int MCS_PHASES = 3;
static const int MCS_PROBES = 7;
static const int MCS_PAYLOAD_WORDS = 20;
static const int MCS_OBSERVATION_MS = 200;

// Probe offsets are quarters of the configured bandwidth. The five inner
// probes cover [-B/2,+B/2]; the outer pair measure adjacent background at
// -B and +B.
static const int MCS_PROBE_OFFSET_QUARTERS[MCS_PROBES] =
    {-4, -2, -1, 0, 1, 2, 4};

static const int MCS_SEQUENCE_WORD = 0;
static const int MCS_GENERATION_WORD = 1;
static const int MCS_SAMPLE_RATE_WORD = 2;
static const int MCS_STATUS_WORD = 3;
static const int MCS_PHASES_WORD = 4;  // valid [2:0], detected [10:8]
static const int MCS_CONFIGURED_MILLIHZ_WORD = 5;
static const int MCS_MEASURED_MILLIHZ_WORD = 6;
static const int MCS_BANDWIDTH_MILLIHZ_WORD = 7;
static const int MCS_OBSERVATION_MS_WORD = 8;
static const int MCS_FIRST_SAMPLE_LOW_WORD = 9;
static const int MCS_FIRST_SAMPLE_HIGH_WORD = 10;
static const int MCS_LAST_SAMPLE_LOW_WORD = 11;
static const int MCS_LAST_SAMPLE_HIGH_WORD = 12;
static const int MCS_MAGNITUDE_UV_WORD = 13;
static const int MCS_BACKGROUND_UV_WORD = 16;
static const int MCS_THRESHOLD_E4_WORD = 19;

static const int MCS_STATUS_ENABLED_BIT = 0;
static const int MCS_STATUS_LOCKED_BIT = 1;
static const int MCS_STATUS_FALLBACK_BIT = 2;
static const int MCS_STATUS_DISCONTINUITY_BIT = 3;
static const int MCS_STATUS_ARITHMETIC_BIT = 4;
static const int MCS_STATUS_BACKGROUND_DOMINANT_BIT = 5;

void hls_mains_signal_engine(hls::stream<mains_signal_input_beat_t> &s_frame,
                             hls::stream<record_axis_t> &m_mcs);

#endif  // MSAP1_MAINS_SIGNAL_ENGINE_HPP
