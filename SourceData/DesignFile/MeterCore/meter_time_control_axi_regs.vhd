library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.metering_pkg.all;
use work.meter_frequency_10s_pkg.all;

-- Linux-owned metrology time-control endpoint. This block is independent of
-- every DMA path: it observes accepted conversion frames directly and owns
-- atomic PL-tick/sample-index correlation plus interval scheduling registers.
entity meter_time_control_axi_regs is
  port (
    aclk : in std_logic;
    aresetn : in std_logic;
    s_axi_awaddr : in std_logic_vector(7 downto 0);
    s_axi_awvalid : in std_logic;
    s_axi_awready : out std_logic;
    s_axi_wdata : in std_logic_vector(31 downto 0);
    s_axi_wstrb : in std_logic_vector(3 downto 0);
    s_axi_wvalid : in std_logic;
    s_axi_wready : out std_logic;
    s_axi_bresp : out std_logic_vector(1 downto 0);
    s_axi_bvalid : out std_logic;
    s_axi_bready : in std_logic;
    s_axi_araddr : in std_logic_vector(7 downto 0);
    s_axi_arvalid : in std_logic;
    s_axi_arready : out std_logic;
    s_axi_rdata : out std_logic_vector(31 downto 0);
    s_axi_rresp : out std_logic_vector(1 downto 0);
    s_axi_rvalid : out std_logic;
    s_axi_rready : in std_logic;
    sample_accept_i : in std_logic;
    sample_index_i : in std_logic_vector(63 downto 0);
    ten_minute_target_sample_o : out std_logic_vector(63 downto 0);
    ten_minute_target_valid_o : out std_logic;
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

architecture rtl of meter_time_control_axi_regs is
  constant VERSION_VALUE : std_logic_vector(31 downto 0) := x"00010000";
  constant IDENTIFIER_VALUE : std_logic_vector(31 downto 0) := x"3143544D"; -- MTC1
  signal tick_counter : unsigned(63 downto 0) := (others => '0');
  signal current_sample : std_logic_vector(63 downto 0) := (others => '0');
  signal sample_seen : std_logic := '0';
  signal latched_tick : std_logic_vector(63 downto 0) := (others => '0');
  signal latched_sample : std_logic_vector(63 downto 0) := (others => '0');
  signal ten_minute_target : std_logic_vector(63 downto 0) := (others => '0');
  signal ten_minute_valid : std_logic := '0';
  signal ten_minute_update : std_logic := '0';
  signal frequency_10s_boundary : frequency_10s_boundary_t := FREQUENCY_10S_BOUNDARY_RESET;
  signal frequency_10s_boundary_update : std_logic := '0';
  signal bvalid : std_logic := '0';
  signal rvalid : std_logic := '0';
  signal rdata : std_logic_vector(31 downto 0) := (others => '0');
begin
  s_axi_awready <= '1' when bvalid = '0' and s_axi_awvalid = '1' and s_axi_wvalid = '1' else '0';
  s_axi_wready <= '1' when bvalid = '0' and s_axi_awvalid = '1' and s_axi_wvalid = '1' else '0';
  s_axi_bresp <= "00";
  s_axi_bvalid <= bvalid;
  s_axi_arready <= '1' when rvalid = '0' else '0';
  s_axi_rresp <= "00";
  s_axi_rvalid <= rvalid;
  s_axi_rdata <= rdata;
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
      if aresetn = '0' then
        tick_counter <= (others => '0');
        current_sample <= (others => '0');
        sample_seen <= '0';
        latched_tick <= (others => '0');
        latched_sample <= (others => '0');
        ten_minute_target <= (others => '0');
        ten_minute_valid <= '0';
        ten_minute_update <= '0';
        frequency_10s_boundary <= FREQUENCY_10S_BOUNDARY_RESET;
        frequency_10s_boundary_update <= '0';
        bvalid <= '0';
        rvalid <= '0';
        rdata <= (others => '0');
      else
        tick_counter <= tick_counter + 1;
        if sample_accept_i = '1' then
          current_sample <= sample_index_i;
          sample_seen <= '1';
        end if;
        if bvalid = '1' and s_axi_bready = '1' then
          bvalid <= '0';
        end if;
        if bvalid = '0' and s_axi_awvalid = '1' and s_axi_wvalid = '1' then
          address_word := to_integer(unsigned(s_axi_awaddr(7 downto 2)));
          if address_word = 2 and s_axi_wstrb(0) = '1' and s_axi_wdata(1) = '1' then
            latched_tick <= std_logic_vector(tick_counter);
            if sample_accept_i = '1' then
              latched_sample <= sample_index_i;
            else
              latched_sample <= current_sample;
            end if;
          elsif address_word = 16 then
            ten_minute_target(31 downto 0) <= apply_write_strobes(ten_minute_target(31 downto 0), s_axi_wdata, s_axi_wstrb);
          elsif address_word = 17 then
            ten_minute_target(63 downto 32) <= apply_write_strobes(ten_minute_target(63 downto 32), s_axi_wdata, s_axi_wstrb);
          elsif address_word = 18 and s_axi_wstrb(0) = '1' then
            ten_minute_valid <= s_axi_wdata(0);
            if s_axi_wdata(1) = '1' then
              ten_minute_update <= not ten_minute_update;
            end if;
          elsif address_word = FREQUENCY_10S_REG_START_SAMPLE_LOW / 4 then
            frequency_10s_boundary.start_sample(31 downto 0) <= apply_write_strobes(frequency_10s_boundary.start_sample(31 downto 0), s_axi_wdata, s_axi_wstrb);
          elsif address_word = FREQUENCY_10S_REG_START_SAMPLE_HIGH / 4 then
            frequency_10s_boundary.start_sample(63 downto 32) <= apply_write_strobes(frequency_10s_boundary.start_sample(63 downto 32), s_axi_wdata, s_axi_wstrb);
          elsif address_word = FREQUENCY_10S_REG_END_SAMPLE_LOW / 4 then
            frequency_10s_boundary.end_sample(31 downto 0) <= apply_write_strobes(frequency_10s_boundary.end_sample(31 downto 0), s_axi_wdata, s_axi_wstrb);
          elsif address_word = FREQUENCY_10S_REG_END_SAMPLE_HIGH / 4 then
            frequency_10s_boundary.end_sample(63 downto 32) <= apply_write_strobes(frequency_10s_boundary.end_sample(63 downto 32), s_axi_wdata, s_axi_wstrb);
          elsif address_word = FREQUENCY_10S_REG_UTC_START_LOW / 4 then
            frequency_10s_boundary.utc_start_nanoseconds(31 downto 0) <= apply_write_strobes(frequency_10s_boundary.utc_start_nanoseconds(31 downto 0), s_axi_wdata, s_axi_wstrb);
          elsif address_word = FREQUENCY_10S_REG_UTC_START_HIGH / 4 then
            frequency_10s_boundary.utc_start_nanoseconds(63 downto 32) <= apply_write_strobes(frequency_10s_boundary.utc_start_nanoseconds(63 downto 32), s_axi_wdata, s_axi_wstrb);
          elsif address_word = FREQUENCY_10S_REG_UTC_END_LOW / 4 then
            frequency_10s_boundary.utc_end_nanoseconds(31 downto 0) <= apply_write_strobes(frequency_10s_boundary.utc_end_nanoseconds(31 downto 0), s_axi_wdata, s_axi_wstrb);
          elsif address_word = FREQUENCY_10S_REG_UTC_END_HIGH / 4 then
            frequency_10s_boundary.utc_end_nanoseconds(63 downto 32) <= apply_write_strobes(frequency_10s_boundary.utc_end_nanoseconds(63 downto 32), s_axi_wdata, s_axi_wstrb);
          elsif address_word = FREQUENCY_10S_REG_UNCERTAINTY_LOW / 4 then
            frequency_10s_boundary.utc_uncertainty_nanoseconds(31 downto 0) <= apply_write_strobes(frequency_10s_boundary.utc_uncertainty_nanoseconds(31 downto 0), s_axi_wdata, s_axi_wstrb);
          elsif address_word = FREQUENCY_10S_REG_UNCERTAINTY_HIGH / 4 then
            frequency_10s_boundary.utc_uncertainty_nanoseconds(63 downto 32) <= apply_write_strobes(frequency_10s_boundary.utc_uncertainty_nanoseconds(63 downto 32), s_axi_wdata, s_axi_wstrb);
          elsif address_word = FREQUENCY_10S_REG_MEASURED_RATE_MILLIHZ / 4 then
            frequency_10s_boundary.measured_sample_rate_millihz <= apply_write_strobes(frequency_10s_boundary.measured_sample_rate_millihz, s_axi_wdata, s_axi_wstrb);
          elsif address_word = FREQUENCY_10S_REG_BOUNDARY_GENERATION / 4 then
            frequency_10s_boundary.boundary_generation <= apply_write_strobes(frequency_10s_boundary.boundary_generation, s_axi_wdata, s_axi_wstrb);
          elsif address_word = FREQUENCY_10S_REG_PROFILE / 4 then
            frequency_10s_boundary.profile <= apply_write_strobes(frequency_10s_boundary.profile, s_axi_wdata, s_axi_wstrb);
          elsif address_word = FREQUENCY_10S_REG_CONTROL / 4 then
            control_word := apply_write_strobes(frequency_10s_boundary.control, s_axi_wdata, s_axi_wstrb);
            frequency_10s_boundary.control <= (31 downto 4 => '0') & control_word(FREQUENCY_10S_CONTROL_CANCEL_BIT) & '0' & control_word(1 downto 0);
            if control_word(2) = '1' then
              frequency_10s_boundary_update <= not frequency_10s_boundary_update;
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
            when 0 => rdata <= VERSION_VALUE;
            when 1 => rdata <= IDENTIFIER_VALUE;
            when 2 => rdata <= (others => '0');
            when 3 => rdata <= (31 downto 1 => '0') & sample_seen;
            when 4 => rdata <= latched_tick(31 downto 0);
            when 5 => rdata <= latched_tick(63 downto 32);
            when 6 => rdata <= latched_sample(31 downto 0);
            when 7 => rdata <= latched_sample(63 downto 32);
            when 8 => rdata <= std_logic_vector(tick_counter(31 downto 0));
            when 9 => rdata <= std_logic_vector(tick_counter(63 downto 32));
            when 10 => rdata <= current_sample(31 downto 0);
            when 11 => rdata <= current_sample(63 downto 32);
            when 16 => rdata <= ten_minute_target(31 downto 0);
            when 17 => rdata <= ten_minute_target(63 downto 32);
            when 18 => rdata <= (31 downto 9 => '0') & ten_minute_update & (7 downto 1 => '0') & ten_minute_valid;
            when FREQUENCY_10S_REG_START_SAMPLE_LOW / 4 => rdata <= frequency_10s_boundary.start_sample(31 downto 0);
            when FREQUENCY_10S_REG_START_SAMPLE_HIGH / 4 => rdata <= frequency_10s_boundary.start_sample(63 downto 32);
            when FREQUENCY_10S_REG_END_SAMPLE_LOW / 4 => rdata <= frequency_10s_boundary.end_sample(31 downto 0);
            when FREQUENCY_10S_REG_END_SAMPLE_HIGH / 4 => rdata <= frequency_10s_boundary.end_sample(63 downto 32);
            when FREQUENCY_10S_REG_UTC_START_LOW / 4 => rdata <= frequency_10s_boundary.utc_start_nanoseconds(31 downto 0);
            when FREQUENCY_10S_REG_UTC_START_HIGH / 4 => rdata <= frequency_10s_boundary.utc_start_nanoseconds(63 downto 32);
            when FREQUENCY_10S_REG_UTC_END_LOW / 4 => rdata <= frequency_10s_boundary.utc_end_nanoseconds(31 downto 0);
            when FREQUENCY_10S_REG_UTC_END_HIGH / 4 => rdata <= frequency_10s_boundary.utc_end_nanoseconds(63 downto 32);
            when FREQUENCY_10S_REG_UNCERTAINTY_LOW / 4 => rdata <= frequency_10s_boundary.utc_uncertainty_nanoseconds(31 downto 0);
            when FREQUENCY_10S_REG_UNCERTAINTY_HIGH / 4 => rdata <= frequency_10s_boundary.utc_uncertainty_nanoseconds(63 downto 32);
            when FREQUENCY_10S_REG_MEASURED_RATE_MILLIHZ / 4 => rdata <= frequency_10s_boundary.measured_sample_rate_millihz;
            when FREQUENCY_10S_REG_BOUNDARY_GENERATION / 4 => rdata <= frequency_10s_boundary.boundary_generation;
            when FREQUENCY_10S_REG_PROFILE / 4 => rdata <= frequency_10s_boundary.profile;
            when FREQUENCY_10S_REG_CONTROL / 4 => rdata <= (31 downto 9 => '0') & frequency_10s_boundary_update & (7 downto 4 => '0') & frequency_10s_boundary.control(FREQUENCY_10S_CONTROL_CANCEL_BIT) & '0' & frequency_10s_boundary.control(1 downto 0);
            when FREQUENCY_10S_REG_OBSERVER_STATUS / 4 => rdata <= frequency_10s_status_i;
            when FREQUENCY_10S_REG_COMPLETED_COUNT / 4 => rdata <= frequency_10s_completed_count_i;
            when FREQUENCY_10S_REG_DROPPED_COUNT / 4 => rdata <= frequency_10s_dropped_count_i;
            when FREQUENCY_10S_REG_OVERFLOW_COUNT / 4 => rdata <= frequency_10s_overflow_count_i;
            when FREQUENCY_10S_REG_DISCONTINUITY_COUNT / 4 => rdata <= frequency_10s_discontinuity_count_i;
            when others => rdata <= (others => '0');
          end case;
          rvalid <= '1';
        end if;
      end if;
    end if;
  end process;
end architecture;
