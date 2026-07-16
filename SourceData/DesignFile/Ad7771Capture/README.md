# AD7771 capture module

`Ad7771Capture_Wrapper` is added to `AdcSubSystem.bd` as a Vivado module
reference. It receives the AD7771 four-DOUT data interface and exposes
packetized samples to an AXI DMA.

## Data path

```text
AD7771 DCLK + DRDY + DOUT[3:0]
        -> 4-lane deserializer (8 x header + signed 24-bit sample)
        -> 512-frame asynchronous block-RAM FIFO
        -> 32-bit AXI4-Stream, CH0 through CH7
        -> AXI DMA S2MM
        -> PS DDR
```

The receiver verifies the three-bit channel ID in every header, sign-extends
the sample to 32 bits, and counts frames, FIFO overflows, header errors, and
AD7771 alert headers. A 256-frame packet is 2048 AXI beats or 8192 bytes.

## DRDY framing

The board signal retains the legacy name `ADC_DRDY_N`. In the standalone DOUT
interface, the AD7771 drives it low for most of the conversion interval, pulses
it high before the next output frame, and then drives it low as the new frame
starts. The receiver detects that high-to-low transition and samples the header
MSB on the following DCLK falling edge.

Do not treat the low level as a persistent frame-valid indication. Doing so
causes the receiver to deserialize repeated LSB data continuously between real
frames and destroys header alignment.

## AXI-Lite register map

| Offset | Access | Description |
| ---: | --- | --- |
| `0x00` | R | Version (`0x00010000`) |
| `0x04` | R/W | Control: capture, FIFO reset, RESET, START, CONVST_SAR |
| `0x08` | R/W | Frames per AXI packet |
| `0x0C` | R | Live/sticky status |
| `0x10` | R | Received frame count |
| `0x14` | R | FIFO overflow count |
| `0x18` | R | Header error count |
| `0x1C` | R | Alert-header count |
| `0x20` | R | Emitted packet count |
| `0x24` | R | Format descriptor (`8 channels, 4 lanes, AXIS32`) |
| `0x28` | R | Identifier (`"AD71"`) |

Control bit 3 drives the board signal named `ADC_START_N`, but the physical
AD7771 START pin is a positive synchronization input. The reset value is low;
normal software synchronization uses the AD7771 `SPI_SYNC` register bit.

## Project scripts

- `verify_ad7771_design.tcl` refreshes the module reference, maintains its
  AXI-Lite address assignment, validates the BD, and regenerates output
  products.
- `synth_ad7771_design.tcl` runs full top-level synthesis and focused reports.
- `implement_ad7771_design.tcl` places/routes the design, writes the bitstream,
  produces timing/CDC/DRC/I/O reports, and exports the XSA used by Vitis.
