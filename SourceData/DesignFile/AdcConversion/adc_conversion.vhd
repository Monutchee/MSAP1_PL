library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.metering_pkg.all;

entity adc_conversion is
  port (
    aclk             : in  std_logic;
    aresetn          : in  std_logic;

    s_axis_tdata     : in  word32_t;
    s_axis_tkeep     : in  std_logic_vector(3 downto 0);
    s_axis_tvalid    : in  std_logic;
    s_axis_tready    : out std_logic;
    s_axis_tlast     : in  std_logic;

    m_axis_tdata     : out std_logic_vector(511 downto 0);
    m_axis_tkeep     : out std_logic_vector(63 downto 0);
    m_axis_tuser     : out std_logic_vector(383 downto 0);
    m_axis_tvalid    : out std_logic;
    m_axis_tready    : in  std_logic;
    m_axis_tlast     : out std_logic;

    s_axi_awaddr     : in  std_logic_vector(7 downto 0);
    s_axi_awvalid    : in  std_logic;
    s_axi_awready    : out std_logic;
    s_axi_wdata      : in  word32_t;
    s_axi_wstrb      : in  std_logic_vector(3 downto 0);
    s_axi_wvalid     : in  std_logic;
    s_axi_wready     : out std_logic;
    s_axi_bresp      : out std_logic_vector(1 downto 0);
    s_axi_bvalid     : out std_logic;
    s_axi_bready     : in  std_logic;
    s_axi_araddr     : in  std_logic_vector(7 downto 0);
    s_axi_arvalid    : in  std_logic;
    s_axi_arready    : out std_logic;
    s_axi_rdata      : out word32_t;
    s_axi_rresp      : out std_logic_vector(1 downto 0);
    s_axi_rvalid     : out std_logic;
    s_axi_rready     : in  std_logic
  );
end entity;

architecture rtl of adc_conversion is
  signal shadow_generation : word32_t;
  signal shadow_valid_mask : std_logic_vector(7 downto 0);
  signal shadow_enable     : std_logic;
  signal shadow_scale_flat : std_logic_vector(255 downto 0);
  signal apply_toggle      : std_logic;

  signal active_generation : word32_t := (others => '0');
  signal active_valid_mask : std_logic_vector(7 downto 0) := (others => '0');
  signal active_enable     : std_logic := '0';
  signal active_scale      : word32_array_t(0 to 7) := (others => (others => '0'));
  signal apply_seen        : std_logic := '0';

  signal channel_index     : natural range 0 to 7 := 0;
  signal frame_buffer      : std_logic_vector(511 downto 0) := (others => '0');
  signal raw_frame_buffer  : std_logic_vector(255 downto 0) := (others => '0');
  signal output_data       : std_logic_vector(511 downto 0) := (others => '0');
  signal output_user       : std_logic_vector(383 downto 0) := (others => '0');
  signal output_valid      : std_logic := '0';
  signal sample_sequence   : unsigned(31 downto 0) := (others => '0');
  signal saturation_seen   : std_logic := '0';
  signal apply_waiting     : std_logic;
  signal can_accept        : std_logic;
begin
  register_bank : entity work.adc_conversion_axi_regs
    port map (
      aclk => aclk,
      aresetn => aresetn,
      s_axi_awaddr => s_axi_awaddr,
      s_axi_awvalid => s_axi_awvalid,
      s_axi_awready => s_axi_awready,
      s_axi_wdata => s_axi_wdata,
      s_axi_wstrb => s_axi_wstrb,
      s_axi_wvalid => s_axi_wvalid,
      s_axi_wready => s_axi_wready,
      s_axi_bresp => s_axi_bresp,
      s_axi_bvalid => s_axi_bvalid,
      s_axi_bready => s_axi_bready,
      s_axi_araddr => s_axi_araddr,
      s_axi_arvalid => s_axi_arvalid,
      s_axi_arready => s_axi_arready,
      s_axi_rdata => s_axi_rdata,
      s_axi_rresp => s_axi_rresp,
      s_axi_rvalid => s_axi_rvalid,
      s_axi_rready => s_axi_rready,
      shadow_generation_o => shadow_generation,
      shadow_valid_mask_o => shadow_valid_mask,
      shadow_enable_o => shadow_enable,
      shadow_scale_q16_o => shadow_scale_flat,
      apply_toggle_o => apply_toggle,
      active_generation_i => active_generation,
      active_valid_mask_i => active_valid_mask,
      active_enable_i => active_enable,
      apply_pending_i => apply_waiting,
      saturation_seen_i => saturation_seen,
      sample_sequence_i => std_logic_vector(sample_sequence)
    );

  apply_waiting <= apply_toggle xor apply_seen;
  can_accept <= '1' when output_valid = '0' or m_axis_tready = '1' else '0';
  s_axis_tready <= can_accept when not (apply_waiting = '1' and channel_index = 0) else '0';

  m_axis_tdata <= output_data;
  m_axis_tkeep <= (others => '1');
  m_axis_tuser <= output_user;
  m_axis_tvalid <= output_valid;
  m_axis_tlast <= '1';

  process (aclk)
    variable raw_value       : signed(32 downto 0);
    variable scale_value     : signed(32 downto 0);
    variable product_value   : signed(65 downto 0);
    variable converted_value : sword64_t;
    variable next_frame      : std_logic_vector(511 downto 0);
    variable next_raw_frame  : std_logic_vector(255 downto 0);
    variable next_user       : std_logic_vector(383 downto 0);
    variable next_sequence   : unsigned(31 downto 0);
    variable saturated       : std_logic;
  begin
    if rising_edge(aclk) then
      if aresetn = '0' then
        active_generation <= (others => '0');
        active_valid_mask <= (others => '0');
        active_enable <= '0';
        active_scale <= (others => (others => '0'));
        apply_seen <= '0';
        channel_index <= 0;
        frame_buffer <= (others => '0');
        raw_frame_buffer <= (others => '0');
        output_data <= (others => '0');
        output_user <= (others => '0');
        output_valid <= '0';
        sample_sequence <= (others => '0');
        saturation_seen <= '0';
      else
        if output_valid = '1' and m_axis_tready = '1' then
          output_valid <= '0';
        end if;

        if apply_waiting = '1' and channel_index = 0 then
          active_generation <= shadow_generation;
          active_valid_mask <= shadow_valid_mask;
          active_enable <= shadow_enable;
          for index in 0 to 7 loop
            active_scale(index) <= shadow_scale_flat((index * 32) + 31 downto index * 32);
          end loop;
          apply_seen <= apply_toggle;
          frame_buffer <= (others => '0');
          raw_frame_buffer <= (others => '0');
          saturation_seen <= '0';
        elsif s_axis_tvalid = '1' and s_axis_tready = '1' then
          raw_value := resize(signed(s_axis_tdata), raw_value'length);
          scale_value := signed('0' & active_scale(channel_index));
          product_value := raw_value * scale_value;
          converted_value := saturate_signed_66_to_64(product_value);

          saturated := '0';
          if product_value(65 downto 63) /= "000" and
             product_value(65 downto 63) /= "111" then
            saturated := '1';
            saturation_seen <= '1';
          end if;

          if active_enable = '0' or active_valid_mask(channel_index) = '0' or
             s_axis_tkeep /= "1111" then
            converted_value := (others => '0');
          end if;

          next_frame := frame_buffer;
          next_raw_frame := raw_frame_buffer;
          next_frame((channel_index * 64) + 63 downto channel_index * 64) :=
            std_logic_vector(converted_value);
          next_raw_frame((channel_index * 32) + 31 downto channel_index * 32) :=
            s_axis_tdata;
          frame_buffer <= next_frame;
          raw_frame_buffer <= next_raw_frame;

          if channel_index = 7 then
            next_sequence := sample_sequence + 1;
            next_user := (others => '0');
            next_user(31 downto 0) := std_logic_vector(next_sequence);
            next_user(63 downto 32) := active_generation;
            next_user(71 downto 64) := active_valid_mask when active_enable = '1' else x"00";
            next_user(72) := saturation_seen or saturated;
            next_user(73) := s_axis_tlast;
            next_user(383 downto 128) := next_raw_frame;
            output_data <= next_frame;
            output_user <= next_user;
            output_valid <= '1';
            sample_sequence <= next_sequence;
            channel_index <= 0;
          else
            channel_index <= channel_index + 1;
          end if;
        end if;
      end if;
    end if;
  end process;
end architecture;
