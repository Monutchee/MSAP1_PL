library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity MeterPacketizer_Wrapper is
  port (
    aclk               : in  std_logic;
    aresetn            : in  std_logic;
    record_data_i      : in  std_logic_vector(2047 downto 0);
    record_valid_i     : in  std_logic;
    record_ready_o     : out std_logic;
    m_axis_meter_tdata : out std_logic_vector(31 downto 0);
    m_axis_meter_tkeep : out std_logic_vector(3 downto 0);
    m_axis_meter_tvalid: out std_logic;
    m_axis_meter_tready: in  std_logic;
    m_axis_meter_tlast : out std_logic;
    drop_count_o       : out std_logic_vector(31 downto 0)
  );

  attribute X_INTERFACE_INFO : string;
  attribute X_INTERFACE_PARAMETER : string;
  attribute X_INTERFACE_INFO of aclk : signal is "xilinx.com:signal:clock:1.0 aclk CLK";
  attribute X_INTERFACE_PARAMETER of aclk : signal is
    "XIL_INTERFACENAME aclk, ASSOCIATED_BUSIF M_AXIS_METER, ASSOCIATED_RESET aresetn, FREQ_HZ 99999001";
  attribute X_INTERFACE_INFO of aresetn : signal is "xilinx.com:signal:reset:1.0 aresetn RST";
  attribute X_INTERFACE_PARAMETER of aresetn : signal is "XIL_INTERFACENAME aresetn, POLARITY ACTIVE_LOW";
  attribute X_INTERFACE_INFO of m_axis_meter_tdata : signal is "xilinx.com:interface:axis:1.0 M_AXIS_METER TDATA";
  attribute X_INTERFACE_INFO of m_axis_meter_tkeep : signal is "xilinx.com:interface:axis:1.0 M_AXIS_METER TKEEP";
  attribute X_INTERFACE_INFO of m_axis_meter_tvalid : signal is "xilinx.com:interface:axis:1.0 M_AXIS_METER TVALID";
  attribute X_INTERFACE_INFO of m_axis_meter_tready : signal is "xilinx.com:interface:axis:1.0 M_AXIS_METER TREADY";
  attribute X_INTERFACE_INFO of m_axis_meter_tlast : signal is "xilinx.com:interface:axis:1.0 M_AXIS_METER TLAST";
  attribute X_INTERFACE_PARAMETER of m_axis_meter_tdata : signal is
    "XIL_INTERFACENAME M_AXIS_METER, TDATA_NUM_BYTES 4, TUSER_WIDTH 0, HAS_TREADY 1, HAS_TKEEP 1, HAS_TLAST 1";
end entity;

architecture rtl of MeterPacketizer_Wrapper is
  signal active_data   : std_logic_vector(2047 downto 0) := (others => '0');
  signal pending_data  : std_logic_vector(2047 downto 0) := (others => '0');
  signal active_valid  : std_logic := '0';
  signal pending_valid : std_logic := '0';
  signal word_index    : natural range 0 to 63 := 0;
  signal drop_count    : unsigned(31 downto 0) := (others => '0');
begin
  -- New snapshots are always accepted. If both buffers are occupied, the
  -- pending snapshot is replaced so the newest measurement is retained.
  record_ready_o <= '1';
  m_axis_meter_tdata <= active_data((word_index * 32) + 31 downto word_index * 32);
  m_axis_meter_tkeep <= "1111";
  m_axis_meter_tvalid <= active_valid;
  m_axis_meter_tlast <= '1' when word_index = 63 else '0';
  drop_count_o <= std_logic_vector(drop_count);

  process (aclk)
    variable next_active_data   : std_logic_vector(2047 downto 0);
    variable next_pending_data  : std_logic_vector(2047 downto 0);
    variable next_active_valid  : std_logic;
    variable next_pending_valid : std_logic;
    variable next_word_index    : natural range 0 to 63;
    variable next_drop_count    : unsigned(31 downto 0);
  begin
    if rising_edge(aclk) then
      if aresetn = '0' then
        active_data <= (others => '0');
        pending_data <= (others => '0');
        active_valid <= '0';
        pending_valid <= '0';
        word_index <= 0;
        drop_count <= (others => '0');
      else
        next_active_data := active_data;
        next_pending_data := pending_data;
        next_active_valid := active_valid;
        next_pending_valid := pending_valid;
        next_word_index := word_index;
        next_drop_count := drop_count;

        if active_valid = '1' and m_axis_meter_tready = '1' then
          if word_index = 63 then
            if pending_valid = '1' then
              next_active_data := pending_data;
              next_active_valid := '1';
              next_pending_valid := '0';
            else
              next_active_valid := '0';
            end if;
            next_word_index := 0;
          else
            next_word_index := word_index + 1;
          end if;
        end if;

        if record_valid_i = '1' then
          if next_active_valid = '0' then
            next_active_data := record_data_i;
            next_active_valid := '1';
            next_word_index := 0;
          elsif next_pending_valid = '0' then
            next_pending_data := record_data_i;
            next_pending_valid := '1';
          else
            next_pending_data := record_data_i;
            next_drop_count := next_drop_count + 1;
          end if;
        end if;

        active_data <= next_active_data;
        pending_data <= next_pending_data;
        active_valid <= next_active_valid;
        pending_valid <= next_pending_valid;
        word_index <= next_word_index;
        drop_count <= next_drop_count;
      end if;
    end if;
  end process;
end architecture;
