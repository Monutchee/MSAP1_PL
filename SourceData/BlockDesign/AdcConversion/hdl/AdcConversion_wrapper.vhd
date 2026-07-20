--Copyright 1986-2022 Xilinx, Inc. All Rights Reserved.
--Copyright 2022-2025 Advanced Micro Devices, Inc. All Rights Reserved.
----------------------------------------------------------------------------------
--Tool Version: Vivado v.2025.2 (lin64) Build 6299465 Fri Nov 14 12:34:56 MST 2025
--Date        : Sun Jul 19 23:18:07 2026
--Host        : mnc1 running 64-bit Ubuntu 24.04.4 LTS
--Command     : generate_target AdcConversion_wrapper.bd
--Design      : AdcConversion_wrapper
--Purpose     : IP block netlist
----------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
library UNISIM;
use UNISIM.VCOMPONENTS.ALL;
entity AdcConversion_wrapper is
  port (
    M_AXIS_0_tdata : out STD_LOGIC_VECTOR ( 511 downto 0 );
    M_AXIS_0_tkeep : out STD_LOGIC_VECTOR ( 63 downto 0 );
    M_AXIS_0_tlast : out STD_LOGIC;
    M_AXIS_0_tready : in STD_LOGIC;
    M_AXIS_0_tuser : out STD_LOGIC_VECTOR ( 383 downto 0 );
    M_AXIS_0_tvalid : out STD_LOGIC;
    s_axi_config_0_araddr : in STD_LOGIC_VECTOR ( 7 downto 0 );
    s_axi_config_0_arready : out STD_LOGIC;
    s_axi_config_0_arvalid : in STD_LOGIC;
    s_axi_config_0_awaddr : in STD_LOGIC_VECTOR ( 7 downto 0 );
    s_axi_config_0_awready : out STD_LOGIC;
    s_axi_config_0_awvalid : in STD_LOGIC;
    s_axi_config_0_bready : in STD_LOGIC;
    s_axi_config_0_bresp : out STD_LOGIC_VECTOR ( 1 downto 0 );
    s_axi_config_0_bvalid : out STD_LOGIC;
    s_axi_config_0_rdata : out STD_LOGIC_VECTOR ( 31 downto 0 );
    s_axi_config_0_rready : in STD_LOGIC;
    s_axi_config_0_rresp : out STD_LOGIC_VECTOR ( 1 downto 0 );
    s_axi_config_0_rvalid : out STD_LOGIC;
    s_axi_config_0_wdata : in STD_LOGIC_VECTOR ( 31 downto 0 );
    s_axi_config_0_wready : out STD_LOGIC;
    s_axi_config_0_wstrb : in STD_LOGIC_VECTOR ( 3 downto 0 );
    s_axi_config_0_wvalid : in STD_LOGIC;
    s_axis_aclk_0 : in STD_LOGIC;
    s_axis_aresetn_0 : in STD_LOGIC;
    s_axis_raw_0_tdata : in STD_LOGIC_VECTOR ( 31 downto 0 );
    s_axis_raw_0_tkeep : in STD_LOGIC_VECTOR ( 3 downto 0 );
    s_axis_raw_0_tlast : in STD_LOGIC;
    s_axis_raw_0_tready : out STD_LOGIC;
    s_axis_raw_0_tvalid : in STD_LOGIC
  );
end AdcConversion_wrapper;

architecture STRUCTURE of AdcConversion_wrapper is
  component AdcConversion is
  port (
    s_axis_raw_0_tdata : in STD_LOGIC_VECTOR ( 31 downto 0 );
    s_axis_raw_0_tkeep : in STD_LOGIC_VECTOR ( 3 downto 0 );
    s_axis_raw_0_tlast : in STD_LOGIC;
    s_axis_raw_0_tvalid : in STD_LOGIC;
    s_axis_raw_0_tready : out STD_LOGIC;
    s_axi_config_0_awaddr : in STD_LOGIC_VECTOR ( 7 downto 0 );
    s_axi_config_0_awvalid : in STD_LOGIC;
    s_axi_config_0_awready : out STD_LOGIC;
    s_axi_config_0_wdata : in STD_LOGIC_VECTOR ( 31 downto 0 );
    s_axi_config_0_wstrb : in STD_LOGIC_VECTOR ( 3 downto 0 );
    s_axi_config_0_wvalid : in STD_LOGIC;
    s_axi_config_0_wready : out STD_LOGIC;
    s_axi_config_0_bresp : out STD_LOGIC_VECTOR ( 1 downto 0 );
    s_axi_config_0_bvalid : out STD_LOGIC;
    s_axi_config_0_bready : in STD_LOGIC;
    s_axi_config_0_araddr : in STD_LOGIC_VECTOR ( 7 downto 0 );
    s_axi_config_0_arvalid : in STD_LOGIC;
    s_axi_config_0_arready : out STD_LOGIC;
    s_axi_config_0_rdata : out STD_LOGIC_VECTOR ( 31 downto 0 );
    s_axi_config_0_rresp : out STD_LOGIC_VECTOR ( 1 downto 0 );
    s_axi_config_0_rvalid : out STD_LOGIC;
    s_axi_config_0_rready : in STD_LOGIC;
    M_AXIS_0_tdata : out STD_LOGIC_VECTOR ( 511 downto 0 );
    M_AXIS_0_tkeep : out STD_LOGIC_VECTOR ( 63 downto 0 );
    M_AXIS_0_tlast : out STD_LOGIC;
    M_AXIS_0_tready : in STD_LOGIC;
    M_AXIS_0_tuser : out STD_LOGIC_VECTOR ( 383 downto 0 );
    M_AXIS_0_tvalid : out STD_LOGIC;
    s_axis_aresetn_0 : in STD_LOGIC;
    s_axis_aclk_0 : in STD_LOGIC
  );
  end component AdcConversion;
begin
AdcConversion_i: component AdcConversion
     port map (
      M_AXIS_0_tdata(511 downto 0) => M_AXIS_0_tdata(511 downto 0),
      M_AXIS_0_tkeep(63 downto 0) => M_AXIS_0_tkeep(63 downto 0),
      M_AXIS_0_tlast => M_AXIS_0_tlast,
      M_AXIS_0_tready => M_AXIS_0_tready,
      M_AXIS_0_tuser(383 downto 0) => M_AXIS_0_tuser(383 downto 0),
      M_AXIS_0_tvalid => M_AXIS_0_tvalid,
      s_axi_config_0_araddr(7 downto 0) => s_axi_config_0_araddr(7 downto 0),
      s_axi_config_0_arready => s_axi_config_0_arready,
      s_axi_config_0_arvalid => s_axi_config_0_arvalid,
      s_axi_config_0_awaddr(7 downto 0) => s_axi_config_0_awaddr(7 downto 0),
      s_axi_config_0_awready => s_axi_config_0_awready,
      s_axi_config_0_awvalid => s_axi_config_0_awvalid,
      s_axi_config_0_bready => s_axi_config_0_bready,
      s_axi_config_0_bresp(1 downto 0) => s_axi_config_0_bresp(1 downto 0),
      s_axi_config_0_bvalid => s_axi_config_0_bvalid,
      s_axi_config_0_rdata(31 downto 0) => s_axi_config_0_rdata(31 downto 0),
      s_axi_config_0_rready => s_axi_config_0_rready,
      s_axi_config_0_rresp(1 downto 0) => s_axi_config_0_rresp(1 downto 0),
      s_axi_config_0_rvalid => s_axi_config_0_rvalid,
      s_axi_config_0_wdata(31 downto 0) => s_axi_config_0_wdata(31 downto 0),
      s_axi_config_0_wready => s_axi_config_0_wready,
      s_axi_config_0_wstrb(3 downto 0) => s_axi_config_0_wstrb(3 downto 0),
      s_axi_config_0_wvalid => s_axi_config_0_wvalid,
      s_axis_aclk_0 => s_axis_aclk_0,
      s_axis_aresetn_0 => s_axis_aresetn_0,
      s_axis_raw_0_tdata(31 downto 0) => s_axis_raw_0_tdata(31 downto 0),
      s_axis_raw_0_tkeep(3 downto 0) => s_axis_raw_0_tkeep(3 downto 0),
      s_axis_raw_0_tlast => s_axis_raw_0_tlast,
      s_axis_raw_0_tready => s_axis_raw_0_tready,
      s_axis_raw_0_tvalid => s_axis_raw_0_tvalid
    );
end STRUCTURE;
