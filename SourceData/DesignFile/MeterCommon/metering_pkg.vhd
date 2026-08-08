library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package metering_pkg is
  constant METER_CHANNEL_COUNT : positive := 8;

  subtype word32_t is std_logic_vector(31 downto 0);
  subtype sword64_t is signed(63 downto 0);
  subtype uword64_t is unsigned(63 downto 0);

  -- Converted-frame TUSER layout (384 bits, one beat per 8-channel frame).
  -- The 64-bit free-running sample index is split so bits 31:0 keep their
  -- original position: existing consumers of the low word stay unchanged
  -- while the high word rides in a previously unused TUSER region.
  --
  --   [31:0]    sample index, low word (was the 32-bit sample sequence)
  --   [63:32]   active configuration generation
  --   [71:64]   valid channel mask
  --   [72]      saturation sticky flag
  --   [73]      source-packet TLAST
  --   [105:74]  sample index, high word
  --   [127:106] unused
  --   [383:128] eight raw 32-bit ADC words (waveform branch)
  constant TUSER_SAMPLE_INDEX_LOW_LSB  : natural := 0;
  constant TUSER_SAMPLE_INDEX_LOW_MSB  : natural := 31;
  constant TUSER_SAMPLE_INDEX_HIGH_LSB : natural := 74;
  constant TUSER_SAMPLE_INDEX_HIGH_MSB : natural := 105;

  type word32_array_t is array (natural range <>) of word32_t;
  type sword64_array_t is array (natural range <>) of sword64_t;
  type uword128_array_t is array (natural range <>) of unsigned(127 downto 0);

  function apply_write_strobes(
    current_value : word32_t;
    write_value   : word32_t;
    write_strobe  : std_logic_vector(3 downto 0)
  ) return word32_t;

  function saturate_signed_66_to_64(value : signed(65 downto 0)) return sword64_t;
end package;

package body metering_pkg is
  function apply_write_strobes(
    current_value : word32_t;
    write_value   : word32_t;
    write_strobe  : std_logic_vector(3 downto 0)
  ) return word32_t is
    variable result : word32_t := current_value;
  begin
    for byte_index in 0 to 3 loop
      if write_strobe(byte_index) = '1' then
        result((byte_index * 8) + 7 downto byte_index * 8) :=
          write_value((byte_index * 8) + 7 downto byte_index * 8);
      end if;
    end loop;
    return result;
  end function;

  function saturate_signed_66_to_64(value : signed(65 downto 0)) return sword64_t is
    variable result : sword64_t;
  begin
    if value(65 downto 63) = "000" or value(65 downto 63) = "111" then
      result := value(63 downto 0);
    elsif value(65) = '0' then
      result := signed'(x"7FFFFFFFFFFFFFFF");
    else
      result := signed'(x"8000000000000000");
    end if;
    return result;
  end function;
end package body;
