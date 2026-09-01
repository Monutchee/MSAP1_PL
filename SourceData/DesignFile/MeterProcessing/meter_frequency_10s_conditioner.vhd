library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.metering_pkg.all;
use work.meter_frequency_10s_pkg.all;

-- Fixed linear-phase conditioner for the Class-A ten-second observer.
--
-- Production uses a third-order CIC decimator by 128 followed by the
-- symmetric binomial FIR (1 + z^-1)^20 / 2^20 at 1 kSPS. The CIC is itself a
-- symmetric FIR in its equivalent form. The exact combined group delay is
-- removed from the sample timestamp, so downstream interpolation remains in
-- the conversion-domain sample coordinate system.
entity meter_frequency_10s_conditioner is
  generic (
    G_DECIMATION : positive := 128;
    G_CIC_GAIN_SHIFT : natural := 21;
    G_WARMUP_OUTPUTS : positive := 24
  );
  port (
    aclk : in std_logic;
    aresetn : in std_logic;
    frame_accept_i : in std_logic;
    frame_data_i : in std_logic_vector(METER_CONVERTED_FRAME_BITS - 1 downto 0);
    frame_keep_i : in std_logic_vector(METER_CONVERTED_KEEP_BITS - 1 downto 0);
    frame_user_i : in std_logic_vector(383 downto 0);
    config_generation_i : in std_logic_vector(31 downto 0);
    config_apply_toggle_i : in std_logic;
    measured_frame_rate_valid_i : in std_logic;

    sample_valid_o : out std_logic;
    sample_microvolts_o : out signed(31 downto 0);
    sample_index_o : out unsigned(63 downto 0);
    sample_fraction_q16_o : out unsigned(15 downto 0);
    filter_ready_o : out std_logic;
    reference_valid_o : out std_logic;
    discontinuity_pulse_o : out std_logic
  );
end entity;

architecture rtl of meter_frequency_10s_conditioner is
  type fir_history_t is array (0 to 20) of signed(63 downto 0);
  type fir_coefficient_t is array (0 to 20) of natural;
  constant C_FIR_COEFFICIENT : fir_coefficient_t := (
    1, 20, 190, 1140, 4845, 15504, 38760, 77520, 125970, 167960,
    184756, 167960, 125970, 77520, 38760, 15504, 4845, 1140, 190,
    20, 1);
  constant C_FILTER_DELAY_TWICE : positive := 23 * G_DECIMATION - 3;
  constant C_FILTER_DELAY_CEIL : natural :=
    (C_FILTER_DELAY_TWICE + 1) / 2;
  constant C_FILTER_DELAY_HALF : boolean :=
    (C_FILTER_DELAY_TWICE mod 2) = 1;

  subtype fir_product_t is signed(95 downto 0);

  signal apply_seen : std_logic := '0';
  signal rate_valid_seen : std_logic := '0';
  signal have_index : std_logic := '0';
  signal last_index : unsigned(63 downto 0) := (others => '0');
  signal decimation_count : natural range 0 to G_DECIMATION - 1 := 0;
  signal integrator_1 : signed(63 downto 0) := (others => '0');
  signal integrator_2 : signed(63 downto 0) := (others => '0');
  signal integrator_3 : signed(63 downto 0) := (others => '0');
  signal comb_delay_1 : signed(63 downto 0) := (others => '0');
  signal comb_delay_2 : signed(63 downto 0) := (others => '0');
  signal comb_delay_3 : signed(63 downto 0) := (others => '0');
  signal fir_history : fir_history_t := (others => (others => '0'));
  signal fir_accumulator : fir_product_t := (others => '0');
  signal fir_index : natural range 0 to 20 := 0;
  signal fir_busy : std_logic := '0';
  signal fir_timestamp : unsigned(63 downto 0) := (others => '0');
  signal warmup_outputs : natural range 0 to G_WARMUP_OUTPUTS := 0;
  signal output_valid : std_logic := '0';
  signal output_sample : signed(31 downto 0) := (others => '0');
  signal output_index : unsigned(63 downto 0) := (others => '0');
  signal filter_ready : std_logic := '0';
  signal reference_valid : std_logic := '0';
  signal discontinuity_pulse : std_logic := '0';
begin
  assert G_WARMUP_OUTPUTS >= 21
    report "frequency conditioner warmup must cover the complete FIR"
    severity failure;

  sample_valid_o <= output_valid;
  sample_microvolts_o <= output_sample;
  sample_index_o <= output_index;
  sample_fraction_q16_o <= to_unsigned(32768, 16) when C_FILTER_DELAY_HALF
                           else (others => '0');
  filter_ready_o <= filter_ready;
  reference_valid_o <= reference_valid;
  discontinuity_pulse_o <= discontinuity_pulse;

  process (aclk)
    variable input_valid : boolean;
    variable reset_filter : boolean;
    variable current_index : unsigned(63 downto 0);
    variable input_sample : signed(31 downto 0);
    variable i1_next : signed(63 downto 0);
    variable i2_next : signed(63 downto 0);
    variable i3_next : signed(63 downto 0);
    variable comb_1 : signed(63 downto 0);
    variable comb_2 : signed(63 downto 0);
    variable comb_3 : signed(63 downto 0);
    variable cic_sample : signed(63 downto 0);
    variable product : fir_product_t;
    variable total : fir_product_t;
    variable normalized : fir_product_t;
  begin
    if rising_edge(aclk) then
      output_valid <= '0';
      discontinuity_pulse <= '0';
      reset_filter := false;

      if aresetn = '0' then
        apply_seen <= '0';
        rate_valid_seen <= '0';
        have_index <= '0';
        last_index <= (others => '0');
        decimation_count <= 0;
        integrator_1 <= (others => '0');
        integrator_2 <= (others => '0');
        integrator_3 <= (others => '0');
        comb_delay_1 <= (others => '0');
        comb_delay_2 <= (others => '0');
        comb_delay_3 <= (others => '0');
        fir_history <= (others => (others => '0'));
        fir_accumulator <= (others => '0');
        fir_index <= 0;
        fir_busy <= '0';
        fir_timestamp <= (others => '0');
        warmup_outputs <= 0;
        output_sample <= (others => '0');
        output_index <= (others => '0');
        filter_ready <= '0';
        reference_valid <= '0';
      else
        if config_apply_toggle_i /= apply_seen then
          apply_seen <= config_apply_toggle_i;
          reset_filter := true;
        end if;
        if measured_frame_rate_valid_i /= rate_valid_seen then
          rate_valid_seen <= measured_frame_rate_valid_i;
          reset_filter := true;
        end if;

        if fir_busy = '1' then
          product := fir_history(fir_index) *
            to_signed(C_FIR_COEFFICIENT(fir_index), 32);
          total := fir_accumulator + product;
          if fir_index = 20 then
            normalized := shift_right(total, 20);
            if normalized > resize(signed'(x"7FFFFFFF"), normalized'length) then
              output_sample <= signed'(x"7FFFFFFF");
            elsif normalized < resize(signed'(x"80000000"), normalized'length) then
              output_sample <= signed'(x"80000000");
            else
              output_sample <= normalized(31 downto 0);
            end if;
            if fir_timestamp >= to_unsigned(C_FILTER_DELAY_CEIL, 64) and
               warmup_outputs = G_WARMUP_OUTPUTS then
              output_index <= fir_timestamp - C_FILTER_DELAY_CEIL;
              output_valid <= '1';
              filter_ready <= '1';
            end if;
            fir_busy <= '0';
            fir_index <= 0;
          else
            fir_accumulator <= total;
            fir_index <= fir_index + 1;
          end if;
        end if;

        if frame_accept_i = '1' then
          current_index(63 downto 32) := unsigned(frame_user_i(
            TUSER_SAMPLE_INDEX_HIGH_MSB downto
            TUSER_SAMPLE_INDEX_HIGH_LSB));
          current_index(31 downto 0) := unsigned(frame_user_i(
            TUSER_SAMPLE_INDEX_LOW_MSB downto
            TUSER_SAMPLE_INDEX_LOW_LSB));
          input_valid := frame_keep_i = (frame_keep_i'range => '1') and
            frame_user_i(63 downto 32) = config_generation_i and
            frame_user_i(64 + FREQUENCY_10S_REFERENCE_CHANNEL) = '1' and
            measured_frame_rate_valid_i = '1';
          if have_index = '1' and current_index /= last_index + 1 then
            input_valid := false;
          end if;
          if input_valid then
            reference_valid <= '1';
          else
            reference_valid <= '0';
          end if;
          last_index <= current_index;
          have_index <= '1';

          if not input_valid then
            reset_filter := true;
          elsif not reset_filter then
            input_sample := signed(frame_data_i(
              FREQUENCY_10S_REFERENCE_CHANNEL * METER_CONVERTED_LANE_BITS + 47
              downto FREQUENCY_10S_REFERENCE_CHANNEL *
                METER_CONVERTED_LANE_BITS + 16));
            i1_next := integrator_1 + resize(input_sample, 64);
            i2_next := integrator_2 + i1_next;
            i3_next := integrator_3 + i2_next;
            integrator_1 <= i1_next;
            integrator_2 <= i2_next;
            integrator_3 <= i3_next;

            if decimation_count = G_DECIMATION - 1 then
              decimation_count <= 0;
              comb_1 := i3_next - comb_delay_1;
              comb_2 := comb_1 - comb_delay_2;
              comb_3 := comb_2 - comb_delay_3;
              comb_delay_1 <= i3_next;
              comb_delay_2 <= comb_1;
              comb_delay_3 <= comb_2;
              cic_sample := shift_right(comb_3, G_CIC_GAIN_SHIFT);

              if fir_busy = '1' then
                reset_filter := true;
              else
                for index in 20 downto 1 loop
                  fir_history(index) <= fir_history(index - 1);
                end loop;
                fir_history(0) <= cic_sample;
                fir_accumulator <= cic_sample *
                  to_signed(C_FIR_COEFFICIENT(0), 32);
                fir_index <= 1;
                fir_busy <= '1';
                fir_timestamp <= current_index;
                if warmup_outputs < G_WARMUP_OUTPUTS then
                  warmup_outputs <= warmup_outputs + 1;
                end if;
              end if;
            else
              decimation_count <= decimation_count + 1;
            end if;
          end if;
        end if;

        if reset_filter then
          decimation_count <= 0;
          integrator_1 <= (others => '0');
          integrator_2 <= (others => '0');
          integrator_3 <= (others => '0');
          comb_delay_1 <= (others => '0');
          comb_delay_2 <= (others => '0');
          comb_delay_3 <= (others => '0');
          fir_history <= (others => (others => '0'));
          fir_accumulator <= (others => '0');
          fir_index <= 0;
          fir_busy <= '0';
          warmup_outputs <= 0;
          filter_ready <= '0';
          output_valid <= '0';
          discontinuity_pulse <= '1';
        end if;
      end if;
    end if;
  end process;
end architecture;
