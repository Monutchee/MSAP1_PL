# M16 HarmonicEngine and Vivado handoff

The repository-owned M16 path is embedded in `MeterCore_Wrapper`.
`hls_harmonic_engine` consumes seven 4,096-bin XFFT frames plus one provenance
context, classifies orders 1 through 127, and emits one spectrum family as 42
fixed 256-byte records. The Linux side assembles all 42 chunks before exposing
a latest spectrum.

The conditioner, spectral ping/pong frontend, packaged HarmonicEngine,
complete-family-capacity record FIFO, XFFT configuration, and fault handling
are internal. The Vivado owner adds only one XFFT v9.1 customization, connects
its four AXIS interfaces and event pins, and connects the dedicated
`M_AXIS_HARMONIC` producer to the record switch.

On a project that predates M16, register the packaged IP and maintained RTL
sources before synthesis:

```sh
vivado -mode batch -source SourceData/Script/register_hls_components.tcl
vivado -mode batch -source SourceData/Script/register_m16_harmonic_sources.tcl
```

## Production geometry

Every spectrum covers one contiguous grid-synchronous basic block:

- 10 cycles at a declared 50 Hz nominal;
- 12 cycles at a declared 60 Hz nominal;
- exactly 4,096 conditioned samples over that block; and
- seven lanes in order CH0 through CH6 (IA, IB, IC, IN, VC, VB, VA).

This makes the effective analysis cadence 20.48 kframe/s for a nominal
200 ms block and places the fundamental exactly at bin 10 or 12. Harmonic
order `h` is therefore centered at bin `10*h` or `12*h`, which is the contract
implemented by HarmonicEngine.

Increasing XFFT length alone does not improve the measurement resolution. A
4,096-point transform over the required 200 ms interval already has true 5 Hz
bin spacing. Zero-padding to 8,192 only interpolates that spectrum, while
collecting 8,192 real samples at 20.48 kSPS would double the interval to
400 ms and violate the 10/12-cycle family contract.

The A4 16 kSPS / 3,200-sample + zero-padding prototype remains a resource
sizing experiment only. Do not use that zero-padded geometry in production:
its 3.90625 Hz XFFT bins do not coincide with the 5 Hz bins of a 10/12-cycle
analysis interval. The production conditioner must perform a qualified
rational resampling to 4,096 samples per block; it must not merely drop input
frames.

### Embedded adaptive conditioner

`meter_spectral_conditioner` implements the production conversion directly:

- every selectable source rate uses the exact rational ratio `L/25`, where
  `L = 512000/Fs`;
- every valid 200 ms source block becomes exactly 4,096 frames at 20.48 kSPS;
- a 512-frame BRAM history ring and 16-entry marker queue accept source frames
  independently of the seven-lane, time-shared MAC; and
- each Q20 phase has exact unity DC gain.

| ID | Fs (kSPS) | L | Source frames | Taps | Delay | Max order 50/60 Hz |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 32 | 16 | 6,400 | 65 | 32 | 127 / 127 |
| 2 | 64 | 8 | 12,800 | 129 | 64 | 127 / 127 |
| 3 | 128 | 4 | 25,600 | 257 | 128 | 127 / 127 |
| 4 | 16 | 32 | 3,200 | 69 | 34 | 127 / 106 |
| 5 | 8 | 64 | 1,600 | 69 | 34 | 64 / 53 |
| 6 | 4 | 128 | 800 | 69 | 34 | 32 / 26 |
| 7 | 2 | 256 | 400 | 69 | 34 | 16 / 13 |
| 8 | 1 | 512 | 200 | 69 | 34 | 8 / 6 |

The 32/64/128 kSPS profiles share a 1,025-tap Kaiser prototype on the 512 kHz
interpolation grid. Lower rates use a compact 129-row endpoint-inclusive
fractional-delay table; a tap-carried interpolation remainder preserves exact
Q20 unity without a correction ROM. The maintained reproducer reports no more
than 0.001688 dB passband ripple, high-rate stopbands below -79.65 dBFS, and
low-rate image bounds below -88.18 dBFS.

The first complete block after reset or APPLY primes history and marker
alignment. `conditioner_valid` is set only for a locked 50 Hz/10-cycle or
60 Hz/12-cycle block with valid frequency, a measured rate within the ADC
health tolerance of the selected profile (1% plus 2 Hz), and that profile's
exact source-frame count within the one-frame endpoint allowance. APPLY flushes
the conditioner token/history transaction and any incomplete frontend capture
as one boundary. Unsupported rates or malformed geometry are structurally
invalidated; the conditioner selects among the eight characterized profiles
and does not claim an arbitrary off-nominal-rate resampler.

## Vendor-neutral frontend

`SourceData/DesignFile/MeterProcessing/meter_spectral_frontend.vhd` is the
embedded production ping/pong buffer and channel scheduler. Its default
configuration uses two 4,096 x 168-bit XPM URAM banks (three K26 URAMs per
bank). It accepts one context followed by
4,096 simultaneous 7 x 24-bit real frames with TLAST on frame 4,095, then
serializes seven real-valued complex frames to the shared XFFT.

Important behavior:

- sample input is observational and always ready; it cannot backpressure ADC
  acquisition;
- a malformed TLAST invalidates the whole input window;
- if both banks are occupied, the whole next window is consumed and counted
  as dropped;
- context is emitted exactly once before the associated seven FFT frames;
- FFT input order is CH0, CH1, ... CH6, with 4,096 beats and TLAST per channel;
- the frontend patches context bits 319:288 with its complete-window drop
  counter snapshot; and
- `USE_XPM=1` is the production setting. `USE_XPM=0` exists only for the
  small behavioral testbench.

The earlier BRAM sizing route used 38 RAMB36. The embedded production setting
deliberately moves that storage to six URAMs so the external XFFT and the rest
of TopDesign retain BRAM headroom. The final pre-XFFT `MeterCore_Wrapper`
focused synthesis on K26 at 100 MHz passes with WNS +2.801 ns and uses 35,010
CLB LUTs (29.89%), 47,950 registers (20.47%), 84 BRAM tiles (58.33%), six
URAMs (9.38%), and 243 DSPs (19.47%). The integrated adaptive conditioner,
XFFT, and compact switch route passes at WNS +0.322 ns / TNS 0, with 50,092
LUTs (42.77%), 71,207 registers (30.40%), 10,424 physical CLBs (71.20%),
109.5 BRAM tiles (76.04%), six URAMs (9.38%), and 247 DSPs (19.79%). It has
zero DRC errors and zero critical warnings. Bitstream/XSA generation and the
target soak remain separate release gates.

## XFFT v9.1 customization

Create one AMD/Xilinx FFT v9.1 instance with this contract:

| Setting | Required value |
| --- | --- |
| Transform length | 4,096 |
| Channels | 1 (the frontend serializes seven frames) |
| Direction | Forward |
| Data format | Fixed point |
| Input width | 24 bits |
| Output width | 24 bits |
| Scaling | Block floating point |
| Output ordering | Bit-reversed |
| TDATA | `{imag[23:0], real[23:0]}` |
| TUSER | XK_INDEX then byte padding then BLK_EXP |
| TUSER layout consumed by HLS | `[11:0] XK_INDEX`, `[15:12] 0`, `[20:16] BLK_EXP`, `[23:21] 0` |
| TLAST | Beat 4,095 of every channel frame |

Bit-reversed output avoids a reorder buffer; HarmonicEngine treats XK_INDEX,
not arrival order, as the bin identity. BLK_EXP must remain constant within a
channel frame.

The following dictionary was accepted by the installed Vivado 2025.2 XFFT
v9.1 core for `xck26-sfvc784-2LV-c`. It generates `s_axis_config_tdata[7:0]`,
`m_axis_data_tdata[47:0]`, and `m_axis_data_tuser[23:0]` with the field layout
above:

```tcl
set_property -dict [list \
  CONFIG.channels {1} \
  CONFIG.transform_length {4096} \
  CONFIG.implementation_options {radix_2_lite_burst_io} \
  CONFIG.input_width {24} \
  CONFIG.phase_factor_width {24} \
  CONFIG.data_format {fixed_point} \
  CONFIG.scaling_options {block_floating_point} \
  CONFIG.output_ordering {bit_reversed_order} \
  CONFIG.xk_index {true} \
  CONFIG.memory_options_data {block_ram} \
  CONFIG.memory_options_phase_factors {block_ram} \
  CONFIG.memory_options_reorder {block_ram} \
  CONFIG.butterfly_type {use_luts} \
  CONFIG.complex_mult_type {use_mults_resources} \
  CONFIG.aresetn {true} \
  CONFIG.target_clock_frequency {100}] [get_ips <your_xfft_ip_name>]
```

After reset, send one `s_axis_config` transfer with `TDATA=8'h01`: bit 0 is
`FWD_INV`, where 1 selects forward, and bits 7:1 are zero. Hold TVALID and
TDATA until TREADY accepts the transfer; do not start frontend data before
that handshake. The configuration remains forward unless another config beat
is sent. Tie `m_axis_status_tready` high even though HarmonicEngine obtains
BLK_EXP from data TUSER.

Connect every event output to the matching `MeterCore_Wrapper` input rather
than leaving it open: `event_tlast_unexpected`, `event_tlast_missing`,
`event_status_channel_halt`, `event_data_in_channel_halt`, and
`event_data_out_channel_halt`. `event_frame_started` is an observation pulse,
not a fault, and `event_fft_overflow` is disabled by block-floating-point
mode. The shim folds all fault events into a family-wide structural marker at
TUSER bit 12, which HarmonicEngine checks alongside output TLAST, XK_INDEX,
and BLK_EXP. It also exposes a saturating event-cycle count at processing
register `0xE4`. Treat any nonzero count as a failed integration/soak gate.

## HarmonicEngine context

One 576-bit beat precedes the seven XFFT output frames:

| Bits | Field |
| --- | --- |
| 31:0 | configuration generation |
| 63:32 | source sample rate in frames/s |
| 95:64 | source frames covered by the basic block |
| 103:96 | active lane mask |
| 111:104 | grid locked, conditioner valid, first-after-discontinuity, rate-limited flags |
| 119:112 | nominal frequency, 50 or 60 |
| 127:120 | cycle count, 10 or 12 |
| 135:128 | qualified maximum order |
| 143:136 | characterized conditioner profile ID |
| 159:144 | reserved zero |
| 191:160 | measured fundamental frequency in millihertz |
| 255:192 | first source-sample index |
| 287:256 | downstream complete-record drops |
| 319:288 | complete source-window drops, patched by the frontend |
| 543:320 | seven Q16.16 micro-unit/count scales |
| 575:544 | reserved zero |

Every polyphase phase has exact unity DC gain in Q20. The seven scales are the
active ADC-conversion Q16.16 micro-unit/count values exported directly from
`adc_conversion`; no hidden conditioner scale correction is required.

## Record and block-design wiring

The implemented boundary is:

```text
MeterCore raw frame observer
  -> embedded adaptive L/25 conditioner -> embedded 4K frontend
  -> M_AXIS_FFT_DATA ---------> XFFT S_AXIS_DATA
  <- S_AXIS_FFT_DATA <--------- XFFT M_AXIS_DATA
  -> M_AXIS_FFT_CONFIG -------> XFFT S_AXIS_CONFIG
  <- S_AXIS_FFT_STATUS <------- XFFT M_AXIS_STATUS
  <- xfft_event_* <------------ XFFT event outputs
  -> embedded HarmonicEngine -> embedded 4096-word packet FIFO
  -> M_AXIS_HARMONIC -> MTR_AXI_Switch/S03_AXIS -> existing meter DMA
```

`MTR_AXI_Switch` has exactly four inputs: S00 SingleCycle packet FIFO, S01 PQ
packet FIFO, S02 R5 aggregation return, and S03 harmonics. The required
4,096-word XPM packet FIFO is already inside MeterCore and has capacity for all
42 x 64-word records plus margin; do not add a duplicate external FIFO. Keep
True Round-Robin switch arbitration on TLAST, with maximum-transfer and cycle
arbitration disabled.

Do not put sample payloads on RPMsg. R5C0 changes in this milestone only
extend the simulator configuration ABI for fractional harmonic/interharmonic
tones; the spectrum continues through the Linux-owned meter DMA.

## HLS build and verification

The component participates in the normal all-component flow:

```sh
./mnc HLS build
```

For a focused iteration from the PL repository:

```sh
SourceData/HLS_DesignFile/run_hls.sh \
  SourceData/HLS_DesignFile/MeterProcessing/HarmonicEngine
```

The focused C simulation, synthesis, and C/RTL co-simulation pass with the
42-record golden and structural-fault rejection. The 100 MHz HLS estimate is
6.653 ns, 0.718--2.560 ms family latency, 14 BRAM18K, 26 DSP, 5,702 FF, and
8,466 LUT. `check_meter_core.tcl` also runs the coefficient-response check,
conditioner geometry/DC test, frontend fault/framing test, and complete
MeterCore elaboration. The final integrated full-PL route with XFFT and the
compact switch passes timing; bitstream/XSA and target tests remain release
gates.
