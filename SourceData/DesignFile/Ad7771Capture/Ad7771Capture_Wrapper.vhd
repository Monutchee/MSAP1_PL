library ieee;
use ieee.std_logic_1164.all;

-- Vivado IP Integrator module-reference boundary. Keep this entity in the
-- ordinary VHDL file type; the implementation entities use VHDL-2008.
entity Ad7771Capture_Wrapper is
    port (
        s_axi_aclk       : in  std_logic;
        s_axi_aresetn    : in  std_logic;

        s_axi_awaddr     : in  std_logic_vector(7 downto 0);
        s_axi_awvalid    : in  std_logic;
        s_axi_awready    : out std_logic;
        s_axi_wdata      : in  std_logic_vector(31 downto 0);
        s_axi_wstrb      : in  std_logic_vector(3 downto 0);
        s_axi_wvalid     : in  std_logic;
        s_axi_wready     : out std_logic;
        s_axi_bresp      : out std_logic_vector(1 downto 0);
        s_axi_bvalid     : out std_logic;
        s_axi_bready     : in  std_logic;
        s_axi_araddr     : in  std_logic_vector(7 downto 0);
        s_axi_arvalid    : in  std_logic;
        s_axi_arready    : out std_logic;
        s_axi_rdata      : out std_logic_vector(31 downto 0);
        s_axi_rresp      : out std_logic_vector(1 downto 0);
        s_axi_rvalid     : out std_logic;
        s_axi_rready     : in  std_logic;

        m_axis_tdata     : out std_logic_vector(31 downto 0);
        m_axis_tkeep     : out std_logic_vector(3 downto 0);
        m_axis_tvalid    : out std_logic;
        m_axis_tready    : in  std_logic;
        m_axis_tlast     : out std_logic;

        adc_dclk         : in  std_logic;
        adc_drdy_n       : in  std_logic;
        adc_dout         : in  std_logic_vector(3 downto 0);
        adc_reset_n      : out std_logic;
        adc_start_n      : out std_logic;
        adc_convst_sar   : out std_logic
    );
end entity Ad7771Capture_Wrapper;

architecture rtl of Ad7771Capture_Wrapper is
    attribute X_INTERFACE_INFO      : string;
    attribute X_INTERFACE_PARAMETER : string;

    attribute X_INTERFACE_INFO of s_axi_aclk : signal is
        "xilinx.com:signal:clock:1.0 s_axi_aclk CLK";
    attribute X_INTERFACE_PARAMETER of s_axi_aclk : signal is
        "XIL_INTERFACENAME s_axi_aclk, ASSOCIATED_BUSIF S_AXI:M_AXIS, ASSOCIATED_RESET s_axi_aresetn, FREQ_HZ 99999001";
    attribute X_INTERFACE_INFO of s_axi_aresetn : signal is
        "xilinx.com:signal:reset:1.0 s_axi_aresetn RST";
    attribute X_INTERFACE_PARAMETER of s_axi_aresetn : signal is
        "XIL_INTERFACENAME s_axi_aresetn, POLARITY ACTIVE_LOW";

    attribute X_INTERFACE_INFO of s_axi_awaddr  : signal is "xilinx.com:interface:aximm:1.0 S_AXI AWADDR";
    attribute X_INTERFACE_PARAMETER of s_axi_awaddr : signal is
        "XIL_INTERFACENAME S_AXI, PROTOCOL AXI4LITE, DATA_WIDTH 32, ADDR_WIDTH 8, ID_WIDTH 0, READ_WRITE_MODE READ_WRITE";
    attribute X_INTERFACE_INFO of s_axi_awvalid : signal is "xilinx.com:interface:aximm:1.0 S_AXI AWVALID";
    attribute X_INTERFACE_INFO of s_axi_awready : signal is "xilinx.com:interface:aximm:1.0 S_AXI AWREADY";
    attribute X_INTERFACE_INFO of s_axi_wdata   : signal is "xilinx.com:interface:aximm:1.0 S_AXI WDATA";
    attribute X_INTERFACE_INFO of s_axi_wstrb   : signal is "xilinx.com:interface:aximm:1.0 S_AXI WSTRB";
    attribute X_INTERFACE_INFO of s_axi_wvalid  : signal is "xilinx.com:interface:aximm:1.0 S_AXI WVALID";
    attribute X_INTERFACE_INFO of s_axi_wready  : signal is "xilinx.com:interface:aximm:1.0 S_AXI WREADY";
    attribute X_INTERFACE_INFO of s_axi_bresp   : signal is "xilinx.com:interface:aximm:1.0 S_AXI BRESP";
    attribute X_INTERFACE_INFO of s_axi_bvalid  : signal is "xilinx.com:interface:aximm:1.0 S_AXI BVALID";
    attribute X_INTERFACE_INFO of s_axi_bready  : signal is "xilinx.com:interface:aximm:1.0 S_AXI BREADY";
    attribute X_INTERFACE_INFO of s_axi_araddr  : signal is "xilinx.com:interface:aximm:1.0 S_AXI ARADDR";
    attribute X_INTERFACE_INFO of s_axi_arvalid : signal is "xilinx.com:interface:aximm:1.0 S_AXI ARVALID";
    attribute X_INTERFACE_INFO of s_axi_arready : signal is "xilinx.com:interface:aximm:1.0 S_AXI ARREADY";
    attribute X_INTERFACE_INFO of s_axi_rdata   : signal is "xilinx.com:interface:aximm:1.0 S_AXI RDATA";
    attribute X_INTERFACE_INFO of s_axi_rresp   : signal is "xilinx.com:interface:aximm:1.0 S_AXI RRESP";
    attribute X_INTERFACE_INFO of s_axi_rvalid  : signal is "xilinx.com:interface:aximm:1.0 S_AXI RVALID";
    attribute X_INTERFACE_INFO of s_axi_rready  : signal is "xilinx.com:interface:aximm:1.0 S_AXI RREADY";

    attribute X_INTERFACE_INFO of m_axis_tdata  : signal is "xilinx.com:interface:axis:1.0 M_AXIS TDATA";
    attribute X_INTERFACE_PARAMETER of m_axis_tdata : signal is
        "XIL_INTERFACENAME M_AXIS, TDATA_NUM_BYTES 4, TUSER_WIDTH 0, HAS_TREADY 1, HAS_TLAST 1, HAS_TKEEP 1";
    attribute X_INTERFACE_INFO of m_axis_tkeep  : signal is "xilinx.com:interface:axis:1.0 M_AXIS TKEEP";
    attribute X_INTERFACE_INFO of m_axis_tvalid : signal is "xilinx.com:interface:axis:1.0 M_AXIS TVALID";
    attribute X_INTERFACE_INFO of m_axis_tready : signal is "xilinx.com:interface:axis:1.0 M_AXIS TREADY";
    attribute X_INTERFACE_INFO of m_axis_tlast  : signal is "xilinx.com:interface:axis:1.0 M_AXIS TLAST";

    attribute X_INTERFACE_INFO of adc_dclk : signal is
        "xilinx.com:signal:clock:1.0 adc_dclk CLK";
    attribute X_INTERFACE_PARAMETER of adc_dclk : signal is
        "XIL_INTERFACENAME adc_dclk, FREQ_HZ 8192000";
begin
    implementation : entity work.ad7771_capture(rtl)
        port map (
            s_axi_aclk       => s_axi_aclk,
            s_axi_aresetn    => s_axi_aresetn,
            s_axi_awaddr     => s_axi_awaddr,
            s_axi_awvalid    => s_axi_awvalid,
            s_axi_awready    => s_axi_awready,
            s_axi_wdata      => s_axi_wdata,
            s_axi_wstrb      => s_axi_wstrb,
            s_axi_wvalid     => s_axi_wvalid,
            s_axi_wready     => s_axi_wready,
            s_axi_bresp      => s_axi_bresp,
            s_axi_bvalid     => s_axi_bvalid,
            s_axi_bready     => s_axi_bready,
            s_axi_araddr     => s_axi_araddr,
            s_axi_arvalid    => s_axi_arvalid,
            s_axi_arready    => s_axi_arready,
            s_axi_rdata      => s_axi_rdata,
            s_axi_rresp      => s_axi_rresp,
            s_axi_rvalid     => s_axi_rvalid,
            s_axi_rready     => s_axi_rready,
            m_axis_tdata     => m_axis_tdata,
            m_axis_tkeep     => m_axis_tkeep,
            m_axis_tvalid    => m_axis_tvalid,
            m_axis_tready    => m_axis_tready,
            m_axis_tlast     => m_axis_tlast,
            adc_dclk         => adc_dclk,
            adc_drdy_n       => adc_drdy_n,
            adc_dout         => adc_dout,
            adc_reset_n      => adc_reset_n,
            adc_start_n      => adc_start_n,
            adc_convst_sar   => adc_convst_sar
        );
end architecture rtl;
