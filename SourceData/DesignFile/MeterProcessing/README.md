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

## 256-byte periodic meter record

Words 0 through 15 form the header. Word 0 is ASCII `MTR1`, word 1 is
format/version `0x00010001`, and word 2 is the byte length (`256`). The header
also contains result sequence, configuration generation, sample rate, window
size, valid/status masks, capture frame/header/overflow/alert counters, and
result-drop counters.

Words 16 through 55 contain five words per channel: signed mean micro-units,
unsigned raw ADC RMS counts, and signed 64-bit RMS micro-units. Remaining
words are reserved for frequency, power, energy, demand, and PQ records.

The synchronized capture counters are internal MeterCore signals connecting
the capture entity directly to `MeterResultHub_Wrapper`; they do not cross the
single `MeterCore_Wrapper` module-reference boundary in `TopDesign.bd`.
