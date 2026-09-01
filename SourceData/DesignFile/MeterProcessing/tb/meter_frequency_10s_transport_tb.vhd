library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.metering_pkg.all;
use work.meter_r5_aggregation_pkg.all;
use work.meter_frequency_10s_pkg.all;

entity meter_frequency_10s_transport_tb is
end entity;

architecture tb of meter_frequency_10s_transport_tb is
  constant C_CLOCK_PERIOD : time := 10 ns;
  constant C_SAMPLE_RATE_HZ : positive := 4000;
  constant C_DECIMATION : positive := 4;
  constant C_INTERVAL_START : natural := 4000;
  constant C_INTERVAL_SAMPLES : natural := C_SAMPLE_RATE_HZ * 10;
  constant C_INTERVAL_END : natural :=
    C_INTERVAL_START + C_INTERVAL_SAMPLES;
  constant C_DRIVE_LAST_SAMPLE : natural := C_INTERVAL_END + 200;
  constant C_WAVE_PERIOD_SAMPLES : positive := C_SAMPLE_RATE_HZ / 50;
  constant C_REQUIRED_STATUS : std_logic_vector(31 downto 0) := x"0000061F";

  type word_array_t is array (natural range <>) of
    std_logic_vector(31 downto 0);
  type bit_array_t is array (natural range <>) of std_logic;

  signal aclk : std_logic := '0';
  signal aresetn : std_logic := '0';
  signal frame_accept : std_logic := '0';
  signal frame_data : std_logic_vector(
    METER_CONVERTED_FRAME_BITS - 1 downto 0) := (others => '0');
  signal frame_keep : std_logic_vector(
    METER_CONVERTED_KEEP_BITS - 1 downto 0) := (others => '1');
  signal frame_user : std_logic_vector(383 downto 0) := (others => '0');
  signal config_generation : std_logic_vector(31 downto 0) := x"00000007";
  signal configured_sample_rate : std_logic_vector(31 downto 0) :=
    std_logic_vector(to_unsigned(C_SAMPLE_RATE_HZ, 32));
  signal measured_frame_rate : std_logic_vector(31 downto 0) :=
    std_logic_vector(to_unsigned(C_SAMPLE_RATE_HZ, 32));
  signal measured_frame_rate_valid : std_logic := '0';
  signal config_apply_toggle : std_logic := '0';
  signal boundary : frequency_10s_boundary_t :=
    FREQUENCY_10S_BOUNDARY_RESET;
  signal boundary_update : std_logic := '0';
  signal clear_stats : std_logic := '0';

  signal payload_tdata : std_logic_vector(31 downto 0);
  signal payload_tkeep : std_logic_vector(3 downto 0);
  signal payload_tvalid : std_logic;
  signal payload_tready : std_logic;
  signal payload_tlast : std_logic;
  signal observer_status : std_logic_vector(31 downto 0);
  signal completed_count : std_logic_vector(31 downto 0);
  signal dropped_count : std_logic_vector(31 downto 0);
  signal overflow_count : std_logic_vector(31 downto 0);
  signal discontinuity_count : std_logic_vector(31 downto 0);

  signal frame_tdata : std_logic_vector(31 downto 0);
  signal frame_tkeep : std_logic_vector(3 downto 0);
  signal frame_tvalid : std_logic;
  signal frame_tready : std_logic := '1';
  signal frame_tlast : std_logic;
  signal accepted_packets : std_logic_vector(31 downto 0);
  signal packetizer_drops : std_logic_vector(31 downto 0);
  signal transmitted_packets : std_logic_vector(31 downto 0);
  signal framing_errors : std_logic_vector(31 downto 0);

  signal observed_words : word_array_t(0 to FREQUENCY_10S_FRAME_WORDS - 1) :=
    (others => (others => '0'));
  signal observed_last : bit_array_t(0 to FREQUENCY_10S_FRAME_WORDS - 1) :=
    (others => '0');
  signal observed_count : natural range 0 to FREQUENCY_10S_FRAME_WORDS + 1 := 0;
begin
  aclk <= not aclk after C_CLOCK_PERIOD / 2;

  observer : entity work.meter_frequency_10s_observer
    generic map (
      G_CERTIFIED_SAMPLE_RATE_HZ => C_SAMPLE_RATE_HZ,
      G_DECIMATION => C_DECIMATION,
      G_CIC_GAIN_SHIFT => 6,
      G_FILTER_WARMUP_OUTPUTS => 24,
      G_HYSTERESIS_MICROVOLTS => 1000)
    port map (
      aclk => aclk,
      aresetn => aresetn,
      frame_accept_i => frame_accept,
      frame_data_i => frame_data,
      frame_keep_i => frame_keep,
      frame_user_i => frame_user,
      config_generation_i => config_generation,
      configured_sample_rate_hz_i => configured_sample_rate,
      measured_frame_rate_hz_i => measured_frame_rate,
      measured_frame_rate_valid_i => measured_frame_rate_valid,
      config_apply_toggle_i => config_apply_toggle,
      boundary_i => boundary,
      boundary_update_i => boundary_update,
      clear_stats_i => clear_stats,
      m_axis_payload_tdata => payload_tdata,
      m_axis_payload_tkeep => payload_tkeep,
      m_axis_payload_tvalid => payload_tvalid,
      m_axis_payload_tready => payload_tready,
      m_axis_payload_tlast => payload_tlast,
      status_o => observer_status,
      completed_count_o => completed_count,
      dropped_count_o => dropped_count,
      overflow_count_o => overflow_count,
      discontinuity_count_o => discontinuity_count);

  packetizer : entity work.meter_r5_fixed_packet_export
    generic map (
      G_MAGIC => FREQUENCY_10S_MAGIC,
      G_CONTRACT_REVISION => FREQUENCY_10S_CONTRACT_REVISION,
      G_PAYLOAD_WORDS => FREQUENCY_10S_PAYLOAD_WORDS,
      G_FIFO_DEPTH => 4096,
      G_FIFO_COUNT_WIDTH => 13,
      G_PACKET_SLOTS => 1)
    port map (
      aclk => aclk,
      aresetn => aresetn,
      s_axis_tdata => payload_tdata,
      s_axis_tkeep => payload_tkeep,
      s_axis_tvalid => payload_tvalid,
      s_axis_tready => payload_tready,
      s_axis_tlast => payload_tlast,
      m_axis_tdata => frame_tdata,
      m_axis_tkeep => frame_tkeep,
      m_axis_tvalid => frame_tvalid,
      m_axis_tready => frame_tready,
      m_axis_tlast => frame_tlast,
      accepted_packet_count_o => accepted_packets,
      dropped_packet_count_o => packetizer_drops,
      transmitted_packet_count_o => transmitted_packets,
      framing_error_count_o => framing_errors);

  capture_output : process (aclk)
  begin
    if rising_edge(aclk) then
      if aresetn = '0' then
        observed_count <= 0;
      elsif frame_tvalid = '1' and frame_tready = '1' then
        assert observed_count < FREQUENCY_10S_FRAME_WORDS
          report "FRQ1 packetizer emitted an extra word"
          severity failure;
        assert frame_tkeep = "1111"
          report "FRQ1 packetizer emitted partial TKEEP"
          severity failure;
        if observed_count < FREQUENCY_10S_FRAME_WORDS then
          observed_words(observed_count) <= frame_tdata;
          observed_last(observed_count) <= frame_tlast;
          observed_count <= observed_count + 1;
        end if;
      end if;
    end if;
  end process;

  stimulus : process
    variable frame_data_v : std_logic_vector(
      METER_CONVERTED_FRAME_BITS - 1 downto 0);
    variable frame_user_v : std_logic_vector(383 downto 0);
    variable sample_microvolts : integer;
    variable crc : std_logic_vector(31 downto 0);
    variable crossing_count_v : natural;
    variable crossing_bits_v : std_logic_vector(63 downto 0);
    variable crossing_v : signed(63 downto 0);
    variable previous_crossing_v : signed(63 downto 0);
    variable interval_q16 : signed(63 downto 0);
    variable first_crossing_v : signed(63 downto 0);
    variable last_crossing_v : signed(63 downto 0);
    variable included_crossings : natural;
    variable has_before : boolean;
    variable has_after : boolean;
    variable has_exact_start : boolean;
    variable has_exact_end : boolean;
    variable guard_flags : std_logic_vector(31 downto 0);
  begin
    wait for 8 * C_CLOCK_PERIOD;
    wait until falling_edge(aclk);
    aresetn <= '1';
    measured_frame_rate_valid <= '1';
    wait for 8 * C_CLOCK_PERIOD;

    -- Remove the expected rate-valid startup discontinuity from the counters
    -- before presenting the first measurement interval.
    wait until falling_edge(aclk);
    clear_stats <= '1';
    wait until falling_edge(aclk);
    clear_stats <= '0';

    boundary.start_sample <= std_logic_vector(
      to_unsigned(C_INTERVAL_START, 64));
    boundary.end_sample <= std_logic_vector(to_unsigned(C_INTERVAL_END, 64));
    boundary.utc_start_nanoseconds <= x"00000004A817C800";
    boundary.utc_end_nanoseconds <= x"00000006FC23AC00";
    boundary.utc_uncertainty_nanoseconds <= std_logic_vector(
      to_unsigned(100000, 64));
    boundary.measured_sample_rate_millihz <= std_logic_vector(
      to_unsigned(C_SAMPLE_RATE_HZ * 1000, 32));
    boundary.boundary_generation <= x"00000009";
    boundary.profile <= x"01010632";
    boundary.control <= x"00000003";
    wait until falling_edge(aclk);
    boundary_update <= not boundary_update;

    for sample_index in 0 to C_DRIVE_LAST_SAMPLE loop
      frame_data_v := (others => '0');
      frame_user_v := (others => '0');
      if (sample_index mod C_WAVE_PERIOD_SAMPLES) <
         C_WAVE_PERIOD_SAMPLES / 2 then
        sample_microvolts := 100000000;
      else
        sample_microvolts := -100000000;
      end if;
      frame_data_v(
        FREQUENCY_10S_REFERENCE_CHANNEL * METER_CONVERTED_LANE_BITS + 47
        downto FREQUENCY_10S_REFERENCE_CHANNEL *
          METER_CONVERTED_LANE_BITS + 16) :=
        std_logic_vector(to_signed(sample_microvolts, 32));
      frame_user_v(TUSER_SAMPLE_INDEX_LOW_MSB downto
        TUSER_SAMPLE_INDEX_LOW_LSB) := std_logic_vector(
          to_unsigned(sample_index, 32));
      frame_user_v(63 downto 32) := config_generation;
      frame_user_v(64 + FREQUENCY_10S_REFERENCE_CHANNEL) := '1';
      frame_user_v(TUSER_SAMPLE_INDEX_HIGH_MSB downto
        TUSER_SAMPLE_INDEX_HIGH_LSB) := (others => '0');

      wait until falling_edge(aclk);
      frame_data <= frame_data_v;
      frame_user <= frame_user_v;
      frame_accept <= '1';
      wait until falling_edge(aclk);
      frame_accept <= '0';
      for idle_cycle in 1 to 5 loop
        wait until rising_edge(aclk);
      end loop;
    end loop;

    for timeout_cycle in 0 to 20000 loop
      exit when observed_count = FREQUENCY_10S_FRAME_WORDS;
      wait until rising_edge(aclk);
    end loop;
    assert observed_count = FREQUENCY_10S_FRAME_WORDS
      report "timed out waiting for complete FRQ1 frame"
      severity failure;
    wait until rising_edge(aclk);

    assert observed_words(0) = FREQUENCY_10S_MAGIC and
           observed_words(1) = FREQUENCY_10S_CONTRACT_REVISION and
           unsigned(observed_words(2)) = FREQUENCY_10S_PAYLOAD_WORDS and
           observed_words(3) = x"00000000" and
           observed_words(4) = x"00000000"
      report "FRQ1 fixed header or sequence mirror is incorrect"
      severity failure;
    assert observed_words(5) = config_generation and
           unsigned(observed_words(6)) = C_SAMPLE_RATE_HZ and
           unsigned(observed_words(7)) = C_SAMPLE_RATE_HZ * 1000 and
           unsigned(observed_words(8)) = 50 and
           observed_words(9) = x"00010106"
      report "FRQ1 configuration/profile metadata is incorrect"
      severity failure;
    assert (observed_words(10) and C_REQUIRED_STATUS) = C_REQUIRED_STATUS and
           observed_words(11) = x"00000000"
      report "valid FRQ1 interval carried an unexpected status/reason"
      severity failure;
    assert unsigned(observed_words(12)) = C_INTERVAL_START and
           observed_words(13) = x"00000000" and
           unsigned(observed_words(14)) = C_INTERVAL_END and
           observed_words(15) = x"00000000" and
           unsigned(observed_words(22)) = 9
      report "FRQ1 sample-boundary metadata is incorrect"
      severity failure;

    crossing_count_v := to_integer(unsigned(observed_words(23)));
    assert crossing_count_v >= 500 and crossing_count_v <= 503
      report "FRQ1 crossing count is outside the expected 50 Hz bound"
      severity failure;
    guard_flags := observed_words(25);
    interval_q16 := shift_left(to_signed(C_INTERVAL_SAMPLES, 64), 16);
    included_crossings := 0;
    has_before := false;
    has_after := false;
    has_exact_start := false;
    has_exact_end := false;
    first_crossing_v := (others => '0');
    last_crossing_v := (others => '0');
    for crossing_index in 0 to crossing_count_v - 1 loop
      crossing_bits_v(31 downto 0) :=
        observed_words(28 + crossing_index * 2);
      crossing_bits_v(63 downto 32) :=
        observed_words(28 + crossing_index * 2 + 1);
      crossing_v := signed(crossing_bits_v);
      if crossing_index /= 0 then
        assert crossing_v > previous_crossing_v
          report "FRQ1 crossings are not strictly ordered"
          severity failure;
      end if;
      if crossing_v < 0 then
        has_before := true;
      elsif crossing_v > interval_q16 then
        has_after := true;
      else
        if included_crossings = 0 then
          first_crossing_v := crossing_v;
        end if;
        last_crossing_v := crossing_v;
        included_crossings := included_crossings + 1;
      end if;
      if crossing_v = 0 then
        has_exact_start := true;
      elsif crossing_v = interval_q16 then
        has_exact_end := true;
      end if;
      previous_crossing_v := crossing_v;
    end loop;
    assert included_crossings >= 499 and
           last_crossing_v > first_crossing_v
      report "FRQ1 did not retain the complete in-interval cycle set"
      severity failure;
    assert has_before =
             (guard_flags(FREQUENCY_10S_GUARD_BEFORE_START_BIT) = '1') and
           has_after =
             (guard_flags(FREQUENCY_10S_GUARD_AFTER_END_BIT) = '1') and
           has_exact_start =
             (guard_flags(FREQUENCY_10S_GUARD_EXACT_START_BIT) = '1') and
           has_exact_end =
             (guard_flags(FREQUENCY_10S_GUARD_EXACT_END_BIT) = '1')
      report "FRQ1 guard flags do not match the crossing geometry"
      severity failure;

    for crossing_index in crossing_count_v to
        FREQUENCY_10S_CROSSING_CAPACITY - 1 loop
      assert observed_words(28 + crossing_index * 2) = x"00000000" and
             observed_words(28 + crossing_index * 2 + 1) = x"00000000"
        report "FRQ1 unused crossing capacity is not zero padded"
        severity failure;
    end loop;

    crc := R5_AGG_CRC_INITIAL;
    for word_index in 0 to FREQUENCY_10S_FRAME_WORDS - 2 loop
      crc := crc32c_update_word(crc, observed_words(word_index));
      assert observed_last(word_index) = '0'
        report "FRQ1 asserted TLAST before its CRC"
        severity failure;
    end loop;
    assert observed_words(FREQUENCY_10S_FRAME_WORDS - 1) = not crc and
           observed_last(FREQUENCY_10S_FRAME_WORDS - 1) = '1'
      report "FRQ1 CRC32C or final TLAST is incorrect"
      severity failure;
    assert completed_count = x"00000001" and
           dropped_count = x"00000000" and
           overflow_count = x"00000000" and
           discontinuity_count = x"00000000" and
           accepted_packets = x"00000001" and
           packetizer_drops = x"00000000" and
           transmitted_packets = x"00000001" and
           framing_errors = x"00000000"
      report "FRQ1 observer/transport counters are incorrect"
      severity failure;

    report "PASS: meter_frequency_10s_transport_tb" severity note;
    std.env.finish;
    wait;
  end process;
end architecture;
