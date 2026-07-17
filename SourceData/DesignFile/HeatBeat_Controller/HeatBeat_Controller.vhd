library ieee;
use ieee.std_logic_1164.all;

-- PL-alive indicator driven from the PS-generated PL clock.
entity HeartBeat is
    generic (
        c_CLK_FREQ_HZ : positive := 99_999_001;
        c_BLINK_HZ    : positive := 1
    );
    port (
        clk       : in  std_logic;
        reset_n   : in  std_logic;
        heartbeat : out std_logic
    );
end entity HeartBeat;

architecture rtl of HeartBeat is
    constant c_HALF_PERIOD_COUNT : positive :=
        c_CLK_FREQ_HZ / (2 * c_BLINK_HZ);

    signal count         : natural range 0 to c_HALF_PERIOD_COUNT - 1 := 0;
    signal heartbeat_int : std_logic := '0';
begin
    assert c_CLK_FREQ_HZ >= 2 * c_BLINK_HZ
        report "Heartbeat frequency must be no greater than half the clock frequency"
        severity failure;

    process (clk, reset_n)
    begin
        if reset_n = '0' then
            count         <= 0;
            heartbeat_int <= '0';
        elsif rising_edge(clk) then
            if count = c_HALF_PERIOD_COUNT - 1 then
                count         <= 0;
                heartbeat_int <= not heartbeat_int;
            else
                count <= count + 1;
            end if;
        end if;
    end process;

    heartbeat <= heartbeat_int;
end architecture rtl;
