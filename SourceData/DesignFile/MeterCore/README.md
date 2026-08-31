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
               |              -> SCYC/PQ packet FIFOs -> meter DMA
               |              -> private R5C1 export -> returned records
               |                                      -> meter DMA
               |
               +-> nonblocking 256-frame XPM FIFO
                       -> WFM1 packetizer -> waveform DMA
              +-> M16 adaptive L/25 conditioner -> 4K ping/pong frontend
                       -> external XFFT -> embedded HarmonicEngine
                       -> 4096-word record FIFO -> M_AXIS_HARMONIC
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

## Embedded M16 harmonic path

All repository-owned harmonic logic is inside `MeterCore_Wrapper`. The
conditioner observes preserved signed 24-bit raw lanes CH0--CH6. On APPLY it
selects one exact `L/25` conversion, where `L = 512000/Fs`, for every supported
1, 2, 4, 8, 16, 32, 64, or 128 kSPS rate. The measured rate must remain within
1% plus 2 Hz of the selected rate, matching ADC health policy, and the source
interval must be one exact 10-cycle/50 Hz or 12-cycle/60 Hz basic block within
the one-frame endpoint allowance; every valid profile produces 4,096 samples
at 20.48 kSPS. The 32/64/128 kSPS profiles use a 1,025-tap Kaiser prototype;
lower rates use a compact 129-row fractional-delay table with exact-unity
carried-remainder interpolation. Characterized ripple is at most 0.001688 dB,
with high-rate stopbands below -79.65 dBFS and low-rate image bounds below
-88.18 dBFS. Profile-specific 32/64/128/34-frame group delays are reflected
in marker alignment, so provenance remains the first source sample of the
contiguous block. The first complete block after reset or APPLY primes the
filter; unsupported or malformed geometry is invalidated rather than padded
or silently resampled. APPLY also flushes any incomplete conditioner/frontend
transaction so a retired window cannot strand the next profile.

The same hierarchy owns the two-bank 4K frontend, packaged
`hls_harmonic_engine_ip`, forward-transform configuration, XFFT event
accounting, and a 4,096-word packet FIFO. `M_AXIS_HARMONIC` is therefore a
normal 32-bit, TKEEP/TLAST record producer containing 42 consecutive
256-byte records per spectrum family.

The block-design handoff is intentionally limited to one XFFT v9.1 instance
and one record-switch connection:

| MeterCore interface | XFFT / block-design destination |
| --- | --- |
| `M_AXIS_FFT_DATA` | XFFT `S_AXIS_DATA` |
| `S_AXIS_FFT_DATA` | XFFT `M_AXIS_DATA` |
| `M_AXIS_FFT_CONFIG` | XFFT `S_AXIS_CONFIG` |
| `S_AXIS_FFT_STATUS` | XFFT `M_AXIS_STATUS` |
| six `xfft_event_*` inputs | matching XFFT event outputs |
| `M_AXIS_HARMONIC` | `MTR_AXI_Switch/S03_AXIS` |

Use the exact XFFT property dictionary in
`HLS_DesignFile/MeterProcessing/HarmonicEngine/README.md`. All interfaces use
the MeterCore `aclk`/`aresetn`; the shim holds `8'h01` on config until XFFT
accepts it and drains status continuously. The processing read-only registers
`0xCC`--`0xE4` expose conditioner, frontend, and XFFT health for the routed
soak gate.

The repository-side adaptive, pre-XFFT `MeterCore_Wrapper` synthesis on K26 at
100 MHz passes with WNS +2.801 ns and uses 35,010 CLB LUTs (29.89%), 47,950
registers (20.47%), 84 BRAM tiles (58.33%), six URAMs (9.38%), and 243 DSPs
(19.47%). The integrated adaptive conditioner, XFFT, and compact four-input
record-switch route passes at WNS +0.322 ns / TNS 0, using 50,092 LUTs
(42.77%), 71,207 registers (30.40%), 10,424 physical CLBs (71.20%), 109.5
BRAM tiles (76.04%), six URAMs (9.38%), and 247 DSPs (19.79%). The routed
design has zero DRC errors and zero critical warnings.

All meter-record producers emit 256-byte records as 64 32-bit beats with
`TLAST` asserted on beat 63. `MTR_AXI_Switch` has exactly four inputs:
S00 SingleCycle, S01 PQ, S02 R5C1-returned Basic/aggregate records, and S03
harmonics. The retired duplicate Basic/aggregate MeterCore interfaces are
absent. The module-reference clock metadata is 99,999,001 Hz. `adc_dclk`
remains an independent ADC-source clock and the capture entity retains the
established CDC implementation.

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

The simulator's VHDL owns the deterministic infrastructure: a fractional
sample scheduler, a 32-bit phase accumulator, AXIS framing, and the AXI-Lite
shadow/apply register file. The per-frame waveform mathematics lives in the
packaged HLS engine `hls_sim_wave_engine`
(`SourceData/HLS_DesignFile/MeterCore/SimWaveEngine`, beat layout normative
in `sim_wave_engine.hpp` and mirrored by `adc_simulator_pkg.vhd`): an
interpolated quarter-wave sine (4096 points per cycle, 20-bit linear
interpolation; spurs below -100 dBc), per-channel DC offset, and a uniform
white fluctuation of configurable amplitude whose noise words are a
deterministic hash of the frame index, so golden models reproduce them
bit-exactly. Linux converts engineering RMS/DC/noise values into signed raw
counts and supplies per-channel Q0.32 phase offsets plus the Q0.32 phase
increment, keeping floating-point calculations and sensor-profile policy
outside PL. CH7 remains implemented internally but is zero and invalid by
default.

Configuration is shadowed and committed only between complete eight-channel
frames. `CONTROL[0]` selects the simulator, `CONTROL[1]` enables generation,
and `CONTROL[2]` preserves the phase accumulator, scheduler, and packet
framing across the commit (seamless reconfiguration; without it the waveform
restarts deterministically at 0 degrees and packet frame 0). The register
decode is 12 bits wide (4 KB window). The current register contract is:

| Offset | Register |
| ---: | --- |
| `0x00` | Identifier (`SIM1`) |
| `0x04` | Version (`0x00010004`) |
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
| `0x8C`-`0xA8` | Eight signed DC-offset shadow registers, counts |
| `0xAC` | Counter clear (W1C: `0` saturation, `1` missed, `2` frames) |
| `0xB0`-`0xCC` | Eight active DC-offset readbacks |
| `0xD0`-`0xEC` | Eight unsigned noise-amplitude shadow registers, counts |
| `0x100`-`0x11C` | Eight active noise-amplitude readbacks |
| `0x200`-`0x22C` | Four harmonic/interharmonic slots, three words each (shadow) |
| `0x240`-`0x26C` | Four harmonic/interharmonic slots, three words each (active readback) |
| `0x300` | Shadow event control: channel mask `[7:0]`, repeat `[8]` |
| `0x304` | Shadow event scale, unsigned Q16 (`0x10000` unity, cap 4.0) |
| `0x308` | Shadow event timing: duration `[15:0]`, period `[31:16]`, half cycles |
| `0x30C` | Event trigger (W1: `0` arm, `1` cancel, `2` clear count) |
| `0x310` | Event status: armed, running, holding, completed count `[31:16]` |
| `0x314` | Event remaining: burst `[15:0]`, until repeat `[31:16]`, half cycles |
| `0x318`-`0x320` | Active event control / scale / timing readbacks |

Peak counts outside the signed 24-bit range saturate and increment the
saturation counter, as does any sine + DC + noise sum that crosses a rail.
Each spectral-tone slot is `{frequency ratio Q16.16, channel mask plus Q16
fraction, phase Q0.32}`. Integer ratios inject harmonics through order 127;
fractional ratios inject interharmonics while preserving the frequency-scaled
three-phase lane relationship.
The noise amplitude is the half-width of a uniform distribution (RMS =
amplitude / sqrt(3)); zero disables the path. If downstream backpressure consumes the single pending
sample slot before another scheduled frame can be emitted, the simulator
increments the missed-sample counter rather than silently changing time.

### Event sequencer

The event sequencer (metrology M12) is what makes sag, swell, and
interruption scenarios testable without a physical source. It owns a
SECOND shadow bank with its own trigger register, deliberately apart from
the waveform APPLY: a burst launches against a steady configuration
without committing anything else, and starts and ends on the generator's
OWN half-cycle boundaries (the Q0.32 phase accumulator's MSB flipping).
The envelope is therefore phase-continuous by construction -- no APPLY,
no accumulator reset, no discontinuity that could be mistaken for the
event under test.

Only the amplitude multiply travels to the HLS engine, as the request's
event word: a Q16 scale on the PEAK of every masked channel, applied
before the sine and before the harmonic slots. Injected distortion
therefore rides the dip the way it does on a real grid, while the DC
offset and the noise -- ADC artifacts, not grid quantities -- are
untouched. A unity scale or an empty mask leaves the frame bit-identical
to the pre-event datapath.

Timing is counted in HALF CYCLES, matching the resolution of the
Urms(1/2) detector downstream, and never in samples, so an off-nominal or
fractional sample rate cannot skew a burst's programmed length. Writing
ARM with a zero duration is ignored rather than committed as a
zero-length event; a repeat period at or below the duration runs the
bursts back to back (effective period = duration + 1). CANCEL drops the
envelope immediately and does not count the aborted burst. An APPLY that
does not preserve the phase cancels a running burst, since the waveform
it was timed against has restarted.

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
RMS, frequency, and Basic-record production continue without backpressure from the
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

The "frame sequence" latched here is the conversion stage's 64-bit
free-running sample index, delivered with each frame in TUSER (low word in
bits 31:0, high word in bits 105:74). It is the same monotonic measurement
timebase that BASIC-v2 records reference in words 60/61, so a
correlation read maps basic-block sample ranges to UTC directly. Because the
waveform branch taps the stream before the conversion-to-processing
elasticity FIFO while RMS consumes after it, a latched value can lead the RMS
tap by up to the FIFO depth (16 frames, 0.5 ms at 32 kSPS); the counter value
itself travels with the frame and is identical at both taps. The counter is
never reset by configuration apply or by Linux time changes — only by PL
reset.

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
Basic record, and verifies that two RMS windows can be captured while the DMA
stream is backpressured. `adc_simulator_tb` separately checks channel order,
phase progression, frame-boundary apply, packet `TLAST`, saturation, missed
samples, and AXI backpressure stability.
