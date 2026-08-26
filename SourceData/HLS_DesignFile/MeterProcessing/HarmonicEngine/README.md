# M16 HarmonicEngine and Vivado handoff

The repository-owned M16 path is complete up to explicit vendor-IP and block
design boundaries. `hls_harmonic_engine` consumes seven 4,096-bin XFFT frames
plus one provenance context, classifies orders 1 through 127, and emits one
atomic spectrum family as 42 fixed 256-byte records. The Linux side assembles
all 42 chunks before exposing a latest spectrum.

The block design, anti-alias/resampling IP, XFFT customization, generated XCI,
and routed target verification are intentionally left to the Vivado owner.

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

The A4 16 kSPS / 3,200-sample + zero-padding prototype remains a resource
sizing experiment only. Do not use that zero-padded geometry in production:
its 3.90625 Hz XFFT bins do not coincide with the 5 Hz bins of a 10/12-cycle
analysis interval. The production conditioner must perform a qualified
rational resampling to 4,096 samples per block; it must not merely drop input
frames.

The conditioner owns its characterized anti-alias response. For a full
60 Hz spectrum the passband must cover order 127 (7.62 kHz) below the
10.24 kHz conditioned Nyquist limit. Set

```text
qualified_max_order = min(127, floor(qualified_passband_hz / measured_fundamental_hz))
```

and leave `conditioner_valid` clear until the selected profile's gain,
passband, alias rejection, latency, and rational-rate behavior have been
verified. HarmonicEngine automatically marks orders above that limit
unavailable and sets the rate-limited family status.

## Vendor-neutral frontend

`SourceData/DesignFile/MeterProcessing/meter_spectral_frontend.sv` is the
production ping/pong buffer and channel scheduler. Its default configuration
uses two 4,096 x 168-bit XPM BRAM banks. It accepts one context followed by
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

The standalone production-default out-of-context route used 38 RAMB36,
514 CLB LUTs, and 1,897 registers on `xck26-sfvc784-2LV-c`; its internal
100 MHz timing was +3.264 ns WNS / +0.087 ns WHS with no DRC findings.
Re-run the full routed PL resource/timing gate after integration; these are
not routed system figures.

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

Connect every event output to sticky PL health/counter logic rather than
leaving it open: `event_tlast_unexpected`, `event_tlast_missing`,
`event_status_channel_halt`, `event_data_in_channel_halt`, and
`event_data_out_channel_halt`. `event_frame_started` is an observation pulse,
not a fault, and `event_fft_overflow` is disabled by block-floating-point
mode. The two TLAST events are structurally prevented by the frontend and are
also backed up by HarmonicEngine's output TLAST/XK_INDEX/BLK_EXP checks. Treat
any event-fault count as a failed integration/soak gate and perform a marked
discontinuity recovery; do not silently ignore it.

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

The conditioner and 24-bit normalization must preserve a documented gain. The
seven scales convert one conditioned count into each lane's native micro-unit;
include any deterministic resampler gain in those values.

## Record and block-design wiring

Wire the path in this order:

```text
qualified 10/12-cycle source
  -> anti-alias + rational resampler (vendor IP, 4096 frames/block)
  -> meter_spectral_frontend
       m_axis_fft -> XFFT s_axis_data
       m_axis_context ----------------------+
  -> XFFT (s_axis_config = forward; m_axis_status ready; events -> health)
       m_axis_data -> hls_harmonic_engine s_fft
       frontend context -> hls_harmonic_engine s_context
  -> hls_harmonic_engine m_records
  -> packet-mode AXIS FIFO
  -> MTR_AXI_Switch new S05_AXIS
  -> existing meter DMA
```

`MTR_AXI_Switch` currently has five inputs (S00..S04, with the R5 aggregation
return on S04). Increase `NUM_SI` to 6 and use S05 for harmonics. Use a
packet-mode record FIFO with at least one complete 64-word record of atomic
capacity; 4,096 words is preferred because it holds the complete 42-record
family plus arbitration margin. Keep arbitration on TLAST.

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
42-record golden. The 100 MHz HLS estimate is 150.31 MHz, 1.005--2.847 ms
family latency, 14 BRAM18K, 24 DSP, 5,639 FF, and 8,359 LUT. The final verdict
is the routed full-PL build after the Vivado integration above.
