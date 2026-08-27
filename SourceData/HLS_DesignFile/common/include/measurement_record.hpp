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
//   0x0007 power             0x000A single-cycle diagnostic
//   0x0008 phasor            0x000B sliding RMS / PQ trigger
//   0x0009 unbalance         0x000C..0x000F 10-min/2-h/flicker/mains
//   0x0010 aggregate power   0x0012 aggregate unbalance
//   0x0011 aggregate phasor
// ---------------------------------------------------------------------------
// Plain integer constants so they can parameterize serialize_record<>.
static const uint32_t MREC_MAGIC = 0x3152544Du;  // ASCII "MTR1", little-endian

static const uint32_t MREC_FORMAT_MTR1_V3 = 0x00010003u;  // proposed (deployed: v2 0x00010002)
static const uint32_t MREC_FORMAT_MTR2_V2 = 0x00020002u;  // proposed (deployed: v1 0x00020001)
static const uint32_t MREC_FORMAT_SCYC_V4 = 0x000A0004u;  // single-cycle diagnostic
// v5 (M6): status-word bits 2..4 gain meaning (first-after-gap and its
// causes) and every emitted result is a whole cycle (partial windows
// after reset/APPLY/abort are suppressed, not emitted).
static const uint32_t MREC_FORMAT_SCYC_V5 = 0x000A0005u;  // single-cycle diagnostic
// BASIC v4 (M7): the 10/12-cycle tier record emitted by
// Agg10_12MeasurementEngine, which merges SingleCycleResults and retires
// Mtr1Engine. Interior identical to MTR1-v3 for the envelope, timing
// word, the 7 active per-lane slots, and words 56..63 (the retirement
// proof); the differences are additive:
//   words 14/15      : block last-sample index (low/high) -- the tier's
//                      own measurement-span anchor (was zero in MTR1-v3)
//   words 51/52/53   : VAB/VBC/VCA RMS, micro-units, 32-bit (the unused
//                      lane-7 slot; line-line stats merge from the
//                      single-cycle difference accumulators)
//   words 54/55      : reserved zero
//   status word bit 2: first block after a discontinuity (upstream gap,
//                      APPLY, or reset), mirroring the SCYC-v5 contract
static const uint32_t MREC_FORMAT_BASIC_V4 = 0x00010004u;  // 10/12-cycle basic
// POWER v1 (M8): emitted by Agg10_12CycleEngine on the SAME stream as
// BASIC-v4, immediately after it, describing the same block (same
// sequence, generation, first/last sample, status). Per phase: active
// power P (signed, picowatts, import positive), apparent power S
// (unsigned, pico-VA, S = Vrms x Irms), true power factor PF (signed,
// millionths, sign follows P, 0 when S is 0 -- consumers must treat
// S == 0 as PF-undefined). Totals: P and S are arithmetic sums over the
// three phases; PF_total = P_total / S_total (never an average of phase
// PFs). Crest factors: per lane, peak/RMS in ten-thousandths, peak =
// max(|min|, |max|) of the merged per-cycle extrema, RMS as finalized
// under the committed dc_remove; 0 when the RMS is 0.
static const uint32_t MREC_FORMAT_POWER_V1 = 0x00070001u;  // 10/12-cycle power
// PHASOR v1 (M9): third record of the block, same stream, immediately
// after POWER-v1, same correlation fields. Fundamental (synchronous-
// correlation) quantities only. Per lane: fundamental RMS (micro-units)
// and phase angle (millidegrees, RELATIVE TO VA — VA reads exactly 0;
// see the angle conventions in metering_types.hpp). Line-line phasors
// are the complex differences of the finalized lane phasors (VAB =
// VA - VB etc.), never sqrt(3) scalings. Per phase: V-I displacement
// angle phi1, fundamental active power P1 (signed picowatts), reactive
// power Q1 (signed picovars, lagging/inductive POSITIVE — the exact
// phasor cross product), displacement PF (millionths, sign follows P1,
// 0 = undefined when the fundamental apparent power S1 = V1 x I1 is 0),
// and a load-nature code (MET_NATURE_*, classified from Q1's sign).
// Totals are arithmetic sums; total displacement PF = P1_tot / S1_tot.
// Status bit 1: at least one merged cycle had no usable frequency
// reference (SCYC phasor-invalid) — every phasor word is then suspect.
// v2 (M11 follow-up): angle words switched from signed [-180000,
// 180000) to the unsigned [0, 360000) industry convention.
static const uint32_t MREC_FORMAT_PHASOR_V2 = 0x00080002u;  // 10/12-cycle phasor
// UNBALANCE v1 (M10): fourth record of each block, same stream, same
// correlation fields. Symmetrical components of the fundamental phasors
// (a-operator conventions in metering_types.hpp): zero/positive/negative
// sequence RMS (u32 micro-units) and angle (s32 millidegrees relative to
// VA) for voltage (VA/VB/VC) and current (IA/IB/IC, never IN), plus the
// zero-sequence ratios |X0|/|X1| and unbalance ratios UNBL = |X2|/|X1|
// in millionths (0 + flag clear = undefined when |X1| = 0, clamped at
// the u32 rail — an ACB feed drives them off scale by design). Flags
// word: per-set ratio validity + the M9 angle-reference flag. Status
// bit 1 mirrors the PHASOR record (frequency-reference loss poisons the
// same correlation these components come from).
// v2: angle words in the unsigned [0, 360000) convention (see PHASOR).
static const uint32_t MREC_FORMAT_UNBAL_V2 = 0x00090002u;  // 10/12-cycle unbalance
// AGG v3 (M11): the 150/180-cycle tier record emitted by
// Agg150_180CycleEngine, which merges Agg10_12Result block accumulators
// and retires Mtr2Engine + the 808-bit basic_result_beat. Interior keeps
// the MTR2-v2 map (shape word 13, folded-sequence range 14/15, per-lane
// RMS 16..31, mean frequency 32, diagnostics 33..35) with additive
// changes:
//   words 36/37 : the interval's last-sample index (low/high)
//   words 38..40: VAB/VBC/VCA aggregate RMS, micro-units, 32-bit
// SEMANTIC upgrade vs MTR2-v2 (pre-production, no compat): per-lane RMS
// is finalized from the summed RAW accumulators over the whole interval
// (mean-corrected under the committed dc_remove, sample-weighted) — no
// longer sqrt(mean of the 15 block-RMS squares). Golden equivalence, not
// bit-identity, is the acceptance rule.
static const uint32_t MREC_FORMAT_AGG_V3 = 0x00020003u;  // 150/180-cycle basic
// AGG-POWER/PHASOR/UNBAL v1 (M11): the aggregate tier's companions,
// emitted back to back after each AGG-v3 record on the same stream with
// the same sequence/anchors/status. Their PAYLOAD word maps are
// IDENTICAL to the basic-period POWER-v1 / PHASOR-v1 / UNBAL-v1 maps
// (words 16+); the format-header extension differs: word 13 carries the
// MTR2 shape word and words 14/15 the folded basic-sequence range,
// mirroring AGG-v3. Only the format word tells the periods apart — the
// records interleave on ONE DMA stream.
static const uint32_t MREC_FORMAT_AGG_POWER_V1  = 0x00100001u;
static const uint32_t MREC_FORMAT_AGG_PHASOR_V2 = 0x00110002u;
static const uint32_t MREC_FORMAT_AGG_UNBAL_V2  = 0x00120002u;
// TEN-MINUTE v1 (M13): clock-aligned IEC aggregation of consecutive
// eligible 10/12-cycle blocks.  These four records share the aggregate
// output stream with the 150/180-cycle family; the format word is the
// period discriminator.  Frequency is deliberately unavailable here:
// the standardized 10 s frequency product is a separate direct-cycle
// calculation and must not be inferred from this interval.
static const uint32_t MREC_FORMAT_TEN_MINUTE_V1        = 0x000C0001u;
static const uint32_t MREC_FORMAT_TEN_MINUTE_POWER_V1  = 0x00130001u;
static const uint32_t MREC_FORMAT_TEN_MINUTE_PHASOR_V2 = 0x00140002u;
static const uint32_t MREC_FORMAT_TEN_MINUTE_UNBAL_V2  = 0x00150002u;
// TWO-HOUR v1 (M14): cascaded aggregation of exactly twelve complete,
// aligned TEN-MINUTE intervals.  The payload layout deliberately matches the
// ten-minute family so the APU can share one long-period decoder; only the
// format word and the shape count identify the period.  Frequency remains a
// separate direct-cycle product and is therefore unavailable here too.
static const uint32_t MREC_FORMAT_TWO_HOUR_V1        = 0x000D0001u;
static const uint32_t MREC_FORMAT_TWO_HOUR_POWER_V1  = 0x00160001u;
static const uint32_t MREC_FORMAT_TWO_HOUR_PHASOR_V2 = 0x00170002u;
static const uint32_t MREC_FORMAT_TWO_HOUR_UNBAL_V2  = 0x00180002u;
// M15 live-partial records. These are operational previews of the open
// accumulator images, not normative IEC interval results. Their layouts are
// identical to the completed long-period families so consumers can share the
// decoder, while the distinct format IDs and status flags prevent an open
// result from replacing or masquerading as a completed result.
static const uint32_t MREC_FORMAT_OPEN_TEN_MINUTE_V1        = 0x000E0001u;
static const uint32_t MREC_FORMAT_OPEN_TEN_MINUTE_POWER_V1  = 0x00190001u;
static const uint32_t MREC_FORMAT_OPEN_TEN_MINUTE_PHASOR_V2 = 0x001A0002u;
static const uint32_t MREC_FORMAT_OPEN_TEN_MINUTE_UNBAL_V2  = 0x001B0002u;
static const uint32_t MREC_FORMAT_OPEN_TWO_HOUR_V1        = 0x000F0001u;
static const uint32_t MREC_FORMAT_OPEN_TWO_HOUR_POWER_V1  = 0x001C0001u;
static const uint32_t MREC_FORMAT_OPEN_TWO_HOUR_PHASOR_V2 = 0x001D0002u;
static const uint32_t MREC_FORMAT_OPEN_TWO_HOUR_UNBAL_V2  = 0x001E0002u;
// HARMONIC v1 (M16): one complete 10/12-cycle spectrum is a family of
// channel/chunk records with one shared sequence and common envelope.  Each
// record carries up to 24 consecutive orders as packed 64-bit entries.  The
// producer emits six chunks for every active product lane (CH0..CH6), orders
// 1..127; CH7 remains outside the product harmonic family.
static const uint32_t MREC_FORMAT_HARMONIC_V1 = 0x00050001u;
/* R5C1 magnitude-only harmonic family for 3 s, 10 min, and 2 h periods. */
static const uint32_t MREC_FORMAT_HARMONIC_AGG_V1 = 0x001F0001u;
// PQEVT v1 (M12): the sliding Urms(1/2) tier's record, emitted by
// SlidingOneCycleRmsEngine on its OWN producer port (M_AXIS_PQ). Three
// kinds share the format, distinguished by the format-header word 13:
// a periodic heartbeat snapshot, an event-start record (emitted the
// moment an event is declared, so a long interruption is visible while
// it is still happening), and an event-end record carrying the finished
// event's duration and residual/peak. Conventions — threshold units,
// the polyphase begin/end rule, severity, and residual/peak selection —
// are normative in metering_types.hpp.
static const uint32_t MREC_FORMAT_PQEVT_V1 = 0x000B0001u;

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

// HARMONIC-v1 interior.  Word 13 is intentionally range-shaped rather than
// hard-coded to six chunks so a later record producer may extend max_order
// without changing the record format:
//   [2:0]   channel (0..6)
//   [6:3]   zero-based chunk index
//   [14:7]  first order in this chunk
//   [19:15] number of entries (1..24)
//   [23:20] chunks in this channel family
//   [31:24] maximum order produced by this family
// Word 14 is the mean measured fundamental frequency in millihertz.
// Word 15 packs qualified_max_order, nominal_frequency_hz, cycle_count, and
// filter_profile_id in successive bytes.
// Words 16..63 contain 24 little-endian 64-bit entries:
//   [39:0]  subgroup RMS magnitude, channel micro-units
//   [59:40] central-line angle, millidegrees in [0, 360000)
//   [60]    magnitude valid
//   [61]    angle valid
//   [63:62] reserved zero
static const int HARMONIC_HEADER_WORD = 13;
static const int HARMONIC_FREQUENCY_WORD = 14;
static const int HARMONIC_METADATA_WORD = 15;
static const int HARMONIC_ENTRY_BASE_WORD = 16;
static const int HARMONIC_ORDERS_PER_RECORD = 24;
static const int HARMONIC_MAX_ORDER_V1 = 127;
static const int HARMONIC_CHUNKS_PER_CHANNEL_V1 = 6;
static const int HARMONIC_CHANNELS_V1 = 7;

static const int HARMONIC_HEADER_CHANNEL_LSB = 0;
static const int HARMONIC_HEADER_CHUNK_LSB = 3;
static const int HARMONIC_HEADER_FIRST_ORDER_LSB = 7;
static const int HARMONIC_HEADER_ORDER_COUNT_LSB = 15;
static const int HARMONIC_HEADER_CHUNK_COUNT_LSB = 20;
static const int HARMONIC_HEADER_MAX_ORDER_LSB = 24;

static const int HARMONIC_META_QUALIFIED_MAX_LSB = 0;
static const int HARMONIC_META_NOMINAL_HZ_LSB = 8;
static const int HARMONIC_META_CYCLE_COUNT_LSB = 16;
static const int HARMONIC_META_FILTER_PROFILE_LSB = 24;

static const int HARMONIC_ENTRY_MAGNITUDE_BITS = 40;
static const int HARMONIC_ENTRY_ANGLE_LSB = 40;
static const int HARMONIC_ENTRY_ANGLE_BITS = 20;
static const int HARMONIC_ENTRY_MAGNITUDE_VALID_BIT = 60;
static const int HARMONIC_ENTRY_ANGLE_VALID_BIT = 61;

static const int HARMONIC_STATUS_COMPLETE_BIT = 1;
static const int HARMONIC_STATUS_GRID_LOCKED_BIT = 2;
static const int HARMONIC_STATUS_CONDITIONER_VALID_BIT = 3;
static const int HARMONIC_STATUS_FFT_VALID_BIT = 4;
static const int HARMONIC_STATUS_FULL_RANGE_BIT = 5;
static const int HARMONIC_STATUS_FIRST_AFTER_DISCONTINUITY_BIT = 6;
static const int HARMONIC_STATUS_RATE_LIMITED_BIT = 7;

// ---------------------------------------------------------------------------
// MTR1-v3 interior: per-channel basic measurements, frequency block,
// capture diagnostics.
// ---------------------------------------------------------------------------

// Word 13: basic-block timing/provenance word.
static const int MTR1_TIMING_WORD        = 13;
static const int MTR1_TIMING_NOMINAL_LSB = 0;   // [7:0]  declared nominal Hz
static const int MTR1_TIMING_CYCLES_LSB  = 8;   // [15:8] complete cycles in block
static const int MTR1_TIMING_FLAGS_LSB   = 16;  // [18:16] MET_FLAG_* (locked/fallback/first)
// Additive M15 provenance.  The format IDs stay unchanged: older readers
// already ignore the formerly-reserved upper timing bits.
static const int MTR1_TIMING_UTC_RESYNCHRONIZED_BIT = 19;

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
// POWER-v1 interior (envelope words 0..12 shared; timing word 13 and the
// last-sample anchor 14/15 mirror BASIC-v4).
static const int POWER_PHASE_BASE_WORD   = 16;  // A, then B, C
static const int POWER_PHASE_STRIDE      = 5;
static const int POWER_PHASE_P_LOW       = 0;   // s64 picowatts
static const int POWER_PHASE_P_HIGH      = 1;
static const int POWER_PHASE_S_LOW       = 2;   // u64 pico-VA
static const int POWER_PHASE_S_HIGH      = 3;
static const int POWER_PHASE_PF          = 4;   // s32 millionths
static const int POWER_TOTAL_P_LOW_WORD  = 31;
static const int POWER_TOTAL_P_HIGH_WORD = 32;
static const int POWER_TOTAL_S_LOW_WORD  = 33;
static const int POWER_TOTAL_S_HIGH_WORD = 34;
static const int POWER_TOTAL_PF_WORD     = 35;
static const int POWER_CREST_BASE_WORD   = 36;  // 7 x u32, crest x 1e4

// BASIC-v4 additions on top of the MTR1 map (see the format note above).
static const int BASIC_LAST_SAMPLE_LOW_WORD  = 14;
static const int BASIC_LAST_SAMPLE_HIGH_WORD = 15;
static const int BASIC_VLL_BASE_WORD         = 51;  // 3 x 32-bit micro-units

// PHASOR-v1 interior (envelope words 0..12 shared; timing word 13 and
// the last-sample anchor 14/15 mirror BASIC-v4). Angle words are u32
// millidegrees in [0, 360000), relative to VA (metering_types.hpp).
static const int PHASOR_CH_BASE_WORD    = 16;  // 7 lanes, hardware order
static const int PHASOR_CH_STRIDE       = 2;
static const int PHASOR_CH_FUND_RMS     = 0;   // u32 micro-units
static const int PHASOR_CH_ANGLE        = 1;   // u32 millidegrees
static const int PHASOR_VLL_BASE_WORD   = 30;  // 3 pairs (AB, BC, CA), same
static const int PHASOR_VLL_STRIDE      = 2;   //   {fund RMS, angle} shape
static const int PHASOR_DISP_BASE_WORD  = 36;  // 3 x u32 phi1 (A, B, C)
static const int PHASOR_Q1_BASE_WORD    = 39;  // 3 x s64 picovars (lo/hi)
static const int PHASOR_Q1_TOTAL_LOW_WORD  = 45;
static const int PHASOR_Q1_TOTAL_HIGH_WORD = 46;
static const int PHASOR_DPF_BASE_WORD   = 47;  // 3 x s32 millionths
static const int PHASOR_DPF_TOTAL_WORD  = 50;
static const int PHASOR_FLAGS_WORD      = 51;  // natures + reference flag:
static const int PHASOR_FLAGS_NATURE_A_LSB     = 0;  // [1:0] MET_NATURE_*
static const int PHASOR_FLAGS_NATURE_B_LSB     = 2;  // [3:2]
static const int PHASOR_FLAGS_NATURE_C_LSB     = 4;  // [5:4]
static const int PHASOR_FLAGS_NATURE_TOTAL_LSB = 6;  // [7:6]
static const int PHASOR_FLAGS_REF_VALID_BIT    = 8;  // VA angle reference usable
static const int PHASOR_P1_BASE_WORD    = 52;  // 3 x s64 picowatts (lo/hi)
static const int PHASOR_P1_TOTAL_LOW_WORD  = 58;
static const int PHASOR_P1_TOTAL_HIGH_WORD = 59;
// Words 60..63 reserved zero.

// PHASOR-v1 status bit (word 8), beyond the common arithmetic bit.
static const int PHASOR_STATUS_INVALID_BIT = 1;  // a merged cycle lacked a
                                                 //   frequency reference

// UNBALANCE-v1 interior (envelope words 0..12 shared; timing word 13 and
// the last-sample anchor 14/15 mirror BASIC-v4). Sequence order within
// each set: zero, positive, negative.
static const int UNBAL_V_BASE_WORD   = 16;  // 3 x {rms u32, angle s32}
static const int UNBAL_I_BASE_WORD   = 22;  // 3 x {rms u32, angle s32}
static const int UNBAL_SEQ_STRIDE    = 2;
static const int UNBAL_SEQ_RMS       = 0;   // u32 micro-units
static const int UNBAL_SEQ_ANGLE     = 1;   // u32 millidegrees (rel. VA)
static const int UNBAL_V_ZERO_RATIO_WORD = 28;  // |V0|/|V1|, millionths
static const int UNBAL_V_UNBALANCE_WORD  = 29;  // |V2|/|V1|, millionths
static const int UNBAL_I_ZERO_RATIO_WORD = 30;  // |I0|/|I1|, millionths
static const int UNBAL_I_UNBALANCE_WORD  = 31;  // |I2|/|I1|, millionths
static const int UNBAL_FLAGS_WORD        = 32;
static const int UNBAL_FLAGS_V_VALID_BIT   = 0;  // |V1| != 0: V ratios usable
static const int UNBAL_FLAGS_I_VALID_BIT   = 1;  // |I1| != 0: I ratios usable
static const int UNBAL_FLAGS_REF_VALID_BIT = 8;  // VA angle reference usable
// Words 33..63 reserved zero.

// UNBALANCE-v1 status bit (word 8), mirroring the PHASOR record.
static const int UNBAL_STATUS_INVALID_BIT = 1;

// ---------------------------------------------------------------------------
// PQEVT-v1 interior. Envelope words 0..12 as always; the envelope
// first-sample (9/10) is the WINDOW start for a periodic record and the
// EVENT start for both event kinds, so every record self-describes its
// measurement span with words 14/15.
// ---------------------------------------------------------------------------
static const int PQ_KIND_WORD = 13;
static const int PQ_KIND_LSB          = 0;   // [7:0]   MET_PQ_KIND_*
static const int PQ_KIND_EVENT_LSB    = 8;   // [15:8]  MET_PQ_EVENT_*
static const int PQ_KIND_PHASES_LSB   = 16;  // [18:16] affected phase mask A/B/C
static const int PQ_KIND_LOCKED_BIT   = 24;  // grid lock at the last update
static const int PQ_KIND_FALLBACK_BIT = 25;  // half-cycle strobe was synthetic
static const int PQ_KIND_ARMED_BIT    = 26;  // detection enabled (reference != 0)
static const int PQ_LAST_SAMPLE_LOW_WORD  = 14;
static const int PQ_LAST_SAMPLE_HIGH_WORD = 15;
// Latest Urms(1/2) and the window/event extremes, per voltage phase
// (A/B/C), 32-bit micro-volts. The extremes span the periodic window for
// a heartbeat and the whole event for an event-end record.
static const int PQ_URMS_BASE_WORD     = 16;  // 3 x u32
static const int PQ_URMS_MIN_BASE_WORD = 19;  // 3 x u32
static const int PQ_URMS_MAX_BASE_WORD = 22;  // 3 x u32
// Latest Irms(1/2) per phase, micro-amperes: the companion quantity for
// inrush and fault-current context alongside a voltage event.
static const int PQ_IRMS_BASE_WORD     = 25;  // 3 x u32
static const int PQ_EVENT_SEQ_WORD     = 28;  // ties START to END; 0 = periodic
static const int PQ_DURATION_LOW_WORD  = 29;  // event duration, SAMPLES (u64)
static const int PQ_DURATION_HIGH_WORD = 30;
static const int PQ_UPDATES_WORD       = 31;  // half-cycle updates in the span
// Configuration echo: the thresholds this record was evaluated against,
// so a stored event stays interpretable without the settings of the day.
static const int PQ_REFERENCE_WORD     = 32;  // Udin, micro-volts (0 = disarmed)
static const int PQ_SAG_THRESHOLD_WORD = 33;  // 1e-4 fraction of Udin
static const int PQ_SWELL_THRESHOLD_WORD     = 34;
static const int PQ_INTERRUPT_THRESHOLD_WORD = 35;
static const int PQ_HYSTERESIS_WORD          = 36;
// Words 37..63 reserved zero.


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
static const int MTR2_CONTINUITY_COUNT_WORD = 35;

// AGG-v3 additions on top of the MTR2 map (see the format note above).
static const int AGG_LAST_SAMPLE_LOW_WORD  = 36;
static const int AGG_LAST_SAMPLE_HIGH_WORD = 37;
static const int AGG_VLL_BASE_WORD         = 38;  // 3 x 32-bit micro-units

// ---------------------------------------------------------------------------
// TEN-MINUTE-v1 additions.  Words 13..40 retain the aggregate layout above
// so generic aggregate decoders can reuse the RMS/VLL/diagnostic paths.
// The shape word is widened semantically for this variable-length interval:
//   [15:0]  number of complete 10/12-cycle blocks folded
//   [23:16] nominal frequency
//   [31:24] interval flags (see TEN_MINUTE_FLAG_* below)
// Word 41 carries the complete-cycle count because a 10-minute interval can
// contain 30,000/36,000 cycles and therefore no longer fits the old shape
// field alongside the block count.
// ---------------------------------------------------------------------------
static const int TEN_MINUTE_SHAPE_BLOCKS_LSB  = 0;
static const int TEN_MINUTE_SHAPE_NOMINAL_LSB = 16;
static const int TEN_MINUTE_SHAPE_FLAGS_LSB   = 24;

static const int TEN_MINUTE_FLAG_CONTAMINATED_BIT = 0;
static const int TEN_MINUTE_FLAG_ALIGNED_BIT      = 1;

static const int TEN_MINUTE_TOTAL_CYCLES_WORD       = 41;
static const int TEN_MINUTE_TARGET_SAMPLE_LOW_WORD  = 42;
static const int TEN_MINUTE_TARGET_SAMPLE_HIGH_WORD = 43;
static const int TEN_MINUTE_OVERSHOOT_SAMPLES_WORD  = 44;

// Fundamental-record status bits in addition to the common arithmetic bit.
static const int TEN_MINUTE_STATUS_COMPLETE_BIT     = 1;
static const int TEN_MINUTE_STATUS_TIME_ALIGNED_BIT = 2;
static const int TEN_MINUTE_STATUS_CONTAMINATED_BIT = 3;
static const int TEN_MINUTE_STATUS_BOUNDARY_VALID_BIT = 4;
static const int TEN_MINUTE_STATUS_OPEN_INTERVAL_BIT   = 5;
static const int TEN_MINUTE_STATUS_NON_NORMATIVE_BIT   = 6;

// ---------------------------------------------------------------------------
// SCYC-v4 interior: the single-cycle diagnostic record. One record per
// complete grid cycle while cycle timing is locked; observability for
// the single-cycle foundation before the 10/12-cycle tier consumes its
// result beats. Envelope words 0..12 as always (first-sample timestamp
// in 9/10). v2 (M3) added the diagnostic one-cycle readings: per-lane
// mean-corrected-per-config RMS and line-line RMS, in the same
// micro-unit convention as the MTR1 record (Q16 >> 16). These are
// DIAGNOSTIC readings (handover §10): the authoritative outputs remain
// the mergeable statistics on the result beat.
// ---------------------------------------------------------------------------
static const int SCYC_TIMING_WORD = 13;  // nominal[7:0] | cycles[15:8]=1 | flags[18:16]
static const int SCYC_CYCLE_SEQ_WORD = 14;       // grid cycle sequence
static const int SCYC_LAST_SAMPLE_LOW_WORD = 16;  // cycle's last conversion index
static const int SCYC_LAST_SAMPLE_HIGH_WORD = 17;
static const int SCYC_PROC_TICK_LOW_WORD = 18;   // PL tick at record emission
static const int SCYC_PROC_TICK_HIGH_WORD = 19;
static const int SCYC_FREQ_VALUE_WORD = 20;      // frequency, millihertz
static const int SCYC_FREQ_STATUS_WORD = 21;     // frequency engine status
// Words 24..37: 7 lanes x 2 words of one-cycle RMS, micro-units 64-bit.
static const int SCYC_CH_BASE_WORD = 24;
static const int SCYC_CH_STRIDE_WORDS = 2;
// Words 38..43: Vab/Vbc/Vca one-cycle RMS, micro-units 64-bit (from the
// instantaneous-difference accumulators, dc included; never sqrt(3)*VLN).
static const int SCYC_VLL_BASE_WORD = 38;
// Words 44..49: per-phase one-cycle ACTIVE power, SIGNED 64-bit
// picowatts (v3 / metrology M4; sign conventions in metering_types.hpp:
// import positive). Diagnostic — the mergeable sum(v*i) rides the beat.
static const int SCYC_POWER_BASE_WORD = 44;
// Words 50..63: per-lane FUNDAMENTAL RMS, micro-units 64-bit (v4 /
// metrology M5): |mean phasor| * sqrt(2) from the synchronous
// correlation. Under distortion this reads BELOW the total RMS in words
// 24..37 — that separation is the phasor-rejection acceptance check.
// Status bit 1: phasor invalid this cycle (frequency reference unusable).
static const int SCYC_FUND_BASE_WORD = 50;  // sequence/sample-range breaks

// MTR2 status bits (word 8), beyond the common arithmetic bit.
static const int MTR2_STATUS_COMPLETE_BIT  = 1;  // always set — only complete aggregates emit
static const int MTR2_STATUS_FREQUENCY_BIT = 2;  // all 15 frequency inputs were valid
// The continuing pre-boundary interval and the new UTC-synchronized interval
// deliberately overlap.  These additive bits make that standards-defined
// transition distinguishable from a duplicated/corrupt record.
static const int MTR2_STATUS_UTC_OVERLAP_BIT = 3;
static const int MTR2_STATUS_UTC_RESYNCHRONIZED_BIT = 4;

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
// Keep this as one callable formatter in multi-tier producers.  Inlining it at
// every record call site creates a separate set of word decoders and enables
// for the same BRAM-backed image, which is especially costly in the interval
// record builder.
#pragma HLS INLINE off
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
// One serial clear engine is sufficient: record publication is orders of
// magnitude slower than the 100 MHz fabric clock.  Sharing it avoids a clear
// loop (and its independently controlled image ports) for every record kind.
#pragma HLS INLINE off
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
// Runtime-format serializer. Identical framing guarantee to the template
// below; the format travels as a value so ONE serializer instance can
// emit records of several formats. That matters where a single engine
// owns more than one tier: the interval service emits multiple record
// formats across two intervals, and without this each call site would
// carry its own copy of the 64-beat loop and its 2048-bit image buffer.
inline void serialize_record_format(record_image_t &image, uint32_t format,
                                    record_axis_stream_t &m_axis) {
#pragma HLS INLINE off
  image.word[MREC_MAGIC_WORD]  = MREC_MAGIC;
  image.word[MREC_FORMAT_WORD] = ap_uint<32>(format);
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

// Compile-time-format wrapper: unchanged contract for every existing
// producer, now a thin call into the shared serializer above.
template <uint32_t FORMAT>
void serialize_record(record_image_t &image, record_axis_stream_t &m_axis) {
  serialize_record_format(image, FORMAT, m_axis);
}

#endif  // MSAP1_MEASUREMENT_RECORD_HPP
