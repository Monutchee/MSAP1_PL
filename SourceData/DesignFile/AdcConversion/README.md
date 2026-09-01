# AD7771 conversion stage

`AdcConversion_Wrapper` is a Vivado module-reference boundary. It consumes the
existing eight-beat AD7771 raw frame and emits one 384-bit converted frame.
Each 48-bit lane is a signed Q16 value whose integer unit is one microvolt or
one microamp, depending on the configured channel.

The 48-bit lane is the high-rate transport and multiplier-input contract. It
retains 16 fractional bits and 31 magnitude bits above the sign, covering
approximately +/-2147 V or +/-2147 A in micro-units. Meter result fields and
the 64/96/128-bit accumulators remain wide; narrowing the stream therefore
reduces routing and multiplier cost without narrowing accumulated results.

`TUSER[383:128]` carries the eight signed raw 32-bit ADC lanes for aggregate
count-domain metering inside PL. It is consumed by `MeterProcessing` and is
never packetized as continuous waveform data for Linux. `TUSER[127:0]` holds
the sample index, configuration generation, validity, saturation, and packet
status.

The sample index is a 64-bit free-running measurement timebase counting
accepted complete frames from PL reset. It is never reset or stepped by
configuration apply or Linux time changes, so grid-cycle timing and basic
measurement blocks can reference ADC samples unambiguously for the product
lifetime (a 64-bit counter cannot wrap at any supported rate). The low word
stays in `TUSER[31:0]` for existing consumers; the high word rides in
`TUSER[105:74]` (see `metering_pkg`). The `SAMPLE_SEQUENCE` register keeps
exposing the low 32 bits.

The stage contains no board constants. Software writes unsigned Q16.16
micro-unit-per-count coefficients and the current-input wiring to shadow
registers, then commits them with `CONTROL.APPLY`. A commit takes effect only
between frames. Current coefficients remain indexed by physical ADC channel;
CH0--CH3 are then routed to logical Ia/Ib/Ic/In and optionally inverted. The
raw TUSER lanes and exported scale provenance use that same logical order.

## AXI-Lite registers

| Offset | Name | Description |
| --- | --- | --- |
| `0x00` | `VERSION` | `0x00010001` |
| `0x04` | `IDENTIFIER` | ASCII `ACV1` |
| `0x08` | `CONTROL` | bit 0 write-one `APPLY`; bit 1 shadow enable |
| `0x0c` | `STATUS` | active, apply-pending, saturation-seen |
| `0x10` | `SHADOW_GENERATION` | software configuration generation |
| `0x14` | `SHADOW_VALID_MASK` | one bit per channel |
| `0x18..0x34` | `SHADOW_SCALE[0..7]` | unsigned Q16.16 micro-unit/count |
| `0x38` | `ACTIVE_GENERATION` | committed generation |
| `0x3c` | `ACTIVE_VALID_MASK` | committed channel mask |
| `0x40` | `SAMPLE_SEQUENCE` | completed converted frames |
| `0x44` | `SHADOW_CURRENT_WIRING` | CH0..3 phase map in bits 0..7; CH0..3 inversion in bits 8..11 |
| `0x48` | `ACTIVE_CURRENT_WIRING` | committed current wiring |

Each two-bit phase code is `0=A`, `1=B`, `2=C`, or `3=N`, indexed by physical
ADC channel. The four codes must form a permutation. The reset value is
`0x000000e4` (CH0=A, CH1=B, CH2=C, CH3=N, all normal). An invalid shadow map
does not commit and sets STATUS bit 3. STATUS bit 2 is also asserted when
reversing the signed-24-bit minimum requires clamping to the positive rail.

`MeterCore` buffers this stream with AMD `xpm_fifo_axis` in the same clock
domain. The FIFO is configured for 384-bit `TDATA`, 384-bit `TUSER`, `TKEEP`,
`TLAST`, and a depth of 16 frames.
