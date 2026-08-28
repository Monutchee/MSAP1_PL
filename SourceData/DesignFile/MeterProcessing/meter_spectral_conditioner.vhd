-- SPDX-License-Identifier: MIT
--
-- M16 streaming anti-alias/rational conditioner.
--
-- Every supported ADC rate (1, 2, 4, 8, 16, 32, 64, or 128 kframe/s) is
-- converted to 20.48 kframe/s with an exact L/25 rational profile, where
-- L=512000/Fs.  A grid-synchronous 200 ms source block therefore always
-- becomes exactly 4,096 simultaneous seven-channel samples for the external
-- 4K XFFT.
--
-- Source capture is independent of the time-shared MAC.  A block-RAM history
-- ring and a 16-entry source-token queue preserve every accepted ADC frame
-- while one multiplier evaluates the active phase over all seven lanes.  The
-- worst profile (128 kSPS, 257 taps) takes about 3,600 clocks per output,
-- below the 4,883-clock average output interval at 99.999 MHz.
--
-- Profiles 32/64/128 kSPS share a 1,025-tap Kaiser prototype on the 512 kHz
-- interpolation grid.  Profiles 1..16 kSPS interpolate a compact 129-row,
-- 69-tap fractional-delay table and qualify orders only through 0.4 Fs.  A
-- carried remainder preserves exact Q20 unity gain for every fine phase.
-- Three signed Q20 coefficients are packed into each 63-bit ROM word.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library xpm;
use xpm.vcomponents.all;

entity meter_spectral_conditioner is
  generic (
    CHANNELS               : positive := 7;
    SAMPLE_WIDTH           : positive := 24;
    CONTEXT_BITS           : positive := 576;
    EXPECTED_SOURCE_FRAMES : positive := 6400;
    OUTPUT_FRAMES          : positive := 4096;
    SOURCE_RATE_HZ         : positive := 32000;
    COEFFICIENT_MEMORY_PRIMITIVE : string := "block";
    HISTORY_MEMORY_PRIMITIVE     : string := "block"
  );
  port (
    aclk    : in std_logic;
    aresetn : in std_logic;

    frame_accept_i       : in std_logic;
    raw_frame_i          : in std_logic_vector(255 downto 0);
    frame_user_i         : in std_logic_vector(383 downto 0);
    frame_closes_block_i : in std_logic;

    grid_locked_i            : in std_logic;
    grid_nominal_hz_i         : in std_logic_vector(7 downto 0);
    grid_cycle_count_i        : in std_logic_vector(7 downto 0);
    config_enable_i           : in std_logic;
    config_apply_toggle_i     : in std_logic;
    configured_frame_rate_i   : in std_logic_vector(31 downto 0);
    source_frame_rate_i       : in std_logic_vector(31 downto 0);
    source_frame_rate_valid_i : in std_logic;
    frequency_millihz_i       : in std_logic_vector(31 downto 0);
    frequency_valid_i         : in std_logic;
    active_scale_q16_i        : in std_logic_vector(255 downto 0);
    emit_drops_i              : in std_logic_vector(31 downto 0);

    m_axis_context_tdata  : out std_logic_vector(CONTEXT_BITS-1 downto 0);
    m_axis_context_tvalid : out std_logic;
    m_axis_context_tready : in  std_logic;

    m_axis_frame_tdata  : out std_logic_vector(CHANNELS*SAMPLE_WIDTH-1 downto 0);
    m_axis_frame_tvalid : out std_logic;
    m_axis_frame_tready : in  std_logic;
    m_axis_frame_tlast  : out std_logic;
    m_axis_frame_fault  : out std_logic;

    completed_blocks_o : out std_logic_vector(31 downto 0);
    invalid_blocks_o   : out std_logic_vector(31 downto 0);
    service_overruns_o : out std_logic_vector(31 downto 0)
  );
end entity;

architecture rtl of meter_spectral_conditioner is
  constant C_RATE_DENOMINATOR : positive := 25;
  constant C_MAX_DELAY        : positive := 128;
  constant C_HISTORY_DEPTH    : positive := 512;
  constant C_HISTORY_ADDR_BITS: positive := 9;
  constant C_TOKEN_DEPTH      : positive := 16;
  constant C_TOKEN_ADDR_BITS  : positive := 4;
  constant C_FRAME_WIDTH      : positive := CHANNELS * SAMPLE_WIDTH;

  constant C_COEFFICIENT_BITS : positive := 21;
  constant C_COEFFICIENT_FRAC : positive := 20;
  constant C_ROM_WORD_BITS    : positive := 63;
  constant C_ROM_WORDS        : positive := 4007;
  constant C_ROM_ADDR_BITS    : positive := 12;

  -- Packed coefficient-ROM geometry.  The low-rate table has 129 endpoint-
  -- inclusive base phases x 23 words.  High-rate rows are padded to 66, 129,
  -- and 258 coefficients.
  constant C_LOW_BASE_WORD    : natural := 0;
  constant C_LOW_FINE_PHASES  : positive := 512;
  constant C_LOW_BASE_INTERVALS : positive := 128;
  constant C_LOW_FINE_PER_BASE  : positive :=
    C_LOW_FINE_PHASES / C_LOW_BASE_INTERVALS;
  constant C_LOW_WORDS_PHASE  : positive := 23;
  constant C_32K_BASE_WORD    : natural := 2967;
  constant C_32K_WORDS_PHASE  : positive := 22;
  constant C_64K_BASE_WORD    : natural := 3319;
  constant C_64K_WORDS_PHASE  : positive := 43;
  constant C_128K_BASE_WORD   : natural := 3663;
  constant C_128K_WORDS_PHASE : positive := 86;

  constant C_U32_MAX : unsigned(31 downto 0) := (others => '1');

  -- A continuous crossing is represented by one accepted ADC frame.  At an
  -- otherwise exact nominal 10/12-cycle boundary, interpolation and input
  -- noise may therefore select either adjacent frame.  The resampling lattice
  -- remains the exact profile L/25 lattice; this tolerance normalizes only
  -- that discrete endpoint choice and is not a general geometry allowance.
  constant C_ENDPOINT_QUANTIZATION_FRAMES : natural := 1;

  subtype u32_t is unsigned(31 downto 0);
  subtype history_pointer_t is unsigned(C_HISTORY_ADDR_BITS-1 downto 0);

  type state_t is (
    S_IDLE,
    S_DECIDE,
    S_CONTEXT_WAIT,
    S_OUTPUT_CHECK,
    S_PREFETCH,
    S_LOAD,
    S_INTERP_WAIT,
    S_INTERP_LOAD,
    S_MAC,
    S_COMMIT,
    S_STORE,
    S_CLOSE
  );
  signal state : state_t;

  type token_pointer_array_t is array (0 to C_TOKEN_DEPTH-1) of
    history_pointer_t;
  type token_flag_array_t is array (0 to C_TOKEN_DEPTH-1) of std_logic;
  signal token_pointer_fifo : token_pointer_array_t;
  signal token_start_fifo   : token_flag_array_t;
  signal token_close_fifo   : token_flag_array_t;
  signal token_write_pointer: unsigned(C_TOKEN_ADDR_BITS-1 downto 0);
  signal token_read_pointer : unsigned(C_TOKEN_ADDR_BITS-1 downto 0);
  signal token_count        : unsigned(C_TOKEN_ADDR_BITS downto 0);

  signal current_pointer       : history_pointer_t;
  signal current_delayed_start : std_logic;
  signal current_delayed_close : std_logic;

  signal history_write_pointer : history_pointer_t;
  signal history_count         : unsigned(C_HISTORY_ADDR_BITS downto 0);
  signal history_write_enable  : std_logic;
  signal history_write_data    : std_logic_vector(C_FRAME_WIDTH-1 downto 0);
  signal history_read_enable   : std_logic;
  signal history_read_address  : std_logic_vector(C_HISTORY_ADDR_BITS-1 downto 0);
  signal history_read_data     : std_logic_vector(C_FRAME_WIDTH-1 downto 0);

  signal start_delay : std_logic_vector(C_MAX_DELAY-1 downto 0);
  signal close_delay : std_logic_vector(C_MAX_DELAY-1 downto 0);

  signal source_start_pending        : std_logic;
  signal source_block_count          : u32_t;
  signal pending_close_count         : u32_t;
  signal pending_close_profile_valid : std_logic;
  signal pending_close_generation    : u32_t;
  signal pending_start_context       : std_logic_vector(CONTEXT_BITS-1 downto 0);
  signal pending_start_profile_valid : std_logic;

  signal active_profile : natural range 0 to 8;
  signal apply_seen     : std_logic;

  signal spectral_synced           : std_logic;
  signal block_active              : std_logic;
  signal block_profile_valid       : std_logic;
  signal block_generation          : u32_t;
  signal first_after_discontinuity : std_logic;
  signal block_service_fault       : std_logic;
  signal block_input_count         : u32_t;
  signal produced_count            : u32_t;
  signal input_index               : u32_t;

  signal pending_frame       : std_logic_vector(C_FRAME_WIDTH-1 downto 0);
  signal pending_frame_valid : std_logic;
  signal computed_frame      : std_logic_vector(C_FRAME_WIDTH-1 downto 0);
  signal pending_close_fault : std_logic;

  signal completed_blocks : u32_t;
  signal invalid_blocks   : u32_t;
  signal service_overruns : u32_t;

  signal mac_channel      : unsigned(2 downto 0);
  signal mac_tap          : unsigned(8 downto 0);
  signal mac_accumulator  : signed(55 downto 0);
  signal mac_sample       : signed(SAMPLE_WIDTH-1 downto 0);
  signal mac_base_coefficient : signed(C_COEFFICIENT_BITS-1 downto 0);
  signal mac_coefficient  : signed(C_COEFFICIENT_BITS-1 downto 0);
  signal mac_product      : signed(SAMPLE_WIDTH+C_COEFFICIENT_BITS-1 downto 0);
  signal mac_interpolate  : std_logic;
  signal mac_interpolation_fraction  : unsigned(1 downto 0);
  signal mac_interpolation_remainder : unsigned(1 downto 0);
  signal mac_phase_a_base : unsigned(C_ROM_ADDR_BITS-1 downto 0);
  signal mac_phase_b_base : unsigned(C_ROM_ADDR_BITS-1 downto 0);

  signal coefficient_enable : std_logic;
  signal coefficient_addr   : std_logic_vector(C_ROM_ADDR_BITS-1 downto 0);
  signal coefficient_data   : std_logic_vector(C_ROM_WORD_BITS-1 downto 0);
  signal coefficient_slot   : unsigned(1 downto 0);

  function profile_for_rate(rate : std_logic_vector(31 downto 0))
    return natural is
  begin
    if unsigned(rate) = to_unsigned(SOURCE_RATE_HZ, rate'length) then
      return 1;
    elsif unsigned(rate) = to_unsigned(64000, rate'length) then
      return 2;
    elsif unsigned(rate) = to_unsigned(128000, rate'length) then
      return 3;
    elsif unsigned(rate) = to_unsigned(16000, rate'length) then
      return 4;
    elsif unsigned(rate) = to_unsigned(8000, rate'length) then
      return 5;
    elsif unsigned(rate) = to_unsigned(4000, rate'length) then
      return 6;
    elsif unsigned(rate) = to_unsigned(2000, rate'length) then
      return 7;
    elsif unsigned(rate) = to_unsigned(1000, rate'length) then
      return 8;
    end if;
    return 0;
  end function;

  function profile_taps(profile : natural) return positive is
  begin
    case profile is
      when 1 => return 65;
      when 2 => return 129;
      when 3 => return 257;
      when 4 | 5 | 6 | 7 | 8 => return 69;
      when others => return 65;
    end case;
  end function;

  function profile_delay(profile : natural) return positive is
  begin
    case profile is
      when 1 => return 32;
      when 2 => return 64;
      when 3 => return 128;
      when 4 | 5 | 6 | 7 | 8 => return 34;
      when others => return 32;
    end case;
  end function;

  function profile_expected_frames(profile : natural) return positive is
  begin
    case profile is
      when 1 => return EXPECTED_SOURCE_FRAMES;
      when 2 => return OUTPUT_FRAMES * C_RATE_DENOMINATOR / 8;
      when 3 => return OUTPUT_FRAMES * C_RATE_DENOMINATOR / 4;
      when 4 => return OUTPUT_FRAMES * C_RATE_DENOMINATOR / 32;
      when 5 => return OUTPUT_FRAMES * C_RATE_DENOMINATOR / 64;
      when 6 => return OUTPUT_FRAMES * C_RATE_DENOMINATOR / 128;
      when 7 => return OUTPUT_FRAMES * C_RATE_DENOMINATOR / 256;
      when 8 => return OUTPUT_FRAMES * C_RATE_DENOMINATOR / 512;
      when others => return EXPECTED_SOURCE_FRAMES;
    end case;
  end function;

  function endpoint_count_matches(
    actual   : u32_t;
    expected : positive)
    return boolean is
  begin
    return
      actual >= to_unsigned(
        expected - C_ENDPOINT_QUANTIZATION_FRAMES, actual'length) and
      actual <= to_unsigned(
        expected + C_ENDPOINT_QUANTIZATION_FRAMES, actual'length);
  end function;

  function qualified_max_order(
    profile : natural;
    nominal : std_logic_vector(7 downto 0))
    return natural is
  begin
    -- Explicit constants keep division out of the context publication path.
    -- Low-rate profiles are qualified only through floor(0.4 Fs / Fnom).
    if unsigned(nominal) = to_unsigned(50, nominal'length) then
      case profile is
        when 1 | 2 | 3 | 4 => return 127;
        when 5 => return 64;
        when 6 => return 32;
        when 7 => return 16;
        when 8 => return 8;
        when others => return 0;
      end case;
    elsif unsigned(nominal) = to_unsigned(60, nominal'length) then
      case profile is
        when 1 | 2 | 3 => return 127;
        when 4 => return 106;
        when 5 => return 53;
        when 6 => return 26;
        when 7 => return 13;
        when 8 => return 6;
        when others => return 0;
      end case;
    end if;
    return 0;
  end function;

  function profile_phase_base(
    profile : natural;
    phase   : natural)
    return natural is
  begin
    case profile is
      when 1 =>
        return C_32K_BASE_WORD + phase * C_32K_WORDS_PHASE;
      when 2 =>
        return C_64K_BASE_WORD + phase * C_64K_WORDS_PHASE;
      when 3 =>
        return C_128K_BASE_WORD + phase * C_128K_WORDS_PHASE;
      when others =>
        return C_32K_BASE_WORD;
    end case;
  end function;

  function target_input(
    numerator : u32_t;
    profile   : natural)
    return u32_t is
  begin
    case profile is
      when 1 => return shift_right(numerator, 4);
      when 2 => return shift_right(numerator, 3);
      when 3 => return shift_right(numerator, 2);
      when 4 => return shift_right(numerator, 5);
      when 5 => return shift_right(numerator, 6);
      when 6 => return shift_right(numerator, 7);
      when 7 => return shift_right(numerator, 8);
      when 8 => return shift_right(numerator, 9);
      when others => return (others => '1');
    end case;
  end function;

  function target_phase(
    numerator : u32_t;
    profile   : natural)
    return natural is
  begin
    case profile is
      when 1 => return to_integer(numerator(3 downto 0));
      when 2 => return to_integer(numerator(2 downto 0));
      when 3 => return to_integer(numerator(1 downto 0));
      when 4 => return to_integer(numerator(4 downto 0));
      when 5 => return to_integer(numerator(5 downto 0));
      when 6 => return to_integer(numerator(6 downto 0));
      when 7 => return to_integer(numerator(7 downto 0));
      when 8 => return to_integer(numerator(8 downto 0));
      when others => return 0;
    end case;
  end function;

  function low_fine_phase(
    profile : natural;
    phase   : natural)
    return natural is
  begin
    case profile is
      when 4 => return phase * 16;
      when 5 => return phase * 8;
      when 6 => return phase * 4;
      when 7 => return phase * 2;
      when 8 => return phase;
      when others => return 0;
    end case;
  end function;

  function profile_is_qualified(
    profile          : natural;
    locked           : std_logic;
    nominal          : std_logic_vector(7 downto 0);
    cycles           : std_logic_vector(7 downto 0);
    enabled          : std_logic;
    configured_rate  : std_logic_vector(31 downto 0);
    measured_rate    : std_logic_vector(31 downto 0);
    frame_rate_valid : std_logic;
    frequency_valid  : std_logic)
    return std_logic is
  begin
    if profile /= 0 and enabled = '1' and locked = '1' and
       frame_rate_valid = '1' and frequency_valid = '1' and
       profile_for_rate(configured_rate) = profile and
       unsigned(measured_rate) = unsigned(configured_rate) and
       ((unsigned(nominal) = to_unsigned(50, nominal'length) and
         unsigned(cycles) = to_unsigned(10, cycles'length)) or
        (unsigned(nominal) = to_unsigned(60, nominal'length) and
         unsigned(cycles) = to_unsigned(12, cycles'length))) then
      return '1';
    end if;
    return '0';
  end function;

  function history_address_for(
    pointer : history_pointer_t;
    tap     : natural)
    return std_logic_vector is
  begin
    return std_logic_vector(to_unsigned(
      (to_integer(pointer) - tap + C_HISTORY_DEPTH) mod C_HISTORY_DEPTH,
      C_HISTORY_ADDR_BITS));
  end function;

  function polyphase_saturate(accumulated : signed(55 downto 0))
    return signed is
    variable shifted : signed(55 downto 0);
  begin
    shifted := shift_right(accumulated, C_COEFFICIENT_FRAC);
    if shifted > to_signed(2**(SAMPLE_WIDTH-1)-1, shifted'length) then
      return to_signed(2**(SAMPLE_WIDTH-1)-1, SAMPLE_WIDTH);
    elsif shifted < to_signed(-(2**(SAMPLE_WIDTH-1)), shifted'length) then
      return to_signed(-(2**(SAMPLE_WIDTH-1)), SAMPLE_WIDTH);
    end if;
    return shifted(SAMPLE_WIDTH-1 downto 0);
  end function;
begin
  assert CHANNELS = 7 and SAMPLE_WIDTH = 24
    report "meter_spectral_conditioner production geometry is 7x24-bit"
    severity failure;
  assert CONTEXT_BITS >= 576
    report "conditioner context is too narrow"
    severity failure;
  assert EXPECTED_SOURCE_FRAMES * 16 =
         OUTPUT_FRAMES * C_RATE_DENOMINATOR
    report "profile 1 source/output geometry is not an exact 16/25 ratio"
    severity failure;
  assert C_LOW_FINE_PER_BASE = 4 and
         C_32K_BASE_WORD =
           (C_LOW_BASE_INTERVALS + 1) * C_LOW_WORDS_PHASE
    report "conditioner compact low-rate ROM geometry is inconsistent"
    severity failure;
  assert C_128K_BASE_WORD + 4 * C_128K_WORDS_PHASE = C_ROM_WORDS
    report "conditioner coefficient ROM geometry is inconsistent"
    severity failure;

  completed_blocks_o <= std_logic_vector(completed_blocks);
  invalid_blocks_o <= std_logic_vector(invalid_blocks);
  service_overruns_o <= std_logic_vector(service_overruns);
  mac_product <= mac_sample * mac_coefficient;

  pack_history : for channel in 0 to CHANNELS-1 generate
    history_write_data(channel*SAMPLE_WIDTH+SAMPLE_WIDTH-1 downto
                       channel*SAMPLE_WIDTH) <=
      raw_frame_i(channel*32+SAMPLE_WIDTH-1 downto channel*32);
  end generate;

  -- Do not let a frame write race an APPLY edge.  The sequencer begins
  -- accepting the newly selected profile on the following clock.
  history_write_enable <=
    frame_accept_i when aresetn = '1' and active_profile /= 0 and
                        config_apply_toggle_i = apply_seen
    else '0';

  history_ram : xpm_memory_sdpram
    generic map (
      MEMORY_SIZE         => C_HISTORY_DEPTH * C_FRAME_WIDTH,
      MEMORY_PRIMITIVE    => HISTORY_MEMORY_PRIMITIVE,
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
      ADDR_WIDTH_A        => C_HISTORY_ADDR_BITS,
      READ_DATA_WIDTH_B   => C_FRAME_WIDTH,
      ADDR_WIDTH_B        => C_HISTORY_ADDR_BITS,
      READ_RESET_VALUE_B  => "0",
      READ_LATENCY_B      => 1,
      WRITE_MODE_B        => "read_first",
      RST_MODE_B          => "SYNC"
    )
    port map (
      sleep          => '0',
      clka           => aclk,
      ena            => history_write_enable,
      wea            => (others => '1'),
      addra          => std_logic_vector(history_write_pointer),
      dina           => history_write_data,
      injectsbiterra => '0',
      injectdbiterra => '0',
      clkb           => aclk,
      rstb           => not aresetn,
      enb            => history_read_enable,
      regceb         => '1',
      addrb          => history_read_address,
      doutb          => history_read_data,
      sbiterrb       => open,
      dbiterrb       => open
    );

  coefficient_rom : xpm_memory_sprom
    generic map (
      MEMORY_SIZE         => C_ROM_WORDS * C_ROM_WORD_BITS,
      MEMORY_PRIMITIVE    => COEFFICIENT_MEMORY_PRIMITIVE,
      ECC_MODE            => "no_ecc",
      MEMORY_INIT_FILE    => "meter_spectral_conditioner_q20.mem",
      MEMORY_INIT_PARAM   => "",
      USE_MEM_INIT        => 1,
      WAKEUP_TIME         => "disable_sleep",
      AUTO_SLEEP_TIME     => 0,
      MESSAGE_CONTROL     => 0,
      MEMORY_OPTIMIZATION => "true",
      CASCADE_HEIGHT      => 0,
      SIM_ASSERT_CHK      => 1,
      READ_DATA_WIDTH_A   => C_ROM_WORD_BITS,
      ADDR_WIDTH_A        => C_ROM_ADDR_BITS,
      READ_RESET_VALUE_A  => "0",
      READ_LATENCY_A      => 1,
      RST_MODE_A          => "SYNC"
    )
    port map (
      sleep          => '0',
      clka           => aclk,
      rsta           => not aresetn,
      ena            => coefficient_enable,
      regcea         => '1',
      addra          => coefficient_addr,
      injectsbiterra => '0',
      injectdbiterra => '0',
      douta          => coefficient_data,
      sbiterra       => open,
      dbiterra       => open
    );

  conditioner_sequencer : process(aclk)
    variable context_value         : std_logic_vector(CONTEXT_BITS-1 downto 0);
    variable accepted_source_count : u32_t;
    variable next_input_index      : u32_t;
    variable target_numerator      : u32_t;
    variable target_input_index    : u32_t;
    variable accumulated_value     : signed(55 downto 0);
    variable coefficient_value     : signed(C_COEFFICIENT_BITS-1 downto 0);
    variable start_now             : std_logic;
    variable profile_now           : std_logic;
    variable delayed_start_now     : std_logic;
    variable delayed_close_now     : std_logic;
    variable close_geometry_valid  : boolean;
    variable close_fault           : std_logic;
    variable phase_value           : natural;
    variable fine_phase            : natural;
    variable base_phase            : natural;
    variable phase_a_word          : natural;
    variable phase_b_word          : natural;
    variable next_tap              : natural;
    variable token_count_value     : natural range 0 to C_TOKEN_DEPTH;
    variable qualified_max         : natural;
    variable base_coefficient      : signed(C_COEFFICIENT_BITS-1 downto 0);
    variable difference_value      : signed(C_COEFFICIENT_BITS downto 0);
    variable interpolation_product : signed(C_COEFFICIENT_BITS+4 downto 0);
    variable interpolation_numerator : signed(C_COEFFICIENT_BITS+5 downto 0);
    variable interpolated_value    : signed(C_COEFFICIENT_BITS+5 downto 0);
    variable interpolation_residue : signed(C_COEFFICIENT_BITS+5 downto 0);
  begin
    if rising_edge(aclk) then
      if aresetn = '0' then
        state                       <= S_IDLE;
        token_write_pointer         <= (others => '0');
        token_read_pointer          <= (others => '0');
        token_count                 <= (others => '0');
        current_pointer             <= (others => '0');
        current_delayed_start       <= '0';
        current_delayed_close       <= '0';
        history_write_pointer       <= (others => '0');
        history_count               <= (others => '0');
        history_read_enable         <= '0';
        history_read_address        <= (others => '0');
        start_delay                 <= (others => '0');
        close_delay                 <= (others => '0');
        source_start_pending        <= '1';
        source_block_count          <= (others => '0');
        pending_close_count         <= (others => '0');
        pending_close_profile_valid <= '0';
        pending_close_generation    <= (others => '0');
        pending_start_context       <= (others => '0');
        pending_start_profile_valid <= '0';
        active_profile              <= 1;
        apply_seen                  <= '0';
        spectral_synced             <= '0';
        block_active                <= '0';
        block_profile_valid         <= '0';
        block_generation            <= (others => '0');
        first_after_discontinuity   <= '1';
        block_service_fault         <= '0';
        block_input_count           <= (others => '0');
        produced_count              <= (others => '0');
        input_index                 <= (others => '0');
        pending_frame               <= (others => '0');
        pending_frame_valid         <= '0';
        computed_frame              <= (others => '0');
        pending_close_fault         <= '0';
        m_axis_context_tdata        <= (others => '0');
        m_axis_context_tvalid       <= '0';
        m_axis_frame_tdata          <= (others => '0');
        m_axis_frame_tvalid         <= '0';
        m_axis_frame_tlast          <= '0';
        m_axis_frame_fault          <= '0';
        completed_blocks            <= (others => '0');
        invalid_blocks              <= (others => '0');
        service_overruns            <= (others => '0');
        mac_channel                 <= (others => '0');
        mac_tap                     <= (others => '0');
        mac_accumulator             <= (others => '0');
        mac_sample                  <= (others => '0');
        mac_base_coefficient        <= (others => '0');
        mac_coefficient             <= (others => '0');
        mac_interpolate             <= '0';
        mac_interpolation_fraction  <= (others => '0');
        mac_interpolation_remainder <= (others => '0');
        mac_phase_a_base            <= (others => '0');
        mac_phase_b_base            <= (others => '0');
        coefficient_enable          <= '0';
        coefficient_addr            <= (others => '0');
        coefficient_slot            <= (others => '0');
      else
        if m_axis_context_tvalid = '1' and
           m_axis_context_tready = '1' then
          m_axis_context_tvalid <= '0';
        end if;
        if m_axis_frame_tvalid = '1' and m_axis_frame_tready = '1' then
          m_axis_frame_tvalid <= '0';
          m_axis_frame_tlast <= '0';
          m_axis_frame_fault <= '0';
        end if;

        if config_apply_toggle_i /= apply_seen then
          -- APPLY is a capture-transaction boundary.  The companion frontend
          -- sees the same toggle, so clearing outstanding context/frame beats
          -- cannot strand it waiting for the old window's TLAST.
          apply_seen                  <= config_apply_toggle_i;
          active_profile              <= profile_for_rate(
                                           configured_frame_rate_i);
          state                       <= S_IDLE;
          token_write_pointer         <= (others => '0');
          token_read_pointer          <= (others => '0');
          token_count                 <= (others => '0');
          history_write_pointer       <= (others => '0');
          history_count               <= (others => '0');
          history_read_enable         <= '0';
          start_delay                 <= (others => '0');
          close_delay                 <= (others => '0');
          current_delayed_start       <= '0';
          current_delayed_close       <= '0';
          source_start_pending        <= '1';
          source_block_count          <= (others => '0');
          pending_close_count         <= (others => '0');
          pending_close_profile_valid <= '0';
          pending_start_profile_valid <= '0';
          spectral_synced             <= '0';
          block_active                <= '0';
          block_profile_valid         <= '0';
          pending_frame_valid         <= '0';
          first_after_discontinuity   <= '1';
          block_service_fault         <= '0';
          block_input_count           <= (others => '0');
          produced_count              <= (others => '0');
          coefficient_enable          <= '0';
          mac_interpolate             <= '0';
          mac_interpolation_remainder <= (others => '0');
          m_axis_context_tvalid       <= '0';
          m_axis_frame_tvalid         <= '0';
          m_axis_frame_tlast          <= '0';
          m_axis_frame_fault          <= '0';
        else
          token_count_value := to_integer(token_count);

          case state is
            when S_IDLE =>
              coefficient_enable <= '0';
              history_read_enable <= '0';
              if token_count_value /= 0 then
                current_pointer <= token_pointer_fifo(
                  to_integer(token_read_pointer));
                current_delayed_start <= token_start_fifo(
                  to_integer(token_read_pointer));
                current_delayed_close <= token_close_fifo(
                  to_integer(token_read_pointer));
                token_read_pointer <= token_read_pointer + 1;
                token_count_value := token_count_value - 1;
                state <= S_DECIDE;
              end if;

            when S_DECIDE =>
              if current_delayed_start = '1' and spectral_synced = '1' then
                if m_axis_context_tvalid = '0' then
                  context_value := pending_start_context;
                  context_value(104) := grid_locked_i;
                  context_value(105) := pending_start_profile_valid;
                  context_value(106) := first_after_discontinuity;
                  if qualified_max_order(
                       active_profile, grid_nominal_hz_i) < 127 then
                    context_value(107) := '1';
                  else
                    context_value(107) := '0';
                  end if;
                  context_value(287 downto 256) := emit_drops_i;
                  m_axis_context_tdata <= context_value;
                  m_axis_context_tvalid <= '1';

                  block_active <= '1';
                  block_profile_valid <= pending_start_profile_valid;
                  block_generation <= unsigned(
                    pending_start_context(31 downto 0));
                  block_input_count <= to_unsigned(1, 32);
                  produced_count <= (others => '0');
                  input_index <= (others => '0');
                  pending_frame_valid <= '0';
                  block_service_fault <= '0';
                  state <= S_CONTEXT_WAIT;
                end if;
              elsif current_delayed_close = '1' and spectral_synced = '0' then
                -- The first complete source block primes the centered filter
                -- history and marker alignment. Publication starts next block.
                spectral_synced <= '1';
                block_active <= '0';
                pending_frame_valid <= '0';
                first_after_discontinuity <= '1';
                block_service_fault <= '0';
                state <= S_IDLE;
              elsif block_active = '1' then
                next_input_index := input_index + 1;
                input_index <= next_input_index;
                block_input_count <= block_input_count + 1;
                state <= S_OUTPUT_CHECK;
              else
                state <= S_IDLE;
              end if;

            when S_CONTEXT_WAIT =>
              if m_axis_context_tvalid = '1' and
                 m_axis_context_tready = '1' then
                state <= S_OUTPUT_CHECK;
              end if;

            when S_OUTPUT_CHECK =>
              target_numerator := to_unsigned(
                to_integer(produced_count) * C_RATE_DENOMINATOR, 32);
              target_input_index := target_input(
                target_numerator, active_profile);
              if produced_count < to_unsigned(
                   OUTPUT_FRAMES, produced_count'length) and
                 target_input_index = input_index then
                phase_value := target_phase(
                  target_numerator, active_profile);
                mac_channel <= (others => '0');
                mac_tap <= (others => '0');
                mac_accumulator <= (others => '0');
                mac_interpolation_remainder <= (others => '0');
                if active_profile >= 4 then
                  fine_phase := low_fine_phase(
                    active_profile, phase_value);
                  base_phase := fine_phase / C_LOW_FINE_PER_BASE;
                  phase_a_word := C_LOW_BASE_WORD +
                    base_phase * C_LOW_WORDS_PHASE;
                  phase_b_word := C_LOW_BASE_WORD +
                    (base_phase + 1) * C_LOW_WORDS_PHASE;
                  if fine_phase mod C_LOW_FINE_PER_BASE = 0 then
                    mac_interpolate <= '0';
                  else
                    mac_interpolate <= '1';
                  end if;
                  mac_interpolation_fraction <= to_unsigned(
                    fine_phase mod C_LOW_FINE_PER_BASE,
                    mac_interpolation_fraction'length);
                else
                  phase_a_word := profile_phase_base(
                    active_profile, phase_value);
                  phase_b_word := phase_a_word;
                  mac_interpolate <= '0';
                  mac_interpolation_fraction <= (others => '0');
                end if;
                mac_phase_a_base <= to_unsigned(
                  phase_a_word, mac_phase_a_base'length);
                mac_phase_b_base <= to_unsigned(
                  phase_b_word, mac_phase_b_base'length);
                coefficient_addr <= std_logic_vector(to_unsigned(
                  phase_a_word, coefficient_addr'length));
                coefficient_slot <= (others => '0');
                coefficient_enable <= '1';
                history_read_address <= history_address_for(
                  current_pointer, 0);
                history_read_enable <= '1';
                state <= S_PREFETCH;
              elsif target_input_index < input_index and
                    produced_count < to_unsigned(
                      OUTPUT_FRAMES, produced_count'length) then
                -- This can only follow a lost source token.  Preserve forward
                -- progress and make the complete family structurally invalid.
                block_service_fault <= '1';
                produced_count <= produced_count + 1;
              elsif current_delayed_close = '1' then
                close_geometry_valid :=
                  endpoint_count_matches(
                    pending_close_count,
                    profile_expected_frames(active_profile)) and
                  endpoint_count_matches(
                    block_input_count,
                    profile_expected_frames(active_profile)) and
                  produced_count = to_unsigned(OUTPUT_FRAMES, 32) and
                  pending_frame_valid = '1' and
                  pending_close_profile_valid = block_profile_valid and
                  pending_close_generation = block_generation and
                  block_service_fault = '0';
                if close_geometry_valid then
                  pending_close_fault <= '0';
                else
                  pending_close_fault <= '1';
                end if;
                coefficient_enable <= '0';
                history_read_enable <= '0';
                state <= S_CLOSE;
              else
                state <= S_IDLE;
              end if;

            -- One cycle lets both synchronous memories return tap zero.
            when S_PREFETCH =>
              state <= S_LOAD;

            when S_LOAD =>
              case to_integer(coefficient_slot) is
                when 0 =>
                  coefficient_value := signed(
                    coefficient_data(C_COEFFICIENT_BITS-1 downto 0));
                when 1 =>
                  coefficient_value := signed(coefficient_data(
                    2*C_COEFFICIENT_BITS-1 downto C_COEFFICIENT_BITS));
                when others =>
                  coefficient_value := signed(coefficient_data(
                    3*C_COEFFICIENT_BITS-1 downto 2*C_COEFFICIENT_BITS));
              end case;
              mac_sample <= signed(history_read_data(
                to_integer(mac_channel)*SAMPLE_WIDTH+SAMPLE_WIDTH-1 downto
                to_integer(mac_channel)*SAMPLE_WIDTH));

              if mac_interpolate = '1' then
                mac_base_coefficient <= coefficient_value;
                coefficient_addr <= std_logic_vector(
                  mac_phase_b_base + to_unsigned(
                    to_integer(mac_tap) / 3,
                    mac_phase_b_base'length));
                state <= S_INTERP_WAIT;
              else
                mac_coefficient <= coefficient_value;
                if to_integer(mac_tap) <
                   profile_taps(active_profile) - 1 then
                  next_tap := to_integer(mac_tap) + 1;
                  history_read_address <= history_address_for(
                    current_pointer, next_tap);
                  coefficient_addr <= std_logic_vector(
                    mac_phase_a_base + to_unsigned(
                      next_tap / 3, mac_phase_a_base'length));
                  coefficient_slot <= to_unsigned(
                    next_tap mod 3, coefficient_slot'length);
                end if;
                state <= S_MAC;
              end if;

            -- The compact low-rate table stores every fourth fine phase.
            -- Wait for the adjacent row, then interpolate with a tap-carried
            -- remainder.  Both endpoint rows sum to Q20 unity, so the final
            -- remainder is zero and the interpolated row does too.
            when S_INTERP_WAIT =>
              state <= S_INTERP_LOAD;

            when S_INTERP_LOAD =>
              case to_integer(coefficient_slot) is
                when 0 =>
                  coefficient_value := signed(
                    coefficient_data(C_COEFFICIENT_BITS-1 downto 0));
                when 1 =>
                  coefficient_value := signed(coefficient_data(
                    2*C_COEFFICIENT_BITS-1 downto C_COEFFICIENT_BITS));
                when others =>
                  coefficient_value := signed(coefficient_data(
                    3*C_COEFFICIENT_BITS-1 downto 2*C_COEFFICIENT_BITS));
              end case;
              base_coefficient := mac_base_coefficient;
              difference_value := resize(
                coefficient_value, difference_value'length) - resize(
                base_coefficient, difference_value'length);
              interpolation_product := resize(
                difference_value * to_signed(
                  to_integer(mac_interpolation_fraction), 3),
                interpolation_product'length);
              interpolation_numerator :=
                shift_left(resize(
                  base_coefficient, interpolation_numerator'length), 2) +
                resize(interpolation_product,
                       interpolation_numerator'length) +
                to_signed(to_integer(mac_interpolation_remainder),
                          interpolation_numerator'length);
              interpolated_value := shift_right(
                interpolation_numerator, 2);
              interpolation_residue := interpolation_numerator -
                shift_left(interpolated_value, 2);
              mac_coefficient <= resize(
                interpolated_value, mac_coefficient'length);
              mac_interpolation_remainder <= unsigned(
                interpolation_residue(
                  mac_interpolation_remainder'range));

              if to_integer(mac_tap) <
                 profile_taps(active_profile) - 1 then
                next_tap := to_integer(mac_tap) + 1;
                history_read_address <= history_address_for(
                  current_pointer, next_tap);
                coefficient_addr <= std_logic_vector(
                  mac_phase_a_base + to_unsigned(
                    next_tap / 3, mac_phase_a_base'length));
                coefficient_slot <= to_unsigned(
                  next_tap mod 3, coefficient_slot'length);
              end if;
              state <= S_MAC;

            when S_MAC =>
              if mac_tap = 0 then
                accumulated_value := resize(
                  mac_product, accumulated_value'length);
              else
                accumulated_value := mac_accumulator + resize(
                  mac_product, accumulated_value'length);
              end if;
              mac_accumulator <= accumulated_value;
              if to_integer(mac_tap) =
                 profile_taps(active_profile) - 1 then
                state <= S_COMMIT;
              else
                mac_tap <= mac_tap + 1;
                state <= S_LOAD;
              end if;

            when S_COMMIT =>
              computed_frame(
                to_integer(mac_channel)*SAMPLE_WIDTH+SAMPLE_WIDTH-1 downto
                to_integer(mac_channel)*SAMPLE_WIDTH) <=
                  std_logic_vector(polyphase_saturate(mac_accumulator));
              mac_accumulator <= (others => '0');
              mac_tap <= (others => '0');
              if to_integer(mac_channel) = CHANNELS - 1 then
                mac_channel <= (others => '0');
                coefficient_enable <= '0';
                history_read_enable <= '0';
                state <= S_STORE;
              else
                mac_channel <= mac_channel + 1;
                coefficient_addr <= std_logic_vector(mac_phase_a_base);
                coefficient_slot <= (others => '0');
                mac_interpolation_remainder <= (others => '0');
                history_read_address <= history_address_for(
                  current_pointer, 0);
                state <= S_PREFETCH;
              end if;

            when S_STORE =>
              if m_axis_frame_tvalid = '0' or
                 m_axis_frame_tready = '1' then
                if pending_frame_valid = '1' then
                  m_axis_frame_tdata <= pending_frame;
                  m_axis_frame_tvalid <= '1';
                  m_axis_frame_tlast <= '0';
                  m_axis_frame_fault <= '0';
                end if;
                pending_frame <= computed_frame;
                pending_frame_valid <= '1';
                produced_count <= produced_count + 1;
                state <= S_OUTPUT_CHECK;
              end if;

            when S_CLOSE =>
              if m_axis_frame_tvalid = '0' or
                 m_axis_frame_tready = '1' then
                close_fault := pending_close_fault or block_service_fault;
                m_axis_frame_tdata <= pending_frame;
                m_axis_frame_tvalid <= '1';
                m_axis_frame_tlast <= '1';
                m_axis_frame_fault <= close_fault;
                pending_frame_valid <= '0';
                block_active <= '0';
                if close_fault = '0' then
                  if completed_blocks /= C_U32_MAX then
                    completed_blocks <= completed_blocks + 1;
                  end if;
                  first_after_discontinuity <= '0';
                else
                  if invalid_blocks /= C_U32_MAX then
                    invalid_blocks <= invalid_blocks + 1;
                  end if;
                  first_after_discontinuity <= '1';
                end if;
                block_service_fault <= '0';
                state <= S_IDLE;
              end if;
          end case;

          -- Source capture runs regardless of MAC or AXIS state.  The token
          -- FIFO contains only the history pointer plus delayed block markers;
          -- the wide seven-lane sample remains in the block-RAM history ring.
          if frame_accept_i = '1' and active_profile /= 0 then
            start_now := source_start_pending;
            profile_now := profile_is_qualified(
              active_profile,
              grid_locked_i,
              grid_nominal_hz_i,
              grid_cycle_count_i,
              config_enable_i,
              configured_frame_rate_i,
              source_frame_rate_i,
              source_frame_rate_valid_i,
              frequency_valid_i);
            if start_now = '1' then
              accepted_source_count := to_unsigned(1, 32);
            else
              accepted_source_count := source_block_count + 1;
            end if;

            delayed_start_now := start_delay(
              profile_delay(active_profile)-1);
            delayed_close_now := close_delay(
              profile_delay(active_profile)-1);
            start_delay <= start_delay(C_MAX_DELAY-2 downto 0) &
                           start_now;
            close_delay <= close_delay(C_MAX_DELAY-2 downto 0) &
                           frame_closes_block_i;

            if to_integer(history_count) >=
               profile_taps(active_profile)-1 then
              if token_count_value < C_TOKEN_DEPTH then
                token_pointer_fifo(to_integer(token_write_pointer)) <=
                  history_write_pointer;
                token_start_fifo(to_integer(token_write_pointer)) <=
                  delayed_start_now;
                token_close_fifo(to_integer(token_write_pointer)) <=
                  delayed_close_now;
                token_write_pointer <= token_write_pointer + 1;
                token_count_value := token_count_value + 1;
              else
                if service_overruns /= C_U32_MAX then
                  service_overruns <= service_overruns + 1;
                end if;
                block_service_fault <= '1';
              end if;
            end if;

            history_write_pointer <= history_write_pointer + 1;
            if history_count < to_unsigned(
                 C_HISTORY_DEPTH, history_count'length) then
              history_count <= history_count + 1;
            end if;

            if start_now = '1' then
              qualified_max := qualified_max_order(
                active_profile, grid_nominal_hz_i);
              context_value := (others => '0');
              context_value(31 downto 0) := frame_user_i(63 downto 32);
              context_value(63 downto 32) := configured_frame_rate_i;
              context_value(95 downto 64) := std_logic_vector(to_unsigned(
                profile_expected_frames(active_profile), 32));
              context_value(103 downto 96) := frame_user_i(71 downto 64);
              context_value(111 downto 104) := (others => '0');
              context_value(119 downto 112) := grid_nominal_hz_i;
              context_value(127 downto 120) := grid_cycle_count_i;
              context_value(135 downto 128) := std_logic_vector(to_unsigned(
                qualified_max, 8));
              context_value(143 downto 136) := std_logic_vector(to_unsigned(
                active_profile, 8));
              context_value(191 downto 160) := frequency_millihz_i;
              context_value(223 downto 192) := frame_user_i(31 downto 0);
              context_value(255 downto 224) := frame_user_i(105 downto 74);
              context_value(543 downto 320) :=
                active_scale_q16_i(223 downto 0);
              pending_start_context <= context_value;
              pending_start_profile_valid <= profile_now;
              source_start_pending <= '0';
            end if;

            source_block_count <= accepted_source_count;
            if frame_closes_block_i = '1' then
              pending_close_count <= accepted_source_count;
              pending_close_profile_valid <= profile_now;
              pending_close_generation <= unsigned(
                frame_user_i(63 downto 32));
              source_block_count <= (others => '0');
              source_start_pending <= '1';
            end if;
          end if;

          token_count <= to_unsigned(
            token_count_value, token_count'length);
        end if;
      end if;
    end if;
  end process;
end architecture;
