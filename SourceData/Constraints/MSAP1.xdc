# AD7771 sensor board on the KR260 Raspberry Pi header.
# Comments name the SOM240_2 connector position from the KR260 schematic;
# PACKAGE_PIN names the corresponding XCK26 device ball from XTP685.
# AXI Quad SPI standard-mode pin mapping: IO0=MOSI, IO1=MISO.
#
# DRIVE/SLEW are stated explicitly rather than inherited. The AD7771 sits on
# a 200 mm unshielded flying lead, which is several times the length at which
# an FPGA edge starts behaving as a transmission line, so the edge rate on
# these pins is a real design parameter and not a detail to leave at
# whatever the tool defaults to. SLEW SLOW is already the LVCMOS default;
# naming it documents the intent and stops a future default change from
# silently altering the interface.
#
# The two output roles are constrained differently on purpose:
#
#   IO0/MOSI, SS - carry data and framing, sampled by the ADC at a defined
#                  instant, so a softer edge costs nothing and lowers what
#                  they couple into their neighbours. DRIVE 8.
#
#   SCK          - kept at full DRIVE 12. It is tempting to soften the clock
#                  too, since it is the aggressor sitting next to MOSI, but a
#                  slow edge lingers near the ADC's input threshold, and a
#                  noise glitch there is read as an EXTRA CLOCK. That
#                  desynchronises the whole frame, which is exactly the
#                  observed failure (SPI_INVALID_READ_ERR plus a misframed
#                  reply). A clock wants the cleanest, fastest threshold
#                  crossing available; reflections belong to series
#                  termination at the driver, not to a weaker driver.
#
# IO1/MISO is an INPUT. DRIVE and SLEW are output-only properties and do not
# apply; its signal quality is set by the ADC's SDO_DRIVE_STR register and by
# the cable, neither of which this file reaches.
set_property -dict { PACKAGE_PIN AE13 IOSTANDARD LVCMOS33 DRIVE 8  SLEW SLOW } [get_ports {EXT_ADC_SPI_io0_io}]  ;# SOM240_2 C59, HDC10
set_property -dict { PACKAGE_PIN AC13 IOSTANDARD LVCMOS33 }                    [get_ports {EXT_ADC_SPI_io1_io}]  ;# SOM240_2 C58, HDC09
set_property -dict { PACKAGE_PIN AC14 IOSTANDARD LVCMOS33 DRIVE 12 SLEW SLOW } [get_ports {EXT_ADC_SPI_sck_io}]  ;# SOM240_2 C56, HDC08_CC
set_property -dict { PACKAGE_PIN AF13 IOSTANDARD LVCMOS33 DRIVE 8  SLEW SLOW } [get_ports {EXT_ADC_SPI_ss_io[0]}] ;# SOM240_2 C60, HDC11

# The SPI pins carry no timing constraints, deliberately. SCK is generated
# inside the AXI Quad SPI core from divided AXI clock logic, not forwarded
# through an ODDR, so there is no port for create_generated_clock to hang a
# verified source-synchronous relationship on. Vivado ships no such
# constraints for this IP either. It is also unnecessary: at ratio 16 the bit
# period is 160 ns against the AD7771's 5 ns SDI setup/hold (t20/t21), so
# routing skew has roughly thirty times the margin it needs. Pin-level timing
# is not the fault here and constraining it would only add risk.

# Four-lane source-synchronous conversion-data interface.
set_property -dict { PACKAGE_PIN Y13  IOSTANDARD LVCMOS33 } [get_ports {ADC_DOUT[0]}] ;# SOM240_2 A55, HDC19
set_property -dict { PACKAGE_PIN AB13 IOSTANDARD LVCMOS33 } [get_ports {ADC_DOUT[1]}] ;# SOM240_2 B53, HDC13
set_property -dict { PACKAGE_PIN AG13 IOSTANDARD LVCMOS33 } [get_ports {ADC_DOUT[2]}] ;# SOM240_2 C54, HDC06
set_property -dict { PACKAGE_PIN AH14 IOSTANDARD LVCMOS33 } [get_ports {ADC_DOUT[3]}] ;# SOM240_2 D58, HDC05
set_property -dict { PACKAGE_PIN AB15 IOSTANDARD LVCMOS33 } [get_ports {ADC_DCLK}]    ;# SOM240_2 B57, HDC16_CC
set_property -dict { PACKAGE_PIN AA13 IOSTANDARD LVCMOS33 } [get_ports {ADC_DRDY_N}]  ;# SOM240_2 B52, HDC12

# ADC hardware control outputs.
set_property -dict { PACKAGE_PIN AH13 IOSTANDARD LVCMOS33 } [get_ports {ADC_RESET_N}]    ;# SOM240_2 C55, HDC07
set_property -dict { PACKAGE_PIN W11  IOSTANDARD LVCMOS33 } [get_ports {ADC_START_N}]    ;# SOM240_2 A58, HDC21
set_property -dict { PACKAGE_PIN W12  IOSTANDARD LVCMOS33 } [get_ports {ADC_CONVST_SAR}] ;# SOM240_2 A56, HDC20

# The selected four-lane format keeps DCLK at the board's 8.192 MHz MCLK for
# every ODR. Constrain that fixed source-synchronous clock directly.
create_clock -name ADC_DCLK -period 122.070 [get_ports {ADC_DCLK}]

# AD7771 Table 2 guarantees every DOUT bit for at least 20 ns before and
# after the falling DCLK edge.  The receiver captures on that falling edge.
set_input_delay -clock [get_clocks ADC_DCLK] -clock_fall -max -20.000 \
    [get_ports {ADC_DOUT[*]}]
set_input_delay -clock [get_clocks ADC_DCLK] -clock_fall -min 20.000 \
    [get_ports {ADC_DOUT[*]}]


# User defined LED
set_property -dict { PACKAGE_PIN F8 IOSTANDARD LVCMOS18 } [get_ports {UF1_LED}]
set_property -dict { PACKAGE_PIN E8 IOSTANDARD LVCMOS18 } [get_ports {UF2_LED_tri_o[0]}]


#fan control
set_property -dict {PACKAGE_PIN A12 IOSTANDARD LVCMOS33} [get_ports {KR260_Fan_PWM[0]}]
