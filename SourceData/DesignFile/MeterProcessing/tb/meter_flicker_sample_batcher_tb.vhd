library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.metering_pkg.all;
use work.meter_r5_power_quality_protocol_pkg.all;

entity meter_flicker_sample_batcher_tb is
end entity;

architecture simulation of meter_flicker_sample_batcher_tb is
  constant CLOCK_PERIOD : time := 10 ns;
  constant PACKETS      : positive := 2;

  type word_array_t is array (0 to PACKETS * R5_FLK_PAYLOAD_WORDS - 1) of
    std_logic_vector(31 downto 0);
  type bit_array_t is array (0 to PACKETS * R5_FLK_PAYLOAD_WORDS - 1) of
    std_logic;

  signal clock       : std_logic := '0';
  signal resetn      : std_logic := '0';
  signal frame_accept: std_logic := '0';
  signal frame_data  : std_logic_vector(METER_CONVERTED_FRAME_BITS - 1
    downto 0) := (others => '0');
  signal frame_keep  : std_logic_vector(METER_CONVERTED_KEEP_BITS - 1
    downto 0) := (others => '1');
  signal frame_user  : std_logic_vector(383 downto 0) := (others => '0');
  signal config_words  : m18_config_words_t := (others => (others => '0'));
  signal output_data : std_logic_vector(31 downto 0);
  signal output_keep : std_logic_vector(3 downto 0);
  signal output_valid: std_logic;
  signal output_last : std_logic;
  signal drop_count  : std_logic_vector(31 downto 0);
  signal observed      : word_array_t := (others => (others => '0'));
  signal observed_last : bit_array_t := (others => '0');
  signal observed_count: natural range 0 to PACKETS * R5_FLK_PAYLOAD_WORDS := 0;

  function lane_value(value : integer) return unsigned is
  begin
    return unsigned(to_signed(value, METER_CONVERTED_LANE_BITS));
  end function;

  function packed_word(value_a : integer; value_b : integer;
                       value_c : integer; word : natural)
    return std_logic_vector is
    variable a : unsigned(47 downto 0) := lane_value(value_a);
    variable b : unsigned(47 downto 0) := lane_value(value_b);
    variable c : unsigned(47 downto 0) := lane_value(value_c);
    variable result : std_logic_vector(31 downto 0);
  begin
    case word is
      when 0 => result := std_logic_vector(a(31 downto 0));
      when 1 => result := std_logic_vector(b(15 downto 0)) &
                          std_logic_vector(a(47 downto 32));
      when 2 => result := std_logic_vector(b(47 downto 16));
      when 3 => result := std_logic_vector(c(31 downto 0));
      when others =>
        result := x"00" & x"17" & std_logic_vector(c(47 downto 32));
    end case;
    return result;
  end function;
begin
  clock <= not clock after CLOCK_PERIOD / 2;

  watchdog : process
  begin
    wait for 200 us;
    assert false
      report "Flicker batcher timeout at observed word " &
        integer'image(observed_count)
      severity failure;
    wait;
  end process;

  dut : entity work.meter_flicker_sample_batcher
    port map (
      aclk => clock,
      aresetn => resetn,
      frame_accept_i => frame_accept,
      frame_data_i => frame_data,
      frame_keep_i => frame_keep,
      frame_user_i => frame_user,
      cycle_locked_i => '1',
      cycle_fallback_i => '0',
      nominal_hz_i => std_logic_vector(to_unsigned(60, 8)),
      shadow_sample_rate_i => std_logic_vector(to_unsigned(128000, 32)),
      m18_shadow_words_i => config_words,
      config_apply_toggle_i => '1',
      m_axis_flk_tdata => output_data,
      m_axis_flk_tkeep => output_keep,
      m_axis_flk_tvalid => output_valid,
      m_axis_flk_tready => '1',
      m_axis_flk_tlast => output_last,
      drop_count_o => drop_count);

  capture : process (clock)
  begin
    if rising_edge(clock) then
      if resetn = '0' then
        observed_count <= 0;
      elsif output_valid = '1' then
        assert output_keep = x"F"
          report "Flicker batcher emitted partial TKEEP" severity failure;
        assert observed_count < observed'length
          report "Flicker batcher emitted extra payload data" severity failure;
        observed(observed_count) <= output_data;
        observed_last(observed_count) <= output_last;
        observed_count <= observed_count + 1;
      end if;
    end if;
  end process;

  stimulus : process
    procedure send_frame(index : natural; value_a : integer;
                         value_b : integer; value_c : integer) is
      variable data_value : std_logic_vector(METER_CONVERTED_FRAME_BITS - 1
        downto 0) := (others => '0');
      variable user_value : std_logic_vector(383 downto 0) := (others => '0');
    begin
      data_value((METER_LANE_VA + 1) * METER_CONVERTED_LANE_BITS - 1 downto
        METER_LANE_VA * METER_CONVERTED_LANE_BITS) :=
          std_logic_vector(lane_value(value_a));
      data_value((METER_LANE_VB + 1) * METER_CONVERTED_LANE_BITS - 1 downto
        METER_LANE_VB * METER_CONVERTED_LANE_BITS) :=
          std_logic_vector(lane_value(value_b));
      data_value((METER_LANE_VC + 1) * METER_CONVERTED_LANE_BITS - 1 downto
        METER_LANE_VC * METER_CONVERTED_LANE_BITS) :=
          std_logic_vector(lane_value(value_c));
      user_value(31 downto 0) := std_logic_vector(to_unsigned(index, 32));
      user_value(105 downto 74) := (others => '0');
      user_value(64 + METER_LANE_VA) := '1';
      user_value(64 + METER_LANE_VB) := '1';
      user_value(64 + METER_LANE_VC) := '1';
      wait until falling_edge(clock);
      frame_data <= data_value;
      frame_user <= user_value;
      frame_accept <= '1';
      wait until rising_edge(clock);
      wait until falling_edge(clock);
      frame_accept <= '0';
      for idle_cycle in 1 to 18 loop
        wait until rising_edge(clock);
      end loop;
    end procedure;

    procedure check_sample(packet_base : natural; sample : natural;
                           value_a : integer; value_b : integer;
                           value_c : integer) is
      variable base : natural;
    begin
      base := packet_base + R5_FLK_SAMPLE_BASE_WORD +
        sample * R5_FLK_WORDS_PER_FRAME;
      for word in 0 to R5_FLK_WORDS_PER_FRAME - 1 loop
        assert observed(base + word) =
          packed_word(value_a, value_b, value_c, word)
          report "Flicker packed voltage word mismatch" severity failure;
      end loop;
    end procedure;

    constant SECOND_PACKET : natural := R5_FLK_PAYLOAD_WORDS;
  begin
    config_words(M18_CONFIG_GENERATION_WORD) <=
      std_logic_vector(to_unsigned(7, 32));
    config_words(M18_CONFIG_REFERENCE_VOLTAGE_WORD) <=
      std_logic_vector(to_unsigned(120000000, 32));
    config_words(M18_CONFIG_FLICKER_FLAGS_WORD)(M18_ENGINE_ENABLED_BIT) <= '1';
    config_words(M18_CONFIG_FLICKER_PHASE_MASK_WORD) <= x"00000007";
    config_words(M18_CONFIG_FLICKER_LAMP_WORD) <=
      std_logic_vector(to_unsigned(120, 32));
    config_words(M18_CONFIG_FLICKER_LIVE_MS_WORD) <=
      std_logic_vector(to_unsigned(1000, 32));
    config_words(M18_CONFIG_FLICKER_PST_SECONDS_WORD) <=
      std_logic_vector(to_unsigned(600, 32));

    wait for 8 * CLOCK_PERIOD;
    wait until falling_edge(clock);
    resetn <= '1';

    for sample in 0 to R5_FLK_BATCH_FRAMES - 1 loop
      send_frame(1000 + sample, 100000 + sample, -200000 - sample,
                 300000 + sample);
    end loop;
    if observed_count /= R5_FLK_PAYLOAD_WORDS then
      wait until observed_count = R5_FLK_PAYLOAD_WORDS;
    end if;
    wait until rising_edge(clock);

    assert observed(R5_FLK_SEQUENCE_WORD) = x"00000001"
      report "first Flicker batch sequence mismatch" severity failure;
    assert observed(R5_FLK_GENERATION_WORD) = x"00000007"
      report "Flicker generation mismatch" severity failure;
    assert observed(R5_FLK_SAMPLE_RATE_WORD) =
      std_logic_vector(to_unsigned(128000, 32))
      report "Flicker sample rate mismatch" severity failure;
    assert observed(R5_FLK_FRAME_CAPACITY_WORD) = x"00000100"
      report "Flicker frame capacity mismatch" severity failure;
    assert observed(R5_FLK_PHASE_MASK_WORD) = x"00000007"
      report "Flicker phase mask mismatch" severity failure;
    assert observed(R5_FLK_MODEL_WORD) = x"003C0078"
      report "Flicker lamp/nominal model mismatch" severity failure;
    assert observed(R5_FLK_TIMING_WORD) = x"025803E8"
      report "Flicker timing mismatch" severity failure;
    assert observed(R5_FLK_FIRST_SAMPLE_LOW_WORD) =
      std_logic_vector(to_unsigned(1000, 32))
      report "Flicker first sample mismatch" severity failure;
    check_sample(0, 0, 100000, -200000, 300000);
    check_sample(0, 255, 100255, -200255, 300255);
    assert observed(R5_FLK_ACTUAL_COUNT_WORD) = x"00000100"
      report "complete Flicker batch count mismatch" severity failure;
    assert observed(R5_FLK_BATCH_STATUS_WORD) = x"00000001"
      report "first Flicker batch must report only initial discontinuity"
      severity failure;
    assert observed(R5_FLK_LAST_SAMPLE_LOW_WORD) =
      std_logic_vector(to_unsigned(1255, 32))
      report "complete Flicker batch last sample mismatch" severity failure;
    assert observed_last(R5_FLK_LAST_SAMPLE_HIGH_WORD) = '1'
      report "complete Flicker batch TLAST mismatch" severity failure;
    assert drop_count = x"00000000"
      report "complete Flicker batch incorrectly counted a drop"
      severity failure;

    for sample in 0 to 9 loop
      send_frame(2000 + sample, 400000 + sample, -500000 - sample,
                 600000 + sample);
    end loop;
    send_frame(3000, 700000, -800000, 900000);
    if observed_count /= PACKETS * R5_FLK_PAYLOAD_WORDS then
      wait until observed_count = PACKETS * R5_FLK_PAYLOAD_WORDS;
    end if;
    wait until rising_edge(clock);

    check_sample(SECOND_PACKET, 0, 400000, -500000, 600000);
    check_sample(SECOND_PACKET, 9, 400009, -500009, 600009);
    assert observed(SECOND_PACKET + R5_FLK_SAMPLE_BASE_WORD +
      10 * R5_FLK_WORDS_PER_FRAME) = x"00000000"
      report "aborted Flicker batch was not zero padded" severity failure;
    assert observed(SECOND_PACKET + R5_FLK_ACTUAL_COUNT_WORD) = x"0000000A"
      report "aborted Flicker batch count mismatch" severity failure;
    assert observed(SECOND_PACKET + R5_FLK_BATCH_STATUS_WORD) = x"00000003"
      report "aborted Flicker batch lacks discontinuity/drop status"
      severity failure;
    assert observed(SECOND_PACKET + R5_FLK_LAST_SAMPLE_LOW_WORD) =
      std_logic_vector(to_unsigned(2009, 32))
      report "aborted Flicker batch last sample mismatch" severity failure;
    assert observed_last(SECOND_PACKET + R5_FLK_LAST_SAMPLE_HIGH_WORD) = '1'
      report "aborted Flicker batch TLAST mismatch" severity failure;
    assert drop_count = x"00000001"
      report "aborted Flicker batch drop count mismatch" severity failure;

    report "PASS: meter_flicker_sample_batcher_tb" severity note;
    std.env.finish;
  end process;
end architecture;
