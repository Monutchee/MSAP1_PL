library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.meter_frequency_10s_pkg.all;

entity meter_time_control_regs_tb is
end entity;

architecture tb of meter_time_control_regs_tb is
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
  signal sample_accept : std_logic := '0';
  signal sample_index : std_logic_vector(63 downto 0) := (others => '0');
  signal ten_minute_target : std_logic_vector(63 downto 0);
  signal ten_minute_valid : std_logic;
  signal ten_minute_update : std_logic;
  signal boundary : frequency_10s_boundary_t;
  signal boundary_update : std_logic;
begin
  aclk <= not aclk after C_CLOCK_PERIOD / 2;

  dut : entity work.meter_time_control_axi_regs
    port map (
      aclk => aclk, aresetn => aresetn,
      s_axi_awaddr => awaddr, s_axi_awvalid => awvalid,
      s_axi_awready => awready, s_axi_wdata => wdata,
      s_axi_wstrb => wstrb, s_axi_wvalid => wvalid,
      s_axi_wready => wready, s_axi_bresp => bresp,
      s_axi_bvalid => bvalid, s_axi_bready => bready,
      s_axi_araddr => araddr, s_axi_arvalid => arvalid,
      s_axi_arready => arready, s_axi_rdata => rdata,
      s_axi_rresp => rresp, s_axi_rvalid => rvalid,
      s_axi_rready => rready,
      sample_accept_i => sample_accept, sample_index_i => sample_index,
      ten_minute_target_sample_o => ten_minute_target,
      ten_minute_target_valid_o => ten_minute_valid,
      ten_minute_target_update_o => ten_minute_update,
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
      assert bresp = "00" report "meter-time AXI write error" severity failure;
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
        report "meter-time AXI readback mismatch at " & integer'image(address)
        severity failure;
    end procedure;
  begin
    wait for 8 * C_CLOCK_PERIOD;
    wait until falling_edge(aclk);
    aresetn <= '1';
    wait for 4 * C_CLOCK_PERIOD;

    axi_read(16#00#, x"00010000");
    axi_read(16#04#, x"3143544D");
    sample_index <= x"1122334455667788";
    sample_accept <= '1';
    wait until rising_edge(aclk);
    wait until falling_edge(aclk);
    sample_accept <= '0';
    axi_write(16#08#, x"00000002");
    axi_read(16#0C#, x"00000001");
    axi_read(16#18#, x"55667788");
    axi_read(16#1C#, x"11223344");

    axi_write(16#40#, x"89ABCDEF");
    axi_write(16#44#, x"01234567");
    axi_write(16#48#, x"00000003");
    axi_read(16#40#, x"89ABCDEF");
    axi_read(16#44#, x"01234567");
    axi_read(16#48#, x"00000101");
    assert ten_minute_target = x"0123456789ABCDEF" and
           ten_minute_valid = '1' and ten_minute_update = '1'
      report "ten-minute target handoff is incorrect" severity failure;

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
    axi_write(FREQUENCY_10S_REG_PROFILE, x"0000003C", "0001");
    axi_write(FREQUENCY_10S_REG_CONTROL, x"00000007");

    axi_read(FREQUENCY_10S_REG_PROFILE, x"0101063C");
    axi_read(FREQUENCY_10S_REG_CONTROL, x"00000103");
    axi_read(FREQUENCY_10S_REG_OBSERVER_STATUS, x"A0000001");
    axi_read(FREQUENCY_10S_REG_COMPLETED_COUNT, x"00000011");
    axi_read(FREQUENCY_10S_REG_DROPPED_COUNT, x"00000022");
    axi_read(FREQUENCY_10S_REG_OVERFLOW_COUNT, x"00000033");
    axi_read(FREQUENCY_10S_REG_DISCONTINUITY_COUNT, x"00000044");
    assert boundary.start_sample = x"0123456789ABCDEF" and
           boundary.end_sample = x"FEDCBA9876543210" and
           boundary.profile = x"0101063C" and
           boundary.control = x"00000003" and boundary_update = '1'
      report "ten-second boundary handoff is incorrect" severity failure;

    axi_write(FREQUENCY_10S_REG_CONTROL, x"0000000C");
    axi_read(FREQUENCY_10S_REG_CONTROL, x"00000008");
    assert boundary.control = x"00000008" and boundary_update = '0'
      report "ten-second cancellation handoff is incorrect" severity failure;

    report "PASS: meter_time_control_regs_tb" severity note;
    std.env.finish;
    wait;
  end process;
end architecture;
