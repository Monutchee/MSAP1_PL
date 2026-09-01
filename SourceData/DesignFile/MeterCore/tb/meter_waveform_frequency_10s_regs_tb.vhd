library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.meter_frequency_10s_pkg.all;

entity meter_waveform_frequency_10s_regs_tb is
end entity;

architecture tb of meter_waveform_frequency_10s_regs_tb is
  constant C_CLOCK_PERIOD : time := 10 ns;

  signal aclk : std_logic := '0';
  signal aresetn : std_logic := '0';
  signal awaddr : std_logic_vector(7 downto 0) := (others => '0');
  signal awvalid : std_logic := '0';
  signal awready : std_logic;
  signal wdata : std_logic_vector(31 downto 0) := (others => '0');
  signal wstrb : std_logic_vector(3 downto 0) := (others => '0');
  signal wvalid : std_logic := '0';
  signal wready : std_logic;
  signal bresp : std_logic_vector(1 downto 0);
  signal bvalid : std_logic;
  signal bready : std_logic := '1';
  signal araddr : std_logic_vector(7 downto 0) := (others => '0');
  signal arvalid : std_logic := '0';
  signal arready : std_logic;
  signal rdata : std_logic_vector(31 downto 0);
  signal rresp : std_logic_vector(1 downto 0);
  signal rvalid : std_logic;
  signal rready : std_logic := '1';

  signal boundary : frequency_10s_boundary_t;
  signal boundary_update : std_logic;
begin
  aclk <= not aclk after C_CLOCK_PERIOD / 2;

  dut : entity work.meter_waveform_axi_regs
    port map (
      aclk => aclk,
      aresetn => aresetn,
      s_axi_awaddr => awaddr,
      s_axi_awvalid => awvalid,
      s_axi_awready => awready,
      s_axi_wdata => wdata,
      s_axi_wstrb => wstrb,
      s_axi_wvalid => wvalid,
      s_axi_wready => wready,
      s_axi_bresp => bresp,
      s_axi_bvalid => bvalid,
      s_axi_bready => bready,
      s_axi_araddr => araddr,
      s_axi_arvalid => arvalid,
      s_axi_arready => arready,
      s_axi_rdata => rdata,
      s_axi_rresp => rresp,
      s_axi_rvalid => rvalid,
      s_axi_rready => rready,
      tick_i => x"0123456789ABCDEF",
      sequence_i => x"1122334455667788",
      drop_count_i => x"01020304",
      block_count_i => x"05060708",
      status_i => x"0000000F",
      enable_o => open,
      clear_stats_o => open,
      ten_minute_target_sample_o => open,
      ten_minute_target_valid_o => open,
      ten_minute_target_update_o => open,
      frequency_10s_boundary_o => boundary,
      frequency_10s_boundary_update_o => boundary_update,
      frequency_10s_status_i => x"A0000001",
      frequency_10s_completed_count_i => x"00000011",
      frequency_10s_dropped_count_i => x"00000022",
      frequency_10s_overflow_count_i => x"00000033",
      frequency_10s_discontinuity_count_i => x"00000044");

  stimulus : process
    procedure axi_write(
      constant address : in natural;
      constant value : in std_logic_vector(31 downto 0);
      constant strobes : in std_logic_vector(3 downto 0) := "1111") is
    begin
      wait until falling_edge(aclk);
      awaddr <= std_logic_vector(to_unsigned(address, awaddr'length));
      wdata <= value;
      wstrb <= strobes;
      awvalid <= '1';
      wvalid <= '1';
      wait until rising_edge(aclk) and awready = '1' and wready = '1';
      wait until falling_edge(aclk);
      awvalid <= '0';
      wvalid <= '0';
      wstrb <= (others => '0');
      if bvalid = '0' then
        wait until rising_edge(aclk) and bvalid = '1';
      end if;
      assert bresp = "00"
        report "frequency ten-second AXI write returned an error"
        severity failure;
    end procedure;

    procedure axi_read(
      constant address : in natural;
      constant expected : in std_logic_vector(31 downto 0)) is
    begin
      wait until falling_edge(aclk);
      araddr <= std_logic_vector(to_unsigned(address, araddr'length));
      arvalid <= '1';
      wait until rising_edge(aclk) and arready = '1';
      wait until falling_edge(aclk);
      arvalid <= '0';
      if rvalid = '0' then
        wait until rising_edge(aclk) and rvalid = '1';
      end if;
      assert rresp = "00" and rdata = expected
        report "frequency ten-second AXI readback mismatch at address " &
          integer'image(address)
        severity failure;
    end procedure;
  begin
    wait for 8 * C_CLOCK_PERIOD;
    wait until falling_edge(aclk);
    aresetn <= '1';
    wait for 4 * C_CLOCK_PERIOD;

    axi_write(FREQUENCY_10S_REG_START_SAMPLE_LOW, x"89ABCDEF");
    axi_write(FREQUENCY_10S_REG_START_SAMPLE_HIGH, x"01234567");
    axi_write(FREQUENCY_10S_REG_END_SAMPLE_LOW, x"76543210");
    axi_write(FREQUENCY_10S_REG_END_SAMPLE_HIGH, x"FEDCBA98");
    axi_write(FREQUENCY_10S_REG_UTC_START_LOW, x"A817C800");
    axi_write(FREQUENCY_10S_REG_UTC_START_HIGH, x"00000004");
    axi_write(FREQUENCY_10S_REG_UTC_END_LOW, x"FC23AC00");
    axi_write(FREQUENCY_10S_REG_UTC_END_HIGH, x"00000006");
    axi_write(FREQUENCY_10S_REG_UNCERTAINTY_LOW, x"000186A0");
    axi_write(FREQUENCY_10S_REG_UNCERTAINTY_HIGH, x"00000000");
    axi_write(FREQUENCY_10S_REG_MEASURED_RATE_MILLIHZ, x"07A12000");
    axi_write(FREQUENCY_10S_REG_BOUNDARY_GENERATION, x"11223344");
    axi_write(FREQUENCY_10S_REG_PROFILE, x"01010632");
    -- Byte strobes must preserve the untouched profile fields.
    axi_write(FREQUENCY_10S_REG_PROFILE, x"0000003C", "0001");
    axi_write(FREQUENCY_10S_REG_CONTROL, x"00000007");

    axi_read(FREQUENCY_10S_REG_START_SAMPLE_LOW, x"89ABCDEF");
    axi_read(FREQUENCY_10S_REG_START_SAMPLE_HIGH, x"01234567");
    axi_read(FREQUENCY_10S_REG_END_SAMPLE_LOW, x"76543210");
    axi_read(FREQUENCY_10S_REG_END_SAMPLE_HIGH, x"FEDCBA98");
    axi_read(FREQUENCY_10S_REG_UTC_START_LOW, x"A817C800");
    axi_read(FREQUENCY_10S_REG_UTC_START_HIGH, x"00000004");
    axi_read(FREQUENCY_10S_REG_UTC_END_LOW, x"FC23AC00");
    axi_read(FREQUENCY_10S_REG_UTC_END_HIGH, x"00000006");
    axi_read(FREQUENCY_10S_REG_UNCERTAINTY_LOW, x"000186A0");
    axi_read(FREQUENCY_10S_REG_UNCERTAINTY_HIGH, x"00000000");
    axi_read(FREQUENCY_10S_REG_MEASURED_RATE_MILLIHZ, x"07A12000");
    axi_read(FREQUENCY_10S_REG_BOUNDARY_GENERATION, x"11223344");
    axi_read(FREQUENCY_10S_REG_PROFILE, x"0101063C");
    axi_read(FREQUENCY_10S_REG_CONTROL, x"00000103");
    axi_read(FREQUENCY_10S_REG_OBSERVER_STATUS, x"A0000001");
    axi_read(FREQUENCY_10S_REG_COMPLETED_COUNT, x"00000011");
    axi_read(FREQUENCY_10S_REG_DROPPED_COUNT, x"00000022");
    axi_read(FREQUENCY_10S_REG_OVERFLOW_COUNT, x"00000033");
    axi_read(FREQUENCY_10S_REG_DISCONTINUITY_COUNT, x"00000044");

    assert boundary.start_sample = x"0123456789ABCDEF" and
           boundary.end_sample = x"FEDCBA9876543210" and
           boundary.utc_start_nanoseconds = x"00000004A817C800" and
           boundary.utc_end_nanoseconds = x"00000006FC23AC00" and
           boundary.utc_uncertainty_nanoseconds = x"00000000000186A0" and
           boundary.measured_sample_rate_millihz = x"07A12000" and
           boundary.boundary_generation = x"11223344" and
           boundary.profile = x"0101063C" and
           boundary.control = x"00000003" and
           boundary_update = '1'
      report "frequency ten-second coherent boundary handoff is incorrect"
      severity failure;

    report "PASS: meter_waveform_frequency_10s_regs_tb" severity note;
    std.env.finish;
    wait;
  end process;
end architecture;
