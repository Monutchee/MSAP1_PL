library ieee;
use ieee.std_logic_1164.all;

-- Private co-release PL -> R5C1 harmonic-family transport. The payload is the
-- exact 42 x 64-word HARMONIC-v1 family; only the surrounding HRM1 packet is
-- private. Linux measurement records never use this framing.
package meter_r5_harmonic_pkg is
  constant R5_HARMONIC_MAGIC             : std_logic_vector(31 downto 0) := x"314D5248"; -- "HRM1"
  constant R5_HARMONIC_CONTRACT_REVISION : std_logic_vector(31 downto 0) := x"00000001";
  constant R5_HARMONIC_RECORD_WORDS      : positive := 64;
  constant R5_HARMONIC_RECORDS_PER_FAMILY: positive := 42;
  constant R5_HARMONIC_PAYLOAD_WORDS     : positive :=
    R5_HARMONIC_RECORD_WORDS * R5_HARMONIC_RECORDS_PER_FAMILY;
  constant R5_HARMONIC_HEADER_WORDS      : positive := 4;
  constant R5_HARMONIC_FRAME_WORDS       : positive :=
    R5_HARMONIC_HEADER_WORDS + R5_HARMONIC_PAYLOAD_WORDS + 1;
end package;
