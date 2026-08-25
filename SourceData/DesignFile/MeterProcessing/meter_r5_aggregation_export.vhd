library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library xpm;
use xpm.vcomponents.all;

use work.meter_r5_aggregation_pkg.all;

-- Packetized export of the exact SingleCycleEngine sufficient-stat result to
-- R5C1.  This diagnostic/offload branch must never backpressure the metrology
-- producer.  At word zero it either reserves storage for the complete packet
-- or selects whole-packet discard; both choices continue accepting every
-- source word through the packet boundary.  A congested R5 transport can
-- therefore lose an explicitly counted export packet, but it cannot disturb
-- the SingleCycle engine or any other measurement path.
entity meter_r5_aggregation_export is
  generic (
    -- Retained for source compatibility with the migration build.  Both
    -- modes now use identical non-blocking whole-packet capture semantics.
    G_AUTHORITATIVE_INPUT : boolean := false
  );
  port (
    aclk    : in std_logic;
    aresetn : in std_logic;

    result_word_valid_i : in  std_logic;
    result_word_ready_o : out std_logic;
    result_word_i       : in  std_logic_vector(31 downto 0);

    cycle_locked_i   : in std_logic;
    cycle_fallback_i : in std_logic;

    shadow_generation_i   : in std_logic_vector(31 downto 0);
    shadow_sample_rate_i  : in std_logic_vector(31 downto 0);
    shadow_valid_mask_i   : in std_logic_vector(7 downto 0);
    shadow_enable_i       : in std_logic;
    shadow_dc_remove_i    : in std_logic;
    config_apply_toggle_i : in std_logic;

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

    m_axis_tdata  : out std_logic_vector(31 downto 0);
    m_axis_tkeep  : out std_logic_vector(3 downto 0);
    m_axis_tvalid : out std_logic;
    m_axis_tready : in  std_logic;
    m_axis_tlast  : out std_logic;

    accepted_packet_count_o  : out std_logic_vector(31 downto 0);
    dropped_packet_count_o   : out std_logic_vector(31 downto 0);
    transmitted_packet_count_o : out std_logic_vector(31 downto 0);
    framing_error_count_o    : out std_logic_vector(31 downto 0);
    last_sequence_o          : out std_logic_vector(31 downto 0);
    queue_level_o            : out std_logic_vector(7 downto 0);
    status_o                 : out std_logic_vector(31 downto 0)
  );
end entity;

architecture rtl of meter_r5_aggregation_export is
  constant RESULT_FIFO_DEPTH       : positive := 4096;
  constant RESULT_FIFO_COUNT_WIDTH : positive := 13;
  constant CONTEXT_FIFO_DEPTH       : positive := 16;
  constant CONTEXT_FIFO_COUNT_WIDTH : positive := 5;
  constant CONTEXT_BITS             : positive := R5_AGG_CONTEXT_WORDS * 32;

  type output_phase_t is (OUTPUT_IDLE, OUTPUT_HEADER, OUTPUT_RESULT,
                          OUTPUT_CONTEXT, OUTPUT_CRC);

  signal input_index       : natural range 0 to R5_AGG_RESULT_WORDS - 1 := 0;
  signal input_ready       : std_logic;
  signal input_accept      : std_logic;
  signal capture_packet    : std_logic := '0';
  signal reserve_packet    : std_logic;
  signal capture_current_word : std_logic;
  signal result_fifo_write : std_logic;
  signal context_fifo_write: std_logic;
  signal context_snapshot  : std_logic_vector(CONTEXT_BITS - 1 downto 0);

  signal result_fifo_read     : std_logic;
  signal result_fifo_dout     : std_logic_vector(31 downto 0);
  signal result_fifo_full     : std_logic;
  signal result_fifo_empty    : std_logic;
  signal result_fifo_overflow : std_logic;
  signal result_fifo_underflow: std_logic;
  signal result_fifo_wr_busy  : std_logic;
  signal result_fifo_rd_busy  : std_logic;
  signal result_fifo_count    : std_logic_vector(RESULT_FIFO_COUNT_WIDTH - 1 downto 0);

  signal context_fifo_read     : std_logic;
  signal context_fifo_dout     : std_logic_vector(CONTEXT_BITS - 1 downto 0);
  signal context_fifo_full     : std_logic;
  signal context_fifo_empty    : std_logic;
  signal context_fifo_overflow : std_logic;
  signal context_fifo_underflow: std_logic;
  signal context_fifo_wr_busy  : std_logic;
  signal context_fifo_rd_busy  : std_logic;
  signal context_fifo_count    : std_logic_vector(CONTEXT_FIFO_COUNT_WIDTH - 1 downto 0);

  signal output_phase         : output_phase_t := OUTPUT_IDLE;
  signal output_header_index  : natural range 0 to R5_AGG_HEADER_WORDS - 1 := 0;
  signal output_result_index  : natural range 0 to R5_AGG_RESULT_WORDS - 1 := 0;
  signal output_context_index : natural range 0 to R5_AGG_CONTEXT_WORDS - 1 := 0;
  signal output_word          : std_logic_vector(31 downto 0);
  signal output_valid         : std_logic;
  signal output_last          : std_logic;
  signal output_accept        : std_logic;
  signal crc_state            : std_logic_vector(31 downto 0) := R5_AGG_CRC_INITIAL;

  signal complete_packet_count : unsigned(4 downto 0) := (others => '0');
  -- XPM FWFT FIFOs can expose additional output-stage capacity beyond their
  -- configured RAM depth.  Do not use the FIFO's delayed data count as the
  -- packet-admission authority: doing so can accept more contexts than the
  -- matching complete-packet counter can represent.  This credit counter
  -- includes the packet currently being captured, every completed packet,
  -- and the packet currently being serialized.
  signal reserved_packet_count : unsigned(4 downto 0) := (others => '0');
  signal packet_reserve_pulse  : std_logic;
  signal packet_complete_pulse : std_logic;
  signal packet_sent_pulse     : std_logic;

  signal accepted_packet_count    : unsigned(31 downto 0) := (others => '0');
  signal dropped_packet_count     : unsigned(31 downto 0) := (others => '0');
  signal transmitted_packet_count : unsigned(31 downto 0) := (others => '0');
  signal framing_error_count      : unsigned(31 downto 0) := (others => '0');
  signal last_sequence            : std_logic_vector(31 downto 0) := (others => '0');
  signal framing_error_sticky     : std_logic;
  signal dropped_packet_sticky    : std_logic;
begin
  assert RESULT_FIFO_DEPTH >= R5_AGG_RESULT_WORDS * CONTEXT_FIFO_DEPTH
    report "R5 aggregation result FIFO cannot reserve every context slot"
    severity failure;

  -- A whole result packet and one matching context slot are reserved at word
  -- zero.  The inequality deliberately leaves no dependence on downstream
  -- READY once capture of a packet has begun.
  reserve_packet <= '1' when
    reserved_packet_count <
      to_unsigned(CONTEXT_FIFO_DEPTH, reserved_packet_count'length) and
    unsigned(result_fifo_count) <=
      to_unsigned(RESULT_FIFO_DEPTH - R5_AGG_RESULT_WORDS,
                  result_fifo_count'length) and
    unsigned(context_fifo_count) <
      to_unsigned(CONTEXT_FIFO_DEPTH, context_fifo_count'length) and
    result_fifo_full = '0' and context_fifo_full = '0' and
    result_fifo_wr_busy = '0' and context_fifo_wr_busy = '0' else '0';

  -- Never allow R5C1 congestion to propagate into the measurement pipeline.
  -- reserve_packet is sampled only at word zero.  When it is false, the
  -- exporter consumes and discards every word until the packet boundary and
  -- increments dropped_packet_count exactly once at the final word.
  input_ready <= aresetn;

  result_word_ready_o <= input_ready;
  input_accept <= result_word_valid_i and input_ready;
  capture_current_word <= reserve_packet when input_index = 0 else capture_packet;
  result_fifo_write <= input_accept and capture_current_word;
  context_fifo_write <= input_accept and reserve_packet
                        when input_index = 0 else '0';
  packet_reserve_pulse <= input_accept and reserve_packet
                          when input_index = 0 else '0';
  packet_complete_pulse <= input_accept and capture_packet
                           when input_index = R5_AGG_RESULT_WORDS - 1 else '0';
  packet_sent_pulse <= output_accept when output_phase = OUTPUT_CRC else '0';

  context_snapshot(31 downto 0) <= shadow_generation_i;
  context_snapshot(63 downto 32) <= shadow_sample_rate_i;
  context_snapshot(95 downto 64) <=
    (31 downto 13 => '0') & cycle_fallback_i & cycle_locked_i &
    config_apply_toggle_i & shadow_dc_remove_i & shadow_enable_i &
    shadow_valid_mask_i;
  context_snapshot(127 downto 96) <= frequency_status_i;
  context_snapshot(159 downto 128) <= frequency_period_i;
  context_snapshot(191 downto 160) <= frequency_sequence_i;
  context_snapshot(223 downto 192) <= capture_frame_count_i;
  context_snapshot(255 downto 224) <= capture_header_errors_i;
  context_snapshot(287 downto 256) <= capture_overflows_i;
  context_snapshot(319 downto 288) <= capture_alerts_i;
  context_snapshot(351 downto 320) <= ten_minute_target_sample_i(31 downto 0);
  context_snapshot(383 downto 352) <= ten_minute_target_sample_i(63 downto 32);
  context_snapshot(415 downto 384) <=
    (31 downto 2 => '0') & ten_minute_target_update_i & ten_minute_target_valid_i;

  result_words : xpm_fifo_sync
    generic map (
      DOUT_RESET_VALUE    => "0", ECC_MODE => "no_ecc",
      FIFO_MEMORY_TYPE    => "block", FIFO_READ_LATENCY => 0,
      FIFO_WRITE_DEPTH    => RESULT_FIFO_DEPTH, FULL_RESET_VALUE => 0,
      PROG_EMPTY_THRESH   => 10, PROG_FULL_THRESH => RESULT_FIFO_DEPTH - 8,
      RD_DATA_COUNT_WIDTH => RESULT_FIFO_COUNT_WIDTH, READ_DATA_WIDTH => 32,
      READ_MODE           => "fwft", SIM_ASSERT_CHK => 1,
      USE_ADV_FEATURES    => "1000", WAKEUP_TIME => 0,
      WRITE_DATA_WIDTH    => 32, WR_DATA_COUNT_WIDTH => RESULT_FIFO_COUNT_WIDTH)
    port map (
      sleep => '0', rst => not aresetn, wr_clk => aclk,
      wr_en => result_fifo_write, din => result_word_i,
      full => result_fifo_full, overflow => result_fifo_overflow,
      wr_rst_busy => result_fifo_wr_busy,
      rd_en => result_fifo_read, dout => result_fifo_dout,
      empty => result_fifo_empty, underflow => result_fifo_underflow,
      rd_rst_busy => result_fifo_rd_busy, data_valid => open,
      almost_empty => open, almost_full => open, prog_empty => open,
      prog_full => open, rd_data_count => open,
      wr_data_count => result_fifo_count, wr_ack => open,
      injectsbiterr => '0', injectdbiterr => '0', sbiterr => open, dbiterr => open);

  contexts : xpm_fifo_sync
    generic map (
      DOUT_RESET_VALUE    => "0", ECC_MODE => "no_ecc",
      FIFO_MEMORY_TYPE    => "auto", FIFO_READ_LATENCY => 0,
      FIFO_WRITE_DEPTH    => CONTEXT_FIFO_DEPTH, FULL_RESET_VALUE => 0,
      PROG_EMPTY_THRESH   => 2, PROG_FULL_THRESH => CONTEXT_FIFO_DEPTH - 2,
      RD_DATA_COUNT_WIDTH => CONTEXT_FIFO_COUNT_WIDTH,
      READ_DATA_WIDTH     => CONTEXT_BITS, READ_MODE => "fwft",
      SIM_ASSERT_CHK      => 1, USE_ADV_FEATURES => "1000", WAKEUP_TIME => 0,
      WRITE_DATA_WIDTH    => CONTEXT_BITS,
      WR_DATA_COUNT_WIDTH => CONTEXT_FIFO_COUNT_WIDTH)
    port map (
      sleep => '0', rst => not aresetn, wr_clk => aclk,
      wr_en => context_fifo_write, din => context_snapshot,
      full => context_fifo_full, overflow => context_fifo_overflow,
      wr_rst_busy => context_fifo_wr_busy,
      rd_en => context_fifo_read, dout => context_fifo_dout,
      empty => context_fifo_empty, underflow => context_fifo_underflow,
      rd_rst_busy => context_fifo_rd_busy, data_valid => open,
      almost_empty => open, almost_full => open, prog_empty => open,
      prog_full => open, rd_data_count => open,
      wr_data_count => context_fifo_count, wr_ack => open,
      injectsbiterr => '0', injectdbiterr => '0', sbiterr => open, dbiterr => open);

  process (all)
  begin
    output_word <= (others => '0');
    output_valid <= '0';
    output_last <= '0';

    case output_phase is
      when OUTPUT_IDLE =>
        null;
      when OUTPUT_HEADER =>
        output_valid <= '1';
        case output_header_index is
          when 0 => output_word <= R5_AGG_MAGIC;
          when 1 => output_word <= R5_AGG_CONTRACT_REVISION;
          when 2 => output_word <= std_logic_vector(to_unsigned(R5_AGG_PAYLOAD_WORDS, 32));
          when others => output_word <= result_fifo_dout;
        end case;
      when OUTPUT_RESULT =>
        output_valid <= not result_fifo_empty and not result_fifo_rd_busy;
        output_word <= result_fifo_dout;
      when OUTPUT_CONTEXT =>
        output_valid <= not context_fifo_empty and not context_fifo_rd_busy;
        output_word <= context_fifo_dout((output_context_index + 1) * 32 - 1
                                         downto output_context_index * 32);
      when OUTPUT_CRC =>
        output_valid <= '1';
        output_word <= not crc_state;
        output_last <= '1';
    end case;
  end process;

  output_accept <= output_valid and m_axis_tready;
  result_fifo_read <= output_accept when output_phase = OUTPUT_RESULT else '0';
  context_fifo_read <= output_accept when output_phase = OUTPUT_CONTEXT and
                       output_context_index = R5_AGG_CONTEXT_WORDS - 1 else '0';

  m_axis_tdata <= output_word;
  m_axis_tkeep <= (others => '1');
  m_axis_tvalid <= output_valid;
  m_axis_tlast <= output_last;

  process (aclk)
  begin
    if rising_edge(aclk) then
      if aresetn = '0' then
        input_index <= 0;
        capture_packet <= '0';
        accepted_packet_count <= (others => '0');
        dropped_packet_count <= (others => '0');
      elsif input_accept = '1' then
        if input_index = 0 then
          capture_packet <= reserve_packet;
        end if;

        if input_index = R5_AGG_RESULT_WORDS - 1 then
          input_index <= 0;
          if capture_packet = '1' then
            accepted_packet_count <= saturating_increment(accepted_packet_count);
          else
            -- Account for a discarded statistic packet only after its final
            -- word is observed.  This makes the counter describe complete
            -- source packets, even if reset interrupts a packet in flight.
            dropped_packet_count <= saturating_increment(dropped_packet_count);
          end if;
          capture_packet <= '0';
        else
          input_index <= input_index + 1;
        end if;
      end if;
    end if;
  end process;

  process (aclk)
    variable next_count : unsigned(4 downto 0);
  begin
    if rising_edge(aclk) then
      if aresetn = '0' then
        complete_packet_count <= (others => '0');
      else
        next_count := complete_packet_count;
        if packet_complete_pulse = '1' and packet_sent_pulse = '0' then
          if next_count < to_unsigned(CONTEXT_FIFO_DEPTH, next_count'length) then
            next_count := next_count + 1;
          end if;
        elsif packet_complete_pulse = '0' and packet_sent_pulse = '1' then
          if next_count /= 0 then
            next_count := next_count - 1;
          end if;
        end if;
        complete_packet_count <= next_count;
      end if;
    end if;
  end process;

  -- Admission credits are taken at source word zero and returned only after
  -- the complete framed packet (including CRC and TLAST) is accepted by the
  -- AXI-Stream sink.  This makes the packet boundary—not an implementation-
  -- specific XPM count—the single source of truth for queue capacity.
  process (aclk)
    variable next_reserved : unsigned(4 downto 0);
  begin
    if rising_edge(aclk) then
      if aresetn = '0' then
        reserved_packet_count <= (others => '0');
      else
        next_reserved := reserved_packet_count;
        if packet_reserve_pulse = '1' and packet_sent_pulse = '0' then
          if next_reserved <
             to_unsigned(CONTEXT_FIFO_DEPTH, next_reserved'length) then
            next_reserved := next_reserved + 1;
          end if;
        elsif packet_reserve_pulse = '0' and packet_sent_pulse = '1' then
          if next_reserved /= 0 then
            next_reserved := next_reserved - 1;
          end if;
        end if;
        reserved_packet_count <= next_reserved;
      end if;
    end if;
  end process;

  process (aclk)
  begin
    if rising_edge(aclk) then
      if aresetn = '0' then
        output_phase <= OUTPUT_IDLE;
        output_header_index <= 0;
        output_result_index <= 0;
        output_context_index <= 0;
        crc_state <= R5_AGG_CRC_INITIAL;
        transmitted_packet_count <= (others => '0');
        framing_error_count <= (others => '0');
        last_sequence <= (others => '0');
      else
        if result_fifo_overflow = '1' or result_fifo_underflow = '1' or
           context_fifo_overflow = '1' or context_fifo_underflow = '1' then
          framing_error_count <= saturating_increment(framing_error_count);
        end if;

        if output_phase = OUTPUT_IDLE then
          if complete_packet_count /= 0 and result_fifo_empty = '0' and
             context_fifo_empty = '0' and result_fifo_rd_busy = '0' and
             context_fifo_rd_busy = '0' then
            output_phase <= OUTPUT_HEADER;
            output_header_index <= 0;
            output_result_index <= 0;
            output_context_index <= 0;
            crc_state <= R5_AGG_CRC_INITIAL;
            last_sequence <= result_fifo_dout;
          end if;
        elsif output_accept = '1' then
          if output_phase /= OUTPUT_CRC then
            crc_state <= crc32c_update_word(crc_state, output_word);
          end if;

          case output_phase is
            when OUTPUT_HEADER =>
              if output_header_index = R5_AGG_HEADER_WORDS - 1 then
                output_phase <= OUTPUT_RESULT;
                output_result_index <= 0;
              else
                output_header_index <= output_header_index + 1;
              end if;
            when OUTPUT_RESULT =>
              if output_result_index = R5_AGG_RESULT_WORDS - 1 then
                output_phase <= OUTPUT_CONTEXT;
                output_context_index <= 0;
              else
                output_result_index <= output_result_index + 1;
              end if;
            when OUTPUT_CONTEXT =>
              if output_context_index = R5_AGG_CONTEXT_WORDS - 1 then
                output_phase <= OUTPUT_CRC;
              else
                output_context_index <= output_context_index + 1;
              end if;
            when OUTPUT_CRC =>
              output_phase <= OUTPUT_IDLE;
              transmitted_packet_count <= saturating_increment(transmitted_packet_count);
            when others => null;
          end case;
        end if;
      end if;
    end if;
  end process;

  accepted_packet_count_o <= std_logic_vector(accepted_packet_count);
  dropped_packet_count_o <= std_logic_vector(dropped_packet_count);
  transmitted_packet_count_o <= std_logic_vector(transmitted_packet_count);
  framing_error_count_o <= std_logic_vector(framing_error_count);
  last_sequence_o <= last_sequence;
  queue_level_o <= std_logic_vector(resize(complete_packet_count, 8));
  framing_error_sticky <= '1' when framing_error_count /= 0 else '0';
  dropped_packet_sticky <= '1' when dropped_packet_count /= 0 else '0';
  status_o <= (31 downto 8 => '0') &
              std_logic_vector(resize(complete_packet_count, 5)) &
              framing_error_sticky & dropped_packet_sticky & '1';
end architecture;
