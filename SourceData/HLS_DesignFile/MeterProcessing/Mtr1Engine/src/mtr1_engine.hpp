#ifndef MTR1_ENGINE_HPP
#define MTR1_ENGINE_HPP

#include <hls_stream.h>

#include "basic_result_beat.hpp"
#include "measurement_record.hpp"
#include "metering_types.hpp"

// The MTR1 basic measurement engine (normative source). It is the HLS
// rewrite of the retired VHDL pair meter_rms.vhd + MeterResultHub_Wrapper
// (both in git history): per-channel accumulation over one IEC 61000-4-30
// basic block, block finalization (mean, mean-corrected RMS, raw-count
// RMS), MTR1-v3 record construction, and AXIS serialization — one
// component, three streams.
//
//   s_sample  : one beat per accepted converted frame (layout below),
//               assembled by meter_mtr1_hls_shim.vhd in lock step.
//   m_axis    : complete MTR1-v3 records, exactly MREC_WORDS x 32-bit
//               beats, TLAST on the last beat (serialize_record).
//   m_result  : one basic_result_beat_t per finalized block — the input
//               contract of the 150/180-cycle aggregator.
//
// Arithmetic contract (pinned to meter_rms.vhd, floor/truncate semantics):
//   sum        : signed 128-bit accumulation of 64-bit Q16 samples
//   square     : unsigned 128-bit accumulation of sample^2, SATURATING to
//                all-ones with the sticky arithmetic flag on carry-out
//   raw sum    : signed 64-bit accumulation of 32-bit raw samples
//   raw square : unsigned 96-bit accumulation of raw^2 (cannot overflow)
//   mean       : sign-magnitude division floor(|sum|/N) truncated to 64
//                bits, then negated when sum < 0 (truncation toward zero,
//                and the truncation to 64 bits happens BEFORE negation)
//   variance   : (square*N [160-bit, saturate+flag if >= 2^128]
//                 - |sum|(63:0)^2 when dc_remove, with flag+clamp rules)
//                / N^2, floor
//   rms        : floor(sqrt(variance)), exact 128->64 restoring root
//   raw path   : same variance/root recurrence on the raw accumulators;
//                the record carries the low 32 bits of the raw root
//   units      : record mean/RMS words are Q16 >> 16, arithmetic shift
// The sticky arithmetic flag survives until the next APPLY (record status
// word bit 0), exactly like the RTL.
//
// Window rules (pinned to meter_rms.vhd):
//   - cycle mode: the block closes on the beat whose closes_block flag is
//     set (grid_cycle_timing decides; the engine never re-derives IEC
//     boundaries). Legacy mode: the block closes when the accumulated
//     count reaches the configured window.
//   - a malformed or stale-generation frame (while enabled) discards the
//     running window;
//   - configuration commits when the beat-sampled APPLY toggle changes:
//     accumulators clear, the sticky flag clears, and the carrying
//     beat's frame is then processed under the NEW configuration (it
//     accumulates only if its generation tag already matches — the
//     stale guard rejects it otherwise). Discarding it instead would
//     skew the first post-APPLY block by one frame against
//     grid_cycle_timing's block accounting;
//   - every closed window is finalized: the closing invocation runs the
//     whole finalize + emission inline (single-shot process, the
//     CycleAggregator pattern), so the retired RTL's calc-busy window
//     drop has no equivalent and result_drops (record word 12) is
//     constant 0. While finalizing (~15 us measured) the engine does
//     not accept beats; the VHDL shim's beat FIFO absorbs incoming
//     frames (8 deep covers the 128 kSPS capture ceiling) and counts a
//     drop if it ever overflows, so measurement itself is never stalled
//     and loss is never silent.
//
// Accepted divergences from the retired RTL (same class as the
// aggregator's documented APPLY races; none reachable at product rates):
//   1. Frequency words (56..59) and capture diagnostics (60..63) are
//      latched at BLOCK CLOSE, not at result emission ~40 us later, so
//      they can lag the RTL's values by at most one asynchronous update.
//   2. An APPLY that lands during a window's finalization is observed on
//      the next consumed beat, after the result has been emitted (old
//      generation, APU-rejected as stale); the RTL discarded such an
//      in-flight result silently.
//   3. The RTL's defensive clear also flushed two in-flight pipeline
//      frames around a malformed/stale frame; here exactly the accepted
//      frames accumulate.
//   4. APPLY is observed on the next sample beat, not between frames; the
//      stream idles only when capture is stopped, where the first block
//      after restart is flagged/ineligible anyway.
//   5. A window closing while the engine is still finalizing the previous
//      one is finalized late, never dropped (the RTL counted a drop);
//      the cost is bounded shim-FIFO occupancy, not data loss.

// ---------------------------------------------------------------------------
// Input beat: one converted frame plus the levels and close-latched
// context that travel with it (shim-packed). Every field is byte aligned;
// [MSB:LSB] positions are normative and meter_mtr1_hls_shim.vhd mirrors
// them.
//
// The provenance/frequency/capture fields (bits 920..1263) are sampled by
// the shim on every beat but are MEANINGFUL on a closing beat: they are
// grid_cycle_timing's latched values for the block that beat closes,
// stable until the next close.
// ---------------------------------------------------------------------------
static const int MTR1_IN_SAMPLES_LSB      = 0;     // [511:0]   8 x 64b Q16 converted
static const int MTR1_IN_RAW_LSB          = 512;   // [767:512] 8 x 32b raw samples
static const int MTR1_IN_FRAME_MASK_LSB   = 768;   // [775:768] frame valid mask
static const int MTR1_IN_FRAME_GEN_LSB    = 776;   // [807:776] frame's generation tag
static const int MTR1_IN_MALFORMED_BIT    = 808;   // TKEEP was not all-ones
static const int MTR1_IN_CLOSES_BIT       = 809;   // frame closes the basic block
static const int MTR1_IN_CYCLE_MODE_BIT   = 810;   // grid cycle mode active (level)
static const int MTR1_IN_APPLY_BIT        = 811;   // config APPLY toggle (level)
static const int MTR1_IN_ENABLE_BIT       = 812;   // shadow enable (latched at APPLY)
static const int MTR1_IN_DC_REMOVE_BIT    = 813;   // shadow dc_remove (latched at APPLY)
static const int MTR1_IN_CFG_GEN_LSB      = 816;   // [847:816]  shadow generation
static const int MTR1_IN_CFG_RATE_LSB     = 848;   // [879:848]  shadow sample rate
static const int MTR1_IN_CFG_WINDOW_LSB   = 880;   // [911:880]  shadow window samples
static const int MTR1_IN_CFG_MASK_LSB     = 912;   // [919:912]  shadow valid mask
static const int MTR1_IN_FIRST_SAMPLE_LSB = 920;   // [983:920]  block first sample
static const int MTR1_IN_CYCLE_COUNT_LSB  = 984;   // [991:984]  block cycle count
static const int MTR1_IN_NOMINAL_LSB      = 992;   // [999:992]  declared nominal Hz
static const int MTR1_IN_BLOCK_FLAGS_LSB  = 1000;  // [1002:1000] MTR_FLAG_*
static const int MTR1_IN_FREQ_MHZ_LSB     = 1008;  // [1039:1008] frequency millihertz
static const int MTR1_IN_FREQ_STATUS_LSB  = 1040;  // [1071:1040] frequency status word
static const int MTR1_IN_FREQ_PERIOD_LSB  = 1072;  // [1103:1072] averaged Q16 period
static const int MTR1_IN_FREQ_SEQ_LSB     = 1104;  // [1135:1104] frequency meas. sequence
static const int MTR1_IN_CAP_FRAMES_LSB   = 1136;  // [1167:1136] capture frame count
static const int MTR1_IN_CAP_HDRERR_LSB   = 1168;  // [1199:1168] capture header errors
static const int MTR1_IN_CAP_OVERFLOW_LSB = 1200;  // [1231:1200] capture FIFO overflows
static const int MTR1_IN_CAP_ALERTS_LSB   = 1232;  // [1263:1232] ADC alert count
static const int MTR1_IN_BITS             = 1264;  // 158 bytes on AXIS

typedef ap_uint<MTR1_IN_BITS> mtr1_sample_beat_t;

// FREQUENCY_STATUS bit consumed for the basic result beat's
// frequency_valid (meter_frequency_pkg FREQUENCY_STATUS_VALID).
static const int MTR1_FREQ_STATUS_VALID_BIT = 1;

void hls_mtr1_engine(hls::stream<mtr1_sample_beat_t> &s_sample,
                     hls::stream<record_axis_t> &m_axis,
                     hls::stream<basic_result_beat_t> &m_result);

#endif  // MTR1_ENGINE_HPP
