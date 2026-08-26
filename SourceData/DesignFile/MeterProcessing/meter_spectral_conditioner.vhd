-- SPDX-License-Identifier: MIT
--
-- M16 streaming anti-alias/rational conditioner.
--
-- The production profile accepts the preserved seven raw signed 24-bit ADC
-- lanes at 32 kframe/s and emits 4,096 simultaneous real samples for an exact
-- 6,400-frame 10/12-cycle basic block. It is a 16/25 rational resampler with
-- a 1,025-tap, 16-phase, Q20 Kaiser low-pass prototype. Only one 65-tap phase
-- is evaluated per output, using one time-shared multiplier over seven lanes.
-- The composite passband is flat through 7.62 kHz and the first alias band is
-- below -79 dB; every phase is normalized to exact unity DC gain.
--
-- The prototype group delay is exactly 32 source frames. Delaying the block
-- markers by that amount makes output sample n correspond to source position
-- n*25/16 while retaining the original block's provenance. This branch is
-- observational and has no input READY. A phase costs 65*7=455 clocks, well
-- below the 3,124-clock minimum frame spacing at 32 kSPS/99.999 MHz. Any
-- violated service interval is counted and invalidates the affected window.

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
    SOURCE_RATE_HZ         : positive := 32000
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
  constant C_PHASE_COUNT      : positive := 16;
  constant C_PHASE_TAPS       : positive := 65;
  constant C_PROTOTYPE_TAPS   : positive := 1025;
  constant C_FILTER_DELAY     : positive := 32;
  constant C_COEFFICIENT_BITS : positive := 21;
  constant C_COEFFICIENT_FRAC : positive := 20;
  constant C_RATE_NUMERATOR   : positive := 16;
  constant C_RATE_DENOMINATOR : positive := 25;
  constant C_FRAME_WIDTH      : positive := CHANNELS * SAMPLE_WIDTH;
  constant C_ROM_WORDS        : positive := C_PHASE_COUNT * C_PHASE_TAPS;
  constant C_U32_MAX          : unsigned(31 downto 0) := (others => '1');

  type state_t is (S_IDLE, S_DECIDE, S_PREFETCH, S_MAC, S_STORE, S_CLOSE);
  signal state : state_t;

  type history_row_t is array (0 to C_PHASE_TAPS-1) of
    signed(SAMPLE_WIDTH-1 downto 0);
  type history_t is array (0 to CHANNELS-1) of history_row_t;
  signal history : history_t;

  signal write_pointer         : unsigned(6 downto 0);
  signal captured_pointer      : unsigned(6 downto 0);
  signal history_count         : unsigned(6 downto 0);
  signal current_history_valid : std_logic;

  signal start_delay           : std_logic_vector(C_FILTER_DELAY-1 downto 0);
  signal close_delay           : std_logic_vector(C_FILTER_DELAY-1 downto 0);
  signal current_delayed_start : std_logic;
  signal current_delayed_close : std_logic;

  signal source_start_pending        : std_logic;
  signal source_block_count          : unsigned(31 downto 0);
  signal pending_close_count         : unsigned(31 downto 0);
  signal pending_close_profile_valid : std_logic;
  signal pending_close_generation    : unsigned(31 downto 0);
  signal pending_start_context       : std_logic_vector(CONTEXT_BITS-1 downto 0);
  signal pending_start_profile_valid : std_logic;

  signal spectral_synced           : std_logic;
  signal block_active              : std_logic;
  signal block_profile_valid       : std_logic;
  signal block_generation          : unsigned(31 downto 0);
  signal first_after_discontinuity : std_logic;
  signal block_service_fault       : std_logic;
  signal block_input_count         : unsigned(31 downto 0);
  signal produced_count            : unsigned(31 downto 0);
  signal input_index               : unsigned(31 downto 0);

  signal pending_frame       : std_logic_vector(C_FRAME_WIDTH-1 downto 0);
  signal pending_frame_valid : std_logic;
  signal computed_frame      : std_logic_vector(C_FRAME_WIDTH-1 downto 0);
  signal pending_close_fault : std_logic;

  signal completed_blocks : unsigned(31 downto 0);
  signal invalid_blocks   : unsigned(31 downto 0);
  signal service_overruns : unsigned(31 downto 0);
  signal apply_seen       : std_logic;

  signal mac_phase         : unsigned(3 downto 0);
  signal mac_channel       : unsigned(2 downto 0);
  signal mac_tap           : unsigned(6 downto 0);
  signal rom_fetch_tap     : unsigned(6 downto 0);
  signal mac_accumulator   : signed(55 downto 0);
  signal mac_sample        : signed(SAMPLE_WIDTH-1 downto 0);
  signal mac_coefficient   : signed(C_COEFFICIENT_BITS-1 downto 0);
  signal mac_product       : signed(SAMPLE_WIDTH+C_COEFFICIENT_BITS-1 downto 0);
  signal coefficient_addr  : std_logic_vector(10 downto 0);
  signal coefficient_data  : std_logic_vector(C_COEFFICIENT_BITS-1 downto 0);
  signal coefficient_enable : std_logic;
  signal history_address    : natural range 0 to C_PHASE_TAPS-1;

  function polyphase_saturate(accumulated : signed(55 downto 0))
    return signed is
    variable shifted : signed(55 downto 0);
  begin
    shifted := shift_right(accumulated, C_COEFFICIENT_FRAC);
    if shifted > to_signed(2**(SAMPLE_WIDTH-1)-1, shifted'length) then
      return to_signed(2**(SAMPLE_WIDTH-1)-1, SAMPLE_WIDTH);
    elsif shifted < to_signed(-(2**(SAMPLE_WIDTH-1)), shifted'length) then
      return to_signed(-(2**(SAMPLE_WIDTH-1)), SAMPLE_WIDTH);
    else
      return shifted(SAMPLE_WIDTH-1 downto 0);
    end if;
  end function;

  function profile_is_qualified(
    locked           : std_logic;
    nominal          : std_logic_vector(7 downto 0);
    cycles           : std_logic_vector(7 downto 0);
    enabled          : std_logic;
    frame_rate       : std_logic_vector(31 downto 0);
    frame_rate_valid : std_logic;
    frequency_valid  : std_logic)
    return std_logic is
  begin
    if enabled = '1' and locked = '1' and frame_rate_valid = '1' and
       frequency_valid = '1' and
       unsigned(frame_rate) = to_unsigned(SOURCE_RATE_HZ, frame_rate'length) and
       ((unsigned(nominal) = to_unsigned(50, nominal'length) and
         unsigned(cycles) = to_unsigned(10, cycles'length)) or
        (unsigned(nominal) = to_unsigned(60, nominal'length) and
         unsigned(cycles) = to_unsigned(12, cycles'length))) then
      return '1';
    end if;
    return '0';
  end function;
begin
  assert CHANNELS = 7 and SAMPLE_WIDTH = 24
    report "meter_spectral_conditioner production geometry is 7x24-bit"
    severity failure;
  assert EXPECTED_SOURCE_FRAMES * C_RATE_NUMERATOR =
         OUTPUT_FRAMES * C_RATE_DENOMINATOR
    report "conditioner source/output geometry is not an exact 16/25 ratio"
    severity failure;
  assert CONTEXT_BITS >= 576
    report "conditioner context is too narrow"
    severity failure;
  assert C_PROTOTYPE_TAPS = C_PHASE_COUNT * (C_PHASE_TAPS - 1) + 1
    report "conditioner polyphase prototype geometry is inconsistent"
    severity failure;

  coefficient_addr <= std_logic_vector(to_unsigned(
    to_integer(mac_phase) * C_PHASE_TAPS + to_integer(rom_fetch_tap),
    coefficient_addr'length));
  history_address <= (to_integer(captured_pointer) - to_integer(mac_tap) +
                      C_PHASE_TAPS) mod C_PHASE_TAPS;
  mac_sample <= history(to_integer(mac_channel))(history_address);
  mac_coefficient <= signed(coefficient_data);
  mac_product <= mac_sample * mac_coefficient;

  completed_blocks_o <= std_logic_vector(completed_blocks);
  invalid_blocks_o <= std_logic_vector(invalid_blocks);
  service_overruns_o <= std_logic_vector(service_overruns);

  -- A synchronous block ROM keeps the 16 independently normalized phases
  -- out of LUT muxes. Phases 1..15 have 64 prototype taps and use a zero pad
  -- at address 64 so the MAC controller remains constant-latency.
  coefficient_rom : xpm_memory_sprom
    generic map (
      MEMORY_SIZE         => C_ROM_WORDS * C_COEFFICIENT_BITS,
      MEMORY_PRIMITIVE    => "block",
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
      READ_DATA_WIDTH_A   => C_COEFFICIENT_BITS,
      ADDR_WIDTH_A        => coefficient_addr'length,
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
    variable context_value          : std_logic_vector(CONTEXT_BITS-1 downto 0);
    variable accepted_source_count  : unsigned(31 downto 0);
    variable start_now              : std_logic;
    variable profile_now            : std_logic;
    variable accumulated_value      : signed(55 downto 0);
    variable next_input_index       : unsigned(31 downto 0);
    variable target_numerator       : unsigned(31 downto 0);
    variable target_input_index     : unsigned(31 downto 0);
    variable output_due             : boolean;
    variable close_geometry_valid   : boolean;
    variable close_fault            : std_logic;
  begin
    if rising_edge(aclk) then
      if aresetn = '0' then
        state                       <= S_IDLE;
        write_pointer               <= (others => '0');
        captured_pointer            <= (others => '0');
        history_count               <= (others => '0');
        current_history_valid       <= '0';
        start_delay                 <= (others => '0');
        close_delay                 <= (others => '0');
        current_delayed_start       <= '0';
        current_delayed_close       <= '0';
        source_start_pending        <= '1';
        source_block_count          <= (others => '0');
        pending_close_count         <= (others => '0');
        pending_close_profile_valid <= '0';
        pending_close_generation    <= (others => '0');
        pending_start_context       <= (others => '0');
        pending_start_profile_valid <= '0';
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
        apply_seen                  <= '0';
        mac_phase                   <= (others => '0');
        mac_channel                 <= (others => '0');
        mac_tap                     <= (others => '0');
        rom_fetch_tap               <= (others => '0');
        mac_accumulator             <= (others => '0');
        coefficient_enable          <= '0';
        for channel in 0 to CHANNELS-1 loop
          for tap in 0 to C_PHASE_TAPS-1 loop
            history(channel)(tap) <= (others => '0');
          end loop;
        end loop;
      else
        if m_axis_context_tvalid = '1' and m_axis_context_tready = '1' then
          m_axis_context_tvalid <= '0';
        end if;
        if m_axis_frame_tvalid = '1' and m_axis_frame_tready = '1' then
          m_axis_frame_tvalid <= '0';
          m_axis_frame_tlast <= '0';
          m_axis_frame_fault <= '0';
        end if;

        if config_apply_toggle_i /= apply_seen then
          -- Keep raw history continuous, but discard marker and phase state so
          -- no spectral block spans two configurations.
          apply_seen                  <= config_apply_toggle_i;
          start_delay                 <= (others => '0');
          close_delay                 <= (others => '0');
          current_delayed_start       <= '0';
          current_delayed_close       <= '0';
          source_start_pending        <= '1';
          source_block_count          <= (others => '0');
          spectral_synced             <= '0';
          block_active                <= '0';
          block_profile_valid         <= '0';
          block_generation            <= (others => '0');
          pending_frame_valid         <= '0';
          first_after_discontinuity   <= '1';
          block_service_fault         <= '0';
          coefficient_enable          <= '0';
          state                       <= S_IDLE;
        else
          if frame_accept_i = '1' and state /= S_IDLE then
            -- Never stall acquisition; mark the affected family bad.
            if service_overruns /= C_U32_MAX then
              service_overruns <= service_overruns + 1;
            end if;
            block_service_fault <= '1';
          end if;

          case state is
            when S_IDLE =>
              coefficient_enable <= '0';
              if frame_accept_i = '1' then
                start_now := source_start_pending;
                profile_now := profile_is_qualified(
                  grid_locked_i, grid_nominal_hz_i, grid_cycle_count_i,
                  config_enable_i, source_frame_rate_i,
                  source_frame_rate_valid_i, frequency_valid_i);
                if start_now = '1' then
                  accepted_source_count := to_unsigned(1, 32);
                else
                  accepted_source_count := source_block_count + 1;
                end if;

                for channel in 0 to CHANNELS-1 loop
                  history(channel)(to_integer(write_pointer)) <= signed(
                    raw_frame_i(channel*32+SAMPLE_WIDTH-1 downto channel*32));
                end loop;
                captured_pointer <= write_pointer;
                if to_integer(write_pointer) = C_PHASE_TAPS - 1 then
                  write_pointer <= (others => '0');
                else
                  write_pointer <= write_pointer + 1;
                end if;
                if history_count < to_unsigned(C_PHASE_TAPS, history_count'length) then
                  history_count <= history_count + 1;
                end if;
                if history_count >= to_unsigned(C_PHASE_TAPS-1, history_count'length) then
                  current_history_valid <= '1';
                else
                  current_history_valid <= '0';
                end if;

                current_delayed_start <= start_delay(C_FILTER_DELAY-1);
                current_delayed_close <= close_delay(C_FILTER_DELAY-1);
                start_delay <= start_delay(C_FILTER_DELAY-2 downto 0) & start_now;
                close_delay <= close_delay(C_FILTER_DELAY-2 downto 0) &
                               frame_closes_block_i;

                if start_now = '1' then
                  context_value := (others => '0');
                  context_value(31 downto 0) := frame_user_i(63 downto 32);
                  context_value(63 downto 32) := source_frame_rate_i;
                  context_value(95 downto 64) := std_logic_vector(
                    to_unsigned(EXPECTED_SOURCE_FRAMES, 32));
                  context_value(103 downto 96) := frame_user_i(71 downto 64);
                  context_value(111 downto 104) := (others => '0');
                  context_value(119 downto 112) := grid_nominal_hz_i;
                  context_value(127 downto 120) := grid_cycle_count_i;
                  context_value(135 downto 128) := std_logic_vector(to_unsigned(127, 8));
                  context_value(143 downto 136) := std_logic_vector(to_unsigned(1, 8));
                  context_value(191 downto 160) := frequency_millihz_i;
                  context_value(255 downto 224) := frame_user_i(105 downto 74);
                  context_value(223 downto 192) := frame_user_i(31 downto 0);
                  context_value(543 downto 320) := active_scale_q16_i(223 downto 0);
                  pending_start_context <= context_value;
                  pending_start_profile_valid <= profile_now;
                  source_start_pending <= '0';
                end if;

                source_block_count <= accepted_source_count;
                if frame_closes_block_i = '1' then
                  pending_close_count <= accepted_source_count;
                  pending_close_profile_valid <= profile_now;
                  pending_close_generation <= unsigned(frame_user_i(63 downto 32));
                  source_block_count <= (others => '0');
                  source_start_pending <= '1';
                end if;
                state <= S_DECIDE;
              end if;

            when S_DECIDE =>
              if current_history_valid = '0' then
                state <= S_IDLE;
              elsif current_delayed_start = '1' and spectral_synced = '1' then
                -- Reserve the frontend bank before sample zero.
                if m_axis_context_tvalid = '0' or m_axis_context_tready = '1' then
                  context_value := pending_start_context;
                  context_value(104) := grid_locked_i;
                  context_value(105) := pending_start_profile_valid;
                  context_value(106) := first_after_discontinuity;
                  context_value(107) := '0';
                  context_value(287 downto 256) := emit_drops_i;
                  m_axis_context_tdata <= context_value;
                  m_axis_context_tvalid <= '1';

                  block_active <= '1';
                  block_profile_valid <= pending_start_profile_valid;
                  block_generation <= unsigned(pending_start_context(31 downto 0));
                  block_input_count <= to_unsigned(1, 32);
                  produced_count <= (others => '0');
                  input_index <= (others => '0');
                  pending_frame_valid <= '0';
                  mac_phase <= (others => '0');
                  mac_channel <= (others => '0');
                  mac_tap <= (others => '0');
                  rom_fetch_tap <= (others => '0');
                  mac_accumulator <= (others => '0');
                  coefficient_enable <= '1';
                  state <= S_PREFETCH;
                end if;
              elsif current_delayed_close = '1' and spectral_synced = '0' then
                -- The first complete block primes history and marker alignment.
                -- Publication starts with the next block.
                spectral_synced <= '1';
                block_active <= '0';
                pending_frame_valid <= '0';
                first_after_discontinuity <= '1';
                block_service_fault <= '0';
                state <= S_IDLE;
              elsif block_active = '1' then
                next_input_index := input_index + 1;
                block_input_count <= block_input_count + 1;
                input_index <= next_input_index;

                if current_delayed_close = '1' then
                  close_geometry_valid :=
                    pending_close_count = to_unsigned(
                      EXPECTED_SOURCE_FRAMES, pending_close_count'length) and
                    block_input_count + 1 = to_unsigned(
                      EXPECTED_SOURCE_FRAMES, block_input_count'length) and
                    produced_count = to_unsigned(
                      OUTPUT_FRAMES, produced_count'length) and
                    pending_close_profile_valid = block_profile_valid and
                    pending_close_generation = block_generation and
                    block_service_fault = '0';
                  if close_geometry_valid then
                    pending_close_fault <= '0';
                  else
                    pending_close_fault <= '1';
                  end if;
                  coefficient_enable <= '0';
                  state <= S_CLOSE;
                else
                  target_numerator := to_unsigned(
                    to_integer(produced_count) * C_RATE_DENOMINATOR, 32);
                  target_input_index := shift_right(target_numerator, 4);
                  output_due := produced_count < to_unsigned(
                    OUTPUT_FRAMES, produced_count'length) and
                    target_input_index = next_input_index;
                  if output_due then
                    mac_phase <= target_numerator(3 downto 0);
                    mac_channel <= (others => '0');
                    mac_tap <= (others => '0');
                    rom_fetch_tap <= (others => '0');
                    mac_accumulator <= (others => '0');
                    coefficient_enable <= '1';
                    state <= S_PREFETCH;
                  else
                    state <= S_IDLE;
                  end if;
                end if;
              else
                state <= S_IDLE;
              end if;

            -- One cycle lets the synchronous ROM return tap zero.
            when S_PREFETCH =>
              rom_fetch_tap <= to_unsigned(1, rom_fetch_tap'length);
              state <= S_MAC;

            when S_MAC =>
              if mac_tap = 0 then
                accumulated_value := resize(mac_product, accumulated_value'length);
              else
                accumulated_value := mac_accumulator +
                  resize(mac_product, accumulated_value'length);
              end if;
              if to_integer(mac_tap) = C_PHASE_TAPS - 1 then
                computed_frame(
                  to_integer(mac_channel)*SAMPLE_WIDTH+SAMPLE_WIDTH-1 downto
                  to_integer(mac_channel)*SAMPLE_WIDTH) <=
                    std_logic_vector(polyphase_saturate(accumulated_value));
                mac_accumulator <= (others => '0');
                mac_tap <= (others => '0');
                if to_integer(mac_channel) = CHANNELS - 1 then
                  mac_channel <= (others => '0');
                  coefficient_enable <= '0';
                  state <= S_STORE;
                else
                  -- Tap zero for the next lane was prefetched while the final
                  -- tap accumulated.
                  mac_channel <= mac_channel + 1;
                  rom_fetch_tap <= to_unsigned(1, rom_fetch_tap'length);
                end if;
              else
                mac_accumulator <= accumulated_value;
                mac_tap <= mac_tap + 1;
                if to_integer(mac_tap) = C_PHASE_TAPS - 2 then
                  rom_fetch_tap <= (others => '0');
                else
                  rom_fetch_tap <= mac_tap + 2;
                end if;
              end if;

            when S_STORE =>
              if m_axis_frame_tvalid = '0' or m_axis_frame_tready = '1' then
                if pending_frame_valid = '1' then
                  m_axis_frame_tdata <= pending_frame;
                  m_axis_frame_tvalid <= '1';
                  m_axis_frame_tlast <= '0';
                  m_axis_frame_fault <= '0';
                end if;
                pending_frame <= computed_frame;
                pending_frame_valid <= '1';
                produced_count <= produced_count + 1;
                state <= S_IDLE;
              end if;

            when S_CLOSE =>
              if m_axis_frame_tvalid = '0' or m_axis_frame_tready = '1' then
                close_fault := pending_close_fault or block_service_fault;
                if frame_accept_i = '1' and state /= S_IDLE then
                  close_fault := '1';
                end if;
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
        end if;
      end if;
    end if;
  end process;
end architecture;
