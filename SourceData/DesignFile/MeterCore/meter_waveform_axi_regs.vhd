library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.metering_pkg.all;

-- Linux-owned waveform capture control and statistics. Time correlation and
-- interval scheduling live in meter_time_control_axi_regs so this register
-- bank cannot couple metrology timing to waveform DMA operation.
entity meter_waveform_axi_regs is
  port (
    aclk    : in std_logic;
    aresetn : in std_logic;
    s_axi_awaddr : in std_logic_vector(7 downto 0);
    s_axi_awvalid : in std_logic;
    s_axi_awready : out std_logic;
    s_axi_wdata : in std_logic_vector(31 downto 0);
    s_axi_wstrb : in std_logic_vector(3 downto 0);
    s_axi_wvalid : in std_logic;
    s_axi_wready : out std_logic;
    s_axi_bresp : out std_logic_vector(1 downto 0);
    s_axi_bvalid : out std_logic;
    s_axi_bready : in std_logic;
    s_axi_araddr : in std_logic_vector(7 downto 0);
    s_axi_arvalid : in std_logic;
    s_axi_arready : out std_logic;
    s_axi_rdata : out std_logic_vector(31 downto 0);
    s_axi_rresp : out std_logic_vector(1 downto 0);
    s_axi_rvalid : out std_logic;
    s_axi_rready : in std_logic;
    drop_count_i : in std_logic_vector(31 downto 0);
    block_count_i : in std_logic_vector(31 downto 0);
    status_i : in std_logic_vector(31 downto 0);
    enable_o : out std_logic;
    clear_stats_o : out std_logic
  );
end entity;

architecture rtl of meter_waveform_axi_regs is
  constant VERSION_VALUE : std_logic_vector(31 downto 0) := x"00020000";
  constant IDENTIFIER_VALUE : std_logic_vector(31 downto 0) := x"31434657"; -- WFC1
  constant BLOCK_BYTES_VALUE : std_logic_vector(31 downto 0) := x"00008040";
  signal enabled : std_logic := '0';
  signal clear_stats : std_logic := '0';
  signal bvalid : std_logic := '0';
  signal rvalid : std_logic := '0';
  signal rdata : std_logic_vector(31 downto 0) := (others => '0');
begin
  s_axi_awready <= '1' when bvalid = '0' and s_axi_awvalid = '1' and s_axi_wvalid = '1' else '0';
  s_axi_wready <= '1' when bvalid = '0' and s_axi_awvalid = '1' and s_axi_wvalid = '1' else '0';
  s_axi_bresp <= "00";
  s_axi_bvalid <= bvalid;
  s_axi_arready <= '1' when rvalid = '0' else '0';
  s_axi_rresp <= "00";
  s_axi_rvalid <= rvalid;
  s_axi_rdata <= rdata;
  enable_o <= enabled;
  clear_stats_o <= clear_stats;

  process (aclk)
    variable address_word : natural range 0 to 63;
    variable control_word : std_logic_vector(31 downto 0);
  begin
    if rising_edge(aclk) then
      clear_stats <= '0';
      if aresetn = '0' then
        enabled <= '0';
        clear_stats <= '0';
        bvalid <= '0';
        rvalid <= '0';
        rdata <= (others => '0');
      else
        if bvalid = '1' and s_axi_bready = '1' then
          bvalid <= '0';
        end if;
        if bvalid = '0' and s_axi_awvalid = '1' and s_axi_wvalid = '1' then
          address_word := to_integer(unsigned(s_axi_awaddr(7 downto 2)));
          if address_word = 2 then
            control_word := (others => '0');
            control_word(0) := enabled;
            control_word := apply_write_strobes(control_word, s_axi_wdata, s_axi_wstrb);
            enabled <= control_word(0);
            if control_word(2) = '1' then
              clear_stats <= '1';
            end if;
          end if;
          bvalid <= '1';
        end if;
        if rvalid = '1' and s_axi_rready = '1' then
          rvalid <= '0';
        end if;
        if rvalid = '0' and s_axi_arvalid = '1' then
          address_word := to_integer(unsigned(s_axi_araddr(7 downto 2)));
          case address_word is
            when 0 => rdata <= VERSION_VALUE;
            when 1 => rdata <= IDENTIFIER_VALUE;
            when 2 => rdata <= (31 downto 1 => '0') & enabled;
            when 3 => rdata <= status_i;
            when 12 => rdata <= drop_count_i;
            when 13 => rdata <= block_count_i;
            when 14 => rdata <= BLOCK_BYTES_VALUE;
            when others => rdata <= (others => '0');
          end case;
          rvalid <= '1';
        end if;
      end if;
    end if;
  end process;
end architecture;
