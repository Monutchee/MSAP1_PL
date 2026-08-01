# MeterCore

`MeterCore_Wrapper` is the single Vivado module-reference boundary for the
MSAP1 ADC capture and metering datapath. The wrapper is ordinary VHDL for IP
Integrator discovery; `meter_core` and the implementation entities are
VHDL-2008.

The standalone hierarchy is:

```text
Physical AD7771 capture --+
                          +-> raw source mux -> ADC conversion
Raw ADC simulator --------+                       |
                                                   +-> 16-frame XPM AXI4-Stream FIFO
               +-> unified current/voltage RMS --------+
               +-> VLA positive zero-cross frequency --+
               |                                      |
               |         result hub <- coherent results+
               |              -> MTR1 packetizer -> meter DMA
               |
               +-> nonblocking 256-frame XPM FIFO
                       -> WFM1 packetizer -> waveform DMA
```

The existing AXI4-Lite interfaces retain their software contracts and the
simulator adds one RPU-owned interface:

| Interface | Top-level address |
| --- | --- |
| `S_AXI_CAPTURE` | `0xB0020000` |
| `S_AXI_CONVERSION` | `0xB0040000` |
| `S_AXI_PROCESSING` | `0xB0050000` |
| `S_AXI_WAVEFORM` | `0xB0070000` |
| `S_AXI_SIMULATOR` | `0xB0080000` |

`M_AXIS_METER` emits the existing 256-byte MTR1 records as 64 32-bit beats,
with `TLAST` asserted on beat 63. The module-reference clock metadata is
99,999,001 Hz. `adc_dclk` remains an independent ADC-source clock and the
capture entity retains the established CDC implementation.

## Raw ADC simulator

`adc_simulator` emits the same eight 32-bit AXI4-Stream beats consumed from
the physical receiver. Samples are signed 24-bit ADC counts sign-extended to
32 bits and ordered as follows:

```text
CH0 Ia, CH1 Ib, CH2 Ic, CH3 In,
CH4 Vc, CH5 Vb, CH6 Va, CH7 disabled
```

The raw-source mux is deliberately placed before conversion, RMS, frequency,
meter packetization, and waveform capture. A simulated waveform therefore
exercises every normal downstream path. Only the selected source receives
`TREADY`; software must stop capture before changing the source. The physical
AD7771 receiver and its clock-domain crossing remain unchanged.

The simulator has a fractional sample scheduler, a 32-bit phase accumulator,
and a shared 256-entry sine table. Linux converts engineering RMS values into
signed raw peak counts and supplies per-channel Q0.32 phase offsets. Software
also supplies the Q0.32 phase increment, keeping floating-point calculations
and sensor-profile policy outside PL. CH7 remains implemented internally but
is zero and invalid by default.

Configuration is shadowed and committed only between complete eight-channel
frames. `CONTROL[0]` selects the simulator and `CONTROL[1]` enables generation.
The current register contract is:

| Offset | Register |
| ---: | --- |
| `0x00` | Identifier (`SIM1`) |
| `0x04` | Version (`0x00010000`) |
| `0x08` | Shadow control |
| `0x0C` | Shadow sample rate, frame/s |
| `0x10` | Shadow signal frequency, mHz |
| `0x14` | Shadow channel-valid mask |
| `0x18` | Shadow configuration generation |
| `0x1C` | Apply (`bit 0`) |
| `0x20` | Status: source, enable, apply pending, saturation, missed sample |
| `0x24` | Active sample rate |
| `0x28` | Active frequency, mHz |
| `0x2C` | Active valid mask |
| `0x30` | Active configuration generation |
| `0x34` | Generated frame count |
| `0x38` | Saturation count |
| `0x3C` | Missed sample count |
| `0x40`-`0x5C` | Eight signed raw peak-count shadow registers |
| `0x60`-`0x7C` | Eight Q0.32 phase-offset shadow registers |
| `0x80` | Shadow Q0.32 phase step per sample |
| `0x84` | Active control |
| `0x88` | Active Q0.32 phase step |

Peak counts outside the signed 24-bit range saturate and increment the
saturation counter. If downstream backpressure consumes the single pending
sample slot before another scheduled frame can be emitted, the simulator
increments the missed-sample counter rather than silently changing time.

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

The integration test programs the metering AXI4-Lite interfaces, sends real
four-lane AD7771 serial frames, checks both DC-removal modes and the complete
MTR1 record, and verifies that two RMS windows can be captured while the DMA
stream is backpressured. `adc_simulator_tb` separately checks channel order,
phase progression, frame-boundary apply, packet `TLAST`, saturation, missed
samples, and AXI backpressure stability.
