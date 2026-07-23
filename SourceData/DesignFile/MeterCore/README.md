# MeterCore

`MeterCore_Wrapper` is the single Vivado module-reference boundary for the
MSAP1 ADC capture and metering datapath. The wrapper is ordinary VHDL for IP
Integrator discovery; `meter_core` and the implementation entities are
VHDL-2008.

The standalone hierarchy is:

```text
AD7771 capture -> ADC conversion -> 16-frame XPM AXI4-Stream FIFO
               -> unified current/voltage RMS
               -> result hub -> MTR1 packetizer
```

The three AXI4-Lite interfaces retain their existing software contracts:

| Interface | Top-level address |
| --- | --- |
| `S_AXI_CAPTURE` | `0xB0020000` |
| `S_AXI_CONVERSION` | `0xB0040000` |
| `S_AXI_PROCESSING` | `0xB0050000` |

`M_AXIS_METER` emits the existing 256-byte MTR1 records as 64 32-bit beats,
with `TLAST` asserted on beat 63. The module-reference clock metadata is
99,999,001 Hz. `adc_dclk` remains an independent ADC-source clock and the
capture entity retains the established CDC implementation.

`TopDesign.bd` instantiates this wrapper directly. System-level IP such as the
Zynq platform, AXI DMA, SmartConnect, AXI Quad SPI, clocks, resets, heartbeat,
and fan routing remains in that single block design; metering datapath logic
remains in the VHDL hierarchy described above.

The conversion-to-processing elasticity buffer is an `xpm_fifo_axis` macro in
common-clock mode. It stores complete converted frames and their AXI4-Stream
metadata without a custom FIFO implementation, generated XCI, or additional
block design.

## Verification

Run the end-to-end mixed-language test and focused synthesis from the
repository root:

```sh
vivado -mode batch -source SourceData/Script/AI_gen/check_meter_core.tcl
vivado -mode batch \
  -source SourceData/Script/AI_gen/check_metering_synthesis.tcl \
  -tclargs MeterCore_Wrapper
```

The integration test programs all three AXI4-Lite interfaces, sends real
four-lane AD7771 serial frames, checks both DC-removal modes and the complete
MTR1 record, and verifies that two RMS windows can be captured while the DMA
stream is backpressured.
