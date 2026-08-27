library ieee;
use ieee.std_logic_1164.all;

-- Whole-packet AXI4-Stream arbiter. Source 0 has priority only while idle;
-- once the first beat transfers, ownership is held through TLAST.
entity meter_axis_packet_arbiter_2to1 is
  port (
    aclk    : in std_logic;
    aresetn : in std_logic;

    s0_axis_tdata  : in  std_logic_vector(31 downto 0);
    s0_axis_tkeep  : in  std_logic_vector(3 downto 0);
    s0_axis_tvalid : in  std_logic;
    s0_axis_tready : out std_logic;
    s0_axis_tlast  : in  std_logic;

    s1_axis_tdata  : in  std_logic_vector(31 downto 0);
    s1_axis_tkeep  : in  std_logic_vector(3 downto 0);
    s1_axis_tvalid : in  std_logic;
    s1_axis_tready : out std_logic;
    s1_axis_tlast  : in  std_logic;

    m_axis_tdata  : out std_logic_vector(31 downto 0);
    m_axis_tkeep  : out std_logic_vector(3 downto 0);
    m_axis_tvalid : out std_logic;
    m_axis_tready : in  std_logic;
    m_axis_tlast  : out std_logic
  );
end entity;

architecture rtl of meter_axis_packet_arbiter_2to1 is
  type owner_t is (IDLE, SOURCE_0, SOURCE_1);
  signal owner : owner_t := IDLE;
  signal selected_source_0 : std_logic;
  signal output_accept : std_logic;
begin
  selected_source_0 <= '1' when owner = SOURCE_0 or
    (owner = IDLE and s0_axis_tvalid = '1') else '0';

  m_axis_tdata <= s0_axis_tdata when selected_source_0 = '1' else
                  s1_axis_tdata;
  m_axis_tkeep <= s0_axis_tkeep when selected_source_0 = '1' else
                  s1_axis_tkeep;
  m_axis_tvalid <= s0_axis_tvalid when selected_source_0 = '1' else
                   s1_axis_tvalid;
  m_axis_tlast <= s0_axis_tlast when selected_source_0 = '1' else
                  s1_axis_tlast;

  s0_axis_tready <= m_axis_tready when selected_source_0 = '1' else '0';
  s1_axis_tready <= m_axis_tready when selected_source_0 = '0' and
    (owner = SOURCE_1 or (owner = IDLE and s0_axis_tvalid = '0')) else '0';
  output_accept <= m_axis_tvalid and m_axis_tready;

  process (aclk)
  begin
    if rising_edge(aclk) then
      if aresetn = '0' then
        owner <= IDLE;
      elsif output_accept = '1' then
        if m_axis_tlast = '1' then
          owner <= IDLE;
        elsif owner = IDLE then
          if selected_source_0 = '1' then
            owner <= SOURCE_0;
          else
            owner <= SOURCE_1;
          end if;
        end if;
      end if;
    end if;
  end process;
end architecture;
