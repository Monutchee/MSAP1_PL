# Meter processing stage

The meter-processing stage computes block RMS for current channels 0 through 3
and voltage channels 4 through 6 from one coherent converted-sample window.
The default window is 6,400 frames, which is exactly 200 ms at 32 kSPS.
Mean-corrected AC RMS uses

```text
sqrt((N * sum(x^2) - sum(x)^2) / N^2)
```

with 128-bit accumulators and multi-cycle unsigned division and integer square
root. Zero-referenced total RMS uses `sqrt(sum(x^2) / N)`. Accumulation of the
next window continues while the previous snapshot is evaluated.

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
    sample_rate_hz * complete_cycles * 1000 * 65536
    / elapsed_q16_samples
```

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

Frequency shadow fields commit on the existing processing `APPLY` toggle at
the same frame boundary as RMS. Applying a new configuration clears crossing
history, preventing an interval from spanning configuration generations.

## 256-byte periodic meter record

Words 0 through 15 form the header. Word 0 is ASCII `MTR1`, word 1 is
format/version `0x00010001`, and word 2 is the byte length (`256`). The header
also contains result sequence, configuration generation, sample rate, window
size, valid/status masks, capture frame/header/overflow/alert counters, and
result-drop counters.

Words 16 through 55 contain five words per channel: signed mean micro-units,
unsigned raw ADC RMS counts, and signed 64-bit RMS micro-units. Word 56 is
frequency in millihertz, word 57 contains frequency status/mode/reference/cycle
fields, word 58 is the averaged Q16 period, and word 59 is its measurement
sequence. Words 60 through 63 remain reserved for power, energy, demand, and PQ.

The synchronized capture counters are internal MeterCore signals connecting
the capture entity directly to `MeterResultHub_Wrapper`; they do not cross the
single `MeterCore_Wrapper` module-reference boundary in `TopDesign.bd`.
