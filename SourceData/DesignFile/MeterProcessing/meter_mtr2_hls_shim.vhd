library ieee;
use ieee.std_logic_1164.all;

-- Integration shim for the HLS MTR2 150/180-cycle aggregation engine —
-- the structural twin of meter_mtr1_hls_shim, so every record producer
-- presents the same shape to meter_core: a VHDL shim hosting one
-- packaged HLS engine.
--
-- Unlike the MTR1 shim this one has no work to do beyond hosting: the
-- engine's input is already a proper AXI4-Stream (the MTR1 engine's
-- basic-result beats, layout normative in common/basic_result_beat.hpp),
-- arriving once per ~200 ms against a microsecond-scale busy window, so
-- no beat assembly, staging, or FIFO is needed — the stream handshake
-- alone is sufficient, and the MTR1 engine's registered master keeps the
-- boundary AXI-compliant. Deliberately NO level-to-event conversion
-- exists here (the 2026-08-13..16 record-duplication incident was
-- localized to exactly that pattern in this shim's retired predecessor).
--
-- The engine builds and serializes its own MTR2-v2 records
-- (measurement_record.hpp); its health counters ride inside the record
-- and are republished by record_word_tap in meter_core.
entity meter_mtr2_hls_shim is
  port (
    aclk    : in std_logic;
    aresetn : in std_logic;

    -- Basic-result beats from the MTR1 engine.
    s_result_tdata  : in  std_logic_vector(807 downto 0);
    s_result_tvalid : in  std_logic;
    s_result_tready : out std_logic;

    -- MTR2-v2 record stream (to the exported M_AXIS_MTR2 boundary).
    m_axis_mtr2_tdata  : out std_logic_vector(31 downto 0);
    m_axis_mtr2_tkeep  : out std_logic_vector(3 downto 0);
    m_axis_mtr2_tvalid : out std_logic;
    m_axis_mtr2_tready : in  std_logic;
    m_axis_mtr2_tlast  : out std_logic
  );
end entity;

architecture rtl of meter_mtr2_hls_shim is
  -- Bound to the packaged-IP customization (SourceData/IP/
  -- hls_mtr2_engine_ip) in the Vivado project; the non-project check
  -- flows bind the same name through tb/hls_mtr2_engine_ip.v.
  component hls_mtr2_engine_ip is
    port (
      ap_clk        : in  std_logic;
      ap_rst_n      : in  std_logic;
      s_basic_TDATA : in  std_logic_vector(807 downto 0);
      s_basic_TVALID: in  std_logic;
      s_basic_TREADY: out std_logic;
      m_axis_TDATA  : out std_logic_vector(31 downto 0);
      m_axis_TVALID : out std_logic;
      m_axis_TREADY : in  std_logic;
      m_axis_TKEEP  : out std_logic_vector(3 downto 0);
      m_axis_TSTRB  : out std_logic_vector(3 downto 0);
      m_axis_TLAST  : out std_logic_vector(0 downto 0)
    );
  end component;

  signal tlast_vec : std_logic_vector(0 downto 0);
  -- Records are never sparse: TSTRB duplicates TKEEP and terminates here.
  signal tstrb_nc  : std_logic_vector(3 downto 0);
begin
  core : hls_mtr2_engine_ip
    port map (
      ap_clk         => aclk,
      ap_rst_n       => aresetn,
      s_basic_TDATA  => s_result_tdata,
      s_basic_TVALID => s_result_tvalid,
      s_basic_TREADY => s_result_tready,
      m_axis_TDATA   => m_axis_mtr2_tdata,
      m_axis_TVALID  => m_axis_mtr2_tvalid,
      m_axis_TREADY  => m_axis_mtr2_tready,
      m_axis_TKEEP   => m_axis_mtr2_tkeep,
      m_axis_TSTRB   => tstrb_nc,
      m_axis_TLAST   => tlast_vec
    );
  m_axis_mtr2_tlast <= tlast_vec(0);
end architecture;
