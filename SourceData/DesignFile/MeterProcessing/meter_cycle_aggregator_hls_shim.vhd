library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.metering_pkg.all;
use work.measurement_record_bus_pkg.all;

-- Integration shim for the HLS 150/180-cycle aggregation engine (the
-- sole MTR2 aggregate source; the hand-written RTL engine it was trialed
-- against retired after the compared deployment -- see git history).
--
-- Presents the metering event-style boundary to meter_core and adapts it
-- to the HLS core's two AXI4-Stream interfaces:
--
--   * Input: each single-cycle Basic result event is packed into one
--     808-bit beat and held until the core accepts it. The shim never
--     backpressures measurement; if a new event ever arrived while the
--     previous beat was still waiting (impossible at real block rates:
--     one event per ~200 ms against a ~15 us worst-case busy window) the
--     old beat is replaced and drop_count_o increments.
--   * The configuration APPLY toggle is not a separate core port: its
--     level is sampled into every beat. See cycle_aggregator.hpp for the
--     accepted divergence when APPLY races the Basic result event.
--   * Output: the core's 968-bit aggregate beat is always accepted,
--     unpacked, and republished as a single-cycle valid event with
--     outputs held stable until the next aggregate, mirroring the RTL
--     engine. The engine's diagnostic counters travel inside the beat,
--     so record/reset/ineligible/continuity counts are "as of the last
--     completed aggregate", not live like the RTL engine's registers.
--
-- Beat bit positions mirror cycle_aggregator.hpp (the single normative
-- layout); keep both in lock step. The equivalence testbench
-- (tb/meter_aggregator_equivalence_tb.sv) catches any drift.
entity meter_cycle_aggregator_hls_shim is
  port (
    aclk    : in std_logic;
    aresetn : in std_logic;

    basic_i               : in basic_measurement_result_t;
    config_apply_toggle_i : in std_logic;

    aggregate_valid_o        : out std_logic;
    aggregate_sequence_o     : out word32_t;
    aggregate_generation_o   : out word32_t;
    aggregate_sample_rate_o  : out word32_t;
    aggregate_samples_o      : out word32_t;
    aggregate_valid_mask_o   : out std_logic_vector(7 downto 0);
    aggregate_arithmetic_o   : out std_logic;
    aggregate_freq_valid_o   : out std_logic;
    aggregate_first_seq_o    : out word32_t;
    aggregate_last_seq_o     : out word32_t;
    aggregate_nominal_o      : out std_logic_vector(7 downto 0);
    aggregate_cycles_o       : out std_logic_vector(15 downto 0);
    aggregate_first_sample_o : out std_logic_vector(63 downto 0);
    aggregate_rms_q16_o      : out std_logic_vector(511 downto 0);
    aggregate_freq_millihz_o : out word32_t;

    record_count_o     : out word32_t;
    reset_count_o      : out word32_t;
    ineligible_count_o : out word32_t;
    continuity_count_o : out word32_t;
    drop_count_o       : out word32_t
  );
end entity;

architecture rtl of meter_cycle_aggregator_hls_shim is
  -- Input beat field LSBs (cycle_aggregator.hpp CAGG_IN_*).
  constant IN_SEQUENCE_LSB     : natural := 0;
  constant IN_GENERATION_LSB   : natural := 32;
  constant IN_SAMPLE_RATE_LSB  : natural := 64;
  constant IN_SAMPLE_COUNT_LSB : natural := 96;
  constant IN_VALID_MASK_LSB   : natural := 128;
  constant IN_FLAGS_LSB        : natural := 136;
  constant IN_CYCLE_COUNT_LSB  : natural := 144;
  constant IN_NOMINAL_HZ_LSB   : natural := 152;
  constant IN_STATUS_LSB       : natural := 160;
  constant IN_FREQ_LSB         : natural := 192;
  constant IN_FREQ_VALID_BIT   : natural := 224;
  constant IN_APPLY_TOGGLE_BIT : natural := 225;
  constant IN_FIRST_SAMPLE_LSB : natural := 232;
  constant IN_RMS_LSB          : natural := 296;

  -- Output beat field LSBs (cycle_aggregator.hpp CAGG_OUT_*).
  constant OUT_SEQUENCE_LSB     : natural := 0;
  constant OUT_GENERATION_LSB   : natural := 32;
  constant OUT_SAMPLE_RATE_LSB  : natural := 64;
  constant OUT_SAMPLES_LSB      : natural := 96;
  constant OUT_VALID_MASK_LSB   : natural := 128;
  constant OUT_NOMINAL_HZ_LSB   : natural := 136;
  constant OUT_CYCLES_LSB       : natural := 144;
  constant OUT_ARITHMETIC_BIT   : natural := 160;
  constant OUT_FREQ_VALID_BIT   : natural := 161;
  constant OUT_FIRST_SEQ_LSB    : natural := 168;
  constant OUT_LAST_SEQ_LSB     : natural := 200;
  constant OUT_FREQ_LSB         : natural := 232;
  constant OUT_FIRST_SAMPLE_LSB : natural := 264;
  constant OUT_RMS_LSB          : natural := 328;
  constant OUT_RECORD_CNT_LSB   : natural := 840;
  constant OUT_RESET_CNT_LSB    : natural := 872;
  constant OUT_INELIG_CNT_LSB   : natural := 904;
  constant OUT_CONT_CNT_LSB     : natural := 936;

  -- Bound to the packaged-IP customization (SourceData/IP/
  -- hls_cycle_aggregator_ip) in the Vivado project; the non-project check
  -- flows bind the same name through tb/hls_cycle_aggregator_ip.v, a thin
  -- wrapper over the packaged RTL. Vivado reserves the bare IP definition
  -- name for the catalog, hence the _ip suffix.
  component hls_cycle_aggregator_ip is
    port (
      ap_clk            : in  std_logic;
      ap_rst_n          : in  std_logic;
      s_basic_TDATA     : in  std_logic_vector(
                            HLS_AGG_BASIC_BEAT_BITS - 1 downto 0);
      s_basic_TVALID    : in  std_logic;
      s_basic_TREADY    : out std_logic;
      m_aggregate_TDATA : out std_logic_vector(
                            HLS_AGG_AGGREGATE_BEAT_BITS - 1 downto 0);
      m_aggregate_TVALID: out std_logic;
      m_aggregate_TREADY: in  std_logic
    );
  end component;

  signal beat_data    : std_logic_vector(
                          HLS_AGG_BASIC_BEAT_BITS - 1 downto 0)
                        := (others => '0');
  signal beat_pending : std_logic := '0';
  signal in_ready     : std_logic;
  signal drop_count   : unsigned(31 downto 0) := (others => '0');

  signal out_data  : std_logic_vector(
                       HLS_AGG_AGGREGATE_BEAT_BITS - 1 downto 0);
  signal out_valid : std_logic;

  signal aggregate_valid : std_logic := '0';
  signal result_beat     : std_logic_vector(
                             HLS_AGG_AGGREGATE_BEAT_BITS - 1 downto 0)
                           := (others => '0');
begin
  core : hls_cycle_aggregator_ip
    port map (
      ap_clk             => aclk,
      ap_rst_n           => aresetn,
      s_basic_TDATA      => beat_data,
      s_basic_TVALID     => beat_pending,
      s_basic_TREADY     => in_ready,
      m_aggregate_TDATA  => out_data,
      m_aggregate_TVALID => out_valid,
      m_aggregate_TREADY => '1'
    );

  process (aclk)
  begin
    if rising_edge(aclk) then
      aggregate_valid <= '0';

      if aresetn = '0' then
        beat_pending <= '0';
        drop_count <= (others => '0');
      else
        if beat_pending = '1' and in_ready = '1' then
          beat_pending <= '0';
        end if;

        if basic_i.valid = '1' then
          -- Newest-wins capture. A replacement is only possible if the
          -- core were still busy from the previous event; count it, never
          -- stall the measurement pipeline.
          if beat_pending = '1' and in_ready = '0' then
            drop_count <= drop_count + 1;
          end if;
          beat_data <= (others => '0');
          beat_data(IN_SEQUENCE_LSB + 31 downto IN_SEQUENCE_LSB) <=
            basic_i.result_sequence;
          beat_data(IN_GENERATION_LSB + 31 downto IN_GENERATION_LSB) <=
            basic_i.generation;
          beat_data(IN_SAMPLE_RATE_LSB + 31 downto IN_SAMPLE_RATE_LSB) <=
            basic_i.sample_rate_hz;
          beat_data(IN_SAMPLE_COUNT_LSB + 31 downto IN_SAMPLE_COUNT_LSB) <=
            basic_i.sample_count;
          beat_data(IN_VALID_MASK_LSB + 7 downto IN_VALID_MASK_LSB) <=
            basic_i.valid_mask;
          beat_data(IN_FLAGS_LSB + 2 downto IN_FLAGS_LSB) <= basic_i.flags;
          beat_data(IN_CYCLE_COUNT_LSB + 7 downto IN_CYCLE_COUNT_LSB) <=
            basic_i.cycle_count;
          beat_data(IN_NOMINAL_HZ_LSB + 7 downto IN_NOMINAL_HZ_LSB) <=
            basic_i.nominal_hz;
          beat_data(IN_STATUS_LSB + 31 downto IN_STATUS_LSB) <=
            basic_i.status;
          beat_data(IN_FREQ_LSB + 31 downto IN_FREQ_LSB) <=
            basic_i.frequency_millihz;
          beat_data(IN_FREQ_VALID_BIT) <= basic_i.frequency_valid;
          beat_data(IN_APPLY_TOGGLE_BIT) <= config_apply_toggle_i;
          beat_data(IN_FIRST_SAMPLE_LSB + 63 downto IN_FIRST_SAMPLE_LSB) <=
            basic_i.first_sample;
          beat_data(IN_RMS_LSB + 511 downto IN_RMS_LSB) <= basic_i.rms_q16;
          beat_pending <= '1';
        end if;

        if out_valid = '1' then
          result_beat <= out_data;
          aggregate_valid <= '1';
        end if;
      end if;
    end if;
  end process;

  aggregate_valid_o <= aggregate_valid;
  aggregate_sequence_o <=
    result_beat(OUT_SEQUENCE_LSB + 31 downto OUT_SEQUENCE_LSB);
  aggregate_generation_o <=
    result_beat(OUT_GENERATION_LSB + 31 downto OUT_GENERATION_LSB);
  aggregate_sample_rate_o <=
    result_beat(OUT_SAMPLE_RATE_LSB + 31 downto OUT_SAMPLE_RATE_LSB);
  aggregate_samples_o <=
    result_beat(OUT_SAMPLES_LSB + 31 downto OUT_SAMPLES_LSB);
  aggregate_valid_mask_o <=
    result_beat(OUT_VALID_MASK_LSB + 7 downto OUT_VALID_MASK_LSB);
  aggregate_arithmetic_o <= result_beat(OUT_ARITHMETIC_BIT);
  aggregate_freq_valid_o <= result_beat(OUT_FREQ_VALID_BIT);
  aggregate_first_seq_o <=
    result_beat(OUT_FIRST_SEQ_LSB + 31 downto OUT_FIRST_SEQ_LSB);
  aggregate_last_seq_o <=
    result_beat(OUT_LAST_SEQ_LSB + 31 downto OUT_LAST_SEQ_LSB);
  aggregate_nominal_o <=
    result_beat(OUT_NOMINAL_HZ_LSB + 7 downto OUT_NOMINAL_HZ_LSB);
  aggregate_cycles_o <=
    result_beat(OUT_CYCLES_LSB + 15 downto OUT_CYCLES_LSB);
  aggregate_first_sample_o <=
    result_beat(OUT_FIRST_SAMPLE_LSB + 63 downto OUT_FIRST_SAMPLE_LSB);
  aggregate_rms_q16_o <=
    result_beat(OUT_RMS_LSB + 511 downto OUT_RMS_LSB);
  aggregate_freq_millihz_o <=
    result_beat(OUT_FREQ_LSB + 31 downto OUT_FREQ_LSB);

  record_count_o <=
    result_beat(OUT_RECORD_CNT_LSB + 31 downto OUT_RECORD_CNT_LSB);
  reset_count_o <=
    result_beat(OUT_RESET_CNT_LSB + 31 downto OUT_RESET_CNT_LSB);
  ineligible_count_o <=
    result_beat(OUT_INELIG_CNT_LSB + 31 downto OUT_INELIG_CNT_LSB);
  continuity_count_o <=
    result_beat(OUT_CONT_CNT_LSB + 31 downto OUT_CONT_CNT_LSB);
  drop_count_o <= std_logic_vector(drop_count);
end architecture;
