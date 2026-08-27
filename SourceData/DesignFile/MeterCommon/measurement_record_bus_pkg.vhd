library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Measurement record geometry and register-offset contract.
--
-- Record wire formats and shared metrology contracts are normative in C++:
--   SourceData/HLS_DesignFile/common/include/measurement_record.hpp
--   SourceData/HLS_DesignFile/common/include/single_cycle_packet.hpp
-- R5C1 owns interval aggregation and record serialization; the retired VHDL
-- record bus lives in git history.
--
-- This package keeps only what VHDL still consumes: the fixed record
-- geometry (the DMA-ring framing invariant, observed by
-- record_word_tap.vhd) and the AXI-Lite offsets of the aggregation
-- health registers (meter_processing_axi_regs.vhd).
package measurement_record_bus_pkg is
  -- Fixed record geometry shared by every producer: one cyclic-DMA
  -- period carries exactly one 256-byte record (msap1_dma_meter.c), so
  -- every record is 64 x 32-bit AXIS beats with TLAST on beat 63, always.
  constant MEASUREMENT_RECORD_WORDS : positive := 64;
  constant MEASUREMENT_RECORD_BITS  : positive := 2048;

  -- Processing AXI-Lite offsets for aggregate health (base 0xB0050000).
  -- These legacy PL aggregation registers remain mapped for software
  -- compatibility but read zero now that R5C1 owns interval records.
  constant AGG_REG_STATUS            : natural := 16#78#;
  constant AGG_REG_RECORD_COUNT      : natural := 16#7C#;
  constant AGG_REG_RESET_COUNT       : natural := 16#80#;
  constant AGG_REG_INELIGIBLE_COUNT  : natural := 16#84#;
  constant AGG_REG_CONTINUITY_COUNT  : natural := 16#88#;
  constant AGG_REG_DROP_COUNT        : natural := 16#8C#;

  -- AGG_STATUS layout retained for register-map compatibility.
  constant AGG_STATUS_BLOCKS_LSB   : natural := 0;
  constant AGG_STATUS_ACTIVE_BIT   : natural := 8;

  -- Retained diagnostics from the compared-pair trial (read-only).
  --   RECORD_COUNT:   reads zero.
  --   MISMATCH_COUNT: reserved, reads zero (the RTL reference engine and
  --                   its compare block retired after the trial).
  --   DROP_COUNT:     SingleCycle shim result-packet drops; any nonzero value
  --                   is a fault.
  constant HLS_AGG_REG_RECORD_COUNT   : natural := 16#90#;
  constant HLS_AGG_REG_MISMATCH_COUNT : natural := 16#94#;
  constant HLS_AGG_REG_DROP_COUNT     : natural := 16#98#;

  -- Private PL -> R5C1 aggregation-export diagnostics. These
  -- counters describe the exact co-release transport only; they do not
  -- participate in measurement validity and cannot backpressure metrology.
  -- 0xA0..0xAC belongs to the power-quality event block.  Keep this
  -- diagnostic window contiguous above it so independent package constants
  -- cannot alias in the AXI-Lite read decoder.
  constant R5_AGG_EXPORT_REG_STATUS            : natural := 16#B0#;
  constant R5_AGG_EXPORT_REG_ACCEPTED_COUNT    : natural := 16#B4#;
  constant R5_AGG_EXPORT_REG_DROPPED_COUNT     : natural := 16#B8#;
  constant R5_AGG_EXPORT_REG_TRANSMITTED_COUNT : natural := 16#BC#;
  constant R5_AGG_EXPORT_REG_FRAMING_ERRORS    : natural := 16#C0#;
  constant R5_AGG_EXPORT_REG_LAST_SEQUENCE     : natural := 16#C4#;
  constant R5_AGG_EXPORT_REG_QUEUE_LEVEL       : natural := 16#C8#;

  -- M16 spectral-path diagnostics.  All counters are read-only, saturating,
  -- and observational; they never backpressure capture or the other meter
  -- producers.  A nonzero service/drop/malformed/structural-fault counter is
  -- a failed integration or soak gate.  Channel-halt counters are separate
  -- edge-counted backpressure diagnostics and do not invalidate spectra.
  constant HARMONIC_REG_CONDITIONED_BLOCKS  : natural := 16#CC#;
  constant HARMONIC_REG_INVALID_BLOCKS      : natural := 16#D0#;
  constant HARMONIC_REG_SERVICE_OVERRUNS    : natural := 16#D4#;
  constant HARMONIC_REG_FRONTEND_COMPLETED  : natural := 16#D8#;
  constant HARMONIC_REG_FRONTEND_DROPPED    : natural := 16#DC#;
  constant HARMONIC_REG_FRONTEND_MALFORMED  : natural := 16#E0#;
  constant HARMONIC_REG_XFFT_FAULT_COUNT    : natural := 16#E4#;
  constant HARMONIC_REG_XFFT_DATA_IN_HALTS  : natural := 16#E8#;
  constant HARMONIC_REG_XFFT_DATA_OUT_HALTS : natural := 16#EC#;
  constant HARMONIC_REG_XFFT_STATUS_HALTS   : natural := 16#F0#;
end package;
