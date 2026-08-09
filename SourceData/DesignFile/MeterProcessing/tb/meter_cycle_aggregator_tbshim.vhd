library ieee;
use ieee.std_logic_1164.all;

library work;
use work.metering_pkg.all;
use work.measurement_record_bus_pkg.all;

-- Test-only shim: exposes meter_cycle_aggregator's basic-result record
-- port as scalar ports so the SystemVerilog unit testbench can drive it
-- (mixed-language boundaries cannot carry VHDL records). Not part of the
-- production hierarchy.
entity meter_cycle_aggregator_tbshim is
  port (
    aclk    : in std_logic;
    aresetn : in std_logic;

    basic_valid_i         : in std_logic;
    basic_sequence_i      : in word32_t;
    basic_generation_i    : in word32_t;
    basic_sample_rate_i   : in word32_t;
    basic_sample_count_i  : in word32_t;
    basic_valid_mask_i    : in std_logic_vector(7 downto 0);
    basic_status_i        : in word32_t;
    basic_rms_q16_i       : in std_logic_vector(511 downto 0);
    basic_first_sample_i  : in std_logic_vector(63 downto 0);
    basic_cycle_count_i   : in std_logic_vector(7 downto 0);
    basic_nominal_hz_i    : in std_logic_vector(7 downto 0);
    basic_flags_i         : in std_logic_vector(2 downto 0);
    basic_freq_millihz_i  : in word32_t;
    basic_freq_valid_i    : in std_logic;
    config_apply_toggle_i : in std_logic;

    aggregate_valid_o        : out std_logic;
    aggregate_sequence_o     : out word32_t;
    aggregate_generation_o   : out word32_t;
    aggregate_sample_rate_o  : out word32_t;
    aggregate_samples_o      : out word32_t;
    aggregate_valid_mask_o   : out std_logic_vector(7 downto 0);
    aggregate_arithmetic_o   : out std_logic;
    aggregate_freq_valid_o   : out std_logic;
    aggregate_first_seq_o    : out word32_t;
    aggregate_last_seq_o     : out word32_t;
    aggregate_nominal_o      : out std_logic_vector(7 downto 0);
    aggregate_cycles_o       : out std_logic_vector(15 downto 0);
    aggregate_first_sample_o : out std_logic_vector(63 downto 0);
    aggregate_rms_q16_o      : out std_logic_vector(511 downto 0);
    aggregate_freq_millihz_o : out word32_t;
    status_o                 : out word32_t;
    record_count_o           : out word32_t;
    reset_count_o            : out word32_t;
    ineligible_count_o       : out word32_t;
    continuity_count_o       : out word32_t
  );
end entity;

architecture rtl of meter_cycle_aggregator_tbshim is
  signal basic_result : basic_measurement_result_t;
begin
  basic_result.valid <= basic_valid_i;
  basic_result.result_sequence <= basic_sequence_i;
  basic_result.generation <= basic_generation_i;
  basic_result.sample_rate_hz <= basic_sample_rate_i;
  basic_result.sample_count <= basic_sample_count_i;
  basic_result.valid_mask <= basic_valid_mask_i;
  basic_result.status <= basic_status_i;
  basic_result.rms_q16 <= basic_rms_q16_i;
  basic_result.first_sample <= basic_first_sample_i;
  basic_result.cycle_count <= basic_cycle_count_i;
  basic_result.nominal_hz <= basic_nominal_hz_i;
  basic_result.flags <= basic_flags_i;
  basic_result.frequency_millihz <= basic_freq_millihz_i;
  basic_result.frequency_valid <= basic_freq_valid_i;

  aggregator : entity work.meter_cycle_aggregator
    port map (
      aclk => aclk,
      aresetn => aresetn,
      basic_i => basic_result,
      config_apply_toggle_i => config_apply_toggle_i,
      aggregate_valid_o => aggregate_valid_o,
      aggregate_sequence_o => aggregate_sequence_o,
      aggregate_generation_o => aggregate_generation_o,
      aggregate_sample_rate_o => aggregate_sample_rate_o,
      aggregate_samples_o => aggregate_samples_o,
      aggregate_valid_mask_o => aggregate_valid_mask_o,
      aggregate_arithmetic_o => aggregate_arithmetic_o,
      aggregate_freq_valid_o => aggregate_freq_valid_o,
      aggregate_first_seq_o => aggregate_first_seq_o,
      aggregate_last_seq_o => aggregate_last_seq_o,
      aggregate_nominal_o => aggregate_nominal_o,
      aggregate_cycles_o => aggregate_cycles_o,
      aggregate_first_sample_o => aggregate_first_sample_o,
      aggregate_rms_q16_o => aggregate_rms_q16_o,
      aggregate_freq_millihz_o => aggregate_freq_millihz_o,
      status_o => status_o,
      record_count_o => record_count_o,
      reset_count_o => reset_count_o,
      ineligible_count_o => ineligible_count_o,
      continuity_count_o => continuity_count_o
    );
end architecture;
