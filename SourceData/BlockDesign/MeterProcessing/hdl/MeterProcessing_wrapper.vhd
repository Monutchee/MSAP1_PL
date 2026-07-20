--Copyright 1986-2022 Xilinx, Inc. All Rights Reserved.
--Copyright 2022-2025 Advanced Micro Devices, Inc. All Rights Reserved.
----------------------------------------------------------------------------------
--Tool Version: Vivado v.2025.2 (lin64) Build 6299465 Fri Nov 14 12:34:56 MST 2025
--Date        : Sun Jul 19 23:18:07 2026
--Host        : mnc1 running 64-bit Ubuntu 24.04.4 LTS
--Command     : generate_target MeterProcessing_wrapper.bd
--Design      : MeterProcessing_wrapper
--Purpose     : IP block netlist
----------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
library UNISIM;
use UNISIM.VCOMPONENTS.ALL;
entity MeterProcessing_wrapper is
  port (
    S_AXIS_0_tdata : in STD_LOGIC_VECTOR ( 511 downto 0 );
    S_AXIS_0_tkeep : in STD_LOGIC_VECTOR ( 63 downto 0 );
    S_AXIS_0_tlast : in STD_LOGIC;
    S_AXIS_0_tready : out STD_LOGIC;
    S_AXIS_0_tuser : in STD_LOGIC_VECTOR ( 383 downto 0 );
    S_AXIS_0_tvalid : in STD_LOGIC;
    aclk_0 : in STD_LOGIC;
    aresetn_0 : in STD_LOGIC;
    capture_alerts_i_0 : in STD_LOGIC_VECTOR ( 31 downto 0 );
    capture_frame_count_i_0 : in STD_LOGIC_VECTOR ( 31 downto 0 );
    capture_header_errors_i_0 : in STD_LOGIC_VECTOR ( 31 downto 0 );
    capture_overflows_i_0 : in STD_LOGIC_VECTOR ( 31 downto 0 );
    m_axis_meter_0_tdata : out STD_LOGIC_VECTOR ( 31 downto 0 );
    m_axis_meter_0_tkeep : out STD_LOGIC_VECTOR ( 3 downto 0 );
    m_axis_meter_0_tlast : out STD_LOGIC;
    m_axis_meter_0_tready : in STD_LOGIC;
    m_axis_meter_0_tvalid : out STD_LOGIC;
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
    s_axi_config_0_wvalid : in STD_LOGIC
  );
end MeterProcessing_wrapper;

architecture STRUCTURE of MeterProcessing_wrapper is
  component MeterProcessing is
  port (
    S_AXIS_0_tdata : in STD_LOGIC_VECTOR ( 511 downto 0 );
    S_AXIS_0_tkeep : in STD_LOGIC_VECTOR ( 63 downto 0 );
    S_AXIS_0_tlast : in STD_LOGIC;
    S_AXIS_0_tready : out STD_LOGIC;
    S_AXIS_0_tuser : in STD_LOGIC_VECTOR ( 383 downto 0 );
    S_AXIS_0_tvalid : in STD_LOGIC;
    m_axis_meter_0_tdata : out STD_LOGIC_VECTOR ( 31 downto 0 );
    m_axis_meter_0_tkeep : out STD_LOGIC_VECTOR ( 3 downto 0 );
    m_axis_meter_0_tlast : out STD_LOGIC;
    m_axis_meter_0_tvalid : out STD_LOGIC;
    m_axis_meter_0_tready : in STD_LOGIC;
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
    aresetn_0 : in STD_LOGIC;
    aclk_0 : in STD_LOGIC;
    capture_frame_count_i_0 : in STD_LOGIC_VECTOR ( 31 downto 0 );
    capture_header_errors_i_0 : in STD_LOGIC_VECTOR ( 31 downto 0 );
    capture_overflows_i_0 : in STD_LOGIC_VECTOR ( 31 downto 0 );
    capture_alerts_i_0 : in STD_LOGIC_VECTOR ( 31 downto 0 )
  );
  end component MeterProcessing;
begin
MeterProcessing_i: component MeterProcessing
     port map (
      S_AXIS_0_tdata(511 downto 0) => S_AXIS_0_tdata(511 downto 0),
      S_AXIS_0_tkeep(63 downto 0) => S_AXIS_0_tkeep(63 downto 0),
      S_AXIS_0_tlast => S_AXIS_0_tlast,
      S_AXIS_0_tready => S_AXIS_0_tready,
      S_AXIS_0_tuser(383 downto 0) => S_AXIS_0_tuser(383 downto 0),
      S_AXIS_0_tvalid => S_AXIS_0_tvalid,
      aclk_0 => aclk_0,
      aresetn_0 => aresetn_0,
      capture_alerts_i_0(31 downto 0) => capture_alerts_i_0(31 downto 0),
      capture_frame_count_i_0(31 downto 0) => capture_frame_count_i_0(31 downto 0),
      capture_header_errors_i_0(31 downto 0) => capture_header_errors_i_0(31 downto 0),
      capture_overflows_i_0(31 downto 0) => capture_overflows_i_0(31 downto 0),
      m_axis_meter_0_tdata(31 downto 0) => m_axis_meter_0_tdata(31 downto 0),
      m_axis_meter_0_tkeep(3 downto 0) => m_axis_meter_0_tkeep(3 downto 0),
      m_axis_meter_0_tlast => m_axis_meter_0_tlast,
      m_axis_meter_0_tready => m_axis_meter_0_tready,
      m_axis_meter_0_tvalid => m_axis_meter_0_tvalid,
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
      s_axi_config_0_wvalid => s_axi_config_0_wvalid
    );
end STRUCTURE;
