library ieee;
use ieee.std_logic_1164.all;

-- Fair whole-packet arbiter for the private R5C1 packet families. Selection
-- is round-robin only while idle; after the first accepted beat, ownership is
-- immutable through TLAST. Thus packet types cannot interleave and every
-- continuously pending family is selected within four packet boundaries.
entity meter_axis_packet_arbiter_5to1 is
  port (
    aclk    : in std_logic;
    aresetn : in std_logic;

    s0_axis_tdata  : in std_logic_vector(31 downto 0);
    s0_axis_tkeep  : in std_logic_vector(3 downto 0);
    s0_axis_tvalid : in std_logic;
    s0_axis_tready : out std_logic;
    s0_axis_tlast  : in std_logic;
    s1_axis_tdata  : in std_logic_vector(31 downto 0);
    s1_axis_tkeep  : in std_logic_vector(3 downto 0);
    s1_axis_tvalid : in std_logic;
    s1_axis_tready : out std_logic;
    s1_axis_tlast  : in std_logic;
    s2_axis_tdata  : in std_logic_vector(31 downto 0);
    s2_axis_tkeep  : in std_logic_vector(3 downto 0);
    s2_axis_tvalid : in std_logic;
    s2_axis_tready : out std_logic;
    s2_axis_tlast  : in std_logic;
    s3_axis_tdata  : in std_logic_vector(31 downto 0);
    s3_axis_tkeep  : in std_logic_vector(3 downto 0);
    s3_axis_tvalid : in std_logic;
    s3_axis_tready : out std_logic;
    s3_axis_tlast  : in std_logic;
    s4_axis_tdata  : in std_logic_vector(31 downto 0);
    s4_axis_tkeep  : in std_logic_vector(3 downto 0);
    s4_axis_tvalid : in std_logic;
    s4_axis_tready : out std_logic;
    s4_axis_tlast  : in std_logic;

    m_axis_tdata  : out std_logic_vector(31 downto 0);
    m_axis_tkeep  : out std_logic_vector(3 downto 0);
    m_axis_tvalid : out std_logic;
    m_axis_tready : in std_logic;
    m_axis_tlast  : out std_logic
  );
end entity;

architecture rtl of meter_axis_packet_arbiter_5to1 is
  type data_array_t is array (0 to 4) of std_logic_vector(31 downto 0);
  type keep_array_t is array (0 to 4) of std_logic_vector(3 downto 0);
  type bit_array_t is array (0 to 4) of std_logic;
  signal source_data  : data_array_t;
  signal source_keep  : keep_array_t;
  signal source_valid : bit_array_t;
  signal source_ready : bit_array_t;
  signal source_last  : bit_array_t;
  signal owner         : integer range -1 to 4 := -1;
  signal next_priority : natural range 0 to 4 := 0;
  signal selected      : natural range 0 to 4 := 0;
  signal selected_valid: std_logic;
  signal output_accept : std_logic;
begin
  source_data(0) <= s0_axis_tdata; source_keep(0) <= s0_axis_tkeep;
  source_valid(0) <= s0_axis_tvalid; source_last(0) <= s0_axis_tlast;
  source_data(1) <= s1_axis_tdata; source_keep(1) <= s1_axis_tkeep;
  source_valid(1) <= s1_axis_tvalid; source_last(1) <= s1_axis_tlast;
  source_data(2) <= s2_axis_tdata; source_keep(2) <= s2_axis_tkeep;
  source_valid(2) <= s2_axis_tvalid; source_last(2) <= s2_axis_tlast;
  source_data(3) <= s3_axis_tdata; source_keep(3) <= s3_axis_tkeep;
  source_valid(3) <= s3_axis_tvalid; source_last(3) <= s3_axis_tlast;
  source_data(4) <= s4_axis_tdata; source_keep(4) <= s4_axis_tkeep;
  source_valid(4) <= s4_axis_tvalid; source_last(4) <= s4_axis_tlast;

  s0_axis_tready <= source_ready(0); s1_axis_tready <= source_ready(1);
  s2_axis_tready <= source_ready(2); s3_axis_tready <= source_ready(3);
  s4_axis_tready <= source_ready(4);

  process (all)
    variable choice : natural range 0 to 4;
    variable probe  : natural range 0 to 4;
    variable found  : boolean;
  begin
    choice := next_priority;
    found := false;
    if owner /= -1 then
      choice := owner;
      found := true;
    else
      for offset in 0 to 4 loop
        probe := (next_priority + offset) mod 5;
        if not found and source_valid(probe) = '1' then
          choice := probe;
          found := true;
        end if;
      end loop;
    end if;
    selected <= choice;
    if found then selected_valid <= source_valid(choice);
    else selected_valid <= '0'; end if;
    for index in 0 to 4 loop
      source_ready(index) <= '0';
    end loop;
    if found then source_ready(choice) <= m_axis_tready; end if;
  end process;

  m_axis_tdata <= source_data(selected);
  m_axis_tkeep <= source_keep(selected);
  m_axis_tvalid <= selected_valid;
  m_axis_tlast <= source_last(selected);
  output_accept <= selected_valid and m_axis_tready;

  process (aclk)
  begin
    if rising_edge(aclk) then
      if aresetn = '0' then
        owner <= -1;
        next_priority <= 0;
      elsif output_accept = '1' then
        if source_last(selected) = '1' then
          owner <= -1;
          if selected = 4 then next_priority <= 0;
          else next_priority <= selected + 1; end if;
        elsif owner = -1 then
          owner <= selected;
        end if;
      end if;
    end if;
  end process;
end architecture;
