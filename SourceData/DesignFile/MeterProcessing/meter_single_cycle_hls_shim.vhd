library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Sample-beat shim hosting the packaged single-cycle measurement engine
-- (HLS_DesignFile/MeterProcessing/SingleCycleEngine; the beat layout
-- below mirrors single_cycle_engine.hpp SCYC_IN_* in lock step).
--
-- Structure and rules follow meter_mtr1_hls_shim.vhd:
--   * each accepted frame is staged for one cycle and pushed with context
--     sampled at the push. That alignment is load-bearing twice over
--     here: grid_cycle_timing's cycle_boundary_o and cycle_sequence_o are
--     REGISTERED strobes, asserted one aclk after the crossing frame --
--     exactly when that frame sits staged -- so the close marker and the
--     cycle sequence land on the frame that ends the cycle.
--   * the beat FIFO absorbs the engine's record-serialization latency
--     and counts a drop if it ever overflows (never backpressure).
--   * APPLY is carried as a level; the engine detects the edge.
entity meter_single_cycle_hls_shim is
  port (
    aclk    : in std_logic;
    aresetn : in std_logic;

    -- Accepted converted frame (one beat per frame_accept_i pulse).
    frame_accept_i : in std_logic;
    frame_data_i   : in std_logic_vector(511 downto 0);
    frame_keep_i   : in std_logic_vector(63 downto 0);
    frame_user_i   : in std_logic_vector(383 downto 0);

    -- Grid-cycle timing. The boundary/sequence pair is registered (one
    -- aclk after the crossing frame); cycle_mode is a level.
    cycle_boundary_i : in std_logic;
    cycle_sequence_i : in std_logic_vector(31 downto 0);
    cycle_mode_i     : in std_logic;
    block_nominal_hz_i : in std_logic_vector(7 downto 0);
    block_flags_i      : in std_logic_vector(2 downto 0);

    -- Shadow configuration and the APPLY toggle (shared processing set).
    shadow_generation_i   : in std_logic_vector(31 downto 0);
    shadow_sample_rate_i  : in std_logic_vector(31 downto 0);
    shadow_valid_mask_i   : in std_logic_vector(7 downto 0);
    shadow_enable_i       : in std_logic;
    config_apply_toggle_i : in std_logic;

    -- Free-running PL tick (waveform correlation counter) for the
    -- processing timestamp, and the VLA frequency snapshot.
    pl_tick_i            : in std_logic_vector(63 downto 0);
    frequency_millihz_i  : in std_logic_vector(31 downto 0);
    frequency_status_i   : in std_logic_vector(31 downto 0);

    -- SCYC-v1 diagnostic record stream (to the exported M_AXIS_SCYC).
    m_axis_scyc_tdata  : out std_logic_vector(31 downto 0);
    m_axis_scyc_tkeep  : out std_logic_vector(3 downto 0);
    m_axis_scyc_tvalid : out std_logic;
    m_axis_scyc_tready : in  std_logic;
    m_axis_scyc_tlast  : out std_logic;

    -- Single-cycle result beats (the 10/12-cycle tier's input, M7).
    m_result_tdata  : out std_logic_vector(511 downto 0);
    m_result_tvalid : out std_logic;
    m_result_tready : in  std_logic;

    -- Sample beats discarded because the FIFO was full.
    drop_count_o : out std_logic_vector(31 downto 0)
  );
end entity;

architecture rtl of meter_single_cycle_hls_shim is
  -- Sample beat geometry (single_cycle_engine.hpp SCYC_IN_*).
  constant BEAT_BITS          : natural := 1152;
  constant IN_SAMPLES_LSB     : natural := 0;
  constant IN_RAW_LSB         : natural := 512;
  constant IN_FRAME_MASK_LSB  : natural := 768;
  constant IN_FRAME_GEN_LSB   : natural := 776;
  constant IN_MALFORMED_BIT   : natural := 808;
  constant IN_CLOSES_BIT      : natural := 809;
  constant IN_CYCLE_MODE_BIT  : natural := 810;
  constant IN_APPLY_BIT       : natural := 811;
  constant IN_ENABLE_BIT      : natural := 812;
  constant IN_CFG_GEN_LSB     : natural := 816;
  constant IN_CFG_RATE_LSB    : natural := 848;
  constant IN_CFG_MASK_LSB    : natural := 880;
  constant IN_CYCLE_SEQ_LSB   : natural := 896;
  constant IN_NOMINAL_LSB     : natural := 928;
  constant IN_FLAGS_LSB       : natural := 936;
  constant IN_SAMPLE_IDX_LSB  : natural := 960;
  constant IN_PL_TICK_LSB     : natural := 1024;
  constant IN_FREQ_MHZ_LSB    : natural := 1088;
  constant IN_FREQ_STATUS_LSB : natural := 1120;

  component hls_single_cycle_engine_ip is
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
      m_result_TDATA  : out std_logic_vector(511 downto 0);
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

  -- One-cycle frame stage: payload captured with the frame, context
  -- (cycle boundary/sequence, shadow set, tick, frequency) at the push.
  signal staged_valid     : std_logic := '0';
  signal staged_data      : std_logic_vector(511 downto 0) := (others => '0');
  signal staged_raw       : std_logic_vector(255 downto 0) := (others => '0');
  signal staged_mask      : std_logic_vector(7 downto 0) := (others => '0');
  signal staged_gen       : std_logic_vector(31 downto 0) := (others => '0');
  signal staged_index     : std_logic_vector(63 downto 0) := (others => '0');
  signal staged_malformed : std_logic := '0';

  signal m_axis_tlast_vec : std_logic_vector(0 downto 0);
  signal m_axis_tstrb     : std_logic_vector(3 downto 0);
begin
  head_valid <= '1' when fill_level /= 0 else '0';
  head_data <= fifo_mem(rd_ptr);

  core : hls_single_cycle_engine_ip
    port map (
      ap_clk          => aclk,
      ap_rst_n        => aresetn,
      s_sample_TDATA  => head_data,
      s_sample_TVALID => head_valid,
      s_sample_TREADY => in_ready,
      m_axis_TDATA    => m_axis_scyc_tdata,
      m_axis_TVALID   => m_axis_scyc_tvalid,
      m_axis_TREADY   => m_axis_scyc_tready,
      m_axis_TKEEP    => m_axis_scyc_tkeep,
      m_axis_TSTRB    => m_axis_tstrb,
      m_axis_TLAST    => m_axis_tlast_vec,
      m_result_TDATA  => m_result_tdata,
      m_result_TVALID => m_result_tvalid,
      m_result_TREADY => m_result_tready
    );
  m_axis_scyc_tlast <= m_axis_tlast_vec(0);

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
        staged_valid <= '0';
      else
        popping := head_valid = '1' and in_ready = '1';
        pushing := false;

        -- Push the staged frame; context sampled now, one cycle after the
        -- frame, so grid_cycle_timing's registered boundary/sequence pair
        -- lands on the frame that completed the cycle.
        if staged_valid = '1' then
          if fill_level = FIFO_DEPTH and not popping then
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
            beat(IN_CLOSES_BIT) := cycle_boundary_i;
            beat(IN_CYCLE_MODE_BIT) := cycle_mode_i;
            beat(IN_APPLY_BIT) := config_apply_toggle_i;
            beat(IN_ENABLE_BIT) := shadow_enable_i;
            beat(IN_CFG_GEN_LSB + 31 downto IN_CFG_GEN_LSB) :=
              shadow_generation_i;
            beat(IN_CFG_RATE_LSB + 31 downto IN_CFG_RATE_LSB) :=
              shadow_sample_rate_i;
            beat(IN_CFG_MASK_LSB + 7 downto IN_CFG_MASK_LSB) :=
              shadow_valid_mask_i;
            beat(IN_CYCLE_SEQ_LSB + 31 downto IN_CYCLE_SEQ_LSB) :=
              cycle_sequence_i;
            beat(IN_NOMINAL_LSB + 7 downto IN_NOMINAL_LSB) :=
              block_nominal_hz_i;
            beat(IN_FLAGS_LSB + 2 downto IN_FLAGS_LSB) := block_flags_i;
            beat(IN_SAMPLE_IDX_LSB + 63 downto IN_SAMPLE_IDX_LSB) :=
              staged_index;
            beat(IN_PL_TICK_LSB + 63 downto IN_PL_TICK_LSB) := pl_tick_i;
            beat(IN_FREQ_MHZ_LSB + 31 downto IN_FREQ_MHZ_LSB) :=
              frequency_millihz_i;
            beat(IN_FREQ_STATUS_LSB + 31 downto IN_FREQ_STATUS_LSB) :=
              frequency_status_i;
            fifo_mem(wr_ptr) <= beat;
            if wr_ptr = FIFO_DEPTH - 1 then
              wr_ptr <= 0;
            else
              wr_ptr <= wr_ptr + 1;
            end if;
          end if;
          staged_valid <= '0';
        end if;

        -- Stage the incoming frame's payload (push happens first in this
        -- process, so a single stage never collides with itself). The
        -- frame's 64-bit conversion index rides in TUSER: low word in
        -- [31:0], high word in [105:74].
        if frame_accept_i = '1' then
          staged_valid <= '1';
          staged_data <= frame_data_i;
          staged_raw <= frame_user_i(383 downto 128);
          staged_mask <= frame_user_i(71 downto 64);
          staged_gen <= frame_user_i(63 downto 32);
          staged_index <= frame_user_i(105 downto 74) &
                          frame_user_i(31 downto 0);
          if frame_keep_i /= x"FFFFFFFFFFFFFFFF" then
            staged_malformed <= '1';
          else
            staged_malformed <= '0';
          end if;
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
