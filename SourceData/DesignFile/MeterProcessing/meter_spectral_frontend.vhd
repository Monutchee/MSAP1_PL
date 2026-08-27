-- SPDX-License-Identifier: MIT
--
-- M16 spectral window buffer and channel scheduler.
--
-- The upstream conditioner delivers exactly FFT_LENGTH simultaneous
-- seven-channel frames for every grid-synchronous 10/12-cycle basic block.
-- It presents one context beat before the first frame and asserts TLAST on
-- frame FFT_LENGTH-1.  This observer never backpressures sample data: when
-- both banks are occupied it consumes and discards the complete window, then
-- reports the loss through dropped_windows.
--
-- A completed bank is serialized CH0..CH6 into one real-valued complex frame
-- per channel.  The context beat is emitted before those seven frames.  The
-- intended downstream chain is:
--
--   meter_spectral_frontend -> AMD/Xilinx XFFT -> hls_harmonic_engine
--                  context --------------------> hls_harmonic_engine

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library xpm;
use xpm.vcomponents.all;

entity meter_spectral_frontend is
  generic (
    CHANNELS     : integer := 7;
    SAMPLE_WIDTH : integer := 24;
    FFT_LENGTH   : integer := 4096;
    CONTEXT_BITS : integer := 576;
    -- Production retains the XPM URAM implementation.  The behavioral
    -- alternative exists only for small, vendor-library-free testbenches.
    USE_XPM      : boolean := true
  );
  port (
    aclk    : in std_logic;
    aresetn : in std_logic;
    config_apply_toggle_i : in std_logic;

    s_axis_context_tdata  : in  std_logic_vector(CONTEXT_BITS-1 downto 0);
    s_axis_context_tvalid : in  std_logic;
    s_axis_context_tready : out std_logic;

    s_axis_frame_tdata  : in  std_logic_vector(CHANNELS*SAMPLE_WIDTH-1 downto 0);
    s_axis_frame_tvalid : in  std_logic;
    s_axis_frame_tready : out std_logic;
    s_axis_frame_tlast  : in  std_logic;
    -- A conditioner/profile/geometry fault invalidates the complete bank,
    -- even when its AXIS frame count and TLAST are otherwise correct.
    s_axis_frame_fault  : in  std_logic;

    m_axis_context_tdata  : out std_logic_vector(CONTEXT_BITS-1 downto 0);
    m_axis_context_tvalid : out std_logic;
    m_axis_context_tready : in  std_logic;

    m_axis_fft_tdata  : out std_logic_vector(2*SAMPLE_WIDTH-1 downto 0);
    m_axis_fft_tvalid : out std_logic;
    m_axis_fft_tready : in  std_logic;
    m_axis_fft_tlast  : out std_logic;

    busy              : out std_logic;
    completed_windows : out std_logic_vector(31 downto 0);
    dropped_windows   : out std_logic_vector(31 downto 0);
    malformed_windows : out std_logic_vector(31 downto 0)
  );
end entity;

architecture rtl of meter_spectral_frontend is
  function ceiling_log2(value : natural) return positive is
    variable remaining : natural := value - 1;
    variable result    : natural := 0;
  begin
    while remaining > 0 loop
      remaining := remaining / 2;
      result := result + 1;
    end loop;
    if result = 0 then
      return 1;
    end if;
    return result;
  end function;

  function is_power_of_two(value : natural) return boolean is
    variable remaining : natural := value;
  begin
    if remaining < 2 then
      return false;
    end if;
    while remaining > 1 loop
      if remaining mod 2 /= 0 then
        return false;
      end if;
      remaining := remaining / 2;
    end loop;
    return true;
  end function;

  function bank_number(value : std_logic) return natural is
  begin
    if value = '1' then
      return 1;
    end if;
    return 0;
  end function;

  constant C_FRAME_WIDTH : positive := CHANNELS * SAMPLE_WIDTH;
  constant C_ADDR_WIDTH  : positive := ceiling_log2(FFT_LENGTH);
  constant C_CH_WIDTH    : positive := ceiling_log2(CHANNELS);
  constant C_CONTEXT_RESULT_DROPS_LSB : natural := 288;
  constant C_U32_MAX : unsigned(31 downto 0) := (others => '1');

  type scheduler_state_t is (
    S_IDLE,
    S_CONTEXT,
    S_READ,
    S_WAIT_1,
    S_WAIT_2,
    S_SEND
  );
  type context_bank_array_t is array (0 to 1) of
    std_logic_vector(CONTEXT_BITS-1 downto 0);
  type frame_bank_array_t is array (0 to 1) of
    std_logic_vector(C_FRAME_WIDTH-1 downto 0);

  signal context_bank : context_bank_array_t;
  signal bank_data    : frame_bank_array_t;
  signal bank_ready   : std_logic_vector(1 downto 0) := (others => '0');
  signal bank_preference : std_logic := '0';

  signal capture_active        : std_logic := '0';
  signal capture_bank          : std_logic := '0';
  signal capture_discard       : std_logic := '0';
  signal capture_framing_fault : std_logic := '0';
  signal capture_index         : unsigned(C_ADDR_WIDTH-1 downto 0) :=
    (others => '0');
  signal apply_seen            : std_logic := '0';

  signal scheduler_state : scheduler_state_t := S_IDLE;
  signal active_bank     : std_logic := '0';
  signal channel_index   : unsigned(C_CH_WIDTH-1 downto 0) :=
    (others => '0');
  signal fft_index       : unsigned(C_ADDR_WIDTH-1 downto 0) :=
    (others => '0');

  signal context_fire   : std_logic;
  signal frame_fire     : std_logic;
  signal read_enable    : std_logic;
  signal release_bank_now : std_logic;
  signal bank_0_available : std_logic;
  signal bank_1_available : std_logic;
  signal selected_bank           : std_logic;
  signal selected_bank_available : std_logic;
  signal context_with_drops : std_logic_vector(CONTEXT_BITS-1 downto 0);
  signal window_active    : std_logic;
  signal effective_bank   : std_logic;
  signal effective_discard: std_logic;
  signal effective_fault  : std_logic;
  signal effective_index  : unsigned(C_ADDR_WIDTH-1 downto 0);
  signal expected_last    : std_logic;
  signal memory_write_enable : std_logic;
  signal bank_write_enable : std_logic_vector(1 downto 0);
  signal bank_read_enable  : std_logic_vector(1 downto 0);

  signal context_data_reg  : std_logic_vector(CONTEXT_BITS-1 downto 0) :=
    (others => '0');
  signal context_valid_reg : std_logic := '0';
  signal fft_data_reg      : std_logic_vector(2*SAMPLE_WIDTH-1 downto 0) :=
    (others => '0');
  signal fft_valid_reg     : std_logic := '0';
  signal fft_last_reg      : std_logic := '0';
  signal completed_windows_reg : unsigned(31 downto 0) := (others => '0');
  signal dropped_windows_reg   : unsigned(31 downto 0) := (others => '0');
  signal malformed_windows_reg : unsigned(31 downto 0) := (others => '0');
begin
  assert CHANNELS >= 1 and CHANNELS <= 8
    report "meter_spectral_frontend CHANNELS must be 1..8"
    severity failure;
  assert SAMPLE_WIDTH >= 1
    report "meter_spectral_frontend SAMPLE_WIDTH must be positive"
    severity failure;
  assert is_power_of_two(FFT_LENGTH)
    report "meter_spectral_frontend FFT_LENGTH must be a power of two"
    severity failure;
  assert CONTEXT_BITS >= 320
    report "meter_spectral_frontend context is too narrow"
    severity failure;

  m_axis_context_tdata  <= context_data_reg;
  m_axis_context_tvalid <= context_valid_reg;
  m_axis_fft_tdata       <= fft_data_reg;
  m_axis_fft_tvalid      <= fft_valid_reg;
  m_axis_fft_tlast       <= fft_last_reg;
  completed_windows <= std_logic_vector(completed_windows_reg);
  dropped_windows   <= std_logic_vector(dropped_windows_reg);
  malformed_windows <= std_logic_vector(malformed_windows_reg);

  -- Context producers may wait between windows.  Sample data is an observer
  -- branch and is therefore always consumed, even if it must be discarded.
  s_axis_context_tready <= '1' when capture_active = '0' and
                                   config_apply_toggle_i = apply_seen
                           else '0';
  s_axis_frame_tready <= '1';
  context_fire <= s_axis_context_tvalid and s_axis_context_tready;
  frame_fire <= s_axis_frame_tvalid;
  read_enable <= '1' when scheduler_state = S_READ else '0';

  -- A bank completing its final output transfer is reusable on this edge.
  release_bank_now <= '1' when scheduler_state = S_SEND and
                              fft_valid_reg = '1' and
                              m_axis_fft_tready = '1' and
                              to_integer(fft_index) = FFT_LENGTH-1 and
                              to_integer(channel_index) = CHANNELS-1
                      else '0';
  bank_0_available <= '1' when bank_ready(0) = '0' or
                              (release_bank_now = '1' and active_bank = '0')
                      else '0';
  bank_1_available <= '1' when bank_ready(1) = '0' or
                              (release_bank_now = '1' and active_bank = '1')
                      else '0';

  select_capture_bank : process(all)
  begin
    selected_bank <= bank_preference;
    if bank_preference = '0' then
      if bank_0_available = '1' then
        selected_bank <= '0';
      elsif bank_1_available = '1' then
        selected_bank <= '1';
      end if;
    else
      if bank_1_available = '1' then
        selected_bank <= '1';
      elsif bank_0_available = '1' then
        selected_bank <= '0';
      end if;
    end if;
  end process;

  selected_bank_available <= bank_1_available when selected_bank = '1'
                             else bank_0_available;

  stamp_drop_snapshot : process(all)
    variable context_value : std_logic_vector(CONTEXT_BITS-1 downto 0);
  begin
    context_value := s_axis_context_tdata;
    context_value(C_CONTEXT_RESULT_DROPS_LSB+31 downto
                  C_CONTEXT_RESULT_DROPS_LSB) :=
      std_logic_vector(dropped_windows_reg);
    context_with_drops <= context_value;
  end process;

  window_active <= capture_active or context_fire;
  effective_bank <= capture_bank when capture_active = '1' else selected_bank;
  effective_discard <= capture_discard when capture_active = '1' else
                       not selected_bank_available;
  effective_fault <= (capture_framing_fault and capture_active) or
                     s_axis_frame_fault;
  effective_index <= capture_index when capture_active = '1' else
                     (others => '0');
  expected_last <= '1' when to_integer(effective_index) = FFT_LENGTH-1
                   else '0';
  memory_write_enable <= '1' when aresetn = '1' and
                                 config_apply_toggle_i = apply_seen and
                                 frame_fire = '1' and window_active = '1' and
                                 effective_discard = '0' and
                                 effective_fault = '0'
                         else '0';

  busy <= '1' when capture_active = '1' or bank_ready /= "00" or
                   scheduler_state /= S_IDLE
          else '0';

  bank_write_enable(0) <= memory_write_enable when effective_bank = '0'
                          else '0';
  bank_write_enable(1) <= memory_write_enable when effective_bank = '1'
                          else '0';
  bank_read_enable(0) <= read_enable when active_bank = '0' else '0';
  bank_read_enable(1) <= read_enable when active_bank = '1' else '0';

  g_xpm_banks : if USE_XPM generate
    g_window_bank : for bank in 0 to 1 generate
      window_bank_i : xpm_memory_sdpram
        generic map (
          MEMORY_SIZE         => FFT_LENGTH * C_FRAME_WIDTH,
          MEMORY_PRIMITIVE    => "ultra",
          CLOCKING_MODE       => "common_clock",
          ECC_MODE            => "no_ecc",
          MEMORY_INIT_FILE    => "none",
          MEMORY_INIT_PARAM   => "",
          USE_MEM_INIT        => 0,
          WAKEUP_TIME         => "disable_sleep",
          AUTO_SLEEP_TIME     => 0,
          MESSAGE_CONTROL     => 0,
          MEMORY_OPTIMIZATION => "true",
          CASCADE_HEIGHT      => 0,
          SIM_ASSERT_CHK      => 1,
          WRITE_DATA_WIDTH_A  => C_FRAME_WIDTH,
          BYTE_WRITE_WIDTH_A  => C_FRAME_WIDTH,
          ADDR_WIDTH_A        => C_ADDR_WIDTH,
          READ_DATA_WIDTH_B   => C_FRAME_WIDTH,
          ADDR_WIDTH_B        => C_ADDR_WIDTH,
          READ_RESET_VALUE_B  => "0",
          READ_LATENCY_B      => 2,
          WRITE_MODE_B        => "read_first",
          RST_MODE_B          => "SYNC"
        )
        port map (
          sleep          => '0',
          clka           => aclk,
          ena            => bank_write_enable(bank),
          wea            => (others => '1'),
          addra          => std_logic_vector(effective_index),
          dina           => s_axis_frame_tdata,
          injectsbiterra => '0',
          injectdbiterra => '0',
          clkb           => aclk,
          rstb           => not aresetn,
          enb            => bank_read_enable(bank),
          regceb         => '1',
          addrb          => std_logic_vector(fft_index),
          doutb          => bank_data(bank),
          sbiterrb       => open,
          dbiterrb       => open
        );
    end generate;
  end generate;

  g_behavioral_banks : if not USE_XPM generate
    type window_memory_t is array (0 to FFT_LENGTH-1) of
      std_logic_vector(C_FRAME_WIDTH-1 downto 0);
    signal window_bank_0 : window_memory_t;
    signal window_bank_1 : window_memory_t;
    signal read_stage    : frame_bank_array_t;
  begin
    behavioral_memory : process(aclk)
    begin
      if rising_edge(aclk) then
        if memory_write_enable = '1' then
          if effective_bank = '0' then
            window_bank_0(to_integer(effective_index)) <= s_axis_frame_tdata;
          else
            window_bank_1(to_integer(effective_index)) <= s_axis_frame_tdata;
          end if;
        end if;
        if read_enable = '1' then
          read_stage(0) <= window_bank_0(to_integer(fft_index));
          read_stage(1) <= window_bank_1(to_integer(fft_index));
        end if;
        bank_data(0) <= read_stage(0);
        bank_data(1) <= read_stage(1);
      end if;
    end process;
  end generate;

  capture_and_schedule : process(aclk)
    variable fft_word  : std_logic_vector(2*SAMPLE_WIDTH-1 downto 0);
    variable sample_lsb: natural;
  begin
    if rising_edge(aclk) then
      if aresetn = '0' then
        bank_ready             <= (others => '0');
        bank_preference        <= '0';
        capture_active         <= '0';
        capture_bank           <= '0';
        capture_discard        <= '0';
        capture_framing_fault  <= '0';
        capture_index          <= (others => '0');
        apply_seen             <= '0';
        scheduler_state        <= S_IDLE;
        active_bank            <= '0';
        channel_index          <= (others => '0');
        fft_index              <= (others => '0');
        context_data_reg       <= (others => '0');
        context_valid_reg      <= '0';
        fft_data_reg           <= (others => '0');
        fft_valid_reg          <= '0';
        fft_last_reg           <= '0';
        completed_windows_reg  <= (others => '0');
        dropped_windows_reg    <= (others => '0');
        malformed_windows_reg  <= (others => '0');
      else
        if config_apply_toggle_i /= apply_seen then
          -- APPLY aborts only an incomplete capture.  Complete banks retain
          -- their original context and continue through XFFT/HLS.
          apply_seen            <= config_apply_toggle_i;
          capture_active        <= '0';
          capture_discard       <= '0';
          capture_framing_fault <= '0';
          capture_index         <= (others => '0');
        else
          -- Reserve a bank with the context.  If neither bank is free, the
          -- following window is consumed but deliberately dropped.
          if context_fire = '1' then
            capture_active        <= '1';
            capture_bank          <= selected_bank;
            capture_discard       <= not selected_bank_available;
            capture_framing_fault <= '0';
            capture_index         <= (others => '0');
            if selected_bank_available = '1' then
              context_bank(bank_number(selected_bank)) <= context_with_drops;
              bank_preference <= not selected_bank;
            elsif dropped_windows_reg /= C_U32_MAX then
              dropped_windows_reg <= dropped_windows_reg + 1;
            end if;
          end if;

          if frame_fire = '1' then
            if capture_active = '1' or context_fire = '1' then
              if effective_discard = '1' then
                if s_axis_frame_tlast = '1' then
                  capture_active <= '0';
                end if;
              elsif s_axis_frame_fault = '1' then
                -- An explicit upstream fault has whole-window scope.  Count
                -- it once and consume through TLAST to regain alignment.
                if capture_framing_fault = '0' and
                   malformed_windows_reg /= C_U32_MAX then
                  malformed_windows_reg <= malformed_windows_reg + 1;
                end if;
                if s_axis_frame_tlast = '1' then
                  capture_active <= '0';
                else
                  capture_active        <= '1';
                  capture_framing_fault <= '1';
                end if;
              elsif effective_fault = '1' then
                -- A missing expected TLAST already invalidated this block.
                -- Consume through the eventual TLAST without double-counting.
                if s_axis_frame_tlast = '1' then
                  capture_active <= '0';
                end if;
              elsif s_axis_frame_tlast /= expected_last then
                if malformed_windows_reg /= C_U32_MAX then
                  malformed_windows_reg <= malformed_windows_reg + 1;
                end if;
                if s_axis_frame_tlast = '1' then
                  capture_active <= '0';
                else
                  capture_active        <= '1';
                  capture_framing_fault <= '1';
                end if;
              elsif expected_last = '1' then
                bank_ready(bank_number(effective_bank)) <= '1';
                capture_active <= '0';
              else
                capture_index <= effective_index + 1;
              end if;
            elsif s_axis_frame_tlast = '1' then
              if malformed_windows_reg /= C_U32_MAX then
                malformed_windows_reg <= malformed_windows_reg + 1;
              end if;
            end if;
          end if;
        end if;

        case scheduler_state is
          when S_IDLE =>
            context_valid_reg <= '0';
            fft_valid_reg <= '0';
            fft_last_reg <= '0';
            if bank_ready(0) = '1' then
              active_bank <= '0';
              context_data_reg <= context_bank(0);
              context_valid_reg <= '1';
              scheduler_state <= S_CONTEXT;
            elsif bank_ready(1) = '1' then
              active_bank <= '1';
              context_data_reg <= context_bank(1);
              context_valid_reg <= '1';
              scheduler_state <= S_CONTEXT;
            end if;

          when S_CONTEXT =>
            if context_valid_reg = '1' and m_axis_context_tready = '1' then
              context_valid_reg <= '0';
              channel_index <= (others => '0');
              fft_index <= (others => '0');
              scheduler_state <= S_READ;
            end if;

          when S_READ =>
            scheduler_state <= S_WAIT_1;

          when S_WAIT_1 =>
            scheduler_state <= S_WAIT_2;

          when S_WAIT_2 =>
            scheduler_state <= S_SEND;

          when S_SEND =>
            if fft_valid_reg = '0' then
              fft_word := (others => '0');
              sample_lsb := to_integer(channel_index) * SAMPLE_WIDTH;
              fft_word(SAMPLE_WIDTH-1 downto 0) :=
                bank_data(bank_number(active_bank))(
                  sample_lsb+SAMPLE_WIDTH-1 downto sample_lsb);
              fft_data_reg <= fft_word;
              if to_integer(fft_index) = FFT_LENGTH-1 then
                fft_last_reg <= '1';
              else
                fft_last_reg <= '0';
              end if;
              fft_valid_reg <= '1';
            elsif m_axis_fft_tready = '1' then
              fft_valid_reg <= '0';
              if to_integer(fft_index) = FFT_LENGTH-1 then
                if to_integer(channel_index) = CHANNELS-1 then
                  bank_ready(bank_number(active_bank)) <= '0';
                  if completed_windows_reg /= C_U32_MAX then
                    completed_windows_reg <= completed_windows_reg + 1;
                  end if;
                  scheduler_state <= S_IDLE;
                else
                  channel_index <= channel_index + 1;
                  fft_index <= (others => '0');
                  scheduler_state <= S_READ;
                end if;
              else
                fft_index <= fft_index + 1;
                scheduler_state <= S_READ;
              end if;
            end if;

          when others =>
            scheduler_state <= S_IDLE;
        end case;
      end if;
    end if;
  end process;
end architecture;
