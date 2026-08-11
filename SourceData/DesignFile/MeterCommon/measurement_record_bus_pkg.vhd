library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.metering_pkg.all;

-- Measurement record bus and 150/180-cycle aggregation contracts.
--
-- The record bus generalizes the existing MTR1 DMA path: every metrology
-- producer publishes complete fixed-size 256-byte records through one
-- valid/ready port; a deterministic arbiter forwards them to the single
-- existing packetizer and AXI DMA channel. This milestone connects two
-- producers (Basic and 150/180-cycle aggregate); future producers
-- (harmonics, PQ events) add a port, not a new DMA architecture.
--
-- Transport must never backpressure measurement: each producer holds its
-- newest pending record and counts replacements when the DMA side stalls,
-- exactly like the original hub/packetizer pair. At the product record
-- rates (Basic ~5/s, aggregate ~1 per 3 s) the packetizer's two-deep
-- buffer plus one pending record per producer is provably sufficient;
-- drop counters make any violation visible rather than silent.
package measurement_record_bus_pkg is
  -- Fixed record geometry shared by every producer (word 2 of the header).
  constant MEASUREMENT_RECORD_WORDS : positive := 64;
  constant MEASUREMENT_RECORD_BITS  : positive := 2048;

  subtype measurement_record_t is
    std_logic_vector(MEASUREMENT_RECORD_BITS - 1 downto 0);

  -- Record types carried on the bus. The payload is self-describing
  -- (header word 1), so the type is informational for arbitration and
  -- future filtering.
  constant RECORD_TYPE_BASIC     : natural := 1;
  constant RECORD_TYPE_AGGREGATE : natural := 2;

  -- The internal Basic measurement result event, published once per closed
  -- basic block when the RMS engine finishes its calculation. Both the
  -- Basic record producer (MeterResultHub) and the cycle aggregator consume
  -- this same event; the aggregator must never decode MTR1 packets.
  type basic_measurement_result_t is record
    valid            : std_logic;
    result_sequence  : word32_t;
    generation       : word32_t;
    sample_rate_hz   : word32_t;
    sample_count     : word32_t;  -- actual samples in the block
    valid_mask       : std_logic_vector(7 downto 0);
    status           : word32_t;  -- bit 0: arithmetic overflow
    rms_q16          : std_logic_vector(511 downto 0);  -- 8 x signed Q16
    -- Closed-block provenance, latched atomically by grid_cycle_timing.
    first_sample     : std_logic_vector(63 downto 0);
    cycle_count      : std_logic_vector(7 downto 0);
    nominal_hz       : std_logic_vector(7 downto 0);
    flags            : std_logic_vector(2 downto 0);
    -- Frequency estimate sampled at the result event (same sampling the
    -- Basic record uses for MTR1 words 56/57).
    frequency_millihz: word32_t;
    frequency_valid  : std_logic;
  end record;

  -- IEC 61000-4-30: the 150/180-cycle aggregate is formed from exactly 15
  -- standardized Basic measurement results (15 x 10 cycles at 50 Hz,
  -- 15 x 12 cycles at 60 Hz). It is not a 3-second timer and not an
  -- independent raw-sample RMS engine.
  constant AGGREGATE_BASIC_BLOCKS : positive := 15;

  -- MTR2: 150/180-cycle fundamental aggregate record. Word 0 keeps the
  -- container magic ("MTR1") the DMA/stream layer keys on; word 1 carries
  -- the record type/version consumed by the APU decoder registry.
  constant MTR2_FORMAT : word32_t := x"00020001";
  constant MTR2_SEQUENCE_WORD          : natural := 3;
  constant MTR2_GENERATION_WORD        : natural := 4;
  constant MTR2_SAMPLE_RATE_WORD       : natural := 5;
  constant MTR2_TOTAL_SAMPLES_WORD     : natural := 6;
  constant MTR2_VALID_MASK_WORD        : natural := 7;
  constant MTR2_STATUS_WORD            : natural := 8;
  constant MTR2_FIRST_BASIC_SEQ_WORD   : natural := 9;
  constant MTR2_LAST_BASIC_SEQ_WORD    : natural := 10;
  constant MTR2_SHAPE_WORD             : natural := 11;
  constant MTR2_FIRST_SAMPLE_LOW_WORD  : natural := 12;
  constant MTR2_FIRST_SAMPLE_HIGH_WORD : natural := 13;
  constant MTR2_CHANNEL_BASE_WORD      : natural := 16;  -- 8 ch x 2 words
  constant MTR2_FREQUENCY_WORD         : natural := 32;

  -- MTR2 status word bits.
  constant MTR2_STATUS_ARITHMETIC_BIT : natural := 0;
  constant MTR2_STATUS_COMPLETE_BIT   : natural := 1;
  constant MTR2_STATUS_FREQUENCY_BIT  : natural := 2;

  -- MTR2 shape word layout: [7:0] basic block count, [15:8] nominal Hz,
  -- [31:16] total cycle count (150 or 180).
  constant MTR2_SHAPE_BLOCKS_LSB  : natural := 0;
  constant MTR2_SHAPE_NOMINAL_LSB : natural := 8;
  constant MTR2_SHAPE_CYCLES_LSB  : natural := 16;

  -- Aggregation arithmetic geometry (see meter_cycle_aggregator):
  --   input:        |RMS| as signed 64-bit Q16 (magnitude < 2^63)
  --   square:       unsigned 126 bits
  --   accumulator:  unsigned 132 bits (15 x 2^126 < 2^130, 2 bits margin)
  --   mean:         floor(acc / 15), bit-serial division
  --   aggregate:    floor(sqrt(mean)), 64-bit binary-search root
  -- All rounding is floor; no stage can overflow by construction, so no
  -- implicit truncation or saturation participates in the result.
  constant AGGREGATE_ACCUMULATOR_BITS : positive := 132;

  -- Processing AXI-Lite offsets for aggregate health (base 0xB0050000).
  constant AGG_REG_STATUS            : natural := 16#78#;
  constant AGG_REG_RECORD_COUNT      : natural := 16#7C#;
  constant AGG_REG_RESET_COUNT       : natural := 16#80#;
  constant AGG_REG_INELIGIBLE_COUNT  : natural := 16#84#;
  constant AGG_REG_CONTINUITY_COUNT  : natural := 16#88#;
  constant AGG_REG_DROP_COUNT        : natural := 16#8C#;

  -- AGG_STATUS layout: [4:0] basic blocks accumulated in the open
  -- aggregate, [8] an aggregate is in progress.
  constant AGG_STATUS_BLOCKS_LSB   : natural := 0;
  constant AGG_STATUS_ACTIVE_BIT   : natural := 8;

  -- HLS 150/180-cycle aggregator trial. A Vitis HLS implementation of the
  -- aggregation contract (SourceData/HLS_DesignFile/MeterProcessing/
  -- CycleAggregator) runs in meter_core as a shadow of the RTL engine:
  -- same Basic result event in, compared field-for-field whenever both
  -- engines emit. It publishes no MTR2 records; the RTL engine remains
  -- the production producer. The AXI4-Stream beat geometry lives in
  -- cycle_aggregator.hpp and meter_cycle_aggregator_hls_shim.vhd.
  constant HLS_AGG_BASIC_BEAT_BITS     : positive := 808;
  constant HLS_AGG_AGGREGATE_BEAT_BITS : positive := 968;

  -- Processing AXI-Lite offsets for the HLS trial (read-only).
  --   RECORD_COUNT:   aggregates completed by the HLS engine, sampled at
  --                   its last emitted aggregate.
  --   MISMATCH_COUNT: aggregate pairs (or unpaired emits) whose compared
  --                   fields differed; 0 means the engines agree.
  --   DROP_COUNT:     Basic result events the shim had to discard because
  --                   the HLS core was still busy (impossible at real
  --                   block rates; any nonzero value is a fault).
  constant HLS_AGG_REG_RECORD_COUNT   : natural := 16#90#;
  constant HLS_AGG_REG_MISMATCH_COUNT : natural := 16#94#;
  constant HLS_AGG_REG_DROP_COUNT     : natural := 16#98#;
end package;
