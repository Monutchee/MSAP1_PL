# MeterCore

`MeterCore_Wrapper` is the single Vivado module-reference boundary for the
MSAP1 ADC capture and metering datapath. The wrapper is ordinary VHDL for IP
Integrator discovery; `meter_core` and the implementation entities are
VHDL-2008.

The standalone hierarchy is:

```text
AD7771 capture -> ADC conversion -> 16-frame XPM AXI4-Stream FIFO
               +-> unified current/voltage RMS --------+
               +-> VLA positive zero-cross frequency --+
               |                                      |
               |         result hub <- coherent results+
               |              -> MTR1 packetizer -> meter DMA
               |
               +-> nonblocking 256-frame XPM FIFO
                       -> WFM1 packetizer -> waveform DMA
```

The four AXI4-Lite interfaces retain their software contracts:

| Interface | Top-level address |
| --- | --- |
| `S_AXI_CAPTURE` | `0xB0020000` |
| `S_AXI_CONVERSION` | `0xB0040000` |
| `S_AXI_PROCESSING` | `0xB0050000` |
| `S_AXI_WAVEFORM` | `0xB0070000` |

`M_AXIS_METER` emits the existing 256-byte MTR1 records as 64 32-bit beats,
with `TLAST` asserted on beat 63. The module-reference clock metadata is
99,999,001 Hz. `adc_dclk` remains an independent ADC-source clock and the
capture entity retains the established CDC implementation.

`M_AXIS_WAVEFORM` continuously emits raw, signed 24-bit ADC samples in
32-bit storage. A WFM1 block is exactly 32,832 bytes:

```text
64-byte WFM1 header
1024 frames × 8 channels × 4 bytes
```

The header carries a 64-bit frame sequence, 64-bit free-running PL tick,
measured sample rate, configuration generation, drop count, and block
sequence. `TLAST` is asserted only on the final word of frame 1023. The
waveform branch never drives the conversion stream's `ready`; when Linux is
not armed or its FIFO fills, only raw waveform frames are dropped and counted.
RMS, frequency, and MTR1 production continue without backpressure from the
diagnostic waveform path.

`TopDesign.bd` instantiates this wrapper directly. System-level IP such as the
Zynq platform, two AXI DMA instances, SmartConnect, AXI Quad SPI, clocks,
resets, heartbeat, and fan routing remains in that single block design;
metering datapath logic remains in the VHDL hierarchy described above. The
meter DMA remains at `0xB0030000`; the dedicated waveform DMA is at
`0xB0060000`. Both are SG-enabled S2MM-only engines with independent
interrupts and DDR descriptor/data paths.

The conversion-to-processing elasticity buffer is an `xpm_fifo_axis` macro in
common-clock mode. It stores complete converted frames and their AXI4-Stream
metadata without a custom FIFO implementation, generated XCI, or additional
block design.

The VLA frequency path observes each frame accepted by the RMS engine. It has
no `ready` output and can therefore never backpressure conversion, RMS, or ADC
capture. A qualified crossing first requires VLA below the negative hysteresis
threshold, then a negative-to-positive transition. The crossing position is
linearly interpolated in Q16 sample units:

```text
crossing = previous_sample_index
         + (-previous_value / (current_value - previous_value))
```

Counting only positive-going crossings produces one interval per complete grid
cycle. The estimator supports one-cycle, rolling-cycle, and complete-cycle
time-window modes. Frequency is independent of the RMS `remove_dc` setting.

## Waveform correlation registers

Linux owns `S_AXI_WAVEFORM`. The register block is independent from the
waveform DMA:

| Offset | Register |
| ---: | --- |
| `0x00` | Version (`0x00010000`) |
| `0x04` | Identifier (`WFC1`) |
| `0x08` | Control: enable, latch, clear statistics |
| `0x0C` | Status |
| `0x10`–`0x14` | Latched 64-bit PL tick |
| `0x18`–`0x1C` | Latched 64-bit frame sequence |
| `0x20`–`0x24` | Live 64-bit PL tick |
| `0x28`–`0x2C` | Live 64-bit frame sequence |
| `0x30` | Dropped waveform frames |
| `0x34` | Completed WFM1 blocks |
| `0x38` | WFM1 block size |

A control write with `LATCH=1` atomically snapshots tick and sequence. Linux
brackets that write with `CLOCK_TAI` reads, providing an uncertainty-bounded
mapping from raw sample sequence to wall time without placing timestamps in
RPMsg.

## Verification

Run the end-to-end mixed-language test and focused synthesis from the
repository root:

```sh
vivado -mode batch -source SourceData/Script/AI_gen/check_meter_core.tcl
vivado -mode batch -source SourceData/Script/AI_gen/check_meter_frequency.tcl
vivado -mode batch \
  -source SourceData/Script/AI_gen/check_metering_synthesis.tcl \
  -tclargs MeterCore_Wrapper
```

The integration test programs all three AXI4-Lite interfaces, sends real
four-lane AD7771 serial frames, checks both DC-removal modes and the complete
MTR1 record, and verifies that two RMS windows can be captured while the DMA
stream is backpressured.
