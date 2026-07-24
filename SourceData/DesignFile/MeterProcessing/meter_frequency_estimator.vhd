library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library xpm;
use xpm.vcomponents.all;

library work;
use work.meter_frequency_pkg.all;

-- Converts qualified VLA zero crossings into a filtered frequency result.
--
-- The crossing FIFO stores Q16 sample timestamps for cycle-window modes.
-- Time-window mode uses a non-overlapping complete-cycle interval so no
-- partial cycle is ever included. The output remains invalid until a complete
-- configured interval has been observed.
entity meter_frequency_estimator is
  port (
    aclk                       : in  std_logic;
    aresetn                    : in  std_logic;
    clear_i                    : in  std_logic;
    enabled_i                  : in  std_logic;
    mode_i                     : in  std_logic_vector(2 downto 0);
    averaging_cycles_i         : in  std_logic_vector(7 downto 0);
    averaging_window_samples_i : in  std_logic_vector(31 downto 0);
    sample_rate_hz_i           : in  std_logic_vector(31 downto 0);
    minimum_millihz_i          : in  std_logic_vector(31 downto 0);
    maximum_millihz_i          : in  std_logic_vector(31 downto 0);
    frame_accept_i             : in  std_logic;
    sample_sequence_i          : in  std_logic_vector(31 downto 0);
    crossing_valid_i           : in  std_logic;
    previous_sequence_i        : in  std_logic_vector(31 downto 0);
    previous_sample_q16_i      : in  std_logic_vector(63 downto 0);
    current_sample_q16_i       : in  std_logic_vector(63 downto 0);
    frequency_millihz_o        : out std_logic_vector(31 downto 0);
    period_q16_samples_o       : out std_logic_vector(31 downto 0);
    measurement_sequence_o     : out std_logic_vector(31 downto 0);
    cycles_used_o              : out std_logic_vector(7 downto 0);
    valid_o                    : out std_logic;
    measuring_o                : out std_logic;
    out_of_range_o             : out std_logic;
    timeout_o                  : out std_logic;
    arithmetic_error_o         : out std_logic;
    rejected_count_o           : out std_logic_vector(31 downto 0)
  );
end entity;

architecture rtl of meter_frequency_estimator is
  constant DIVIDER_WIDTH : positive := 80;
  subtype divider_word_t is unsigned(DIVIDER_WIDTH - 1 downto 0);

  type estimator_state_t is (
    EST_IDLE,
    EST_WAIT_INTERPOLATION,
    EST_WAIT_FREQUENCY,
    EST_WAIT_PERIOD
  );

  function make_frequency_numerator(
    sample_rate : std_logic_vector(31 downto 0);
    cycles      : unsigned(7 downto 0)
  ) return divider_word_t is
    variable rate_cycles : unsigned(39 downto 0);
    variable milliscaled : unsigned(49 downto 0);
  begin
    rate_cycles := unsigned(sample_rate) * cycles;
    milliscaled := rate_cycles * to_unsigned(1000, 10);
    return resize(milliscaled, DIVIDER_WIDTH) sll 16;
  end function;

  signal state              : estimator_state_t := EST_IDLE;
  signal divider_start      : std_logic := '0';
  signal divider_dividend   : divider_word_t := (others => '0');
  signal divider_divisor    : divider_word_t := (others => '0');
  signal divider_done       : std_logic;
  signal divider_quotient   : divider_word_t;
  signal divider_zero       : std_logic;

  signal pending_prev_seq   : unsigned(31 downto 0) := (others => '0');
  signal pending_elapsed    : unsigned(63 downto 0) := (others => '0');
  signal pending_cycles     : unsigned(7 downto 0) := (others => '0');
  signal pending_frequency  : unsigned(31 downto 0) := (others => '0');

  signal fifo_reset         : std_logic;
  signal fifo_din           : std_logic_vector(63 downto 0) := (others => '0');
  signal fifo_dout          : std_logic_vector(63 downto 0);
  signal fifo_write         : std_logic := '0';
  signal fifo_read          : std_logic := '0';
  signal fifo_full          : std_logic;
  signal fifo_empty         : std_logic;
  signal fifo_data_valid    : std_logic;
  signal fifo_reset_busy    : std_logic;
  signal queue_count        : natural range 0 to 128 := 0;

  signal time_start_valid   : std_logic := '0';
  signal time_start         : unsigned(63 downto 0) := (others => '0');
  signal time_cycles        : unsigned(7 downto 0) := (others => '0');
  signal last_crossing_seq  : unsigned(31 downto 0) := (others => '0');
  signal have_crossing      : std_logic := '0';

  signal frequency_millihz : std_logic_vector(31 downto 0) := (others => '0');
  signal period_q16         : std_logic_vector(31 downto 0) := (others => '0');
  signal measurement_seq   : unsigned(31 downto 0) := (others => '0');
  signal cycles_used       : std_logic_vector(7 downto 0) := (others => '0');
  signal result_valid      : std_logic := '0';
  signal out_of_range      : std_logic := '0';
  signal timeout           : std_logic := '0';
  signal arithmetic_error  : std_logic := '0';
  signal rejected_count    : unsigned(31 downto 0) := (others => '0');
begin
  fifo_reset <= not aresetn or clear_i;
  frequency_millihz_o <= frequency_millihz;
  period_q16_samples_o <= period_q16;
  measurement_sequence_o <= std_logic_vector(measurement_seq);
  cycles_used_o <= cycles_used;
  valid_o <= result_valid;
  measuring_o <= '1' when have_crossing = '1' else '0';
  out_of_range_o <= out_of_range;
  timeout_o <= timeout;
  arithmetic_error_o <= arithmetic_error;
  rejected_count_o <= std_logic_vector(rejected_count);

  divider : entity work.meter_unsigned_divider
    generic map (WIDTH => DIVIDER_WIDTH)
    port map (
      aclk => aclk,
      aresetn => aresetn,
      start_i => divider_start,
      dividend_i => divider_dividend,
      divisor_i => divider_divisor,
      busy_o => open,
      done_o => divider_done,
      quotient_o => divider_quotient,
      divide_by_zero_o => divider_zero
    );

  crossing_fifo : xpm_fifo_sync
    generic map (
      DOUT_RESET_VALUE    => "0",
      ECC_MODE            => "no_ecc",
      FIFO_MEMORY_TYPE    => "auto",
      FIFO_READ_LATENCY   => 0,
      FIFO_WRITE_DEPTH    => 128,
      FULL_RESET_VALUE    => 0,
      PROG_EMPTY_THRESH   => 10,
      PROG_FULL_THRESH    => 118,
      RD_DATA_COUNT_WIDTH => 8,
      READ_DATA_WIDTH     => 64,
      READ_MODE           => "fwft",
      SIM_ASSERT_CHK      => 1,
      USE_ADV_FEATURES    => "1000",
      WAKEUP_TIME         => 0,
      WRITE_DATA_WIDTH    => 64,
      WR_DATA_COUNT_WIDTH => 8
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
      data_valid => fifo_data_valid,
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

  process (aclk)
    variable previous_magnitude : unsigned(63 downto 0);
    variable sample_delta       : signed(64 downto 0);
    variable crossing_timestamp : unsigned(63 downto 0);
    variable elapsed            : unsigned(63 downto 0);
    variable requested_cycles   : unsigned(7 downto 0);
    variable completed_cycles   : unsigned(7 downto 0);
    variable timeout_left       : unsigned(63 downto 0);
    variable timeout_right      : unsigned(63 downto 0);
    variable current_frequency  : unsigned(31 downto 0);
  begin
    if rising_edge(aclk) then
      divider_start <= '0';
      fifo_write <= '0';
      fifo_read <= '0';

      if aresetn = '0' or clear_i = '1' then
        state <= EST_IDLE;
        queue_count <= 0;
        time_start_valid <= '0';
        time_cycles <= (others => '0');
        have_crossing <= '0';
        frequency_millihz <= (others => '0');
        period_q16 <= (others => '0');
        measurement_seq <= (others => '0');
        cycles_used <= (others => '0');
        result_valid <= '0';
        out_of_range <= '0';
        timeout <= '0';
        arithmetic_error <= '0';
        rejected_count <= (others => '0');
      else
        -- Compare products instead of dividing to derive the three-period
        -- no-signal timeout. This keeps timeout checking off the shared divider.
        if frame_accept_i = '1' and have_crossing = '1' and
           unsigned(minimum_millihz_i) /= 0 then
          timeout_left := (unsigned(sample_sequence_i) -
                           last_crossing_seq) *
                          unsigned(minimum_millihz_i);
          timeout_right := resize(
            unsigned(sample_rate_hz_i) * to_unsigned(3000, 12), 64);
          if timeout_left >= timeout_right then
            result_valid <= '0';
            timeout <= '1';
            have_crossing <= '0';
            time_start_valid <= '0';
          end if;
        end if;

        if enabled_i = '0' then
          result_valid <= '0';
          have_crossing <= '0';
          time_start_valid <= '0';
        end if;

        if crossing_valid_i = '1' and enabled_i = '1' then
          last_crossing_seq <= unsigned(previous_sequence_i) + 1;
          have_crossing <= '1';
          timeout <= '0';
          if state /= EST_IDLE then
            -- A calculation taking longer than one sample period is a design
            -- error at the configured sample rate; reject rather than corrupt
            -- the crossing history.
            arithmetic_error <= '1';
            rejected_count <= rejected_count + 1;
          else
            previous_magnitude :=
              unsigned(-signed(previous_sample_q16_i));
            sample_delta := resize(signed(current_sample_q16_i), 65) -
                            resize(signed(previous_sample_q16_i), 65);
            if sample_delta <= 0 then
              arithmetic_error <= '1';
              rejected_count <= rejected_count + 1;
            else
              pending_prev_seq <= unsigned(previous_sequence_i);
              divider_dividend <=
                resize(previous_magnitude, DIVIDER_WIDTH) sll 16;
              divider_divisor <= resize(unsigned(sample_delta),
                                        DIVIDER_WIDTH);
              divider_start <= '1';
              state <= EST_WAIT_INTERPOLATION;
            end if;
          end if;
        end if;

        case state is
          when EST_IDLE =>
            null;

          when EST_WAIT_INTERPOLATION =>
            if divider_done = '1' then
              if divider_zero = '1' or divider_quotient(79 downto 16) /=
                 to_unsigned(0, 64) then
                arithmetic_error <= '1';
                rejected_count <= rejected_count + 1;
                state <= EST_IDLE;
              else
                crossing_timestamp :=
                  (resize(pending_prev_seq, 64) sll 16) +
                  resize(divider_quotient(15 downto 0), 64);

                if mode_i = FREQUENCY_MODE_ROLLING_TIME then
                  if time_start_valid = '0' then
                    time_start <= crossing_timestamp;
                    time_start_valid <= '1';
                    time_cycles <= (others => '0');
                    state <= EST_IDLE;
                  else
                    completed_cycles := time_cycles + 1;
                    elapsed := elapsed_q16_samples(
                      crossing_timestamp, time_start);
                    if elapsed >=
                       (resize(unsigned(averaging_window_samples_i), 64)
                        sll 16) then
                      pending_elapsed <= elapsed;
                      pending_cycles <= completed_cycles;
                      divider_dividend <= make_frequency_numerator(
                        sample_rate_hz_i, completed_cycles);
                      divider_divisor <= resize(elapsed, DIVIDER_WIDTH);
                      divider_start <= '1';
                      time_start <= crossing_timestamp;
                      time_cycles <= (others => '0');
                      state <= EST_WAIT_FREQUENCY;
                    else
                      time_cycles <= completed_cycles;
                      state <= EST_IDLE;
                    end if;
                  end if;
                else
                  if mode_i = FREQUENCY_MODE_SINGLE_CYCLE then
                    requested_cycles := to_unsigned(1, 8);
                  else
                    requested_cycles := unsigned(averaging_cycles_i);
                  end if;

                  if requested_cycles = 0 or fifo_reset_busy = '1' or
                     fifo_full = '1' then
                    arithmetic_error <= '1';
                    rejected_count <= rejected_count + 1;
                    state <= EST_IDLE;
                  elsif queue_count < to_integer(requested_cycles) then
                    fifo_din <= std_logic_vector(crossing_timestamp);
                    fifo_write <= '1';
                    queue_count <= queue_count + 1;
                    state <= EST_IDLE;
                  elsif fifo_data_valid = '1' and fifo_empty = '0' then
                    elapsed := elapsed_q16_samples(
                      crossing_timestamp, unsigned(fifo_dout));
                    pending_elapsed <= elapsed;
                    pending_cycles <= requested_cycles;
                    fifo_din <= std_logic_vector(crossing_timestamp);
                    fifo_write <= '1';
                    fifo_read <= '1';
                    divider_dividend <= make_frequency_numerator(
                      sample_rate_hz_i, requested_cycles);
                    divider_divisor <= resize(elapsed, DIVIDER_WIDTH);
                    divider_start <= '1';
                    state <= EST_WAIT_FREQUENCY;
                  else
                    arithmetic_error <= '1';
                    rejected_count <= rejected_count + 1;
                    state <= EST_IDLE;
                  end if;
                end if;
              end if;
            end if;

          when EST_WAIT_FREQUENCY =>
            if divider_done = '1' then
              if divider_zero = '1' or divider_quotient(79 downto 32) /=
                 to_unsigned(0, 48) then
                arithmetic_error <= '1';
                rejected_count <= rejected_count + 1;
                state <= EST_IDLE;
              else
                pending_frequency <= divider_quotient(31 downto 0);
                divider_dividend <= resize(pending_elapsed, DIVIDER_WIDTH);
                divider_divisor <= resize(pending_cycles, DIVIDER_WIDTH);
                divider_start <= '1';
                state <= EST_WAIT_PERIOD;
              end if;
            end if;

          when EST_WAIT_PERIOD =>
            if divider_done = '1' then
              current_frequency := pending_frequency;
              if divider_zero = '1' or divider_quotient(79 downto 32) /=
                 to_unsigned(0, 48) then
                arithmetic_error <= '1';
                result_valid <= '0';
                rejected_count <= rejected_count + 1;
              elsif current_frequency < unsigned(minimum_millihz_i) or
                    current_frequency > unsigned(maximum_millihz_i) then
                out_of_range <= '1';
                result_valid <= '0';
                rejected_count <= rejected_count + 1;
              else
                frequency_millihz <= std_logic_vector(current_frequency);
                period_q16 <= std_logic_vector(divider_quotient(31 downto 0));
                measurement_seq <= measurement_seq + 1;
                cycles_used <= std_logic_vector(pending_cycles);
                result_valid <= '1';
                out_of_range <= '0';
              end if;
              state <= EST_IDLE;
            end if;
        end case;
      end if;
    end if;
  end process;
end architecture;
