library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.metering_pkg.all;
use work.meter_r5_aggregation_pkg.all;
use work.meter_frequency_10s_pkg.all;

-- Nonblocking ten-second crossing observer.
--
-- This entity owns conditioning and crossing interpolation only. A Linux
-- boundary tuple identifies one exact UTC interval in the free-running sample
-- coordinate system. The fixed payload contains observations and provenance;
-- R5C1 remains the sole owner of complete-cycle selection and arithmetic.
entity meter_frequency_10s_observer is
  generic (
    G_CERTIFIED_SAMPLE_RATE_HZ : positive := 128000;
    G_DECIMATION : positive := 128;
    G_CIC_GAIN_SHIFT : natural := 21;
    G_FILTER_WARMUP_OUTPUTS : positive := 24;
    G_HYSTERESIS_MICROVOLTS : positive := 1000000
  );
  port (
    aclk : in std_logic;
    aresetn : in std_logic;
    frame_accept_i : in std_logic;
    frame_data_i : in std_logic_vector(METER_CONVERTED_FRAME_BITS - 1 downto 0);
    frame_keep_i : in std_logic_vector(METER_CONVERTED_KEEP_BITS - 1 downto 0);
    frame_user_i : in std_logic_vector(383 downto 0);
    config_generation_i : in std_logic_vector(31 downto 0);
    configured_sample_rate_hz_i : in std_logic_vector(31 downto 0);
    measured_frame_rate_hz_i : in std_logic_vector(31 downto 0);
    measured_frame_rate_valid_i : in std_logic;
    config_apply_toggle_i : in std_logic;
    boundary_i : in frequency_10s_boundary_t;
    boundary_update_i : in std_logic;
    clear_stats_i : in std_logic;

    m_axis_payload_tdata : out std_logic_vector(31 downto 0);
    m_axis_payload_tkeep : out std_logic_vector(3 downto 0);
    m_axis_payload_tvalid : out std_logic;
    m_axis_payload_tready : in std_logic;
    m_axis_payload_tlast : out std_logic;

    status_o : out std_logic_vector(31 downto 0);
    completed_count_o : out std_logic_vector(31 downto 0);
    dropped_count_o : out std_logic_vector(31 downto 0);
    overflow_count_o : out std_logic_vector(31 downto 0);
    discontinuity_count_o : out std_logic_vector(31 downto 0)
  );
end entity;

architecture rtl of meter_frequency_10s_observer is
  type crossing_storage_t is array (
    0 to 2 * FREQUENCY_10S_CROSSING_CAPACITY - 1) of
    std_logic_vector(63 downto 0);
  attribute ram_style : string;

  function relative_crossing_q16(
    sample_index : unsigned(63 downto 0);
    fraction_q16 : unsigned(15 downto 0);
    interval_start : unsigned(63 downto 0)) return signed is
    variable magnitude : unsigned(63 downto 0);
    variable result : signed(63 downto 0);
  begin
    if sample_index >= interval_start then
      magnitude := shift_left(sample_index - interval_start, 16) +
        resize(fraction_q16, 64);
      result := signed(magnitude);
    else
      magnitude := shift_left(interval_start - sample_index, 16) -
        resize(fraction_q16, 64);
      result := -signed(magnitude);
    end if;
    return result;
  end function;

  function boundary_geometry_valid(
    value : frequency_10s_boundary_t) return boolean is
    variable sample_span : unsigned(63 downto 0);
    variable utc_span : unsigned(63 downto 0);
    variable actual_millisamples : unsigned(95 downto 0);
    variable expected_millisamples : unsigned(95 downto 0);
    variable difference : unsigned(95 downto 0);
  begin
    if unsigned(value.end_sample) <= unsigned(value.start_sample) or
       unsigned(value.utc_end_nanoseconds) <=
         unsigned(value.utc_start_nanoseconds) then
      return false;
    end if;
    sample_span := unsigned(value.end_sample) - unsigned(value.start_sample);
    utc_span := unsigned(value.utc_end_nanoseconds) -
      unsigned(value.utc_start_nanoseconds);
    if sample_span > to_unsigned(2000000, 64) or
       utc_span /= unsigned'(x"00000002540BE400") or
       unsigned(value.measured_sample_rate_millihz) = 0 or
       unsigned(value.measured_sample_rate_millihz) > 200000000 or
       unsigned(value.boundary_generation) = 0 then
      return false;
    end if;
    actual_millisamples := resize(sample_span * to_unsigned(1000, 10), 96);
    expected_millisamples := resize(
      unsigned(value.measured_sample_rate_millihz) * to_unsigned(10, 4), 96);
    if actual_millisamples >= expected_millisamples then
      difference := actual_millisamples - expected_millisamples;
    else
      difference := expected_millisamples - actual_millisamples;
    end if;
    return difference <= to_unsigned(2000, 96);
  end function;

  function profile_supported(
    value : frequency_10s_boundary_t;
    configured_rate : std_logic_vector(31 downto 0)) return boolean is
  begin
    return unsigned(configured_rate) = G_CERTIFIED_SAMPLE_RATE_HZ and
      (unsigned(value.profile(7 downto 0)) = 50 or
       unsigned(value.profile(7 downto 0)) = 60) and
      unsigned(value.profile(15 downto 8)) =
        FREQUENCY_10S_REFERENCE_CHANNEL and
      unsigned(value.profile(23 downto 16)) =
        FREQUENCY_10S_FILTER_PROFILE and
      unsigned(value.profile(31 downto 24)) =
        FREQUENCY_10S_CALIBRATION_PROFILE;
  end function;

  function sample_rate_valid(
    value : frequency_10s_boundary_t;
    configured_rate : std_logic_vector(31 downto 0);
    measured_rate : std_logic_vector(31 downto 0);
    measured_valid : std_logic) return boolean is
    variable configured : unsigned(31 downto 0);
    variable measured : unsigned(31 downto 0);
    variable requested_millihz : unsigned(63 downto 0);
    variable captured_millihz : unsigned(63 downto 0);
    variable tolerance_hz : unsigned(31 downto 0);
    variable rate_difference : unsigned(31 downto 0);
    variable milli_difference : unsigned(63 downto 0);
  begin
    if measured_valid = '0' then
      return false;
    end if;
    configured := unsigned(configured_rate);
    measured := unsigned(measured_rate);
    -- 1/128 + 1/512 + 1/1024 = 0.9765625%, then add the established
    -- two-hertz quantization allowance used by the other observers.
    tolerance_hz := shift_right(configured, 7) +
      shift_right(configured, 9) + shift_right(configured, 10) + 2;
    if measured >= configured then
      rate_difference := measured - configured;
    else
      rate_difference := configured - measured;
    end if;
    requested_millihz := resize(
      unsigned(value.measured_sample_rate_millihz), 64);
    captured_millihz := resize(measured * to_unsigned(1000, 10), 64);
    if requested_millihz >= captured_millihz then
      milli_difference := requested_millihz - captured_millihz;
    else
      milli_difference := captured_millihz - requested_millihz;
    end if;
    return rate_difference <= tolerance_hz and
      milli_difference <= to_unsigned(1500, 64);
  end function;

  signal conditioned_valid : std_logic;
  signal conditioned_sample : signed(31 downto 0);
  signal conditioned_index : unsigned(63 downto 0);
  signal conditioned_fraction : unsigned(15 downto 0);
  signal conditioner_ready : std_logic;
  signal conditioner_reference_valid : std_logic;
  signal conditioner_discontinuity : std_logic;

  signal previous_valid : std_logic := '0';
  signal previous_sample : signed(31 downto 0) := (others => '0');
  signal previous_index : unsigned(63 downto 0) := (others => '0');
  signal previous_fraction : unsigned(15 downto 0) := (others => '0');
  signal crossing_armed : std_logic := '0';

  signal divider_start : std_logic := '0';
  signal divider_dividend : unsigned(63 downto 0) := (others => '0');
  signal divider_divisor : unsigned(63 downto 0) := (others => '0');
  signal divider_busy : std_logic;
  signal divider_done : std_logic;
  signal divider_quotient : unsigned(63 downto 0);
  signal divider_zero : std_logic;
  signal pending_crossing_index : unsigned(63 downto 0) := (others => '0');
  signal pending_crossing_fraction : unsigned(15 downto 0) := (others => '0');

  signal have_latest_crossing : std_logic := '0';
  signal latest_crossing_index : unsigned(63 downto 0) := (others => '0');
  signal latest_crossing_fraction : unsigned(15 downto 0) := (others => '0');

  signal boundary_update_seen : std_logic := '0';
  signal queued_boundary : frequency_10s_boundary_t :=
    FREQUENCY_10S_BOUNDARY_RESET;
  signal queued_boundary_valid : std_logic := '0';
  signal queued_drop_pending : std_logic := '0';
  signal active_boundary : frequency_10s_boundary_t :=
    FREQUENCY_10S_BOUNDARY_RESET;
  signal active_interval : std_logic := '0';
  signal active_configuration_generation : std_logic_vector(31 downto 0) :=
    (others => '0');
  signal active_configured_sample_rate : std_logic_vector(31 downto 0) :=
    (others => '0');
  signal active_status : std_logic_vector(31 downto 0) := (others => '0');
  signal active_reason : std_logic_vector(31 downto 0) := (others => '0');
  signal active_guard_flags : std_logic_vector(31 downto 0) := (others => '0');
  signal active_observer_drops : unsigned(31 downto 0) := (others => '0');
  signal end_seen : std_logic := '0';
  signal finalize_pending : std_logic := '0';

  -- One write port and one synchronous read port infer a compact block RAM.
  -- Do not reset this storage: frozen_crossing_count masks every unwritten
  -- entry, and a reset loop would force both banks into flip-flops.
  signal crossing_storage : crossing_storage_t;
  attribute ram_style of crossing_storage : signal is "block";
  signal crossing_read_address : natural range 0 to
    2 * FREQUENCY_10S_CROSSING_CAPACITY - 1 := 0;
  signal crossing_read_data : std_logic_vector(63 downto 0) :=
    (others => '0');
  signal crossing_high_word_data : std_logic_vector(63 downto 0) :=
    (others => '0');
  signal write_bank : natural range 0 to 1 := 0;
  signal crossing_count : natural range 0 to FREQUENCY_10S_CROSSING_CAPACITY := 0;

  signal interval_sequence : unsigned(31 downto 0) := (others => '0');
  signal packet_pending : std_logic := '0';
  signal payload_index : natural range 0 to FREQUENCY_10S_PAYLOAD_WORDS - 1 := 0;
  signal frozen_bank : natural range 0 to 1 := 0;
  signal frozen_crossing_count : natural range 0 to
    FREQUENCY_10S_CROSSING_CAPACITY := 0;
  signal frozen_sequence : std_logic_vector(31 downto 0) := (others => '0');
  signal frozen_configuration_generation : std_logic_vector(31 downto 0) :=
    (others => '0');
  signal frozen_configured_sample_rate : std_logic_vector(31 downto 0) :=
    (others => '0');
  signal frozen_boundary : frequency_10s_boundary_t :=
    FREQUENCY_10S_BOUNDARY_RESET;
  signal frozen_status : std_logic_vector(31 downto 0) := (others => '0');
  signal frozen_reason : std_logic_vector(31 downto 0) := (others => '0');
  signal frozen_guard_flags : std_logic_vector(31 downto 0) := (others => '0');
  signal frozen_observer_drops : std_logic_vector(31 downto 0) :=
    (others => '0');

  signal completed_count : unsigned(31 downto 0) := (others => '0');
  signal dropped_count : unsigned(31 downto 0) := (others => '0');
  signal overflow_count : unsigned(31 downto 0) := (others => '0');
  signal discontinuity_count : unsigned(31 downto 0) := (others => '0');
  signal payload_word : std_logic_vector(31 downto 0) := (others => '0');
begin
  conditioner : entity work.meter_frequency_10s_conditioner
    generic map (
      G_DECIMATION => G_DECIMATION,
      G_CIC_GAIN_SHIFT => G_CIC_GAIN_SHIFT,
      G_WARMUP_OUTPUTS => G_FILTER_WARMUP_OUTPUTS)
    port map (
      aclk => aclk,
      aresetn => aresetn,
      frame_accept_i => frame_accept_i,
      frame_data_i => frame_data_i,
      frame_keep_i => frame_keep_i,
      frame_user_i => frame_user_i,
      config_generation_i => config_generation_i,
      config_apply_toggle_i => config_apply_toggle_i,
      measured_frame_rate_valid_i => measured_frame_rate_valid_i,
      sample_valid_o => conditioned_valid,
      sample_microvolts_o => conditioned_sample,
      sample_index_o => conditioned_index,
      sample_fraction_q16_o => conditioned_fraction,
      filter_ready_o => conditioner_ready,
      reference_valid_o => conditioner_reference_valid,
      discontinuity_pulse_o => conditioner_discontinuity);

  interpolation_divider : entity work.meter_unsigned_divider
    generic map (WIDTH => 64)
    port map (
      aclk => aclk,
      aresetn => aresetn,
      start_i => divider_start,
      dividend_i => divider_dividend,
      divisor_i => divider_divisor,
      busy_o => divider_busy,
      done_o => divider_done,
      quotient_o => divider_quotient,
      divide_by_zero_o => divider_zero);

  m_axis_payload_tdata <= payload_word;
  m_axis_payload_tkeep <= (others => '1');
  m_axis_payload_tvalid <= packet_pending;
  m_axis_payload_tlast <= '1' when packet_pending = '1' and
    payload_index = FREQUENCY_10S_PAYLOAD_WORDS - 1 else '0';
  completed_count_o <= std_logic_vector(completed_count);
  dropped_count_o <= std_logic_vector(dropped_count);
  overflow_count_o <= std_logic_vector(overflow_count);
  discontinuity_count_o <= std_logic_vector(discontinuity_count);
  status_o <= (31 downto 6 => '0') & divider_busy &
    conditioner_reference_valid & conditioner_ready & packet_pending &
    active_interval & queued_boundary_valid;

  crossing_read_address_select : process (all)
    variable crossing_index_v : natural range 0 to
      FREQUENCY_10S_CROSSING_CAPACITY - 1;
  begin
    crossing_read_address <= frozen_bank * FREQUENCY_10S_CROSSING_CAPACITY;
    if packet_pending = '1' and
       payload_index >= FREQUENCY_10S_METADATA_WORDS then
      crossing_index_v :=
        (payload_index - FREQUENCY_10S_METADATA_WORDS) / 2;
      -- During the held high word, prefetch the next crossing. The current
      -- high half is retained separately, so arbitrary AXIS stalls are safe.
      if ((payload_index - FREQUENCY_10S_METADATA_WORDS) mod 2) = 1 and
         crossing_index_v < FREQUENCY_10S_CROSSING_CAPACITY - 1 then
        crossing_index_v := crossing_index_v + 1;
      end if;
      crossing_read_address <=
        frozen_bank * FREQUENCY_10S_CROSSING_CAPACITY + crossing_index_v;
    end if;
  end process;

  crossing_read_port : process (aclk)
  begin
    if rising_edge(aclk) then
      crossing_read_data <= crossing_storage(crossing_read_address);
    end if;
  end process;

  payload_mux : process (all)
    variable crossing_index_v : natural;
  begin
    payload_word <= (others => '0');
    case payload_index is
      when 0 => payload_word <= frozen_sequence;
      when 1 => payload_word <= frozen_configuration_generation;
      when 2 => payload_word <= frozen_configured_sample_rate;
      when 3 => payload_word <= frozen_boundary.measured_sample_rate_millihz;
      when 4 => payload_word <= x"000000" & frozen_boundary.profile(7 downto 0);
      when 5 => payload_word <= x"00" & frozen_boundary.profile(31 downto 8);
      when 6 => payload_word <= frozen_status;
      when 7 => payload_word <= frozen_reason;
      when 8 => payload_word <= frozen_boundary.start_sample(31 downto 0);
      when 9 => payload_word <= frozen_boundary.start_sample(63 downto 32);
      when 10 => payload_word <= frozen_boundary.end_sample(31 downto 0);
      when 11 => payload_word <= frozen_boundary.end_sample(63 downto 32);
      when 12 => payload_word <= frozen_boundary.utc_start_nanoseconds(31 downto 0);
      when 13 => payload_word <= frozen_boundary.utc_start_nanoseconds(63 downto 32);
      when 14 => payload_word <= frozen_boundary.utc_end_nanoseconds(31 downto 0);
      when 15 => payload_word <= frozen_boundary.utc_end_nanoseconds(63 downto 32);
      when 16 => payload_word <= frozen_boundary.utc_uncertainty_nanoseconds(31 downto 0);
      when 17 => payload_word <= frozen_boundary.utc_uncertainty_nanoseconds(63 downto 32);
      when 18 => payload_word <= frozen_boundary.boundary_generation;
      when 19 => payload_word <= std_logic_vector(to_unsigned(
        frozen_crossing_count, 32));
      when 20 => payload_word <= frozen_observer_drops;
      when 21 => payload_word <= frozen_guard_flags;
      when 22 | 23 => payload_word <= (others => '0');
      when others =>
        crossing_index_v := (payload_index - FREQUENCY_10S_METADATA_WORDS) / 2;
        if crossing_index_v < frozen_crossing_count then
          if ((payload_index - FREQUENCY_10S_METADATA_WORDS) mod 2) = 0 then
            payload_word <= crossing_read_data(31 downto 0);
          else
            payload_word <= crossing_high_word_data(63 downto 32);
          end if;
        end if;
    end case;
  end process;

  process (aclk)
    variable magnitude : unsigned(32 downto 0);
    variable sample_delta : signed(32 downto 0);
    variable time_delta_q16 : unsigned(30 downto 0);
    variable interpolation_product : unsigned(63 downto 0);
    variable fraction_sum : unsigned(64 downto 0);
    variable crossing_index_v : unsigned(63 downto 0);
    variable crossing_fraction_v : unsigned(15 downto 0);
    variable relative_v : signed(63 downto 0);
    variable interval_start_v : unsigned(63 downto 0);
    variable interval_end_v : unsigned(63 downto 0);
    variable crossing_after_end : boolean;
    variable crossing_exact_start : boolean;
    variable crossing_exact_end : boolean;
    variable start_status : std_logic_vector(31 downto 0);
    variable start_reason : std_logic_vector(31 downto 0);
    variable start_drops : unsigned(31 downto 0);
    variable latest_relative : signed(63 downto 0);
    variable crossing_write : boolean;
    variable crossing_write_address : natural range 0 to
      2 * FREQUENCY_10S_CROSSING_CAPACITY - 1;
    variable crossing_write_data : std_logic_vector(63 downto 0);
    variable cancel_update : boolean;
  begin
    if rising_edge(aclk) then
      divider_start <= '0';
      crossing_write := false;
      crossing_write_address := 0;
      crossing_write_data := (others => '0');
      cancel_update := boundary_update_i /= boundary_update_seen and
        boundary_i.control(FREQUENCY_10S_CONTROL_CANCEL_BIT) = '1';

      if aresetn = '0' then
        previous_valid <= '0';
        previous_sample <= (others => '0');
        previous_index <= (others => '0');
        previous_fraction <= (others => '0');
        crossing_armed <= '0';
        divider_dividend <= (others => '0');
        divider_divisor <= (others => '0');
        pending_crossing_index <= (others => '0');
        pending_crossing_fraction <= (others => '0');
        have_latest_crossing <= '0';
        latest_crossing_index <= (others => '0');
        latest_crossing_fraction <= (others => '0');
        boundary_update_seen <= '0';
        queued_boundary <= FREQUENCY_10S_BOUNDARY_RESET;
        queued_boundary_valid <= '0';
        queued_drop_pending <= '0';
        active_boundary <= FREQUENCY_10S_BOUNDARY_RESET;
        active_interval <= '0';
        active_configuration_generation <= (others => '0');
        active_configured_sample_rate <= (others => '0');
        active_status <= (others => '0');
        active_reason <= (others => '0');
        active_guard_flags <= (others => '0');
        active_observer_drops <= (others => '0');
        end_seen <= '0';
        finalize_pending <= '0';
        write_bank <= 0;
        crossing_count <= 0;
        interval_sequence <= (others => '0');
        packet_pending <= '0';
        payload_index <= 0;
        frozen_bank <= 0;
        frozen_crossing_count <= 0;
        frozen_sequence <= (others => '0');
        frozen_configuration_generation <= (others => '0');
        frozen_configured_sample_rate <= (others => '0');
        frozen_boundary <= FREQUENCY_10S_BOUNDARY_RESET;
        frozen_status <= (others => '0');
        frozen_reason <= (others => '0');
        frozen_guard_flags <= (others => '0');
        frozen_observer_drops <= (others => '0');
        crossing_high_word_data <= (others => '0');
        completed_count <= (others => '0');
        dropped_count <= (others => '0');
        overflow_count <= (others => '0');
        discontinuity_count <= (others => '0');
      else
        if clear_stats_i = '1' then
          completed_count <= (others => '0');
          dropped_count <= (others => '0');
          overflow_count <= (others => '0');
          discontinuity_count <= (others => '0');
        end if;

        if packet_pending = '1' and m_axis_payload_tready = '1' then
          if payload_index >= FREQUENCY_10S_METADATA_WORDS and
             ((payload_index - FREQUENCY_10S_METADATA_WORDS) mod 2) = 0 then
            crossing_high_word_data <= crossing_read_data;
          end if;
          if payload_index = FREQUENCY_10S_PAYLOAD_WORDS - 1 then
            packet_pending <= '0';
            payload_index <= 0;
          else
            payload_index <= payload_index + 1;
          end if;
        end if;

        if boundary_update_i /= boundary_update_seen then
          boundary_update_seen <= boundary_update_i;
          if boundary_i.control(FREQUENCY_10S_CONTROL_CANCEL_BIT) = '1' then
            -- Capture/configuration shutdown is not a metrology interval. Drop
            -- both software-owned tuples silently so neither can be revived
            -- as a stale invalid record when conversions resume.
            queued_boundary_valid <= '0';
            queued_drop_pending <= '0';
            active_interval <= '0';
            end_seen <= '0';
            finalize_pending <= '0';
            crossing_count <= 0;
          else
            if queued_boundary_valid = '1' then
              dropped_count <= saturating_increment(dropped_count);
              queued_drop_pending <= '1';
            end if;
            queued_boundary <= boundary_i;
            queued_boundary_valid <= '1';
          end if;
        end if;

        if conditioner_discontinuity = '1' then
          previous_valid <= '0';
          crossing_armed <= '0';
          have_latest_crossing <= '0';
          discontinuity_count <= saturating_increment(discontinuity_count);
          if active_interval = '1' then
            active_status(FREQUENCY_10S_STATUS_SOURCE_DISCONTINUITY_BIT) <= '1';
            active_status(FREQUENCY_10S_STATUS_FILTER_READY_BIT) <= '0';
            active_status(FREQUENCY_10S_STATUS_REFERENCE_VALID_BIT) <= '0';
            active_reason(FREQUENCY_10S_REASON_DISCONTINUITY_BIT) <= '1';
            active_reason(FREQUENCY_10S_REASON_FILTER_WARMUP_BIT) <= '1';
            active_reason(FREQUENCY_10S_REASON_REFERENCE_INVALID_BIT) <= '1';
          end if;
        end if;

        if conditioned_valid = '1' and not cancel_update then
          if conditioned_sample <= -to_signed(G_HYSTERESIS_MICROVOLTS, 32) then
            crossing_armed <= '1';
          end if;
          if previous_valid = '1' and crossing_armed = '1' and
             previous_sample < 0 and conditioned_sample >= 0 then
            if divider_busy = '0' then
              sample_delta := resize(conditioned_sample, 33) -
                resize(previous_sample, 33);
              if sample_delta > 0 and conditioned_index > previous_index then
                magnitude := unsigned(-resize(previous_sample, 33));
                time_delta_q16 := resize(
                  shift_left(conditioned_index - previous_index, 16), 31);
                interpolation_product := magnitude * time_delta_q16;
                divider_dividend <= interpolation_product;
                divider_divisor <= resize(unsigned(sample_delta), 64);
                pending_crossing_index <= previous_index;
                pending_crossing_fraction <= previous_fraction;
                divider_start <= '1';
              else
                dropped_count <= saturating_increment(dropped_count);
                if active_interval = '1' then
                  active_observer_drops <=
                    saturating_increment(active_observer_drops);
                  active_status(FREQUENCY_10S_STATUS_OBSERVER_DROP_BIT) <= '1';
                  active_reason(FREQUENCY_10S_REASON_OBSERVER_DROP_BIT) <= '1';
                end if;
              end if;
            else
              dropped_count <= saturating_increment(dropped_count);
              if active_interval = '1' then
                active_observer_drops <=
                  saturating_increment(active_observer_drops);
                active_status(FREQUENCY_10S_STATUS_OBSERVER_DROP_BIT) <= '1';
                active_reason(FREQUENCY_10S_REASON_OBSERVER_DROP_BIT) <= '1';
              end if;
            end if;
            crossing_armed <= '0';
          end if;
          previous_sample <= conditioned_sample;
          previous_index <= conditioned_index;
          previous_fraction <= conditioned_fraction;
          previous_valid <= '1';

          if active_interval = '1' then
            interval_end_v := unsigned(active_boundary.end_sample);
            if conditioned_index > interval_end_v or
               (conditioned_index = interval_end_v and
                conditioned_fraction /= 0) then
              end_seen <= '1';
            end if;
          elsif queued_boundary_valid = '1' and
                conditioned_index >= unsigned(queued_boundary.start_sample) then
            active_boundary <= queued_boundary;
            active_configuration_generation <= config_generation_i;
            active_configured_sample_rate <= configured_sample_rate_hz_i;
            active_interval <= '1';
            queued_boundary_valid <= '0';
            end_seen <= '0';
            finalize_pending <= '0';
            crossing_count <= 0;
            active_guard_flags <= (others => '0');
            start_status := (others => '0');
            start_reason := (others => '0');
            start_drops := (others => '0');
            if queued_drop_pending = '1' then
              start_status(FREQUENCY_10S_STATUS_OBSERVER_DROP_BIT) := '1';
              start_reason(FREQUENCY_10S_REASON_OBSERVER_DROP_BIT) := '1';
              start_drops := to_unsigned(1, 32);
              queued_drop_pending <= '0';
            end if;
            if boundary_geometry_valid(queued_boundary) and
               queued_boundary.control(FREQUENCY_10S_CONTROL_VALID_BIT) = '1' then
              start_status(FREQUENCY_10S_STATUS_BOUNDARY_VALID_BIT) := '1';
            else
              start_reason(FREQUENCY_10S_REASON_BOUNDARY_INVALID_BIT) := '1';
            end if;
            if queued_boundary.control(
                 FREQUENCY_10S_CONTROL_TIME_SYNCHRONIZED_BIT) = '1' then
              start_status(FREQUENCY_10S_STATUS_TIME_SYNCHRONIZED_BIT) := '1';
            else
              start_reason(FREQUENCY_10S_REASON_TIME_UNSYNCHRONIZED_BIT) := '1';
            end if;
            if unsigned(queued_boundary.utc_uncertainty_nanoseconds) >
               to_unsigned(1000000, 64) then
              start_reason(FREQUENCY_10S_REASON_TIME_UNCERTAINTY_BIT) := '1';
            end if;
            if sample_rate_valid(queued_boundary,
                 configured_sample_rate_hz_i, measured_frame_rate_hz_i,
                 measured_frame_rate_valid_i) then
              start_status(FREQUENCY_10S_STATUS_SAMPLE_RATE_VALID_BIT) := '1';
            else
              start_reason(FREQUENCY_10S_REASON_SAMPLE_RATE_INVALID_BIT) := '1';
            end if;
            if conditioner_ready = '1' then
              start_status(FREQUENCY_10S_STATUS_FILTER_READY_BIT) := '1';
            else
              start_reason(FREQUENCY_10S_REASON_FILTER_WARMUP_BIT) := '1';
            end if;
            if conditioner_reference_valid = '1' then
              start_status(FREQUENCY_10S_STATUS_REFERENCE_VALID_BIT) := '1';
            else
              start_reason(FREQUENCY_10S_REASON_REFERENCE_INVALID_BIT) := '1';
            end if;
            if unsigned(queued_boundary.profile(31 downto 24)) =
               FREQUENCY_10S_CALIBRATION_PROFILE then
              start_status(FREQUENCY_10S_STATUS_CALIBRATION_VALID_BIT) := '1';
            else
              start_reason(FREQUENCY_10S_REASON_CALIBRATION_INVALID_BIT) := '1';
            end if;
            if profile_supported(queued_boundary,
                 configured_sample_rate_hz_i) then
              start_status(FREQUENCY_10S_STATUS_PROFILE_SUPPORTED_BIT) := '1';
            else
              start_reason(FREQUENCY_10S_REASON_UNSUPPORTED_PROFILE_BIT) := '1';
            end if;
            if conditioned_index > unsigned(queued_boundary.start_sample) +
                 G_DECIMATION then
              start_status(FREQUENCY_10S_STATUS_RESYNCHRONIZED_BIT) := '1';
              start_status(FREQUENCY_10S_STATUS_SOURCE_DISCONTINUITY_BIT) := '1';
              start_reason(FREQUENCY_10S_REASON_DISCONTINUITY_BIT) := '1';
            end if;
            active_status <= start_status;
            active_reason <= start_reason;
            active_observer_drops <= start_drops;

            -- Seed the interval with the most recent crossing only when it is
            -- still at or before the requested end. A tuple delivered after
            -- its end is already marked resynchronized/discontinuous above;
            -- admitting an arbitrarily late crossing as an "after" guard
            -- would misrepresent the bounded observation geometry.
            if have_latest_crossing = '1' and
               (latest_crossing_index <
                  unsigned(queued_boundary.end_sample) or
                (latest_crossing_index =
                   unsigned(queued_boundary.end_sample) and
                 latest_crossing_fraction = 0)) then
              latest_relative := relative_crossing_q16(
                latest_crossing_index, latest_crossing_fraction,
                unsigned(queued_boundary.start_sample));
              crossing_write := true;
              crossing_write_address :=
                write_bank * FREQUENCY_10S_CROSSING_CAPACITY;
              crossing_write_data := std_logic_vector(latest_relative);
              crossing_count <= 1;
              if latest_relative < 0 then
                active_guard_flags(
                  FREQUENCY_10S_GUARD_BEFORE_START_BIT) <= '1';
              elsif latest_relative = 0 then
                active_guard_flags(
                  FREQUENCY_10S_GUARD_EXACT_START_BIT) <= '1';
              end if;
              if latest_crossing_index =
                   unsigned(queued_boundary.end_sample) and
                 latest_crossing_fraction = 0 then
                active_guard_flags(
                  FREQUENCY_10S_GUARD_EXACT_END_BIT) <= '1';
              end if;
            end if;
          end if;
        end if;

        if divider_done = '1' and not cancel_update then
          if divider_zero = '1' then
            dropped_count <= saturating_increment(dropped_count);
            if active_interval = '1' then
              active_observer_drops <=
                saturating_increment(active_observer_drops);
              active_status(FREQUENCY_10S_STATUS_OBSERVER_DROP_BIT) <= '1';
              active_reason(FREQUENCY_10S_REASON_OBSERVER_DROP_BIT) <= '1';
            end if;
          else
            fraction_sum := resize(pending_crossing_fraction, 65) +
              resize(divider_quotient, 65);
            crossing_index_v := pending_crossing_index +
              resize(shift_right(fraction_sum, 16), 64);
            crossing_fraction_v := fraction_sum(15 downto 0);
            latest_crossing_index <= crossing_index_v;
            latest_crossing_fraction <= crossing_fraction_v;
            have_latest_crossing <= '1';
            if active_interval = '1' then
              interval_start_v := unsigned(active_boundary.start_sample);
              interval_end_v := unsigned(active_boundary.end_sample);
              crossing_after_end := crossing_index_v > interval_end_v or
                (crossing_index_v = interval_end_v and
                 crossing_fraction_v /= 0);
              crossing_exact_start := crossing_index_v = interval_start_v and
                crossing_fraction_v = 0;
              crossing_exact_end := crossing_index_v = interval_end_v and
                crossing_fraction_v = 0;
              relative_v := relative_crossing_q16(crossing_index_v,
                crossing_fraction_v, interval_start_v);
              if crossing_count < FREQUENCY_10S_CROSSING_CAPACITY then
                crossing_write := true;
                crossing_write_address :=
                  write_bank * FREQUENCY_10S_CROSSING_CAPACITY +
                  crossing_count;
                crossing_write_data := std_logic_vector(relative_v);
                crossing_count <= crossing_count + 1;
                if relative_v < 0 then
                  active_guard_flags(
                    FREQUENCY_10S_GUARD_BEFORE_START_BIT) <= '1';
                end if;
                if crossing_after_end then
                  active_guard_flags(
                    FREQUENCY_10S_GUARD_AFTER_END_BIT) <= '1';
                end if;
                if crossing_exact_start then
                  active_guard_flags(
                    FREQUENCY_10S_GUARD_EXACT_START_BIT) <= '1';
                end if;
                if crossing_exact_end then
                  active_guard_flags(
                    FREQUENCY_10S_GUARD_EXACT_END_BIT) <= '1';
                end if;
              else
                overflow_count <= saturating_increment(overflow_count);
                active_status(FREQUENCY_10S_STATUS_CROSSING_OVERFLOW_BIT) <= '1';
                active_reason(FREQUENCY_10S_REASON_CROSSING_OVERFLOW_BIT) <= '1';
              end if;
            end if;
          end if;
        end if;

        if not cancel_update and active_interval = '1' and end_seen = '1' and
           divider_busy = '0' and divider_done = '0' and
           divider_start = '0' then
          finalize_pending <= '1';
        end if;

        if finalize_pending = '1' and not cancel_update then
          finalize_pending <= '0';
          active_interval <= '0';
          end_seen <= '0';
          if packet_pending = '0' then
            frozen_bank <= write_bank;
            frozen_crossing_count <= crossing_count;
            frozen_sequence <= std_logic_vector(interval_sequence);
            frozen_configuration_generation <=
              active_configuration_generation;
            frozen_configured_sample_rate <= active_configured_sample_rate;
            frozen_boundary <= active_boundary;
            frozen_status <= active_status;
            frozen_reason <= active_reason;
            frozen_guard_flags <= active_guard_flags;
            frozen_observer_drops <=
              std_logic_vector(active_observer_drops);
            packet_pending <= '1';
            payload_index <= 0;
            interval_sequence <= interval_sequence + 1;
            completed_count <= saturating_increment(completed_count);
            if write_bank = 0 then
              write_bank <= 1;
            else
              write_bank <= 0;
            end if;
          else
            dropped_count <= saturating_increment(dropped_count);
            interval_sequence <= interval_sequence + 1;
            queued_drop_pending <= '1';
          end if;
        end if;

        if crossing_write then
          crossing_storage(crossing_write_address) <= crossing_write_data;
        end if;
      end if;
    end if;
  end process;
end architecture;
