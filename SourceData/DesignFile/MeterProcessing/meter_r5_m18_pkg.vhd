library ieee;
use ieee.std_logic_1164.all;

-- Exact co-release M18 private packets. All use the AGG1/HRM1 four-word
-- header and CRC32C convention and are arbitrated only at TLAST boundaries.
package meter_r5_m18_pkg is
  constant R5_PQE_MAGIC : std_logic_vector(31 downto 0) := x"31455150"; -- PQE1
  constant R5_FLK_MAGIC : std_logic_vector(31 downto 0) := x"314B4C46"; -- FLK1
  constant R5_MCS_MAGIC : std_logic_vector(31 downto 0) := x"3153434D"; -- MCS1
  constant R5_M18_CONTRACT_REVISION : std_logic_vector(31 downto 0) :=
    x"00000001";
  constant R5_M18_HEADER_WORDS : positive := 4;
  constant R5_M18_CRC_WORDS : positive := 1;
  constant R5_PQE_PAYLOAD_WORDS : positive := 64;
  constant R5_FLK_PAYLOAD_WORDS : positive := 64;
  constant R5_MCS_PAYLOAD_WORDS : positive := 20;
  constant R5_PQE_FRAME_WORDS : positive :=
    R5_M18_HEADER_WORDS + R5_PQE_PAYLOAD_WORDS + R5_M18_CRC_WORDS;
  constant R5_FLK_FRAME_WORDS : positive :=
    R5_M18_HEADER_WORDS + R5_FLK_PAYLOAD_WORDS + R5_M18_CRC_WORDS;
  constant R5_MCS_FRAME_WORDS : positive :=
    R5_M18_HEADER_WORDS + R5_MCS_PAYLOAD_WORDS + R5_M18_CRC_WORDS;
end package;

package body meter_r5_m18_pkg is
end package body;
