library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.metering_pkg.all;

entity meter_rms is
  generic (
    G_FIRST_CHANNEL : natural := 4;
    G_CHANNEL_COUNT : positive := 3;
    G_RESULT_MASK   : std_logic_vector(7 downto 0) := x"70"
  );
  port (
    aclk                    : in  std_logic;
    aresetn                 : in  std_logic;
    s_axis_tdata            : in  std_logic_vector(511 downto 0);
    s_axis_tkeep            : in  std_logic_vector(63 downto 0);
    s_axis_tuser            : in  std_logic_vector(383 downto 0);
    s_axis_tvalid           : in  std_logic;
    s_axis_tready           : out std_logic;
    s_axis_tlast            : in  std_logic;

    config_generation_i     : in  word32_t;
    config_sample_rate_i    : in  word32_t;
    config_window_samples_i : in  word32_t;
    config_valid_mask_i     : in  std_logic_vector(7 downto 0);
    config_enable_i         : in  std_logic;
    config_dc_remove_i      : in  std_logic;
    config_apply_toggle_i   : in  std_logic;

    active_generation_o     : out word32_t;
    status_o                : out word32_t;
    result_valid_o          : out std_logic;
    result_sequence_o       : out word32_t;
    result_generation_o     : out word32_t;
    result_sample_rate_o    : out word32_t;
    result_window_samples_o : out word32_t;
    result_valid_mask_o     : out std_logic_vector(7 downto 0);
    result_status_o         : out word32_t;
    result_mean_q16_o       : out std_logic_vector(511 downto 0);
    result_rms_q16_o        : out std_logic_vector(511 downto 0);
    result_rms_count_o      : out std_logic_vector(255 downto 0);
    result_drop_count_o     : out word32_t
  );
end entity;

architecture rtl of meter_rms is
  type calc_state_t is (
    CALC_IDLE,
    CALC_PREPARE_MEAN,
    CALC_DIVIDE_MEAN,
    CALC_PREPARE_VARIANCE,
    CALC_FORM_VARIANCE,
    CALC_DIVIDE_VARIANCE,
    CALC_SQRT_MULTIPLY,
    CALC_SQRT_COMPARE
  );
  type signed128_array_t is array (0 to G_CHANNEL_COUNT - 1) of
    signed(127 downto 0);
  type unsigned128_array_t is array (0 to G_CHANNEL_COUNT - 1) of
    unsigned(127 downto 0);
  type signed64_array_t is array (0 to G_CHANNEL_COUNT - 1) of
    signed(63 downto 0);
  type unsigned96_array_t is array (0 to G_CHANNEL_COUNT - 1) of
    unsigned(95 downto 0);

  signal active_generation     : word32_t := (others => '0');
  signal active_sample_rate    : word32_t := std_logic_vector(to_unsigned(32000, 32));
  signal active_window_samples : word32_t := std_logic_vector(to_unsigned(6400, 32));
  signal active_valid_mask     : std_logic_vector(7 downto 0) := (others => '0');
  signal active_enable         : std_logic := '0';
  signal active_dc_remove      : std_logic := '1';
  signal apply_seen            : std_logic := '0';

  signal accumulator_sum       : signed128_array_t := (others => (others => '0'));
  signal accumulator_square    : unsigned128_array_t := (others => (others => '0'));
  signal raw_accumulator_sum   : signed64_array_t := (others => (others => '0'));
  signal raw_accumulator_square: unsigned96_array_t := (others => (others => '0'));
  signal snapshot_sum          : signed128_array_t := (others => (others => '0'));
  signal snapshot_square       : unsigned128_array_t := (others => (others => '0'));
  signal raw_snapshot_sum      : signed64_array_t := (others => (others => '0'));
  signal raw_snapshot_square   : unsigned96_array_t := (others => (others => '0'));
  signal sample_count          : unsigned(31 downto 0) := (others => '0');
  signal snapshot_generation   : word32_t := (others => '0');
  signal snapshot_sample_rate  : word32_t := (others => '0');
  signal snapshot_window       : word32_t := (others => '0');
  signal snapshot_valid_mask   : std_logic_vector(7 downto 0) := (others => '0');
  signal snapshot_dc_remove    : std_logic := '1';

  signal calc_state            : calc_state_t := CALC_IDLE;
  signal calc_channel          : natural range 0 to G_CHANNEL_COUNT - 1 := 0;
  signal calc_raw_mode         : std_logic := '0';
  signal divider_dividend      : unsigned(127 downto 0) := (others => '0');
  signal divider_divisor       : unsigned(127 downto 0) := (others => '0');
  signal divider_quotient      : unsigned(127 downto 0) := (others => '0');
  signal divider_remainder     : unsigned(128 downto 0) := (others => '0');
  signal divider_bit           : natural range 0 to 127 := 127;
  signal mean_negative         : std_logic := '0';
  signal variance_product      : unsigned(159 downto 0) := (others => '0');
  signal variance_sum_square   : unsigned(127 downto 0) := (others => '0');
  signal variance_denominator  : unsigned(63 downto 0) := (others => '0');
  signal variance_sum_too_wide : std_logic := '0';
  signal sqrt_radicand         : unsigned(127 downto 0) := (others => '0');
  signal sqrt_low              : uword64_t := (others => '0');
  signal sqrt_high             : uword64_t := (others => '1');
  signal sqrt_midpoint         : uword64_t := (others => '0');
  signal sqrt_midpoint_square  : unsigned(127 downto 0) := (others => '0');
  signal sqrt_iteration        : natural range 0 to 63 := 0;

  signal result_sequence       : unsigned(31 downto 0) := (others => '0');
  signal result_mean           : sword64_array_t(0 to 7) := (others => (others => '0'));
  signal result_rms            : sword64_array_t(0 to 7) := (others => (others => '0'));
  signal result_rms_count      : word32_array_t(0 to 7) := (others => (others => '0'));
  signal result_valid          : std_logic := '0';
  signal result_generation     : word32_t := (others => '0');
  signal result_sample_rate    : word32_t := (others => '0');
  signal result_window         : word32_t := (others => '0');
  signal result_mask           : std_logic_vector(7 downto 0) := (others => '0');
  signal result_status         : word32_t := (others => '0');
  signal result_drop_count     : unsigned(31 downto 0) := (others => '0');
  signal arithmetic_overflow   : std_logic := '0';
  signal calculation_busy      : std_logic;
  signal configuration_pending : std_logic;
begin
  assert G_FIRST_CHANNEL + G_CHANNEL_COUNT <= 8
    report "meter_rms channel range exceeds the eight-channel frame"
    severity failure;

  -- The broadcaster branches must never be able to stop the sampling stream.
  s_axis_tready <= '1';
  active_generation_o <= active_generation;
  result_valid_o <= result_valid;
  result_sequence_o <= std_logic_vector(result_sequence);
  result_generation_o <= result_generation;
  result_sample_rate_o <= result_sample_rate;
  result_window_samples_o <= result_window;
  result_valid_mask_o <= result_mask;
  result_status_o <= result_status;
  result_drop_count_o <= std_logic_vector(result_drop_count);

  calculation_busy <= '1' when calc_state /= CALC_IDLE else '0';
  configuration_pending <= config_apply_toggle_i xor apply_seen;
  status_o <= (31 downto 4 => '0') & arithmetic_overflow &
              calculation_busy & configuration_pending & active_enable;

  generate_result_lanes : for channel_index in 0 to 7 generate
    result_mean_q16_o((channel_index * 64) + 63 downto channel_index * 64) <=
      std_logic_vector(result_mean(channel_index));
    result_rms_q16_o((channel_index * 64) + 63 downto channel_index * 64) <=
      std_logic_vector(result_rms(channel_index));
    result_rms_count_o((channel_index * 32) + 31 downto channel_index * 32) <=
      result_rms_count(channel_index);
  end generate;

  process (aclk)
    variable sample_value      : sword64_t;
    variable square_value      : unsigned(127 downto 0);
    variable sum_next          : signed128_array_t;
    variable square_next       : unsigned128_array_t;
    variable raw_sample_value  : signed(31 downto 0);
    variable raw_square_value  : unsigned(63 downto 0);
    variable raw_sum_next      : signed64_array_t;
    variable raw_square_next   : unsigned96_array_t;
    variable square_extended   : unsigned(128 downto 0);
    variable window_value      : unsigned(31 downto 0);
    variable absolute_sum      : unsigned(127 downto 0);
    variable numerator         : unsigned(127 downto 0);
    variable remainder_shifted : unsigned(128 downto 0);
    variable divisor_extended  : unsigned(128 downto 0);
    variable quotient_next     : unsigned(127 downto 0);
    variable mean_value        : sword64_t;
    variable midpoint_sum      : unsigned(64 downto 0);
    variable midpoint          : uword64_t;
    variable low_next          : uword64_t;
    variable high_next         : uword64_t;
    variable root_value        : uword64_t;
  begin
    if rising_edge(aclk) then
      if aresetn = '0' then
        active_generation <= (others => '0');
        active_sample_rate <= std_logic_vector(to_unsigned(32000, 32));
        active_window_samples <= std_logic_vector(to_unsigned(6400, 32));
        active_valid_mask <= (others => '0');
        active_enable <= '0';
        active_dc_remove <= '1';
        apply_seen <= '0';
        accumulator_sum <= (others => (others => '0'));
        accumulator_square <= (others => (others => '0'));
        raw_accumulator_sum <= (others => (others => '0'));
        raw_accumulator_square <= (others => (others => '0'));
        sample_count <= (others => '0');
        calc_state <= CALC_IDLE;
        calc_channel <= 0;
        calc_raw_mode <= '0';
        result_sequence <= (others => '0');
        result_mean <= (others => (others => '0'));
        result_rms <= (others => (others => '0'));
        result_rms_count <= (others => (others => '0'));
        result_valid <= '0';
        result_mask <= (others => '0');
        result_status <= (others => '0');
        result_drop_count <= (others => '0');
        arithmetic_overflow <= '0';
      else
        result_valid <= '0';

        if config_apply_toggle_i /= apply_seen then
          active_generation <= config_generation_i;
          active_sample_rate <= config_sample_rate_i;
          active_window_samples <= config_window_samples_i;
          active_valid_mask <= config_valid_mask_i;
          active_enable <= config_enable_i;
          active_dc_remove <= config_dc_remove_i;
          apply_seen <= config_apply_toggle_i;
          accumulator_sum <= (others => (others => '0'));
          accumulator_square <= (others => (others => '0'));
          raw_accumulator_sum <= (others => (others => '0'));
          raw_accumulator_square <= (others => (others => '0'));
          sample_count <= (others => '0');
          calc_state <= CALC_IDLE;
          calc_raw_mode <= '0';
          result_mask <= (others => '0');
          arithmetic_overflow <= '0';
        else
          -- Accumulation runs independently of the result arithmetic state.
          if s_axis_tvalid = '1' and s_axis_tkeep = x"FFFFFFFFFFFFFFFF" and
             active_enable = '1' and
             s_axis_tuser(63 downto 32) = active_generation then
            sum_next := accumulator_sum;
            square_next := accumulator_square;
            raw_sum_next := raw_accumulator_sum;
            raw_square_next := raw_accumulator_square;
            for rms_index in 0 to G_CHANNEL_COUNT - 1 loop
              sample_value := signed(
                s_axis_tdata(((rms_index + G_FIRST_CHANNEL) * 64) + 63
                             downto
                             (rms_index + G_FIRST_CHANNEL) * 64));
              sum_next(rms_index) :=
                accumulator_sum(rms_index) + resize(sample_value, 128);
              square_value := unsigned(sample_value * sample_value);
              square_extended := ('0' & accumulator_square(rms_index)) +
                                 ('0' & square_value);
              if square_extended(128) = '1' then
                square_next(rms_index) := (others => '1');
                arithmetic_overflow <= '1';
              else
                square_next(rms_index) := square_extended(127 downto 0);
              end if;

              raw_sample_value := signed(s_axis_tuser(
                128 + ((rms_index + G_FIRST_CHANNEL) * 32) + 31 downto
                128 + ((rms_index + G_FIRST_CHANNEL) * 32)));
              raw_sum_next(rms_index) := raw_accumulator_sum(rms_index) +
                resize(raw_sample_value, 64);
              raw_square_value := unsigned(raw_sample_value * raw_sample_value);
              raw_square_next(rms_index) := raw_accumulator_square(rms_index) +
                resize(raw_square_value, 96);
            end loop;

            window_value := unsigned(active_window_samples);
            if window_value /= 0 and sample_count + 1 >= window_value then
              if calc_state = CALC_IDLE then
                snapshot_sum <= sum_next;
                snapshot_square <= square_next;
                raw_snapshot_sum <= raw_sum_next;
                raw_snapshot_square <= raw_square_next;
                snapshot_generation <= active_generation;
                snapshot_sample_rate <= active_sample_rate;
                snapshot_window <= active_window_samples;
                snapshot_valid_mask <= active_valid_mask and
                                       s_axis_tuser(71 downto 64);
                snapshot_dc_remove <= active_dc_remove;
                calc_channel <= 0;
                calc_raw_mode <= '0';
                calc_state <= CALC_PREPARE_MEAN;
              else
                result_drop_count <= result_drop_count + 1;
              end if;
              accumulator_sum <= (others => (others => '0'));
              accumulator_square <= (others => (others => '0'));
              raw_accumulator_sum <= (others => (others => '0'));
              raw_accumulator_square <= (others => (others => '0'));
              sample_count <= (others => '0');
            else
              accumulator_sum <= sum_next;
              accumulator_square <= square_next;
              raw_accumulator_sum <= raw_sum_next;
              raw_accumulator_square <= raw_square_next;
              sample_count <= sample_count + 1;
            end if;
          elsif s_axis_tvalid = '1' and active_enable = '1' then
            -- Never mix generations or malformed converted frames in one RMS
            -- window. The next matching frame starts a fresh window.
            accumulator_sum <= (others => (others => '0'));
            accumulator_square <= (others => (others => '0'));
            raw_accumulator_sum <= (others => (others => '0'));
            raw_accumulator_square <= (others => (others => '0'));
            sample_count <= (others => '0');
          end if;

          case calc_state is
            when CALC_IDLE =>
              null;

            when CALC_PREPARE_MEAN =>
              if snapshot_sum(calc_channel)(127) = '1' then
                absolute_sum := unsigned(-snapshot_sum(calc_channel));
                mean_negative <= '1';
              else
                absolute_sum := unsigned(snapshot_sum(calc_channel));
                mean_negative <= '0';
              end if;
              divider_dividend <= absolute_sum;
              divider_divisor <= resize(unsigned(snapshot_window), 128);
              divider_quotient <= (others => '0');
              divider_remainder <= (others => '0');
              divider_bit <= 127;
              calc_state <= CALC_DIVIDE_MEAN;

            when CALC_DIVIDE_MEAN =>
              remainder_shifted := divider_remainder(127 downto 0) &
                                   divider_dividend(divider_bit);
              divisor_extended := '0' & divider_divisor;
              quotient_next := divider_quotient;
              if remainder_shifted >= divisor_extended then
                divider_remainder <= remainder_shifted - divisor_extended;
                quotient_next(divider_bit) := '1';
              else
                divider_remainder <= remainder_shifted;
              end if;
              divider_quotient <= quotient_next;

              if divider_bit = 0 then
                mean_value := signed(quotient_next(63 downto 0));
                if mean_negative = '1' then
                  mean_value := -mean_value;
                end if;
                result_mean(calc_channel + G_FIRST_CHANNEL) <= mean_value;
                calc_state <= CALC_PREPARE_VARIANCE;
              else
                divider_bit <= divider_bit - 1;
              end if;

            when CALC_PREPARE_VARIANCE =>
              if calc_raw_mode = '1' then
                variance_product <= resize(raw_snapshot_square(calc_channel), 128) *
                                    unsigned(snapshot_window);
                if raw_snapshot_sum(calc_channel)(63) = '1' then
                  absolute_sum := resize(unsigned(-raw_snapshot_sum(calc_channel)), 128);
                else
                  absolute_sum := resize(unsigned(raw_snapshot_sum(calc_channel)), 128);
                end if;
              else
                variance_product <= snapshot_square(calc_channel) *
                                    unsigned(snapshot_window);
                if snapshot_sum(calc_channel)(127) = '1' then
                  absolute_sum := unsigned(-snapshot_sum(calc_channel));
                else
                  absolute_sum := unsigned(snapshot_sum(calc_channel));
                end if;
              end if;
              variance_sum_square <= absolute_sum(63 downto 0) *
                                     absolute_sum(63 downto 0);
              if absolute_sum(127 downto 64) /= 0 then
                variance_sum_too_wide <= '1';
              else
                variance_sum_too_wide <= '0';
              end if;
              variance_denominator <= unsigned(snapshot_window) *
                                      unsigned(snapshot_window);
              calc_state <= CALC_FORM_VARIANCE;

            when CALC_FORM_VARIANCE =>
              if variance_product(159 downto 128) /= 0 then
                arithmetic_overflow <= '1';
                numerator := (others => '1');
              else
                numerator := variance_product(127 downto 0);
              end if;

              if snapshot_dc_remove = '1' then
                if variance_sum_too_wide = '1' then
                  arithmetic_overflow <= '1';
                  numerator := (others => '0');
                elsif numerator >= variance_sum_square then
                  numerator := numerator - variance_sum_square;
                else
                  numerator := (others => '0');
                  arithmetic_overflow <= '1';
                end if;
              end if;

              divider_dividend <= numerator;
              divider_divisor <= resize(variance_denominator, 128);
              divider_quotient <= (others => '0');
              divider_remainder <= (others => '0');
              divider_bit <= 127;
              calc_state <= CALC_DIVIDE_VARIANCE;

            when CALC_DIVIDE_VARIANCE =>
              remainder_shifted := divider_remainder(127 downto 0) &
                                   divider_dividend(divider_bit);
              divisor_extended := '0' & divider_divisor;
              quotient_next := divider_quotient;
              if remainder_shifted >= divisor_extended then
                divider_remainder <= remainder_shifted - divisor_extended;
                quotient_next(divider_bit) := '1';
              else
                divider_remainder <= remainder_shifted;
              end if;
              divider_quotient <= quotient_next;

              if divider_bit = 0 then
                sqrt_radicand <= quotient_next;
                sqrt_low <= (others => '0');
                sqrt_high <= (others => '1');
                sqrt_iteration <= 0;
                calc_state <= CALC_SQRT_MULTIPLY;
              else
                divider_bit <= divider_bit - 1;
              end if;

            when CALC_SQRT_MULTIPLY =>
              midpoint_sum := ('0' & sqrt_low) + ('0' & sqrt_high) + 1;
              midpoint := midpoint_sum(64 downto 1);
              sqrt_midpoint <= midpoint;
              sqrt_midpoint_square <= midpoint * midpoint;
              calc_state <= CALC_SQRT_COMPARE;

            when CALC_SQRT_COMPARE =>
              low_next := sqrt_low;
              high_next := sqrt_high;
              if sqrt_midpoint_square <= sqrt_radicand then
                low_next := sqrt_midpoint;
              else
                high_next := sqrt_midpoint - 1;
              end if;
              sqrt_low <= low_next;
              sqrt_high <= high_next;

              if sqrt_iteration = 63 then
                root_value := low_next;
                if calc_raw_mode = '0' then
                  result_rms(calc_channel + G_FIRST_CHANNEL) <=
                    signed(root_value);
                  calc_raw_mode <= '1';
                  calc_state <= CALC_PREPARE_VARIANCE;
                else
                  result_rms_count(calc_channel + G_FIRST_CHANNEL) <=
                    std_logic_vector(root_value(31 downto 0));
                  calc_raw_mode <= '0';
                  if calc_channel = G_CHANNEL_COUNT - 1 then
                    result_sequence <= result_sequence + 1;
                    result_generation <= snapshot_generation;
                    result_sample_rate <= snapshot_sample_rate;
                    result_window <= snapshot_window;
                    result_mask <= snapshot_valid_mask and G_RESULT_MASK;
                    result_status <= (31 downto 1 => '0') & arithmetic_overflow;
                    result_valid <= '1';
                    calc_state <= CALC_IDLE;
                  else
                    calc_channel <= calc_channel + 1;
                    calc_state <= CALC_PREPARE_MEAN;
                  end if;
                end if;
              else
                sqrt_iteration <= sqrt_iteration + 1;
                calc_state <= CALC_SQRT_MULTIPLY;
              end if;
          end case;
        end if;
      end if;
    end if;
  end process;
end architecture;
