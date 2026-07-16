//Copyright 1986-2022 Xilinx, Inc. All Rights Reserved.
//Copyright 2022-2025 Advanced Micro Devices, Inc. All Rights Reserved.
//--------------------------------------------------------------------------------
//Tool Version: Vivado v.2025.2 (lin64) Build 6299465 Fri Nov 14 12:34:56 MST 2025
//Date        : Wed Jul 15 14:42:24 2026
//Host        : mnc1 running 64-bit Ubuntu 24.04.4 LTS
//Command     : generate_target TopDesign_wrapper.bd
//Design      : TopDesign_wrapper
//Purpose     : IP block netlist
//--------------------------------------------------------------------------------
`timescale 1 ps / 1 ps

module TopDesign_wrapper
   (ADC_CONVST_SAR,
    ADC_DCLK,
    ADC_DOUT,
    ADC_DRDY_N,
    ADC_RESET_N,
    ADC_START_N,
    EXT_ADC_SPI_io0_io,
    EXT_ADC_SPI_io1_io,
    EXT_ADC_SPI_sck_io,
    EXT_ADC_SPI_ss_io,
    KR260_Fan_PWM,
    UF1_LED,
    UF2_LED_tri_o);
  output ADC_CONVST_SAR;
  input ADC_DCLK;
  input [3:0]ADC_DOUT;
  input ADC_DRDY_N;
  output ADC_RESET_N;
  output ADC_START_N;
  inout EXT_ADC_SPI_io0_io;
  inout EXT_ADC_SPI_io1_io;
  inout EXT_ADC_SPI_sck_io;
  inout [0:0]EXT_ADC_SPI_ss_io;
  output [0:0]KR260_Fan_PWM;
  output UF1_LED;
  output [0:0]UF2_LED_tri_o;

  wire ADC_CONVST_SAR;
  wire ADC_DCLK;
  wire [3:0]ADC_DOUT;
  wire ADC_DRDY_N;
  wire ADC_RESET_N;
  wire ADC_START_N;
  wire EXT_ADC_SPI_io0_i;
  wire EXT_ADC_SPI_io0_io;
  wire EXT_ADC_SPI_io0_o;
  wire EXT_ADC_SPI_io0_t;
  wire EXT_ADC_SPI_io1_i;
  wire EXT_ADC_SPI_io1_io;
  wire EXT_ADC_SPI_io1_o;
  wire EXT_ADC_SPI_io1_t;
  wire EXT_ADC_SPI_sck_i;
  wire EXT_ADC_SPI_sck_io;
  wire EXT_ADC_SPI_sck_o;
  wire EXT_ADC_SPI_sck_t;
  wire [0:0]EXT_ADC_SPI_ss_i_0;
  wire [0:0]EXT_ADC_SPI_ss_io_0;
  wire [0:0]EXT_ADC_SPI_ss_o_0;
  wire EXT_ADC_SPI_ss_t;
  wire [0:0]KR260_Fan_PWM;
  wire UF1_LED;
  wire [0:0]UF2_LED_tri_o;

  IOBUF EXT_ADC_SPI_io0_iobuf
       (.I(EXT_ADC_SPI_io0_o),
        .IO(EXT_ADC_SPI_io0_io),
        .O(EXT_ADC_SPI_io0_i),
        .T(EXT_ADC_SPI_io0_t));
  IOBUF EXT_ADC_SPI_io1_iobuf
       (.I(EXT_ADC_SPI_io1_o),
        .IO(EXT_ADC_SPI_io1_io),
        .O(EXT_ADC_SPI_io1_i),
        .T(EXT_ADC_SPI_io1_t));
  IOBUF EXT_ADC_SPI_sck_iobuf
       (.I(EXT_ADC_SPI_sck_o),
        .IO(EXT_ADC_SPI_sck_io),
        .O(EXT_ADC_SPI_sck_i),
        .T(EXT_ADC_SPI_sck_t));
  IOBUF EXT_ADC_SPI_ss_iobuf_0
       (.I(EXT_ADC_SPI_ss_o_0),
        .IO(EXT_ADC_SPI_ss_io[0]),
        .O(EXT_ADC_SPI_ss_i_0),
        .T(EXT_ADC_SPI_ss_t));
  TopDesign TopDesign_i
       (.ADC_CONVST_SAR(ADC_CONVST_SAR),
        .ADC_DCLK(ADC_DCLK),
        .ADC_DOUT(ADC_DOUT),
        .ADC_DRDY_N(ADC_DRDY_N),
        .ADC_RESET_N(ADC_RESET_N),
        .ADC_START_N(ADC_START_N),
        .EXT_ADC_SPI_io0_i(EXT_ADC_SPI_io0_i),
        .EXT_ADC_SPI_io0_o(EXT_ADC_SPI_io0_o),
        .EXT_ADC_SPI_io0_t(EXT_ADC_SPI_io0_t),
        .EXT_ADC_SPI_io1_i(EXT_ADC_SPI_io1_i),
        .EXT_ADC_SPI_io1_o(EXT_ADC_SPI_io1_o),
        .EXT_ADC_SPI_io1_t(EXT_ADC_SPI_io1_t),
        .EXT_ADC_SPI_sck_i(EXT_ADC_SPI_sck_i),
        .EXT_ADC_SPI_sck_o(EXT_ADC_SPI_sck_o),
        .EXT_ADC_SPI_sck_t(EXT_ADC_SPI_sck_t),
        .EXT_ADC_SPI_ss_i(EXT_ADC_SPI_ss_i_0),
        .EXT_ADC_SPI_ss_o(EXT_ADC_SPI_ss_o_0),
        .EXT_ADC_SPI_ss_t(EXT_ADC_SPI_ss_t),
        .KR260_Fan_PWM(KR260_Fan_PWM),
        .UF1_LED(UF1_LED),
        .UF2_LED_tri_o(UF2_LED_tri_o));
endmodule
