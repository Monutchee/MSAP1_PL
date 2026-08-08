library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.metering_pkg.all;

-- Shared grid-cycle timing definitions for IEC 61000-4-30 basic measurement
-- blocks.
--
-- A basic measurement block is cycle-defined, not time-defined:
--   nominal 50 Hz -> 10 complete grid cycles per block
--   nominal 60 Hz -> 12 complete grid cycles per block
-- The nominal duration is approximately 200 ms, but the block boundary is
-- always derived from zero crossings; the configured sample-count window is
-- only the free-run fallback used while the voltage reference is unusable.
--
-- Keeping the software-visible register layout and the MTR1 word map beside
-- the packing helpers makes PL, RPU, and APU share one contract.
package grid_timing_pkg is
  -- Processing AXI-Lite offsets (base 0xB0050000). The shadow value commits
  -- on the same CONTROL apply toggle as the RMS and frequency configuration
  -- so one basic block can never span two configuration generations.
  constant GRID_REG_SHADOW_CONFIG : natural := 16#6C#;
  constant GRID_REG_ACTIVE_CONFIG : natural := 16#70#;
  constant GRID_REG_STATUS        : natural := 16#74#;

  -- GRID_*_CONFIG layout:
  --   [7:0]  cycles per basic block (10 or 12)
  --   [15:8] declared nominal grid frequency in Hz (50 or 60)
  --   [16]   cycle timing enable
  constant GRID_CONFIG_CYCLES_LSB  : natural := 0;
  constant GRID_CONFIG_NOMINAL_LSB : natural := 8;
  constant GRID_CONFIG_ENABLE_BIT  : natural := 16;

  -- GRID_STATUS layout:
  --   [0]    locked: block boundaries currently derive from zero crossings
  --   [1]    reference channel usable on the most recent frame
  --   [2]    cycle timing enabled (active configuration)
  --   [15:8] complete cycles counted in the current open block
  constant GRID_STATUS_LOCKED_BIT     : natural := 0;
  constant GRID_STATUS_REFERENCE_BIT  : natural := 1;
  constant GRID_STATUS_ENABLED_BIT    : natural := 2;
  constant GRID_STATUS_CYCLES_LSB     : natural := 8;

  constant GRID_CYCLES_50HZ : natural := 10;
  constant GRID_CYCLES_60HZ : natural := 12;

  -- MTR1 format 2 (word 1 = 0x00010002) additions. Word 6 carries the actual
  -- sample count of the block; these words carry the remaining provenance.
  --   word 15: [7:0] nominal Hz, [15:8] cycle count,
  --            [16] cycle_locked, [17] free_run_fallback,
  --            [18] first_block_after_apply
  --   words 60/61: first sample index of the block, low/high 32 bits.
  -- The last sample index is intentionally not recorded:
  -- last = first + count - 1.
  constant MTR1_FORMAT_V2 : word32_t := x"00010002";
  constant MTR1_TIMING_WORD            : natural := 15;
  constant MTR1_FIRST_SAMPLE_LOW_WORD  : natural := 60;
  constant MTR1_FIRST_SAMPLE_HIGH_WORD : natural := 61;
  constant MTR1_TIMING_NOMINAL_LSB     : natural := 0;
  constant MTR1_TIMING_CYCLES_LSB      : natural := 8;
  constant MTR1_TIMING_LOCKED_BIT      : natural := 16;
  constant MTR1_TIMING_FALLBACK_BIT    : natural := 17;
  constant MTR1_TIMING_FIRST_BLOCK_BIT : natural := 18;

  -- Closed-block flag vector shared between grid_cycle_timing and the hub.
  constant GRID_BLOCK_FLAG_LOCKED      : natural := 0;
  constant GRID_BLOCK_FLAG_FALLBACK    : natural := 1;
  constant GRID_BLOCK_FLAG_FIRST_BLOCK : natural := 2;

  function pack_grid_config(
    cycles_per_block : natural;
    nominal_hz       : natural;
    enable           : std_logic
  ) return word32_t;

  -- Reset default: 60 Hz nominal, 12 cycles, cycle timing enabled. The RMS
  -- engine is disabled until software configures it, so the default only
  -- determines behaviour between reset and the first apply.
  constant GRID_CONFIG_DEFAULT : word32_t;
end package;

package body grid_timing_pkg is
  function pack_grid_config(
    cycles_per_block : natural;
    nominal_hz       : natural;
    enable           : std_logic
  ) return word32_t is
    variable result : word32_t := (others => '0');
  begin
    result(7 downto 0) := std_logic_vector(to_unsigned(cycles_per_block, 8));
    result(15 downto 8) := std_logic_vector(to_unsigned(nominal_hz, 8));
    result(GRID_CONFIG_ENABLE_BIT) := enable;
    return result;
  end function;

  constant GRID_CONFIG_DEFAULT : word32_t :=
    pack_grid_config(GRID_CYCLES_60HZ, 60, '1');
end package body;
