library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Qualified positive-going zero-crossing detector for one converted channel.
--
-- A crossing is accepted only after the signal has first moved below the
-- negative hysteresis threshold. This prevents noise around zero from
-- generating multiple periods. The detector returns the two samples that
-- bracket zero; interpolation is deliberately left to the estimator.
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
    reference_valid_o     : out std_logic
  );
end entity;

architecture rtl of meter_zero_crossing is
  signal previous_valid  : std_logic := '0';
  signal previous_sample : signed(63 downto 0) := (others => '0');
  signal previous_seq    : std_logic_vector(31 downto 0) := (others => '0');
  signal armed           : std_logic := '0';
  signal reference_valid : std_logic := '0';
begin
  armed_o <= armed;
  reference_valid_o <= reference_valid;

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
        reference_valid <= '0';
      elsif frame_accept_i = '1' then
        reference_valid <= sample_valid_i;
        if sample_valid_i = '0' then
          previous_valid <= '0';
          armed <= '0';
        else
          current_sample := signed(sample_q16_i);
          threshold_q16 := signed(resize(unsigned(hysteresis_uv_i), 64) sll 16);

          if current_sample <= -threshold_q16 then
            armed <= '1';
          end if;

          if previous_valid = '1' and armed = '1' and
             previous_sample < 0 and current_sample >= 0 then
            previous_sequence_o <= previous_seq;
            previous_sample_q16_o <= std_logic_vector(previous_sample);
            current_sample_q16_o <= std_logic_vector(current_sample);
            crossing_valid_o <= '1';
            armed <= '0';
          end if;

          previous_sample <= current_sample;
          previous_seq <= sample_sequence_i;
          previous_valid <= '1';
        end if;
      end if;
    end if;
  end process;
end architecture;
