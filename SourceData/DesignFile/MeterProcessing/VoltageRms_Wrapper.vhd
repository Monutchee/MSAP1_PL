library ieee;
use ieee.std_logic_1164.all;

entity VoltageRms_Wrapper is
  port (
    aclk                    : in  std_logic;
    aresetn                 : in  std_logic;
    s_axis_converted_tdata  : in  std_logic_vector(511 downto 0);
    s_axis_converted_tkeep  : in  std_logic_vector(63 downto 0);
    s_axis_converted_tuser  : in  std_logic_vector(383 downto 0);
    s_axis_converted_tvalid : in  std_logic;
    s_axis_converted_tready : out std_logic;
    s_axis_converted_tlast  : in  std_logic;

    s_axi_config_awaddr     : in  std_logic_vector(7 downto 0);
    s_axi_config_awvalid    : in  std_logic;
    s_axi_config_awready    : out std_logic;
    s_axi_config_wdata      : in  std_logic_vector(31 downto 0);
    s_axi_config_wstrb      : in  std_logic_vector(3 downto 0);
    s_axi_config_wvalid     : in  std_logic;
    s_axi_config_wready     : out std_logic;
    s_axi_config_bresp      : out std_logic_vector(1 downto 0);
    s_axi_config_bvalid     : out std_logic;
    s_axi_config_bready     : in  std_logic;
    s_axi_config_araddr     : in  std_logic_vector(7 downto 0);
    s_axi_config_arvalid    : in  std_logic;
    s_axi_config_arready    : out std_logic;
    s_axi_config_rdata      : out std_logic_vector(31 downto 0);
    s_axi_config_rresp      : out std_logic_vector(1 downto 0);
    s_axi_config_rvalid     : out std_logic;
    s_axi_config_rready     : in  std_logic;

    packet_drop_count_i     : in  std_logic_vector(31 downto 0);
    result_valid_o          : out std_logic;
    result_sequence_o       : out std_logic_vector(31 downto 0);
    result_generation_o     : out std_logic_vector(31 downto 0);
    result_sample_rate_o    : out std_logic_vector(31 downto 0);
    result_window_samples_o : out std_logic_vector(31 downto 0);
    result_valid_mask_o     : out std_logic_vector(7 downto 0);
    result_status_o         : out std_logic_vector(31 downto 0);
    result_mean_q16_o       : out std_logic_vector(511 downto 0);
    result_rms_q16_o        : out std_logic_vector(511 downto 0);
    result_rms_count_o      : out std_logic_vector(255 downto 0)
  );

  attribute X_INTERFACE_INFO : string;
  attribute X_INTERFACE_PARAMETER : string;
  attribute X_INTERFACE_INFO of aclk : signal is "xilinx.com:signal:clock:1.0 aclk CLK";
  attribute X_INTERFACE_PARAMETER of aclk : signal is
    "XIL_INTERFACENAME aclk, ASSOCIATED_BUSIF S_AXIS_CONVERTED:S_AXI_CONFIG, ASSOCIATED_RESET aresetn, FREQ_HZ 99999001";
  attribute X_INTERFACE_INFO of aresetn : signal is "xilinx.com:signal:reset:1.0 aresetn RST";
  attribute X_INTERFACE_PARAMETER of aresetn : signal is "XIL_INTERFACENAME aresetn, POLARITY ACTIVE_LOW";

  attribute X_INTERFACE_INFO of s_axis_converted_tdata : signal is "xilinx.com:interface:axis:1.0 S_AXIS_CONVERTED TDATA";
  attribute X_INTERFACE_INFO of s_axis_converted_tkeep : signal is "xilinx.com:interface:axis:1.0 S_AXIS_CONVERTED TKEEP";
  attribute X_INTERFACE_INFO of s_axis_converted_tuser : signal is "xilinx.com:interface:axis:1.0 S_AXIS_CONVERTED TUSER";
  attribute X_INTERFACE_INFO of s_axis_converted_tvalid : signal is "xilinx.com:interface:axis:1.0 S_AXIS_CONVERTED TVALID";
  attribute X_INTERFACE_INFO of s_axis_converted_tready : signal is "xilinx.com:interface:axis:1.0 S_AXIS_CONVERTED TREADY";
  attribute X_INTERFACE_INFO of s_axis_converted_tlast : signal is "xilinx.com:interface:axis:1.0 S_AXIS_CONVERTED TLAST";
  attribute X_INTERFACE_PARAMETER of s_axis_converted_tdata : signal is
    "XIL_INTERFACENAME S_AXIS_CONVERTED, TDATA_NUM_BYTES 64, TUSER_WIDTH 384, HAS_TREADY 1, HAS_TKEEP 1, HAS_TLAST 1";

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

architecture structural of VoltageRms_Wrapper is
  signal shadow_generation     : std_logic_vector(31 downto 0);
  signal shadow_sample_rate    : std_logic_vector(31 downto 0);
  signal shadow_window_samples : std_logic_vector(31 downto 0);
  signal shadow_valid_mask     : std_logic_vector(7 downto 0);
  signal shadow_enable         : std_logic;
  signal shadow_dc_remove      : std_logic;
  signal apply_toggle          : std_logic;
  signal active_generation     : std_logic_vector(31 downto 0);
  signal core_status           : std_logic_vector(31 downto 0);
  signal result_sequence       : std_logic_vector(31 downto 0);
  signal result_drop_count     : std_logic_vector(31 downto 0);
begin
  registers : entity work.meter_processing_axi_regs
    port map (
      aclk => aclk, aresetn => aresetn,
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
      s_axi_rready => s_axi_config_rready,
      shadow_generation_o => shadow_generation,
      shadow_sample_rate_o => shadow_sample_rate,
      shadow_window_samples_o => shadow_window_samples,
      shadow_valid_mask_o => shadow_valid_mask,
      shadow_enable_o => shadow_enable,
      shadow_dc_remove_o => shadow_dc_remove,
      apply_toggle_o => apply_toggle,
      active_generation_i => active_generation,
      result_sequence_i => result_sequence,
      result_drop_count_i => result_drop_count,
      packet_drop_count_i => packet_drop_count_i,
      status_i => core_status
    );

  rms_core : entity work.voltage_rms
    port map (
      aclk => aclk, aresetn => aresetn,
      s_axis_tdata => s_axis_converted_tdata,
      s_axis_tkeep => s_axis_converted_tkeep,
      s_axis_tuser => s_axis_converted_tuser,
      s_axis_tvalid => s_axis_converted_tvalid,
      s_axis_tready => s_axis_converted_tready,
      s_axis_tlast => s_axis_converted_tlast,
      config_generation_i => shadow_generation,
      config_sample_rate_i => shadow_sample_rate,
      config_window_samples_i => shadow_window_samples,
      config_valid_mask_i => shadow_valid_mask,
      config_enable_i => shadow_enable,
      config_dc_remove_i => shadow_dc_remove,
      config_apply_toggle_i => apply_toggle,
      active_generation_o => active_generation,
      status_o => core_status,
      result_valid_o => result_valid_o,
      result_sequence_o => result_sequence,
      result_generation_o => result_generation_o,
      result_sample_rate_o => result_sample_rate_o,
      result_window_samples_o => result_window_samples_o,
      result_valid_mask_o => result_valid_mask_o,
      result_status_o => result_status_o,
      result_mean_q16_o => result_mean_q16_o,
      result_rms_q16_o => result_rms_q16_o,
      result_rms_count_o => result_rms_count_o,
      result_drop_count_o => result_drop_count
    );

  result_sequence_o <= result_sequence;
end architecture;
