# CycleAggregator — HLS trial of the 150/180-cycle aggregator

A Vitis HLS (2025.2) implementation of the IEC 61000-4-30 150/180-cycle
aggregation contract, built to evaluate HLS as an implementation route
against the hand-written engine
(`SourceData/DesignFile/MeterProcessing/meter_cycle_aggregator.vhd`).
The functional rules — 15 eligible Basic results, `floor(sqrt(floor(
sum(x_i^2)/15)))` per RMS lane, `floor(sum(f_i)/15)` for frequency,
eligibility/seeding/continuity handling — are the RTL engine's, pinned by
its header comment and by `MeterCommon/measurement_record_bus_pkg.vhd`.

## Layout

- `src/cycle_aggregator.hpp` — normative AXI4-Stream beat layouts (808-bit
  Basic-result beat in, 968-bit aggregate beat out) and shared constants.
  `meter_cycle_aggregator_hls_shim.vhd` mirrors these offsets; keep them
  in lock step.
- `src/cycle_aggregator.cpp` — the engine. Area-shaped: serial divide by
  15 and multiplier-free restoring square root in PIPELINE-off loops
  (worst-case finalize ≈ 14 µs against a ~200 ms event period).
- `test/cycle_aggregator_tb.cpp` — port of the twelve scenarios from
  `tb/meter_cycle_aggregator_tb.sv`, with an independent binary-search
  golden root. Runs identically in C simulation and C/RTL co-simulation.
- `hls_config.cfg` — component configuration (part, 10 ns clock,
  `syn.rtl.reset=state` so `ap_rst_n` re-zeroes the counters like the RTL
  engine's `aresetn`).
- `../../run_hls.sh` (shared, component-agnostic) — csim → csynth →
  cosim → package, then unpacks the packaged IP into
  `../../ip_repo/CycleAggregator/`. Run it from inside this directory
  with no arguments, or from anywhere as
  `HLS_DesignFile/run_hls.sh MeterProcessing/CycleAggregator`.
- `../../ip_repo/` — the generated Vivado IP repository (NOT tracked).
  The product project consumes the engine as a packaged-IP customization:
  `ip_repo` is registered in `ip_repo_paths`, and the tracked XCI at
  `SourceData/IP/hls_cycle_aggregator_ip/` instantiates
  `monutchee:msap1:hls_cycle_aggregator:1.0` inside the MeterCore module
  reference (`SUPPORTS_MODREF=1`). The non-project check scripts compile
  the same packaged RTL directly from `ip_repo/CycleAggregator/hdl/
  verilog`, bound to the customization's module name by
  `DesignFile/MeterProcessing/tb/hls_cycle_aggregator_ip.v`.
  On a fresh checkout run `run_hls.sh` (or `make_HLS.sh`) before opening
  the Vivado project or running the metering check scripts.

  After ANY change to `src/` or `hls_config.cfg`: rerun `run_hls.sh`,
  then let Vivado pick up the new revision with
  `Script/refresh_hls_ip.tcl` (catalog rebuild + IP upgrade);
  `./make_HLS.sh` chains both automatically.
  `Script/register_hls_components.tcl` is the one-time (and
  idempotent) project registration, generic over every packaged
  component in `ip_repo` — it creates missing `SourceData/IP/<name>_ip`
  customizations from each package's own VLNV; only a new component's
  shim VHDL is added by hand. Vivado does not lock projects and a
  live GUI session saves its own state over batch edits, so when the
  project is open in a GUI, `source` these scripts in that session's Tcl
  console instead of batch mode.

## Interface

Free-running (`ap_ctrl_none`), never backpressures measurement. One input
beat per Basic result event; the configuration APPLY toggle level rides
inside the beat (bit `CAGG_IN_APPLY_TOGGLE_BIT`), sampled per event by
the shim. One output beat per completed aggregate carrying the result
plus the record/reset/ineligible/continuity counters as of that emit.
Accepted divergences from the RTL engine (sub-200-ms APPLY races the
product never performs) are documented in `cycle_aggregator.hpp`.

## Integration

`meter_core.vhd` instantiates the engine through
`MeterProcessing/meter_cycle_aggregator_hls_shim.vhd`, consuming the same
Basic result event as the RTL aggregator.
`MeterProcessing/meter_aggregator_compare.vhd` scores agreement whenever
both engines emit. The `HLS_AGGREGATE_PRODUCER` constant in
`meter_core.vhd` selects which engine's aggregates become MTR2 records —
currently this engine produces them, with the RTL engine running as the
compared reference (flip the constant to revert). Read-only registers in
the processing block (base `0xB0050000`): HLS record count `0x90`,
mismatch count `0x94`, shim drop count `0x98` (see
`measurement_record_bus_pkg.vhd`); the `AGG_*` health registers
`0x78`-`0x88` stay on the RTL engine.

## Verification

- `run_hls.sh`: C simulation and C/RTL co-simulation of the T1–T12 port.
- `check_metering_pipeline.tcl`: includes
  `tb/meter_aggregator_equivalence_tb.sv`, which drives the RTL engine
  and this engine (through the real shim) with identical stimulus and
  requires field-for-field agreement on every aggregate.
- `check_meter_core.tcl`, `check_metering_module_references.tcl`,
  `check_metering_synthesis.tcl`: cover the MeterCore integration.
- `compare_aggregator_synthesis.tcl`: side-by-side out-of-context
  utilization/timing of both implementations.

## Trial results (2025.2, xck26-sfvc784-2LV-c, 100 MHz)

Out-of-context synthesis:

| implementation      | LUT   | FF    | DSP | BRAM | WNS (ns) |
|---------------------|-------|-------|-----|------|----------|
| RTL engine          | 1,964 | 3,385 | 32  | 0    | +3.84    |
| HLS core            | 1,510 | 3,027 | 16  | 0    | +2.18    |
| HLS core + shim     | 1,496 | 4,629 | 16  | 0    | +2.18    |

Worst-case event latency: RTL ≈ 20 µs, HLS ≈ 14 µs — both irrelevant
against the ~200 ms Basic result period. The first untuned HLS schedule
cost 25k LUT / 84 DSP; the table's numbers required three area shapings
(PIPELINE-off serial arithmetic, explicit lane pack/unpack to avoid
variable-index barrel shifts on the wide beats, LUTRAM binding for the
accumulator array). See `doc/hls_cycle_aggregator_trial.md` for the full
comparison narrative.

## Extending (10-minute / 2-hour tiers, future HLS modules)

The 10-min and 2-h Class A tiers aggregate this block's output the same
way this block aggregates Basic results: reuse the beat pattern (result
beat in, aggregate beat out, counters in-beat), parameterize the block
count, and chain engines. New HLS components follow this folder's
template — component folder under `HLS_DesignFile/<area>/<Name>` with
`vitis-comp.json` (work_dir `build`), `hls_config.cfg` setting `syn.top`
and `package.ip.*`, beat layout in one header mirrored by one VHDL shim,
and an equivalence bench against a golden or RTL reference. No new build
or registration scripts: the shared `run_hls.sh` and `make_HLS.sh`
discover and build any component, and `register_hls_components.tcl`
creates its XCI from the package's own VLNV. The only per-component
integration work is the maintained shim VHDL (and, for a shadow
deployment, its compare wiring).
