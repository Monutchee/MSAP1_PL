library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.metering_pkg.all;
use work.grid_timing_pkg.all;
use work.measurement_record_bus_pkg.all;

-- IEC 61000-4-30 150/180-cycle aggregator.
--
-- This engine aggregates exactly AGGREGATE_BASIC_BLOCKS (15) consecutive
-- eligible Basic measurement results into one 150-cycle (50 Hz nominal) or
-- 180-cycle (60 Hz nominal) fundamental aggregate. It consumes the internal
-- Basic result event -- the same event the Basic record producer consumes --
-- and is therefore an aggregator of standardized Basic results, NOT a
-- second independent RMS engine over raw ADC samples, and NOT a 3-second
-- wall-clock window. The close event is "15 eligible Basic blocks", never a
-- timer.
--
-- Aggregation rules (per quantity, per the standard):
--   * RMS voltage/current: square root of the arithmetic mean of the
--     squares of the 15 Basic RMS values, unweighted (each Basic interval
--     contributes equally even though sample counts vary with grid
--     frequency): agg = floor(sqrt(floor(sum(x_i^2) / 15))). Computed in
--     the internal Q16 domain so no precision is lost through the public
--     micro-unit format.
--   * Frequency: arithmetic mean floor(sum(f_i)/15) of the 15 sampled
--     values, published only when every input was valid. This is an
--     informative aggregate; the standardized frequency interval is the
--     10 s tier, which is out of scope here.
--
-- Arithmetic geometry (documented in measurement_record_bus_pkg):
-- 64-bit Q16 inputs -> 126-bit squares -> 132-bit accumulators (15 x 2^126
-- cannot overflow) -> bit-serial floor division by 15 -> 128-bit radicand
-- -> 64-bit floor square root. Nothing relies on implicit truncation.
-- The squaring step is pipelined over three clocks per channel (lane mux and
-- magnitude, multiply, accumulate) purely so no single path has to carry all
-- three at the AXI clock period. The accumulated values are identical to a
-- single-cycle implementation; only the state walk is longer, which is free
-- here because Basic results arrive ~200 ms apart.
--
-- A Basic input only enters an aggregate when ALL of the following hold,
-- mirroring the APU's class_a_aggregation_eligible() rule:
--   * cycle_locked, not free_run_fallback, not first_block_after_apply
--   * cycle_count matches the nominal (50 Hz -> 10, 60 Hz -> 12)
--   * same configuration generation as the blocks already accumulated
--   * same nominal frequency as the blocks already accumulated
--   * same sample rate as the blocks already accumulated (MTR2 carries one
--     sample rate for the whole interval, so the invariant is explicit here
--     rather than inferred from the generation)
--   * consecutive Basic result sequences (modulo 2**32)
--   * gapless: first_sample = previous first_sample + previous count
-- Sequence continuity and sample-range continuity are BOTH required: they
-- catch different faults (a lost result event versus a sample-domain
-- discontinuity), so neither replaces the other.
-- Any violation resets the partial aggregate (counted per cause); an
-- eligible block that caused a generation/nominal/continuity reset seeds a
-- fresh aggregate so the engine re-aligns on the next natural boundary. An
-- ineligible block never seeds. A rejected block is never silently skipped
-- with a later block taking its place inside the same aggregate.
--
-- Like every metrology observer in this design the aggregator has no ready
-- output and cannot backpressure the measurement pipeline.
entity meter_cycle_aggregator is
  port (
    aclk    : in std_logic;
    aresetn : in std_logic;

    -- Basic result event (single-cycle valid) and the shared APPLY toggle.
    basic_i               : in basic_measurement_result_t;
    config_apply_toggle_i : in std_logic;

    -- Aggregate result event (single-cycle valid; outputs stay stable
    -- until the next aggregate completes, ~3 s later).
    aggregate_valid_o        : out std_logic;
    aggregate_sequence_o     : out word32_t;
    aggregate_generation_o   : out word32_t;
    aggregate_sample_rate_o  : out word32_t;
    aggregate_samples_o      : out word32_t;
    aggregate_valid_mask_o   : out std_logic_vector(7 downto 0);
    aggregate_arithmetic_o   : out std_logic;
    aggregate_freq_valid_o   : out std_logic;
    aggregate_first_seq_o    : out word32_t;
    aggregate_last_seq_o     : out word32_t;
    aggregate_nominal_o      : out std_logic_vector(7 downto 0);
    aggregate_cycles_o       : out std_logic_vector(15 downto 0);
    aggregate_first_sample_o : out std_logic_vector(63 downto 0);
    aggregate_rms_q16_o      : out std_logic_vector(511 downto 0);
    aggregate_freq_millihz_o : out word32_t;

    -- Health/diagnostics for the processing register bank.
    status_o           : out word32_t;
    record_count_o     : out word32_t;
    reset_count_o      : out word32_t;
    ineligible_count_o : out word32_t;
    continuity_count_o : out word32_t
  );
end entity;

architecture rtl of meter_cycle_aggregator is
  constant C_CHANNELS : natural := 7;  -- CH0..CH6; CH7 stays zero

  type state_t is (
    S_IDLE,
    S_SQUARE_LOAD,   -- per channel: select the Q16 lane, take its magnitude
    S_SQUARE_MULT,   -- per channel: square the magnitude
    S_SQUARE_ACC,    -- per channel: add the square to the accumulator
    S_DIV_PREP,      -- per-channel finalize: mean = acc / 15
    S_DIV_RUN,
    S_SQRT_MULTIPLY, -- 64-bit floor root of the 128-bit mean
    S_SQRT_COMPARE,
    S_FREQ_PREP,     -- frequency mean = freq_sum / 15 (no square root)
    S_FREQ_RUN,
    S_EMIT
  );

  type acc_array_t is array (0 to C_CHANNELS - 1) of
    unsigned(AGGREGATE_ACCUMULATOR_BITS - 1 downto 0);
  type rms_array_t is array (0 to C_CHANNELS - 1) of unsigned(63 downto 0);

  signal state        : state_t := S_IDLE;
  signal apply_seen   : std_logic := '0';

  -- Open-aggregate bookkeeping.
  signal blocks_accumulated : unsigned(4 downto 0) := (others => '0');
  signal agg_generation     : word32_t := (others => '0');
  signal agg_nominal        : unsigned(7 downto 0) := (others => '0');
  signal agg_sample_rate    : word32_t := (others => '0');
  signal agg_first_sample   : unsigned(63 downto 0) := (others => '0');
  signal agg_first_seq      : word32_t := (others => '0');
  signal agg_last_seq       : word32_t := (others => '0');
  signal agg_total_samples  : unsigned(31 downto 0) := (others => '0');
  signal agg_total_cycles   : unsigned(15 downto 0) := (others => '0');
  signal expected_next_first: unsigned(63 downto 0) := (others => '0');
  -- Next Basic result sequence required by the open aggregate. Unsigned
  -- arithmetic wraps naturally at 2**32, so 0xFFFFFFFF -> 0x00000000 stays
  -- consecutive without a special case.
  signal expected_next_seq  : unsigned(31 downto 0) := (others => '0');
  signal mask_and           : std_logic_vector(7 downto 0) := (others => '0');
  signal freq_sum           : unsigned(35 downto 0) := (others => '0');
  signal freq_all_valid     : std_logic := '0';
  signal arithmetic_flag    : std_logic := '0';
  signal square_acc         : acc_array_t := (others => (others => '0'));

  -- One captured input being squared/accumulated.
  signal capture_rms      : std_logic_vector(511 downto 0) := (others => '0');
  signal capture_finalize : std_logic := '0';
  signal work_channel     : natural range 0 to C_CHANNELS - 1 := 0;
  -- Squaring pipeline registers, one stage boundary each (see S_SQUARE_*).
  signal square_magnitude : unsigned(63 downto 0) := (others => '0');
  signal square_product   : unsigned(127 downto 0) := (others => '0');

  -- Shared bit-serial divider (dividend/15) and binary-search square root,
  -- following the meter_rms implementation pattern. Division and root are
  -- both floor operations.
  signal divider_dividend : unsigned(AGGREGATE_ACCUMULATOR_BITS - 1 downto 0)
    := (others => '0');
  signal divider_quotient : unsigned(AGGREGATE_ACCUMULATOR_BITS - 1 downto 0)
    := (others => '0');
  signal divider_remainder : unsigned(AGGREGATE_ACCUMULATOR_BITS downto 0)
    := (others => '0');
  signal divider_bit      : natural range 0 to
    AGGREGATE_ACCUMULATOR_BITS - 1 := AGGREGATE_ACCUMULATOR_BITS - 1;
  signal sqrt_radicand    : unsigned(127 downto 0) := (others => '0');
  signal sqrt_low         : unsigned(63 downto 0) := (others => '0');
  signal sqrt_high        : unsigned(63 downto 0) := (others => '1');
  signal sqrt_midpoint    : unsigned(63 downto 0) := (others => '0');
  signal sqrt_square      : unsigned(127 downto 0) := (others => '0');
  signal sqrt_iteration   : natural range 0 to 63 := 0;

  -- Latched aggregate outputs.
  signal result_rms       : rms_array_t := (others => (others => '0'));
  signal out_valid        : std_logic := '0';
  signal out_sequence     : unsigned(31 downto 0) := (others => '0');
  signal out_freq_millihz : word32_t := (others => '0');
  signal out_freq_valid   : std_logic := '0';

  -- Diagnostics.
  signal record_count     : unsigned(31 downto 0) := (others => '0');
  signal reset_count      : unsigned(31 downto 0) := (others => '0');
  signal ineligible_count : unsigned(31 downto 0) := (others => '0');
  signal continuity_count : unsigned(31 downto 0) := (others => '0');

  -- Eligibility of the current input event, evaluated combinationally.
  function expected_cycles(nominal : std_logic_vector(7 downto 0))
    return unsigned is
  begin
    if unsigned(nominal) = 50 then
      return to_unsigned(GRID_CYCLES_50HZ, 8);
    end if;
    return to_unsigned(GRID_CYCLES_60HZ, 8);
  end function;

  signal input_eligible : std_logic;
begin
  input_eligible <= '1' when
      basic_i.flags(GRID_BLOCK_FLAG_LOCKED) = '1' and
      basic_i.flags(GRID_BLOCK_FLAG_FALLBACK) = '0' and
      basic_i.flags(GRID_BLOCK_FLAG_FIRST_BLOCK) = '0' and
      (unsigned(basic_i.nominal_hz) = 50 or
       unsigned(basic_i.nominal_hz) = 60) and
      unsigned(basic_i.cycle_count) = expected_cycles(basic_i.nominal_hz)
    else '0';

  aggregate_valid_o <= out_valid;
  aggregate_sequence_o <= std_logic_vector(out_sequence);
  aggregate_generation_o <= agg_generation;
  aggregate_sample_rate_o <= agg_sample_rate;
  aggregate_samples_o <= std_logic_vector(agg_total_samples);
  aggregate_valid_mask_o <= mask_and;
  aggregate_arithmetic_o <= arithmetic_flag;
  aggregate_freq_valid_o <= out_freq_valid;
  aggregate_first_seq_o <= agg_first_seq;
  aggregate_last_seq_o <= agg_last_seq;
  aggregate_nominal_o <= std_logic_vector(agg_nominal);
  aggregate_cycles_o <= std_logic_vector(agg_total_cycles);
  aggregate_first_sample_o <= std_logic_vector(agg_first_sample);
  aggregate_freq_millihz_o <= out_freq_millihz;

  output_lanes : for channel in 0 to 7 generate
    lane_active : if channel < C_CHANNELS generate
      aggregate_rms_q16_o((channel * 64) + 63 downto channel * 64) <=
        std_logic_vector(result_rms(channel));
    end generate;
    lane_zero : if channel >= C_CHANNELS generate
      aggregate_rms_q16_o((channel * 64) + 63 downto channel * 64) <=
        (others => '0');
    end generate;
  end generate;

  status_o(31 downto 9) <= (others => '0');
  status_o(AGG_STATUS_ACTIVE_BIT) <= '1' when blocks_accumulated /= 0 else '0';
  status_o(7 downto 5) <= (others => '0');
  status_o(AGG_STATUS_BLOCKS_LSB + 4 downto AGG_STATUS_BLOCKS_LSB) <=
    std_logic_vector(blocks_accumulated);
  record_count_o <= std_logic_vector(record_count);
  reset_count_o <= std_logic_vector(reset_count);
  ineligible_count_o <= std_logic_vector(ineligible_count);
  continuity_count_o <= std_logic_vector(continuity_count);

  process (aclk)
    variable seed        : boolean;
    variable sample_q16  : signed(63 downto 0);
    variable rem_shift   : unsigned(AGGREGATE_ACCUMULATOR_BITS downto 0);
    variable quot_next   : unsigned(AGGREGATE_ACCUMULATOR_BITS - 1 downto 0);
    variable mid_sum     : unsigned(64 downto 0);
    variable midpoint    : unsigned(63 downto 0);
  begin
    if rising_edge(aclk) then
      out_valid <= '0';

      if aresetn = '0' then
        state <= S_IDLE;
        apply_seen <= '0';
        blocks_accumulated <= (others => '0');
        expected_next_seq <= (others => '0');
        square_acc <= (others => (others => '0'));
        freq_sum <= (others => '0');
        freq_all_valid <= '0';
        arithmetic_flag <= '0';
        mask_and <= (others => '0');
        capture_finalize <= '0';
        out_sequence <= (others => '0');
        record_count <= (others => '0');
        reset_count <= (others => '0');
        ineligible_count <= (others => '0');
        continuity_count <= (others => '0');
      else
        -- A configuration APPLY terminates any partially accumulated
        -- aggregate: the new generation's first block will seed afresh.
        if config_apply_toggle_i /= apply_seen then
          apply_seen <= config_apply_toggle_i;
          if blocks_accumulated /= 0 or state /= S_IDLE then
            reset_count <= reset_count + 1;
          end if;
          blocks_accumulated <= (others => '0');
          state <= S_IDLE;
          capture_finalize <= '0';
        elsif basic_i.valid = '1' then
          if state /= S_IDLE then
            -- Cannot happen at real block rates (the finalize chain takes
            -- microseconds, blocks arrive every ~200 ms); treated as a
            -- coherency loss rather than silently mixing inputs.
            reset_count <= reset_count + 1;
            blocks_accumulated <= (others => '0');
            state <= S_IDLE;
            capture_finalize <= '0';
          elsif input_eligible = '0' then
            -- An ineligible block invalidates the running aggregate and
            -- never seeds a new one: the interval must stay contiguous.
            ineligible_count <= ineligible_count + 1;
            if blocks_accumulated /= 0 then
              reset_count <= reset_count + 1;
            end if;
            blocks_accumulated <= (others => '0');
          else
            seed := blocks_accumulated = 0;
            if not seed then
              if basic_i.generation /= agg_generation or
                 unsigned(basic_i.nominal_hz) /= agg_nominal or
                 basic_i.sample_rate_hz /= agg_sample_rate then
                -- Generation, nominal, or sample-rate change: the partial
                -- aggregate is discarded and this block seeds the next one.
                -- The sample-rate test is defensive -- the configuration
                -- fingerprint makes a rate change also change the
                -- generation -- but MTR2 reports one rate for the whole
                -- interval, so the invariant is enforced directly.
                reset_count <= reset_count + 1;
                seed := true;
              elsif unsigned(basic_i.result_sequence) /= expected_next_seq or
                    unsigned(basic_i.first_sample) /= expected_next_first then
                -- A lost or reordered Basic result (sequence) or a
                -- sample-domain discontinuity (first sample) both mean the
                -- 15 inputs would not describe one contiguous interval.
                continuity_count <= continuity_count + 1;
                reset_count <= reset_count + 1;
                seed := true;
              end if;
            end if;

            if seed then
              agg_generation <= basic_i.generation;
              agg_nominal <= unsigned(basic_i.nominal_hz);
              agg_sample_rate <= basic_i.sample_rate_hz;
              agg_first_sample <= unsigned(basic_i.first_sample);
              agg_first_seq <= basic_i.result_sequence;
              agg_total_samples <= unsigned(basic_i.sample_count);
              agg_total_cycles <=
                resize(unsigned(basic_i.cycle_count), 16);
              mask_and <= basic_i.valid_mask;
              freq_sum <= resize(
                unsigned(basic_i.frequency_millihz), 36);
              freq_all_valid <= basic_i.frequency_valid;
              arithmetic_flag <= basic_i.status(0);
              square_acc <= (others => (others => '0'));
              blocks_accumulated <= to_unsigned(1, 5);
              capture_finalize <= '0';
            else
              agg_total_samples <= agg_total_samples +
                unsigned(basic_i.sample_count);
              agg_total_cycles <= agg_total_cycles +
                resize(unsigned(basic_i.cycle_count), 16);
              mask_and <= mask_and and basic_i.valid_mask;
              freq_sum <= freq_sum + resize(
                unsigned(basic_i.frequency_millihz), 36);
              freq_all_valid <= freq_all_valid and
                basic_i.frequency_valid;
              arithmetic_flag <= arithmetic_flag or basic_i.status(0);
              blocks_accumulated <= blocks_accumulated + 1;
              capture_finalize <= '0';
              if blocks_accumulated + 1 = AGGREGATE_BASIC_BLOCKS then
                capture_finalize <= '1';
              end if;
            end if;
            agg_last_seq <= basic_i.result_sequence;
            expected_next_seq <= unsigned(basic_i.result_sequence) + 1;
            expected_next_first <= unsigned(basic_i.first_sample) +
              resize(unsigned(basic_i.sample_count), 64);
            capture_rms <= basic_i.rms_q16;
            work_channel <= 0;
            state <= S_SQUARE_LOAD;
          end if;
        else
          case state is
            when S_IDLE =>
              null;

            when S_SQUARE_LOAD =>
              -- Select this channel's captured Q16 RMS lane out of the
              -- 512-bit capture register and register its magnitude. RMS
              -- magnitudes are non-negative; the signed lane is normalized
              -- defensively.
              sample_q16 := signed(capture_rms(
                (work_channel * 64) + 63 downto work_channel * 64));
              if sample_q16 < 0 then
                square_magnitude <= unsigned(-sample_q16);
              else
                square_magnitude <= unsigned(sample_q16);
              end if;
              state <= S_SQUARE_MULT;

            when S_SQUARE_MULT =>
              -- The 64x64 multiply owns a clock period of its own so the
              -- DSP cascade does not share one with the lane mux ahead of
              -- it or the 132-bit accumulate behind it.
              square_product <= square_magnitude * square_magnitude;
              state <= S_SQUARE_ACC;

            when S_SQUARE_ACC =>
              square_acc(work_channel) <= square_acc(work_channel) +
                resize(square_product, AGGREGATE_ACCUMULATOR_BITS);
              if work_channel = C_CHANNELS - 1 then
                if capture_finalize = '1' then
                  work_channel <= 0;
                  state <= S_DIV_PREP;
                else
                  state <= S_IDLE;
                end if;
              else
                work_channel <= work_channel + 1;
                state <= S_SQUARE_LOAD;
              end if;

            when S_DIV_PREP =>
              divider_dividend <= square_acc(work_channel);
              divider_quotient <= (others => '0');
              divider_remainder <= (others => '0');
              divider_bit <= AGGREGATE_ACCUMULATOR_BITS - 1;
              state <= S_DIV_RUN;

            when S_DIV_RUN =>
              rem_shift := divider_remainder(
                AGGREGATE_ACCUMULATOR_BITS - 1 downto 0) &
                divider_dividend(divider_bit);
              quot_next := divider_quotient;
              if rem_shift >= to_unsigned(
                  AGGREGATE_BASIC_BLOCKS,
                  AGGREGATE_ACCUMULATOR_BITS + 1) then
                divider_remainder <= rem_shift - to_unsigned(
                  AGGREGATE_BASIC_BLOCKS,
                  AGGREGATE_ACCUMULATOR_BITS + 1);
                quot_next(divider_bit) := '1';
              else
                divider_remainder <= rem_shift;
              end if;
              divider_quotient <= quot_next;
              if divider_bit = 0 then
                -- Mean of 15 squares of 126-bit values stays below 2^127,
                -- so the 128-bit radicand cannot truncate.
                sqrt_radicand <= quot_next(127 downto 0);
                sqrt_low <= (others => '0');
                sqrt_high <= (others => '1');
                sqrt_iteration <= 0;
                state <= S_SQRT_MULTIPLY;
              else
                divider_bit <= divider_bit - 1;
              end if;

            when S_SQRT_MULTIPLY =>
              mid_sum := ('0' & sqrt_low) + ('0' & sqrt_high) + 1;
              midpoint := mid_sum(64 downto 1);
              sqrt_midpoint <= midpoint;
              sqrt_square <= midpoint * midpoint;
              state <= S_SQRT_COMPARE;

            when S_SQRT_COMPARE =>
              if sqrt_square <= sqrt_radicand then
                sqrt_low <= sqrt_midpoint;
              else
                sqrt_high <= sqrt_midpoint - 1;
              end if;
              if sqrt_iteration = 63 then
                if sqrt_square <= sqrt_radicand then
                  result_rms(work_channel) <= sqrt_midpoint;
                else
                  result_rms(work_channel) <= sqrt_low;
                end if;
                if work_channel = C_CHANNELS - 1 then
                  state <= S_FREQ_PREP;
                else
                  work_channel <= work_channel + 1;
                  state <= S_DIV_PREP;
                end if;
              else
                sqrt_iteration <= sqrt_iteration + 1;
                state <= S_SQRT_MULTIPLY;
              end if;

            when S_FREQ_PREP =>
              divider_dividend <= resize(freq_sum,
                AGGREGATE_ACCUMULATOR_BITS);
              divider_quotient <= (others => '0');
              divider_remainder <= (others => '0');
              divider_bit <= AGGREGATE_ACCUMULATOR_BITS - 1;
              state <= S_FREQ_RUN;

            when S_FREQ_RUN =>
              rem_shift := divider_remainder(
                AGGREGATE_ACCUMULATOR_BITS - 1 downto 0) &
                divider_dividend(divider_bit);
              quot_next := divider_quotient;
              if rem_shift >= to_unsigned(
                  AGGREGATE_BASIC_BLOCKS,
                  AGGREGATE_ACCUMULATOR_BITS + 1) then
                divider_remainder <= rem_shift - to_unsigned(
                  AGGREGATE_BASIC_BLOCKS,
                  AGGREGATE_ACCUMULATOR_BITS + 1);
                quot_next(divider_bit) := '1';
              else
                divider_remainder <= rem_shift;
              end if;
              divider_quotient <= quot_next;
              if divider_bit = 0 then
                if freq_all_valid = '1' then
                  out_freq_millihz <= std_logic_vector(
                    quot_next(31 downto 0));
                else
                  out_freq_millihz <= (others => '0');
                end if;
                out_freq_valid <= freq_all_valid;
                state <= S_EMIT;
              else
                divider_bit <= divider_bit - 1;
              end if;

            when S_EMIT =>
              out_sequence <= out_sequence + 1;
              out_valid <= '1';
              record_count <= record_count + 1;
              blocks_accumulated <= (others => '0');
              state <= S_IDLE;
          end case;
        end if;
      end if;
    end if;
  end process;
end architecture;
