library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.metering_pkg.all;
use work.meter_r5_power_quality_protocol_pkg.all;

-- Nonblocking raw-voltage observer shared by the R5C1 flicker and mains-
-- signalling engines. Converted A/B/C Q16 values are reduced to signed integer
-- microvolts and packed into fixed 256-frame VSB1 payloads. The observer never
-- owns the acquisition ready path; any local loss is counted and marks both
-- the current and next batch as discontinuous.
entity meter_voltage_sample_batcher is
  port (
    aclk    : in std_logic;
    aresetn : in std_logic;

    frame_accept_i : in std_logic;
    frame_data_i   : in std_logic_vector(METER_CONVERTED_FRAME_BITS - 1 downto 0);
    frame_keep_i   : in std_logic_vector(METER_CONVERTED_KEEP_BITS - 1 downto 0);
    frame_user_i   : in std_logic_vector(383 downto 0);

    cycle_locked_i        : in std_logic;
    cycle_fallback_i      : in std_logic;
    nominal_hz_i          : in std_logic_vector(7 downto 0);
    shadow_sample_rate_i  : in std_logic_vector(31 downto 0);
    m18_shadow_words_i    : in m18_config_words_t;
    config_apply_toggle_i : in std_logic;

    m_axis_vsb_tdata  : out std_logic_vector(31 downto 0);
    m_axis_vsb_tkeep  : out std_logic_vector(3 downto 0);
    m_axis_vsb_tvalid : out std_logic;
    m_axis_vsb_tready : in std_logic;
    m_axis_vsb_tlast  : out std_logic;

    drop_count_o : out std_logic_vector(31 downto 0)
  );
end entity;

architecture rtl of meter_voltage_sample_batcher is
  type output_state_t is (OUTPUT_IDLE, OUTPUT_METADATA, OUTPUT_SAMPLE,
                          OUTPUT_WAIT_FRAME, OUTPUT_PAD, OUTPUT_TRAILER);

  signal output_state  : output_state_t := OUTPUT_IDLE;
  signal metadata_word : natural range 0 to R5_VSB_SAMPLE_BASE_WORD - 1 := 0;
  signal sample_word   : natural range 0 to R5_VSB_WORDS_PER_FRAME - 1 := 0;
  signal trailer_word  : natural range 0 to 3 := 0;
  signal sample_count  : natural range 0 to R5_VSB_BATCH_FRAMES := 0;
  signal pad_remaining : natural range 0 to
    R5_VSB_BATCH_FRAMES * R5_VSB_WORDS_PER_FRAME := 0;

  signal packet_sequence : unsigned(31 downto 0) := (others => '0');
  signal first_sample     : unsigned(63 downto 0) := (others => '0');
  signal last_sample      : unsigned(63 downto 0) := (others => '0');
  signal sample_index     : unsigned(63 downto 0) := (others => '0');
  signal batch_status     : std_logic_vector(31 downto 0) := (others => '0');
  signal pending_discontinuity : std_logic := '1';
  signal pending_source_drop   : std_logic := '0';

  signal sample_va    : std_logic_vector(31 downto 0) := (others => '0');
  signal sample_vb    : std_logic_vector(31 downto 0) := (others => '0');
  signal sample_vc    : std_logic_vector(31 downto 0) := (others => '0');
  signal sample_flags : std_logic_vector(7 downto 0) := (others => '0');

  signal snapshot_apply       : std_logic := '0';
  signal snapshot_generation  : std_logic_vector(31 downto 0) := (others => '0');
  signal snapshot_sample_rate : std_logic_vector(31 downto 0) := (others => '0');
  signal snapshot_phase_mask  : std_logic_vector(31 downto 0) := (others => '0');
  signal snapshot_lamp        : std_logic_vector(15 downto 0) := (others => '0');
  signal snapshot_nominal_hz  : std_logic_vector(7 downto 0) := (others => '0');
  signal snapshot_live_ms     : std_logic_vector(31 downto 0) := (others => '0');
  signal snapshot_pst_seconds : std_logic_vector(31 downto 0) := (others => '0');
  signal snapshot_reference_uv: std_logic_vector(31 downto 0) := (others => '0');

  signal output_data   : std_logic_vector(31 downto 0);
  signal output_valid  : std_logic;
  signal output_last   : std_logic;
  signal output_accept : std_logic;
  signal drop_count    : unsigned(31 downto 0) := (others => '0');
begin
  assert R5_VSB_ACTUAL_COUNT_WORD = R5_VSB_SAMPLE_BASE_WORD +
      R5_VSB_BATCH_FRAMES * R5_VSB_WORDS_PER_FRAME
    report "VSB1 sample geometry does not reach the trailer"
    severity failure;
  assert R5_VSB_PAYLOAD_WORDS = R5_VSB_LAST_SAMPLE_HIGH_WORD + 1
    report "VSB1 trailer does not fill the payload"
    severity failure;

  process (all)
  begin
    output_data <= (others => '0');
    output_valid <= '0';
    output_last <= '0';
    case output_state is
      when OUTPUT_METADATA =>
        output_valid <= '1';
        case metadata_word is
          when R5_VSB_SEQUENCE_WORD =>
            output_data <= std_logic_vector(packet_sequence);
          when R5_VSB_GENERATION_WORD =>
            output_data <= snapshot_generation;
          when R5_VSB_SAMPLE_RATE_WORD =>
            output_data <= snapshot_sample_rate;
          when R5_VSB_FRAME_CAPACITY_WORD =>
            output_data <= std_logic_vector(to_unsigned(
              R5_VSB_BATCH_FRAMES, output_data'length));
          when R5_VSB_PHASE_MASK_WORD =>
            output_data <= snapshot_phase_mask;
          when R5_VSB_MODEL_WORD =>
            output_data <= x"00" & snapshot_nominal_hz & snapshot_lamp;
          when R5_VSB_TIMING_WORD =>
            output_data <= snapshot_pst_seconds(15 downto 0) &
                           snapshot_live_ms(15 downto 0);
          when R5_VSB_REFERENCE_UV_WORD =>
            output_data <= snapshot_reference_uv;
          when R5_VSB_FIRST_SAMPLE_LOW_WORD =>
            output_data <= std_logic_vector(first_sample(31 downto 0));
          when others =>
            output_data <= std_logic_vector(first_sample(63 downto 32));
        end case;
      when OUTPUT_SAMPLE =>
        output_valid <= '1';
        case sample_word is
          when 0 => output_data <= sample_va;
          when 1 => output_data <= sample_vb;
          when 2 => output_data <= sample_vc;
          when others => output_data <= x"000000" & sample_flags;
        end case;
      when OUTPUT_PAD =>
        output_valid <= '1';
      when OUTPUT_TRAILER =>
        output_valid <= '1';
        case trailer_word is
          when 0 =>
            output_data <= std_logic_vector(to_unsigned(
              sample_count, output_data'length));
          when 1 => output_data <= batch_status;
          when 2 => output_data <= std_logic_vector(last_sample(31 downto 0));
          when others =>
            output_data <= std_logic_vector(last_sample(63 downto 32));
            output_last <= '1';
        end case;
      when others =>
        null;
    end case;
  end process;

  output_accept <= output_valid and m_axis_vsb_tready;
  m_axis_vsb_tdata <= output_data;
  m_axis_vsb_tkeep <= (others => '1');
  m_axis_vsb_tvalid <= output_valid;
  m_axis_vsb_tlast <= output_last;
  drop_count_o <= std_logic_vector(drop_count);

  process (aclk)
    variable incoming_index : unsigned(63 downto 0);
    variable flags          : std_logic_vector(7 downto 0);
    variable configuration_matches : boolean;
  begin
    if rising_edge(aclk) then
      if aresetn = '0' then
        output_state <= OUTPUT_IDLE;
        metadata_word <= 0;
        sample_word <= 0;
        trailer_word <= 0;
        sample_count <= 0;
        pad_remaining <= 0;
        packet_sequence <= (others => '0');
        first_sample <= (others => '0');
        last_sample <= (others => '0');
        sample_index <= (others => '0');
        batch_status <= (others => '0');
        pending_discontinuity <= '1';
        pending_source_drop <= '0';
        drop_count <= (others => '0');
      else
        if output_accept = '1' then
          case output_state is
            when OUTPUT_METADATA =>
              if metadata_word = R5_VSB_SAMPLE_BASE_WORD - 1 then
                metadata_word <= 0;
                sample_word <= 0;
                output_state <= OUTPUT_SAMPLE;
              else
                metadata_word <= metadata_word + 1;
              end if;
            when OUTPUT_SAMPLE =>
              if sample_word = R5_VSB_WORDS_PER_FRAME - 1 then
                sample_word <= 0;
                last_sample <= sample_index;
                sample_count <= sample_count + 1;
                if sample_count = R5_VSB_BATCH_FRAMES - 1 then
                  trailer_word <= 0;
                  output_state <= OUTPUT_TRAILER;
                else
                  output_state <= OUTPUT_WAIT_FRAME;
                end if;
              else
                sample_word <= sample_word + 1;
              end if;
            when OUTPUT_PAD =>
              if pad_remaining = 1 then
                pad_remaining <= 0;
                trailer_word <= 0;
                output_state <= OUTPUT_TRAILER;
              else
                pad_remaining <= pad_remaining - 1;
              end if;
            when OUTPUT_TRAILER =>
              if trailer_word = 3 then
                trailer_word <= 0;
                sample_count <= 0;
                batch_status <= (others => '0');
                output_state <= OUTPUT_IDLE;
              else
                trailer_word <= trailer_word + 1;
              end if;
            when others =>
              null;
          end case;
        end if;

        if frame_accept_i = '1' then
          incoming_index := unsigned(frame_user_i(105 downto 74)) &
                            unsigned(frame_user_i(31 downto 0));
          flags := (others => '0');
          flags(R5_VSB_SAMPLE_VALID_A_BIT) := frame_user_i(64 + METER_LANE_VA);
          flags(R5_VSB_SAMPLE_VALID_B_BIT) := frame_user_i(64 + METER_LANE_VB);
          flags(R5_VSB_SAMPLE_VALID_C_BIT) := frame_user_i(64 + METER_LANE_VC);
          if frame_keep_i /= (frame_keep_i'range => '1') then
            flags(R5_VSB_SAMPLE_MALFORMED_BIT) := '1';
          end if;
          flags(R5_VSB_SAMPLE_LOCKED_BIT) := cycle_locked_i;
          flags(R5_VSB_SAMPLE_FALLBACK_BIT) := cycle_fallback_i;
          flags(R5_VSB_SAMPLE_SATURATED_BIT) := frame_user_i(72);

          if output_state = OUTPUT_IDLE and
              (m18_shadow_words_i(M18_CONFIG_FLICKER_FLAGS_WORD)
                 (M18_ENGINE_ENABLED_BIT) = '1' or
               m18_shadow_words_i(M18_CONFIG_MAINS_FLAGS_WORD)
                 (M18_ENGINE_ENABLED_BIT) = '1') then
            packet_sequence <= packet_sequence + 1;
            first_sample <= incoming_index;
            last_sample <= incoming_index;
            sample_index <= incoming_index;
            sample_count <= 0;
            metadata_word <= 0;
            sample_word <= 0;
            sample_va <= frame_data_i(
              METER_LANE_VA * METER_CONVERTED_LANE_BITS + 47 downto
              METER_LANE_VA * METER_CONVERTED_LANE_BITS + 16);
            sample_vb <= frame_data_i(
              METER_LANE_VB * METER_CONVERTED_LANE_BITS + 47 downto
              METER_LANE_VB * METER_CONVERTED_LANE_BITS + 16);
            sample_vc <= frame_data_i(
              METER_LANE_VC * METER_CONVERTED_LANE_BITS + 47 downto
              METER_LANE_VC * METER_CONVERTED_LANE_BITS + 16);
            sample_flags <= flags;
            snapshot_apply <= config_apply_toggle_i;
            snapshot_generation <=
              m18_shadow_words_i(M18_CONFIG_GENERATION_WORD);
            snapshot_sample_rate <= shadow_sample_rate_i;
            snapshot_phase_mask <=
              m18_shadow_words_i(M18_CONFIG_FLICKER_PHASE_MASK_WORD) or
              m18_shadow_words_i(M18_CONFIG_MAINS_PHASE_MASK_WORD);
            snapshot_lamp <=
              m18_shadow_words_i(M18_CONFIG_FLICKER_LAMP_WORD)(15 downto 0);
            snapshot_nominal_hz <= nominal_hz_i;
            snapshot_live_ms <=
              m18_shadow_words_i(M18_CONFIG_FLICKER_LIVE_MS_WORD);
            snapshot_pst_seconds <=
              m18_shadow_words_i(M18_CONFIG_FLICKER_PST_SECONDS_WORD);
            snapshot_reference_uv <=
              m18_shadow_words_i(M18_CONFIG_REFERENCE_VOLTAGE_WORD);
            batch_status <= (others => '0');
            if pending_discontinuity = '1' then
              batch_status(R5_VSB_BATCH_DISCONTINUITY_BIT) <= '1';
            end if;
            if pending_source_drop = '1' then
              batch_status(R5_VSB_BATCH_SOURCE_DROP_BIT) <= '1';
            end if;
            pending_discontinuity <= '0';
            pending_source_drop <= '0';
            output_state <= OUTPUT_METADATA;
          elsif output_state = OUTPUT_WAIT_FRAME then
            configuration_matches :=
              config_apply_toggle_i = snapshot_apply and
              (m18_shadow_words_i(M18_CONFIG_FLICKER_FLAGS_WORD)
                 (M18_ENGINE_ENABLED_BIT) = '1' or
               m18_shadow_words_i(M18_CONFIG_MAINS_FLAGS_WORD)
                 (M18_ENGINE_ENABLED_BIT) = '1') and
              m18_shadow_words_i(M18_CONFIG_GENERATION_WORD) =
                snapshot_generation and
              shadow_sample_rate_i = snapshot_sample_rate and
              (m18_shadow_words_i(M18_CONFIG_FLICKER_PHASE_MASK_WORD) or
               m18_shadow_words_i(M18_CONFIG_MAINS_PHASE_MASK_WORD)) =
                snapshot_phase_mask and
              m18_shadow_words_i(M18_CONFIG_FLICKER_LAMP_WORD)(15 downto 0) =
                snapshot_lamp and
              nominal_hz_i = snapshot_nominal_hz and
              m18_shadow_words_i(M18_CONFIG_FLICKER_LIVE_MS_WORD) =
                snapshot_live_ms and
              m18_shadow_words_i(M18_CONFIG_FLICKER_PST_SECONDS_WORD) =
                snapshot_pst_seconds and
              m18_shadow_words_i(M18_CONFIG_REFERENCE_VOLTAGE_WORD) =
                snapshot_reference_uv;
            if configuration_matches and incoming_index = last_sample + 1 then
              sample_index <= incoming_index;
              sample_va <= frame_data_i(
                METER_LANE_VA * METER_CONVERTED_LANE_BITS + 47 downto
                METER_LANE_VA * METER_CONVERTED_LANE_BITS + 16);
              sample_vb <= frame_data_i(
                METER_LANE_VB * METER_CONVERTED_LANE_BITS + 47 downto
                METER_LANE_VB * METER_CONVERTED_LANE_BITS + 16);
              sample_vc <= frame_data_i(
                METER_LANE_VC * METER_CONVERTED_LANE_BITS + 47 downto
                METER_LANE_VC * METER_CONVERTED_LANE_BITS + 16);
              sample_flags <= flags;
              sample_word <= 0;
              output_state <= OUTPUT_SAMPLE;
            else
              if drop_count /= (drop_count'range => '1') then
                drop_count <= drop_count + 1;
              end if;
              batch_status(R5_VSB_BATCH_DISCONTINUITY_BIT) <= '1';
              batch_status(R5_VSB_BATCH_SOURCE_DROP_BIT) <= '1';
              pending_discontinuity <= '1';
              pending_source_drop <= '1';
              pad_remaining <=
                (R5_VSB_BATCH_FRAMES - sample_count) *
                R5_VSB_WORDS_PER_FRAME;
              output_state <= OUTPUT_PAD;
            end if;
          elsif output_state = OUTPUT_IDLE then
            -- A disabled observer is intentionally idle, not losing data.
            pending_discontinuity <= '1';
          else
            if drop_count /= (drop_count'range => '1') then
              drop_count <= drop_count + 1;
            end if;
            if output_state /= OUTPUT_IDLE then
              batch_status(R5_VSB_BATCH_DISCONTINUITY_BIT) <= '1';
              batch_status(R5_VSB_BATCH_SOURCE_DROP_BIT) <= '1';
            end if;
            pending_discontinuity <= '1';
            pending_source_drop <= '1';
          end if;
        end if;
      end if;
    end if;
  end process;
end architecture;
