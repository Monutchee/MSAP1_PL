library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Qualified zero-crossing detector for one converted channel.
--
-- A rising crossing is accepted only after the signal has first moved below
-- the negative hysteresis threshold; a falling crossing only after it has
-- moved above the positive threshold. This prevents noise around zero from
-- generating multiple periods. The detector returns the two samples that
-- bracket zero; interpolation is deliberately left to the estimator.
--
-- Two views of the same decision are exposed:
--   * Registered outputs (crossing_valid_o and the bracket samples), one
--     clock after the accepted frame. The frequency estimator uses these.
--   * Combinational "now" outputs, valid during frame_accept_i itself.
--     Grid-cycle timing uses these so a block-closing decision can travel
--     through the RMS pipeline together with the frame that caused it.
-- Both views are computed from one shared expression so they can never
-- disagree about whether a frame crossed zero.
entity meter_zero_crossing is
  port (
    aclk                  : in  std_logic;
    aresetn               : in  std_logic;
    clear_i               : in  std_logic;
    frame_accept_i        : in  std_logic;
    sample_valid_i        : in  std_logic;
    sample_sequence_i     : in  std_logic_vector(31 downto 0);
    sample_q16_i          : in  std_logic_vector(63 downto 0);
    hysteresis_uv_i       : in  std_logic_vector(31 downto 0);
    crossing_valid_o      : out std_logic;
    previous_sequence_o   : out std_logic_vector(31 downto 0);
    previous_sample_q16_o : out std_logic_vector(63 downto 0);
    current_sample_q16_o  : out std_logic_vector(63 downto 0);
    armed_o               : out std_logic;
    reference_valid_o     : out std_logic;
    rising_crossing_now_o : out std_logic;
    falling_crossing_now_o: out std_logic
  );
end entity;

architecture rtl of meter_zero_crossing is
  signal previous_valid  : std_logic := '0';
  signal previous_sample : signed(63 downto 0) := (others => '0');
  signal previous_seq    : std_logic_vector(31 downto 0) := (others => '0');
  signal armed           : std_logic := '0';
  signal falling_armed   : std_logic := '0';
  signal reference_valid : std_logic := '0';
  signal rising_now      : std_logic;
  signal falling_now     : std_logic;
begin
  armed_o <= armed;
  reference_valid_o <= reference_valid;
  rising_crossing_now_o <= rising_now;
  falling_crossing_now_o <= falling_now;

  -- Shared crossing decision, evaluated against the state registered from
  -- the previous frame and the sample arriving with the current frame. The
  -- outputs are only meaningful while frame_accept_i is high.
  crossing_view : process (all)
    variable current_sample : signed(63 downto 0);
  begin
    rising_now <= '0';
    falling_now <= '0';
    if frame_accept_i = '1' and sample_valid_i = '1' and
       previous_valid = '1' then
      current_sample := signed(sample_q16_i);
      if armed = '1' and previous_sample < 0 and current_sample >= 0 then
        rising_now <= '1';
      end if;
      if falling_armed = '1' and previous_sample >= 0 and
         current_sample < 0 then
        falling_now <= '1';
      end if;
    end if;
  end process;

  process (aclk)
    variable current_sample : signed(63 downto 0);
    variable threshold_q16  : signed(63 downto 0);
  begin
    if rising_edge(aclk) then
      crossing_valid_o <= '0';
      if aresetn = '0' or clear_i = '1' then
        previous_valid <= '0';
        previous_sample <= (others => '0');
        previous_seq <= (others => '0');
        armed <= '0';
        falling_armed <= '0';
        reference_valid <= '0';
      elsif frame_accept_i = '1' then
        reference_valid <= sample_valid_i;
        if sample_valid_i = '0' then
          previous_valid <= '0';
          armed <= '0';
          falling_armed <= '0';
        else
          current_sample := signed(sample_q16_i);
          threshold_q16 := signed(resize(unsigned(hysteresis_uv_i), 64) sll 16);

          if current_sample <= -threshold_q16 then
            armed <= '1';
          end if;
          if current_sample >= threshold_q16 then
            falling_armed <= '1';
          end if;

          if rising_now = '1' then
            previous_sequence_o <= previous_seq;
            previous_sample_q16_o <= std_logic_vector(previous_sample);
            current_sample_q16_o <= std_logic_vector(current_sample);
            crossing_valid_o <= '1';
            armed <= '0';
          end if;
          if falling_now = '1' then
            falling_armed <= '0';
          end if;

          previous_sample <= current_sample;
          previous_seq <= sample_sequence_i;
          previous_valid <= '1';
        end if;
      end if;
    end if;
  end process;
end architecture;
