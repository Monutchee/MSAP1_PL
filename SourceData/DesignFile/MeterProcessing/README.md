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
(`SourceData/HLS_DesignFile/MeterProcessing/SingleCycleEngine`;
`single_cycle_engine.hpp/.cpp` are the normative sources — the hand-written
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
`meter_single_cycle_hls_shim`'s 8-deep beat FIFO absorbs incoming frames, so
measurement is never backpressured and any overflow is a counted fault,
never silent.

## Voltage-domain engine offload

`meter_voltage_sample_batcher` is the shared PL boundary for Flicker and mains
signalling. It observes converted VA/VB/VC samples and emits one CRC32C-
protected VSB1 packet for every 256 input frames whenever either engine is
enabled. Each sample occupies four ordered 32-bit words: signed integer-
microvolt VA/VB/VC and one flags word. No wide HLS sample or result bus
remains. The batcher never backpressures the metrology stream. When the
private FIFO cannot retain a complete packet, it drops that packet as a unit
and carries the loss into the next packet's discontinuity/source-drop status.

R5C1 owns all IEC 61000-4-15 processing after this boundary—reference
normalization, 2 kHz decimation, lamp-model filters, instantaneous flicker,
the 600-second classifier, Pst, and Plt—and also owns the seven-probe 200 ms
mains-signalling estimator. It serializes the unchanged Flicker-v1
(`0x000E0001`) and Mains-Signal-v1 (`0x000F0001`) public records. The bitstream
and R5C1 firmware are a co-release pair; there is no PL calculation fallback.

HLS record images and finalized result arrays are deliberately bound to
dual-port LUTRAM. They are shallow indexed scratch stores, and leaving them on
automatic inference can consume one mostly empty BRAM primitive per array.
Deep sample queues, spectral windows, and private packet stores remain mapped
to BRAM or URAM; do not move those high-capacity buffers into distributed RAM.

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

- `meter_spectral_conditioner`: M16's nonbackpressuring adaptive production
  conditioner. On APPLY it selects the exact `L/25` profile where
  `L = 512000/Fs` for 1, 2, 4, 8, 16, 32, 64, or 128 kSPS, and converts each
  exact 200 ms source block to 4,096 frames at 20.48 kSPS. The 32/64/128 kSPS
  profiles use a 1,025-tap Kaiser prototype; lower rates use a compact
  endpoint-inclusive 129-row fractional-delay table with carried-remainder
  interpolation and exact Q20 unity gain. A 512-frame K26 URAM history ring and
  16-entry marker queue decouple source capture from the time-shared MAC, so
  even 128 kSPS is lossless. A qualified boundary may select either adjacent
  ADC frame because a continuous crossing is discretized at the accepted-frame
  interface; the conditioner normalizes that bounded +/-1 endpoint choice
  while retaining the exact nominal `L/25` lattice, and rejects every larger
  geometry error. The frozen ROM check measures at most 0.001688 dB
  ripple; high-rate stopbands are below -79.65 dBFS and low-rate image bounds
  are below -88.18 dBFS. Unsupported rates, measured/configured-rate mismatch,
  or malformed block geometry are explicitly invalid.
- `meter_spectral_frontend`: M16's VHDL-2008 two-bank 4,096-frame spectral
  buffer and CH0-through-CH6 XFFT scheduler. It is instantiated
  inside MeterCore, maps its two wide banks to six K26 URAMs to preserve BRAM
  for XFFT, aborts an incomplete capture on the same APPLY boundary as the
  conditioner, and preserves whole-window validity under malformed input or
  overload.
- `meter_harmonic_hls_shim`: owns the frontend, packaged HarmonicEngine,
  forward-XFFT configuration handshake, sticky XFFT family-fault injection,
  and a 4,096-word URAM packet-mode record FIFO. Only the XFFT itself crosses
  the MeterCore boundary; records leave on `M_AXIS_HARMONIC`. The matching
  private HRM1 and R5 aggregation packet stores also retain their full depth
  in symmetric URAM FIFOs so the design preserves K26 BRAM headroom.
- `meter_single_cycle_hls_shim`: packs one 1,024-bit logical frame per accepted
  converted frame (layout mirrors `single_cycle_engine.hpp` SCYC_IN_*, kept in
  lock step), buffers up to eight beats, hosts the packaged
  `hls_single_cycle_engine_ip`, and mirrors the APPLY commit for the register
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
| `0x24` | `RESULT_SEQUENCE` | Basic-record sequence, as of the last emitted record (tap on word 3) |
| `0x28` | `RESULT_DROP_COUNT` | Basic-record word 12 (`result_drops`, constant 0: every close is finalized) |
| `0x2c` | `PACKET_DROP_COUNT` | Basic-record word 11 (`emit_drops`, constant 0: emission is blocking) |
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
| `0x78` | `AGG_STATUS` | retired PL aggregation diagnostic; reads 0 |
| `0x7c` | `AGG_RECORD_COUNT` | retired PL aggregation diagnostic; reads 0 |
| `0x80` | `AGG_RESET_COUNT` | retired PL aggregation diagnostic; reads 0 |
| `0x84` | `AGG_INELIGIBLE_COUNT` | retired PL aggregation diagnostic; reads 0 |
| `0x88` | `AGG_CONTINUITY_COUNT` | retired PL aggregation diagnostic; reads 0 |
| `0x8c` | `AGG_DROP_COUNT` | retired PL aggregation diagnostic; reads 0 |
| `0x90` | `HLS_AGG_RECORD_COUNT` | retired compared-pair diagnostic; reads 0 |
| `0x94` | `HLS_AGG_MISMATCH_COUNT` | reserved, reads 0 (the compared-pair trial ended) |
| `0x98` | `HLS_AGG_DROP_COUNT` | SingleCycle shim result-packet drops (any nonzero value is a fault) |
| `0xb0` | `R5_AGG_EXPORT_STATUS` | private PL -> R5C1 exporter state and sticky transport faults |
| `0xb4` | `R5_AGG_EXPORT_ACCEPTED_COUNT` | complete single-cycle result packets admitted to the private exporter |
| `0xb8` | `R5_AGG_EXPORT_DROPPED_COUNT` | whole packets dropped because private exporter storage was unavailable; never partial packets |
| `0xbc` | `R5_AGG_EXPORT_TRANSMITTED_COUNT` | complete CRC-protected frames accepted by the downstream AXI-Stream sink |
| `0xc0` | `R5_AGG_EXPORT_FRAMING_ERRORS` | malformed SingleCycle result packets observed by the exporter |
| `0xc4` | `R5_AGG_EXPORT_LAST_SEQUENCE` | sequence of the most recently admitted result packet |
| `0xc8` | `R5_AGG_EXPORT_QUEUE_LEVEL` | complete packets awaiting private-link transmission |
| `0xcc` | `HARMONIC_CONDITIONED_BLOCKS` | exact conditioner blocks completed without a structural/service fault |
| `0xd0` | `HARMONIC_INVALID_BLOCKS` | conditioner blocks rejected for geometry, discontinuity, or service failure |
| `0xd4` | `HARMONIC_SERVICE_OVERRUNS` | accepted source frames that arrived while the time-shared conditioner was busy; must remain zero |
| `0xd8` | `HARMONIC_FRONTEND_COMPLETED` | complete 4,096-frame windows serialized to XFFT |
| `0xdc` | `HARMONIC_FRONTEND_DROPPED` | whole windows discarded because both ping/pong banks were occupied; must remain zero |
| `0xe0` | `HARMONIC_FRONTEND_MALFORMED` | whole windows rejected for explicit fault or TLAST geometry; must remain zero |
| `0xe4` | `HARMONIC_XFFT_FAULT_COUNT` | cycles carrying an XFFT TLAST/channel-halt event; must remain zero |

The `R5_AGG_EXPORT_*` registers describe a private exact co-release link to
R5C1.  Its fixed contract guard and CRC are image-integrity checks, not a
compatibility-negotiation interface. R5C1 is the sole aggregation authority;
PL contains no interval-aggregation implementation or fallback. The exporter
is a nonbackpressuring consumer of the SingleCycle packet boundary: it reserves
storage for a complete packet at word 0 or consumes and discards that complete
packet.  R5 congestion can therefore increase only the explicit whole-packet
drop counter; it cannot stall capture or any measurement stream.

Frequency and grid shadow fields commit on the existing processing `APPLY`
toggle at the same frame boundary as RMS. Applying a new configuration clears
crossing history and restarts block tracking, preventing an interval or a
basic block from spanning configuration generations. The RPU derives the
cycle count from the declared nominal frequency (50 Hz → 10, 60 Hz → 12);
the PL does not validate the pairing.

## Interval-record path

The PL SingleCycle engine emits one fixed 221-word sufficient-statistics
packet for every complete grid cycle. `meter_r5_aggregation_export.vhd`
appends 13 configuration and health words, a four-word private-link header,
and CRC32C, then sends the complete 239-word frame to R5C1. The packet layout
is pinned by `meter_r5_aggregation_pkg.vhd` and
`common/include/single_cycle_packet.hpp`.

R5C1 owns Basic, 150/180-cycle, UTC 10-minute, and 2-hour aggregation and
record serialization. It returns one complete 256-byte record through the
AXI FIFO TX channel into `MTR_AXI_Switch/S02_AXIS`. The retired duplicate
The duplicate legacy basic/aggregate wrapper interfaces are removed. Every returned
record is 64 x 32-bit beats with TLAST on beat 63 before it joins the Linux
meter-DMA path. The other compact switch inputs are S00 SingleCycle, S01 PQ,
and S03 harmonics. RPMsg remains control-plane only.

The fixed-point interval algorithm and its host tests are owned under
`MSAP1_RPU/R5c1/src/MainApp/aggregation/`. Shared record maps, sufficient
statistics, finalization arithmetic, and serial math remain under
`SourceData/HLS_DesignFile/common/include/` so the PL producer and R5C1
consumer compile against one co-released contract.
