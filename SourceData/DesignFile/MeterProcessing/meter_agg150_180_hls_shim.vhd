library ieee;
use ieee.std_logic_1164.all;

-- Integration shim for the HLS 150/180-cycle aggregation engine (M11,
-- replaces meter_mtr2_hls_shim + the retired Mtr2Engine) — the same
-- pure-hosting shape as its predecessor: every record producer presents
-- one VHDL shim hosting one packaged HLS engine to meter_core.
--
-- No work beyond hosting: the engine's input is the 10/12-cycle tier's
-- block-result stream (agg_block_result.hpp, 7072 bits — the block's
-- provenance AND its committed configuration ride the beat, so no config
-- ports exist here), arriving once per ~200 ms against a
-- microsecond-scale busy window. The producer's registered master keeps
-- the boundary AXI-compliant. Deliberately NO level-to-event conversion
-- (the 2026-08-13..16 record-duplication incident pattern).
--
-- The engine builds and serializes its own AGG record quad
-- (measurement_record.hpp: AGG-v3 + AGG-POWER/PHASOR/UNBAL); its health
-- counters ride inside the AGG-v3 record and are republished by
-- record_word_tap in meter_core.
entity meter_agg150_180_hls_shim is
  port (
    aclk    : in std_logic;
    aresetn : in std_logic;

    -- Block-result beats from the 10/12-cycle engine.
    s_result_tdata  : in  std_logic_vector(7071 downto 0);
    s_result_tvalid : in  std_logic;
    s_result_tready : out std_logic;

    -- Aggregate record stream (to the exported M_AXIS_MTR2 boundary).
    m_axis_mtr2_tdata  : out std_logic_vector(31 downto 0);
    m_axis_mtr2_tkeep  : out std_logic_vector(3 downto 0);
    m_axis_mtr2_tvalid : out std_logic;
    m_axis_mtr2_tready : in  std_logic;
    m_axis_mtr2_tlast  : out std_logic
  );
end entity;

architecture rtl of meter_agg150_180_hls_shim is
  -- Bound to the packaged-IP customization (SourceData/IP/
  -- hls_agg150_180_cycle_engine_ip) in the Vivado project; the
  -- non-project check flows bind the same name through
  -- tb/hls_agg150_180_cycle_engine_ip.v.
  component hls_agg150_180_cycle_engine_ip is
    port (
      ap_clk         : in  std_logic;
      ap_rst_n       : in  std_logic;
      s_block_TDATA  : in  std_logic_vector(7071 downto 0);
      s_block_TVALID : in  std_logic;
      s_block_TREADY : out std_logic;
      m_axis_TDATA   : out std_logic_vector(31 downto 0);
      m_axis_TVALID  : out std_logic;
      m_axis_TREADY  : in  std_logic;
      m_axis_TKEEP   : out std_logic_vector(3 downto 0);
      m_axis_TSTRB   : out std_logic_vector(3 downto 0);
      m_axis_TLAST   : out std_logic_vector(0 downto 0)
    );
  end component;

  signal tlast_vec : std_logic_vector(0 downto 0);
  -- Records are never sparse: TSTRB duplicates TKEEP and terminates here.
  signal tstrb_nc  : std_logic_vector(3 downto 0);
begin
  core : hls_agg150_180_cycle_engine_ip
    port map (
      ap_clk         => aclk,
      ap_rst_n       => aresetn,
      s_block_TDATA  => s_result_tdata,
      s_block_TVALID => s_result_tvalid,
      s_block_TREADY => s_result_tready,
      m_axis_TDATA   => m_axis_mtr2_tdata,
      m_axis_TVALID  => m_axis_mtr2_tvalid,
      m_axis_TREADY  => m_axis_mtr2_tready,
      m_axis_TKEEP   => m_axis_mtr2_tkeep,
      m_axis_TSTRB   => tstrb_nc,
      m_axis_TLAST   => tlast_vec
    );
  m_axis_mtr2_tlast <= tlast_vec(0);
end architecture;
