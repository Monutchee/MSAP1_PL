# AD7771 conversion stage

`AdcConversion_Wrapper` is a Vivado module-reference boundary. It consumes the
existing eight-beat AD7771 raw frame and emits one 512-bit converted frame.
Each 64-bit lane is a signed Q16 value whose integer unit is one microvolt or
one microamp, depending on the configured channel.

`TUSER[383:128]` carries the eight signed raw 32-bit ADC lanes for aggregate
count-domain metering inside PL. It is consumed by `MeterProcessing` and is
never packetized as continuous waveform data for Linux. `TUSER[127:0]` holds
sequence, configuration generation, validity, saturation, and packet status.

The stage contains no board constants. Software writes unsigned Q16.16
micro-unit-per-count coefficients to shadow registers, then commits them with
`CONTROL.APPLY`. A commit takes effect only between frames.

## AXI-Lite registers

| Offset | Name | Description |
| --- | --- | --- |
| `0x00` | `VERSION` | `0x00010000` |
| `0x04` | `IDENTIFIER` | ASCII `ACV1` |
| `0x08` | `CONTROL` | bit 0 write-one `APPLY`; bit 1 shadow enable |
| `0x0c` | `STATUS` | active, apply-pending, saturation-seen |
| `0x10` | `SHADOW_GENERATION` | software configuration generation |
| `0x14` | `SHADOW_VALID_MASK` | one bit per channel |
| `0x18..0x34` | `SHADOW_SCALE[0..7]` | unsigned Q16.16 micro-unit/count |
| `0x38` | `ACTIVE_GENERATION` | committed generation |
| `0x3c` | `ACTIVE_VALID_MASK` | committed channel mask |
| `0x40` | `SAMPLE_SEQUENCE` | completed converted frames |

Vivado integration adds a same-clock AXI4-Stream Data FIFO after
`M_AXIS_CONVERTED`; the RTL intentionally does not hide that IP inside the
module reference. Configure the FIFO for 512-bit `TDATA`, 384-bit `TUSER`,
`TKEEP`, `TLAST`, and a depth of 16 frames.
