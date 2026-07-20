library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.metering_pkg.all;

entity adc_conversion_axi_regs is
  port (
    aclk                 : in  std_logic;
    aresetn              : in  std_logic;

    s_axi_awaddr         : in  std_logic_vector(7 downto 0);
    s_axi_awvalid        : in  std_logic;
    s_axi_awready        : out std_logic;
    s_axi_wdata          : in  word32_t;
    s_axi_wstrb          : in  std_logic_vector(3 downto 0);
    s_axi_wvalid         : in  std_logic;
    s_axi_wready         : out std_logic;
    s_axi_bresp          : out std_logic_vector(1 downto 0);
    s_axi_bvalid         : out std_logic;
    s_axi_bready         : in  std_logic;
    s_axi_araddr         : in  std_logic_vector(7 downto 0);
    s_axi_arvalid        : in  std_logic;
    s_axi_arready        : out std_logic;
    s_axi_rdata          : out word32_t;
    s_axi_rresp          : out std_logic_vector(1 downto 0);
    s_axi_rvalid         : out std_logic;
    s_axi_rready         : in  std_logic;

    shadow_generation_o  : out word32_t;
    shadow_valid_mask_o  : out std_logic_vector(7 downto 0);
    shadow_enable_o      : out std_logic;
    shadow_scale_q16_o   : out std_logic_vector(255 downto 0);
    apply_toggle_o       : out std_logic;

    active_generation_i  : in  word32_t;
    active_valid_mask_i  : in  std_logic_vector(7 downto 0);
    active_enable_i      : in  std_logic;
    apply_pending_i      : in  std_logic;
    saturation_seen_i    : in  std_logic;
    sample_sequence_i    : in  word32_t
  );
end entity;

architecture rtl of adc_conversion_axi_regs is
  constant VERSION_VALUE    : word32_t := x"00010000";
  constant IDENTIFIER_VALUE : word32_t := x"41435631"; -- "ACV1"

  signal shadow_generation : word32_t := (others => '0');
  signal shadow_valid_mask : std_logic_vector(7 downto 0) := (others => '0');
  signal shadow_enable     : std_logic := '0';
  signal shadow_scale      : word32_array_t(0 to 7) := (others => (others => '0'));
  signal apply_toggle      : std_logic := '0';

  signal bvalid            : std_logic := '0';
  signal rvalid            : std_logic := '0';
  signal rdata             : word32_t := (others => '0');
begin
  -- Accept the independently timed AXI-Lite address and data channels only
  -- when both are present. This prevents an early W handshake from losing its
  -- matching address while keeping the single-outstanding-write register bank.
  s_axi_awready <= '1' when bvalid = '0' and
                            s_axi_awvalid = '1' and s_axi_wvalid = '1' else '0';
  s_axi_wready  <= '1' when bvalid = '0' and
                            s_axi_awvalid = '1' and s_axi_wvalid = '1' else '0';
  s_axi_bresp   <= "00";
  s_axi_bvalid  <= bvalid;

  s_axi_arready <= '1' when rvalid = '0' else '0';
  s_axi_rresp   <= "00";
  s_axi_rvalid  <= rvalid;
  s_axi_rdata   <= rdata;

  shadow_generation_o <= shadow_generation;
  shadow_valid_mask_o <= shadow_valid_mask;
  shadow_enable_o <= shadow_enable;
  apply_toggle_o <= apply_toggle;

  generate_scale_output : for channel_index in 0 to 7 generate
    shadow_scale_q16_o((channel_index * 32) + 31 downto channel_index * 32) <=
      shadow_scale(channel_index);
  end generate;

  process (aclk)
    variable address_word : natural range 0 to 63;
    variable status_value : word32_t;
    variable updated_word : word32_t;
  begin
    if rising_edge(aclk) then
      if aresetn = '0' then
        shadow_generation <= (others => '0');
        shadow_valid_mask <= (others => '0');
        shadow_enable <= '0';
        shadow_scale <= (others => (others => '0'));
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
              updated_word := (others => '0');
              updated_word(1) := shadow_enable;
              updated_word := apply_write_strobes(updated_word, s_axi_wdata, s_axi_wstrb);
              shadow_enable <= updated_word(1);
              if s_axi_wstrb(0) = '1' and s_axi_wdata(0) = '1' then
                apply_toggle <= not apply_toggle;
              end if;
            when 4 =>
              shadow_generation <= apply_write_strobes(
                shadow_generation, s_axi_wdata, s_axi_wstrb);
            when 5 =>
              updated_word := (others => '0');
              updated_word(7 downto 0) := shadow_valid_mask;
              updated_word := apply_write_strobes(updated_word, s_axi_wdata, s_axi_wstrb);
              shadow_valid_mask <= updated_word(7 downto 0);
            when 6 to 13 =>
              shadow_scale(address_word - 6) <= apply_write_strobes(
                shadow_scale(address_word - 6), s_axi_wdata, s_axi_wstrb);
            when others =>
              null;
          end case;
          bvalid <= '1';
        end if;

        if rvalid = '1' and s_axi_rready = '1' then
          rvalid <= '0';
        end if;

        if rvalid = '0' and s_axi_arvalid = '1' then
          address_word := to_integer(unsigned(s_axi_araddr(7 downto 2)));
          status_value := (others => '0');
          status_value(0) := active_enable_i;
          status_value(1) := apply_pending_i;
          status_value(2) := saturation_seen_i;

          case address_word is
            when 0 => rdata <= VERSION_VALUE;
            when 1 => rdata <= IDENTIFIER_VALUE;
            when 2 =>
              rdata <= (31 downto 2 => '0') & shadow_enable & '0';
            when 3 => rdata <= status_value;
            when 4 => rdata <= shadow_generation;
            when 5 => rdata <= x"000000" & shadow_valid_mask;
            when 6 to 13 => rdata <= shadow_scale(address_word - 6);
            when 14 => rdata <= active_generation_i;
            when 15 => rdata <= x"000000" & active_valid_mask_i;
            when 16 => rdata <= sample_sequence_i;
            when others => rdata <= (others => '0');
          end case;
          rvalid <= '1';
        end if;
      end if;
    end if;
  end process;
end architecture;
