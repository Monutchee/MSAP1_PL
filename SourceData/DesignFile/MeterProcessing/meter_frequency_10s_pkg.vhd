library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Exact M20 PL/R5C1 observation contract and Linux-owned boundary tuple.
-- PL never computes an interval frequency. It transports conditioned,
-- linearly interpolated crossing positions and enough provenance for R5C1 to
-- select complete cycles and serialize the public FREQUENCY-10S-v1 record.
package meter_frequency_10s_pkg is
  constant FREQUENCY_10S_MAGIC : std_logic_vector(31 downto 0) := x"31515246";
  constant FREQUENCY_10S_CONTRACT_REVISION : std_logic_vector(31 downto 0) :=
    x"00000001";
  constant FREQUENCY_10S_METADATA_WORDS : positive := 24;
  constant FREQUENCY_10S_CROSSING_CAPACITY : positive := 1024;
  constant FREQUENCY_10S_CROSSING_WORDS : positive :=
    FREQUENCY_10S_CROSSING_CAPACITY * 2;
  constant FREQUENCY_10S_PAYLOAD_WORDS : positive :=
    FREQUENCY_10S_METADATA_WORDS + FREQUENCY_10S_CROSSING_WORDS;
  constant FREQUENCY_10S_FRAME_WORDS : positive :=
    4 + FREQUENCY_10S_PAYLOAD_WORDS + 1;

  constant FREQUENCY_10S_REFERENCE_CHANNEL : natural := 6;
  constant FREQUENCY_10S_FILTER_PROFILE : natural := 1;
  constant FREQUENCY_10S_CALIBRATION_PROFILE : natural := 1;

  constant FREQUENCY_10S_CONTROL_VALID_BIT : natural := 0;
  constant FREQUENCY_10S_CONTROL_TIME_SYNCHRONIZED_BIT : natural := 1;

  constant FREQUENCY_10S_STATUS_BOUNDARY_VALID_BIT : natural := 0;
  constant FREQUENCY_10S_STATUS_TIME_SYNCHRONIZED_BIT : natural := 1;
  constant FREQUENCY_10S_STATUS_SAMPLE_RATE_VALID_BIT : natural := 2;
  constant FREQUENCY_10S_STATUS_FILTER_READY_BIT : natural := 3;
  constant FREQUENCY_10S_STATUS_REFERENCE_VALID_BIT : natural := 4;
  constant FREQUENCY_10S_STATUS_SOURCE_DISCONTINUITY_BIT : natural := 5;
  constant FREQUENCY_10S_STATUS_CROSSING_OVERFLOW_BIT : natural := 6;
  constant FREQUENCY_10S_STATUS_OBSERVER_DROP_BIT : natural := 7;
  constant FREQUENCY_10S_STATUS_RESYNCHRONIZED_BIT : natural := 8;
  constant FREQUENCY_10S_STATUS_CALIBRATION_VALID_BIT : natural := 9;
  constant FREQUENCY_10S_STATUS_PROFILE_SUPPORTED_BIT : natural := 10;

  constant FREQUENCY_10S_REASON_UNSUPPORTED_PROFILE_BIT : natural := 0;
  constant FREQUENCY_10S_REASON_TIME_UNSYNCHRONIZED_BIT : natural := 1;
  constant FREQUENCY_10S_REASON_TIME_UNCERTAINTY_BIT : natural := 2;
  constant FREQUENCY_10S_REASON_FILTER_WARMUP_BIT : natural := 3;
  constant FREQUENCY_10S_REASON_REFERENCE_INVALID_BIT : natural := 4;
  constant FREQUENCY_10S_REASON_DISCONTINUITY_BIT : natural := 5;
  constant FREQUENCY_10S_REASON_CROSSING_OVERFLOW_BIT : natural := 6;
  constant FREQUENCY_10S_REASON_OBSERVER_DROP_BIT : natural := 7;
  constant FREQUENCY_10S_REASON_SAMPLE_RATE_INVALID_BIT : natural := 8;
  constant FREQUENCY_10S_REASON_BOUNDARY_INVALID_BIT : natural := 9;
  constant FREQUENCY_10S_REASON_CALIBRATION_INVALID_BIT : natural := 10;

  constant FREQUENCY_10S_GUARD_BEFORE_START_BIT : natural := 0;
  constant FREQUENCY_10S_GUARD_AFTER_END_BIT : natural := 1;
  constant FREQUENCY_10S_GUARD_EXACT_START_BIT : natural := 2;
  constant FREQUENCY_10S_GUARD_EXACT_END_BIT : natural := 3;

  -- Waveform AXI-Lite offsets (base 0xB0070000). The tuple is written to the
  -- shadow bank, then CONTROL.UPDATE toggles one coherent handoff.
  constant FREQUENCY_10S_REG_START_SAMPLE_LOW : natural := 16#50#;
  constant FREQUENCY_10S_REG_START_SAMPLE_HIGH : natural := 16#54#;
  constant FREQUENCY_10S_REG_END_SAMPLE_LOW : natural := 16#58#;
  constant FREQUENCY_10S_REG_END_SAMPLE_HIGH : natural := 16#5C#;
  constant FREQUENCY_10S_REG_UTC_START_LOW : natural := 16#60#;
  constant FREQUENCY_10S_REG_UTC_START_HIGH : natural := 16#64#;
  constant FREQUENCY_10S_REG_UTC_END_LOW : natural := 16#68#;
  constant FREQUENCY_10S_REG_UTC_END_HIGH : natural := 16#6C#;
  constant FREQUENCY_10S_REG_UNCERTAINTY_LOW : natural := 16#70#;
  constant FREQUENCY_10S_REG_UNCERTAINTY_HIGH : natural := 16#74#;
  constant FREQUENCY_10S_REG_MEASURED_RATE_MILLIHZ : natural := 16#78#;
  constant FREQUENCY_10S_REG_BOUNDARY_GENERATION : natural := 16#7C#;
  constant FREQUENCY_10S_REG_PROFILE : natural := 16#80#;
  constant FREQUENCY_10S_REG_CONTROL : natural := 16#84#;
  constant FREQUENCY_10S_REG_OBSERVER_STATUS : natural := 16#88#;
  constant FREQUENCY_10S_REG_COMPLETED_COUNT : natural := 16#8C#;
  constant FREQUENCY_10S_REG_DROPPED_COUNT : natural := 16#90#;
  constant FREQUENCY_10S_REG_OVERFLOW_COUNT : natural := 16#94#;
  constant FREQUENCY_10S_REG_DISCONTINUITY_COUNT : natural := 16#98#;

  type frequency_10s_boundary_t is record
    start_sample : std_logic_vector(63 downto 0);
    end_sample : std_logic_vector(63 downto 0);
    utc_start_nanoseconds : std_logic_vector(63 downto 0);
    utc_end_nanoseconds : std_logic_vector(63 downto 0);
    utc_uncertainty_nanoseconds : std_logic_vector(63 downto 0);
    measured_sample_rate_millihz : std_logic_vector(31 downto 0);
    boundary_generation : std_logic_vector(31 downto 0);
    profile : std_logic_vector(31 downto 0);
    control : std_logic_vector(31 downto 0);
  end record;

  constant FREQUENCY_10S_BOUNDARY_RESET : frequency_10s_boundary_t := (
    start_sample => (others => '0'),
    end_sample => (others => '0'),
    utc_start_nanoseconds => (others => '0'),
    utc_end_nanoseconds => (others => '0'),
    utc_uncertainty_nanoseconds => (others => '0'),
    measured_sample_rate_millihz => (others => '0'),
    boundary_generation => (others => '0'),
    profile => (others => '0'),
    control => (others => '0'));

  type frequency_10s_crossing_memory_t is array
    (0 to FREQUENCY_10S_CROSSING_CAPACITY - 1) of signed(63 downto 0);
end package;
