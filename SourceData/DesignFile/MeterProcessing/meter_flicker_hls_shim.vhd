library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.metering_pkg.all;
use work.meter_r5_m18_pkg.all;

-- Nonblocking converted-frame observer for the M18 IEC flickermeter. The HLS
-- engine has no ownership of the acquisition ready path. A small elastic FIFO
-- absorbs its 2 kSPS filter work and every overflow is retained as a fault
-- counter; the next surviving sample-index gap invalidates the interval.
entity meter_flicker_hls_shim is
  port (
    aclk    : in std_logic;
    aresetn : in std_logic;

    frame_accept_i : in std_logic;
    frame_data_i   : in std_logic_vector(METER_CONVERTED_FRAME_BITS - 1 downto 0);
    frame_keep_i   : in std_logic_vector(METER_CONVERTED_KEEP_BITS - 1 downto 0);
    frame_user_i   : in std_logic_vector(383 downto 0);

    cycle_locked_i        : in std_logic;
    cycle_fallback_i      : in std_logic;
    nominal_hz_i          : in std_logic_vector(7 downto 0);
    shadow_sample_rate_i  : in std_logic_vector(31 downto 0);
    m18_shadow_words_i    : in m18_config_words_t;
    config_apply_toggle_i : in std_logic;

    m_axis_flk_tdata  : out std_logic_vector(31 downto 0);
    m_axis_flk_tkeep  : out std_logic_vector(3 downto 0);
    m_axis_flk_tvalid : out std_logic;
    m_axis_flk_tready : in std_logic;
    m_axis_flk_tlast  : out std_logic;

    drop_count_o : out std_logic_vector(31 downto 0)
  );
end entity;

architecture rtl of meter_flicker_hls_shim is
  constant IN_SAMPLES_LSB      : natural := 0;
  constant IN_FRAME_MASK_LSB   : natural := 384;
  constant IN_MALFORMED_BIT    : natural := 392;
  constant IN_APPLY_BIT        : natural := 393;
  constant IN_ENABLE_BIT       : natural := 394;
  constant IN_LOCKED_BIT       : natural := 395;
  constant IN_FALLBACK_BIT     : natural := 396;
  constant IN_GENERATION_LSB   : natural := 400;
  constant IN_SAMPLE_RATE_LSB  : natural := 432;
  constant IN_PHASE_MASK_LSB   : natural := 464;
  constant IN_LAMP_VOLTAGE_LSB : natural := 472;
  constant IN_NOMINAL_HZ_LSB   : natural := 488;
  constant IN_LIVE_MS_LSB      : natural := 496;
  constant IN_PST_SECONDS_LSB  : natural := 528;
  constant IN_REFERENCE_UV_LSB : natural := 560;
  constant IN_SAMPLE_INDEX_LSB : natural := 592;
  constant BEAT_BITS           : natural := 656;
  constant FIFO_DEPTH          : natural := 8;

  component hls_flicker_engine_ip is
    port (
      ap_clk         : in std_logic;
      ap_rst_n       : in std_logic;
      s_frame_TDATA  : in std_logic_vector(BEAT_BITS - 1 downto 0);
      s_frame_TVALID : in std_logic;
      s_frame_TREADY : out std_logic;
      m_flk_TDATA    : out std_logic_vector(31 downto 0);
      m_flk_TVALID   : out std_logic;
      m_flk_TREADY   : in std_logic;
      m_flk_TKEEP    : out std_logic_vector(3 downto 0);
      m_flk_TSTRB    : out std_logic_vector(3 downto 0);
      m_flk_TLAST    : out std_logic_vector(0 downto 0)
    );
  end component;

  type beat_array_t is array (0 to FIFO_DEPTH - 1) of
    std_logic_vector(BEAT_BITS - 1 downto 0);
  signal fifo_mem : beat_array_t;
  attribute ram_style : string;
  attribute ram_style of fifo_mem : signal is "distributed";

  signal wr_ptr     : natural range 0 to FIFO_DEPTH - 1 := 0;
  signal rd_ptr     : natural range 0 to FIFO_DEPTH - 1 := 0;
  signal fill_level : natural range 0 to FIFO_DEPTH := 0;
  signal drop_count : unsigned(31 downto 0) := (others => '0');
  signal head_valid : std_logic;
  signal in_ready   : std_logic;
  signal tlast_vec  : std_logic_vector(0 downto 0);
  signal tstrb_nc   : std_logic_vector(3 downto 0);

  signal staged_valid     : std_logic := '0';
  signal staged_data      : std_logic_vector(METER_CONVERTED_FRAME_BITS - 1 downto 0) := (others => '0');
  signal staged_mask      : std_logic_vector(7 downto 0) := (others => '0');
  signal staged_index     : std_logic_vector(63 downto 0) := (others => '0');
  signal staged_malformed : std_logic := '0';
begin
  core : hls_flicker_engine_ip
    port map (
      ap_clk => aclk,
      ap_rst_n => aresetn,
      s_frame_TDATA => fifo_mem(rd_ptr),
      s_frame_TVALID => head_valid,
      s_frame_TREADY => in_ready,
      m_flk_TDATA => m_axis_flk_tdata,
      m_flk_TVALID => m_axis_flk_tvalid,
      m_flk_TREADY => m_axis_flk_tready,
      m_flk_TKEEP => m_axis_flk_tkeep,
      m_flk_TSTRB => tstrb_nc,
      m_flk_TLAST => tlast_vec
    );

  m_axis_flk_tlast <= tlast_vec(0);
  head_valid <= '1' when fill_level /= 0 else '0';
  drop_count_o <= std_logic_vector(drop_count);

  process (aclk)
    variable beat    : std_logic_vector(BEAT_BITS - 1 downto 0);
    variable pushing : boolean;
    variable popping : boolean;
  begin
    if rising_edge(aclk) then
      if aresetn = '0' then
        wr_ptr <= 0;
        rd_ptr <= 0;
        fill_level <= 0;
        drop_count <= (others => '0');
        staged_valid <= '0';
      else
        popping := head_valid = '1' and in_ready = '1';
        pushing := false;

        if staged_valid = '1' then
          if fill_level = FIFO_DEPTH and not popping then
            if drop_count /= (drop_count'range => '1') then
              drop_count <= drop_count + 1;
            end if;
          else
            pushing := true;
            beat := (others => '0');
            beat(IN_SAMPLES_LSB + METER_CONVERTED_FRAME_BITS - 1 downto
                 IN_SAMPLES_LSB) := staged_data;
            beat(IN_FRAME_MASK_LSB + 7 downto IN_FRAME_MASK_LSB) :=
              staged_mask;
            beat(IN_MALFORMED_BIT) := staged_malformed;
            beat(IN_APPLY_BIT) := config_apply_toggle_i;
            beat(IN_ENABLE_BIT) :=
              m18_shadow_words_i(M18_CONFIG_FLICKER_FLAGS_WORD)
                (M18_ENGINE_ENABLED_BIT);
            beat(IN_LOCKED_BIT) := cycle_locked_i;
            beat(IN_FALLBACK_BIT) := cycle_fallback_i;
            beat(IN_GENERATION_LSB + 31 downto IN_GENERATION_LSB) :=
              m18_shadow_words_i(M18_CONFIG_GENERATION_WORD);
            beat(IN_SAMPLE_RATE_LSB + 31 downto IN_SAMPLE_RATE_LSB) :=
              shadow_sample_rate_i;
            beat(IN_PHASE_MASK_LSB + 7 downto IN_PHASE_MASK_LSB) :=
              m18_shadow_words_i(M18_CONFIG_FLICKER_PHASE_MASK_WORD)(7 downto 0);
            beat(IN_LAMP_VOLTAGE_LSB + 15 downto IN_LAMP_VOLTAGE_LSB) :=
              m18_shadow_words_i(M18_CONFIG_FLICKER_LAMP_WORD)(15 downto 0);
            beat(IN_NOMINAL_HZ_LSB + 7 downto IN_NOMINAL_HZ_LSB) :=
              nominal_hz_i;
            beat(IN_LIVE_MS_LSB + 31 downto IN_LIVE_MS_LSB) :=
              m18_shadow_words_i(M18_CONFIG_FLICKER_LIVE_MS_WORD);
            beat(IN_PST_SECONDS_LSB + 31 downto IN_PST_SECONDS_LSB) :=
              m18_shadow_words_i(M18_CONFIG_FLICKER_PST_SECONDS_WORD);
            beat(IN_REFERENCE_UV_LSB + 31 downto IN_REFERENCE_UV_LSB) :=
              m18_shadow_words_i(M18_CONFIG_REFERENCE_VOLTAGE_WORD);
            beat(IN_SAMPLE_INDEX_LSB + 63 downto IN_SAMPLE_INDEX_LSB) :=
              staged_index;
            fifo_mem(wr_ptr) <= beat;
            if wr_ptr = FIFO_DEPTH - 1 then
              wr_ptr <= 0;
            else
              wr_ptr <= wr_ptr + 1;
            end if;
          end if;
          staged_valid <= '0';
        end if;

        if frame_accept_i = '1' then
          staged_valid <= '1';
          staged_data <= frame_data_i;
          staged_mask <= frame_user_i(71 downto 64);
          staged_index <= frame_user_i(105 downto 74) &
                          frame_user_i(31 downto 0);
          if frame_keep_i /= (frame_keep_i'range => '1') then
            staged_malformed <= '1';
          else
            staged_malformed <= '0';
          end if;
        end if;

        if popping then
          if rd_ptr = FIFO_DEPTH - 1 then
            rd_ptr <= 0;
          else
            rd_ptr <= rd_ptr + 1;
          end if;
        end if;
        if pushing and not popping then
          fill_level <= fill_level + 1;
        elsif popping and not pushing then
          fill_level <= fill_level - 1;
        end if;
      end if;
    end if;
  end process;
end architecture;
