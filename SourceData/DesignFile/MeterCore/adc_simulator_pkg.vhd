library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Shared register and stream definitions for the raw ADC simulator.
-- Phases use unsigned Q0.32 turns: 0x00000000 is 0 degrees and
-- 0x80000000 is 180 degrees. Peak and DC-offset values are signed 24-bit
-- ADC counts in 32-bit words.
--
-- Version history:
--   0x00010000  original inline-VHDL sine datapath (8-bit LUT index)
--   0x00010001  waveform math moved to the packaged HLS engine
--               (hls_sim_wave_engine): interpolated quarter-wave sine,
--               per-channel DC offset and uniform noise fluctuation,
--               preserve-phase APPLY, counter clears, 12-bit register
--               decode
package adc_simulator_pkg is
  constant ADC_SIMULATOR_ID      : std_logic_vector(31 downto 0) := x"53494D31"; -- SIM1
  constant ADC_SIMULATOR_VERSION : std_logic_vector(31 downto 0) := x"00010001";

  constant ADC_SIM_REG_ID                 : natural := 16#00#;
  constant ADC_SIM_REG_VERSION            : natural := 16#04#;
  constant ADC_SIM_REG_SHADOW_CONTROL     : natural := 16#08#;
  constant ADC_SIM_REG_SHADOW_SAMPLE_RATE : natural := 16#0C#;
  constant ADC_SIM_REG_SHADOW_FREQUENCY   : natural := 16#10#;
  constant ADC_SIM_REG_SHADOW_VALID_MASK  : natural := 16#14#;
  constant ADC_SIM_REG_SHADOW_GENERATION  : natural := 16#18#;
  constant ADC_SIM_REG_APPLY              : natural := 16#1C#;
  constant ADC_SIM_REG_STATUS             : natural := 16#20#;
  constant ADC_SIM_REG_ACTIVE_SAMPLE_RATE : natural := 16#24#;
  constant ADC_SIM_REG_ACTIVE_FREQUENCY   : natural := 16#28#;
  constant ADC_SIM_REG_ACTIVE_VALID_MASK  : natural := 16#2C#;
  constant ADC_SIM_REG_ACTIVE_GENERATION  : natural := 16#30#;
  constant ADC_SIM_REG_FRAME_COUNT        : natural := 16#34#;
  constant ADC_SIM_REG_SATURATION_COUNT   : natural := 16#38#;
  constant ADC_SIM_REG_MISSED_SAMPLE_COUNT : natural := 16#3C#;
  constant ADC_SIM_REG_SHADOW_PEAK_BASE   : natural := 16#40#;
  constant ADC_SIM_REG_SHADOW_PHASE_BASE  : natural := 16#60#;
  constant ADC_SIM_REG_SHADOW_PHASE_STEP  : natural := 16#80#;
  constant ADC_SIM_REG_ACTIVE_CONTROL     : natural := 16#84#;
  constant ADC_SIM_REG_ACTIVE_PHASE_STEP  : natural := 16#88#;
  constant ADC_SIM_REG_SHADOW_DC_BASE     : natural := 16#8C#;
  constant ADC_SIM_REG_COUNTER_CLEAR      : natural := 16#AC#;
  constant ADC_SIM_REG_ACTIVE_DC_BASE     : natural := 16#B0#;
  constant ADC_SIM_REG_SHADOW_NOISE_BASE  : natural := 16#D0#;
  constant ADC_SIM_REG_ACTIVE_NOISE_BASE  : natural := 16#100#;

  -- CONTROL register bits (shadow and active banks share the layout).
  constant ADC_SIM_CONTROL_SOURCE_BIT         : natural := 0;
  constant ADC_SIM_CONTROL_ENABLE_BIT         : natural := 1;
  -- When set at APPLY, the phase accumulator, fractional scheduler, and
  -- packet framing survive the commit: the waveform continues seamlessly
  -- under the new configuration instead of restarting from 0 degrees and
  -- packet frame 0. Prerequisite for runtime scenario changes (sag/swell
  -- events) that must not inject phase discontinuities.
  constant ADC_SIM_CONTROL_PRESERVE_PHASE_BIT : natural := 2;

  -- COUNTER_CLEAR write-1-to-clear strobes. A clear coincident with the
  -- same counter's increment discards that one event; the register exists
  -- for per-scenario bookkeeping, not for lossless accounting.
  constant ADC_SIM_CLEAR_SATURATION_BIT : natural := 0;
  constant ADC_SIM_CLEAR_MISSED_BIT     : natural := 1;
  constant ADC_SIM_CLEAR_FRAME_BIT      : natural := 2;

  -- Waveform-engine beat layout, kept in lock step with the normative
  -- definitions in HLS_DesignFile/MeterCore/SimWaveEngine/src/
  -- sim_wave_engine.hpp. The VHDL packs one request per due frame from
  -- the ACTIVE bank; the engine returns one frame of eight samples plus
  -- per-channel saturation flags.
  constant SIM_WAVE_CHANNELS            : natural := 8;
  constant SIM_WAVE_REQ_BASE_PHASE_LSB  : natural := 0;
  constant SIM_WAVE_REQ_VALID_MASK_LSB  : natural := 32;
  constant SIM_WAVE_REQ_FRAME_INDEX_LSB : natural := 64;
  constant SIM_WAVE_REQ_PEAK_LSB        : natural := 128;
  constant SIM_WAVE_REQ_PHASE_LSB       : natural := 384;
  constant SIM_WAVE_REQ_DC_LSB          : natural := 640;
  constant SIM_WAVE_REQ_NOISE_LSB       : natural := 896;
  constant SIM_WAVE_REQ_BITS            : natural := 1152;
  constant SIM_WAVE_RSP_SAMPLE_LSB      : natural := 0;
  constant SIM_WAVE_RSP_SATURATED_LSB   : natural := 256;
  constant SIM_WAVE_RSP_BITS            : natural := 264;
end package;

package body adc_simulator_pkg is
end package body;
