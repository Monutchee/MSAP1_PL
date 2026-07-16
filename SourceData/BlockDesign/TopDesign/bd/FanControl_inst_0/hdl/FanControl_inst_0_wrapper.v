//Copyright 1986-2022 Xilinx, Inc. All Rights Reserved.
//Copyright 2022-2025 Advanced Micro Devices, Inc. All Rights Reserved.
//--------------------------------------------------------------------------------
//Tool Version: Vivado v.2025.2 (lin64) Build 6299465 Fri Nov 14 12:34:56 MST 2025
//Date        : Thu Jul 16 14:19:09 2026
//Host        : mnc1 running 64-bit Ubuntu 24.04.4 LTS
//Command     : generate_target FanControl_inst_0_wrapper.bd
//Design      : FanControl_inst_0_wrapper
//Purpose     : IP block netlist
//--------------------------------------------------------------------------------
`timescale 1 ps / 1 ps

module FanControl_inst_0_wrapper
   (Din_0,
    Fan_PWM);
  input [2:0]Din_0;
  output [0:0]Fan_PWM;

  wire [2:0]Din_0;
  wire [0:0]Fan_PWM;

  FanControl_inst_0 FanControl_inst_0_i
       (.Din_0(Din_0),
        .Fan_PWM(Fan_PWM));
endmodule
