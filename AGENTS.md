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
  boundary. Its VHDL hierarchy owns AD7771 capture, runtime conversion, VLA
  frequency measurement, grid-cycle timing for IEC 61000-4-30 basic
  measurement blocks (`MeterProcessing/grid_cycle_timing.vhd`, contract in
  `MeterCommon/grid_timing_pkg.vhd`), the raw ADC simulator/source mux, the
  MTR1 sample-beat shim (`MeterProcessing/meter_mtr1_hls_shim.vhd`), and the
  record-stream register taps (`MeterProcessing/record_word_tap.vhd`). The
  metering numerics and record construction/serialization are Vitis HLS
  engines hosted inside this hierarchy; each producer's finished 256-byte
  record stream leaves `MeterCore_Wrapper` as its own AXIS master
  (`M_AXIS_MTR1`, `M_AXIS_MTR2`) into per-producer packet-mode FIFOs and an
  AXIS switch in `TopDesign.bd`.
- The conversion stage owns the 64-bit free-running sample index (low word in
  `TUSER[31:0]`, high word in `TUSER[105:74]`). It is the measurement
  timebase: never reset it on configuration apply and never step it for time
  synchronization. MTR1 format `0x00010002` references it in words 60/61 and
  the waveform correlation block latches it for Linux UTC mapping (the
  BASIC-v4 record keeps those words).
- Grid-cycle timing registers live in the processing block: `GRID_SHADOW_CONFIG`
  `0x6C`, `GRID_ACTIVE_CONFIG` `0x70`, `GRID_STATUS` `0x74` (RPU-owned,
  committed by the shared `CONTROL.APPLY` toggle). Like the frequency and
  waveform branches, grid timing is observational: it must never backpressure
  ADC capture, RMS, or basic-record production.
- All record producers are Vitis HLS engines that build and serialize
  their own records: the single-cycle engine
  (`SourceData/HLS_DesignFile/MeterProcessing/SingleCycleEngine`,
  SCYC-v5 `0x000A0005`), the 10/12-cycle merge tier
  (`.../Agg10_12CycleEngine`, `agg10_12_cycle_engine.hpp`/`.cpp`
  normative — it consumes SingleCycleResult beats, never raw samples,
  retired the sample-domain Mtr1Engine in M7, and emits four records
  per block on one stream: BASIC-v4 `0x00010004`, POWER-v1 `0x00070001`,
  PHASOR-v1 `0x00080001`, UNBAL-v1 `0x00090001`) and
  the 150/180-cycle aggregation engine (`.../Agg150_180CycleEngine`,
  `agg150_180_cycle_engine.hpp`/`.cpp` normative — consumes the 10/12
  tier's block-result beats (provenance + merge-safe accumulators,
  `agg_block_result.hpp`) and emits four records per aggregate: AGG-v3
  `0x00020003`, AGG-POWER `0x00100001`, AGG-PHASOR `0x00110001`,
  AGG-UNBAL `0x00120001`; Mtr2Engine and the 808-bit basic beat retired
  in M11, the hand-written RTL engines live in git history). Shared
  contracts -- the 256-byte record envelope and word maps, the
  SingleCycleResult and block-result beats, the shared interval finalize
  (`metrology_finalize.hpp`), and the serial math -- are single-defined in
  `SourceData/HLS_DesignFile/common/include/` and mirrored by any VHDL
  shim in lock step. Aggregates are formed from exactly 15 eligible Basic
  results -- never from raw samples or a wall-clock timer -- and
  aggregate data never travels over RPMsg. Like every metrology observer
  the engines must never backpressure measurement (the single-cycle
  shim's beat FIFO absorbs finalize latency and counts any overflow; on a
  dead reference grid timing keeps cycle boundaries running synthetically
  at nominal cadence so the whole chain keeps producing flagged results).
  Health registers `0x24`-`0x2c` and `0x78`-`0x98` in the processing
  block are "as of the last emitted record" (the counters ride inside the
  records, republished by `record_word_tap`); `AGG_STATUS` `0x78` and the
  reserved mismatch register `0x94` read zero, and `0x98` now counts
  single-cycle shim FIFO drops. Never wire two
  `register_mode=off` HLS axis ports directly together: a raw HLS axis
  master gates TVALID on TREADY (AXI-illegal) and deadlocks against a
  TVALID-gated reader -- keep the boundary register on every HLS axis
  master.
- `SourceData/HLS_DesignFile/` holds Vitis HLS components: C++ sources are
  the design input; the shared `HLS_DesignFile/run_hls.sh [component]`
  verifies one component (csim + C/RTL cosim), packages the IP, and unpacks
  it into the generated (untracked) Vivado IP repository
  `SourceData/HLS_DesignFile/ip_repo/`. Nothing in the flow is
  per-component: new components need no new scripts. The project consumes
  each engine as a packaged-IP customization: `ip_repo` is registered in
  `ip_repo_paths` and tracked XCIs under `SourceData/IP/<name>_ip/`
  instantiate the packaged definitions inside the MeterCore module
  reference (`SUPPORTS_MODREF=1`); only the `.xci` is tracked, its output
  products are not. The non-project check scripts compile the packaged RTL
  directly from `ip_repo/<Name>/hdl/verilog` with the module-name binding
  in `DesignFile/MeterProcessing/tb/hls_agg10_12_cycle_engine_ip.v`,
  `hls_single_cycle_engine_ip.v`, and `hls_agg150_180_cycle_engine_ip.v`. A fresh
  checkout must run `mnc HLS build` (or `HLS_DesignFile/run_hls.sh`) first;
  the check scripts fail with that instruction when the repository is
  absent. After any HLS source change: `run_hls.sh`, then
  `Script/refresh_hls_ip.tcl` (catalog rebuild + upgrade of stale
  HLS IP customizations) -- `mnc HLS build` chains both.
  `Script/register_hls_components.tcl` is the idempotent, generic
  registration for every packaged component (XCIs are created as
  `SourceData/IP/<name>_ip` from each package's own VLNV; only a new
  component's shim VHDL is added by hand). Vivado does not lock projects and a live GUI
  session saves its own state over batch edits: when the project is open in
  a GUI, source these scripts in that session's Tcl console, never batch.
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
  frequency, or basic-record production. Its short XPM FIFO may drop waveform frames
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
- The full build is staged, one Tcl script per stage under
  `SourceData/Script/` (`build_bd.tcl`, `build_synth.tcl`, `build_impl.tcl`,
  `build_bitstream.tcl`, `export_xsa.tcl`), driven by the workspace
  `mnc PL build` (`--build-bd`, `--compile-synth`, `--compile-impl`,
  `--compile-bit`, `--gen-xsa`, `--sdtgen`; no option runs all of them in
  that order). Add a new build stage as its own script with the shared
  `build_common.tcl` preamble and an `mnc PL build` option, not as a step folded
  into an existing stage: each stage must stay separately rerunnable.
  `build_bd.tcl` exists because the block design's output products are
  untracked, so a fresh checkout has no synthesizable block-design sources.
  Generating them normalizes two tracked files -- the top wrapper's generated
  `--Date` header and the `.bd`'s stored `xci_name`/`xci_path` entries -- so
  expect those diffs on a first build; neither is a design change, and the
  stage never calls `make_wrapper`.
  `build_impl.tcl` stops at `route_design` and `build_bitstream.tcl` resumes
  `impl_1` without resetting it, so a bitstream rerun never discards routing.
  The scripts above under `AI_gen/` remain the focused, non-project checks.
- Vitis HLS re-stamps a component's `coreRevision` on every packaging run, so
  after any HLS rebuild the tracked `SourceData/IP/<name>_ip/*.xci` trails its
  definition and Vivado locks it; a locked IP cannot be generated and fails
  synthesis inside the module reference that instantiates it. `build_bd.tcl`
  and `build_synth.tcl` rebuild the catalog and upgrade a locked `monutchee:*`
  customization themselves, and `build_synth.tcl` refuses to launch while any
  IP is still locked. Expect the `.xci` to show as modified after an HLS
  rebuild: `upgrade_ip` rewrites its `ip_revision`, and the file is tracked.
- `report_status.tcl` and `report_summary.tcl` (`mnc PL status`,
  `mnc PL summary`) are read-only views: they use `open_project -read_only` and so
  are the only project-wide scripts that may run while a Vivado GUI holds the
  project. Keep them read-only, and keep them free of any query that a
  read-only open falsifies -- `IS_LOCKED` is the known one, because a
  read-only project reports every IP as locked.
- For cycle-aggregator changes, `HLS_DesignFile/run_hls.sh` (or
  `mnc HLS build`) runs the twelve-scenario golden bench as C simulation and
  C/RTL co-simulation on the generated core, and `check_meter_core.tcl`
  validates a complete MTR2 record through the shim and engine inside the
  real pipeline.
- Implementation must complete timing/CDC/DRC/I/O review and exports the
  bitstream-inclusive XSA to `../runtime-generated/bin_file/MSAP1_PL.xsa`.

## Maintaining this file

- Update this `AGENTS.md` in the same change when durable hierarchy, interface,
  address-map, generated-source, or verification conventions change.
- Keep run-specific warnings and bring-up results in reports or test/status
  documentation rather than here.
