//Copyright 1986-2022 Xilinx, Inc. All Rights Reserved.
//Copyright 2022-2025 Advanced Micro Devices, Inc. All Rights Reserved.
//--------------------------------------------------------------------------------
//Tool Version: Vivado v.2025.2 (lin64) Build 6299465 Fri Nov 14 12:34:56 MST 2025
//Date        : Wed Jul 15 13:30:25 2026
//Host        : mnc1 running 64-bit Ubuntu 24.04.4 LTS
//Command     : generate_target AdcSubSystem_inst_2_wrapper.bd
//Design      : AdcSubSystem_inst_2_wrapper
//Purpose     : IP block netlist
//--------------------------------------------------------------------------------
`timescale 1 ps / 1 ps

module AdcSubSystem_inst_2_wrapper
   (ADC_CONVST_SAR,
    ADC_DCLK,
    ADC_DOUT,
    ADC_DRDY_N,
    ADC_RESET_N,
    ADC_SPI_io0_io,
    ADC_SPI_io1_io,
    ADC_SPI_sck_io,
    ADC_SPI_ss_io,
    ADC_START_N,
    M_AXIS_SAMPLES_tdata,
    M_AXIS_SAMPLES_tkeep,
    M_AXIS_SAMPLES_tlast,
    M_AXIS_SAMPLES_tready,
    M_AXIS_SAMPLES_tvalid,
    S00_AXI_0_araddr,
    S00_AXI_0_arburst,
    S00_AXI_0_arcache,
    S00_AXI_0_arlen,
    S00_AXI_0_arlock,
    S00_AXI_0_arprot,
    S00_AXI_0_arqos,
    S00_AXI_0_arready,
    S00_AXI_0_arsize,
    S00_AXI_0_aruser,
    S00_AXI_0_arvalid,
    S00_AXI_0_awaddr,
    S00_AXI_0_awburst,
    S00_AXI_0_awcache,
    S00_AXI_0_awlen,
    S00_AXI_0_awlock,
    S00_AXI_0_awprot,
    S00_AXI_0_awqos,
    S00_AXI_0_awready,
    S00_AXI_0_awsize,
    S00_AXI_0_awuser,
    S00_AXI_0_awvalid,
    S00_AXI_0_bready,
    S00_AXI_0_bresp,
    S00_AXI_0_bvalid,
    S00_AXI_0_rdata,
    S00_AXI_0_rlast,
    S00_AXI_0_rready,
    S00_AXI_0_rresp,
    S00_AXI_0_rvalid,
    S00_AXI_0_wdata,
    S00_AXI_0_wlast,
    S00_AXI_0_wready,
    S00_AXI_0_wstrb,
    S00_AXI_0_wvalid,
    ext_spi_clk_0,
    s_axi_aclk,
    s_axi_aresetn_0);
  output ADC_CONVST_SAR;
  input ADC_DCLK;
  input [3:0]ADC_DOUT;
  input ADC_DRDY_N;
  output ADC_RESET_N;
  inout ADC_SPI_io0_io;
  inout ADC_SPI_io1_io;
  inout ADC_SPI_sck_io;
  inout [0:0]ADC_SPI_ss_io;
  output ADC_START_N;
  output [31:0]M_AXIS_SAMPLES_tdata;
  output [3:0]M_AXIS_SAMPLES_tkeep;
  output M_AXIS_SAMPLES_tlast;
  input M_AXIS_SAMPLES_tready;
  output M_AXIS_SAMPLES_tvalid;
  input [31:0]S00_AXI_0_araddr;
  input [1:0]S00_AXI_0_arburst;
  input [3:0]S00_AXI_0_arcache;
  input [7:0]S00_AXI_0_arlen;
  input [0:0]S00_AXI_0_arlock;
  input [2:0]S00_AXI_0_arprot;
  input [3:0]S00_AXI_0_arqos;
  output S00_AXI_0_arready;
  input [2:0]S00_AXI_0_arsize;
  input [15:0]S00_AXI_0_aruser;
  input S00_AXI_0_arvalid;
  input [31:0]S00_AXI_0_awaddr;
  input [1:0]S00_AXI_0_awburst;
  input [3:0]S00_AXI_0_awcache;
  input [7:0]S00_AXI_0_awlen;
  input [0:0]S00_AXI_0_awlock;
  input [2:0]S00_AXI_0_awprot;
  input [3:0]S00_AXI_0_awqos;
  output S00_AXI_0_awready;
  input [2:0]S00_AXI_0_awsize;
  input [15:0]S00_AXI_0_awuser;
  input S00_AXI_0_awvalid;
  input S00_AXI_0_bready;
  output [1:0]S00_AXI_0_bresp;
  output S00_AXI_0_bvalid;
  output [31:0]S00_AXI_0_rdata;
  output S00_AXI_0_rlast;
  input S00_AXI_0_rready;
  output [1:0]S00_AXI_0_rresp;
  output S00_AXI_0_rvalid;
  input [31:0]S00_AXI_0_wdata;
  input S00_AXI_0_wlast;
  output S00_AXI_0_wready;
  input [3:0]S00_AXI_0_wstrb;
  input S00_AXI_0_wvalid;
  input ext_spi_clk_0;
  input s_axi_aclk;
  input s_axi_aresetn_0;

  wire ADC_CONVST_SAR;
  wire ADC_DCLK;
  wire [3:0]ADC_DOUT;
  wire ADC_DRDY_N;
  wire ADC_RESET_N;
  wire ADC_SPI_io0_i;
  wire ADC_SPI_io0_io;
  wire ADC_SPI_io0_o;
  wire ADC_SPI_io0_t;
  wire ADC_SPI_io1_i;
  wire ADC_SPI_io1_io;
  wire ADC_SPI_io1_o;
  wire ADC_SPI_io1_t;
  wire ADC_SPI_sck_i;
  wire ADC_SPI_sck_io;
  wire ADC_SPI_sck_o;
  wire ADC_SPI_sck_t;
  wire [0:0]ADC_SPI_ss_i_0;
  wire [0:0]ADC_SPI_ss_io_0;
  wire [0:0]ADC_SPI_ss_o_0;
  wire ADC_SPI_ss_t;
  wire ADC_START_N;
  wire [31:0]M_AXIS_SAMPLES_tdata;
  wire [3:0]M_AXIS_SAMPLES_tkeep;
  wire M_AXIS_SAMPLES_tlast;
  wire M_AXIS_SAMPLES_tready;
  wire M_AXIS_SAMPLES_tvalid;
  wire [31:0]S00_AXI_0_araddr;
  wire [1:0]S00_AXI_0_arburst;
  wire [3:0]S00_AXI_0_arcache;
  wire [7:0]S00_AXI_0_arlen;
  wire [0:0]S00_AXI_0_arlock;
  wire [2:0]S00_AXI_0_arprot;
  wire [3:0]S00_AXI_0_arqos;
  wire S00_AXI_0_arready;
  wire [2:0]S00_AXI_0_arsize;
  wire [15:0]S00_AXI_0_aruser;
  wire S00_AXI_0_arvalid;
  wire [31:0]S00_AXI_0_awaddr;
  wire [1:0]S00_AXI_0_awburst;
  wire [3:0]S00_AXI_0_awcache;
  wire [7:0]S00_AXI_0_awlen;
  wire [0:0]S00_AXI_0_awlock;
  wire [2:0]S00_AXI_0_awprot;
  wire [3:0]S00_AXI_0_awqos;
  wire S00_AXI_0_awready;
  wire [2:0]S00_AXI_0_awsize;
  wire [15:0]S00_AXI_0_awuser;
  wire S00_AXI_0_awvalid;
  wire S00_AXI_0_bready;
  wire [1:0]S00_AXI_0_bresp;
  wire S00_AXI_0_bvalid;
  wire [31:0]S00_AXI_0_rdata;
  wire S00_AXI_0_rlast;
  wire S00_AXI_0_rready;
  wire [1:0]S00_AXI_0_rresp;
  wire S00_AXI_0_rvalid;
  wire [31:0]S00_AXI_0_wdata;
  wire S00_AXI_0_wlast;
  wire S00_AXI_0_wready;
  wire [3:0]S00_AXI_0_wstrb;
  wire S00_AXI_0_wvalid;
  wire ext_spi_clk_0;
  wire s_axi_aclk;
  wire s_axi_aresetn_0;

  IOBUF ADC_SPI_io0_iobuf
       (.I(ADC_SPI_io0_o),
        .IO(ADC_SPI_io0_io),
        .O(ADC_SPI_io0_i),
        .T(ADC_SPI_io0_t));
  IOBUF ADC_SPI_io1_iobuf
       (.I(ADC_SPI_io1_o),
        .IO(ADC_SPI_io1_io),
        .O(ADC_SPI_io1_i),
        .T(ADC_SPI_io1_t));
  IOBUF ADC_SPI_sck_iobuf
       (.I(ADC_SPI_sck_o),
        .IO(ADC_SPI_sck_io),
        .O(ADC_SPI_sck_i),
        .T(ADC_SPI_sck_t));
  IOBUF ADC_SPI_ss_iobuf_0
       (.I(ADC_SPI_ss_o_0),
        .IO(ADC_SPI_ss_io[0]),
        .O(ADC_SPI_ss_i_0),
        .T(ADC_SPI_ss_t));
  AdcSubSystem_inst_2 AdcSubSystem_inst_2_i
       (.ADC_CONVST_SAR(ADC_CONVST_SAR),
        .ADC_DCLK(ADC_DCLK),
        .ADC_DOUT(ADC_DOUT),
        .ADC_DRDY_N(ADC_DRDY_N),
        .ADC_RESET_N(ADC_RESET_N),
        .ADC_SPI_io0_i(ADC_SPI_io0_i),
        .ADC_SPI_io0_o(ADC_SPI_io0_o),
        .ADC_SPI_io0_t(ADC_SPI_io0_t),
        .ADC_SPI_io1_i(ADC_SPI_io1_i),
        .ADC_SPI_io1_o(ADC_SPI_io1_o),
        .ADC_SPI_io1_t(ADC_SPI_io1_t),
        .ADC_SPI_sck_i(ADC_SPI_sck_i),
        .ADC_SPI_sck_o(ADC_SPI_sck_o),
        .ADC_SPI_sck_t(ADC_SPI_sck_t),
        .ADC_SPI_ss_i(ADC_SPI_ss_i_0),
        .ADC_SPI_ss_o(ADC_SPI_ss_o_0),
        .ADC_SPI_ss_t(ADC_SPI_ss_t),
        .ADC_START_N(ADC_START_N),
        .M_AXIS_SAMPLES_tdata(M_AXIS_SAMPLES_tdata),
        .M_AXIS_SAMPLES_tkeep(M_AXIS_SAMPLES_tkeep),
        .M_AXIS_SAMPLES_tlast(M_AXIS_SAMPLES_tlast),
        .M_AXIS_SAMPLES_tready(M_AXIS_SAMPLES_tready),
        .M_AXIS_SAMPLES_tvalid(M_AXIS_SAMPLES_tvalid),
        .S00_AXI_0_araddr(S00_AXI_0_araddr),
        .S00_AXI_0_arburst(S00_AXI_0_arburst),
        .S00_AXI_0_arcache(S00_AXI_0_arcache),
        .S00_AXI_0_arlen(S00_AXI_0_arlen),
        .S00_AXI_0_arlock(S00_AXI_0_arlock),
        .S00_AXI_0_arprot(S00_AXI_0_arprot),
        .S00_AXI_0_arqos(S00_AXI_0_arqos),
        .S00_AXI_0_arready(S00_AXI_0_arready),
        .S00_AXI_0_arsize(S00_AXI_0_arsize),
        .S00_AXI_0_aruser(S00_AXI_0_aruser),
        .S00_AXI_0_arvalid(S00_AXI_0_arvalid),
        .S00_AXI_0_awaddr(S00_AXI_0_awaddr),
        .S00_AXI_0_awburst(S00_AXI_0_awburst),
        .S00_AXI_0_awcache(S00_AXI_0_awcache),
        .S00_AXI_0_awlen(S00_AXI_0_awlen),
        .S00_AXI_0_awlock(S00_AXI_0_awlock),
        .S00_AXI_0_awprot(S00_AXI_0_awprot),
        .S00_AXI_0_awqos(S00_AXI_0_awqos),
        .S00_AXI_0_awready(S00_AXI_0_awready),
        .S00_AXI_0_awsize(S00_AXI_0_awsize),
        .S00_AXI_0_awuser(S00_AXI_0_awuser),
        .S00_AXI_0_awvalid(S00_AXI_0_awvalid),
        .S00_AXI_0_bready(S00_AXI_0_bready),
        .S00_AXI_0_bresp(S00_AXI_0_bresp),
        .S00_AXI_0_bvalid(S00_AXI_0_bvalid),
        .S00_AXI_0_rdata(S00_AXI_0_rdata),
        .S00_AXI_0_rlast(S00_AXI_0_rlast),
        .S00_AXI_0_rready(S00_AXI_0_rready),
        .S00_AXI_0_rresp(S00_AXI_0_rresp),
        .S00_AXI_0_rvalid(S00_AXI_0_rvalid),
        .S00_AXI_0_wdata(S00_AXI_0_wdata),
        .S00_AXI_0_wlast(S00_AXI_0_wlast),
        .S00_AXI_0_wready(S00_AXI_0_wready),
        .S00_AXI_0_wstrb(S00_AXI_0_wstrb),
        .S00_AXI_0_wvalid(S00_AXI_0_wvalid),
        .ext_spi_clk_0(ext_spi_clk_0),
        .s_axi_aclk(s_axi_aclk),
        .s_axi_aresetn_0(s_axi_aresetn_0));
endmodule
