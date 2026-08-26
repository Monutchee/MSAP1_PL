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
  single-cycle measurement engine, the R5C1 aggregation export, and the
  record-stream register taps (`MeterProcessing/record_word_tap.vhd`). The
  single-cycle metering numerics are implemented by Vitis HLS inside this
  hierarchy. In the production configuration R5C1 owns interval aggregation
  and returns finished 256-byte MTR1/MTR2 records through the bidirectional
  AXI FIFO MM-S into `MTR_AXI_Switch/S02_AXIS` in `TopDesign.bd`. The retired
  duplicate `M_AXIS_MTR1` and `M_AXIS_MTR2` wrapper interfaces do not exist.
  The compact record-switch order is S00 SingleCycle, S01 PQ, S02 R5C1
  return, and S03 harmonics.
- M16 harmonic acquisition is also owned inside `MeterCore_Wrapper`: the
  fixed 32 kSPS 16/25 polyphase conditioner, URAM-backed 4,096-frame ping/pong
  frontend, packaged `hls_harmonic_engine_ip`, XFFT fault handling, and
  4,096-word record FIFO are one hierarchy. The block design owns only one
  XFFT v9.1 customization connected through the wrapper's four `*_FFT_*` AXIS
  interfaces and six event scalars. Finished records leave on the dedicated
  `M_AXIS_HARMONIC` port and join `MTR_AXI_Switch/S03_AXIS`; do not merge them
  into `M_AXIS_PQ`. The production conditioner profile accepts only exact
  6,400-frame 10/12-cycle blocks at measured 32 kSPS. Other geometries emit
  no valid spectral window. Its read-only health window is `0xCC`--`0xE4` in
  `S_AXI_PROCESSING`.
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
- Each accepted converted frame reaches `SingleCycleEngine` as
  32 ordered little-endian 32-bit words through an AMD XPM asymmetric BRAM
  FIFO; the 1,024-bit sample image is a logical/storage-side frame only, not an
  HLS AXIS port. `SingleCycleEngine` produces the merge-safe SCYC-v5 logical
  result (`0x000A0005`) as a fixed packet of 221 ordered 32-bit words. The PL
  exporter appends 13 context words plus framing and CRC32C, then transfers
  the complete 239-word packet to R5C1. R5C1 owns the Basic 10/12-cycle,
  150/180-cycle, UTC 10-minute, 2-hour, and live-preview tiers around one
  serial finalizer. The narrow packet boundary is
  normative in `common/include/single_cycle_packet.hpp`; do not restore the
  retired 1,024-bit SingleCycle input beat, 7,072-bit result beat, or the
  7,488-bit widened RTL context beat. Do not replace the XPM packet FIFOs with
  custom pointer/memory RTL.
  Shared contracts -- the 256-byte record envelope and word maps, logical
  merge-safe sufficient-statistic images, the shared interval finalize
  (`metrology_finalize.hpp`), and serial math -- are single-defined in
  `SourceData/HLS_DesignFile/common/include/` and compiled by R5C1. The
  interval algorithm itself is owned by
  `MSAP1_RPU/R5c1/src/MainApp/aggregation/`; PL contains no aggregation
  implementation or fallback. Aggregates are formed from exactly 15 eligible
  Basic results --
  never from raw samples or a wall-clock timer -- and
  aggregate data never travels over RPMsg. Like every metrology observer
  the engines must never backpressure measurement (the single-cycle
  shim's beat FIFO absorbs finalize latency and counts any overflow; on a
  dead reference grid timing keeps cycle boundaries running synthetically
  at nominal cadence so the whole chain keeps producing flagged results).
  The shared record contract reserves BASIC-v4 timing bit 19 for the first
  UTC-resynchronized Basic, and AGG-v3 status bits 3/4 for the continuing
  overlap/new synchronized 150/180-cycle pair. AGG-v3 words 36/37 carry the
  actual last contributing sample because the continuing overlap record's
  summed contribution count can exceed its physical first-to-last span.
  Health registers `0x24`-`0x2c` remain "as of the last emitted SCYC
  record". The retired PL aggregation registers `0x78`-`0x94` read zero;
  `0x98` counts SingleCycle result-packet drops. Never wire two
  `register_mode=off` HLS axis ports directly together: a raw HLS axis
  master gates TVALID on TREADY (AXI-illegal) and deadlocks against a
  TVALID-gated reader -- keep the boundary register on every HLS axis
  master.
- R5C1 is the sole aggregation authority. `MeterCore_Wrapper` gives the
  exporter unconditional ownership of the SingleCycle handshake.
  `meter_r5_aggregation_export.vhd` receives the exact 221-word SingleCycle
  packet, captures its 13
  context words when result word 0 is accepted, and emits one complete
  239-word packet on `M_AXIS_R5_AGG_INPUT`. The packet contains a four-word
  integrity header, the exact 234-word aggregation input, and a CRC32C word.
  It is a private PL/R5C1 co-release contract: the fixed contract
  word detects a mixed bitstream/firmware image, but there is no negotiation,
  legacy decoder, or compatibility fallback. The exporter uses AMD XPM FIFOs
  and uses an explicit complete-packet credit before retaining word 0. When
  private-link storage is unavailable it still consumes the complete
  SingleCycle packet, discards that packet as one unit, and increments the
  sticky drop diagnostic. It must never deassert the upstream READY signal or
  backpressure metrology. R5C1 returns one complete
  256-byte record through the FIFO TX AXI stream into
  `MTR_AXI_Switch/S02_AXIS`. There is intentionally no PL runtime fallback
  when the co-released R5 image or FIFO path is unavailable.
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
  directly from `ip_repo/<Name>/hdl/verilog` with module-name bindings such as
  `DesignFile/MeterProcessing/tb/hls_single_cycle_engine_ip.v` and
  `hls_harmonic_engine_ip.v`. A fresh
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
vivado -mode batch -source SourceData/Script/AI_gen/check_r5_aggregation_export.tcl
vivado -mode batch -source SourceData/Script/AI_gen/check_metering_pipeline.tcl
vivado -mode batch -source SourceData/Script/AI_gen/check_metering_module_references.tcl
vivado -mode batch -source SourceData/Script/AI_gen/check_meter_record_switch.tcl
vivado -mode batch -source SourceData/Script/AI_gen/check_meter_record_transport.tcl
vivado -mode batch -source SourceData/Script/AI_gen/check_metering_synthesis.tcl -tclargs MeterCore_Wrapper
vivado -mode batch -source SourceData/Script/AI_gen/verify_ad7771_design.tcl
vivado -mode batch -source SourceData/Script/AI_gen/synth_ad7771_design.tcl
vivado -mode batch -source SourceData/Script/AI_gen/implement_ad7771_design.tcl
```

For a project created before M16, run `register_hls_components.tcl` and then
`register_m16_harmonic_sources.tcl` once before the PL build so both the
packaged HarmonicEngine IP and its maintained RTL boundary are in `sources_1`.

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
- For interval-aggregation changes, run the R5C1 focused host suite documented
  in `MSAP1_RPU/AGENTS.md`; PL verification covers only the SingleCycle packet
  and private exporter boundary.
- Implementation must complete timing/CDC/DRC/I/O review and exports the
  bitstream-inclusive XSA to `../runtime-generated/bin_file/MSAP1_PL.xsa`.

## Maintaining this file

- Update this `AGENTS.md` in the same change when durable hierarchy, interface,
  address-map, generated-source, or verification conventions change.
- Keep run-specific warnings and bring-up results in reports or test/status
  documentation rather than here.
