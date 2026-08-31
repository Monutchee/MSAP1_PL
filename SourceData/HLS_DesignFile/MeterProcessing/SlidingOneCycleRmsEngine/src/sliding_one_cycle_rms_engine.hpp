#ifndef SLIDING_ONE_CYCLE_RMS_ENGINE_HPP
#define SLIDING_ONE_CYCLE_RMS_ENGINE_HPP

#include <hls_stream.h>

#include "measurement_record.hpp"
#include "metering_types.hpp"

// The sliding one-cycle RMS / power-quality event engine (metrology M12).
//
// It observes the SAME converted-frame stream the single-cycle engine
// sees — frames are a fan-out, not a stream, so no arbitration exists
// between the two observers — and maintains Urms(1/2): the RMS over one
// grid cycle, refreshed on every HALF-cycle boundary. That is the IEC
// 61000-4-30 detection quantity for dips, swells, and interruptions.
//
// The sliding window is kept with exactly TWO half-cycle accumulators per
// lane: the half being filled and the previous one. At a half-cycle
// boundary the published value is the RMS over their sum, then the halves
// rotate. No sample ring, no rescanning — one square accumulator per lane
// per half, which is why this engine is a fraction of the single-cycle
// engine's cost despite touching every sample.
//
// Square accumulators use the same wide u128 saturating contract as every
// other engine. Converted inputs are 48-bit Q16, so each per-sample square
// is formed exactly at 96 bits and then widened before accumulation.
//
//   s_frame : one beat per accepted converted frame plus the strobes and
//             configuration the hosting shim appends (layout below).
//   m_axis  : PQEVT-v1 records (0x000B0001) on this tier's OWN producer
//             port: periodic heartbeat snapshots, plus an event-start and
//             an event-end record around every declared event. Word map
//             and conventions: measurement_record.hpp / metering_types.hpp.
//
// Detection rules (normative in metering_types.hpp): thresholds are
// fractions of the declared reference Udin; a reference of zero disarms
// detection entirely while snapshots keep flowing; an event begins when
// ANY monitored phase leaves its band and ends only when EVERY phase has
// re-entered it past the hysteresis; the event keeps the most severe type
// it reached and reports the extreme Urms(1/2) of its affected phases.

// ---------------------------------------------------------------------------
// Input beat: the converted frame plus shim-appended strobes, config, and
// PQ thresholds. [MSB:LSB] positions are normative and
// meter_sliding_rms_hls_shim.vhd mirrors them.
// ---------------------------------------------------------------------------
static const int PQIN_SAMPLES_LSB    = 0;    // [383:0]   8 x 48b Q16 samples
static const int PQIN_FRAME_MASK_LSB = 384;  // [391:384] frame valid mask
static const int PQIN_HALF_BIT       = 392;  // frame completes a half cycle
static const int PQIN_MALFORMED_BIT  = 393;  // TKEEP was not all-ones
static const int PQIN_LOCKED_BIT     = 394;  // grid lock (live view)
static const int PQIN_FALLBACK_BIT   = 395;  // half-cycle strobe was synthetic
static const int PQIN_APPLY_BIT      = 396;  // config APPLY toggle (level)
static const int PQIN_ENABLE_BIT     = 397;  // shadow enable
static const int PQIN_CFG_GEN_LSB    = 400;  // [431:400] shadow generation
static const int PQIN_CFG_RATE_LSB   = 432;  // [463:432] shadow sample rate
static const int PQIN_CFG_MASK_LSB   = 464;  // [471:464] shadow valid mask
static const int PQIN_SAMPLE_IDX_LSB = 512;  // [575:512] frame's sample index
static const int PQIN_PL_TICK_LSB    = 576;  // [639:576] free-running PL tick
static const int PQIN_REFERENCE_LSB  = 640;  // [671:640] Udin, micro-volts
static const int PQIN_SAG_LSB        = 672;  // [687:672] sag threshold, 1e-4
static const int PQIN_SWELL_LSB      = 688;  // [703:688] swell threshold, 1e-4
static const int PQIN_INTERRUPT_LSB  = 704;  // [719:704] interruption, 1e-4
static const int PQIN_HYSTERESIS_LSB = 720;  // [735:720] hysteresis, 1e-4
static const int PQIN_BITS           = 736;  // 92 bytes on AXIS

typedef ap_uint<PQIN_BITS> pq_input_beat_t;

// Monitored phases: voltage A/B/C drive detection, current A/B/C ride
// along as fault-context. Index order is A, B, C in both sets.
static const int PQ_PHASES = 3;

// Half-cycle updates between periodic heartbeat records (~1 s at 50 Hz,
// ~0.83 s at 60 Hz). The heartbeat also carries the window's Urms(1/2)
// extremes, so a slow poller still sees excursions that never crossed a
// threshold.
static const int PQ_PERIODIC_UPDATES = 100;

// M18 PQE1 payload emitted at every qualified half-cycle boundary. The PL
// packetizer adds the four-word private header and CRC32C; R5C1 validates this
// exact sufficient-statistic image before running the durable lifecycle state
// machines. All unused words are zero and therefore reserved.
static const int PQE_PAYLOAD_WORDS = 64;
static const int PQE_SEQUENCE_WORD = 0;
static const int PQE_GENERATION_WORD = 1;
static const int PQE_SAMPLE_RATE_WORD = 2;
static const int PQE_STATUS_WORD = 3;
static const int PQE_VALID_PHASES_WORD = 4;
static const int PQE_WINDOW_SAMPLES_WORD = 5;
static const int PQE_FIRST_SAMPLE_LOW_WORD = 6;
static const int PQE_FIRST_SAMPLE_HIGH_WORD = 7;
static const int PQE_LAST_SAMPLE_LOW_WORD = 8;
static const int PQE_LAST_SAMPLE_HIGH_WORD = 9;
static const int PQE_PL_TICK_LOW_WORD = 10;
static const int PQE_PL_TICK_HIGH_WORD = 11;
static const int PQE_URMS_Q16_BASE_WORD = 12; // three little-endian u64 values
static const int PQE_IRMS_Q16_BASE_WORD = 18; // three little-endian u64 values
static const int PQE_REFERENCE_WORD = 24;
static const int PQE_SAG_THRESHOLD_WORD = 25;
static const int PQE_SWELL_THRESHOLD_WORD = 26;
static const int PQE_INTERRUPT_THRESHOLD_WORD = 27;
static const int PQE_HYSTERESIS_WORD = 28;
static const int PQE_APPLY_WORD = 29;

static const int PQE_STATUS_LOCKED_BIT = 0;
static const int PQE_STATUS_FALLBACK_BIT = 1;
static const int PQE_STATUS_DISCONTINUITY_BIT = 2;
static const int PQE_STATUS_ARITHMETIC_BIT = 3;
static const int PQE_STATUS_ENABLED_BIT = 4;
static const int PQE_VALID_VOLTAGE_LSB = 0;
static const int PQE_VALID_CURRENT_LSB = 8;

void hls_sliding_one_cycle_rms_engine(hls::stream<pq_input_beat_t> &s_frame,
                                      hls::stream<record_axis_t> &m_axis,
                                      hls::stream<record_axis_t> &m_pqe);

#endif  // SLIDING_ONE_CYCLE_RMS_ENGINE_HPP
