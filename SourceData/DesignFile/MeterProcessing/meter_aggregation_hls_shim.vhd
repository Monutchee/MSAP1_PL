library ieee;
use ieee.std_logic_1164.all;

-- Integration shim for the HLS 10/12-cycle basic measurement engine
-- (M7, replaces meter_mtr1_hls_shim + the retired Mtr1Engine). The
-- engine consumes the single-cycle tier's result beats — one per whole
-- grid cycle — so unlike the retired sample-domain shim there is no
-- frame assembly and no drop-counting FIFO: the input cadence (~17-20 ms)
-- dwarfs the engine's finalize busy window (~tens of us), and the
-- single-cycle engine's registered master plus this shim's one skid
-- stage absorb the brief backpressure without loss.
--
-- The shim's only work is widening: each result beat is captured into
-- the skid stage together with the configuration shadows and the live
-- context sampled AT THAT MOMENT (grid lock view, frequency words,
-- capture counters), packed to the engine's 7392-bit input layout
-- (normative in HLS_DesignFile/MeterProcessing/AggregationEngine/
-- src/agg10_12_engine.hpp) and held stable until the engine accepts it.
--
-- The register-file mirror (active generation / enable / apply) commits
-- immediately on the APPLY toggle, exactly like the retired shim: the
-- engine commits the identical values when the toggled beat reaches it.
entity meter_aggregation_hls_shim is
  port (
    aclk    : in std_logic;
    aresetn : in std_logic;

    -- Single-cycle result beats (SCYC-v5 contract, 7072 bits).
    s_result_tdata  : in  std_logic_vector(7071 downto 0);
    s_result_tvalid : in  std_logic;
    s_result_tready : out std_logic;

    -- Live grid-timing view for per-cycle lock/fallback provenance.
    cycle_locked_i   : in std_logic;
    cycle_fallback_i : in std_logic;

    -- Shadow configuration and the shared APPLY toggle.
    shadow_generation_i  : in std_logic_vector(31 downto 0);
    shadow_sample_rate_i : in std_logic_vector(31 downto 0);
    shadow_valid_mask_i  : in std_logic_vector(7 downto 0);
    shadow_enable_i      : in std_logic;
    shadow_dc_remove_i   : in std_logic;
    config_apply_toggle_i : in std_logic;

    -- Frequency and capture context (record words 56..63).
    frequency_status_i   : in std_logic_vector(31 downto 0);
    frequency_period_i   : in std_logic_vector(31 downto 0);
    frequency_sequence_i : in std_logic_vector(31 downto 0);
    capture_frame_count_i   : in std_logic_vector(31 downto 0);
    capture_header_errors_i : in std_logic_vector(31 downto 0);
    capture_overflows_i     : in std_logic_vector(31 downto 0);
    capture_alerts_i        : in std_logic_vector(31 downto 0);

    -- BASIC-v4 record stream (to the exported M_AXIS_MTR1 boundary).
    m_axis_basic_tdata  : out std_logic_vector(31 downto 0);
    m_axis_basic_tkeep  : out std_logic_vector(3 downto 0);
    m_axis_basic_tvalid : out std_logic;
    m_axis_basic_tready : in  std_logic;
    m_axis_basic_tlast  : out std_logic;

    -- Block-result beats to the 150/180-cycle aggregator (M11 contract:
    -- agg_block_result.hpp — provenance + merge-safe accumulators).
    m_axis_agg_tdata  : out std_logic_vector(31 downto 0);
    m_axis_agg_tkeep  : out std_logic_vector(3 downto 0);
    m_axis_agg_tvalid : out std_logic;
    m_axis_agg_tready : in  std_logic;
    m_axis_agg_tlast  : out std_logic;

    -- Register-file mirror.
    active_generation_o : out std_logic_vector(31 downto 0);
    active_enable_o     : out std_logic;
    apply_seen_o        : out std_logic
  );
end entity;

architecture rtl of meter_aggregation_hls_shim is
  -- Engine input layout (agg10_12_engine.hpp, normative there).
  constant IN_RESULT_LSB       : natural := 0;
  constant IN_CFG_GEN_LSB      : natural := 7072;
  constant IN_CFG_RATE_LSB     : natural := 7104;
  constant IN_CFG_MASK_LSB     : natural := 7136;
  constant IN_ENABLE_BIT       : natural := 7144;
  constant IN_DC_REMOVE_BIT    : natural := 7145;
  constant IN_APPLY_BIT        : natural := 7146;
  constant IN_LOCKED_BIT       : natural := 7147;
  constant IN_FALLBACK_BIT     : natural := 7148;
  constant IN_FREQ_STATUS_LSB  : natural := 7168;
  constant IN_FREQ_PERIOD_LSB  : natural := 7200;
  constant IN_FREQ_SEQ_LSB     : natural := 7232;
  constant IN_CAP_FRAMES_LSB   : natural := 7264;
  constant IN_CAP_HDRERR_LSB   : natural := 7296;
  constant IN_CAP_OVERFLOW_LSB : natural := 7328;
  constant IN_CAP_ALERTS_LSB   : natural := 7360;
  constant IN_BITS             : natural := 7392;

  -- Bound to the packaged-IP customization (SourceData/IP/
  -- hls_aggregation_engine_ip) in the Vivado project; the non-project check
  -- flows bind the same name through tb/hls_aggregation_engine_ip.v.
  --
  -- ONE engine now owns both finalized tiers (roadmap A1), so this shim
  -- hosts two record masters instead of one record master plus a 7072-bit
  -- block-result beat: the inter-tier hand-off became an internal variable
  -- and the 150/180 shim it used to feed is gone.
  component hls_aggregation_engine_ip is
    port (
      ap_clk          : in  std_logic;
      ap_rst_n        : in  std_logic;
      s_result_TDATA  : in  std_logic_vector(IN_BITS - 1 downto 0);
      s_result_TVALID : in  std_logic;
      s_result_TREADY : out std_logic;
      m_basic_TDATA   : out std_logic_vector(31 downto 0);
      m_basic_TVALID  : out std_logic;
      m_basic_TREADY  : in  std_logic;
      m_basic_TKEEP   : out std_logic_vector(3 downto 0);
      m_basic_TSTRB   : out std_logic_vector(3 downto 0);
      m_basic_TLAST   : out std_logic_vector(0 downto 0);
      m_agg_TDATA     : out std_logic_vector(31 downto 0);
      m_agg_TVALID    : out std_logic;
      m_agg_TREADY    : in  std_logic;
      m_agg_TKEEP     : out std_logic_vector(3 downto 0);
      m_agg_TSTRB     : out std_logic_vector(3 downto 0);
      m_agg_TLAST     : out std_logic_vector(0 downto 0)
    );
  end component;

  signal stage_valid : std_logic := '0';
  signal stage_beat  : std_logic_vector(IN_BITS - 1 downto 0) :=
    (others => '0');
  signal engine_ready : std_logic;
  signal tlast_vec     : std_logic_vector(0 downto 0);
  signal agg_tlast_vec : std_logic_vector(0 downto 0);
  -- Records are never sparse: TSTRB duplicates TKEEP and terminates here.
  signal tstrb_nc      : std_logic_vector(3 downto 0);
  signal agg_tstrb_nc  : std_logic_vector(3 downto 0);

  signal active_generation : std_logic_vector(31 downto 0) := (others => '0');
  signal active_enable     : std_logic := '0';
  signal apply_seen        : std_logic := '0';
begin
  core : hls_aggregation_engine_ip
    port map (
      ap_clk          => aclk,
      ap_rst_n        => aresetn,
      s_result_TDATA  => stage_beat,
      s_result_TVALID => stage_valid,
      s_result_TREADY => engine_ready,
      m_basic_TDATA   => m_axis_basic_tdata,
      m_basic_TVALID  => m_axis_basic_tvalid,
      m_basic_TREADY  => m_axis_basic_tready,
      m_basic_TKEEP   => m_axis_basic_tkeep,
      m_basic_TSTRB   => tstrb_nc,
      m_basic_TLAST   => tlast_vec,
      m_agg_TDATA     => m_axis_agg_tdata,
      m_agg_TVALID    => m_axis_agg_tvalid,
      m_agg_TREADY    => m_axis_agg_tready,
      m_agg_TKEEP     => m_axis_agg_tkeep,
      m_agg_TSTRB     => agg_tstrb_nc,
      m_agg_TLAST     => agg_tlast_vec
    );
  m_axis_basic_tlast <= tlast_vec(0);
  m_axis_agg_tlast <= agg_tlast_vec(0);

  active_generation_o <= active_generation;
  active_enable_o <= active_enable;
  apply_seen_o <= apply_seen;

  -- Skid stage: accept when empty, or in the same cycle the engine
  -- consumes the held beat. The context is sampled at capture time and
  -- stays stable for as long as the engine holds off.
  s_result_tready <= (not stage_valid) or engine_ready;

  process (aclk)
  begin
    if rising_edge(aclk) then
      if aresetn = '0' then
        stage_valid <= '0';
        active_generation <= (others => '0');
        active_enable <= '0';
        apply_seen <= '0';
      else
        -- Immediate APPLY-commit mirror (register-file view). The engine
        -- commits the identical values when the toggled beat reaches it.
        if config_apply_toggle_i /= apply_seen then
          apply_seen <= config_apply_toggle_i;
          active_generation <= shadow_generation_i;
          active_enable <= shadow_enable_i;
        end if;

        if s_result_tvalid = '1' and
           (stage_valid = '0' or engine_ready = '1') then
          stage_beat <= (others => '0');
          stage_beat(IN_RESULT_LSB + 7071 downto IN_RESULT_LSB) <=
            s_result_tdata;
          stage_beat(IN_CFG_GEN_LSB + 31 downto IN_CFG_GEN_LSB) <=
            shadow_generation_i;
          stage_beat(IN_CFG_RATE_LSB + 31 downto IN_CFG_RATE_LSB) <=
            shadow_sample_rate_i;
          stage_beat(IN_CFG_MASK_LSB + 7 downto IN_CFG_MASK_LSB) <=
            shadow_valid_mask_i;
          stage_beat(IN_ENABLE_BIT) <= shadow_enable_i;
          stage_beat(IN_DC_REMOVE_BIT) <= shadow_dc_remove_i;
          stage_beat(IN_APPLY_BIT) <= config_apply_toggle_i;
          stage_beat(IN_LOCKED_BIT) <= cycle_locked_i;
          stage_beat(IN_FALLBACK_BIT) <= cycle_fallback_i;
          stage_beat(IN_FREQ_STATUS_LSB + 31 downto IN_FREQ_STATUS_LSB) <=
            frequency_status_i;
          stage_beat(IN_FREQ_PERIOD_LSB + 31 downto IN_FREQ_PERIOD_LSB) <=
            frequency_period_i;
          stage_beat(IN_FREQ_SEQ_LSB + 31 downto IN_FREQ_SEQ_LSB) <=
            frequency_sequence_i;
          stage_beat(IN_CAP_FRAMES_LSB + 31 downto IN_CAP_FRAMES_LSB) <=
            capture_frame_count_i;
          stage_beat(IN_CAP_HDRERR_LSB + 31 downto IN_CAP_HDRERR_LSB) <=
            capture_header_errors_i;
          stage_beat(IN_CAP_OVERFLOW_LSB + 31 downto IN_CAP_OVERFLOW_LSB) <=
            capture_overflows_i;
          stage_beat(IN_CAP_ALERTS_LSB + 31 downto IN_CAP_ALERTS_LSB) <=
            capture_alerts_i;
          stage_valid <= '1';
        elsif stage_valid = '1' and engine_ready = '1' then
          stage_valid <= '0';
        end if;
      end if;
    end if;
  end process;
end architecture;
