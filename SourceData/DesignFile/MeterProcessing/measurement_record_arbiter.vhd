library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.measurement_record_bus_pkg.all;

-- Measurement record bus arbiter.
--
-- Forwards complete fixed-size records from the metrology producers to the
-- single packetizer/DMA path. Arbitration is deterministic fixed priority:
-- Basic first, then aggregate. Starvation is impossible at the design
-- record rates (Basic ~5/s, aggregate ~1 per 3 s) because the packetizer
-- drains a 256-byte record in 64 beats (~microseconds): when both records
-- become pending in the same interval, the Basic record is accepted first
-- and the aggregate immediately after -- neither is discarded. Each
-- producer keeps its own newest-wins pending record with a drop counter,
-- so a stalled DMA can never backpressure the measurement engines.
--
-- The output stage is REGISTERED, and that is load-bearing: the original
-- combinational mux fed the packetizer's 2048-bit capture registers with
-- only picoseconds of hold margin in the routed device (0.016 ns measured
-- on the 2026-08-13 build), and in the field that race intermittently
-- captured the wrong producer's record -- one basic record lost and the
-- aggregate duplicated per window, with every drop counter silent, in
-- self-clearing episodes (incident 2026-08-13..15, see
-- MSAP1_DOC/raw_doc/incident_logs/2026-08-14/ANALYSIS.md). A flop-to-flop
-- handoff gives the capture bus a full clock cycle and makes the race
-- structurally impossible; the one cycle of added latency is nothing
-- against the 200 ms record cadence.
--
-- Future producers (harmonics, PQ events) extend this arbiter with another
-- input port; the DMA architecture stays unchanged.
entity measurement_record_arbiter is
  port (
    aclk                  : in  std_logic;
    aresetn               : in  std_logic;

    basic_record_i        : in  measurement_record_t;
    basic_valid_i         : in  std_logic;
    basic_ready_o         : out std_logic;

    aggregate_record_i    : in  measurement_record_t;
    aggregate_valid_i     : in  std_logic;
    aggregate_ready_o     : out std_logic;

    m_record_o            : out measurement_record_t;
    m_valid_o             : out std_logic;
    m_ready_i             : in  std_logic
  );
end entity;

architecture rtl of measurement_record_arbiter is
  signal out_record  : measurement_record_t := (others => '0');
  signal out_valid   : std_logic := '0';
  -- The output register can accept a record when empty or when the
  -- downstream consumes its current one this cycle.
  signal stage_ready : std_logic;
begin
  stage_ready <= (not out_valid) or m_ready_i;

  -- Same one-cycle producer handshake as before: a producer holding valid
  -- sees ready the moment the output stage can take its record, and the
  -- fixed Basic-first priority is unchanged.
  basic_ready_o     <= stage_ready and basic_valid_i;
  aggregate_ready_o <= stage_ready and aggregate_valid_i and
                       (not basic_valid_i);

  m_record_o <= out_record;
  m_valid_o  <= out_valid;

  process (aclk)
  begin
    if rising_edge(aclk) then
      if aresetn = '0' then
        out_record <= (others => '0');
        out_valid  <= '0';
      else
        if out_valid = '1' and m_ready_i = '1' then
          out_valid <= '0';
        end if;
        if stage_ready = '1' then
          if basic_valid_i = '1' then
            out_record <= basic_record_i;
            out_valid  <= '1';
          elsif aggregate_valid_i = '1' then
            out_record <= aggregate_record_i;
            out_valid  <= '1';
          end if;
        end if;
      end if;
    end if;
  end process;
end architecture;
