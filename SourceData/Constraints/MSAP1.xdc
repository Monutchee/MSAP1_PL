# AD7771nSPI
# MOSI (Master Out Slave In) - connect IO0 pins
#set_property -dict { PACKAGE_PIN AE13 IOSTANDARD LVCMOS33 } [get_ports {ADC_SPI_io0_io}]

# MISO (Master In Slave Out) - connect IO1 pins
#set_property -dict { PACKAGE_PIN AC13 IOSTANDARD LVCMOS33 } [get_ports {ADC_SPI_io1_io}]

# SCK (Serial Clock) - connect SCK pins
#set_property -dict { PACKAGE_PIN AC14 IOSTANDARD LVCMOS33 } [get_ports {ADC_SPI_sck_io}]

# CS (Chip Select) - connect SS pins
# CS0
#set_property -dict { PACKAGE_PIN AF13 IOSTANDARD LVCMOS33 } [get_ports {ADC_SPI_ss_io[0]}]

# ADC nRST
#set_property -dict { PACKAGE_PIN F8 IOSTANDARD LVCMOS18 } [get_ports ADC_nRST_tri_o ];


# User defined LED
set_property -dict { PACKAGE_PIN F8 IOSTANDARD LVCMOS18 } [get_ports {UF1_LED}]
set_property -dict { PACKAGE_PIN E8 IOSTANDARD LVCMOS18 } [get_ports {UF2_LED_tri_o[0]}]


#fan control
set_property -dict {PACKAGE_PIN A12 IOSTANDARD LVCMOS33} [get_ports {KR260_Fan_PWM[0]}]