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

  -- PQE1 payload words. RMS values are unsigned Q16 micro-units; each u64 is
  -- low word first. Validity packs voltage A/B/C in bits 0..2 and current
  -- A/B/C in bits 8..10. Words 30..63 are reserved zero in revision 1.
  constant R5_PQE_SEQUENCE_WORD          : natural := 0;
  constant R5_PQE_GENERATION_WORD        : natural := 1;
  constant R5_PQE_SAMPLE_RATE_WORD       : natural := 2;
  constant R5_PQE_STATUS_WORD            : natural := 3;
  constant R5_PQE_VALID_PHASES_WORD      : natural := 4;
  constant R5_PQE_WINDOW_SAMPLES_WORD    : natural := 5;
  constant R5_PQE_FIRST_SAMPLE_LOW_WORD  : natural := 6;
  constant R5_PQE_FIRST_SAMPLE_HIGH_WORD : natural := 7;
  constant R5_PQE_LAST_SAMPLE_LOW_WORD   : natural := 8;
  constant R5_PQE_LAST_SAMPLE_HIGH_WORD  : natural := 9;
  constant R5_PQE_PL_TICK_LOW_WORD       : natural := 10;
  constant R5_PQE_PL_TICK_HIGH_WORD      : natural := 11;
  constant R5_PQE_URMS_Q16_BASE_WORD     : natural := 12;
  constant R5_PQE_IRMS_Q16_BASE_WORD     : natural := 18;
  constant R5_PQE_REFERENCE_WORD         : natural := 24;
  constant R5_PQE_SAG_THRESHOLD_WORD     : natural := 25;
  constant R5_PQE_SWELL_THRESHOLD_WORD   : natural := 26;
  constant R5_PQE_INTERRUPT_THRESHOLD_WORD : natural := 27;
  constant R5_PQE_HYSTERESIS_WORD        : natural := 28;
  constant R5_PQE_APPLY_WORD             : natural := 29;
end package;

package body meter_r5_m18_pkg is
end package body;
