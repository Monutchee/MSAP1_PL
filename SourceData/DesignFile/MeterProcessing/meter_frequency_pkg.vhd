library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Shared frequency-measurement definitions.
--
-- Frequency is reported in millihertz. Crossing timestamps use Q16 sample
-- units: the integer part identifies a converted ADC frame and the fractional
-- part is the linearly interpolated position of the zero crossing.
package meter_frequency_pkg is
  subtype frequency_word_t is std_logic_vector(31 downto 0);
  subtype crossing_timestamp_t is unsigned(47 downto 0);

  constant FREQUENCY_MODE_SINGLE_CYCLE  : std_logic_vector(2 downto 0) := "000";
  constant FREQUENCY_MODE_ROLLING_CYCLES: std_logic_vector(2 downto 0) := "001";
  constant FREQUENCY_MODE_ROLLING_TIME  : std_logic_vector(2 downto 0) := "010";

  constant FREQUENCY_REFERENCE_VLA : natural := 6;

  -- Processing AXI-Lite offsets. Keeping the software-visible layout beside
  -- the fixed-point definitions makes future producers share one contract.
  constant FREQUENCY_REG_SHADOW_CONTROL         : natural := 16#30#;
  constant FREQUENCY_REG_SHADOW_WINDOW_SAMPLES  : natural := 16#34#;
  constant FREQUENCY_REG_SHADOW_MINIMUM_MILLIHZ : natural := 16#38#;
  constant FREQUENCY_REG_SHADOW_MAXIMUM_MILLIHZ : natural := 16#3C#;
  constant FREQUENCY_REG_SHADOW_HYSTERESIS_UV   : natural := 16#40#;
  constant FREQUENCY_REG_ACTIVE_CONTROL         : natural := 16#44#;
  constant FREQUENCY_REG_ACTIVE_WINDOW_SAMPLES  : natural := 16#48#;
  constant FREQUENCY_REG_ACTIVE_MINIMUM_MILLIHZ : natural := 16#4C#;
  constant FREQUENCY_REG_ACTIVE_MAXIMUM_MILLIHZ : natural := 16#50#;
  constant FREQUENCY_REG_ACTIVE_HYSTERESIS_UV   : natural := 16#54#;
  constant FREQUENCY_REG_STATUS                 : natural := 16#58#;
  constant FREQUENCY_REG_VALUE_MILLIHZ          : natural := 16#5C#;
  constant FREQUENCY_REG_PERIOD_Q16_SAMPLES     : natural := 16#60#;
  constant FREQUENCY_REG_MEASUREMENT_SEQUENCE   : natural := 16#64#;
  constant FREQUENCY_REG_REJECTED_COUNT         : natural := 16#68#;

  constant MTR1_FREQUENCY_VALUE_WORD    : natural := 56;
  constant MTR1_FREQUENCY_STATUS_WORD   : natural := 57;
  constant MTR1_FREQUENCY_PERIOD_WORD   : natural := 58;
  constant MTR1_FREQUENCY_SEQUENCE_WORD : natural := 59;

  constant FREQUENCY_STATUS_ENABLED          : natural := 0;
  constant FREQUENCY_STATUS_VALID            : natural := 1;
  constant FREQUENCY_STATUS_REFERENCE_VALID  : natural := 2;
  constant FREQUENCY_STATUS_ARMED            : natural := 3;
  constant FREQUENCY_STATUS_MEASURING        : natural := 4;
  constant FREQUENCY_STATUS_OUT_OF_RANGE     : natural := 5;
  constant FREQUENCY_STATUS_TIMEOUT          : natural := 6;
  constant FREQUENCY_STATUS_ARITHMETIC_ERROR : natural := 7;

  type frequency_configuration_t is record
    enabled                : std_logic;
    mode                   : std_logic_vector(2 downto 0);
    reference_channel      : std_logic_vector(3 downto 0);
    averaging_cycles       : std_logic_vector(7 downto 0);
    averaging_window_samples: frequency_word_t;
    minimum_millihz        : frequency_word_t;
    maximum_millihz        : frequency_word_t;
    hysteresis_microvolts  : frequency_word_t;
  end record;

  type frequency_result_t is record
    value_millihz       : frequency_word_t;
    status              : frequency_word_t;
    period_q16_samples  : frequency_word_t;
    measurement_sequence: frequency_word_t;
  end record;

  function pack_frequency_control(
    enabled          : std_logic;
    mode             : std_logic_vector(2 downto 0);
    reference_channel: std_logic_vector(3 downto 0);
    averaging_cycles : std_logic_vector(7 downto 0)
  ) return std_logic_vector;

  -- A 32-bit sample index plus 16 fractional bits naturally wraps at 2^48.
  -- Subtracting in that domain keeps elapsed intervals correct when the
  -- capture sequence rolls from 0xffffffff to zero.
  function elapsed_q16_samples(
    current_timestamp : unsigned(63 downto 0);
    earlier_timestamp : unsigned(63 downto 0)
  ) return unsigned;
end package;

package body meter_frequency_pkg is
  function pack_frequency_control(
    enabled          : std_logic;
    mode             : std_logic_vector(2 downto 0);
    reference_channel: std_logic_vector(3 downto 0);
    averaging_cycles : std_logic_vector(7 downto 0)
  ) return std_logic_vector is
    variable result : std_logic_vector(31 downto 0) := (others => '0');
  begin
    result(0) := enabled;
    result(3 downto 1) := mode;
    result(7 downto 4) := reference_channel;
    result(15 downto 8) := averaging_cycles;
    return result;
  end function;

  function elapsed_q16_samples(
    current_timestamp : unsigned(63 downto 0);
    earlier_timestamp : unsigned(63 downto 0)
  ) return unsigned is
    variable wrapped_elapsed : crossing_timestamp_t;
  begin
    wrapped_elapsed :=
      current_timestamp(47 downto 0) - earlier_timestamp(47 downto 0);
    return resize(wrapped_elapsed, 64);
  end function;
end package body;
