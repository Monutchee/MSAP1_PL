--Copyright 1986-2022 Xilinx, Inc. All Rights Reserved.
--Copyright 2022-2025 Advanced Micro Devices, Inc. All Rights Reserved.
----------------------------------------------------------------------------------
--Tool Version: Vivado v.2025.2 (lin64) Build 6299465 Fri Nov 14 12:34:56 MST 2025
--Date        : Fri Jul 17 11:25:35 2026
--Host        : mnc1 running 64-bit Ubuntu 24.04.4 LTS
--Command     : generate_target FanControl_inst_0_wrapper.bd
--Design      : FanControl_inst_0_wrapper
--Purpose     : IP block netlist
----------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
library UNISIM;
use UNISIM.VCOMPONENTS.ALL;
entity FanControl_inst_0_wrapper is
  port (
    Din_0 : in STD_LOGIC_VECTOR ( 2 downto 0 );
    Fan_PWM : out STD_LOGIC_VECTOR ( 0 to 0 )
  );
end FanControl_inst_0_wrapper;

architecture STRUCTURE of FanControl_inst_0_wrapper is
  component FanControl_inst_0 is
  port (
    Din_0 : in STD_LOGIC_VECTOR ( 2 downto 0 );
    Fan_PWM : out STD_LOGIC_VECTOR ( 0 to 0 )
  );
  end component FanControl_inst_0;
begin
FanControl_inst_0_i: component FanControl_inst_0
     port map (
      Din_0(2 downto 0) => Din_0(2 downto 0),
      Fan_PWM(0) => Fan_PWM(0)
    );
end STRUCTURE;
