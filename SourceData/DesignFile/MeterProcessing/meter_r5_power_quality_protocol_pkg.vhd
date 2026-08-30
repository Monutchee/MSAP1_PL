library ieee;
use ieee.std_logic_1164.all;

-- Exact co-release power-quality packets between MeterCore and R5C1. All use
-- the AGG1/HRM1 four-word header and CRC32C convention and are arbitrated only
-- at TLAST boundaries.
package meter_r5_power_quality_protocol_pkg is
  -- Fixed RPMsg-v10 PL-facing power-quality configuration image. R5C0 writes it
  -- through the processing block's indexed F4/F8 window before toggling the
  -- shared APPLY bit. Engines sample it only on APPLY, so no measurement can
  -- observe a partially staged profile.
  constant M18_CONFIG_WORDS : positive := 79;
  type m18_config_words_t is array (0 to M18_CONFIG_WORDS - 1) of
    std_logic_vector(31 downto 0);
  constant M18_CONFIG_GENERATION_WORD       : natural := 0;
  constant M18_CONFIG_EVENT_COUNT_WORD      : natural := 1;
  constant M18_CONFIG_REFERENCE_CURRENT_WORD: natural := 2;
  constant M18_CONFIG_REFERENCE_VOLTAGE_WORD: natural := 3;
  constant M18_CONFIG_EVENT_BASE_WORD        : natural := 4;
  constant M18_CONFIG_EVENT_STRIDE_WORDS     : natural := 7;
  constant M18_CONFIG_EVENT_PROFILE_COUNT    : natural := 9;
  constant M18_CONFIG_FLICKER_FLAGS_WORD      : natural := 67;
  constant M18_CONFIG_FLICKER_PHASE_MASK_WORD : natural := 68;
  constant M18_CONFIG_FLICKER_LAMP_WORD       : natural := 69;
  constant M18_CONFIG_FLICKER_LIVE_MS_WORD    : natural := 70;
  constant M18_CONFIG_FLICKER_PST_SECONDS_WORD: natural := 71;
  constant M18_CONFIG_FLICKER_PLT_COUNT_WORD  : natural := 72;
  constant M18_CONFIG_MAINS_FLAGS_WORD        : natural := 73;
  constant M18_CONFIG_MAINS_CARRIER_WORD      : natural := 74;
  constant M18_CONFIG_MAINS_BANDWIDTH_WORD    : natural := 75;
  constant M18_CONFIG_MAINS_OBSERVATION_WORD  : natural := 76;
  constant M18_CONFIG_MAINS_PHASE_MASK_WORD   : natural := 77;
  constant M18_CONFIG_MAINS_THRESHOLD_WORD    : natural := 78;
  constant M18_ENGINE_ENABLED_BIT              : natural := 0;

  constant M18_REG_CONFIG_INDEX  : natural := 16#F4#;
  constant M18_REG_CONFIG_DATA   : natural := 16#F8#;
  constant M18_REG_CONFIG_STATUS : natural := 16#FC#;

  constant R5_PQE_MAGIC : std_logic_vector(31 downto 0) := x"31455150"; -- PQE1
  constant R5_VSB_MAGIC : std_logic_vector(31 downto 0) := x"31425356"; -- VSB1
  constant R5_M18_CONTRACT_REVISION : std_logic_vector(31 downto 0) :=
    x"00000001";
  constant R5_VSB_CONTRACT_REVISION : std_logic_vector(31 downto 0) :=
    x"00000001";
  constant R5_M18_HEADER_WORDS : positive := 4;
  constant R5_M18_CRC_WORDS : positive := 1;
  constant R5_PQE_PAYLOAD_WORDS : positive := 64;
  constant R5_VSB_PAYLOAD_WORDS : positive := 1038;
  constant R5_PQE_FRAME_WORDS : positive :=
    R5_M18_HEADER_WORDS + R5_PQE_PAYLOAD_WORDS + R5_M18_CRC_WORDS;
  constant R5_VSB_FRAME_WORDS : positive :=
    R5_M18_HEADER_WORDS + R5_VSB_PAYLOAD_WORDS + R5_M18_CRC_WORDS;

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

  -- VSB1 payload words. PL transports one shared batch of 256 consecutive
  -- voltage frames to R5C1 for both the flicker and mains-signalling engines.
  -- Each frame is VA/VB/VC as signed integer microvolts followed by one flags
  -- word. Flicker-specific profile metadata remains in the fixed header so the
  -- flickermeter can validate its staged configuration; mains signalling uses
  -- the same generation, sample-rate, phase availability, and raw samples.
  constant R5_VSB_SEQUENCE_WORD          : natural := 0;
  constant R5_VSB_GENERATION_WORD        : natural := 1;
  constant R5_VSB_SAMPLE_RATE_WORD       : natural := 2;
  constant R5_VSB_FRAME_CAPACITY_WORD    : natural := 3;
  constant R5_VSB_PHASE_MASK_WORD        : natural := 4;
  constant R5_VSB_MODEL_WORD             : natural := 5;
  constant R5_VSB_TIMING_WORD            : natural := 6;
  constant R5_VSB_REFERENCE_UV_WORD       : natural := 7;
  constant R5_VSB_FIRST_SAMPLE_LOW_WORD  : natural := 8;
  constant R5_VSB_FIRST_SAMPLE_HIGH_WORD : natural := 9;
  constant R5_VSB_SAMPLE_BASE_WORD        : natural := 10;
  constant R5_VSB_BATCH_FRAMES            : positive := 256;
  constant R5_VSB_WORDS_PER_FRAME         : positive := 4;
  constant R5_VSB_ACTUAL_COUNT_WORD       : natural := 1034;
  constant R5_VSB_BATCH_STATUS_WORD       : natural := 1035;
  constant R5_VSB_LAST_SAMPLE_LOW_WORD    : natural := 1036;
  constant R5_VSB_LAST_SAMPLE_HIGH_WORD   : natural := 1037;

  -- Packed-frame flags occupy payload frame word 3 bits 6:0.
  constant R5_VSB_SAMPLE_VALID_A_BIT      : natural := 0;
  constant R5_VSB_SAMPLE_VALID_B_BIT      : natural := 1;
  constant R5_VSB_SAMPLE_VALID_C_BIT      : natural := 2;
  constant R5_VSB_SAMPLE_MALFORMED_BIT    : natural := 3;
  constant R5_VSB_SAMPLE_LOCKED_BIT       : natural := 4;
  constant R5_VSB_SAMPLE_FALLBACK_BIT     : natural := 5;
  constant R5_VSB_SAMPLE_SATURATED_BIT    : natural := 6;

  constant R5_VSB_BATCH_DISCONTINUITY_BIT : natural := 0;
  constant R5_VSB_BATCH_SOURCE_DROP_BIT   : natural := 1;
end package;

package body meter_r5_power_quality_protocol_pkg is
end package body;
