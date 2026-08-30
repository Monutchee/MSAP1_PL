library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library xpm;
use xpm.vcomponents.all;

-- Nonblocking raw-waveform branch.
--
-- Every accepted converted frame still carries the original eight 32-bit ADC
-- words in TUSER[383:128]. This module copies that payload into an XPM FIFO,
-- adds the frame's 64-bit sample index and the PL tick, and emits fixed WFM1
-- DMA blocks. It intentionally has no ready output: a stopped waveform DMA
-- drops waveform frames and increments drop_count_o without disturbing RMS
-- or meter records.
--
-- sequence_o carries the conversion-domain sample index of the most recently
-- accepted frame (delivered with the frame via sample_index_i), not a local
-- count. The Linux correlation latch therefore captures the same monotonic
-- measurement timebase that BASIC-v4 records reference, and UTC mapping
-- needs no separate counter domain.
entity meter_waveform is
  generic (
    G_FRAMES_PER_BLOCK : positive := 1024;
    G_FIFO_DEPTH       : positive := 256
  );
  port (
    aclk    : in std_logic;
    aresetn : in std_logic;

    frame_accept_i            : in std_logic;
    raw_frame_i               : in std_logic_vector(255 downto 0);
    sample_index_i            : in std_logic_vector(63 downto 0);
    config_generation_i       : in std_logic_vector(31 downto 0);
    measured_frame_rate_hz_i  : in std_logic_vector(31 downto 0);
    measured_frame_rate_valid_i : in std_logic;
    enable_i                  : in std_logic;
    clear_stats_i             : in std_logic;

    tick_o        : out std_logic_vector(63 downto 0);
    sequence_o    : out std_logic_vector(63 downto 0);
    drop_count_o  : out std_logic_vector(31 downto 0);
    block_count_o : out std_logic_vector(31 downto 0);
    status_o      : out std_logic_vector(31 downto 0);

    m_axis_tdata  : out std_logic_vector(31 downto 0);
    m_axis_tkeep  : out std_logic_vector(3 downto 0);
    m_axis_tvalid : out std_logic;
    m_axis_tready : in  std_logic;
    m_axis_tlast  : out std_logic
  );
end entity;

architecture rtl of meter_waveform is
  constant C_HEADER_WORDS : positive := 16;
  constant C_FRAME_WORDS  : positive := 8;
  constant C_BLOCK_BYTES  : positive :=
    (C_HEADER_WORDS * 4) + (G_FRAMES_PER_BLOCK * C_FRAME_WORDS * 4);
  constant C_FIFO_WIDTH   : positive := 449;

  constant C_RAW_LSB  : natural := 0;
  constant C_RAW_MSB  : natural := 255;
  constant C_SEQ_LSB  : natural := 256;
  constant C_SEQ_MSB  : natural := 319;
  constant C_TICK_LSB : natural := 320;
  constant C_TICK_MSB : natural := 383;
  constant C_GEN_LSB  : natural := 384;
  constant C_GEN_MSB  : natural := 415;
  constant C_RATE_LSB : natural := 416;
  constant C_RATE_MSB : natural := 447;
  constant C_RATE_VALID : natural := 448;

  type output_state_t is (OUT_WAIT, OUT_HEADER, OUT_FRAMES);
  signal state : output_state_t := OUT_WAIT;

  signal tick_counter     : unsigned(63 downto 0) := (others => '0');
  signal frame_sequence   : unsigned(63 downto 0) := (others => '0');
  signal drop_count       : unsigned(31 downto 0) := (others => '0');
  signal block_count      : unsigned(31 downto 0) := (others => '0');

  signal fifo_din         : std_logic_vector(C_FIFO_WIDTH - 1 downto 0) :=
    (others => '0');
  signal fifo_dout        : std_logic_vector(C_FIFO_WIDTH - 1 downto 0);
  signal fifo_write       : std_logic := '0';
  signal fifo_read        : std_logic;
  signal fifo_full        : std_logic;
  signal fifo_empty       : std_logic;
  signal fifo_reset_busy  : std_logic;
  signal fifo_reset       : std_logic;

  signal header_index     : natural range 0 to C_HEADER_WORDS - 1 := 0;
  signal frame_index      : natural range 0 to G_FRAMES_PER_BLOCK - 1 := 0;
  signal frame_word_index : natural range 0 to C_FRAME_WORDS - 1 := 0;
  signal first_sequence   : std_logic_vector(63 downto 0) := (others => '0');
  signal first_tick       : std_logic_vector(63 downto 0) := (others => '0');
  signal first_generation : std_logic_vector(31 downto 0) := (others => '0');
  signal first_rate       : std_logic_vector(31 downto 0) := (others => '0');
  signal first_rate_valid : std_logic := '0';
  signal active_block_number : unsigned(31 downto 0) := (others => '0');

  signal axis_data        : std_logic_vector(31 downto 0);
  signal axis_valid       : std_logic;
  signal axis_last        : std_logic;

  function header_word(
    index            : natural;
    sequence_value   : std_logic_vector(63 downto 0);
    tick_value       : std_logic_vector(63 downto 0);
    generation_value : std_logic_vector(31 downto 0);
    rate_value       : std_logic_vector(31 downto 0);
    rate_valid       : std_logic;
    drops            : unsigned(31 downto 0);
    block_number     : unsigned(31 downto 0)
  ) return std_logic_vector is
    variable value : std_logic_vector(31 downto 0) := (others => '0');
  begin
    case index is
      when 0  => value := x"314D4657"; -- little-endian "WFM1"
      when 1  => value := x"00010000";
      when 2  => value := std_logic_vector(to_unsigned(C_BLOCK_BYTES, 32));
      when 3  => value := std_logic_vector(to_unsigned(G_FRAMES_PER_BLOCK, 32));
      when 4  => value := x"00000020"; -- 8 channels * 4 bytes
      when 5  => value := sequence_value(31 downto 0);
      when 6  => value := sequence_value(63 downto 32);
      when 7  => value := tick_value(31 downto 0);
      when 8  => value := tick_value(63 downto 32);
      when 9  => value := rate_value;
      when 10 => value := generation_value;
      when 11 =>
        value := (others => '0');
        value(0) := rate_valid;
        if drops /= 0 then
          value(1) := '1';
        end if;
      when 12 => value := std_logic_vector(drops);
      when 13 => value := std_logic_vector(block_number);
      when others => value := (others => '0');
    end case;
    return value;
  end function;
begin
  tick_o <= std_logic_vector(tick_counter);
  sequence_o <= std_logic_vector(frame_sequence);
  drop_count_o <= std_logic_vector(drop_count);
  block_count_o <= std_logic_vector(block_count);

  status_o <=
    (31 downto 4 => '0') &
    fifo_reset_busy &
    fifo_full &
    (not fifo_empty) &
    enable_i;

  m_axis_tdata <= axis_data;
  m_axis_tkeep <= (others => '1');
  m_axis_tvalid <= axis_valid;
  m_axis_tlast <= axis_last;

  -- Pop the FIFO on the same edge that accepts the last word of a frame. In
  -- FWFT mode this makes the next frame visible without duplicating word zero.
  fifo_read <= '1' when state = OUT_FRAMES and axis_valid = '1' and
                        m_axis_tready = '1' and
                        frame_word_index = C_FRAME_WORDS - 1 else '0';

  -- ENABLE is a stream-epoch boundary, not only an input gate. Flush queued
  -- frames and abandon any partial AXI packet while Linux tears DMA down so
  -- the next open always begins with a complete WFM1 header/period.
  fifo_reset <= (not aresetn) or (not enable_i);

  waveform_fifo : xpm_fifo_sync
    generic map (
      DOUT_RESET_VALUE    => "0",
      ECC_MODE            => "no_ecc",
      FIFO_MEMORY_TYPE    => "auto",
      FIFO_READ_LATENCY   => 0,
      FIFO_WRITE_DEPTH    => G_FIFO_DEPTH,
      FULL_RESET_VALUE    => 0,
      PROG_EMPTY_THRESH   => 10,
      PROG_FULL_THRESH    => G_FIFO_DEPTH - 8,
      RD_DATA_COUNT_WIDTH => 9,
      READ_DATA_WIDTH     => C_FIFO_WIDTH,
      READ_MODE           => "fwft",
      SIM_ASSERT_CHK      => 1,
      USE_ADV_FEATURES    => "1000",
      WAKEUP_TIME         => 0,
      WRITE_DATA_WIDTH    => C_FIFO_WIDTH,
      WR_DATA_COUNT_WIDTH => 9
    )
    port map (
      sleep => '0',
      rst => fifo_reset,
      wr_clk => aclk,
      wr_en => fifo_write,
      din => fifo_din,
      full => fifo_full,
      overflow => open,
      wr_rst_busy => fifo_reset_busy,
      rd_en => fifo_read,
      dout => fifo_dout,
      empty => fifo_empty,
      underflow => open,
      rd_rst_busy => open,
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

  process (all)
  begin
    axis_data <= (others => '0');
    axis_valid <= '0';
    axis_last <= '0';

    case state is
      when OUT_HEADER =>
        axis_data <= header_word(
          header_index, first_sequence, first_tick, first_generation,
          first_rate, first_rate_valid, drop_count, active_block_number);
        axis_valid <= '1';
      when OUT_FRAMES =>
        if fifo_empty = '0' then
          axis_data <= fifo_dout(
            (frame_word_index * 32) + 31 downto frame_word_index * 32);
          axis_valid <= '1';
          if frame_index = G_FRAMES_PER_BLOCK - 1 and
             frame_word_index = C_FRAME_WORDS - 1 then
            axis_last <= '1';
          end if;
        end if;
      when others =>
        null;
    end case;
  end process;

  process (aclk)
    variable next_sequence : unsigned(63 downto 0);
  begin
    if rising_edge(aclk) then
      fifo_write <= '0';

      if aresetn = '0' then
        tick_counter <= (others => '0');
        frame_sequence <= (others => '0');
        drop_count <= (others => '0');
        block_count <= (others => '0');
        state <= OUT_WAIT;
        header_index <= 0;
        frame_index <= 0;
        frame_word_index <= 0;
        active_block_number <= (others => '0');
      else
        tick_counter <= tick_counter + 1;

        if clear_stats_i = '1' then
          drop_count <= (others => '0');
        end if;

        -- Correlation follows the conversion-domain sample index even while
        -- waveform persistence is disabled.
        if frame_accept_i = '1' then
          next_sequence := unsigned(sample_index_i);
          frame_sequence <= next_sequence;
        end if;

        if enable_i = '0' then
          state <= OUT_WAIT;
          header_index <= 0;
          frame_index <= 0;
          frame_word_index <= 0;
        else
          if frame_accept_i = '1' and fifo_full = '0' and
              fifo_reset_busy = '0' then
            fifo_din(C_RAW_MSB downto C_RAW_LSB) <= raw_frame_i;
            fifo_din(C_SEQ_MSB downto C_SEQ_LSB) <=
              sample_index_i;
            fifo_din(C_TICK_MSB downto C_TICK_LSB) <=
              std_logic_vector(tick_counter);
            fifo_din(C_GEN_MSB downto C_GEN_LSB) <= config_generation_i;
            fifo_din(C_RATE_MSB downto C_RATE_LSB) <=
              measured_frame_rate_hz_i;
            fifo_din(C_RATE_VALID) <= measured_frame_rate_valid_i;
            fifo_write <= '1';
          elsif frame_accept_i = '1' then
            drop_count <= drop_count + 1;
          end if;

          case state is
            when OUT_WAIT =>
              if fifo_empty = '0' then
                first_sequence <= fifo_dout(C_SEQ_MSB downto C_SEQ_LSB);
                first_tick <= fifo_dout(C_TICK_MSB downto C_TICK_LSB);
                first_generation <= fifo_dout(C_GEN_MSB downto C_GEN_LSB);
                first_rate <= fifo_dout(C_RATE_MSB downto C_RATE_LSB);
                first_rate_valid <= fifo_dout(C_RATE_VALID);
                active_block_number <= block_count + 1;
                header_index <= 0;
                frame_index <= 0;
                frame_word_index <= 0;
                state <= OUT_HEADER;
              end if;

            when OUT_HEADER =>
              if axis_valid = '1' and m_axis_tready = '1' then
                if header_index = C_HEADER_WORDS - 1 then
                  state <= OUT_FRAMES;
                  frame_word_index <= 0;
                else
                  header_index <= header_index + 1;
                end if;
              end if;

            when OUT_FRAMES =>
              if axis_valid = '1' and m_axis_tready = '1' then
                if frame_word_index = C_FRAME_WORDS - 1 then
                  frame_word_index <= 0;
                  if frame_index = G_FRAMES_PER_BLOCK - 1 then
                    block_count <= block_count + 1;
                    state <= OUT_WAIT;
                  else
                    frame_index <= frame_index + 1;
                  end if;
                else
                  frame_word_index <= frame_word_index + 1;
                end if;
              end if;
          end case;
        end if;
      end if;
    end if;
  end process;
end architecture;
