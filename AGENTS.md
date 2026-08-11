# MSAP1 PL repository guidance

## Purpose and source ownership

- This repository contains the Vivado 2025.2 design for the KR260 MSAP1
  platform. Read `README.md` for the version-control workflow.
- AD7771 VHDL RTL, its ordinary-VHDL module-reference wrapper, SystemVerilog
  testbenches, and design notes are in `SourceData/DesignFile/Ad7771Capture/`.
  Maintained integration and validation Tcl lives in `SourceData/Script/AI_gen/`.
- Heartbeat VHDL RTL, its ordinary-VHDL module-reference wrapper, and its
  SystemVerilog testbench are in `SourceData/DesignFile/HeatBeat_Controller/`.
- `TopDesign.bd` is the only block design and owns the Zynq platform, the
  independent meter and waveform AXI DMA engines, AXI Quad SPI, AXI GPIO,
  heartbeat, fan routing, clocks, resets, and external ports.
- `SourceData/DesignFile/MeterCore/` is the single metering module-reference
  boundary. Its VHDL hierarchy owns AD7771 capture, runtime conversion, RMS
  processing, VLA frequency measurement, grid-cycle timing for IEC 61000-4-30
  basic measurement blocks (`MeterProcessing/grid_cycle_timing.vhd`, contract
  in `MeterCommon/grid_timing_pkg.vhd`), the raw ADC simulator/source mux, the
  result hub, and MTR1 packetization.
- The conversion stage owns the 64-bit free-running sample index (low word in
  `TUSER[31:0]`, high word in `TUSER[105:74]`). It is the measurement
  timebase: never reset it on configuration apply and never step it for time
  synchronization. MTR1 format `0x00010002` references it in words 60/61 and
  the waveform correlation block latches it for Linux UTC mapping.
- Grid-cycle timing registers live in the processing block: `GRID_SHADOW_CONFIG`
  `0x6C`, `GRID_ACTIVE_CONFIG` `0x70`, `GRID_STATUS` `0x74` (RPU-owned,
  committed by the shared `CONTROL.APPLY` toggle). Like the frequency and
  waveform branches, grid timing is observational: it must never backpressure
  ADC capture, RMS, or MTR1 production.
- The 150/180-cycle aggregator (`MeterProcessing/meter_cycle_aggregator.vhd`)
  consumes the internal Basic result event and publishes MTR2 records
  (`0x00020001`) through the measurement record bus
  (`MeterCommon/measurement_record_bus_pkg.vhd`, arbiter + producers in
  `MeterProcessing/`). Aggregate health registers occupy `0x78`-`0x8C` in the
  processing block. Aggregates are formed from exactly 15 eligible Basic
  results -- never from raw samples or a wall-clock timer -- and aggregate
  data never travels over RPMsg.
- `SourceData/HLS_DesignFile/` holds Vitis HLS components. The first is the
  cycle-aggregator trial (`MeterProcessing/CycleAggregator`): C++ sources are
  the design input; the shared `HLS_DesignFile/run_hls.sh [component]`
  verifies one component (csim + C/RTL cosim), packages the IP, and unpacks
  it into the generated (untracked) Vivado IP repository
  `SourceData/HLS_DesignFile/ip_repo/`. Nothing in the flow is
  per-component: new components need no new scripts. The project consumes the engine as a
  packaged-IP customization: `ip_repo` is registered in `ip_repo_paths` and
  the tracked XCI at `SourceData/IP/hls_cycle_aggregator_ip/` instantiates
  it inside the MeterCore module reference (`SUPPORTS_MODREF=1`); only the
  `.xci` under `SourceData/IP/` is tracked, its output products are not.
  The non-project check scripts compile the packaged RTL directly from
  `ip_repo/CycleAggregator/hdl/verilog` with the module-name binding in
  `DesignFile/MeterProcessing/tb/hls_cycle_aggregator_ip.v`. A fresh
  checkout must run `make_HLS.sh` (or `HLS_DesignFile/run_hls.sh`) first;
  the check scripts fail with that instruction when the repository is
  absent. After any HLS source change: `run_hls.sh`, then
  `Script/refresh_hls_ip.tcl` (catalog rebuild + upgrade of stale
  HLS IP customizations) -- `make_HLS.sh` chains both.
  `Script/register_hls_components.tcl` is the idempotent, generic
  registration for every packaged component (XCIs are created as
  `SourceData/IP/<name>_ip` from each package's own VLNV; only a new
  component's shim VHDL is added by hand). Vivado does not lock projects and a live GUI
  session saves its own state over batch edits: when the project is open in
  a GUI, source these scripts in that session's Tcl console, never batch. The trial
  engine runs in `meter_core` as a compared shadow of the RTL aggregator
  (`meter_cycle_aggregator_hls_shim` + `meter_aggregator_compare`), publishes
  no records, must never backpressure measurement, and reports through
  read-only registers `0x90`-`0x98` in the processing block. The AXI4-Stream
  beat layouts in `cycle_aggregator.hpp` and the shim must stay in lock step.
- Treat `SourceData` HDL, constraints, block designs, and maintained Tcl as
  design inputs. Treat `vivado_gen` runtime products and block-design generated
  HDL/IP products as regenerable unless explicitly tracked by the repository.

## AD7771 hardware contract

- The receiver accepts `ADC_DCLK`, the legacy-named `ADC_DRDY_N`, and four DOUT
  lanes, validates channel headers, sign-extends 24-bit samples, and emits
  32-bit AXI4-Stream beats in channel order 0 through 7. Frame capture starts
  only on the `ADC_DRDY_N` high-to-low transition; the low level must not be
  treated as a persistent frame-valid indication.
- Assert `TLAST` after the configured packet count. The default is 256 frames,
  2048 AXI beats, or 8192 bytes per DMA packet.
- AXI Quad SPI, capture, conversion, processing, and simulator AXI-Lite
  registers are RPU-owned. Linux exclusively owns both SG-enabled S2MM DMA
  engines and the waveform correlation/control registers.
- Current addresses are AXI Quad SPI `0xB0010000`, capture `0xB0020000`, AXI
  meter DMA `0xB0030000`, conversion `0xB0040000`, processing `0xB0050000`,
  waveform DMA `0xB0060000`, and waveform control `0xB0070000`. Address-map
  The raw ADC simulator/source-selection register block is `0xB0080000`.
  Address-map changes require a new XSA and coordinated Linux/device-tree
  updates; changes to RPU-owned segments also require coordinated RPU updates.
- The physical receiver and simulator both feed the raw 32-bit AXI4-Stream
  boundary before conversion. Only the selected source may receive `TREADY`,
  and software must stop capture before switching sources. CH7 remains present
  internally but is zero and invalid in the default simulator configuration.
- The raw waveform branch emits 64-byte WFM1 headers plus 1024 eight-channel
  frames. It is observational and must never backpressure ADC capture, RMS,
  frequency, or MTR1 production. Its short XPM FIFO may drop waveform frames
  and increment its counter when Linux is unavailable.
- Capture diagnostics expose the measured ADC DCLK rate at offset `0x2C` and
  the physical `ADC_DRDY_N` falling-edge rate at offset `0x30`. Both use
  one-second measurement windows and become valid after the baseline window.
- Preserve explicit clock-domain boundaries between ADC DCLK and the AXI clock.
  Do not suppress CDC or timing findings without documenting the actual path.

## Vivado change rules

- Do not hand-edit generated wrappers, BDC instance products, `.bxml`, `.bda`,
  output products, or run directories.
- Make block-design changes through Vivado IP Integrator or maintained Tcl,
  then validate, save, regenerate output products, and refresh the managed top
  wrapper.
- After GUI design changes, export the relevant project/block-design Tcl under
  `SourceData/Script/` so the intent remains reviewable and reproducible.
- Preserve unrelated GUI changes in the project and never delete or recreate a
  block-design container merely to hide an interface/clock validation error.

## Verification

Run from the repository root, escalating only as the change requires:

```sh
vivado -mode batch -source SourceData/Script/AI_gen/check_ad7771_capture.tcl
vivado -mode batch -source SourceData/Script/AI_gen/check_heartbeat.tcl
vivado -mode batch -source SourceData/Script/AI_gen/check_meter_core.tcl
vivado -mode batch -source SourceData/Script/AI_gen/check_meter_frequency.tcl
vivado -mode batch -source SourceData/Script/AI_gen/check_metering_pipeline.tcl
vivado -mode batch -source SourceData/Script/AI_gen/check_metering_synthesis.tcl -tclargs MeterCore_Wrapper
vivado -mode batch -source SourceData/Script/AI_gen/verify_ad7771_design.tcl
vivado -mode batch -source SourceData/Script/AI_gen/synth_ad7771_design.tcl
vivado -mode batch -source SourceData/Script/AI_gen/implement_ad7771_design.tcl
```

- Run the focused capture check for RTL changes and BD verification for any
  integration change. Run synthesis for interface, clock, reset, or constraint
  changes. Run implementation before handing a new XSA to RPU/Yocto.
- For cycle-aggregator changes (either implementation), the pipeline check
  runs the RTL unit test and the RTL/HLS equivalence test
  (`tb/meter_aggregator_equivalence_tb.sv`);
  `vivado -mode batch -source SourceData/Script/AI_gen/compare_aggregator_synthesis.tcl`
  produces the side-by-side utilization/timing comparison.
- Implementation must complete timing/CDC/DRC/I/O review and exports the
  bitstream-inclusive XSA to `../runtime-generated/bin_file/MSAP1_PL.xsa`.

## Maintaining this file

- Update this `AGENTS.md` in the same change when durable hierarchy, interface,
  address-map, generated-source, or verification conventions change.
- Keep run-specific warnings and bring-up results in reports or test/status
  documentation rather than here.
