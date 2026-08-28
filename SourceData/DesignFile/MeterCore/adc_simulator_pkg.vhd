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
--   0x00010002  four global harmonic slots (order, channel mask, Q16
--               fraction of the fundamental, phase); harmonic angles
--               scale the lane offset by the order (physical 3-phase
--               relationship)
--   0x00010003  hardware event sequencer: a timed amplitude envelope on a
--               channel mask, armed by its own trigger register and
--               started/stopped on the generator's own half-cycle
--               boundaries, so sag/swell/interruption scenarios are
--               phase-continuous by construction (metrology M12)
--   0x00010004  harmonic slots use a Q16.16 frequency ratio, allowing
--               integer harmonics through order 127 and fractional
--               interharmonic tones without changing the four-slot model
package adc_simulator_pkg is
  constant ADC_SIMULATOR_ID      : std_logic_vector(31 downto 0) := x"53494D31"; -- SIM1
  constant ADC_SIMULATOR_VERSION : std_logic_vector(31 downto 0) := x"00010004";

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
  -- Four spectral-tone slots, three words each (mirrors
  -- sim_wave_engine.hpp): word0 = frequency/order ratio Q16.16; word1 =
  -- channel mask[7:0] | reserved[15:8] | Q16 fraction[31:16]; word2 =
  -- phase, Q0.32 turns. A zero ratio disables the slot.
  constant ADC_SIM_REG_SHADOW_HARMONIC_BASE : natural := 16#200#;
  constant ADC_SIM_REG_ACTIVE_HARMONIC_BASE : natural := 16#240#;

  -- Event sequencer (M12). Its own shadow bank and its own trigger, held
  -- apart from the waveform APPLY on purpose: an event must be launchable
  -- against a steady configuration without committing anything else.
  constant ADC_SIM_REG_SHADOW_EVENT_CONTROL : natural := 16#300#;
  constant ADC_SIM_REG_SHADOW_EVENT_SCALE   : natural := 16#304#;
  constant ADC_SIM_REG_SHADOW_EVENT_TIMING  : natural := 16#308#;
  constant ADC_SIM_REG_EVENT_TRIGGER        : natural := 16#30C#;
  constant ADC_SIM_REG_EVENT_STATUS         : natural := 16#310#;
  constant ADC_SIM_REG_EVENT_REMAINING      : natural := 16#314#;
  constant ADC_SIM_REG_ACTIVE_EVENT_CONTROL : natural := 16#318#;
  constant ADC_SIM_REG_ACTIVE_EVENT_SCALE   : natural := 16#31C#;
  constant ADC_SIM_REG_ACTIVE_EVENT_TIMING  : natural := 16#320#;

  -- CONTROL register bits (shadow and active banks share the layout).
  constant ADC_SIM_CONTROL_SOURCE_BIT         : natural := 0;
  constant ADC_SIM_CONTROL_ENABLE_BIT         : natural := 1;
  -- When set at APPLY, the phase accumulator, fractional scheduler, and
  -- packet framing survive the commit: the waveform continues seamlessly
  -- under the new configuration instead of restarting from 0 degrees and
  -- packet frame 0. Prerequisite for runtime scenario changes (sag/swell
  -- events) that must not inject phase discontinuities.
  constant ADC_SIM_CONTROL_PRESERVE_PHASE_BIT : natural := 2;

  -- EVENT_CONTROL layout: which channels the envelope multiplies, and
  -- whether the burst repeats on its programmed period.
  constant ADC_SIM_EVENT_MASK_LSB   : natural := 0;   -- [7:0]
  constant ADC_SIM_EVENT_REPEAT_BIT : natural := 8;

  -- EVENT_SCALE: unsigned Q16 amplitude multiplier applied to the peak of
  -- every masked channel while the burst runs. 0x00010000 is unity (a
  -- no-op envelope), 0 is a full interruption, 0x0000E666 a 10 % sag,
  -- 0x00011999 a 10 % swell. Clamped at 4.0 on commit; the scale rides on
  -- the PEAK, so injected harmonics (a fraction of the peak) scale with
  -- the fundamental exactly as a real dip scales a distorted waveform,
  -- while DC offset and noise -- ADC artifacts, not grid quantities --
  -- do not.
  constant ADC_SIM_EVENT_SCALE_UNITY : natural := 16#10000#;
  constant ADC_SIM_EVENT_SCALE_MAX   : natural := 16#40000#;

  -- EVENT_TIMING: burst duration in HALF CYCLES [15:0] (0 disarms the
  -- trigger; half-cycle resolution because Urms(1/2) refreshes every half
  -- cycle) and, for a repeating burst, the period in half cycles [31:16]
  -- measured from one burst's start to the next. A period at or below the
  -- duration runs the bursts back to back (effective period =
  -- duration + 1).
  constant ADC_SIM_EVENT_DURATION_LSB : natural := 0;
  constant ADC_SIM_EVENT_PERIOD_LSB   : natural := 16;

  -- EVENT_TRIGGER write-only strobes (the register reads back zero).
  -- ARM latches the shadow event bank and starts the burst at the next
  -- half-cycle boundary of the generator's own phase accumulator, so the
  -- envelope never injects a phase discontinuity. CANCEL drops the
  -- envelope immediately -- an operator abort, not a scheduled end.
  constant ADC_SIM_EVENT_TRIGGER_ARM_BIT    : natural := 0;
  constant ADC_SIM_EVENT_TRIGGER_CANCEL_BIT : natural := 1;
  constant ADC_SIM_EVENT_TRIGGER_CLEAR_BIT  : natural := 2;

  -- EVENT_STATUS: bit 0 armed (waiting for the boundary), bit 1 running,
  -- bit 2 holding between repeats, [31:16] bursts completed.
  constant ADC_SIM_EVENT_STATUS_ARMED_BIT   : natural := 0;
  constant ADC_SIM_EVENT_STATUS_RUNNING_BIT : natural := 1;
  constant ADC_SIM_EVENT_STATUS_HOLDING_BIT : natural := 2;
  constant ADC_SIM_EVENT_STATUS_COUNT_LSB   : natural := 16;

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
  constant SIM_WAVE_REQ_HARMONIC_LSB    : natural := 1152;
  constant SIM_WAVE_HARMONIC_WORDS      : natural := 12;
  -- Event envelope word: [18:0] Q16 scale, [31:24] channel mask.
  constant SIM_WAVE_REQ_EVENT_LSB       : natural := 1536;
  constant SIM_WAVE_REQ_EVENT_SCALE_LSB : natural := 1536;
  constant SIM_WAVE_REQ_EVENT_MASK_LSB  : natural := 1560;
  constant SIM_WAVE_REQ_BITS            : natural := 1568;
  constant SIM_WAVE_RSP_SAMPLE_LSB      : natural := 0;
  constant SIM_WAVE_RSP_SATURATED_LSB   : natural := 256;
  constant SIM_WAVE_RSP_BITS            : natural := 264;
end package;

package body adc_simulator_pkg is
end package body;
