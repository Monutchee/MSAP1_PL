//Copyright 1986-2022 Xilinx, Inc. All Rights Reserved.
//Copyright 2022-2025 Advanced Micro Devices, Inc. All Rights Reserved.
//--------------------------------------------------------------------------------
//Tool Version: Vivado v.2025.2 (lin64) Build 6299465 Fri Nov 14 12:34:56 MST 2025
//Date        : Tue Jul 14 19:32:23 2026
//Host        : mnc1 running 64-bit Ubuntu 24.04.4 LTS
//Command     : generate_target TopDesign_wrapper.bd
//Design      : TopDesign_wrapper
//Purpose     : IP block netlist
//--------------------------------------------------------------------------------
`timescale 1 ps / 1 ps

module TopDesign_wrapper
   (KR260_Fan_PWM,
    UF1_LED,
    UF2_LED_tri_o);
  output [0:0]KR260_Fan_PWM;
  output UF1_LED;
  output [0:0]UF2_LED_tri_o;

  wire [0:0]KR260_Fan_PWM;
  wire UF1_LED;
  wire [0:0]UF2_LED_tri_o;

  TopDesign TopDesign_i
       (.KR260_Fan_PWM(KR260_Fan_PWM),
        .UF1_LED(UF1_LED),
        .UF2_LED_tri_o(UF2_LED_tri_o));
endmodule
