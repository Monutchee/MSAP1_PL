library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Exact co-release wire contract shared by the PL shadow exporter and the
-- R5C1 aggregation receiver.  The contract word is an image-integrity guard,
-- not a version-negotiation mechanism: PL and RPU ship as one unit and
-- support exactly the layout compiled into that unit.  Multi-byte
-- fields are transmitted as 32-bit little-endian words; the CRC processes
-- each word least-significant byte first.
package meter_r5_aggregation_pkg is
  constant R5_AGG_MAGIC             : std_logic_vector(31 downto 0) := x"31474741";
  constant R5_AGG_CONTRACT_REVISION : std_logic_vector(31 downto 0) := x"00000001";
  constant R5_AGG_RESULT_WORDS    : positive := 221;
  constant R5_AGG_CONTEXT_WORDS   : positive := 13;
  constant R5_AGG_PAYLOAD_WORDS   : positive := R5_AGG_RESULT_WORDS + R5_AGG_CONTEXT_WORDS;
  constant R5_AGG_HEADER_WORDS    : positive := 4;
  constant R5_AGG_FRAME_WORDS     : positive := R5_AGG_HEADER_WORDS + R5_AGG_PAYLOAD_WORDS + 1;

  constant R5_AGG_CRC_INITIAL     : std_logic_vector(31 downto 0) := x"FFFFFFFF";
  constant R5_AGG_CRC_POLYNOMIAL  : std_logic_vector(31 downto 0) := x"82F63B78";

  function crc32c_update_word(
    crc  : std_logic_vector(31 downto 0);
    word : std_logic_vector(31 downto 0)) return std_logic_vector;

  function saturating_increment(value : unsigned) return unsigned;
end package;

package body meter_r5_aggregation_pkg is
  function crc32c_update_word(
    crc  : std_logic_vector(31 downto 0);
    word : std_logic_vector(31 downto 0)) return std_logic_vector is
    variable next_crc : unsigned(31 downto 0) := unsigned(crc);
    variable byte_v   : unsigned(7 downto 0);
  begin
    for byte_index in 0 to 3 loop
      byte_v := unsigned(word((byte_index + 1) * 8 - 1 downto byte_index * 8));
      next_crc := next_crc xor resize(byte_v, next_crc'length);
      for bit_index in 0 to 7 loop
        if next_crc(0) = '1' then
          next_crc := shift_right(next_crc, 1) xor unsigned(R5_AGG_CRC_POLYNOMIAL);
        else
          next_crc := shift_right(next_crc, 1);
        end if;
      end loop;
    end loop;
    return std_logic_vector(next_crc);
  end function;

  function saturating_increment(value : unsigned) return unsigned is
    variable result : unsigned(value'range) := value;
  begin
    if value /= (value'range => '1') then
      result := value + 1;
    end if;
    return result;
  end function;
end package body;
