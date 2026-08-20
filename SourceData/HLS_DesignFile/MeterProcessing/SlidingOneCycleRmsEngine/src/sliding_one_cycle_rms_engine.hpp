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
// Square accumulators use the same widths as every other engine (u128,
// saturating, sticky flag). Narrower products are NOT safe here: the
// conversion stage saturates a 24-bit sample times a 32-bit scale into a
// full signed 64-bit converted value, so the magnitude bound is the
// 64-bit rail, not the much smaller range a typical 120 V profile uses.
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
static const int PQIN_SAMPLES_LSB    = 0;    // [511:0]  8 x 64b Q16 samples
static const int PQIN_FRAME_MASK_LSB = 512;  // [519:512] frame valid mask
static const int PQIN_HALF_BIT       = 520;  // frame completes a half cycle
static const int PQIN_MALFORMED_BIT  = 521;  // TKEEP was not all-ones
static const int PQIN_LOCKED_BIT     = 522;  // grid lock (live view)
static const int PQIN_FALLBACK_BIT   = 523;  // half-cycle strobe was synthetic
static const int PQIN_APPLY_BIT      = 524;  // config APPLY toggle (level)
static const int PQIN_ENABLE_BIT     = 525;  // shadow enable
static const int PQIN_CFG_GEN_LSB    = 528;  // [559:528] shadow generation
static const int PQIN_CFG_RATE_LSB   = 560;  // [591:560] shadow sample rate
static const int PQIN_CFG_MASK_LSB   = 592;  // [599:592] shadow valid mask
static const int PQIN_SAMPLE_IDX_LSB = 640;  // [703:640] frame's sample index
static const int PQIN_PL_TICK_LSB    = 704;  // [767:704] free-running PL tick
static const int PQIN_REFERENCE_LSB  = 768;  // [799:768] Udin, micro-volts
static const int PQIN_SAG_LSB        = 800;  // [815:800] sag threshold, 1e-4
static const int PQIN_SWELL_LSB      = 816;  // [831:816] swell threshold, 1e-4
static const int PQIN_INTERRUPT_LSB  = 832;  // [847:832] interruption, 1e-4
static const int PQIN_HYSTERESIS_LSB = 848;  // [863:848] hysteresis, 1e-4
static const int PQIN_BITS           = 864;  // 108 bytes on AXIS

typedef ap_uint<PQIN_BITS> pq_input_beat_t;

// Monitored phases: voltage A/B/C drive detection, current A/B/C ride
// along as fault-context. Index order is A, B, C in both sets.
static const int PQ_PHASES = 3;

// Half-cycle updates between periodic heartbeat records (~1 s at 50 Hz,
// ~0.83 s at 60 Hz). The heartbeat also carries the window's Urms(1/2)
// extremes, so a slow poller still sees excursions that never crossed a
// threshold.
static const int PQ_PERIODIC_UPDATES = 100;

void hls_sliding_one_cycle_rms_engine(hls::stream<pq_input_beat_t> &s_frame,
                                      hls::stream<record_axis_t> &m_axis);

#endif  // SLIDING_ONE_CYCLE_RMS_ENGINE_HPP
