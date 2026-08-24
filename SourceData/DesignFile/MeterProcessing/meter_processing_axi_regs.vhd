library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.meter_frequency_pkg.all;
use work.grid_timing_pkg.all;
use work.pq_event_pkg.all;
use work.measurement_record_bus_pkg.all;
use work.metering_pkg.all;

entity meter_processing_axi_regs is
  port (
    aclk                    : in  std_logic;
    aresetn                 : in  std_logic;

    s_axi_awaddr            : in  std_logic_vector(7 downto 0);
    s_axi_awvalid           : in  std_logic;
    s_axi_awready           : out std_logic;
    s_axi_wdata             : in  word32_t;
    s_axi_wstrb             : in  std_logic_vector(3 downto 0);
    s_axi_wvalid            : in  std_logic;
    s_axi_wready            : out std_logic;
    s_axi_bresp             : out std_logic_vector(1 downto 0);
    s_axi_bvalid            : out std_logic;
    s_axi_bready            : in  std_logic;
    s_axi_araddr            : in  std_logic_vector(7 downto 0);
    s_axi_arvalid           : in  std_logic;
    s_axi_arready           : out std_logic;
    s_axi_rdata             : out word32_t;
    s_axi_rresp             : out std_logic_vector(1 downto 0);
    s_axi_rvalid            : out std_logic;
    s_axi_rready            : in  std_logic;

    shadow_generation_o     : out word32_t;
    shadow_sample_rate_o    : out word32_t;
    shadow_window_samples_o : out word32_t;
    shadow_valid_mask_o     : out std_logic_vector(7 downto 0);
    shadow_enable_o         : out std_logic;
    shadow_dc_remove_o      : out std_logic;
    apply_toggle_o          : out std_logic;

    frequency_shadow_control_o         : out word32_t;
    frequency_shadow_window_samples_o  : out word32_t;
    frequency_shadow_minimum_millihz_o : out word32_t;
    frequency_shadow_maximum_millihz_o : out word32_t;
    frequency_shadow_hysteresis_uv_o   : out word32_t;
    frequency_active_control_i         : in  word32_t;
    frequency_active_window_samples_i  : in  word32_t;
    frequency_active_minimum_millihz_i : in  word32_t;
    frequency_active_maximum_millihz_i : in  word32_t;
    frequency_active_hysteresis_uv_i   : in  word32_t;
    frequency_status_i                 : in  word32_t;
    frequency_millihz_i                : in  word32_t;
    frequency_period_q16_samples_i     : in  word32_t;
    frequency_measurement_sequence_i   : in  word32_t;
    frequency_rejected_count_i         : in  word32_t;

    -- Grid-cycle timing configuration. The shadow commits on the shared
    -- APPLY toggle alongside the RMS and frequency configuration.
    grid_shadow_config_o               : out word32_t;
    grid_active_config_i               : in  word32_t;
    grid_status_i                      : in  word32_t;

    -- Power-quality (Urms(1/2)) event configuration. The shadows commit
    -- on the same APPLY toggle as everything else, so one half-cycle
    -- evaluation can never straddle two configuration generations.
    pq_shadow_reference_o              : out word32_t;
    pq_shadow_threshold_o              : out word32_t;
    pq_shadow_limits_o                 : out word32_t;
    pq_status_i                        : in  word32_t;

    -- 150/180-cycle aggregation health (read-only).
    agg_status_i                       : in  word32_t;
    agg_record_count_i                 : in  word32_t;
    agg_reset_count_i                  : in  word32_t;
    agg_ineligible_count_i             : in  word32_t;
    agg_continuity_count_i             : in  word32_t;
    agg_drop_count_i                   : in  word32_t;

    -- HLS cycle-aggregator trial health (read-only; see
    -- measurement_record_bus_pkg for the register semantics).
    hls_agg_record_count_i             : in  word32_t;
    hls_agg_mismatch_count_i           : in  word32_t;
    hls_agg_drop_count_i               : in  word32_t;

    -- Exact co-release PL -> R5C1 shadow-export transport diagnostics.
    -- They remain observational and never affect capture or metrology.
    r5_agg_export_status_i             : in  word32_t;
    r5_agg_export_accepted_count_i     : in  word32_t;
    r5_agg_export_dropped_count_i      : in  word32_t;
    r5_agg_export_transmitted_count_i  : in  word32_t;
    r5_agg_export_framing_errors_i     : in  word32_t;
    r5_agg_export_last_sequence_i      : in  word32_t;
    r5_agg_export_queue_level_i        : in  word32_t;

    active_generation_i     : in  word32_t;
    result_sequence_i       : in  word32_t;
    result_drop_count_i     : in  word32_t;
    packet_drop_count_i     : in  word32_t;
    status_i                : in  word32_t
  );
end entity;

architecture rtl of meter_processing_axi_regs is
  constant VERSION_VALUE    : word32_t := x"00010000";
  constant IDENTIFIER_VALUE : word32_t := x"4D505231"; -- "MPR1"

  signal shadow_generation     : word32_t := (others => '0');
  signal shadow_sample_rate    : word32_t := std_logic_vector(to_unsigned(32000, 32));
  signal shadow_window_samples : word32_t := std_logic_vector(to_unsigned(6400, 32));
  signal shadow_valid_mask     : std_logic_vector(7 downto 0) := x"70";
  signal shadow_enable         : std_logic := '0';
  signal shadow_dc_remove      : std_logic := '1';
  -- 0x00000A63 = enabled, rolling-cycles, CH6, 10 cycles.
  signal frequency_shadow_control         : word32_t := x"00000A63";
  signal frequency_shadow_window_samples  : word32_t :=
    std_logic_vector(to_unsigned(32000, 32));
  signal frequency_shadow_minimum_millihz : word32_t :=
    std_logic_vector(to_unsigned(40000, 32));
  signal frequency_shadow_maximum_millihz : word32_t :=
    std_logic_vector(to_unsigned(70000, 32));
  signal frequency_shadow_hysteresis_uv   : word32_t :=
    std_logic_vector(to_unsigned(1000000, 32));
  signal grid_shadow_config    : word32_t := GRID_CONFIG_DEFAULT;
  signal pq_shadow_reference   : word32_t := (others => '0');
  signal pq_shadow_threshold   : word32_t := PQ_THRESHOLD_DEFAULT;
  signal pq_shadow_limits      : word32_t := PQ_LIMITS_DEFAULT;
  signal apply_toggle          : std_logic := '0';
  signal bvalid                : std_logic := '0';
  signal rvalid                : std_logic := '0';
  signal rdata                 : word32_t := (others => '0');
begin
  -- Couple the write-channel handshakes so data can never be consumed before
  -- its address. One write response remains outstanding at a time.
  s_axi_awready <= '1' when bvalid = '0' and
                            s_axi_awvalid = '1' and s_axi_wvalid = '1' else '0';
  s_axi_wready <= '1' when bvalid = '0' and
                           s_axi_awvalid = '1' and s_axi_wvalid = '1' else '0';
  s_axi_bresp <= "00";
  s_axi_bvalid <= bvalid;
  s_axi_arready <= '1' when rvalid = '0' else '0';
  s_axi_rresp <= "00";
  s_axi_rvalid <= rvalid;
  s_axi_rdata <= rdata;

  shadow_generation_o <= shadow_generation;
  shadow_sample_rate_o <= shadow_sample_rate;
  shadow_window_samples_o <= shadow_window_samples;
  shadow_valid_mask_o <= shadow_valid_mask;
  shadow_enable_o <= shadow_enable;
  shadow_dc_remove_o <= shadow_dc_remove;
  apply_toggle_o <= apply_toggle;
  frequency_shadow_control_o <= frequency_shadow_control;
  frequency_shadow_window_samples_o <= frequency_shadow_window_samples;
  frequency_shadow_minimum_millihz_o <= frequency_shadow_minimum_millihz;
  frequency_shadow_maximum_millihz_o <= frequency_shadow_maximum_millihz;
  frequency_shadow_hysteresis_uv_o <= frequency_shadow_hysteresis_uv;
  grid_shadow_config_o <= grid_shadow_config;
  pq_shadow_reference_o <= pq_shadow_reference;
  pq_shadow_threshold_o <= pq_shadow_threshold;
  pq_shadow_limits_o <= pq_shadow_limits;

  process (aclk)
    variable address_word : natural range 0 to 63;
    variable control_word : word32_t;
    variable updated_word : word32_t;
  begin
    if rising_edge(aclk) then
      if aresetn = '0' then
        shadow_generation <= (others => '0');
        shadow_sample_rate <= std_logic_vector(to_unsigned(32000, 32));
        shadow_window_samples <= std_logic_vector(to_unsigned(6400, 32));
        shadow_valid_mask <= x"70";
        shadow_enable <= '0';
        shadow_dc_remove <= '1';
        frequency_shadow_control <= x"00000A63";
        frequency_shadow_window_samples <=
          std_logic_vector(to_unsigned(32000, 32));
        frequency_shadow_minimum_millihz <=
          std_logic_vector(to_unsigned(40000, 32));
        frequency_shadow_maximum_millihz <=
          std_logic_vector(to_unsigned(70000, 32));
        frequency_shadow_hysteresis_uv <=
          std_logic_vector(to_unsigned(1000000, 32));
        grid_shadow_config <= GRID_CONFIG_DEFAULT;
        -- Reference 0 leaves event detection DISARMED until software
        -- declares the reference voltage: an unconfigured meter must
        -- never invent dips (pq_event_pkg).
        pq_shadow_reference <= (others => '0');
        pq_shadow_threshold <= PQ_THRESHOLD_DEFAULT;
        pq_shadow_limits <= PQ_LIMITS_DEFAULT;
        apply_toggle <= '0';
        bvalid <= '0';
        rvalid <= '0';
        rdata <= (others => '0');
      else
        if bvalid = '1' and s_axi_bready = '1' then
          bvalid <= '0';
        end if;

        if bvalid = '0' and s_axi_awvalid = '1' and s_axi_wvalid = '1' then
          address_word := to_integer(unsigned(s_axi_awaddr(7 downto 2)));
          case address_word is
            when 2 =>
              control_word := (others => '0');
              control_word(1) := shadow_enable;
              control_word(2) := shadow_dc_remove;
              control_word := apply_write_strobes(control_word, s_axi_wdata, s_axi_wstrb);
              shadow_enable <= control_word(1);
              shadow_dc_remove <= control_word(2);
              if s_axi_wstrb(0) = '1' and s_axi_wdata(0) = '1' then
                apply_toggle <= not apply_toggle;
              end if;
            when 4 =>
              shadow_generation <= apply_write_strobes(
                shadow_generation, s_axi_wdata, s_axi_wstrb);
            when 5 =>
              shadow_sample_rate <= apply_write_strobes(
                shadow_sample_rate, s_axi_wdata, s_axi_wstrb);
            when 6 =>
              shadow_window_samples <= apply_write_strobes(
                shadow_window_samples, s_axi_wdata, s_axi_wstrb);
            when 7 =>
              updated_word := (others => '0');
              updated_word(7 downto 0) := shadow_valid_mask;
              updated_word := apply_write_strobes(updated_word, s_axi_wdata, s_axi_wstrb);
              shadow_valid_mask <= updated_word(7 downto 0);
            when FREQUENCY_REG_SHADOW_CONTROL / 4 =>
              frequency_shadow_control <= apply_write_strobes(
                frequency_shadow_control, s_axi_wdata, s_axi_wstrb);
            when FREQUENCY_REG_SHADOW_WINDOW_SAMPLES / 4 =>
              frequency_shadow_window_samples <= apply_write_strobes(
                frequency_shadow_window_samples, s_axi_wdata, s_axi_wstrb);
            when FREQUENCY_REG_SHADOW_MINIMUM_MILLIHZ / 4 =>
              frequency_shadow_minimum_millihz <= apply_write_strobes(
                frequency_shadow_minimum_millihz, s_axi_wdata, s_axi_wstrb);
            when FREQUENCY_REG_SHADOW_MAXIMUM_MILLIHZ / 4 =>
              frequency_shadow_maximum_millihz <= apply_write_strobes(
                frequency_shadow_maximum_millihz, s_axi_wdata, s_axi_wstrb);
            when FREQUENCY_REG_SHADOW_HYSTERESIS_UV / 4 =>
              frequency_shadow_hysteresis_uv <= apply_write_strobes(
                frequency_shadow_hysteresis_uv, s_axi_wdata, s_axi_wstrb);
            when GRID_REG_SHADOW_CONFIG / 4 =>
              grid_shadow_config <= apply_write_strobes(
                grid_shadow_config, s_axi_wdata, s_axi_wstrb);
            when PQ_REG_SHADOW_REFERENCE / 4 =>
              pq_shadow_reference <= apply_write_strobes(
                pq_shadow_reference, s_axi_wdata, s_axi_wstrb);
            when PQ_REG_SHADOW_THRESHOLD / 4 =>
              pq_shadow_threshold <= apply_write_strobes(
                pq_shadow_threshold, s_axi_wdata, s_axi_wstrb);
            when PQ_REG_SHADOW_LIMITS / 4 =>
              pq_shadow_limits <= apply_write_strobes(
                pq_shadow_limits, s_axi_wdata, s_axi_wstrb);
            when others => null;
          end case;
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
            when 2 =>
              control_word := (others => '0');
              control_word(1) := shadow_enable;
              control_word(2) := shadow_dc_remove;
              rdata <= control_word;
            when 3 => rdata <= status_i;
            when 4 => rdata <= shadow_generation;
            when 5 => rdata <= shadow_sample_rate;
            when 6 => rdata <= shadow_window_samples;
            when 7 => rdata <= x"000000" & shadow_valid_mask;
            when 8 => rdata <= active_generation_i;
            when 9 => rdata <= result_sequence_i;
            when 10 => rdata <= result_drop_count_i;
            when 11 => rdata <= packet_drop_count_i;
            when FREQUENCY_REG_SHADOW_CONTROL / 4 =>
              rdata <= frequency_shadow_control;
            when FREQUENCY_REG_SHADOW_WINDOW_SAMPLES / 4 =>
              rdata <= frequency_shadow_window_samples;
            when FREQUENCY_REG_SHADOW_MINIMUM_MILLIHZ / 4 =>
              rdata <= frequency_shadow_minimum_millihz;
            when FREQUENCY_REG_SHADOW_MAXIMUM_MILLIHZ / 4 =>
              rdata <= frequency_shadow_maximum_millihz;
            when FREQUENCY_REG_SHADOW_HYSTERESIS_UV / 4 =>
              rdata <= frequency_shadow_hysteresis_uv;
            when FREQUENCY_REG_ACTIVE_CONTROL / 4 =>
              rdata <= frequency_active_control_i;
            when FREQUENCY_REG_ACTIVE_WINDOW_SAMPLES / 4 =>
              rdata <= frequency_active_window_samples_i;
            when FREQUENCY_REG_ACTIVE_MINIMUM_MILLIHZ / 4 =>
              rdata <= frequency_active_minimum_millihz_i;
            when FREQUENCY_REG_ACTIVE_MAXIMUM_MILLIHZ / 4 =>
              rdata <= frequency_active_maximum_millihz_i;
            when FREQUENCY_REG_ACTIVE_HYSTERESIS_UV / 4 =>
              rdata <= frequency_active_hysteresis_uv_i;
            when FREQUENCY_REG_STATUS / 4 => rdata <= frequency_status_i;
            when FREQUENCY_REG_VALUE_MILLIHZ / 4 =>
              rdata <= frequency_millihz_i;
            when FREQUENCY_REG_PERIOD_Q16_SAMPLES / 4 =>
              rdata <= frequency_period_q16_samples_i;
            when FREQUENCY_REG_MEASUREMENT_SEQUENCE / 4 =>
              rdata <= frequency_measurement_sequence_i;
            when FREQUENCY_REG_REJECTED_COUNT / 4 =>
              rdata <= frequency_rejected_count_i;
            when GRID_REG_SHADOW_CONFIG / 4 => rdata <= grid_shadow_config;
            when GRID_REG_ACTIVE_CONFIG / 4 => rdata <= grid_active_config_i;
            when GRID_REG_STATUS / 4 => rdata <= grid_status_i;
            when PQ_REG_SHADOW_REFERENCE / 4 => rdata <= pq_shadow_reference;
            when PQ_REG_SHADOW_THRESHOLD / 4 => rdata <= pq_shadow_threshold;
            when PQ_REG_SHADOW_LIMITS / 4 => rdata <= pq_shadow_limits;
            when PQ_REG_STATUS / 4 => rdata <= pq_status_i;
            when AGG_REG_STATUS / 4 => rdata <= agg_status_i;
            when AGG_REG_RECORD_COUNT / 4 => rdata <= agg_record_count_i;
            when AGG_REG_RESET_COUNT / 4 => rdata <= agg_reset_count_i;
            when AGG_REG_INELIGIBLE_COUNT / 4 => rdata <= agg_ineligible_count_i;
            when AGG_REG_CONTINUITY_COUNT / 4 => rdata <= agg_continuity_count_i;
            when AGG_REG_DROP_COUNT / 4 => rdata <= agg_drop_count_i;
            when HLS_AGG_REG_RECORD_COUNT / 4 =>
              rdata <= hls_agg_record_count_i;
            when HLS_AGG_REG_MISMATCH_COUNT / 4 =>
              rdata <= hls_agg_mismatch_count_i;
            when HLS_AGG_REG_DROP_COUNT / 4 =>
              rdata <= hls_agg_drop_count_i;
            when R5_AGG_EXPORT_REG_STATUS / 4 =>
              rdata <= r5_agg_export_status_i;
            when R5_AGG_EXPORT_REG_ACCEPTED_COUNT / 4 =>
              rdata <= r5_agg_export_accepted_count_i;
            when R5_AGG_EXPORT_REG_DROPPED_COUNT / 4 =>
              rdata <= r5_agg_export_dropped_count_i;
            when R5_AGG_EXPORT_REG_TRANSMITTED_COUNT / 4 =>
              rdata <= r5_agg_export_transmitted_count_i;
            when R5_AGG_EXPORT_REG_FRAMING_ERRORS / 4 =>
              rdata <= r5_agg_export_framing_errors_i;
            when R5_AGG_EXPORT_REG_LAST_SEQUENCE / 4 =>
              rdata <= r5_agg_export_last_sequence_i;
            when R5_AGG_EXPORT_REG_QUEUE_LEVEL / 4 =>
              rdata <= r5_agg_export_queue_level_i;
            when others => rdata <= (others => '0');
          end case;
          rvalid <= '1';
        end if;
      end if;
    end if;
  end process;
end architecture;
