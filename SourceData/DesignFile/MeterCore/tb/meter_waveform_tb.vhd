library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity meter_waveform_tb is
end entity;

architecture sim of meter_waveform_tb is
  constant C_CLOCK_PERIOD : time := 10 ns;
  constant C_FRAMES       : positive := 4;
  constant C_BLOCK_WORDS  : positive := 16 + (C_FRAMES * 8);

  signal aclk       : std_logic := '0';
  signal aresetn    : std_logic := '0';
  signal frame_accept : std_logic := '0';
  signal raw_frame  : std_logic_vector(255 downto 0) := (others => '0');
  signal sample_index : std_logic_vector(63 downto 0) := (others => '0');
  signal enable     : std_logic := '0';
  signal tick       : std_logic_vector(63 downto 0);
  signal sequence_value : std_logic_vector(63 downto 0);
  signal drops      : std_logic_vector(31 downto 0);
  signal blocks     : std_logic_vector(31 downto 0);
  signal status     : std_logic_vector(31 downto 0);
  signal axis_data  : std_logic_vector(31 downto 0);
  signal axis_keep  : std_logic_vector(3 downto 0);
  signal axis_valid : std_logic;
  signal axis_ready : std_logic := '1';
  signal axis_last  : std_logic;
begin
  aclk <= not aclk after C_CLOCK_PERIOD / 2;

  dut : entity work.meter_waveform
    generic map (
      G_FRAMES_PER_BLOCK => C_FRAMES,
      G_FIFO_DEPTH => 16
    )
    port map (
      aclk => aclk,
      aresetn => aresetn,
      frame_accept_i => frame_accept,
      raw_frame_i => raw_frame,
      sample_index_i => sample_index,
      config_generation_i => x"12345678",
      measured_frame_rate_hz_i => std_logic_vector(to_unsigned(128000, 32)),
      measured_frame_rate_valid_i => '1',
      enable_i => enable,
      clear_stats_i => '0',
      tick_o => tick,
      sequence_o => sequence_value,
      drop_count_o => drops,
      block_count_o => blocks,
      status_o => status,
      m_axis_tdata => axis_data,
      m_axis_tkeep => axis_keep,
      m_axis_tvalid => axis_valid,
      m_axis_tready => axis_ready,
      m_axis_tlast => axis_last
    );

  stimulus : process
    procedure wait_fifo_ready is
    begin
      for attempt in 0 to 100 loop
        wait until rising_edge(aclk);
        exit when status(3) = '0';
      end loop;
      assert status(3) = '0'
        report "waveform FIFO did not leave reset" severity failure;
      for delay_cycle in 0 to 3 loop
        wait until rising_edge(aclk);
      end loop;
    end procedure;

    procedure push_frame(constant index : natural) is
    begin
      sample_index <= std_logic_vector(to_unsigned(index, 64));
      raw_frame <= std_logic_vector(to_unsigned(index, raw_frame'length));
      frame_accept <= '1';
      wait until rising_edge(aclk);
      frame_accept <= '0';
      wait until rising_edge(aclk);
    end procedure;

    variable old_words : natural := 0;
    variable new_words : natural := 0;
  begin
    for reset_cycle in 0 to 5 loop
      wait until rising_edge(aclk);
    end loop;
    aresetn <= '1';
    enable <= '1';
    wait_fifo_ready;

    -- Begin a block and stop it after the header plus half of frame zero.
    push_frame(1);
    push_frame(2);
    while old_words < 20 loop
      wait until rising_edge(aclk);
      if axis_valid = '1' and axis_ready = '1' then
        old_words := old_words + 1;
      end if;
    end loop;
    assert axis_last = '0'
      report "partial pre-stop block unexpectedly asserted TLAST"
      severity failure;

    enable <= '0';
    for disabled_cycle in 0 to 5 loop
      wait until rising_edge(aclk);
    end loop;
    assert axis_valid = '0'
      report "waveform output remained valid while disabled" severity failure;

    -- Backpressure while filling the fresh epoch makes every observed word
    -- unambiguously belong to the post-reopen packet.
    axis_ready <= '0';
    enable <= '1';
    wait_fifo_ready;
    push_frame(100);
    push_frame(101);
    push_frame(102);
    push_frame(103);
    axis_ready <= '1';

    while new_words < C_BLOCK_WORDS loop
      wait until rising_edge(aclk);
      if axis_valid = '1' and axis_ready = '1' then
        new_words := new_words + 1;
        if new_words = 1 then
          assert axis_data = x"314D4657"
            report "reopened waveform epoch did not begin with WFM1 magic"
            severity failure;
        elsif new_words = 6 then
          assert axis_data = std_logic_vector(to_unsigned(100, 32))
            report "reopened waveform epoch retained a pre-stop frame"
            severity failure;
        end if;
        if new_words < C_BLOCK_WORDS then
          assert axis_last = '0'
            report "reopened waveform packet asserted TLAST early"
            severity failure;
        else
          assert axis_last = '1'
            report "reopened waveform packet omitted TLAST" severity failure;
        end if;
      end if;
    end loop;

    wait until rising_edge(aclk);

    assert unsigned(blocks) = 1
      report "discarded partial block changed completed block count"
      severity failure;
    assert unsigned(drops) = 0
      report "orderly disable/re-enable created PL waveform drops"
      severity failure;
    report "PASS: meter_waveform disable flushes partial packet" severity note;
    std.env.finish;
  end process;

  watchdog : process
  begin
    wait for 2 ms;
    assert false report "meter_waveform test timed out" severity failure;
  end process;
end architecture;
