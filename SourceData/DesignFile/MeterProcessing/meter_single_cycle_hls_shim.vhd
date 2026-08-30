library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library xpm;
use xpm.vcomponents.all;

library work;
use work.metering_pkg.all;

-- Sample-beat shim hosting the packaged single-cycle measurement engine
-- (HLS_DesignFile/MeterProcessing/SingleCycleEngine; the beat layout
-- below mirrors single_cycle_engine.hpp SCYC_IN_* in lock step).
--
-- Structure and rules for the Basic-record path:
--   * each accepted frame is staged for one cycle and pushed with context
--     sampled at the push. That alignment is load-bearing twice over
--     here: grid_cycle_timing's cycle_boundary_o and cycle_sequence_o are
--     REGISTERED strobes, asserted one aclk after the crossing frame --
--     exactly when that frame sits staged -- so the close marker and the
--     cycle sequence land on the frame that ends the cycle.
--   * an asymmetric AMD XPM FIFO accepts one complete 1,024-bit frame and
--     emits 32 ordered 32-bit words to HLS.  BRAM absorbs the engine's
--     finalize/record-serialization latency without a custom wide FIFO or a
--     1,024-bit routed HLS interface.  Overflow is still observational: the
--     capture path is never backpressured and every discarded frame counts.
--   * the diagnostic SCYC stream is isolated by a second AMD XPM FIFO.  HLS
--     is always ready to emit that non-authoritative record; space for all 64
--     words is reserved at record start, otherwise the complete diagnostic
--     record is discarded.  A stalled dashboard/DMA path therefore cannot
--     stall the authoritative m_result stream or make the sample FIFO lose
--     metrology frames.
--   * APPLY is carried as a level; the engine detects the edge.
entity meter_single_cycle_hls_shim is
  port (
    aclk    : in std_logic;
    aresetn : in std_logic;

    -- Accepted converted frame (one beat per frame_accept_i pulse).
    frame_accept_i : in std_logic;
    frame_data_i   : in std_logic_vector(METER_CONVERTED_FRAME_BITS - 1 downto 0);
    frame_keep_i   : in std_logic_vector(METER_CONVERTED_KEEP_BITS - 1 downto 0);
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
    shadow_dc_remove_i    : in std_logic;
    config_apply_toggle_i : in std_logic;

    -- Free-running PL tick (waveform correlation counter) for the
    -- processing timestamp, and the VLA frequency snapshot.
    pl_tick_i            : in std_logic_vector(63 downto 0);
    frequency_millihz_i  : in std_logic_vector(31 downto 0);
    frequency_status_i   : in std_logic_vector(31 downto 0);

    -- SCYC-v5 diagnostic record stream (to the exported M_AXIS_SCYC).
    m_axis_scyc_tdata  : out std_logic_vector(31 downto 0);
    m_axis_scyc_tkeep  : out std_logic_vector(3 downto 0);
    m_axis_scyc_tvalid : out std_logic;
    m_axis_scyc_tready : in  std_logic;
    m_axis_scyc_tlast  : out std_logic;

    -- Single-cycle result packet (221 ordered 32-bit words; the
    -- aggregation tier's internal input contract).
    m_result_tdata  : out std_logic_vector(31 downto 0);
    m_result_tvalid : out std_logic;
    m_result_tready : in  std_logic;

    -- Sample beats discarded because the FIFO was full.
    drop_count_o : out std_logic_vector(31 downto 0)
  );
end entity;

architecture rtl of meter_single_cycle_hls_shim is
  -- Logical sample beat geometry (single_cycle_sample_packet.hpp SCYC_IN_*).
  constant BEAT_BITS          : natural := 1024;
  constant SAMPLE_WORD_BITS   : natural := 32;
  constant IN_SAMPLES_LSB     : natural := 0;
  constant IN_RAW_LSB         : natural := 384;
  constant IN_FRAME_MASK_LSB  : natural := 640;
  constant IN_FRAME_GEN_LSB   : natural := 648;
  constant IN_MALFORMED_BIT   : natural := 680;
  constant IN_CLOSES_BIT      : natural := 681;
  constant IN_CYCLE_MODE_BIT  : natural := 682;
  constant IN_APPLY_BIT       : natural := 683;
  constant IN_ENABLE_BIT      : natural := 684;
  constant IN_DC_REMOVE_BIT   : natural := 685;
  constant IN_CFG_GEN_LSB     : natural := 688;
  constant IN_CFG_RATE_LSB    : natural := 720;
  constant IN_CFG_MASK_LSB    : natural := 752;
  constant IN_CYCLE_SEQ_LSB   : natural := 768;
  constant IN_NOMINAL_LSB     : natural := 800;
  constant IN_FLAGS_LSB       : natural := 808;
  constant IN_SAMPLE_IDX_LSB  : natural := 832;
  constant IN_PL_TICK_LSB     : natural := 896;
  constant IN_FREQ_MHZ_LSB    : natural := 960;
  constant IN_FREQ_STATUS_LSB : natural := 992;

  component hls_single_cycle_engine_ip is
    port (
      ap_clk          : in  std_logic;
      ap_rst_n        : in  std_logic;
      s_sample_TDATA  : in  std_logic_vector(SAMPLE_WORD_BITS - 1 downto 0);
      s_sample_TVALID : in  std_logic;
      s_sample_TREADY : out std_logic;
      m_axis_TDATA    : out std_logic_vector(31 downto 0);
      m_axis_TVALID   : out std_logic;
      m_axis_TREADY   : in  std_logic;
      m_axis_TKEEP    : out std_logic_vector(3 downto 0);
      m_axis_TSTRB    : out std_logic_vector(3 downto 0);
      m_axis_TLAST    : out std_logic_vector(0 downto 0);
      m_result_TDATA  : out std_logic_vector(31 downto 0);
      m_result_TVALID : out std_logic;
      m_result_TREADY : in  std_logic
    );
  end component;

  -- FIFO_WRITE_DEPTH is expressed in complete 1,024-bit frames.  At the
  -- asymmetric 32-bit read port this is 4,096 words.  A 128-frame queue is
  -- deliberately much deeper than the close/finalize burst while remaining
  -- compact BRAM storage; it is not a replacement metrology history buffer.
  constant SAMPLE_FIFO_WRITE_DEPTH     : positive := 128;
  constant SAMPLE_FIFO_WR_COUNT_WIDTH  : positive := 8;
  constant SAMPLE_FIFO_RD_COUNT_WIDTH  : positive := 13;

  -- The diagnostic output is exactly one 64-word record per completed grid
  -- cycle.  A 1,024-word, 32-bit XPM FIFO holds 16 records in one compact
  -- BRAM-backed queue.  Reserving a complete record before accepting its
  -- first word prevents a full FIFO from ever exposing a partial record.
  constant DIAG_RECORD_WORDS         : positive := 64;
  constant DIAG_FIFO_DEPTH           : positive := 1024;
  constant DIAG_FIFO_COUNT_WIDTH     : positive := 11;
  constant DIAG_FIFO_RESERVE_LIMIT   : natural :=
    DIAG_FIFO_DEPTH - DIAG_RECORD_WORDS;

  signal sample_fifo_din     : std_logic_vector(BEAT_BITS - 1 downto 0);
  signal sample_fifo_dout    : std_logic_vector(SAMPLE_WORD_BITS - 1 downto 0);
  signal sample_fifo_write   : std_logic;
  signal sample_fifo_read    : std_logic;
  signal sample_fifo_full    : std_logic;
  signal sample_fifo_empty   : std_logic;
  signal sample_fifo_wr_busy : std_logic;
  signal sample_fifo_rd_busy : std_logic;
  signal sample_fifo_valid   : std_logic;
  signal in_ready            : std_logic;
  signal drop_count          : unsigned(31 downto 0) := (others => '0');

  -- One-cycle frame stage: payload captured with the frame, context
  -- (cycle boundary/sequence, shadow set, tick, frequency) at the push.
  signal staged_valid     : std_logic := '0';
  signal staged_data      : std_logic_vector(METER_CONVERTED_FRAME_BITS - 1 downto 0) := (others => '0');
  signal staged_raw       : std_logic_vector(255 downto 0) := (others => '0');
  signal staged_mask      : std_logic_vector(7 downto 0) := (others => '0');
  signal staged_gen       : std_logic_vector(31 downto 0) := (others => '0');
  signal staged_index     : std_logic_vector(63 downto 0) := (others => '0');
  signal staged_malformed : std_logic := '0';

  signal hls_diag_tdata     : std_logic_vector(31 downto 0);
  signal hls_diag_tkeep     : std_logic_vector(3 downto 0);
  signal hls_diag_tstrb     : std_logic_vector(3 downto 0);
  signal hls_diag_tvalid    : std_logic;
  signal hls_diag_tlast_vec : std_logic_vector(0 downto 0);

  signal diag_fifo_dout     : std_logic_vector(31 downto 0);
  signal diag_fifo_write    : std_logic;
  signal diag_fifo_read     : std_logic;
  signal diag_fifo_full     : std_logic;
  signal diag_fifo_empty    : std_logic;
  signal diag_fifo_wr_busy  : std_logic;
  signal diag_fifo_rd_busy  : std_logic;
  signal diag_fifo_valid    : std_logic;
  -- The queue is synchronous, so this small external occupancy counter is
  -- exact and avoids depending on an optional XPM count port for the atomic
  -- 64-word record reservation.  Storage itself remains an AMD XPM BRAM.
  signal diag_fifo_occupancy : unsigned(DIAG_FIFO_COUNT_WIDTH - 1 downto 0) :=
    (others => '0');
  signal diag_start_allowed : std_logic;
  signal diag_record_keep   : std_logic := '0';
  signal diag_input_word    : natural range 0 to DIAG_RECORD_WORDS - 1 := 0;
  signal diag_output_word   : natural range 0 to DIAG_RECORD_WORDS - 1 := 0;
  signal diag_drop_count    : unsigned(31 downto 0) := (others => '0');
  signal diag_format_errors : unsigned(31 downto 0) := (others => '0');
begin
  -- XPM asymmetric width conversion emits the least-significant 32-bit word
  -- first.  That is the packet order defined by single_cycle_sample_packet.
  sample_fifo_valid <= '1' when sample_fifo_empty = '0' and
                                sample_fifo_rd_busy = '0' else '0';
  sample_fifo_read <= sample_fifo_valid and in_ready;
  sample_fifo_write <= staged_valid and not sample_fifo_full and
                       not sample_fifo_wr_busy;

  -- The HLS diagnostic master is deliberately never backpressured.  At the
  -- first word of each fixed-size record, reserve all 64 FIFO locations.  If
  -- that reservation cannot be made, consume and discard the whole record.
  -- The authoritative m_result output retains its normal handshake.
  diag_start_allowed <= '1' when diag_fifo_wr_busy = '0' and
                                 diag_fifo_full = '0' and
                                 diag_fifo_occupancy <=
                                   to_unsigned(DIAG_FIFO_RESERVE_LIMIT,
                                               DIAG_FIFO_COUNT_WIDTH)
                        else '0';
  diag_fifo_write <= hls_diag_tvalid and diag_start_allowed
                     when diag_input_word = 0 else
                     hls_diag_tvalid and diag_record_keep;

  diag_fifo_valid <= '1' when diag_fifo_empty = '0' and
                              diag_fifo_rd_busy = '0' else '0';
  diag_fifo_read <= diag_fifo_valid and m_axis_scyc_tready;

  m_axis_scyc_tdata  <= diag_fifo_dout;
  m_axis_scyc_tkeep  <= (others => '1');
  m_axis_scyc_tvalid <= diag_fifo_valid;
  m_axis_scyc_tlast  <= '1' when diag_fifo_valid = '1' and
                                diag_output_word = DIAG_RECORD_WORDS - 1
                        else '0';

  core : hls_single_cycle_engine_ip
    port map (
      ap_clk          => aclk,
      ap_rst_n        => aresetn,
      s_sample_TDATA  => sample_fifo_dout,
      s_sample_TVALID => sample_fifo_valid,
      s_sample_TREADY => in_ready,
      m_axis_TDATA    => hls_diag_tdata,
      m_axis_TVALID   => hls_diag_tvalid,
      m_axis_TREADY   => '1',
      m_axis_TKEEP    => hls_diag_tkeep,
      m_axis_TSTRB    => hls_diag_tstrb,
      m_axis_TLAST    => hls_diag_tlast_vec,
      m_result_TDATA  => m_result_tdata,
      m_result_TVALID => m_result_tvalid,
      m_result_TREADY => m_result_tready
    );
  drop_count_o <= std_logic_vector(drop_count);

  sample_frame_fifo : xpm_fifo_sync
    generic map (
      DOUT_RESET_VALUE    => "0",
      ECC_MODE            => "no_ecc",
      FIFO_MEMORY_TYPE    => "block",
      FIFO_READ_LATENCY   => 0,
      FIFO_WRITE_DEPTH    => SAMPLE_FIFO_WRITE_DEPTH,
      FULL_RESET_VALUE    => 0,
      PROG_EMPTY_THRESH   => 10,
      PROG_FULL_THRESH    => SAMPLE_FIFO_WRITE_DEPTH - 8,
      RD_DATA_COUNT_WIDTH => SAMPLE_FIFO_RD_COUNT_WIDTH,
      READ_DATA_WIDTH     => SAMPLE_WORD_BITS,
      READ_MODE           => "fwft",
      SIM_ASSERT_CHK      => 1,
      USE_ADV_FEATURES    => "1000",
      WAKEUP_TIME         => 0,
      WRITE_DATA_WIDTH    => BEAT_BITS,
      WR_DATA_COUNT_WIDTH => SAMPLE_FIFO_WR_COUNT_WIDTH
    )
    port map (
      sleep => '0',
      rst => not aresetn,
      wr_clk => aclk,
      wr_en => sample_fifo_write,
      din => sample_fifo_din,
      full => sample_fifo_full,
      overflow => open,
      wr_rst_busy => sample_fifo_wr_busy,
      rd_en => sample_fifo_read,
      dout => sample_fifo_dout,
      empty => sample_fifo_empty,
      underflow => open,
      rd_rst_busy => sample_fifo_rd_busy,
      data_valid => open,
      almost_empty => open,
      almost_full => open,
      prog_empty => open,
      prog_full => open,
      rd_data_count => open,
      wr_data_count => open,
      wr_ack => open,
      injectsbiterr => '0',
      injectdbiterr => '0',
      sbiterr => open,
      dbiterr => open
    );

  -- Narrow storage is intentional.  A 2,048-bit atomic write port would
  -- require many shallow BRAM slices and create a wide routed bus.  The
  -- fixed-record reservation above gives the same all-or-drop behavior while
  -- keeping the queue 32 bits wide and compact.
  diagnostic_record_fifo : xpm_fifo_sync
    generic map (
      DOUT_RESET_VALUE    => "0",
      ECC_MODE            => "no_ecc",
      FIFO_MEMORY_TYPE    => "block",
      FIFO_READ_LATENCY   => 0,
      FIFO_WRITE_DEPTH    => DIAG_FIFO_DEPTH,
      FULL_RESET_VALUE    => 0,
      PROG_EMPTY_THRESH   => 2,
      PROG_FULL_THRESH    => DIAG_FIFO_RESERVE_LIMIT,
      RD_DATA_COUNT_WIDTH => DIAG_FIFO_COUNT_WIDTH,
      READ_DATA_WIDTH     => 32,
      READ_MODE           => "fwft",
      SIM_ASSERT_CHK      => 1,
      USE_ADV_FEATURES    => "0000",
      WAKEUP_TIME         => 0,
      WRITE_DATA_WIDTH    => 32,
      WR_DATA_COUNT_WIDTH => DIAG_FIFO_COUNT_WIDTH
    )
    port map (
      sleep => '0',
      rst => not aresetn,
      wr_clk => aclk,
      wr_en => diag_fifo_write,
      din => hls_diag_tdata,
      full => diag_fifo_full,
      overflow => open,
      wr_rst_busy => diag_fifo_wr_busy,
      rd_en => diag_fifo_read,
      dout => diag_fifo_dout,
      empty => diag_fifo_empty,
      underflow => open,
      rd_rst_busy => diag_fifo_rd_busy,
      data_valid => open,
      almost_empty => open,
      almost_full => open,
      prog_empty => open,
      prog_full => open,
      rd_data_count => open,
      wr_data_count => open,
      wr_ack => open,
      injectsbiterr => '0',
      injectdbiterr => '0',
      sbiterr => open,
      dbiterr => open
    );

  -- Track the fixed HLS record boundary independently of TLAST.  TLAST and
  -- byte qualifiers are checked as contract diagnostics, while the exported
  -- stream regenerates a clean boundary every 64 words.
  process (aclk)
  begin
    if rising_edge(aclk) then
      if aresetn = '0' then
        diag_record_keep <= '0';
        diag_input_word <= 0;
        diag_output_word <= 0;
        diag_fifo_occupancy <= (others => '0');
        diag_drop_count <= (others => '0');
        diag_format_errors <= (others => '0');
      else
        -- Count accepted XPM transactions.  A simultaneous push/pop leaves
        -- occupancy unchanged; record admission is decided only at word 0.
        if diag_fifo_write = '1' and diag_fifo_read = '0' then
          diag_fifo_occupancy <= diag_fifo_occupancy + 1;
        elsif diag_fifo_write = '0' and diag_fifo_read = '1' then
          diag_fifo_occupancy <= diag_fifo_occupancy - 1;
        end if;

        if hls_diag_tvalid = '1' then
          if diag_input_word = 0 then
            diag_record_keep <= diag_start_allowed;
            if diag_start_allowed = '0' then
              diag_drop_count <= diag_drop_count + 1;
            end if;
          end if;

          if hls_diag_tkeep /= "1111" or hls_diag_tstrb /= "1111" then
            diag_format_errors <= diag_format_errors + 1;
          elsif diag_input_word = DIAG_RECORD_WORDS - 1 then
            if hls_diag_tlast_vec(0) /= '1' then
              diag_format_errors <= diag_format_errors + 1;
            end if;
          elsif hls_diag_tlast_vec(0) /= '0' then
            diag_format_errors <= diag_format_errors + 1;
          end if;

          if diag_input_word = DIAG_RECORD_WORDS - 1 then
            diag_input_word <= 0;
            diag_record_keep <= '0';
          else
            diag_input_word <= diag_input_word + 1;
          end if;
        end if;

        if diag_fifo_read = '1' then
          if diag_output_word = DIAG_RECORD_WORDS - 1 then
            diag_output_word <= 0;
          else
            diag_output_word <= diag_output_word + 1;
          end if;
        end if;
      end if;
    end if;
  end process;

  -- Assemble the atomic wide write from the staged frame and the registered
  -- one-cycle-later timing context.  This wide vector is local to the XPM
  -- write port; it no longer crosses the HLS hierarchy or feeds custom
  -- distributed storage.
  process (all)
    variable beat : std_logic_vector(BEAT_BITS - 1 downto 0);
  begin
    beat := (others => '0');
    beat(IN_SAMPLES_LSB + METER_CONVERTED_FRAME_BITS - 1 downto
         IN_SAMPLES_LSB) := staged_data;
    beat(IN_RAW_LSB + 255 downto IN_RAW_LSB) := staged_raw;
    beat(IN_FRAME_MASK_LSB + 7 downto IN_FRAME_MASK_LSB) := staged_mask;
    beat(IN_FRAME_GEN_LSB + 31 downto IN_FRAME_GEN_LSB) := staged_gen;
    beat(IN_MALFORMED_BIT) := staged_malformed;
    beat(IN_CLOSES_BIT) := cycle_boundary_i;
    beat(IN_CYCLE_MODE_BIT) := cycle_mode_i;
    beat(IN_APPLY_BIT) := config_apply_toggle_i;
    beat(IN_ENABLE_BIT) := shadow_enable_i;
    beat(IN_DC_REMOVE_BIT) := shadow_dc_remove_i;
    beat(IN_CFG_GEN_LSB + 31 downto IN_CFG_GEN_LSB) := shadow_generation_i;
    beat(IN_CFG_RATE_LSB + 31 downto IN_CFG_RATE_LSB) := shadow_sample_rate_i;
    beat(IN_CFG_MASK_LSB + 7 downto IN_CFG_MASK_LSB) := shadow_valid_mask_i;
    beat(IN_CYCLE_SEQ_LSB + 31 downto IN_CYCLE_SEQ_LSB) := cycle_sequence_i;
    beat(IN_NOMINAL_LSB + 7 downto IN_NOMINAL_LSB) := block_nominal_hz_i;
    beat(IN_FLAGS_LSB + 2 downto IN_FLAGS_LSB) := block_flags_i;
    beat(IN_SAMPLE_IDX_LSB + 63 downto IN_SAMPLE_IDX_LSB) := staged_index;
    beat(IN_PL_TICK_LSB + 63 downto IN_PL_TICK_LSB) := pl_tick_i;
    beat(IN_FREQ_MHZ_LSB + 31 downto IN_FREQ_MHZ_LSB) :=
      frequency_millihz_i;
    beat(IN_FREQ_STATUS_LSB + 31 downto IN_FREQ_STATUS_LSB) :=
      frequency_status_i;
    sample_fifo_din <= beat;
  end process;

  process (aclk)
  begin
    if rising_edge(aclk) then
      if aresetn = '0' then
        drop_count <= (others => '0');
        staged_valid <= '0';
      else
        -- The write port consumes staged_valid on this edge.  If XPM cannot
        -- accept it, report the drop but never drive capture backpressure.
        if staged_valid = '1' then
          if sample_fifo_full = '1' or sample_fifo_wr_busy = '1' then
            drop_count <= drop_count + 1;
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
          if frame_keep_i /= (frame_keep_i'range => '1') then
            staged_malformed <= '1';
          else
            staged_malformed <= '0';
          end if;
        end if;

      end if;
    end if;
  end process;
end architecture;
