library ieee;
use ieee.std_logic_1164.all;

-- Stable Vivado IP Integrator module-reference boundary. Keep this entity in
-- ordinary VHDL; the independently testable implementation uses VHDL-2008.
entity HeatBeat_Wrapper is
    port (
        clk       : in  std_logic;
        reset_n   : in  std_logic;
        heartbeat : out std_logic
    );
end entity HeatBeat_Wrapper;

architecture rtl of HeatBeat_Wrapper is
    attribute X_INTERFACE_INFO      : string;
    attribute X_INTERFACE_PARAMETER : string;

    attribute X_INTERFACE_INFO of clk : signal is
        "xilinx.com:signal:clock:1.0 clk CLK";
    attribute X_INTERFACE_PARAMETER of clk : signal is
        "XIL_INTERFACENAME clk, ASSOCIATED_RESET reset_n, FREQ_HZ 99999001";
    attribute X_INTERFACE_INFO of reset_n : signal is
        "xilinx.com:signal:reset:1.0 reset_n RST";
    attribute X_INTERFACE_PARAMETER of reset_n : signal is
        "XIL_INTERFACENAME reset_n, POLARITY ACTIVE_LOW";
begin
    implementation : entity work.HeartBeat(rtl)
        port map (
            clk       => clk,
            reset_n   => reset_n,
            heartbeat => heartbeat
        );
end architecture rtl;
