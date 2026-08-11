library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.metering_pkg.all;

-- Scores RTL/HLS agreement for the cycle-aggregator trial, one aggregate
-- pair at a time. Both engines hold their outputs stable until their next
-- aggregate (~3 s apart) and finish within microseconds of the fifteenth
-- Basic result, so when the slower engine of a pair emits, the faster
-- engine's outputs still describe the same aggregate: comparing the live
-- outputs at that moment is exact. A dropped or spurious aggregate on
-- either side surfaces through the record-count comparison of every later
-- pair. reset_count is deliberately not compared: a double APPLY between
-- Basic results is invisible to the level-sampled HLS engine (see
-- meter_cycle_aggregator_hls_shim).
entity meter_aggregator_compare is
  port (
    aclk    : in std_logic;
    aresetn : in std_logic;

    rtl_valid_i            : in std_logic;
    rtl_sequence_i         : in word32_t;
    rtl_generation_i       : in word32_t;
    rtl_sample_rate_i      : in word32_t;
    rtl_samples_i          : in word32_t;
    rtl_valid_mask_i       : in std_logic_vector(7 downto 0);
    rtl_arithmetic_i       : in std_logic;
    rtl_freq_valid_i       : in std_logic;
    rtl_first_seq_i        : in word32_t;
    rtl_last_seq_i         : in word32_t;
    rtl_nominal_i          : in std_logic_vector(7 downto 0);
    rtl_cycles_i           : in std_logic_vector(15 downto 0);
    rtl_first_sample_i     : in std_logic_vector(63 downto 0);
    rtl_rms_q16_i          : in std_logic_vector(511 downto 0);
    rtl_freq_millihz_i     : in word32_t;
    rtl_record_count_i     : in word32_t;
    rtl_ineligible_count_i : in word32_t;
    rtl_continuity_count_i : in word32_t;

    hls_valid_i            : in std_logic;
    hls_sequence_i         : in word32_t;
    hls_generation_i       : in word32_t;
    hls_sample_rate_i      : in word32_t;
    hls_samples_i          : in word32_t;
    hls_valid_mask_i       : in std_logic_vector(7 downto 0);
    hls_arithmetic_i       : in std_logic;
    hls_freq_valid_i       : in std_logic;
    hls_first_seq_i        : in word32_t;
    hls_last_seq_i         : in word32_t;
    hls_nominal_i          : in std_logic_vector(7 downto 0);
    hls_cycles_i           : in std_logic_vector(15 downto 0);
    hls_first_sample_i     : in std_logic_vector(63 downto 0);
    hls_rms_q16_i          : in std_logic_vector(511 downto 0);
    hls_freq_millihz_i     : in word32_t;
    hls_record_count_i     : in word32_t;
    hls_ineligible_count_i : in word32_t;
    hls_continuity_count_i : in word32_t;

    mismatch_count_o : out word32_t
  );
end entity;

architecture rtl of meter_aggregator_compare is
  signal rtl_seen       : std_logic := '0';
  signal hls_seen       : std_logic := '0';
  signal mismatch_count : unsigned(31 downto 0) := (others => '0');
begin
  mismatch_count_o <= std_logic_vector(mismatch_count);

  process (aclk)
    variable rtl_ready : std_logic;
    variable hls_ready : std_logic;
    variable mismatch  : boolean;
  begin
    if rising_edge(aclk) then
      if aresetn = '0' then
        rtl_seen <= '0';
        hls_seen <= '0';
        mismatch_count <= (others => '0');
      else
        rtl_ready := rtl_seen or rtl_valid_i;
        hls_ready := hls_seen or hls_valid_i;
        if rtl_ready = '1' and hls_ready = '1' then
          mismatch :=
            hls_sequence_i /= rtl_sequence_i or
            hls_generation_i /= rtl_generation_i or
            hls_sample_rate_i /= rtl_sample_rate_i or
            hls_samples_i /= rtl_samples_i or
            hls_valid_mask_i /= rtl_valid_mask_i or
            hls_arithmetic_i /= rtl_arithmetic_i or
            hls_freq_valid_i /= rtl_freq_valid_i or
            hls_first_seq_i /= rtl_first_seq_i or
            hls_last_seq_i /= rtl_last_seq_i or
            hls_nominal_i /= rtl_nominal_i or
            hls_cycles_i /= rtl_cycles_i or
            hls_first_sample_i /= rtl_first_sample_i or
            hls_rms_q16_i /= rtl_rms_q16_i or
            hls_freq_millihz_i /= rtl_freq_millihz_i or
            hls_record_count_i /= rtl_record_count_i or
            hls_ineligible_count_i /= rtl_ineligible_count_i or
            hls_continuity_count_i /= rtl_continuity_count_i;
          if mismatch then
            mismatch_count <= mismatch_count + 1;
          end if;
          rtl_seen <= '0';
          hls_seen <= '0';
        else
          rtl_seen <= rtl_ready;
          hls_seen <= hls_ready;
        end if;
      end if;
    end if;
  end process;
end architecture;
