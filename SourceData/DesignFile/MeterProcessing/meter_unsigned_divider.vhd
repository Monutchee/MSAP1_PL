library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Iterative unsigned divider used by the frequency estimator.
--
-- One quotient bit is resolved per clock. WIDTH=80 therefore completes well
-- before the next ADC frame even at the supported 128 kSPS maximum. XPM does
-- not provide a general arithmetic divider, so this small reusable primitive
-- keeps variable division out of the higher-level state machine.
entity meter_unsigned_divider is
  generic (
    WIDTH : positive := 80
  );
  port (
    aclk       : in  std_logic;
    aresetn    : in  std_logic;
    start_i    : in  std_logic;
    dividend_i : in  unsigned(WIDTH - 1 downto 0);
    divisor_i  : in  unsigned(WIDTH - 1 downto 0);
    busy_o     : out std_logic;
    done_o     : out std_logic;
    quotient_o : out unsigned(WIDTH - 1 downto 0);
    divide_by_zero_o : out std_logic
  );
end entity;

architecture rtl of meter_unsigned_divider is
  signal busy           : std_logic := '0';
  signal done           : std_logic := '0';
  signal divide_by_zero : std_logic := '0';
  signal dividend       : unsigned(WIDTH - 1 downto 0) := (others => '0');
  signal divisor        : unsigned(WIDTH - 1 downto 0) := (others => '0');
  signal quotient       : unsigned(WIDTH - 1 downto 0) := (others => '0');
  signal remainder      : unsigned(WIDTH downto 0) := (others => '0');
  signal bit_index      : natural range 0 to WIDTH - 1 := WIDTH - 1;
begin
  busy_o <= busy;
  done_o <= done;
  quotient_o <= quotient;
  divide_by_zero_o <= divide_by_zero;

  process (aclk)
    variable shifted_remainder : unsigned(WIDTH downto 0);
    variable extended_divisor  : unsigned(WIDTH downto 0);
    variable next_quotient     : unsigned(WIDTH - 1 downto 0);
  begin
    if rising_edge(aclk) then
      if aresetn = '0' then
        busy <= '0';
        done <= '0';
        divide_by_zero <= '0';
        quotient <= (others => '0');
        remainder <= (others => '0');
        bit_index <= WIDTH - 1;
      else
        done <= '0';
        if start_i = '1' and busy = '0' then
          divide_by_zero <= '0';
          if divisor_i = 0 then
            quotient <= (others => '0');
            divide_by_zero <= '1';
            done <= '1';
          else
            dividend <= dividend_i;
            divisor <= divisor_i;
            quotient <= (others => '0');
            remainder <= (others => '0');
            bit_index <= WIDTH - 1;
            busy <= '1';
          end if;
        elsif busy = '1' then
          shifted_remainder := remainder(WIDTH - 1 downto 0) &
                               dividend(bit_index);
          extended_divisor := '0' & divisor;
          next_quotient := quotient;
          if shifted_remainder >= extended_divisor then
            remainder <= shifted_remainder - extended_divisor;
            next_quotient(bit_index) := '1';
          else
            remainder <= shifted_remainder;
          end if;
          quotient <= next_quotient;

          if bit_index = 0 then
            busy <= '0';
            done <= '1';
          else
            bit_index <= bit_index - 1;
          end if;
        end if;
      end if;
    end if;
  end process;
end architecture;
