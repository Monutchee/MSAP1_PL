# Meter processing stage

The meter-processing stage computes block RMS for current channels 0 through 3
and voltage channels 4 through 6 from one coherent converted-sample window.

The measurement unit is an IEC 61000-4-30 basic measurement block, defined by
grid cycles rather than time: 10 complete cycles at a declared 50 Hz nominal,
12 at 60 Hz (`grid_cycle_timing`). The block therefore lasts approximately
200 ms but tracks the actual grid frequency. `SHADOW_WINDOW_SAMPLES` remains
the free-run fallback window used while the voltage reference is unusable
(and the whole block-close source when cycle timing is disabled); software
programs it to the nominal block length, 6,400 frames at 32 kSPS.
Mean-corrected AC RMS uses

```text
sqrt((N * sum(x^2) - sum(x)^2) / N^2)
```

where `N` is the number of samples actually accumulated in the block (equal
to the configured window only in fixed-window mode), with 128-bit
accumulators and multi-cycle unsigned division and integer square root.
Zero-referenced total RMS uses `sqrt(sum(x^2) / N)`. Accumulation of the next
window continues while the previous snapshot is evaluated.

## Grid-cycle timing

`grid_cycle_timing` observes the frames accepted by the RMS engine and the
qualified crossings of the shared zero-cross detector (both the registered
outputs used by the frequency estimator and a combinational same-frame view).
It counts complete cycles and marks the frame that closes each basic block;
the marker travels through the RMS input pipeline with the frame itself, so
both modules always agree on block membership. The frame carrying the
closing crossing is the last frame of its block, making consecutive blocks
gapless by construction: `first(N+1) = first(N) + count(N)`.

All closed-block provenance (first sample, cycle count, nominal frequency,
flags) is latched together at the block-close event and held until the next
close. An APPLY that lands between a close and the result hub consuming the
metadata therefore cannot relabel the finished block with the new nominal
frequency; the new configuration affects future blocks only.

Lock behaviour: startup and every APPLY begin unlocked; the first qualified
rising crossing closes the initial partial block and locks. If the reference
becomes unusable or no crossing arrives for a quarter of the fallback window,
the lock drops, blocks close on the fallback sample count, and the next
qualified crossing closes the running block early and re-locks. Blocks that
did not close on a counted crossing carry the `free_run_fallback` flag.

The component also produces `cycle_boundary`, `half_cycle_boundary` (from
the falling-crossing view), and `cycle_sequence` strobes for a future PQ
event engine; nothing consumes them yet.

## VLA frequency measurement

`meter_frequency` is an observational CH6/VLA producer running beside RMS. It
does not own an AXI4-Stream handshake and cannot stall the main pipeline.
`meter_zero_crossing` arms below `-hysteresis`, accepts only the next
positive-going zero crossing, and captures the samples bracketing zero.
`meter_frequency_estimator` linearly interpolates that crossing in Q16 sample
units and uses a reusable sequential unsigned divider:

```text
crossing_q16 =
    (previous_sample_index << 16)
    + ((-previous_q16 << 16) / (current_q16 - previous_q16))

frequency_mHz =
    measured_drdy_frames_per_second * complete_cycles * 1000 * 65536
    / elapsed_q16_samples
```

The frame rate comes from the capture block's one-second physical
`ADC_DRDY_N` measurement. The requested profile sample rate is deliberately
not an estimator input. Frequency therefore remains correct when the ADC's
real output cadence differs from the requested rate (for example, 19.2
kframe/s versus 32 kSPS). Results remain invalid until the DRDY meter has a
valid baseline, and crossing history is cleared if that measurement becomes
unavailable or recovers.

The 48-bit Q16 timestamp subtraction is explicitly modulo `2^48`, so the
32-bit capture sequence may wrap without corrupting an interval. The crossing
history uses an `xpm_fifo_sync` with depth 128. With an 80-bit bit-serial
divider, interpolation, frequency, and period calculations complete in fewer
than 250 PL clocks, below the 781 clocks between 128 kSPS frames.

Modes are `single_cycle`, rolling 1–64 complete cycles, and non-overlapping
complete-cycle windows spanning approximately the requested time. After three
periods at the configured minimum frequency without a qualified crossing, the
published value becomes unavailable. Missing signal and out-of-range input are
measurement states; divide/overflow failures set the arithmetic-error flag.

## Module references

- `meter_rms`: reusable VHDL-2008 engine parameterized by first channel,
  channel count, and result mask.
- `VoltageRms_Wrapper`: compatibility AXI4-Stream/AXI-Lite boundary using the
  voltage-only default generics.
- `MeterResultHub_Wrapper`: caches the newest coherent result and builds a
  fixed 256-byte record.
- `MeterPacketizer_Wrapper`: two-record latest-wins buffer and 32-bit AXI4-
  Stream packetizer. `TLAST` is asserted only on word 63.

## MeterProcessing AXI-Lite registers

| Offset | Name | Description |
| --- | --- | --- |
| `0x00` | `VERSION` | `0x00010000` |
| `0x04` | `IDENTIFIER` | ASCII `MPR1` |
| `0x08` | `CONTROL` | bit 0 write-one `APPLY`; bit 1 enable; bit 2 remove DC |
| `0x0c` | `STATUS` | enabled, apply pending, calculation busy, overflow |
| `0x10` | `SHADOW_GENERATION` | software configuration generation |
| `0x14` | `SHADOW_SAMPLE_RATE` | frames/s |
| `0x18` | `SHADOW_WINDOW_SAMPLES` | samples in each RMS result |
| `0x1c` | `SHADOW_VALID_MASK` | valid converted channels |
| `0x20` | `ACTIVE_GENERATION` | committed generation |
| `0x24` | `RESULT_SEQUENCE` | completed RMS snapshots |
| `0x28` | `RESULT_DROP_COUNT` | arithmetic engine missed a window |
| `0x2c` | `PACKET_DROP_COUNT` | newest-pending packet replacements |
| `0x30` | `FREQUENCY_SHADOW_CONTROL` | enable, mode, CH6, cycle count |
| `0x34` | `FREQUENCY_SHADOW_WINDOW_SAMPLES` | rolling-time target |
| `0x38` | `FREQUENCY_SHADOW_MIN_MILLIHZ` | accepted lower limit |
| `0x3c` | `FREQUENCY_SHADOW_MAX_MILLIHZ` | accepted upper limit |
| `0x40` | `FREQUENCY_SHADOW_HYSTERESIS_UV` | positive integer microvolts |
| `0x44`–`0x54` | `FREQUENCY_ACTIVE_*` | atomically committed readback |
| `0x58` | `FREQUENCY_STATUS` | state flags, mode, reference, cycles used |
| `0x5c` | `FREQUENCY_VALUE_MILLIHZ` | latest valid frequency |
| `0x60` | `FREQUENCY_PERIOD_Q16_SAMPLES` | averaged period |
| `0x64` | `FREQUENCY_MEASUREMENT_SEQUENCE` | accepted result counter |
| `0x68` | `FREQUENCY_REJECTED_COUNT` | rejected arithmetic/range results |
| `0x6c` | `GRID_SHADOW_CONFIG` | [7:0] cycles/block, [15:8] nominal Hz, [16] enable |
| `0x70` | `GRID_ACTIVE_CONFIG` | committed grid-timing readback |
| `0x74` | `GRID_STATUS` | [0] locked, [1] reference usable, [2] enabled, [15:8] cycles in open block |
| `0x78` | `AGG_STATUS` | [4:0] basic blocks in the open aggregate, [8] aggregate in progress |
| `0x7c` | `AGG_RECORD_COUNT` | completed 150/180-cycle aggregates |
| `0x80` | `AGG_RESET_COUNT` | partial aggregates discarded (any cause) |
| `0x84` | `AGG_INELIGIBLE_COUNT` | Basic inputs rejected by the eligibility rule |
| `0x88` | `AGG_CONTINUITY_COUNT` | sample-range discontinuities between Basic inputs |
| `0x8c` | `AGG_DROP_COUNT` | aggregate records replaced before transport |

Frequency and grid shadow fields commit on the existing processing `APPLY`
toggle at the same frame boundary as RMS. Applying a new configuration clears
crossing history and restarts block tracking, preventing an interval or a
basic block from spanning configuration generations. The RPU derives the
cycle count from the declared nominal frequency (50 Hz → 10, 60 Hz → 12);
the PL does not validate the pairing.

## 150/180-cycle aggregation and the measurement record bus

`meter_cycle_aggregator` consumes the internal Basic measurement result
event -- the same event the Basic record producer consumes -- and aggregates
exactly 15 consecutive eligible Basic blocks into one 150-cycle (50 Hz) or
180-cycle (60 Hz) fundamental aggregate. It is an aggregator of
standardized Basic results, not a second RMS engine over raw samples, and
the close event is 15 blocks, never a 3-second timer.

Aggregation rules: RMS lanes use the square root of the arithmetic mean of
the squares of the 15 Basic values (unweighted, computed in the internal
Q16 domain; floor division and floor root, 132-bit accumulators that
cannot overflow at 15 x the maximum input). Frequency is the arithmetic
mean of the 15 sampled values, published only when all inputs were valid.

Eligibility mirrors the APU rule: cycle-locked, not fallback, not the
first block after APPLY, exact 10/12 cycle count, same configuration
generation, same nominal frequency, and gapless sample ranges. Any
violation discards the partial aggregate (counted per cause in the
`AGG_*` registers); an ineligible block never seeds the next aggregate,
so a rejected block can never be silently replaced by a later one inside
the same interval.

Both producers publish complete 256-byte records on the measurement
record bus (`measurement_record_bus_pkg`): the Basic producer
(`MeterResultHub_Wrapper`, MTR1 format 2) and the aggregate producer
(`aggregate_record_producer`, MTR2). A deterministic fixed-priority
arbiter (`measurement_record_arbiter`, Basic first) forwards records to
the single existing packetizer and AXI DMA channel; each producer holds
its newest pending record with a drop counter, so a stalled DMA can never
backpressure measurement. Future producers (harmonics, PQ events) add an
arbiter port, not a new DMA path. RPMsg remains control-plane only;
measurement records stay on DMA.

## 256-byte MTR2 aggregate record

Word 0 is the container magic `MTR1`, word 1 is `0x00020001` (aggregate
fundamental record, version 1), word 2 is the byte length (256). Word 3 is
the independent aggregate sequence; words 9/10 carry the first/last Basic
sequence so the relationship between the streams is explicit. Word 6 is
the total sample count of the interval, words 12/13 the 64-bit first
sample index (last = first + count - 1, derived), and word 11 packs the
basic block count (15), nominal frequency, and total cycle count
(150/180). Word 8 carries arithmetic/complete/frequency-valid status;
only complete aggregates are ever emitted. Words 16..31 hold eight
channels x two words of aggregate RMS in signed 64-bit micro-units, word
32 the aggregate frequency in millihertz, and all remaining words are
reserved zero.

## 256-byte periodic meter record

Words 0 through 15 form the header. Word 0 is ASCII `MTR1`, word 1 is
format/version `0x00010002`, and word 2 is the byte length (`256`). The header
also contains result sequence (the basic-block sequence), configuration
generation, sample rate, valid/status masks, capture
frame/header/overflow/alert counters, and result-drop counters.

Format 2 changes versus the original `0x00010001`:

- Word 6 carries the **actual** sample count of the basic block. In cycle
  mode this varies with grid frequency; format 1 reported the configured
  window.
- Word 15 is the basic-block timing word: bits [7:0] declared nominal
  frequency in Hz, bits [15:8] complete cycles in the block, bit 16
  `cycle_locked`, bit 17 `free_run_fallback`, bit 18
  `first_block_after_apply`.
- Words 60/61 are the low/high halves of the block's first sample index on
  the 64-bit free-running conversion sample counter. The last index is
  `first + count - 1` by construction and is deliberately not recorded.

Words 16 through 55 contain five words per channel: signed mean micro-units,
unsigned raw ADC RMS counts, and signed 64-bit RMS micro-units. Word 56 is
frequency in millihertz, word 57 contains frequency status/mode/reference/cycle
fields, word 58 is the averaged Q16 period, and word 59 is its measurement
sequence. Words 62 and 63 remain reserved.

The synchronized capture counters are internal MeterCore signals connecting
the capture entity directly to `MeterResultHub_Wrapper`; they do not cross the
single `MeterCore_Wrapper` module-reference boundary in `TopDesign.bd`.
