library ieee;
use ieee.std_logic_1164.all;

entity AdcConversion_Wrapper is
  port (
    aclk                  : in  std_logic;
    aresetn               : in  std_logic;

    s_axis_raw_tdata      : in  std_logic_vector(31 downto 0);
    s_axis_raw_tkeep      : in  std_logic_vector(3 downto 0);
    s_axis_raw_tvalid     : in  std_logic;
    s_axis_raw_tready     : out std_logic;
    s_axis_raw_tlast      : in  std_logic;

    m_axis_converted_tdata  : out std_logic_vector(511 downto 0);
    m_axis_converted_tkeep  : out std_logic_vector(63 downto 0);
    m_axis_converted_tuser  : out std_logic_vector(383 downto 0);
    m_axis_converted_tvalid : out std_logic;
    m_axis_converted_tready : in  std_logic;
    m_axis_converted_tlast  : out std_logic;

    s_axi_config_awaddr   : in  std_logic_vector(7 downto 0);
    s_axi_config_awvalid  : in  std_logic;
    s_axi_config_awready  : out std_logic;
    s_axi_config_wdata    : in  std_logic_vector(31 downto 0);
    s_axi_config_wstrb    : in  std_logic_vector(3 downto 0);
    s_axi_config_wvalid   : in  std_logic;
    s_axi_config_wready   : out std_logic;
    s_axi_config_bresp    : out std_logic_vector(1 downto 0);
    s_axi_config_bvalid   : out std_logic;
    s_axi_config_bready   : in  std_logic;
    s_axi_config_araddr   : in  std_logic_vector(7 downto 0);
    s_axi_config_arvalid  : in  std_logic;
    s_axi_config_arready  : out std_logic;
    s_axi_config_rdata    : out std_logic_vector(31 downto 0);
    s_axi_config_rresp    : out std_logic_vector(1 downto 0);
    s_axi_config_rvalid   : out std_logic;
    s_axi_config_rready   : in  std_logic
  );

  attribute X_INTERFACE_INFO : string;
  attribute X_INTERFACE_PARAMETER : string;
  attribute X_INTERFACE_INFO of aclk : signal is "xilinx.com:signal:clock:1.0 aclk CLK";
  attribute X_INTERFACE_PARAMETER of aclk : signal is
    "XIL_INTERFACENAME aclk, ASSOCIATED_BUSIF S_AXIS_RAW:M_AXIS_CONVERTED:S_AXI_CONFIG, ASSOCIATED_RESET aresetn, FREQ_HZ 99999001";
  attribute X_INTERFACE_INFO of aresetn : signal is "xilinx.com:signal:reset:1.0 aresetn RST";
  attribute X_INTERFACE_PARAMETER of aresetn : signal is "XIL_INTERFACENAME aresetn, POLARITY ACTIVE_LOW";

  attribute X_INTERFACE_INFO of s_axis_raw_tdata : signal is "xilinx.com:interface:axis:1.0 S_AXIS_RAW TDATA";
  attribute X_INTERFACE_INFO of s_axis_raw_tkeep : signal is "xilinx.com:interface:axis:1.0 S_AXIS_RAW TKEEP";
  attribute X_INTERFACE_INFO of s_axis_raw_tvalid : signal is "xilinx.com:interface:axis:1.0 S_AXIS_RAW TVALID";
  attribute X_INTERFACE_INFO of s_axis_raw_tready : signal is "xilinx.com:interface:axis:1.0 S_AXIS_RAW TREADY";
  attribute X_INTERFACE_INFO of s_axis_raw_tlast : signal is "xilinx.com:interface:axis:1.0 S_AXIS_RAW TLAST";
  attribute X_INTERFACE_PARAMETER of s_axis_raw_tdata : signal is
    "XIL_INTERFACENAME S_AXIS_RAW, TDATA_NUM_BYTES 4, TUSER_WIDTH 0, HAS_TREADY 1, HAS_TKEEP 1, HAS_TLAST 1";

  attribute X_INTERFACE_INFO of m_axis_converted_tdata : signal is "xilinx.com:interface:axis:1.0 M_AXIS_CONVERTED TDATA";
  attribute X_INTERFACE_INFO of m_axis_converted_tkeep : signal is "xilinx.com:interface:axis:1.0 M_AXIS_CONVERTED TKEEP";
  attribute X_INTERFACE_INFO of m_axis_converted_tuser : signal is "xilinx.com:interface:axis:1.0 M_AXIS_CONVERTED TUSER";
  attribute X_INTERFACE_INFO of m_axis_converted_tvalid : signal is "xilinx.com:interface:axis:1.0 M_AXIS_CONVERTED TVALID";
  attribute X_INTERFACE_INFO of m_axis_converted_tready : signal is "xilinx.com:interface:axis:1.0 M_AXIS_CONVERTED TREADY";
  attribute X_INTERFACE_INFO of m_axis_converted_tlast : signal is "xilinx.com:interface:axis:1.0 M_AXIS_CONVERTED TLAST";
  attribute X_INTERFACE_PARAMETER of m_axis_converted_tdata : signal is
    "XIL_INTERFACENAME M_AXIS_CONVERTED, TDATA_NUM_BYTES 64, TUSER_WIDTH 384, HAS_TREADY 1, HAS_TKEEP 1, HAS_TLAST 1";

  attribute X_INTERFACE_INFO of s_axi_config_awaddr : signal is "xilinx.com:interface:aximm:1.0 S_AXI_CONFIG AWADDR";
  attribute X_INTERFACE_INFO of s_axi_config_awvalid : signal is "xilinx.com:interface:aximm:1.0 S_AXI_CONFIG AWVALID";
  attribute X_INTERFACE_INFO of s_axi_config_awready : signal is "xilinx.com:interface:aximm:1.0 S_AXI_CONFIG AWREADY";
  attribute X_INTERFACE_INFO of s_axi_config_wdata : signal is "xilinx.com:interface:aximm:1.0 S_AXI_CONFIG WDATA";
  attribute X_INTERFACE_INFO of s_axi_config_wstrb : signal is "xilinx.com:interface:aximm:1.0 S_AXI_CONFIG WSTRB";
  attribute X_INTERFACE_INFO of s_axi_config_wvalid : signal is "xilinx.com:interface:aximm:1.0 S_AXI_CONFIG WVALID";
  attribute X_INTERFACE_INFO of s_axi_config_wready : signal is "xilinx.com:interface:aximm:1.0 S_AXI_CONFIG WREADY";
  attribute X_INTERFACE_INFO of s_axi_config_bresp : signal is "xilinx.com:interface:aximm:1.0 S_AXI_CONFIG BRESP";
  attribute X_INTERFACE_INFO of s_axi_config_bvalid : signal is "xilinx.com:interface:aximm:1.0 S_AXI_CONFIG BVALID";
  attribute X_INTERFACE_INFO of s_axi_config_bready : signal is "xilinx.com:interface:aximm:1.0 S_AXI_CONFIG BREADY";
  attribute X_INTERFACE_INFO of s_axi_config_araddr : signal is "xilinx.com:interface:aximm:1.0 S_AXI_CONFIG ARADDR";
  attribute X_INTERFACE_INFO of s_axi_config_arvalid : signal is "xilinx.com:interface:aximm:1.0 S_AXI_CONFIG ARVALID";
  attribute X_INTERFACE_INFO of s_axi_config_arready : signal is "xilinx.com:interface:aximm:1.0 S_AXI_CONFIG ARREADY";
  attribute X_INTERFACE_INFO of s_axi_config_rdata : signal is "xilinx.com:interface:aximm:1.0 S_AXI_CONFIG RDATA";
  attribute X_INTERFACE_INFO of s_axi_config_rresp : signal is "xilinx.com:interface:aximm:1.0 S_AXI_CONFIG RRESP";
  attribute X_INTERFACE_INFO of s_axi_config_rvalid : signal is "xilinx.com:interface:aximm:1.0 S_AXI_CONFIG RVALID";
  attribute X_INTERFACE_INFO of s_axi_config_rready : signal is "xilinx.com:interface:aximm:1.0 S_AXI_CONFIG RREADY";
  attribute X_INTERFACE_PARAMETER of s_axi_config_awaddr : signal is
    "XIL_INTERFACENAME S_AXI_CONFIG, PROTOCOL AXI4LITE, DATA_WIDTH 32, ADDR_WIDTH 8, ID_WIDTH 0, READ_WRITE_MODE READ_WRITE";
end entity;

architecture structural of AdcConversion_Wrapper is
begin
  implementation : entity work.adc_conversion
    port map (
      aclk => aclk,
      aresetn => aresetn,
      s_axis_tdata => s_axis_raw_tdata,
      s_axis_tkeep => s_axis_raw_tkeep,
      s_axis_tvalid => s_axis_raw_tvalid,
      s_axis_tready => s_axis_raw_tready,
      s_axis_tlast => s_axis_raw_tlast,
      m_axis_tdata => m_axis_converted_tdata,
      m_axis_tkeep => m_axis_converted_tkeep,
      m_axis_tuser => m_axis_converted_tuser,
      m_axis_tvalid => m_axis_converted_tvalid,
      m_axis_tready => m_axis_converted_tready,
      m_axis_tlast => m_axis_converted_tlast,
      s_axi_awaddr => s_axi_config_awaddr,
      s_axi_awvalid => s_axi_config_awvalid,
      s_axi_awready => s_axi_config_awready,
      s_axi_wdata => s_axi_config_wdata,
      s_axi_wstrb => s_axi_config_wstrb,
      s_axi_wvalid => s_axi_config_wvalid,
      s_axi_wready => s_axi_config_wready,
      s_axi_bresp => s_axi_config_bresp,
      s_axi_bvalid => s_axi_config_bvalid,
      s_axi_bready => s_axi_config_bready,
      s_axi_araddr => s_axi_config_araddr,
      s_axi_arvalid => s_axi_config_arvalid,
      s_axi_arready => s_axi_config_arready,
      s_axi_rdata => s_axi_config_rdata,
      s_axi_rresp => s_axi_config_rresp,
      s_axi_rvalid => s_axi_config_rvalid,
      s_axi_rready => s_axi_config_rready
    );
end architecture;
