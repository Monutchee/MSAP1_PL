library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Integration shim for the HLS MTR1 basic measurement engine (the sole
-- MTR1 producer; the hand-written meter_rms/MeterResultHub pair it
-- replaced lives in git history).
--
-- Presents meter_core's frame/config/provenance signals to the engine as
-- one 1264-bit sample beat per accepted converted frame:
--
--   * Each accepted frame is staged for one cycle and pushed on the
--     next: the frame payload and close marker are captured with the
--     frame (grid_cycle_timing owns all boundary decisions), while the
--     provenance/frequency/capture context is sampled at the push —
--     one cycle AFTER the frame. That matters: grid_cycle_timing latches
--     a block's provenance AT the close event, so sampling it in the
--     closing frame's own cycle would capture the PREVIOUS block's
--     values (the retired hub read them at result time, safely after
--     the latch). Bit positions mirror mtr1_engine.hpp MTR1_IN_* (the
--     single normative layout); keep both in lock step.
--   * The APPLY toggle level is sampled into every beat; the engine
--     commits configuration when the level changes between beats.
--   * An 8-deep distributed-RAM beat FIFO absorbs the engine's inline
--     finalize (~40 us, during which it accepts no beats): at the
--     32 kSPS metering profile that is ~1.3 frame periods and even at
--     the capture path's 128 kSPS ceiling ~5 frames, so eight slots
--     hold the worst case with margin. If the FIFO ever overflows the
--     newest beat is dropped and counted — measurement is never
--     backpressured and loss is never silent (the aggregator-shim rule,
--     one stage earlier).
--   * The engine's two output streams pass through untouched: the
--     MTR1-v3 record stream (to the exported M_AXIS_MTR1 boundary) and
--     the basic-result beat stream (to the 150/180-cycle aggregator).
--     There is deliberately NO event conversion here: the 2026-08-13..16
--     record-duplication incident was localized to exactly such a
--     level-to-event conversion, and this architecture removes the
--     pattern.
--   * The shim mirrors the APPLY commit (active generation / enable /
--     apply-seen) for the AXI-Lite registers, which must reflect a
--     commit immediately, not one record period later.
entity meter_mtr1_hls_shim is
  port (
    aclk    : in std_logic;
    aresetn : in std_logic;

    -- Accepted converted frame (one beat per frame_accept_i pulse).
    frame_accept_i : in std_logic;
    frame_data_i   : in std_logic_vector(511 downto 0);
    frame_keep_i   : in std_logic_vector(63 downto 0);
    frame_user_i   : in std_logic_vector(383 downto 0);

    -- Grid-cycle timing (valid with the accepted frame).
    frame_closes_block_i : in std_logic;
    cycle_mode_i         : in std_logic;
    block_first_sample_i : in std_logic_vector(63 downto 0);
    block_cycle_count_i  : in std_logic_vector(7 downto 0);
    block_nominal_hz_i   : in std_logic_vector(7 downto 0);
    block_flags_i        : in std_logic_vector(2 downto 0);

    -- Shadow configuration and the APPLY toggle.
    shadow_generation_i     : in std_logic_vector(31 downto 0);
    shadow_sample_rate_i    : in std_logic_vector(31 downto 0);
    shadow_window_samples_i : in std_logic_vector(31 downto 0);
    shadow_valid_mask_i     : in std_logic_vector(7 downto 0);
    shadow_enable_i         : in std_logic;
    shadow_dc_remove_i      : in std_logic;
    config_apply_toggle_i   : in std_logic;

    -- VLA frequency snapshot (sampled at the beat).
    frequency_millihz_i  : in std_logic_vector(31 downto 0);
    frequency_status_i   : in std_logic_vector(31 downto 0);
    frequency_period_i   : in std_logic_vector(31 downto 0);
    frequency_sequence_i : in std_logic_vector(31 downto 0);

    -- Capture diagnostics (sampled at the beat).
    capture_frame_count_i   : in std_logic_vector(31 downto 0);
    capture_header_errors_i : in std_logic_vector(31 downto 0);
    capture_overflows_i     : in std_logic_vector(31 downto 0);
    capture_alerts_i        : in std_logic_vector(31 downto 0);

    -- MTR1-v3 record stream (to the exported M_AXIS_MTR1 boundary).
    m_axis_mtr1_tdata  : out std_logic_vector(31 downto 0);
    m_axis_mtr1_tkeep  : out std_logic_vector(3 downto 0);
    m_axis_mtr1_tvalid : out std_logic;
    m_axis_mtr1_tready : in  std_logic;
    m_axis_mtr1_tlast  : out std_logic;

    -- Basic-result beat stream (to the 150/180-cycle aggregator).
    m_result_tdata  : out std_logic_vector(807 downto 0);
    m_result_tvalid : out std_logic;
    m_result_tready : in  std_logic;

    -- Immediate APPLY-commit mirror for the register file.
    active_generation_o : out std_logic_vector(31 downto 0);
    active_enable_o     : out std_logic;
    apply_seen_o        : out std_logic;

    -- Sample beats discarded because the FIFO was full (any nonzero
    -- value at product rates is a fault).
    drop_count_o : out std_logic_vector(31 downto 0)
  );
end entity;

architecture rtl of meter_mtr1_hls_shim is
  -- Sample beat geometry (mtr1_engine.hpp MTR1_IN_*).
  constant BEAT_BITS           : natural := 1264;
  constant IN_SAMPLES_LSB      : natural := 0;
  constant IN_RAW_LSB          : natural := 512;
  constant IN_FRAME_MASK_LSB   : natural := 768;
  constant IN_FRAME_GEN_LSB    : natural := 776;
  constant IN_MALFORMED_BIT    : natural := 808;
  constant IN_CLOSES_BIT       : natural := 809;
  constant IN_CYCLE_MODE_BIT   : natural := 810;
  constant IN_APPLY_BIT        : natural := 811;
  constant IN_ENABLE_BIT       : natural := 812;
  constant IN_DC_REMOVE_BIT    : natural := 813;
  constant IN_CFG_GEN_LSB      : natural := 816;
  constant IN_CFG_RATE_LSB     : natural := 848;
  constant IN_CFG_WINDOW_LSB   : natural := 880;
  constant IN_CFG_MASK_LSB     : natural := 912;
  constant IN_FIRST_SAMPLE_LSB : natural := 920;
  constant IN_CYCLE_COUNT_LSB  : natural := 984;
  constant IN_NOMINAL_LSB      : natural := 992;
  constant IN_BLOCK_FLAGS_LSB  : natural := 1000;
  constant IN_FREQ_MHZ_LSB     : natural := 1008;
  constant IN_FREQ_STATUS_LSB  : natural := 1040;
  constant IN_FREQ_PERIOD_LSB  : natural := 1072;
  constant IN_FREQ_SEQ_LSB     : natural := 1104;
  constant IN_CAP_FRAMES_LSB   : natural := 1136;
  constant IN_CAP_HDRERR_LSB   : natural := 1168;
  constant IN_CAP_OVERFLOW_LSB : natural := 1200;
  constant IN_CAP_ALERTS_LSB   : natural := 1232;

  -- Bound to the packaged-IP customization (SourceData/IP/
  -- hls_mtr1_engine_ip) in the Vivado project; the non-project check
  -- flows bind the same name through tb/hls_mtr1_engine_ip.v.
  component hls_mtr1_engine_ip is
    port (
      ap_clk          : in  std_logic;
      ap_rst_n        : in  std_logic;
      s_sample_TDATA  : in  std_logic_vector(BEAT_BITS - 1 downto 0);
      s_sample_TVALID : in  std_logic;
      s_sample_TREADY : out std_logic;
      m_axis_TDATA    : out std_logic_vector(31 downto 0);
      m_axis_TVALID   : out std_logic;
      m_axis_TREADY   : in  std_logic;
      m_axis_TKEEP    : out std_logic_vector(3 downto 0);
      m_axis_TSTRB    : out std_logic_vector(3 downto 0);
      m_axis_TLAST    : out std_logic_vector(0 downto 0);
      m_result_TDATA  : out std_logic_vector(807 downto 0);
      m_result_TVALID : out std_logic;
      m_result_TREADY : in  std_logic
    );
  end component;

  constant FIFO_DEPTH : natural := 8;
  type beat_fifo_t is array (0 to FIFO_DEPTH - 1) of
    std_logic_vector(BEAT_BITS - 1 downto 0);
  signal fifo_mem   : beat_fifo_t := (others => (others => '0'));
  signal wr_ptr     : natural range 0 to FIFO_DEPTH - 1 := 0;
  signal rd_ptr     : natural range 0 to FIFO_DEPTH - 1 := 0;
  signal fill_level : natural range 0 to FIFO_DEPTH := 0;
  signal drop_count : unsigned(31 downto 0) := (others => '0');

  signal head_valid : std_logic;
  signal head_data  : std_logic_vector(BEAT_BITS - 1 downto 0);
  signal in_ready   : std_logic;

  signal active_generation : std_logic_vector(31 downto 0) := (others => '0');
  signal active_enable     : std_logic := '0';
  signal apply_seen        : std_logic := '0';

  -- One-cycle frame stage: payload captured with the frame, context
  -- sampled at the push (see the provenance note above).
  signal staged_valid  : std_logic := '0';
  signal staged_data   : std_logic_vector(511 downto 0) := (others => '0');
  signal staged_raw    : std_logic_vector(255 downto 0) := (others => '0');
  signal staged_mask   : std_logic_vector(7 downto 0) := (others => '0');
  signal staged_gen    : std_logic_vector(31 downto 0) := (others => '0');
  signal staged_malformed : std_logic := '0';
  signal staged_closes : std_logic := '0';

  signal m_axis_tlast_vec : std_logic_vector(0 downto 0);
  signal m_axis_tstrb     : std_logic_vector(3 downto 0);
begin
  head_valid <= '1' when fill_level /= 0 else '0';
  head_data <= fifo_mem(rd_ptr);

  core : hls_mtr1_engine_ip
    port map (
      ap_clk          => aclk,
      ap_rst_n        => aresetn,
      s_sample_TDATA  => head_data,
      s_sample_TVALID => head_valid,
      s_sample_TREADY => in_ready,
      m_axis_TDATA    => m_axis_mtr1_tdata,
      m_axis_TVALID   => m_axis_mtr1_tvalid,
      m_axis_TREADY   => m_axis_mtr1_tready,
      m_axis_TKEEP    => m_axis_mtr1_tkeep,
      m_axis_TSTRB    => m_axis_tstrb,
      m_axis_TLAST    => m_axis_tlast_vec,
      m_result_TDATA  => m_result_tdata,
      m_result_TVALID => m_result_tvalid,
      m_result_TREADY => m_result_tready
    );
  m_axis_mtr1_tlast <= m_axis_tlast_vec(0);

  active_generation_o <= active_generation;
  active_enable_o <= active_enable;
  apply_seen_o <= apply_seen;
  drop_count_o <= std_logic_vector(drop_count);

  process (aclk)
    variable beat    : std_logic_vector(BEAT_BITS - 1 downto 0);
    variable pushing : boolean;
    variable popping : boolean;
  begin
    if rising_edge(aclk) then
      if aresetn = '0' then
        wr_ptr <= 0;
        rd_ptr <= 0;
        fill_level <= 0;
        drop_count <= (others => '0');
        active_generation <= (others => '0');
        active_enable <= '0';
        apply_seen <= '0';
        staged_valid <= '0';
      else
        -- Immediate APPLY-commit mirror (register-file view). The engine
        -- commits the identical values when the toggled beat reaches it.
        if config_apply_toggle_i /= apply_seen then
          apply_seen <= config_apply_toggle_i;
          active_generation <= shadow_generation_i;
          active_enable <= shadow_enable_i;
        end if;

        popping := head_valid = '1' and in_ready = '1';
        pushing := false;

        -- Push the staged frame (context sampled now, one cycle after the
        -- frame, so a closing frame carries ITS block's just-latched
        -- provenance).
        if staged_valid = '1' then
          if fill_level = FIFO_DEPTH and not popping then
            -- Overflow: drop the staged beat, never the stream.
            drop_count <= drop_count + 1;
          else
            pushing := true;
            beat := (others => '0');
            beat(IN_SAMPLES_LSB + 511 downto IN_SAMPLES_LSB) := staged_data;
            beat(IN_RAW_LSB + 255 downto IN_RAW_LSB) := staged_raw;
            beat(IN_FRAME_MASK_LSB + 7 downto IN_FRAME_MASK_LSB) :=
              staged_mask;
            beat(IN_FRAME_GEN_LSB + 31 downto IN_FRAME_GEN_LSB) := staged_gen;
            beat(IN_MALFORMED_BIT) := staged_malformed;
            beat(IN_CLOSES_BIT) := staged_closes;
            beat(IN_CYCLE_MODE_BIT) := cycle_mode_i;
            beat(IN_APPLY_BIT) := config_apply_toggle_i;
            beat(IN_ENABLE_BIT) := shadow_enable_i;
            beat(IN_DC_REMOVE_BIT) := shadow_dc_remove_i;
            beat(IN_CFG_GEN_LSB + 31 downto IN_CFG_GEN_LSB) :=
              shadow_generation_i;
            beat(IN_CFG_RATE_LSB + 31 downto IN_CFG_RATE_LSB) :=
              shadow_sample_rate_i;
            beat(IN_CFG_WINDOW_LSB + 31 downto IN_CFG_WINDOW_LSB) :=
              shadow_window_samples_i;
            beat(IN_CFG_MASK_LSB + 7 downto IN_CFG_MASK_LSB) :=
              shadow_valid_mask_i;
            beat(IN_FIRST_SAMPLE_LSB + 63 downto IN_FIRST_SAMPLE_LSB) :=
              block_first_sample_i;
            beat(IN_CYCLE_COUNT_LSB + 7 downto IN_CYCLE_COUNT_LSB) :=
              block_cycle_count_i;
            beat(IN_NOMINAL_LSB + 7 downto IN_NOMINAL_LSB) :=
              block_nominal_hz_i;
            beat(IN_BLOCK_FLAGS_LSB + 2 downto IN_BLOCK_FLAGS_LSB) :=
              block_flags_i;
            beat(IN_FREQ_MHZ_LSB + 31 downto IN_FREQ_MHZ_LSB) :=
              frequency_millihz_i;
            beat(IN_FREQ_STATUS_LSB + 31 downto IN_FREQ_STATUS_LSB) :=
              frequency_status_i;
            beat(IN_FREQ_PERIOD_LSB + 31 downto IN_FREQ_PERIOD_LSB) :=
              frequency_period_i;
            beat(IN_FREQ_SEQ_LSB + 31 downto IN_FREQ_SEQ_LSB) :=
              frequency_sequence_i;
            beat(IN_CAP_FRAMES_LSB + 31 downto IN_CAP_FRAMES_LSB) :=
              capture_frame_count_i;
            beat(IN_CAP_HDRERR_LSB + 31 downto IN_CAP_HDRERR_LSB) :=
              capture_header_errors_i;
            beat(IN_CAP_OVERFLOW_LSB + 31 downto IN_CAP_OVERFLOW_LSB) :=
              capture_overflows_i;
            beat(IN_CAP_ALERTS_LSB + 31 downto IN_CAP_ALERTS_LSB) :=
              capture_alerts_i;
            fifo_mem(wr_ptr) <= beat;
            if wr_ptr = FIFO_DEPTH - 1 then
              wr_ptr <= 0;
            else
              wr_ptr <= wr_ptr + 1;
            end if;
          end if;
          staged_valid <= '0';
        end if;

        -- Stage the incoming frame's payload; converted frames arrive at
        -- least several cycles apart, so the single stage never collides
        -- with its own push (which happens first in this process).
        if frame_accept_i = '1' then
          staged_valid <= '1';
          staged_data <= frame_data_i;
          staged_raw <= frame_user_i(383 downto 128);
          staged_mask <= frame_user_i(71 downto 64);
          staged_gen <= frame_user_i(63 downto 32);
          if frame_keep_i /= x"FFFFFFFFFFFFFFFF" then
            staged_malformed <= '1';
          else
            staged_malformed <= '0';
          end if;
          staged_closes <= frame_closes_block_i;
        end if;

        if popping then
          if rd_ptr = FIFO_DEPTH - 1 then
            rd_ptr <= 0;
          else
            rd_ptr <= rd_ptr + 1;
          end if;
        end if;

        if pushing and not popping then
          fill_level <= fill_level + 1;
        elsif popping and not pushing then
          fill_level <= fill_level - 1;
        end if;
      end if;
    end if;
  end process;
end architecture;
