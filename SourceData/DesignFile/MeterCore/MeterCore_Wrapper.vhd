library ieee;
use ieee.std_logic_1164.all;

-- Ordinary-VHDL Vivado module-reference boundary. The implementation and
-- algorithm entities are VHDL-2008 sources.
entity MeterCore_Wrapper is
  port (
    aclk    : in std_logic;
    aresetn : in std_logic;

    s_axi_capture_awaddr  : in  std_logic_vector(7 downto 0);
    s_axi_capture_awvalid : in  std_logic;
    s_axi_capture_awready : out std_logic;
    s_axi_capture_wdata   : in  std_logic_vector(31 downto 0);
    s_axi_capture_wstrb   : in  std_logic_vector(3 downto 0);
    s_axi_capture_wvalid  : in  std_logic;
    s_axi_capture_wready  : out std_logic;
    s_axi_capture_bresp   : out std_logic_vector(1 downto 0);
    s_axi_capture_bvalid  : out std_logic;
    s_axi_capture_bready  : in  std_logic;
    s_axi_capture_araddr  : in  std_logic_vector(7 downto 0);
    s_axi_capture_arvalid : in  std_logic;
    s_axi_capture_arready : out std_logic;
    s_axi_capture_rdata   : out std_logic_vector(31 downto 0);
    s_axi_capture_rresp   : out std_logic_vector(1 downto 0);
    s_axi_capture_rvalid  : out std_logic;
    s_axi_capture_rready  : in  std_logic;

    s_axi_conversion_awaddr  : in  std_logic_vector(7 downto 0);
    s_axi_conversion_awvalid : in  std_logic;
    s_axi_conversion_awready : out std_logic;
    s_axi_conversion_wdata   : in  std_logic_vector(31 downto 0);
    s_axi_conversion_wstrb   : in  std_logic_vector(3 downto 0);
    s_axi_conversion_wvalid  : in  std_logic;
    s_axi_conversion_wready  : out std_logic;
    s_axi_conversion_bresp   : out std_logic_vector(1 downto 0);
    s_axi_conversion_bvalid  : out std_logic;
    s_axi_conversion_bready  : in  std_logic;
    s_axi_conversion_araddr  : in  std_logic_vector(7 downto 0);
    s_axi_conversion_arvalid : in  std_logic;
    s_axi_conversion_arready : out std_logic;
    s_axi_conversion_rdata   : out std_logic_vector(31 downto 0);
    s_axi_conversion_rresp   : out std_logic_vector(1 downto 0);
    s_axi_conversion_rvalid  : out std_logic;
    s_axi_conversion_rready  : in  std_logic;

    s_axi_processing_awaddr  : in  std_logic_vector(7 downto 0);
    s_axi_processing_awvalid : in  std_logic;
    s_axi_processing_awready : out std_logic;
    s_axi_processing_wdata   : in  std_logic_vector(31 downto 0);
    s_axi_processing_wstrb   : in  std_logic_vector(3 downto 0);
    s_axi_processing_wvalid  : in  std_logic;
    s_axi_processing_wready  : out std_logic;
    s_axi_processing_bresp   : out std_logic_vector(1 downto 0);
    s_axi_processing_bvalid  : out std_logic;
    s_axi_processing_bready  : in  std_logic;
    s_axi_processing_araddr  : in  std_logic_vector(7 downto 0);
    s_axi_processing_arvalid : in  std_logic;
    s_axi_processing_arready : out std_logic;
    s_axi_processing_rdata   : out std_logic_vector(31 downto 0);
    s_axi_processing_rresp   : out std_logic_vector(1 downto 0);
    s_axi_processing_rvalid  : out std_logic;
    s_axi_processing_rready  : in  std_logic;

    s_axi_waveform_awaddr  : in  std_logic_vector(7 downto 0);
    s_axi_waveform_awvalid : in  std_logic;
    s_axi_waveform_awready : out std_logic;
    s_axi_waveform_wdata   : in  std_logic_vector(31 downto 0);
    s_axi_waveform_wstrb   : in  std_logic_vector(3 downto 0);
    s_axi_waveform_wvalid  : in  std_logic;
    s_axi_waveform_wready  : out std_logic;
    s_axi_waveform_bresp   : out std_logic_vector(1 downto 0);
    s_axi_waveform_bvalid  : out std_logic;
    s_axi_waveform_bready  : in  std_logic;
    s_axi_waveform_araddr  : in  std_logic_vector(7 downto 0);
    s_axi_waveform_arvalid : in  std_logic;
    s_axi_waveform_arready : out std_logic;
    s_axi_waveform_rdata   : out std_logic_vector(31 downto 0);
    s_axi_waveform_rresp   : out std_logic_vector(1 downto 0);
    s_axi_waveform_rvalid  : out std_logic;
    s_axi_waveform_rready  : in  std_logic;

    s_axi_simulator_awaddr  : in  std_logic_vector(7 downto 0);
    s_axi_simulator_awvalid : in  std_logic;
    s_axi_simulator_awready : out std_logic;
    s_axi_simulator_wdata   : in  std_logic_vector(31 downto 0);
    s_axi_simulator_wstrb   : in  std_logic_vector(3 downto 0);
    s_axi_simulator_wvalid  : in  std_logic;
    s_axi_simulator_wready  : out std_logic;
    s_axi_simulator_bresp   : out std_logic_vector(1 downto 0);
    s_axi_simulator_bvalid  : out std_logic;
    s_axi_simulator_bready  : in  std_logic;
    s_axi_simulator_araddr  : in  std_logic_vector(7 downto 0);
    s_axi_simulator_arvalid : in  std_logic;
    s_axi_simulator_arready : out std_logic;
    s_axi_simulator_rdata   : out std_logic_vector(31 downto 0);
    s_axi_simulator_rresp   : out std_logic_vector(1 downto 0);
    s_axi_simulator_rvalid  : out std_logic;
    s_axi_simulator_rready  : in  std_logic;

    m_axis_mtr1_tdata  : out std_logic_vector(31 downto 0);
    m_axis_mtr1_tkeep  : out std_logic_vector(3 downto 0);
    m_axis_mtr1_tvalid : out std_logic;
    m_axis_mtr1_tready : in  std_logic;
    m_axis_mtr1_tlast  : out std_logic;

    m_axis_mtr2_tdata  : out std_logic_vector(31 downto 0);
    m_axis_mtr2_tkeep  : out std_logic_vector(3 downto 0);
    m_axis_mtr2_tvalid : out std_logic;
    m_axis_mtr2_tready : in  std_logic;
    m_axis_mtr2_tlast  : out std_logic;

    m_axis_waveform_tdata  : out std_logic_vector(31 downto 0);
    m_axis_waveform_tkeep  : out std_logic_vector(3 downto 0);
    m_axis_waveform_tvalid : out std_logic;
    m_axis_waveform_tready : in  std_logic;
    m_axis_waveform_tlast  : out std_logic;

    adc_dclk       : in  std_logic;
    adc_drdy_n     : in  std_logic;
    adc_dout       : in  std_logic_vector(3 downto 0);
    adc_reset_n    : out std_logic;
    adc_start_n    : out std_logic;
    adc_convst_sar : out std_logic
  );
end entity MeterCore_Wrapper;

architecture structural of MeterCore_Wrapper is
  attribute X_INTERFACE_INFO : string;
  attribute X_INTERFACE_PARAMETER : string;

  attribute X_INTERFACE_INFO of aclk : signal is
    "xilinx.com:signal:clock:1.0 aclk CLK";
  attribute X_INTERFACE_PARAMETER of aclk : signal is
    "XIL_INTERFACENAME aclk, FREQ_HZ 99999001, ASSOCIATED_RESET aresetn, ASSOCIATED_BUSIF S_AXI_CAPTURE:S_AXI_CONVERSION:S_AXI_PROCESSING:S_AXI_WAVEFORM:S_AXI_SIMULATOR:M_AXIS_MTR1:M_AXIS_MTR2:M_AXIS_WAVEFORM";
  attribute X_INTERFACE_INFO of aresetn : signal is
    "xilinx.com:signal:reset:1.0 aresetn RST";
  attribute X_INTERFACE_PARAMETER of aresetn : signal is
    "XIL_INTERFACENAME aresetn, POLARITY ACTIVE_LOW";

  attribute X_INTERFACE_INFO of adc_dclk : signal is
    "xilinx.com:signal:clock:1.0 adc_dclk CLK";
  attribute X_INTERFACE_PARAMETER of adc_dclk : signal is
    "XIL_INTERFACENAME adc_dclk, FREQ_HZ 8192000";

  attribute X_INTERFACE_INFO of s_axi_capture_awaddr : signal is "xilinx.com:interface:aximm:1.0 S_AXI_CAPTURE AWADDR";
  attribute X_INTERFACE_PARAMETER of s_axi_capture_awaddr : signal is
    "XIL_INTERFACENAME S_AXI_CAPTURE, PROTOCOL AXI4LITE, DATA_WIDTH 32, ADDR_WIDTH 8, ID_WIDTH 0, READ_WRITE_MODE READ_WRITE";
  attribute X_INTERFACE_INFO of s_axi_capture_awvalid : signal is "xilinx.com:interface:aximm:1.0 S_AXI_CAPTURE AWVALID";
  attribute X_INTERFACE_INFO of s_axi_capture_awready : signal is "xilinx.com:interface:aximm:1.0 S_AXI_CAPTURE AWREADY";
  attribute X_INTERFACE_INFO of s_axi_capture_wdata : signal is "xilinx.com:interface:aximm:1.0 S_AXI_CAPTURE WDATA";
  attribute X_INTERFACE_INFO of s_axi_capture_wstrb : signal is "xilinx.com:interface:aximm:1.0 S_AXI_CAPTURE WSTRB";
  attribute X_INTERFACE_INFO of s_axi_capture_wvalid : signal is "xilinx.com:interface:aximm:1.0 S_AXI_CAPTURE WVALID";
  attribute X_INTERFACE_INFO of s_axi_capture_wready : signal is "xilinx.com:interface:aximm:1.0 S_AXI_CAPTURE WREADY";
  attribute X_INTERFACE_INFO of s_axi_capture_bresp : signal is "xilinx.com:interface:aximm:1.0 S_AXI_CAPTURE BRESP";
  attribute X_INTERFACE_INFO of s_axi_capture_bvalid : signal is "xilinx.com:interface:aximm:1.0 S_AXI_CAPTURE BVALID";
  attribute X_INTERFACE_INFO of s_axi_capture_bready : signal is "xilinx.com:interface:aximm:1.0 S_AXI_CAPTURE BREADY";
  attribute X_INTERFACE_INFO of s_axi_capture_araddr : signal is "xilinx.com:interface:aximm:1.0 S_AXI_CAPTURE ARADDR";
  attribute X_INTERFACE_INFO of s_axi_capture_arvalid : signal is "xilinx.com:interface:aximm:1.0 S_AXI_CAPTURE ARVALID";
  attribute X_INTERFACE_INFO of s_axi_capture_arready : signal is "xilinx.com:interface:aximm:1.0 S_AXI_CAPTURE ARREADY";
  attribute X_INTERFACE_INFO of s_axi_capture_rdata : signal is "xilinx.com:interface:aximm:1.0 S_AXI_CAPTURE RDATA";
  attribute X_INTERFACE_INFO of s_axi_capture_rresp : signal is "xilinx.com:interface:aximm:1.0 S_AXI_CAPTURE RRESP";
  attribute X_INTERFACE_INFO of s_axi_capture_rvalid : signal is "xilinx.com:interface:aximm:1.0 S_AXI_CAPTURE RVALID";
  attribute X_INTERFACE_INFO of s_axi_capture_rready : signal is "xilinx.com:interface:aximm:1.0 S_AXI_CAPTURE RREADY";

  attribute X_INTERFACE_INFO of s_axi_conversion_awaddr : signal is "xilinx.com:interface:aximm:1.0 S_AXI_CONVERSION AWADDR";
  attribute X_INTERFACE_PARAMETER of s_axi_conversion_awaddr : signal is
    "XIL_INTERFACENAME S_AXI_CONVERSION, PROTOCOL AXI4LITE, DATA_WIDTH 32, ADDR_WIDTH 8, ID_WIDTH 0, READ_WRITE_MODE READ_WRITE";
  attribute X_INTERFACE_INFO of s_axi_conversion_awvalid : signal is "xilinx.com:interface:aximm:1.0 S_AXI_CONVERSION AWVALID";
  attribute X_INTERFACE_INFO of s_axi_conversion_awready : signal is "xilinx.com:interface:aximm:1.0 S_AXI_CONVERSION AWREADY";
  attribute X_INTERFACE_INFO of s_axi_conversion_wdata : signal is "xilinx.com:interface:aximm:1.0 S_AXI_CONVERSION WDATA";
  attribute X_INTERFACE_INFO of s_axi_conversion_wstrb : signal is "xilinx.com:interface:aximm:1.0 S_AXI_CONVERSION WSTRB";
  attribute X_INTERFACE_INFO of s_axi_conversion_wvalid : signal is "xilinx.com:interface:aximm:1.0 S_AXI_CONVERSION WVALID";
  attribute X_INTERFACE_INFO of s_axi_conversion_wready : signal is "xilinx.com:interface:aximm:1.0 S_AXI_CONVERSION WREADY";
  attribute X_INTERFACE_INFO of s_axi_conversion_bresp : signal is "xilinx.com:interface:aximm:1.0 S_AXI_CONVERSION BRESP";
  attribute X_INTERFACE_INFO of s_axi_conversion_bvalid : signal is "xilinx.com:interface:aximm:1.0 S_AXI_CONVERSION BVALID";
  attribute X_INTERFACE_INFO of s_axi_conversion_bready : signal is "xilinx.com:interface:aximm:1.0 S_AXI_CONVERSION BREADY";
  attribute X_INTERFACE_INFO of s_axi_conversion_araddr : signal is "xilinx.com:interface:aximm:1.0 S_AXI_CONVERSION ARADDR";
  attribute X_INTERFACE_INFO of s_axi_conversion_arvalid : signal is "xilinx.com:interface:aximm:1.0 S_AXI_CONVERSION ARVALID";
  attribute X_INTERFACE_INFO of s_axi_conversion_arready : signal is "xilinx.com:interface:aximm:1.0 S_AXI_CONVERSION ARREADY";
  attribute X_INTERFACE_INFO of s_axi_conversion_rdata : signal is "xilinx.com:interface:aximm:1.0 S_AXI_CONVERSION RDATA";
  attribute X_INTERFACE_INFO of s_axi_conversion_rresp : signal is "xilinx.com:interface:aximm:1.0 S_AXI_CONVERSION RRESP";
  attribute X_INTERFACE_INFO of s_axi_conversion_rvalid : signal is "xilinx.com:interface:aximm:1.0 S_AXI_CONVERSION RVALID";
  attribute X_INTERFACE_INFO of s_axi_conversion_rready : signal is "xilinx.com:interface:aximm:1.0 S_AXI_CONVERSION RREADY";

  attribute X_INTERFACE_INFO of s_axi_processing_awaddr : signal is "xilinx.com:interface:aximm:1.0 S_AXI_PROCESSING AWADDR";
  attribute X_INTERFACE_PARAMETER of s_axi_processing_awaddr : signal is
    "XIL_INTERFACENAME S_AXI_PROCESSING, PROTOCOL AXI4LITE, DATA_WIDTH 32, ADDR_WIDTH 8, ID_WIDTH 0, READ_WRITE_MODE READ_WRITE";
  attribute X_INTERFACE_INFO of s_axi_processing_awvalid : signal is "xilinx.com:interface:aximm:1.0 S_AXI_PROCESSING AWVALID";
  attribute X_INTERFACE_INFO of s_axi_processing_awready : signal is "xilinx.com:interface:aximm:1.0 S_AXI_PROCESSING AWREADY";
  attribute X_INTERFACE_INFO of s_axi_processing_wdata : signal is "xilinx.com:interface:aximm:1.0 S_AXI_PROCESSING WDATA";
  attribute X_INTERFACE_INFO of s_axi_processing_wstrb : signal is "xilinx.com:interface:aximm:1.0 S_AXI_PROCESSING WSTRB";
  attribute X_INTERFACE_INFO of s_axi_processing_wvalid : signal is "xilinx.com:interface:aximm:1.0 S_AXI_PROCESSING WVALID";
  attribute X_INTERFACE_INFO of s_axi_processing_wready : signal is "xilinx.com:interface:aximm:1.0 S_AXI_PROCESSING WREADY";
  attribute X_INTERFACE_INFO of s_axi_processing_bresp : signal is "xilinx.com:interface:aximm:1.0 S_AXI_PROCESSING BRESP";
  attribute X_INTERFACE_INFO of s_axi_processing_bvalid : signal is "xilinx.com:interface:aximm:1.0 S_AXI_PROCESSING BVALID";
  attribute X_INTERFACE_INFO of s_axi_processing_bready : signal is "xilinx.com:interface:aximm:1.0 S_AXI_PROCESSING BREADY";
  attribute X_INTERFACE_INFO of s_axi_processing_araddr : signal is "xilinx.com:interface:aximm:1.0 S_AXI_PROCESSING ARADDR";
  attribute X_INTERFACE_INFO of s_axi_processing_arvalid : signal is "xilinx.com:interface:aximm:1.0 S_AXI_PROCESSING ARVALID";
  attribute X_INTERFACE_INFO of s_axi_processing_arready : signal is "xilinx.com:interface:aximm:1.0 S_AXI_PROCESSING ARREADY";
  attribute X_INTERFACE_INFO of s_axi_processing_rdata : signal is "xilinx.com:interface:aximm:1.0 S_AXI_PROCESSING RDATA";
  attribute X_INTERFACE_INFO of s_axi_processing_rresp : signal is "xilinx.com:interface:aximm:1.0 S_AXI_PROCESSING RRESP";
  attribute X_INTERFACE_INFO of s_axi_processing_rvalid : signal is "xilinx.com:interface:aximm:1.0 S_AXI_PROCESSING RVALID";
  attribute X_INTERFACE_INFO of s_axi_processing_rready : signal is "xilinx.com:interface:aximm:1.0 S_AXI_PROCESSING RREADY";

  attribute X_INTERFACE_INFO of s_axi_waveform_awaddr : signal is "xilinx.com:interface:aximm:1.0 S_AXI_WAVEFORM AWADDR";
  attribute X_INTERFACE_PARAMETER of s_axi_waveform_awaddr : signal is
    "XIL_INTERFACENAME S_AXI_WAVEFORM, PROTOCOL AXI4LITE, DATA_WIDTH 32, ADDR_WIDTH 8, ID_WIDTH 0, READ_WRITE_MODE READ_WRITE";
  attribute X_INTERFACE_INFO of s_axi_waveform_awvalid : signal is "xilinx.com:interface:aximm:1.0 S_AXI_WAVEFORM AWVALID";
  attribute X_INTERFACE_INFO of s_axi_waveform_awready : signal is "xilinx.com:interface:aximm:1.0 S_AXI_WAVEFORM AWREADY";
  attribute X_INTERFACE_INFO of s_axi_waveform_wdata : signal is "xilinx.com:interface:aximm:1.0 S_AXI_WAVEFORM WDATA";
  attribute X_INTERFACE_INFO of s_axi_waveform_wstrb : signal is "xilinx.com:interface:aximm:1.0 S_AXI_WAVEFORM WSTRB";
  attribute X_INTERFACE_INFO of s_axi_waveform_wvalid : signal is "xilinx.com:interface:aximm:1.0 S_AXI_WAVEFORM WVALID";
  attribute X_INTERFACE_INFO of s_axi_waveform_wready : signal is "xilinx.com:interface:aximm:1.0 S_AXI_WAVEFORM WREADY";
  attribute X_INTERFACE_INFO of s_axi_waveform_bresp : signal is "xilinx.com:interface:aximm:1.0 S_AXI_WAVEFORM BRESP";
  attribute X_INTERFACE_INFO of s_axi_waveform_bvalid : signal is "xilinx.com:interface:aximm:1.0 S_AXI_WAVEFORM BVALID";
  attribute X_INTERFACE_INFO of s_axi_waveform_bready : signal is "xilinx.com:interface:aximm:1.0 S_AXI_WAVEFORM BREADY";
  attribute X_INTERFACE_INFO of s_axi_waveform_araddr : signal is "xilinx.com:interface:aximm:1.0 S_AXI_WAVEFORM ARADDR";
  attribute X_INTERFACE_INFO of s_axi_waveform_arvalid : signal is "xilinx.com:interface:aximm:1.0 S_AXI_WAVEFORM ARVALID";
  attribute X_INTERFACE_INFO of s_axi_waveform_arready : signal is "xilinx.com:interface:aximm:1.0 S_AXI_WAVEFORM ARREADY";
  attribute X_INTERFACE_INFO of s_axi_waveform_rdata : signal is "xilinx.com:interface:aximm:1.0 S_AXI_WAVEFORM RDATA";
  attribute X_INTERFACE_INFO of s_axi_waveform_rresp : signal is "xilinx.com:interface:aximm:1.0 S_AXI_WAVEFORM RRESP";
  attribute X_INTERFACE_INFO of s_axi_waveform_rvalid : signal is "xilinx.com:interface:aximm:1.0 S_AXI_WAVEFORM RVALID";
  attribute X_INTERFACE_INFO of s_axi_waveform_rready : signal is "xilinx.com:interface:aximm:1.0 S_AXI_WAVEFORM RREADY";

  attribute X_INTERFACE_INFO of s_axi_simulator_awaddr : signal is "xilinx.com:interface:aximm:1.0 S_AXI_SIMULATOR AWADDR";
  attribute X_INTERFACE_PARAMETER of s_axi_simulator_awaddr : signal is
    "XIL_INTERFACENAME S_AXI_SIMULATOR, PROTOCOL AXI4LITE, DATA_WIDTH 32, ADDR_WIDTH 8, ID_WIDTH 0, READ_WRITE_MODE READ_WRITE";
  attribute X_INTERFACE_INFO of s_axi_simulator_awvalid : signal is "xilinx.com:interface:aximm:1.0 S_AXI_SIMULATOR AWVALID";
  attribute X_INTERFACE_INFO of s_axi_simulator_awready : signal is "xilinx.com:interface:aximm:1.0 S_AXI_SIMULATOR AWREADY";
  attribute X_INTERFACE_INFO of s_axi_simulator_wdata : signal is "xilinx.com:interface:aximm:1.0 S_AXI_SIMULATOR WDATA";
  attribute X_INTERFACE_INFO of s_axi_simulator_wstrb : signal is "xilinx.com:interface:aximm:1.0 S_AXI_SIMULATOR WSTRB";
  attribute X_INTERFACE_INFO of s_axi_simulator_wvalid : signal is "xilinx.com:interface:aximm:1.0 S_AXI_SIMULATOR WVALID";
  attribute X_INTERFACE_INFO of s_axi_simulator_wready : signal is "xilinx.com:interface:aximm:1.0 S_AXI_SIMULATOR WREADY";
  attribute X_INTERFACE_INFO of s_axi_simulator_bresp : signal is "xilinx.com:interface:aximm:1.0 S_AXI_SIMULATOR BRESP";
  attribute X_INTERFACE_INFO of s_axi_simulator_bvalid : signal is "xilinx.com:interface:aximm:1.0 S_AXI_SIMULATOR BVALID";
  attribute X_INTERFACE_INFO of s_axi_simulator_bready : signal is "xilinx.com:interface:aximm:1.0 S_AXI_SIMULATOR BREADY";
  attribute X_INTERFACE_INFO of s_axi_simulator_araddr : signal is "xilinx.com:interface:aximm:1.0 S_AXI_SIMULATOR ARADDR";
  attribute X_INTERFACE_INFO of s_axi_simulator_arvalid : signal is "xilinx.com:interface:aximm:1.0 S_AXI_SIMULATOR ARVALID";
  attribute X_INTERFACE_INFO of s_axi_simulator_arready : signal is "xilinx.com:interface:aximm:1.0 S_AXI_SIMULATOR ARREADY";
  attribute X_INTERFACE_INFO of s_axi_simulator_rdata : signal is "xilinx.com:interface:aximm:1.0 S_AXI_SIMULATOR RDATA";
  attribute X_INTERFACE_INFO of s_axi_simulator_rresp : signal is "xilinx.com:interface:aximm:1.0 S_AXI_SIMULATOR RRESP";
  attribute X_INTERFACE_INFO of s_axi_simulator_rvalid : signal is "xilinx.com:interface:aximm:1.0 S_AXI_SIMULATOR RVALID";
  attribute X_INTERFACE_INFO of s_axi_simulator_rready : signal is "xilinx.com:interface:aximm:1.0 S_AXI_SIMULATOR RREADY";

  attribute X_INTERFACE_INFO of m_axis_mtr1_tdata : signal is "xilinx.com:interface:axis:1.0 M_AXIS_MTR1 TDATA";
  attribute X_INTERFACE_PARAMETER of m_axis_mtr1_tdata : signal is
    "XIL_INTERFACENAME M_AXIS_MTR1, TDATA_NUM_BYTES 4, TUSER_WIDTH 0, HAS_TREADY 1, HAS_TKEEP 1, HAS_TLAST 1";
  attribute X_INTERFACE_INFO of m_axis_mtr1_tkeep : signal is "xilinx.com:interface:axis:1.0 M_AXIS_MTR1 TKEEP";
  attribute X_INTERFACE_INFO of m_axis_mtr1_tvalid : signal is "xilinx.com:interface:axis:1.0 M_AXIS_MTR1 TVALID";
  attribute X_INTERFACE_INFO of m_axis_mtr1_tready : signal is "xilinx.com:interface:axis:1.0 M_AXIS_MTR1 TREADY";
  attribute X_INTERFACE_INFO of m_axis_mtr1_tlast : signal is "xilinx.com:interface:axis:1.0 M_AXIS_MTR1 TLAST";

  attribute X_INTERFACE_INFO of m_axis_mtr2_tdata : signal is "xilinx.com:interface:axis:1.0 M_AXIS_MTR2 TDATA";
  attribute X_INTERFACE_PARAMETER of m_axis_mtr2_tdata : signal is
    "XIL_INTERFACENAME M_AXIS_MTR2, TDATA_NUM_BYTES 4, TUSER_WIDTH 0, HAS_TREADY 1, HAS_TKEEP 1, HAS_TLAST 1";
  attribute X_INTERFACE_INFO of m_axis_mtr2_tkeep : signal is "xilinx.com:interface:axis:1.0 M_AXIS_MTR2 TKEEP";
  attribute X_INTERFACE_INFO of m_axis_mtr2_tvalid : signal is "xilinx.com:interface:axis:1.0 M_AXIS_MTR2 TVALID";
  attribute X_INTERFACE_INFO of m_axis_mtr2_tready : signal is "xilinx.com:interface:axis:1.0 M_AXIS_MTR2 TREADY";
  attribute X_INTERFACE_INFO of m_axis_mtr2_tlast : signal is "xilinx.com:interface:axis:1.0 M_AXIS_MTR2 TLAST";

  attribute X_INTERFACE_INFO of m_axis_waveform_tdata : signal is "xilinx.com:interface:axis:1.0 M_AXIS_WAVEFORM TDATA";
  attribute X_INTERFACE_PARAMETER of m_axis_waveform_tdata : signal is
    "XIL_INTERFACENAME M_AXIS_WAVEFORM, TDATA_NUM_BYTES 4, TUSER_WIDTH 0, HAS_TREADY 1, HAS_TKEEP 1, HAS_TLAST 1";
  attribute X_INTERFACE_INFO of m_axis_waveform_tkeep : signal is "xilinx.com:interface:axis:1.0 M_AXIS_WAVEFORM TKEEP";
  attribute X_INTERFACE_INFO of m_axis_waveform_tvalid : signal is "xilinx.com:interface:axis:1.0 M_AXIS_WAVEFORM TVALID";
  attribute X_INTERFACE_INFO of m_axis_waveform_tready : signal is "xilinx.com:interface:axis:1.0 M_AXIS_WAVEFORM TREADY";
  attribute X_INTERFACE_INFO of m_axis_waveform_tlast : signal is "xilinx.com:interface:axis:1.0 M_AXIS_WAVEFORM TLAST";
begin
  implementation : entity work.meter_core
    port map (
      aclk => aclk,
      aresetn => aresetn,
      s_axi_capture_awaddr => s_axi_capture_awaddr,
      s_axi_capture_awvalid => s_axi_capture_awvalid,
      s_axi_capture_awready => s_axi_capture_awready,
      s_axi_capture_wdata => s_axi_capture_wdata,
      s_axi_capture_wstrb => s_axi_capture_wstrb,
      s_axi_capture_wvalid => s_axi_capture_wvalid,
      s_axi_capture_wready => s_axi_capture_wready,
      s_axi_capture_bresp => s_axi_capture_bresp,
      s_axi_capture_bvalid => s_axi_capture_bvalid,
      s_axi_capture_bready => s_axi_capture_bready,
      s_axi_capture_araddr => s_axi_capture_araddr,
      s_axi_capture_arvalid => s_axi_capture_arvalid,
      s_axi_capture_arready => s_axi_capture_arready,
      s_axi_capture_rdata => s_axi_capture_rdata,
      s_axi_capture_rresp => s_axi_capture_rresp,
      s_axi_capture_rvalid => s_axi_capture_rvalid,
      s_axi_capture_rready => s_axi_capture_rready,
      s_axi_conversion_awaddr => s_axi_conversion_awaddr,
      s_axi_conversion_awvalid => s_axi_conversion_awvalid,
      s_axi_conversion_awready => s_axi_conversion_awready,
      s_axi_conversion_wdata => s_axi_conversion_wdata,
      s_axi_conversion_wstrb => s_axi_conversion_wstrb,
      s_axi_conversion_wvalid => s_axi_conversion_wvalid,
      s_axi_conversion_wready => s_axi_conversion_wready,
      s_axi_conversion_bresp => s_axi_conversion_bresp,
      s_axi_conversion_bvalid => s_axi_conversion_bvalid,
      s_axi_conversion_bready => s_axi_conversion_bready,
      s_axi_conversion_araddr => s_axi_conversion_araddr,
      s_axi_conversion_arvalid => s_axi_conversion_arvalid,
      s_axi_conversion_arready => s_axi_conversion_arready,
      s_axi_conversion_rdata => s_axi_conversion_rdata,
      s_axi_conversion_rresp => s_axi_conversion_rresp,
      s_axi_conversion_rvalid => s_axi_conversion_rvalid,
      s_axi_conversion_rready => s_axi_conversion_rready,
      s_axi_processing_awaddr => s_axi_processing_awaddr,
      s_axi_processing_awvalid => s_axi_processing_awvalid,
      s_axi_processing_awready => s_axi_processing_awready,
      s_axi_processing_wdata => s_axi_processing_wdata,
      s_axi_processing_wstrb => s_axi_processing_wstrb,
      s_axi_processing_wvalid => s_axi_processing_wvalid,
      s_axi_processing_wready => s_axi_processing_wready,
      s_axi_processing_bresp => s_axi_processing_bresp,
      s_axi_processing_bvalid => s_axi_processing_bvalid,
      s_axi_processing_bready => s_axi_processing_bready,
      s_axi_processing_araddr => s_axi_processing_araddr,
      s_axi_processing_arvalid => s_axi_processing_arvalid,
      s_axi_processing_arready => s_axi_processing_arready,
      s_axi_processing_rdata => s_axi_processing_rdata,
      s_axi_processing_rresp => s_axi_processing_rresp,
      s_axi_processing_rvalid => s_axi_processing_rvalid,
      s_axi_processing_rready => s_axi_processing_rready,
      s_axi_waveform_awaddr => s_axi_waveform_awaddr,
      s_axi_waveform_awvalid => s_axi_waveform_awvalid,
      s_axi_waveform_awready => s_axi_waveform_awready,
      s_axi_waveform_wdata => s_axi_waveform_wdata,
      s_axi_waveform_wstrb => s_axi_waveform_wstrb,
      s_axi_waveform_wvalid => s_axi_waveform_wvalid,
      s_axi_waveform_wready => s_axi_waveform_wready,
      s_axi_waveform_bresp => s_axi_waveform_bresp,
      s_axi_waveform_bvalid => s_axi_waveform_bvalid,
      s_axi_waveform_bready => s_axi_waveform_bready,
      s_axi_waveform_araddr => s_axi_waveform_araddr,
      s_axi_waveform_arvalid => s_axi_waveform_arvalid,
      s_axi_waveform_arready => s_axi_waveform_arready,
      s_axi_waveform_rdata => s_axi_waveform_rdata,
      s_axi_waveform_rresp => s_axi_waveform_rresp,
      s_axi_waveform_rvalid => s_axi_waveform_rvalid,
      s_axi_waveform_rready => s_axi_waveform_rready,
      s_axi_simulator_awaddr => s_axi_simulator_awaddr,
      s_axi_simulator_awvalid => s_axi_simulator_awvalid,
      s_axi_simulator_awready => s_axi_simulator_awready,
      s_axi_simulator_wdata => s_axi_simulator_wdata,
      s_axi_simulator_wstrb => s_axi_simulator_wstrb,
      s_axi_simulator_wvalid => s_axi_simulator_wvalid,
      s_axi_simulator_wready => s_axi_simulator_wready,
      s_axi_simulator_bresp => s_axi_simulator_bresp,
      s_axi_simulator_bvalid => s_axi_simulator_bvalid,
      s_axi_simulator_bready => s_axi_simulator_bready,
      s_axi_simulator_araddr => s_axi_simulator_araddr,
      s_axi_simulator_arvalid => s_axi_simulator_arvalid,
      s_axi_simulator_arready => s_axi_simulator_arready,
      s_axi_simulator_rdata => s_axi_simulator_rdata,
      s_axi_simulator_rresp => s_axi_simulator_rresp,
      s_axi_simulator_rvalid => s_axi_simulator_rvalid,
      s_axi_simulator_rready => s_axi_simulator_rready,
      m_axis_mtr1_tdata => m_axis_mtr1_tdata,
      m_axis_mtr1_tkeep => m_axis_mtr1_tkeep,
      m_axis_mtr1_tvalid => m_axis_mtr1_tvalid,
      m_axis_mtr1_tready => m_axis_mtr1_tready,
      m_axis_mtr1_tlast => m_axis_mtr1_tlast,
      m_axis_mtr2_tdata => m_axis_mtr2_tdata,
      m_axis_mtr2_tkeep => m_axis_mtr2_tkeep,
      m_axis_mtr2_tvalid => m_axis_mtr2_tvalid,
      m_axis_mtr2_tready => m_axis_mtr2_tready,
      m_axis_mtr2_tlast => m_axis_mtr2_tlast,
      m_axis_waveform_tdata => m_axis_waveform_tdata,
      m_axis_waveform_tkeep => m_axis_waveform_tkeep,
      m_axis_waveform_tvalid => m_axis_waveform_tvalid,
      m_axis_waveform_tready => m_axis_waveform_tready,
      m_axis_waveform_tlast => m_axis_waveform_tlast,
      adc_dclk => adc_dclk,
      adc_drdy_n => adc_drdy_n,
      adc_dout => adc_dout,
      adc_reset_n => adc_reset_n,
      adc_start_n => adc_start_n,
      adc_convst_sar => adc_convst_sar
    );
end architecture;
