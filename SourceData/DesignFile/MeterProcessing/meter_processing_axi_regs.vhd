library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.metering_pkg.all;

entity meter_processing_axi_regs is
  port (
    aclk                    : in  std_logic;
    aresetn                 : in  std_logic;

    s_axi_awaddr            : in  std_logic_vector(7 downto 0);
    s_axi_awvalid           : in  std_logic;
    s_axi_awready           : out std_logic;
    s_axi_wdata             : in  word32_t;
    s_axi_wstrb             : in  std_logic_vector(3 downto 0);
    s_axi_wvalid            : in  std_logic;
    s_axi_wready            : out std_logic;
    s_axi_bresp             : out std_logic_vector(1 downto 0);
    s_axi_bvalid            : out std_logic;
    s_axi_bready            : in  std_logic;
    s_axi_araddr            : in  std_logic_vector(7 downto 0);
    s_axi_arvalid           : in  std_logic;
    s_axi_arready           : out std_logic;
    s_axi_rdata             : out word32_t;
    s_axi_rresp             : out std_logic_vector(1 downto 0);
    s_axi_rvalid            : out std_logic;
    s_axi_rready            : in  std_logic;

    shadow_generation_o     : out word32_t;
    shadow_sample_rate_o    : out word32_t;
    shadow_window_samples_o : out word32_t;
    shadow_valid_mask_o     : out std_logic_vector(7 downto 0);
    shadow_enable_o         : out std_logic;
    shadow_dc_remove_o      : out std_logic;
    apply_toggle_o          : out std_logic;

    active_generation_i     : in  word32_t;
    result_sequence_i       : in  word32_t;
    result_drop_count_i     : in  word32_t;
    packet_drop_count_i     : in  word32_t;
    status_i                : in  word32_t
  );
end entity;

architecture rtl of meter_processing_axi_regs is
  constant VERSION_VALUE    : word32_t := x"00010000";
  constant IDENTIFIER_VALUE : word32_t := x"4D505231"; -- "MPR1"

  signal shadow_generation     : word32_t := (others => '0');
  signal shadow_sample_rate    : word32_t := std_logic_vector(to_unsigned(32000, 32));
  signal shadow_window_samples : word32_t := std_logic_vector(to_unsigned(6400, 32));
  signal shadow_valid_mask     : std_logic_vector(7 downto 0) := x"70";
  signal shadow_enable         : std_logic := '0';
  signal shadow_dc_remove      : std_logic := '1';
  signal apply_toggle          : std_logic := '0';
  signal bvalid                : std_logic := '0';
  signal rvalid                : std_logic := '0';
  signal rdata                 : word32_t := (others => '0');
begin
  -- Couple the write-channel handshakes so data can never be consumed before
  -- its address. One write response remains outstanding at a time.
  s_axi_awready <= '1' when bvalid = '0' and
                            s_axi_awvalid = '1' and s_axi_wvalid = '1' else '0';
  s_axi_wready <= '1' when bvalid = '0' and
                           s_axi_awvalid = '1' and s_axi_wvalid = '1' else '0';
  s_axi_bresp <= "00";
  s_axi_bvalid <= bvalid;
  s_axi_arready <= '1' when rvalid = '0' else '0';
  s_axi_rresp <= "00";
  s_axi_rvalid <= rvalid;
  s_axi_rdata <= rdata;

  shadow_generation_o <= shadow_generation;
  shadow_sample_rate_o <= shadow_sample_rate;
  shadow_window_samples_o <= shadow_window_samples;
  shadow_valid_mask_o <= shadow_valid_mask;
  shadow_enable_o <= shadow_enable;
  shadow_dc_remove_o <= shadow_dc_remove;
  apply_toggle_o <= apply_toggle;

  process (aclk)
    variable address_word : natural range 0 to 63;
    variable control_word : word32_t;
    variable updated_word : word32_t;
  begin
    if rising_edge(aclk) then
      if aresetn = '0' then
        shadow_generation <= (others => '0');
        shadow_sample_rate <= std_logic_vector(to_unsigned(32000, 32));
        shadow_window_samples <= std_logic_vector(to_unsigned(6400, 32));
        shadow_valid_mask <= x"70";
        shadow_enable <= '0';
        shadow_dc_remove <= '1';
        apply_toggle <= '0';
        bvalid <= '0';
        rvalid <= '0';
        rdata <= (others => '0');
      else
        if bvalid = '1' and s_axi_bready = '1' then
          bvalid <= '0';
        end if;

        if bvalid = '0' and s_axi_awvalid = '1' and s_axi_wvalid = '1' then
          address_word := to_integer(unsigned(s_axi_awaddr(7 downto 2)));
          case address_word is
            when 2 =>
              control_word := (others => '0');
              control_word(1) := shadow_enable;
              control_word(2) := shadow_dc_remove;
              control_word := apply_write_strobes(control_word, s_axi_wdata, s_axi_wstrb);
              shadow_enable <= control_word(1);
              shadow_dc_remove <= control_word(2);
              if s_axi_wstrb(0) = '1' and s_axi_wdata(0) = '1' then
                apply_toggle <= not apply_toggle;
              end if;
            when 4 =>
              shadow_generation <= apply_write_strobes(
                shadow_generation, s_axi_wdata, s_axi_wstrb);
            when 5 =>
              shadow_sample_rate <= apply_write_strobes(
                shadow_sample_rate, s_axi_wdata, s_axi_wstrb);
            when 6 =>
              shadow_window_samples <= apply_write_strobes(
                shadow_window_samples, s_axi_wdata, s_axi_wstrb);
            when 7 =>
              updated_word := (others => '0');
              updated_word(7 downto 0) := shadow_valid_mask;
              updated_word := apply_write_strobes(updated_word, s_axi_wdata, s_axi_wstrb);
              shadow_valid_mask <= updated_word(7 downto 0);
            when others => null;
          end case;
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
            when 2 =>
              control_word := (others => '0');
              control_word(1) := shadow_enable;
              control_word(2) := shadow_dc_remove;
              rdata <= control_word;
            when 3 => rdata <= status_i;
            when 4 => rdata <= shadow_generation;
            when 5 => rdata <= shadow_sample_rate;
            when 6 => rdata <= shadow_window_samples;
            when 7 => rdata <= x"000000" & shadow_valid_mask;
            when 8 => rdata <= active_generation_i;
            when 9 => rdata <= result_sequence_i;
            when 10 => rdata <= result_drop_count_i;
            when 11 => rdata <= packet_drop_count_i;
            when others => rdata <= (others => '0');
          end case;
          rvalid <= '1';
        end if;
      end if;
    end if;
  end process;
end architecture;
