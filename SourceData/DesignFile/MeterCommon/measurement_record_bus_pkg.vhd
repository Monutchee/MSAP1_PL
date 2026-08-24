library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Measurement record geometry and register-offset contract.
--
-- Since the HLS rewrite (feat/hls_mtr1) the record wire formats, the
-- basic-result beat, and every engine contract are normative in C++:
--   SourceData/HLS_DesignFile/common/include/measurement_record.hpp
--   SourceData/HLS_DesignFile/common/include/basic_result_beat.hpp
--   SourceData/HLS_DesignFile/MeterProcessing/<engine>/src/*.hpp
-- Both producers (MTR1 engine, 150/180-cycle aggregator) build and
-- serialize their own 256-byte records; the retired VHDL record bus
-- (hub/arbiter/packetizer and the wide record type) lives in git history.
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
  -- The engines carry their counters inside their records
  -- (measurement_record.hpp words 3/8/11/12 and 33..35), republished by
  -- record_word_tap, so these registers are "as of the last emitted
  -- record", not live.
  constant AGG_REG_STATUS            : natural := 16#78#;
  constant AGG_REG_RECORD_COUNT      : natural := 16#7C#;
  constant AGG_REG_RESET_COUNT       : natural := 16#80#;
  constant AGG_REG_INELIGIBLE_COUNT  : natural := 16#84#;
  constant AGG_REG_CONTINUITY_COUNT  : natural := 16#88#;
  constant AGG_REG_DROP_COUNT        : natural := 16#8C#;

  -- AGG_STATUS layout, retained for the register map: the HLS engines
  -- expose no live open-aggregate view, so the register reads zero;
  -- liveness shows through AGG_RECORD_COUNT advancing.
  constant AGG_STATUS_BLOCKS_LSB   : natural := 0;
  constant AGG_STATUS_ACTIVE_BIT   : natural := 8;

  -- Retained diagnostics from the compared-pair trial (read-only).
  --   RECORD_COUNT:   mirrors AGG_REG_RECORD_COUNT.
  --   MISMATCH_COUNT: reserved, reads zero (the RTL reference engine and
  --                   its compare block retired after the trial).
  --   DROP_COUNT:     sample beats the MTR1 shim's FIFO had to discard
  --                   because the engine was still finalizing (impossible
  --                   at real rates; any nonzero value is a fault).
  constant HLS_AGG_REG_RECORD_COUNT   : natural := 16#90#;
  constant HLS_AGG_REG_MISMATCH_COUNT : natural := 16#94#;
  constant HLS_AGG_REG_DROP_COUNT     : natural := 16#98#;

  -- Private PL -> R5C1 aggregation shadow-export diagnostics.  These
  -- counters describe the exact co-release transport only; they do not
  -- participate in measurement validity and cannot backpressure the
  -- authoritative PL AggregationEngine.
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
end package;
