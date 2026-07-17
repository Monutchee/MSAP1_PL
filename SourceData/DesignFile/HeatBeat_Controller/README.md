# PL heartbeat

`HeatBeat_Controller.vhd` divides the PS-generated `pl_clk0` clock and drives
the PL-alive LED. Its defaults match the current `99,999,001 Hz` clock and
produce a one-hertz LED cycle.

`HeatBeat_Wrapper.vhd` is the stable ordinary-VHDL module-reference boundary
used by `StatusSignal.bd`. Keep it while that block design contains the
`HeatBeat_Wrapper_0` cell; changing the implementation does not require deleting
or reconnecting the cell.

Connect `clk` to `s_axi_aclk_0` and `reset_n` to `s_axi_aresetn_0` inside
`StatusSignal.bd`. The indicator then confirms that the primary PL clock,
reset distribution, and heartbeat logic are operating. It is diagnostic only
and must not be used for metering timing.

Run the mixed-language test and focused synthesis from the repository root:

```sh
vivado -mode batch -source SourceData/Script/AI_gen/check_heartbeat.tcl
```
