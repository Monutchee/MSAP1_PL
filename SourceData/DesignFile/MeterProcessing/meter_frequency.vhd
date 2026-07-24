library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.meter_frequency_pkg.all;
use work.metering_pkg.all;

-- Top-level frequency producer for MeterCore.
--
-- This block observes accepted converted frames but has no ready output, so a
-- missing grid or a slow frequency calculation can never stall ADC capture or
-- RMS accumulation. Configuration is copied from the processing shadow bank
-- on the shared APPLY toggle and all crossing history is discarded.
entity meter_frequency is
  port (
    aclk                       : in  std_logic;
    aresetn                    : in  std_logic;
    frame_accept_i             : in  std_logic;
    frame_data_i               : in  std_logic_vector(511 downto 0);
    frame_keep_i               : in  std_logic_vector(63 downto 0);
    frame_user_i               : in  std_logic_vector(383 downto 0);

    config_generation_i        : in  word32_t;
    config_sample_rate_i       : in  word32_t;
    config_control_i           : in  word32_t;
    config_window_samples_i    : in  word32_t;
    config_minimum_millihz_i   : in  word32_t;
    config_maximum_millihz_i   : in  word32_t;
    config_hysteresis_uv_i     : in  word32_t;
    config_apply_toggle_i      : in  std_logic;

    active_control_o           : out word32_t;
    active_window_samples_o    : out word32_t;
    active_minimum_millihz_o   : out word32_t;
    active_maximum_millihz_o   : out word32_t;
    active_hysteresis_uv_o     : out word32_t;
    status_o                   : out word32_t;
    frequency_millihz_o        : out word32_t;
    period_q16_samples_o       : out word32_t;
    measurement_sequence_o     : out word32_t;
    rejected_count_o           : out word32_t
  );
end entity;

architecture rtl of meter_frequency is
  signal apply_seen             : std_logic := '0';
  signal clear_measurement      : std_logic := '0';
  signal active_generation      : word32_t := (others => '0');
  signal active_sample_rate     : word32_t := std_logic_vector(to_unsigned(32000, 32));
  signal active_control         : word32_t := x"00000A63";
  signal active_window_samples  : word32_t := std_logic_vector(to_unsigned(32000, 32));
  signal active_minimum_millihz : word32_t := std_logic_vector(to_unsigned(40000, 32));
  signal active_maximum_millihz : word32_t := std_logic_vector(to_unsigned(70000, 32));
  signal active_hysteresis_uv   : word32_t := std_logic_vector(to_unsigned(1000000, 32));

  signal crossing_valid       : std_logic;
  signal crossing_prev_seq    : word32_t;
  signal crossing_prev_sample : std_logic_vector(63 downto 0);
  signal crossing_curr_sample : std_logic_vector(63 downto 0);
  signal detector_armed       : std_logic;
  signal reference_valid      : std_logic;
  signal estimator_valid      : std_logic;
  signal estimator_measuring  : std_logic;
  signal estimator_out_range : std_logic;
  signal estimator_timeout    : std_logic;
  signal estimator_error      : std_logic;
  signal estimator_cycles     : std_logic_vector(7 downto 0);
  signal frequency_status     : word32_t := (others => '0');

  signal reference_sample : std_logic_vector(63 downto 0);
  signal sample_valid     : std_logic;
  signal sample_sequence  : word32_t;
begin
  reference_sample <= frame_data_i(
    (FREQUENCY_REFERENCE_VLA * 64) + 63 downto
    FREQUENCY_REFERENCE_VLA * 64);
  sample_sequence <= frame_user_i(31 downto 0);
  sample_valid <= '1' when frame_keep_i = x"FFFFFFFFFFFFFFFF" and
                           frame_user_i(63 downto 32) = active_generation and
                           frame_user_i(64 + FREQUENCY_REFERENCE_VLA) = '1'
                  else '0';

  active_control_o <= active_control;
  active_window_samples_o <= active_window_samples;
  active_minimum_millihz_o <= active_minimum_millihz;
  active_maximum_millihz_o <= active_maximum_millihz;
  active_hysteresis_uv_o <= active_hysteresis_uv;
  status_o <= frequency_status;

  process (all)
    variable status_value : word32_t := (others => '0');
  begin
    status_value := (others => '0');
    status_value(FREQUENCY_STATUS_ENABLED) := active_control(0);
    status_value(FREQUENCY_STATUS_VALID) := estimator_valid;
    status_value(FREQUENCY_STATUS_REFERENCE_VALID) := reference_valid;
    status_value(FREQUENCY_STATUS_ARMED) := detector_armed;
    status_value(FREQUENCY_STATUS_MEASURING) := estimator_measuring;
    status_value(FREQUENCY_STATUS_OUT_OF_RANGE) := estimator_out_range;
    status_value(FREQUENCY_STATUS_TIMEOUT) := estimator_timeout;
    status_value(FREQUENCY_STATUS_ARITHMETIC_ERROR) := estimator_error;
    status_value(10 downto 8) := active_control(3 downto 1);
    status_value(15 downto 12) := active_control(7 downto 4);
    status_value(23 downto 16) := estimator_cycles;
    frequency_status <= status_value;
  end process;

  -- APPLY is already coordinated with conversion/RMS generation changes.
  -- Copying all fields in this one cycle prevents mixed old/new limits.
  process (aclk)
  begin
    if rising_edge(aclk) then
      clear_measurement <= '0';
      if aresetn = '0' then
        apply_seen <= '0';
        active_generation <= (others => '0');
        active_sample_rate <= std_logic_vector(to_unsigned(32000, 32));
        active_control <= x"00000A63";
        active_window_samples <= std_logic_vector(to_unsigned(32000, 32));
        active_minimum_millihz <= std_logic_vector(to_unsigned(40000, 32));
        active_maximum_millihz <= std_logic_vector(to_unsigned(70000, 32));
        active_hysteresis_uv <= std_logic_vector(to_unsigned(1000000, 32));
      elsif config_apply_toggle_i /= apply_seen then
        active_generation <= config_generation_i;
        active_sample_rate <= config_sample_rate_i;
        active_control <= config_control_i;
        active_window_samples <= config_window_samples_i;
        active_minimum_millihz <= config_minimum_millihz_i;
        active_maximum_millihz <= config_maximum_millihz_i;
        active_hysteresis_uv <= config_hysteresis_uv_i;
        apply_seen <= config_apply_toggle_i;
        clear_measurement <= '1';
      end if;
    end if;
  end process;

  zero_crossing : entity work.meter_zero_crossing
    port map (
      aclk => aclk,
      aresetn => aresetn,
      clear_i => clear_measurement,
      frame_accept_i => frame_accept_i,
      sample_valid_i => sample_valid,
      sample_sequence_i => sample_sequence,
      sample_q16_i => reference_sample,
      hysteresis_uv_i => active_hysteresis_uv,
      crossing_valid_o => crossing_valid,
      previous_sequence_o => crossing_prev_seq,
      previous_sample_q16_o => crossing_prev_sample,
      current_sample_q16_o => crossing_curr_sample,
      armed_o => detector_armed,
      reference_valid_o => reference_valid
    );

  estimator : entity work.meter_frequency_estimator
    port map (
      aclk => aclk,
      aresetn => aresetn,
      clear_i => clear_measurement,
      enabled_i => active_control(0),
      mode_i => active_control(3 downto 1),
      averaging_cycles_i => active_control(15 downto 8),
      averaging_window_samples_i => active_window_samples,
      sample_rate_hz_i => active_sample_rate,
      minimum_millihz_i => active_minimum_millihz,
      maximum_millihz_i => active_maximum_millihz,
      frame_accept_i => frame_accept_i,
      sample_sequence_i => sample_sequence,
      crossing_valid_i => crossing_valid,
      previous_sequence_i => crossing_prev_seq,
      previous_sample_q16_i => crossing_prev_sample,
      current_sample_q16_i => crossing_curr_sample,
      frequency_millihz_o => frequency_millihz_o,
      period_q16_samples_o => period_q16_samples_o,
      measurement_sequence_o => measurement_sequence_o,
      cycles_used_o => estimator_cycles,
      valid_o => estimator_valid,
      measuring_o => estimator_measuring,
      out_of_range_o => estimator_out_range,
      timeout_o => estimator_timeout,
      arithmetic_error_o => estimator_error,
      rejected_count_o => rejected_count_o
    );
end architecture;
