library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library xpm;
use xpm.vcomponents.all;

-- Integration shim for the shared HLS aggregation engine.
--
-- The single-cycle engine emits one fixed packet of 221 ordered 32-bit
-- words.  This shim captures the live configuration/context when word zero
-- is accepted, forwards all 221 measurement words, and appends 13 captured
-- context words.  The aggregation engine therefore receives one fixed
-- 234-word packet per grid cycle.
--
-- This narrow serializer replaces the former 7,488-bit AXI beat and skid
-- register.  It preserves packet atomicity and every measurement field while
-- removing a high-fanout, independently enabled datapath that prevented
-- efficient physical CLB packing.
--
-- A BRAM-backed XPM FIFO decouples packet capture from the deliberately
-- serialized aggregation/finalize engine.  Real grid cycles provide ample
-- processing time, while the FIFO also absorbs diagnostic bursts whose cycle
-- cadence is intentionally much faster than a physical 50/60 Hz source.
entity meter_aggregation_hls_shim is
  port (
    aclk    : in std_logic;
    aresetn : in std_logic;

    -- Single-cycle result packet (221 ordered 32-bit words).
    s_result_tdata  : in  std_logic_vector(31 downto 0);
    s_result_tvalid : in  std_logic;
    s_result_tready : out std_logic;

    -- Live grid-timing view for per-cycle lock/fallback provenance.
    cycle_locked_i   : in std_logic;
    cycle_fallback_i : in std_logic;

    -- Shadow configuration and the shared APPLY toggle.
    shadow_generation_i   : in std_logic_vector(31 downto 0);
    shadow_sample_rate_i  : in std_logic_vector(31 downto 0);
    shadow_valid_mask_i   : in std_logic_vector(7 downto 0);
    shadow_enable_i       : in std_logic;
    shadow_dc_remove_i    : in std_logic;
    config_apply_toggle_i : in std_logic;

    -- Frequency and capture context (record words 56..63).
    frequency_status_i     : in std_logic_vector(31 downto 0);
    frequency_period_i     : in std_logic_vector(31 downto 0);
    frequency_sequence_i   : in std_logic_vector(31 downto 0);
    capture_frame_count_i   : in std_logic_vector(31 downto 0);
    capture_header_errors_i : in std_logic_vector(31 downto 0);
    capture_overflows_i     : in std_logic_vector(31 downto 0);
    capture_alerts_i        : in std_logic_vector(31 downto 0);

    ten_minute_target_sample_i : in std_logic_vector(63 downto 0);
    ten_minute_target_valid_i  : in std_logic;
    ten_minute_target_update_i : in std_logic;

    -- BASIC-v4 record stream (to the exported M_AXIS_MTR1 boundary).
    m_axis_basic_tdata  : out std_logic_vector(31 downto 0);
    m_axis_basic_tkeep  : out std_logic_vector(3 downto 0);
    m_axis_basic_tvalid : out std_logic;
    m_axis_basic_tready : in  std_logic;
    m_axis_basic_tlast  : out std_logic;

    -- Completed/open aggregate record stream.
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
  constant RESULT_WORDS  : positive := 221;
  constant CONTEXT_WORDS : positive := 13;

  -- Sixteen packet contexts cap the number of accepted in-flight packets.
  -- Sixteen complete result packets occupy 3,536 of the 4,096 result-word
  -- entries, so a packet that has started can always finish without being
  -- backpressured part-way through its 221-word transfer.
  constant RESULT_FIFO_DEPTH       : positive := 4096;
  constant RESULT_FIFO_COUNT_WIDTH : positive := 13;
  constant CONTEXT_FIFO_DEPTH       : positive := 16;
  constant CONTEXT_FIFO_COUNT_WIDTH : positive := 5;
  constant CONTEXT_BITS             : positive := CONTEXT_WORDS * 32;

  -- Context word layout; mirrored by aggregation_engine.hpp.
  constant CONTEXT_INDEX_CFG_GENERATION : natural := 0;
  constant CONTEXT_INDEX_CFG_RATE       : natural := 1;
  constant CONTEXT_INDEX_CONTROL        : natural := 2;
  constant CONTEXT_INDEX_FREQ_STATUS    : natural := 3;
  constant CONTEXT_INDEX_FREQ_PERIOD    : natural := 4;
  constant CONTEXT_INDEX_FREQ_SEQUENCE  : natural := 5;
  constant CONTEXT_INDEX_CAP_FRAMES     : natural := 6;
  constant CONTEXT_INDEX_CAP_HDRERR     : natural := 7;
  constant CONTEXT_INDEX_CAP_OVERFLOW   : natural := 8;
  constant CONTEXT_INDEX_CAP_ALERTS     : natural := 9;
  constant CONTEXT_INDEX_TARGET_LOW     : natural := 10;
  constant CONTEXT_INDEX_TARGET_HIGH    : natural := 11;

  constant CTL_ENABLE_BIT    : natural := 8;
  constant CTL_DC_REMOVE_BIT : natural := 9;
  constant CTL_APPLY_BIT     : natural := 10;
  constant CTL_LOCKED_BIT    : natural := 11;
  constant CTL_FALLBACK_BIT  : natural := 12;

  component hls_aggregation_engine_ip is
    port (
      ap_clk          : in  std_logic;
      ap_rst_n        : in  std_logic;
      s_result_TDATA  : in  std_logic_vector(31 downto 0);
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

  type output_phase_t is (OUTPUT_RESULT, OUTPUT_CONTEXT);
  signal output_phase         : output_phase_t := OUTPUT_RESULT;
  signal input_result_index   : natural range 0 to RESULT_WORDS - 1 := 0;
  signal output_result_index  : natural range 0 to RESULT_WORDS - 1 := 0;
  signal output_context_index : natural range 0 to CONTEXT_WORDS - 1 := 0;

  -- Result words and their context snapshots use independent AMD FIFOs.
  -- This is intentionally not one interleaved FIFO: appending 13 context
  -- words to a single write port briefly deasserted s_result_tready and could
  -- overflow the observational sample FIFO in compressed simulations.  With
  -- two queues, context serialization on the read side never pauses capture.
  signal result_fifo_write   : std_logic;
  signal result_fifo_read    : std_logic;
  signal result_fifo_dout    : std_logic_vector(31 downto 0);
  signal result_fifo_full    : std_logic;
  signal result_fifo_empty   : std_logic;
  signal result_fifo_wr_busy : std_logic;
  signal result_fifo_rd_busy : std_logic;

  signal context_fifo_write   : std_logic;
  signal context_fifo_read    : std_logic;
  signal context_fifo_din     : std_logic_vector(CONTEXT_BITS - 1 downto 0);
  signal context_fifo_dout    : std_logic_vector(CONTEXT_BITS - 1 downto 0);
  signal context_fifo_full    : std_logic;
  signal context_fifo_empty   : std_logic;
  signal context_fifo_wr_busy : std_logic;
  signal context_fifo_rd_busy : std_logic;

  signal input_ready_word      : std_logic;
  signal engine_data           : std_logic_vector(31 downto 0);
  signal engine_valid          : std_logic;
  signal engine_ready          : std_logic;
  signal selected_context_word : std_logic_vector(31 downto 0);

  signal basic_tlast_vec : std_logic_vector(0 downto 0);
  signal agg_tlast_vec   : std_logic_vector(0 downto 0);
  signal basic_tstrb_nc  : std_logic_vector(3 downto 0);
  signal agg_tstrb_nc    : std_logic_vector(3 downto 0);

  signal active_generation : std_logic_vector(31 downto 0) := (others => '0');
  signal active_enable     : std_logic := '0';
  signal apply_seen        : std_logic := '0';
begin
  core : hls_aggregation_engine_ip
    port map (
      ap_clk          => aclk,
      ap_rst_n        => aresetn,
      s_result_TDATA  => engine_data,
      s_result_TVALID => engine_valid,
      s_result_TREADY => engine_ready,
      m_basic_TDATA   => m_axis_basic_tdata,
      m_basic_TVALID  => m_axis_basic_tvalid,
      m_basic_TREADY  => m_axis_basic_tready,
      m_basic_TKEEP   => m_axis_basic_tkeep,
      m_basic_TSTRB   => basic_tstrb_nc,
      m_basic_TLAST   => basic_tlast_vec,
      m_agg_TDATA     => m_axis_agg_tdata,
      m_agg_TVALID    => m_axis_agg_tvalid,
      m_agg_TREADY    => m_axis_agg_tready,
      m_agg_TKEEP     => m_axis_agg_tkeep,
      m_agg_TSTRB     => agg_tstrb_nc,
      m_agg_TLAST     => agg_tlast_vec
    );

  m_axis_basic_tlast <= basic_tlast_vec(0);
  m_axis_agg_tlast <= agg_tlast_vec(0);
  active_generation_o <= active_generation;
  active_enable_o <= active_enable;
  apply_seen_o <= apply_seen;

  -- A context slot is reserved together with word zero.  Once a packet has
  -- started, the context queue limits guarantee enough result-word capacity
  -- for the remaining 220 words, so READY does not pulse low within a packet.
  input_ready_word <= '1' when result_fifo_full = '0' and
                              result_fifo_wr_busy = '0' and
                              (input_result_index /= 0 or
                               (context_fifo_full = '0' and
                                context_fifo_wr_busy = '0')) else '0';
  s_result_tready <= input_ready_word;
  result_fifo_write <= s_result_tvalid and input_ready_word;
  context_fifo_write <= result_fifo_write when input_result_index = 0 else '0';

  result_word_fifo : xpm_fifo_sync
    generic map (
      DOUT_RESET_VALUE    => "0",
      ECC_MODE            => "no_ecc",
      FIFO_MEMORY_TYPE    => "block",
      FIFO_READ_LATENCY   => 0,
      FIFO_WRITE_DEPTH    => RESULT_FIFO_DEPTH,
      FULL_RESET_VALUE    => 0,
      PROG_EMPTY_THRESH   => 10,
      PROG_FULL_THRESH    => RESULT_FIFO_DEPTH - 8,
      RD_DATA_COUNT_WIDTH => RESULT_FIFO_COUNT_WIDTH,
      READ_DATA_WIDTH     => 32,
      READ_MODE           => "fwft",
      SIM_ASSERT_CHK      => 1,
      USE_ADV_FEATURES    => "1000",
      WAKEUP_TIME         => 0,
      WRITE_DATA_WIDTH    => 32,
      WR_DATA_COUNT_WIDTH => RESULT_FIFO_COUNT_WIDTH
    )
    port map (
      sleep => '0',
      rst => not aresetn,
      wr_clk => aclk,
      wr_en => result_fifo_write,
      din => s_result_tdata,
      full => result_fifo_full,
      overflow => open,
      wr_rst_busy => result_fifo_wr_busy,
      rd_en => result_fifo_read,
      dout => result_fifo_dout,
      empty => result_fifo_empty,
      underflow => open,
      rd_rst_busy => result_fifo_rd_busy,
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

  -- Capture all 13 words atomically at the first result-word handshake.  The
  -- wide value exists only at this small BRAM FIFO boundary; it is not a
  -- high-fanout datapath and is read out one 32-bit word at a time.
  process (all)
    variable snapshot       : std_logic_vector(CONTEXT_BITS - 1 downto 0);
    variable control_word   : std_logic_vector(31 downto 0);
    variable target_control : std_logic_vector(31 downto 0);
  begin
    snapshot := (others => '0');
    control_word := (others => '0');
    control_word(7 downto 0) := shadow_valid_mask_i;
    control_word(CTL_ENABLE_BIT) := shadow_enable_i;
    control_word(CTL_DC_REMOVE_BIT) := shadow_dc_remove_i;
    control_word(CTL_APPLY_BIT) := config_apply_toggle_i;
    control_word(CTL_LOCKED_BIT) := cycle_locked_i;
    control_word(CTL_FALLBACK_BIT) := cycle_fallback_i;

    target_control := (others => '0');
    target_control(0) := ten_minute_target_valid_i;
    target_control(1) := ten_minute_target_update_i;

    snapshot((CONTEXT_INDEX_CFG_GENERATION + 1) * 32 - 1 downto
             CONTEXT_INDEX_CFG_GENERATION * 32) := shadow_generation_i;
    snapshot((CONTEXT_INDEX_CFG_RATE + 1) * 32 - 1 downto
             CONTEXT_INDEX_CFG_RATE * 32) := shadow_sample_rate_i;
    snapshot((CONTEXT_INDEX_CONTROL + 1) * 32 - 1 downto
             CONTEXT_INDEX_CONTROL * 32) := control_word;
    snapshot((CONTEXT_INDEX_FREQ_STATUS + 1) * 32 - 1 downto
             CONTEXT_INDEX_FREQ_STATUS * 32) := frequency_status_i;
    snapshot((CONTEXT_INDEX_FREQ_PERIOD + 1) * 32 - 1 downto
             CONTEXT_INDEX_FREQ_PERIOD * 32) := frequency_period_i;
    snapshot((CONTEXT_INDEX_FREQ_SEQUENCE + 1) * 32 - 1 downto
             CONTEXT_INDEX_FREQ_SEQUENCE * 32) := frequency_sequence_i;
    snapshot((CONTEXT_INDEX_CAP_FRAMES + 1) * 32 - 1 downto
             CONTEXT_INDEX_CAP_FRAMES * 32) := capture_frame_count_i;
    snapshot((CONTEXT_INDEX_CAP_HDRERR + 1) * 32 - 1 downto
             CONTEXT_INDEX_CAP_HDRERR * 32) := capture_header_errors_i;
    snapshot((CONTEXT_INDEX_CAP_OVERFLOW + 1) * 32 - 1 downto
             CONTEXT_INDEX_CAP_OVERFLOW * 32) := capture_overflows_i;
    snapshot((CONTEXT_INDEX_CAP_ALERTS + 1) * 32 - 1 downto
             CONTEXT_INDEX_CAP_ALERTS * 32) := capture_alerts_i;
    snapshot((CONTEXT_INDEX_TARGET_LOW + 1) * 32 - 1 downto
             CONTEXT_INDEX_TARGET_LOW * 32) :=
      ten_minute_target_sample_i(31 downto 0);
    snapshot((CONTEXT_INDEX_TARGET_HIGH + 1) * 32 - 1 downto
             CONTEXT_INDEX_TARGET_HIGH * 32) :=
      ten_minute_target_sample_i(63 downto 32);
    snapshot(CONTEXT_BITS - 1 downto (CONTEXT_WORDS - 1) * 32) :=
      target_control;
    context_fifo_din <= snapshot;
  end process;

  context_snapshot_fifo : xpm_fifo_sync
    generic map (
      DOUT_RESET_VALUE    => "0",
      ECC_MODE            => "no_ecc",
      FIFO_MEMORY_TYPE    => "block",
      FIFO_READ_LATENCY   => 0,
      FIFO_WRITE_DEPTH    => CONTEXT_FIFO_DEPTH,
      FULL_RESET_VALUE    => 0,
      PROG_EMPTY_THRESH   => 10,
      PROG_FULL_THRESH    => CONTEXT_FIFO_DEPTH - 8,
      RD_DATA_COUNT_WIDTH => CONTEXT_FIFO_COUNT_WIDTH,
      READ_DATA_WIDTH     => CONTEXT_BITS,
      READ_MODE           => "fwft",
      SIM_ASSERT_CHK      => 1,
      USE_ADV_FEATURES    => "1000",
      WAKEUP_TIME         => 0,
      WRITE_DATA_WIDTH    => CONTEXT_BITS,
      WR_DATA_COUNT_WIDTH => CONTEXT_FIFO_COUNT_WIDTH
    )
    port map (
      sleep => '0',
      rst => not aresetn,
      wr_clk => aclk,
      wr_en => context_fifo_write,
      din => context_fifo_din,
      full => context_fifo_full,
      overflow => open,
      wr_rst_busy => context_fifo_wr_busy,
      rd_en => context_fifo_read,
      dout => context_fifo_dout,
      empty => context_fifo_empty,
      underflow => open,
      rd_rst_busy => context_fifo_rd_busy,
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

  -- The read side reconstructs the HLS input packet without widening the AXI
  -- boundary: 221 result words followed by the matching 13-word snapshot.
  selected_context_word <= context_fifo_dout(
    (output_context_index + 1) * 32 - 1 downto
    output_context_index * 32);
  engine_data <= result_fifo_dout when output_phase = OUTPUT_RESULT else
                 selected_context_word;
  engine_valid <= '1' when output_phase = OUTPUT_RESULT and
                           result_fifo_empty = '0' and
                           result_fifo_rd_busy = '0' and
                           context_fifo_empty = '0' and
                           context_fifo_rd_busy = '0' else
                  '1' when output_phase = OUTPUT_CONTEXT and
                           context_fifo_empty = '0' and
                           context_fifo_rd_busy = '0' else
                  '0';
  result_fifo_read <= engine_valid and engine_ready
    when output_phase = OUTPUT_RESULT else '0';
  context_fifo_read <= engine_valid and engine_ready
    when output_phase = OUTPUT_CONTEXT and
         output_context_index = CONTEXT_WORDS - 1 else '0';

  process (aclk)
  begin
    if rising_edge(aclk) then
      if aresetn = '0' then
        input_result_index <= 0;
        output_phase <= OUTPUT_RESULT;
        output_result_index <= 0;
        output_context_index <= 0;
        active_generation <= (others => '0');
        active_enable <= '0';
        apply_seen <= '0';
      else
        -- Immediate APPLY mirror for the processing register file.  The HLS
        -- engine observes the same captured level in the next packet.
        if config_apply_toggle_i /= apply_seen then
          apply_seen <= config_apply_toggle_i;
          active_generation <= shadow_generation_i;
          active_enable <= shadow_enable_i;
        end if;

        if result_fifo_write = '1' then
          if input_result_index = RESULT_WORDS - 1 then
            input_result_index <= 0;
          else
            input_result_index <= input_result_index + 1;
          end if;
        end if;

        if engine_valid = '1' and engine_ready = '1' then
          if output_phase = OUTPUT_RESULT then
            if output_result_index = RESULT_WORDS - 1 then
              output_result_index <= 0;
              output_context_index <= 0;
              output_phase <= OUTPUT_CONTEXT;
            else
              output_result_index <= output_result_index + 1;
            end if;
          else
            if output_context_index = CONTEXT_WORDS - 1 then
              output_context_index <= 0;
              output_phase <= OUTPUT_RESULT;
            else
              output_context_index <= output_context_index + 1;
            end if;
          end if;
        end if;
      end if;
    end if;
  end process;
end architecture;
