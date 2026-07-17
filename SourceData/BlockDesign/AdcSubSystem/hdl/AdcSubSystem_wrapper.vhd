--Copyright 1986-2022 Xilinx, Inc. All Rights Reserved.
--Copyright 2022-2025 Advanced Micro Devices, Inc. All Rights Reserved.
----------------------------------------------------------------------------------
--Tool Version: Vivado v.2025.2 (lin64) Build 6299465 Fri Nov 14 12:34:56 MST 2025
--Date        : Fri Jul 17 10:48:58 2026
--Host        : mnc1 running 64-bit Ubuntu 24.04.4 LTS
--Command     : generate_target AdcSubSystem_wrapper.bd
--Design      : AdcSubSystem_wrapper
--Purpose     : IP block netlist
----------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
library UNISIM;
use UNISIM.VCOMPONENTS.ALL;
entity AdcSubSystem_wrapper is
  port (
    ADC_CONVST_SAR : out STD_LOGIC;
    ADC_DCLK : in STD_LOGIC;
    ADC_DOUT : in STD_LOGIC_VECTOR ( 3 downto 0 );
    ADC_DRDY_N : in STD_LOGIC;
    ADC_RESET_N : out STD_LOGIC;
    ADC_SPI_io0_io : inout STD_LOGIC;
    ADC_SPI_io1_io : inout STD_LOGIC;
    ADC_SPI_sck_io : inout STD_LOGIC;
    ADC_SPI_ss_io : inout STD_LOGIC_VECTOR ( 0 to 0 );
    ADC_START_N : out STD_LOGIC;
    M_AXIS_SAMPLES_tdata : out STD_LOGIC_VECTOR ( 31 downto 0 );
    M_AXIS_SAMPLES_tkeep : out STD_LOGIC_VECTOR ( 3 downto 0 );
    M_AXIS_SAMPLES_tlast : out STD_LOGIC;
    M_AXIS_SAMPLES_tready : in STD_LOGIC;
    M_AXIS_SAMPLES_tvalid : out STD_LOGIC;
    S00_AXI_0_araddr : in STD_LOGIC_VECTOR ( 31 downto 0 );
    S00_AXI_0_arburst : in STD_LOGIC_VECTOR ( 1 downto 0 );
    S00_AXI_0_arcache : in STD_LOGIC_VECTOR ( 3 downto 0 );
    S00_AXI_0_arlen : in STD_LOGIC_VECTOR ( 7 downto 0 );
    S00_AXI_0_arlock : in STD_LOGIC_VECTOR ( 0 to 0 );
    S00_AXI_0_arprot : in STD_LOGIC_VECTOR ( 2 downto 0 );
    S00_AXI_0_arqos : in STD_LOGIC_VECTOR ( 3 downto 0 );
    S00_AXI_0_arready : out STD_LOGIC;
    S00_AXI_0_arsize : in STD_LOGIC_VECTOR ( 2 downto 0 );
    S00_AXI_0_arvalid : in STD_LOGIC;
    S00_AXI_0_awaddr : in STD_LOGIC_VECTOR ( 31 downto 0 );
    S00_AXI_0_awburst : in STD_LOGIC_VECTOR ( 1 downto 0 );
    S00_AXI_0_awcache : in STD_LOGIC_VECTOR ( 3 downto 0 );
    S00_AXI_0_awlen : in STD_LOGIC_VECTOR ( 7 downto 0 );
    S00_AXI_0_awlock : in STD_LOGIC_VECTOR ( 0 to 0 );
    S00_AXI_0_awprot : in STD_LOGIC_VECTOR ( 2 downto 0 );
    S00_AXI_0_awqos : in STD_LOGIC_VECTOR ( 3 downto 0 );
    S00_AXI_0_awready : out STD_LOGIC;
    S00_AXI_0_awsize : in STD_LOGIC_VECTOR ( 2 downto 0 );
    S00_AXI_0_awvalid : in STD_LOGIC;
    S00_AXI_0_bready : in STD_LOGIC;
    S00_AXI_0_bresp : out STD_LOGIC_VECTOR ( 1 downto 0 );
    S00_AXI_0_bvalid : out STD_LOGIC;
    S00_AXI_0_rdata : out STD_LOGIC_VECTOR ( 31 downto 0 );
    S00_AXI_0_rlast : out STD_LOGIC;
    S00_AXI_0_rready : in STD_LOGIC;
    S00_AXI_0_rresp : out STD_LOGIC_VECTOR ( 1 downto 0 );
    S00_AXI_0_rvalid : out STD_LOGIC;
    S00_AXI_0_wdata : in STD_LOGIC_VECTOR ( 31 downto 0 );
    S00_AXI_0_wlast : in STD_LOGIC;
    S00_AXI_0_wready : out STD_LOGIC;
    S00_AXI_0_wstrb : in STD_LOGIC_VECTOR ( 3 downto 0 );
    S00_AXI_0_wvalid : in STD_LOGIC;
    ext_spi_clk_0 : in STD_LOGIC;
    s_axi_aclk : in STD_LOGIC;
    s_axi_aresetn_0 : in STD_LOGIC
  );
end AdcSubSystem_wrapper;

architecture STRUCTURE of AdcSubSystem_wrapper is
  component AdcSubSystem is
  port (
    ADC_SPI_io0_i : in STD_LOGIC;
    ADC_SPI_io0_o : out STD_LOGIC;
    ADC_SPI_io0_t : out STD_LOGIC;
    ADC_SPI_io1_i : in STD_LOGIC;
    ADC_SPI_io1_o : out STD_LOGIC;
    ADC_SPI_io1_t : out STD_LOGIC;
    ADC_SPI_sck_i : in STD_LOGIC;
    ADC_SPI_sck_o : out STD_LOGIC;
    ADC_SPI_sck_t : out STD_LOGIC;
    ADC_SPI_ss_i : in STD_LOGIC_VECTOR ( 0 to 0 );
    ADC_SPI_ss_o : out STD_LOGIC_VECTOR ( 0 to 0 );
    ADC_SPI_ss_t : out STD_LOGIC;
    S00_AXI_0_awaddr : in STD_LOGIC_VECTOR ( 31 downto 0 );
    S00_AXI_0_awlen : in STD_LOGIC_VECTOR ( 7 downto 0 );
    S00_AXI_0_awsize : in STD_LOGIC_VECTOR ( 2 downto 0 );
    S00_AXI_0_awburst : in STD_LOGIC_VECTOR ( 1 downto 0 );
    S00_AXI_0_awlock : in STD_LOGIC_VECTOR ( 0 to 0 );
    S00_AXI_0_awcache : in STD_LOGIC_VECTOR ( 3 downto 0 );
    S00_AXI_0_awprot : in STD_LOGIC_VECTOR ( 2 downto 0 );
    S00_AXI_0_awqos : in STD_LOGIC_VECTOR ( 3 downto 0 );
    S00_AXI_0_awvalid : in STD_LOGIC;
    S00_AXI_0_awready : out STD_LOGIC;
    S00_AXI_0_wdata : in STD_LOGIC_VECTOR ( 31 downto 0 );
    S00_AXI_0_wstrb : in STD_LOGIC_VECTOR ( 3 downto 0 );
    S00_AXI_0_wlast : in STD_LOGIC;
    S00_AXI_0_wvalid : in STD_LOGIC;
    S00_AXI_0_wready : out STD_LOGIC;
    S00_AXI_0_bresp : out STD_LOGIC_VECTOR ( 1 downto 0 );
    S00_AXI_0_bvalid : out STD_LOGIC;
    S00_AXI_0_bready : in STD_LOGIC;
    S00_AXI_0_araddr : in STD_LOGIC_VECTOR ( 31 downto 0 );
    S00_AXI_0_arlen : in STD_LOGIC_VECTOR ( 7 downto 0 );
    S00_AXI_0_arsize : in STD_LOGIC_VECTOR ( 2 downto 0 );
    S00_AXI_0_arburst : in STD_LOGIC_VECTOR ( 1 downto 0 );
    S00_AXI_0_arlock : in STD_LOGIC_VECTOR ( 0 to 0 );
    S00_AXI_0_arcache : in STD_LOGIC_VECTOR ( 3 downto 0 );
    S00_AXI_0_arprot : in STD_LOGIC_VECTOR ( 2 downto 0 );
    S00_AXI_0_arqos : in STD_LOGIC_VECTOR ( 3 downto 0 );
    S00_AXI_0_arvalid : in STD_LOGIC;
    S00_AXI_0_arready : out STD_LOGIC;
    S00_AXI_0_rdata : out STD_LOGIC_VECTOR ( 31 downto 0 );
    S00_AXI_0_rresp : out STD_LOGIC_VECTOR ( 1 downto 0 );
    S00_AXI_0_rlast : out STD_LOGIC;
    S00_AXI_0_rvalid : out STD_LOGIC;
    S00_AXI_0_rready : in STD_LOGIC;
    M_AXIS_SAMPLES_tdata : out STD_LOGIC_VECTOR ( 31 downto 0 );
    M_AXIS_SAMPLES_tkeep : out STD_LOGIC_VECTOR ( 3 downto 0 );
    M_AXIS_SAMPLES_tlast : out STD_LOGIC;
    M_AXIS_SAMPLES_tvalid : out STD_LOGIC;
    M_AXIS_SAMPLES_tready : in STD_LOGIC;
    ext_spi_clk_0 : in STD_LOGIC;
    s_axi_aresetn_0 : in STD_LOGIC;
    s_axi_aclk : in STD_LOGIC;
    ADC_DCLK : in STD_LOGIC;
    ADC_DRDY_N : in STD_LOGIC;
    ADC_DOUT : in STD_LOGIC_VECTOR ( 3 downto 0 );
    ADC_RESET_N : out STD_LOGIC;
    ADC_START_N : out STD_LOGIC;
    ADC_CONVST_SAR : out STD_LOGIC
  );
  end component AdcSubSystem;
  component IOBUF is
  port (
    I : in STD_LOGIC;
    O : out STD_LOGIC;
    T : in STD_LOGIC;
    IO : inout STD_LOGIC
  );
  end component IOBUF;
  signal ADC_SPI_io0_i : STD_LOGIC;
  signal ADC_SPI_io0_o : STD_LOGIC;
  signal ADC_SPI_io0_t : STD_LOGIC;
  signal ADC_SPI_io1_i : STD_LOGIC;
  signal ADC_SPI_io1_o : STD_LOGIC;
  signal ADC_SPI_io1_t : STD_LOGIC;
  signal ADC_SPI_sck_i : STD_LOGIC;
  signal ADC_SPI_sck_o : STD_LOGIC;
  signal ADC_SPI_sck_t : STD_LOGIC;
  signal ADC_SPI_ss_i_0 : STD_LOGIC_VECTOR ( 0 to 0 );
  signal ADC_SPI_ss_io_0 : STD_LOGIC_VECTOR ( 0 to 0 );
  signal ADC_SPI_ss_o_0 : STD_LOGIC_VECTOR ( 0 to 0 );
  signal ADC_SPI_ss_t : STD_LOGIC;
begin
ADC_SPI_io0_iobuf: component IOBUF
     port map (
      I => ADC_SPI_io0_o,
      IO => ADC_SPI_io0_io,
      O => ADC_SPI_io0_i,
      T => ADC_SPI_io0_t
    );
ADC_SPI_io1_iobuf: component IOBUF
     port map (
      I => ADC_SPI_io1_o,
      IO => ADC_SPI_io1_io,
      O => ADC_SPI_io1_i,
      T => ADC_SPI_io1_t
    );
ADC_SPI_sck_iobuf: component IOBUF
     port map (
      I => ADC_SPI_sck_o,
      IO => ADC_SPI_sck_io,
      O => ADC_SPI_sck_i,
      T => ADC_SPI_sck_t
    );
ADC_SPI_ss_iobuf_0: component IOBUF
     port map (
      I => ADC_SPI_ss_o_0(0),
      IO => ADC_SPI_ss_io(0),
      O => ADC_SPI_ss_i_0(0),
      T => ADC_SPI_ss_t
    );
AdcSubSystem_i: component AdcSubSystem
     port map (
      ADC_CONVST_SAR => ADC_CONVST_SAR,
      ADC_DCLK => ADC_DCLK,
      ADC_DOUT(3 downto 0) => ADC_DOUT(3 downto 0),
      ADC_DRDY_N => ADC_DRDY_N,
      ADC_RESET_N => ADC_RESET_N,
      ADC_SPI_io0_i => ADC_SPI_io0_i,
      ADC_SPI_io0_o => ADC_SPI_io0_o,
      ADC_SPI_io0_t => ADC_SPI_io0_t,
      ADC_SPI_io1_i => ADC_SPI_io1_i,
      ADC_SPI_io1_o => ADC_SPI_io1_o,
      ADC_SPI_io1_t => ADC_SPI_io1_t,
      ADC_SPI_sck_i => ADC_SPI_sck_i,
      ADC_SPI_sck_o => ADC_SPI_sck_o,
      ADC_SPI_sck_t => ADC_SPI_sck_t,
      ADC_SPI_ss_i(0) => ADC_SPI_ss_i_0(0),
      ADC_SPI_ss_o(0) => ADC_SPI_ss_o_0(0),
      ADC_SPI_ss_t => ADC_SPI_ss_t,
      ADC_START_N => ADC_START_N,
      M_AXIS_SAMPLES_tdata(31 downto 0) => M_AXIS_SAMPLES_tdata(31 downto 0),
      M_AXIS_SAMPLES_tkeep(3 downto 0) => M_AXIS_SAMPLES_tkeep(3 downto 0),
      M_AXIS_SAMPLES_tlast => M_AXIS_SAMPLES_tlast,
      M_AXIS_SAMPLES_tready => M_AXIS_SAMPLES_tready,
      M_AXIS_SAMPLES_tvalid => M_AXIS_SAMPLES_tvalid,
      S00_AXI_0_araddr(31 downto 0) => S00_AXI_0_araddr(31 downto 0),
      S00_AXI_0_arburst(1 downto 0) => S00_AXI_0_arburst(1 downto 0),
      S00_AXI_0_arcache(3 downto 0) => S00_AXI_0_arcache(3 downto 0),
      S00_AXI_0_arlen(7 downto 0) => S00_AXI_0_arlen(7 downto 0),
      S00_AXI_0_arlock(0) => S00_AXI_0_arlock(0),
      S00_AXI_0_arprot(2 downto 0) => S00_AXI_0_arprot(2 downto 0),
      S00_AXI_0_arqos(3 downto 0) => S00_AXI_0_arqos(3 downto 0),
      S00_AXI_0_arready => S00_AXI_0_arready,
      S00_AXI_0_arsize(2 downto 0) => S00_AXI_0_arsize(2 downto 0),
      S00_AXI_0_arvalid => S00_AXI_0_arvalid,
      S00_AXI_0_awaddr(31 downto 0) => S00_AXI_0_awaddr(31 downto 0),
      S00_AXI_0_awburst(1 downto 0) => S00_AXI_0_awburst(1 downto 0),
      S00_AXI_0_awcache(3 downto 0) => S00_AXI_0_awcache(3 downto 0),
      S00_AXI_0_awlen(7 downto 0) => S00_AXI_0_awlen(7 downto 0),
      S00_AXI_0_awlock(0) => S00_AXI_0_awlock(0),
      S00_AXI_0_awprot(2 downto 0) => S00_AXI_0_awprot(2 downto 0),
      S00_AXI_0_awqos(3 downto 0) => S00_AXI_0_awqos(3 downto 0),
      S00_AXI_0_awready => S00_AXI_0_awready,
      S00_AXI_0_awsize(2 downto 0) => S00_AXI_0_awsize(2 downto 0),
      S00_AXI_0_awvalid => S00_AXI_0_awvalid,
      S00_AXI_0_bready => S00_AXI_0_bready,
      S00_AXI_0_bresp(1 downto 0) => S00_AXI_0_bresp(1 downto 0),
      S00_AXI_0_bvalid => S00_AXI_0_bvalid,
      S00_AXI_0_rdata(31 downto 0) => S00_AXI_0_rdata(31 downto 0),
      S00_AXI_0_rlast => S00_AXI_0_rlast,
      S00_AXI_0_rready => S00_AXI_0_rready,
      S00_AXI_0_rresp(1 downto 0) => S00_AXI_0_rresp(1 downto 0),
      S00_AXI_0_rvalid => S00_AXI_0_rvalid,
      S00_AXI_0_wdata(31 downto 0) => S00_AXI_0_wdata(31 downto 0),
      S00_AXI_0_wlast => S00_AXI_0_wlast,
      S00_AXI_0_wready => S00_AXI_0_wready,
      S00_AXI_0_wstrb(3 downto 0) => S00_AXI_0_wstrb(3 downto 0),
      S00_AXI_0_wvalid => S00_AXI_0_wvalid,
      ext_spi_clk_0 => ext_spi_clk_0,
      s_axi_aclk => s_axi_aclk,
      s_axi_aresetn_0 => s_axi_aresetn_0
    );
end STRUCTURE;
