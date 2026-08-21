library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.metering_pkg.all;

-- Shared power-quality event definitions for the IEC 61000-4-30 Urms(1/2)
-- sliding measurement (metrology roadmap M12).
--
-- Urms(1/2) is the RMS over ONE grid cycle, refreshed every HALF cycle and
-- resynchronized to half-cycle boundaries. It is the standard's detection
-- quantity for voltage dips (sags), swells, and interruptions: the event
-- threshold is a fraction of a declared reference voltage, an event begins
-- when ANY monitored phase crosses the threshold, and ends only when EVERY
-- phase has recovered past the threshold plus its hysteresis.
--
-- Keeping the software-visible register layout beside the engine's contract
-- makes PL, RPU, and APU share one definition, exactly like
-- grid_timing_pkg.vhd does for basic-block timing.
package pq_event_pkg is
  -- Processing AXI-Lite offsets (base 0xB0050000), above the grid and
  -- health windows. The shadow values commit on the same CONTROL apply
  -- toggle as the RMS, frequency, and grid configuration, so one event
  -- evaluation can never straddle two configuration generations.
  constant PQ_REG_SHADOW_REFERENCE : natural := 16#A0#;
  constant PQ_REG_SHADOW_THRESHOLD : natural := 16#A4#;
  constant PQ_REG_SHADOW_LIMITS    : natural := 16#A8#;
  constant PQ_REG_STATUS           : natural := 16#AC#;

  -- PQ_SHADOW_REFERENCE: declared reference voltage Udin in MICROVOLTS.
  -- ZERO DISABLES EVENT DETECTION: the engine keeps publishing periodic
  -- Urms(1/2) snapshots but never declares an event, so a system whose
  -- reference has not been configured yet cannot invent dips. The APU
  -- writes the value from the conversion profile's nominal voltage.
  constant PQ_REFERENCE_DISABLED : natural := 0;

  -- PQ_SHADOW_THRESHOLD layout (fractions of the reference, in units of
  -- 1e-4, so 9000 = 90.00 %):
  --   [15:0]  sag / dip threshold      (default 90 %)
  --   [31:16] swell threshold          (default 110 %)
  constant PQ_THRESHOLD_SAG_LSB   : natural := 0;
  constant PQ_THRESHOLD_SWELL_LSB : natural := 16;

  -- PQ_SHADOW_LIMITS layout, same 1e-4 units:
  --   [15:0]  interruption threshold   (default 10 %)
  --   [31:16] hysteresis               (default 2 %)
  constant PQ_LIMITS_INTERRUPT_LSB  : natural := 0;
  constant PQ_LIMITS_HYSTERESIS_LSB : natural := 16;

  constant PQ_SAG_DEFAULT_E4        : natural := 9000;
  constant PQ_SWELL_DEFAULT_E4      : natural := 11000;
  constant PQ_INTERRUPT_DEFAULT_E4  : natural := 1000;
  constant PQ_HYSTERESIS_DEFAULT_E4 : natural := 200;

  -- PQ_STATUS layout (read-only, "as of the last half-cycle update"):
  --   [0]     an event is in progress
  --   [3:1]   event type of the event in progress (PQ_EVENT_*)
  --   [10:8]  phase mask of the phases currently outside their band
  --   [31:16] saturating count of completed events since reset
  constant PQ_STATUS_ACTIVE_BIT   : natural := 0;
  constant PQ_STATUS_TYPE_LSB     : natural := 1;
  constant PQ_STATUS_PHASES_LSB   : natural := 8;
  constant PQ_STATUS_COUNT_LSB    : natural := 16;

  -- Event type codes; mirrored by the HLS engine (metering_types.hpp) and
  -- the APU decoder. A single event keeps the most severe type it reached,
  -- so a dip that deepens into an interruption reports as an interruption.
  -- Record kinds carried in the PQ record's format-header word; mirrored
  -- from metering_types.hpp (MET_PQ_KIND_*).
  constant PQ_KIND_PERIODIC    : natural := 0;
  constant PQ_KIND_EVENT_START : natural := 1;
  constant PQ_KIND_EVENT_END   : natural := 2;

  constant PQ_EVENT_NONE         : natural := 0;
  constant PQ_EVENT_SAG          : natural := 1;
  constant PQ_EVENT_SWELL        : natural := 2;
  constant PQ_EVENT_INTERRUPTION : natural := 3;

  constant PQ_THRESHOLD_DEFAULT : word32_t;
  constant PQ_LIMITS_DEFAULT    : word32_t;
end package;

package body pq_event_pkg is
  constant PQ_THRESHOLD_DEFAULT : word32_t :=
    std_logic_vector(to_unsigned(PQ_SWELL_DEFAULT_E4, 16)) &
    std_logic_vector(to_unsigned(PQ_SAG_DEFAULT_E4, 16));
  constant PQ_LIMITS_DEFAULT : word32_t :=
    std_logic_vector(to_unsigned(PQ_HYSTERESIS_DEFAULT_E4, 16)) &
    std_logic_vector(to_unsigned(PQ_INTERRUPT_DEFAULT_E4, 16));
end package body;
