# Meter processing stage

The meter-processing stage computes block statistics for current channels 0
through 3 and voltage channels 4 through 6 from one coherent
converted-sample window, and emits them as self-serialized 256-byte
records on per-producer AXIS streams.

The measurement unit is an IEC 61000-4-30 basic measurement block, defined by
grid cycles rather than time: 10 complete cycles at a declared 50 Hz nominal,
12 at 60 Hz (`grid_cycle_timing`). The block therefore lasts approximately
200 ms but tracks the actual grid frequency. `SHADOW_WINDOW_SAMPLES` remains
the free-run fallback window used while the voltage reference is unusable
(and the whole block-close source when cycle timing is disabled); software
programs it to the nominal block length, 6,400 frames at 32 kSPS.

The numerics are a Vitis HLS engine
(`SourceData/HLS_DesignFile/MeterProcessing/Mtr1Engine`;
`mtr1_engine.hpp/.cpp` are the normative sources — the hand-written
`meter_rms`/`MeterResultHub` pair it replaced lives in git history).
Mean-corrected AC RMS uses

```text
sqrt((N * sum(x^2) - sum(x)^2) / N^2)
```

where `N` is the number of samples actually accumulated in the block (equal
to the configured window only in fixed-window mode), with 128-bit
accumulators, serial restoring division, and an exact restoring integer
square root; zero-referenced total RMS uses `sqrt(sum(x^2) / N)`; all
rounding is floor/truncation as pinned in the engine header. The engine
finalizes each closed block inline (~15 us) while
`meter_mtr1_hls_shim`'s 8-deep beat FIFO absorbs incoming frames, so
measurement is never backpressured and any overflow is a counted fault,
never silent.

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

## Modules

- `meter_mtr1_hls_shim`: packs one 1264-bit sample beat per accepted
  converted frame (layout mirrors `mtr1_engine.hpp` MTR1_IN_*, kept in
  lock step), buffers up to eight beats, hosts the packaged
  `hls_mtr1_engine_ip`, and mirrors the APPLY commit for the register
  file. Deliberately contains NO level-to-event conversion — the
  2026-08-13..16 record-duplication incident was localized to exactly
  that pattern in the retired aggregator shim.
- `record_word_tap`: passive observer on each producer's record stream;
  republishes the in-record health counters to the register file
  ("as of the last emitted record") and watchdogs the 64-beat framing
  invariant.

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
| `0x24` | `RESULT_SEQUENCE` | MTR1 record sequence, as of the last emitted record (tap on word 3) |
| `0x28` | `RESULT_DROP_COUNT` | MTR1 record word 12 (`result_drops`, constant 0: every close is finalized) |
| `0x2c` | `PACKET_DROP_COUNT` | MTR1 record word 11 (`emit_drops`, constant 0: emission is blocking) |
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
| `0x78` | `AGG_STATUS` | reads 0 — the HLS engines expose no live open-aggregate view; liveness shows as `0x7c` advancing |
| `0x7c` | `AGG_RECORD_COUNT` | MTR2 record sequence, as of the last emitted aggregate (tap on word 3) |
| `0x80` | `AGG_RESET_COUNT` | MTR2 record word 33, as of the last emit |
| `0x84` | `AGG_INELIGIBLE_COUNT` | MTR2 record word 34, as of the last emit |
| `0x88` | `AGG_CONTINUITY_COUNT` | MTR2 record word 35, as of the last emit |
| `0x8c` | `AGG_DROP_COUNT` | MTR2 record word 11 (`emit_drops`, constant 0: emission is blocking) |
| `0x90` | `HLS_AGG_RECORD_COUNT` | mirrors `AGG_RECORD_COUNT` |
| `0x94` | `HLS_AGG_MISMATCH_COUNT` | reserved, reads 0 (the compared-pair trial ended) |
| `0x98` | `HLS_AGG_DROP_COUNT` | sample beats the MTR1 shim FIFO discarded while the engine was finalizing (any nonzero value is a fault) |

Frequency and grid shadow fields commit on the existing processing `APPLY`
toggle at the same frame boundary as RMS. Applying a new configuration clears
crossing history and restarts block tracking, preventing an interval or a
basic block from spanning configuration generations. The RPU derives the
cycle count from the declared nominal frequency (50 Hz → 10, 60 Hz → 12);
the PL does not validate the pairing.

## Record streams and the 150/180-cycle aggregation engine

Both record producers are Vitis HLS engines that build and serialize
their own 256-byte records; the wire formats are normative in C++
(`SourceData/HLS_DesignFile/common/include/measurement_record.hpp`: the
common envelope in words 0..12 — magic `MTR1`, format, size 256,
per-producer sequence, generation, sample rate, sample count, valid mask,
status, 64-bit first-sample timestamp, emit/result drop words — plus the
MTR1-v3 and MTR2-v2 interior maps).

- The MTR1 engine (`HLS_DesignFile/MeterProcessing/Mtr1Engine`) emits one
  `0x00010003` record per basic block on `M_AXIS_MTR1` and one
  basic-result beat (common `basic_result_beat.hpp`, 808 bits) to the
  aggregator.
- The aggregation engine (`HLS_DesignFile/MeterProcessing/CycleAggregator`)
  consumes exactly 15 consecutive eligible basic results — never raw
  samples, never a wall-clock timer — and emits one `0x00020002` record
  per completed 150-cycle (50 Hz) / 180-cycle (60 Hz) aggregate on
  `M_AXIS_MTR2`. RMS lanes aggregate as floor(sqrt(floor(mean of
  squares))) in the Q16 domain with 132-bit accumulators; frequency is
  the arithmetic mean, published only when all 15 inputs were valid.
  Eligibility mirrors the APU rule: cycle-locked, not fallback, not the
  first block after APPLY, exact 10/12 cycle count, one generation /
  nominal / sample rate, consecutive sequences and gapless sample ranges;
  any violation discards the partial aggregate, counted per cause in
  record words 33..35.

Each producer's stream leaves `MeterCore_Wrapper` as its own AXIS master;
the block design gives each a packet-mode `axis_data_fifo` and an
`axis_switch` slave port (arbitrate-on-TLAST), and the switch feeds the
meter DMA. Every record is exactly 64 x 32-bit beats with TLAST on beat
63 — the DMA-ring framing invariant, watchdogged in fabric by
`record_word_tap`. Future producers add an engine, a wrapper port, a
FIFO, and a switch port; nothing existing changes. RPMsg remains
control-plane only; measurement records stay on DMA.

Records leave the Q16 domain at serialization: mean and RMS words carry
signed 64-bit micro-units (`Q16 >> 16`, arithmetic); the raw-count RMS
word carries ADC counts. The per-engine C++ headers pin the arithmetic
(floor semantics, saturation, sticky overflow-until-APPLY) and the
accepted APPLY-race divergences; each engine's golden C bench runs as C
simulation and C/RTL co-simulation on every `mnc HLS build` /
`run_hls.sh` build, and `tb/meter_record_stream_tb.sv` drives the whole
chain — real shim, both packaged engines, both exported streams — with
word-exact golden records under TREADY backpressure.
