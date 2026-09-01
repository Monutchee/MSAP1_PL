library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.metering_pkg.all;
use work.meter_frequency_10s_pkg.all;

-- Linux-owned control and time-correlation registers for the waveform path.
--
-- A write with CONTROL.LATCH=1 atomically snapshots the free-running PL tick
-- and 64-bit ADC frame sequence. Linux brackets that write with CLOCK_TAI
-- reads, giving userspace a bounded-error mapping from PL frames to wall time.
-- These registers are deliberately separate from the waveform AXI DMA.
entity meter_waveform_axi_regs is
  port (
    aclk    : in std_logic;
    aresetn : in std_logic;

    s_axi_awaddr  : in  std_logic_vector(7 downto 0);
    s_axi_awvalid : in  std_logic;
    s_axi_awready : out std_logic;
    s_axi_wdata   : in  std_logic_vector(31 downto 0);
    s_axi_wstrb   : in  std_logic_vector(3 downto 0);
    s_axi_wvalid  : in  std_logic;
    s_axi_wready  : out std_logic;
    s_axi_bresp   : out std_logic_vector(1 downto 0);
    s_axi_bvalid  : out std_logic;
    s_axi_bready  : in  std_logic;
    s_axi_araddr  : in  std_logic_vector(7 downto 0);
    s_axi_arvalid : in  std_logic;
    s_axi_arready : out std_logic;
    s_axi_rdata   : out std_logic_vector(31 downto 0);
    s_axi_rresp   : out std_logic_vector(1 downto 0);
    s_axi_rvalid  : out std_logic;
    s_axi_rready  : in  std_logic;

    tick_i       : in std_logic_vector(63 downto 0);
    sequence_i   : in std_logic_vector(63 downto 0);
    drop_count_i : in std_logic_vector(31 downto 0);
    block_count_i: in std_logic_vector(31 downto 0);
    status_i     : in std_logic_vector(31 downto 0);

    enable_o      : out std_logic;
    clear_stats_o : out std_logic;

    -- M13 absolute-time boundary. Linux maps the next UTC ten-minute mark
    -- to the conversion-domain sample counter using the correlation ioctl,
    -- writes the 64-bit target, then toggles UPDATE.  The aggregation path
    -- observes the committed tuple with the next single-cycle result beat.
    ten_minute_target_sample_o : out std_logic_vector(63 downto 0);
    ten_minute_target_valid_o  : out std_logic;
    ten_minute_target_update_o : out std_logic;

    frequency_10s_boundary_o : out frequency_10s_boundary_t;
    frequency_10s_boundary_update_o : out std_logic;
    frequency_10s_status_i : in std_logic_vector(31 downto 0);
    frequency_10s_completed_count_i : in std_logic_vector(31 downto 0);
    frequency_10s_dropped_count_i : in std_logic_vector(31 downto 0);
    frequency_10s_overflow_count_i : in std_logic_vector(31 downto 0);
    frequency_10s_discontinuity_count_i : in std_logic_vector(31 downto 0)
  );
end entity;

architecture rtl of meter_waveform_axi_regs is
  constant VERSION_VALUE     : std_logic_vector(31 downto 0) := x"00010001";
  constant IDENTIFIER_VALUE  : std_logic_vector(31 downto 0) := x"31434657"; -- "WFC1"
  constant BLOCK_BYTES_VALUE : std_logic_vector(31 downto 0) := x"00008040"; -- 32,832

  signal enabled         : std_logic := '0';
  signal clear_stats     : std_logic := '0';
  signal latched_tick    : std_logic_vector(63 downto 0) := (others => '0');
  signal latched_sequence: std_logic_vector(63 downto 0) := (others => '0');
  signal ten_minute_target : std_logic_vector(63 downto 0) := (others => '0');
  signal ten_minute_valid  : std_logic := '0';
  signal ten_minute_update : std_logic := '0';
  signal frequency_10s_boundary : frequency_10s_boundary_t :=
    FREQUENCY_10S_BOUNDARY_RESET;
  signal frequency_10s_boundary_update : std_logic := '0';
  signal bvalid          : std_logic := '0';
  signal rvalid          : std_logic := '0';
  signal rdata           : std_logic_vector(31 downto 0) := (others => '0');
begin
  s_axi_awready <= '1' when bvalid = '0' and
                            s_axi_awvalid = '1' and s_axi_wvalid = '1' else '0';
  s_axi_wready  <= '1' when bvalid = '0' and
                            s_axi_awvalid = '1' and s_axi_wvalid = '1' else '0';
  s_axi_bresp  <= "00";
  s_axi_bvalid <= bvalid;

  s_axi_arready <= '1' when rvalid = '0' else '0';
  s_axi_rresp  <= "00";
  s_axi_rvalid <= rvalid;
  s_axi_rdata  <= rdata;

  enable_o <= enabled;
  clear_stats_o <= clear_stats;
  ten_minute_target_sample_o <= ten_minute_target;
  ten_minute_target_valid_o <= ten_minute_valid;
  ten_minute_target_update_o <= ten_minute_update;
  frequency_10s_boundary_o <= frequency_10s_boundary;
  frequency_10s_boundary_update_o <= frequency_10s_boundary_update;

  process (aclk)
    variable address_word : natural range 0 to 63;
    variable control_word : std_logic_vector(31 downto 0);
  begin
    if rising_edge(aclk) then
      clear_stats <= '0';

      if aresetn = '0' then
        enabled <= '0';
        clear_stats <= '0';
        latched_tick <= (others => '0');
        latched_sequence <= (others => '0');
        ten_minute_target <= (others => '0');
        ten_minute_valid <= '0';
        ten_minute_update <= '0';
        frequency_10s_boundary <= FREQUENCY_10S_BOUNDARY_RESET;
        frequency_10s_boundary_update <= '0';
        bvalid <= '0';
        rvalid <= '0';
        rdata <= (others => '0');
      else
        if bvalid = '1' and s_axi_bready = '1' then
          bvalid <= '0';
        end if;

        if bvalid = '0' and s_axi_awvalid = '1' and s_axi_wvalid = '1' then
          address_word := to_integer(unsigned(s_axi_awaddr(7 downto 2)));
          if address_word = 2 then
            control_word := (others => '0');
            control_word(0) := enabled;
            for byte_index in 0 to 3 loop
              if s_axi_wstrb(byte_index) = '1' then
                control_word((byte_index * 8) + 7 downto byte_index * 8) :=
                  s_axi_wdata((byte_index * 8) + 7 downto byte_index * 8);
              end if;
            end loop;
            enabled <= control_word(0);
            if control_word(1) = '1' then
              latched_tick <= tick_i;
              latched_sequence <= sequence_i;
            end if;
            if control_word(2) = '1' then
              clear_stats <= '1';
            end if;
          elsif address_word = 16 then
            for byte_index in 0 to 3 loop
              if s_axi_wstrb(byte_index) = '1' then
                ten_minute_target((byte_index * 8) + 7 downto byte_index * 8) <=
                  s_axi_wdata((byte_index * 8) + 7 downto byte_index * 8);
              end if;
            end loop;
          elsif address_word = 17 then
            for byte_index in 0 to 3 loop
              if s_axi_wstrb(byte_index) = '1' then
                ten_minute_target(32 + (byte_index * 8) + 7 downto
                                  32 + byte_index * 8) <=
                  s_axi_wdata((byte_index * 8) + 7 downto byte_index * 8);
              end if;
            end loop;
          elsif address_word = 18 and s_axi_wstrb(0) = '1' then
            ten_minute_valid <= s_axi_wdata(0);
            if s_axi_wdata(1) = '1' then
              ten_minute_update <= not ten_minute_update;
            end if;
          elsif address_word = FREQUENCY_10S_REG_START_SAMPLE_LOW / 4 then
            frequency_10s_boundary.start_sample(31 downto 0) <=
              apply_write_strobes(
                frequency_10s_boundary.start_sample(31 downto 0),
                s_axi_wdata, s_axi_wstrb);
          elsif address_word = FREQUENCY_10S_REG_START_SAMPLE_HIGH / 4 then
            frequency_10s_boundary.start_sample(63 downto 32) <=
              apply_write_strobes(
                frequency_10s_boundary.start_sample(63 downto 32),
                s_axi_wdata, s_axi_wstrb);
          elsif address_word = FREQUENCY_10S_REG_END_SAMPLE_LOW / 4 then
            frequency_10s_boundary.end_sample(31 downto 0) <=
              apply_write_strobes(
                frequency_10s_boundary.end_sample(31 downto 0),
                s_axi_wdata, s_axi_wstrb);
          elsif address_word = FREQUENCY_10S_REG_END_SAMPLE_HIGH / 4 then
            frequency_10s_boundary.end_sample(63 downto 32) <=
              apply_write_strobes(
                frequency_10s_boundary.end_sample(63 downto 32),
                s_axi_wdata, s_axi_wstrb);
          elsif address_word = FREQUENCY_10S_REG_UTC_START_LOW / 4 then
            frequency_10s_boundary.utc_start_nanoseconds(31 downto 0) <=
              apply_write_strobes(
                frequency_10s_boundary.utc_start_nanoseconds(31 downto 0),
                s_axi_wdata, s_axi_wstrb);
          elsif address_word = FREQUENCY_10S_REG_UTC_START_HIGH / 4 then
            frequency_10s_boundary.utc_start_nanoseconds(63 downto 32) <=
              apply_write_strobes(
                frequency_10s_boundary.utc_start_nanoseconds(63 downto 32),
                s_axi_wdata, s_axi_wstrb);
          elsif address_word = FREQUENCY_10S_REG_UTC_END_LOW / 4 then
            frequency_10s_boundary.utc_end_nanoseconds(31 downto 0) <=
              apply_write_strobes(
                frequency_10s_boundary.utc_end_nanoseconds(31 downto 0),
                s_axi_wdata, s_axi_wstrb);
          elsif address_word = FREQUENCY_10S_REG_UTC_END_HIGH / 4 then
            frequency_10s_boundary.utc_end_nanoseconds(63 downto 32) <=
              apply_write_strobes(
                frequency_10s_boundary.utc_end_nanoseconds(63 downto 32),
                s_axi_wdata, s_axi_wstrb);
          elsif address_word = FREQUENCY_10S_REG_UNCERTAINTY_LOW / 4 then
            frequency_10s_boundary.utc_uncertainty_nanoseconds(31 downto 0) <=
              apply_write_strobes(
                frequency_10s_boundary.utc_uncertainty_nanoseconds(31 downto 0),
                s_axi_wdata, s_axi_wstrb);
          elsif address_word = FREQUENCY_10S_REG_UNCERTAINTY_HIGH / 4 then
            frequency_10s_boundary.utc_uncertainty_nanoseconds(63 downto 32) <=
              apply_write_strobes(
                frequency_10s_boundary.utc_uncertainty_nanoseconds(63 downto 32),
                s_axi_wdata, s_axi_wstrb);
          elsif address_word = FREQUENCY_10S_REG_MEASURED_RATE_MILLIHZ / 4 then
            frequency_10s_boundary.measured_sample_rate_millihz <=
              apply_write_strobes(
                frequency_10s_boundary.measured_sample_rate_millihz,
                s_axi_wdata, s_axi_wstrb);
          elsif address_word = FREQUENCY_10S_REG_BOUNDARY_GENERATION / 4 then
            frequency_10s_boundary.boundary_generation <=
              apply_write_strobes(
                frequency_10s_boundary.boundary_generation,
                s_axi_wdata, s_axi_wstrb);
          elsif address_word = FREQUENCY_10S_REG_PROFILE / 4 then
            frequency_10s_boundary.profile <= apply_write_strobes(
              frequency_10s_boundary.profile, s_axi_wdata, s_axi_wstrb);
          elsif address_word = FREQUENCY_10S_REG_CONTROL / 4 then
            control_word := apply_write_strobes(
              frequency_10s_boundary.control, s_axi_wdata, s_axi_wstrb);
            frequency_10s_boundary.control <=
              (31 downto 4 => '0') &
              control_word(FREQUENCY_10S_CONTROL_CANCEL_BIT) & '0' &
              control_word(1 downto 0);
            if control_word(2) = '1' then
              frequency_10s_boundary_update <=
                not frequency_10s_boundary_update;
            end if;
          end if;
          bvalid <= '1';
        end if;

        if rvalid = '1' and s_axi_rready = '1' then
          rvalid <= '0';
        end if;

        if rvalid = '0' and s_axi_arvalid = '1' then
          address_word := to_integer(unsigned(s_axi_araddr(7 downto 2)));
          case address_word is
            when 0  => rdata <= VERSION_VALUE;
            when 1  => rdata <= IDENTIFIER_VALUE;
            when 2  => rdata <= (31 downto 1 => '0') & enabled;
            when 3  => rdata <= status_i;
            when 4  => rdata <= latched_tick(31 downto 0);
            when 5  => rdata <= latched_tick(63 downto 32);
            when 6  => rdata <= latched_sequence(31 downto 0);
            when 7  => rdata <= latched_sequence(63 downto 32);
            when 8  => rdata <= tick_i(31 downto 0);
            when 9  => rdata <= tick_i(63 downto 32);
            when 10 => rdata <= sequence_i(31 downto 0);
            when 11 => rdata <= sequence_i(63 downto 32);
            when 12 => rdata <= drop_count_i;
            when 13 => rdata <= block_count_i;
            when 14 => rdata <= BLOCK_BYTES_VALUE;
            when 16 => rdata <= ten_minute_target(31 downto 0);
            when 17 => rdata <= ten_minute_target(63 downto 32);
            when 18 => rdata <= (31 downto 9 => '0') & ten_minute_update &
                              (7 downto 1 => '0') & ten_minute_valid;
            when FREQUENCY_10S_REG_START_SAMPLE_LOW / 4 =>
              rdata <= frequency_10s_boundary.start_sample(31 downto 0);
            when FREQUENCY_10S_REG_START_SAMPLE_HIGH / 4 =>
              rdata <= frequency_10s_boundary.start_sample(63 downto 32);
            when FREQUENCY_10S_REG_END_SAMPLE_LOW / 4 =>
              rdata <= frequency_10s_boundary.end_sample(31 downto 0);
            when FREQUENCY_10S_REG_END_SAMPLE_HIGH / 4 =>
              rdata <= frequency_10s_boundary.end_sample(63 downto 32);
            when FREQUENCY_10S_REG_UTC_START_LOW / 4 =>
              rdata <= frequency_10s_boundary.utc_start_nanoseconds(31 downto 0);
            when FREQUENCY_10S_REG_UTC_START_HIGH / 4 =>
              rdata <= frequency_10s_boundary.utc_start_nanoseconds(63 downto 32);
            when FREQUENCY_10S_REG_UTC_END_LOW / 4 =>
              rdata <= frequency_10s_boundary.utc_end_nanoseconds(31 downto 0);
            when FREQUENCY_10S_REG_UTC_END_HIGH / 4 =>
              rdata <= frequency_10s_boundary.utc_end_nanoseconds(63 downto 32);
            when FREQUENCY_10S_REG_UNCERTAINTY_LOW / 4 =>
              rdata <= frequency_10s_boundary.utc_uncertainty_nanoseconds(31 downto 0);
            when FREQUENCY_10S_REG_UNCERTAINTY_HIGH / 4 =>
              rdata <= frequency_10s_boundary.utc_uncertainty_nanoseconds(63 downto 32);
            when FREQUENCY_10S_REG_MEASURED_RATE_MILLIHZ / 4 =>
              rdata <= frequency_10s_boundary.measured_sample_rate_millihz;
            when FREQUENCY_10S_REG_BOUNDARY_GENERATION / 4 =>
              rdata <= frequency_10s_boundary.boundary_generation;
            when FREQUENCY_10S_REG_PROFILE / 4 =>
              rdata <= frequency_10s_boundary.profile;
            when FREQUENCY_10S_REG_CONTROL / 4 =>
              rdata <= (31 downto 9 => '0') & frequency_10s_boundary_update &
                       (7 downto 4 => '0') &
                       frequency_10s_boundary.control(
                         FREQUENCY_10S_CONTROL_CANCEL_BIT) & '0' &
                       frequency_10s_boundary.control(1 downto 0);
            when FREQUENCY_10S_REG_OBSERVER_STATUS / 4 =>
              rdata <= frequency_10s_status_i;
            when FREQUENCY_10S_REG_COMPLETED_COUNT / 4 =>
              rdata <= frequency_10s_completed_count_i;
            when FREQUENCY_10S_REG_DROPPED_COUNT / 4 =>
              rdata <= frequency_10s_dropped_count_i;
            when FREQUENCY_10S_REG_OVERFLOW_COUNT / 4 =>
              rdata <= frequency_10s_overflow_count_i;
            when FREQUENCY_10S_REG_DISCONTINUITY_COUNT / 4 =>
              rdata <= frequency_10s_discontinuity_count_i;
            when others => rdata <= (others => '0');
          end case;
          rvalid <= '1';
        end if;
      end if;
    end if;
  end process;
end architecture;
