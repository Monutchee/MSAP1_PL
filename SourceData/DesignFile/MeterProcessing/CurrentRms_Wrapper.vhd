library ieee;
use ieee.std_logic_1164.all;

entity CurrentRms_Wrapper is
  port (
    aclk                    : in  std_logic;
    aresetn                 : in  std_logic;
    s_axis_converted_tdata  : in  std_logic_vector(511 downto 0);
    s_axis_converted_tkeep  : in  std_logic_vector(63 downto 0);
    s_axis_converted_tuser  : in  std_logic_vector(383 downto 0);
    s_axis_converted_tvalid : in  std_logic;
    s_axis_converted_tready : out std_logic;
    s_axis_converted_tlast  : in  std_logic;
    current_valid_mask_o    : out std_logic_vector(7 downto 0);
    current_mean_q16_o      : out std_logic_vector(511 downto 0);
    current_rms_q16_o       : out std_logic_vector(511 downto 0);
    current_rms_count_o     : out std_logic_vector(255 downto 0)
  );

  attribute X_INTERFACE_INFO : string;
  attribute X_INTERFACE_PARAMETER : string;
  attribute X_INTERFACE_INFO of aclk : signal is "xilinx.com:signal:clock:1.0 aclk CLK";
  attribute X_INTERFACE_PARAMETER of aclk : signal is
    "XIL_INTERFACENAME aclk, ASSOCIATED_BUSIF S_AXIS_CONVERTED, ASSOCIATED_RESET aresetn, FREQ_HZ 99999001";
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
end entity;

architecture rtl of CurrentRms_Wrapper is
begin
  -- Current scaling is intentionally unavailable in this milestone. This
  -- branch consumes every broadcast frame and can never backpressure capture.
  s_axis_converted_tready <= '1';
  current_valid_mask_o <= (others => '0');
  current_mean_q16_o <= (others => '0');
  current_rms_q16_o <= (others => '0');
  current_rms_count_o <= (others => '0');
end architecture;
