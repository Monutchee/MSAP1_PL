library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.metering_pkg.all;
use work.measurement_record_bus_pkg.all;

-- MTR2 record producer: publishes one 256-byte 150/180-cycle aggregate
-- record on the measurement record bus per completed aggregate. Only
-- complete aggregates reach this producer (the aggregator emits nothing
-- for discarded partials), so every published record carries the
-- COMPLETE status bit.
--
-- Mirrors the Basic producer's transport behavior: one pending record,
-- newest wins, and a drop counter when the arbiter/packetizer side has not
-- consumed the previous record. At one aggregate per ~3 s this only fires
-- if the DMA side is stalled far beyond the packetizer's own buffering.
entity aggregate_record_producer is
  port (
    aclk    : in std_logic;
    aresetn : in std_logic;

    aggregate_valid_i        : in std_logic;
    aggregate_sequence_i     : in word32_t;
    aggregate_generation_i   : in word32_t;
    aggregate_sample_rate_i  : in word32_t;
    aggregate_samples_i      : in word32_t;
    aggregate_valid_mask_i   : in std_logic_vector(7 downto 0);
    aggregate_arithmetic_i   : in std_logic;
    aggregate_freq_valid_i   : in std_logic;
    aggregate_first_seq_i    : in word32_t;
    aggregate_last_seq_i     : in word32_t;
    aggregate_nominal_i      : in std_logic_vector(7 downto 0);
    aggregate_cycles_i       : in std_logic_vector(15 downto 0);
    aggregate_first_sample_i : in std_logic_vector(63 downto 0);
    aggregate_rms_q16_i      : in std_logic_vector(511 downto 0);
    aggregate_freq_millihz_i : in word32_t;

    record_data_o  : out measurement_record_t;
    record_valid_o : out std_logic;
    record_ready_i : in  std_logic;
    drop_count_o   : out word32_t
  );
end entity;

architecture rtl of aggregate_record_producer is
  signal record_data  : measurement_record_t := (others => '0');
  signal record_valid : std_logic := '0';
  signal drop_count   : unsigned(31 downto 0) := (others => '0');
begin
  record_data_o <= record_data;
  record_valid_o <= record_valid;
  drop_count_o <= std_logic_vector(drop_count);

  process (aclk)
    variable next_record : measurement_record_t;
    variable rms_q16     : signed(63 downto 0);
    variable rms_units   : signed(63 downto 0);
    variable status_word : word32_t;
    variable word_base   : natural;
  begin
    if rising_edge(aclk) then
      if aresetn = '0' then
        record_data <= (others => '0');
        record_valid <= '0';
        drop_count <= (others => '0');
      else
        if record_valid = '1' and record_ready_i = '1' then
          record_valid <= '0';
        end if;

        if aggregate_valid_i = '1' then
          next_record := (others => '0');

          next_record(31 downto 0) := x"3152544D"; -- container magic "MTR1"
          next_record(63 downto 32) := MTR2_FORMAT;
          next_record(95 downto 64) := std_logic_vector(to_unsigned(256, 32));
          next_record((MTR2_SEQUENCE_WORD * 32) + 31 downto
                      MTR2_SEQUENCE_WORD * 32) := aggregate_sequence_i;
          next_record((MTR2_GENERATION_WORD * 32) + 31 downto
                      MTR2_GENERATION_WORD * 32) := aggregate_generation_i;
          next_record((MTR2_SAMPLE_RATE_WORD * 32) + 31 downto
                      MTR2_SAMPLE_RATE_WORD * 32) := aggregate_sample_rate_i;
          next_record((MTR2_TOTAL_SAMPLES_WORD * 32) + 31 downto
                      MTR2_TOTAL_SAMPLES_WORD * 32) := aggregate_samples_i;
          next_record((MTR2_VALID_MASK_WORD * 32) + 31 downto
                      MTR2_VALID_MASK_WORD * 32) :=
            x"000000" & aggregate_valid_mask_i;

          status_word := (others => '0');
          status_word(MTR2_STATUS_ARITHMETIC_BIT) := aggregate_arithmetic_i;
          -- Only complete 15-block aggregates are ever emitted.
          status_word(MTR2_STATUS_COMPLETE_BIT) := '1';
          status_word(MTR2_STATUS_FREQUENCY_BIT) := aggregate_freq_valid_i;
          next_record((MTR2_STATUS_WORD * 32) + 31 downto
                      MTR2_STATUS_WORD * 32) := status_word;

          next_record((MTR2_FIRST_BASIC_SEQ_WORD * 32) + 31 downto
                      MTR2_FIRST_BASIC_SEQ_WORD * 32) := aggregate_first_seq_i;
          next_record((MTR2_LAST_BASIC_SEQ_WORD * 32) + 31 downto
                      MTR2_LAST_BASIC_SEQ_WORD * 32) := aggregate_last_seq_i;

          next_record((MTR2_SHAPE_WORD * 32) + MTR2_SHAPE_BLOCKS_LSB + 7
                      downto (MTR2_SHAPE_WORD * 32) + MTR2_SHAPE_BLOCKS_LSB)
            := std_logic_vector(to_unsigned(AGGREGATE_BASIC_BLOCKS, 8));
          next_record((MTR2_SHAPE_WORD * 32) + MTR2_SHAPE_NOMINAL_LSB + 7
                      downto (MTR2_SHAPE_WORD * 32) + MTR2_SHAPE_NOMINAL_LSB)
            := aggregate_nominal_i;
          next_record((MTR2_SHAPE_WORD * 32) + MTR2_SHAPE_CYCLES_LSB + 15
                      downto (MTR2_SHAPE_WORD * 32) + MTR2_SHAPE_CYCLES_LSB)
            := aggregate_cycles_i;

          next_record((MTR2_FIRST_SAMPLE_LOW_WORD * 32) + 31 downto
                      MTR2_FIRST_SAMPLE_LOW_WORD * 32) :=
            aggregate_first_sample_i(31 downto 0);
          next_record((MTR2_FIRST_SAMPLE_HIGH_WORD * 32) + 31 downto
                      MTR2_FIRST_SAMPLE_HIGH_WORD * 32) :=
            aggregate_first_sample_i(63 downto 32);

          -- Aggregate RMS values leave the internal Q16 domain here, in
          -- the same micro-unit convention as the Basic record.
          for channel in 0 to 7 loop
            rms_q16 := signed(aggregate_rms_q16_i(
              (channel * 64) + 63 downto channel * 64));
            rms_units := shift_right(rms_q16, 16);
            word_base := MTR2_CHANNEL_BASE_WORD + (channel * 2);
            next_record((word_base * 32) + 31 downto word_base * 32) :=
              std_logic_vector(rms_units(31 downto 0));
            next_record(((word_base + 1) * 32) + 31 downto
                        (word_base + 1) * 32) :=
              std_logic_vector(rms_units(63 downto 32));
          end loop;

          next_record((MTR2_FREQUENCY_WORD * 32) + 31 downto
                      MTR2_FREQUENCY_WORD * 32) := aggregate_freq_millihz_i;

          if record_valid = '1' and record_ready_i = '0' then
            drop_count <= drop_count + 1;
          end if;
          record_data <= next_record;
          record_valid <= '1';
        end if;
      end if;
    end if;
  end process;
end architecture;
