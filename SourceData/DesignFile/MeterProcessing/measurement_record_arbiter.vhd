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
-- Future producers (harmonics, PQ events) extend this arbiter with another
-- input port; the DMA architecture stays unchanged.
entity measurement_record_arbiter is
  port (
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
begin
  m_valid_o <= basic_valid_i or aggregate_valid_i;
  m_record_o <= basic_record_i when basic_valid_i = '1'
                else aggregate_record_i;
  basic_ready_o <= m_ready_i and basic_valid_i;
  aggregate_ready_o <= m_ready_i and aggregate_valid_i and
                       (not basic_valid_i);
end architecture;
