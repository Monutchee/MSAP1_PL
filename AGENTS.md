# MSAP1 PL repository guidance

## Purpose and source ownership

- This repository contains the Vivado 2025.2 design for the KR260 MSAP1
  platform. Read `README.md` for the version-control workflow.
- AD7771 RTL, its module-reference wrapper, and its design notes are in
  `SourceData/DesignFile/Ad7771Capture/`. Maintained integration and validation
  Tcl lives in `SourceData/Script/`.
- `TopDesign.bd` is the implementation top. `AdcSubSystem.bd` is a block-design
  container for ADC control and capture-facing logic.
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
- AXI Quad SPI is the RPU-owned control path. The capture AXI-Lite registers and
  stream-to-memory DMA are also controlled by R5 core 0 during bring-up.
- Current addresses are AXI Quad SPI `0xB0010000`, capture registers
  `0xB0020000`, and AXI DMA `0xB0030000`. Address-map changes require a new XSA
  and coordinated RPU updates.
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
vivado -mode batch -source SourceData/Script/check_ad7771_capture.tcl
vivado -mode batch -source SourceData/Script/verify_ad7771_design.tcl
vivado -mode batch -source SourceData/Script/synth_ad7771_design.tcl
vivado -mode batch -source SourceData/Script/implement_ad7771_design.tcl
```

- Run the focused capture check for RTL changes and BD verification for any
  integration change. Run synthesis for interface, clock, reset, or constraint
  changes. Run implementation before handing a new XSA to RPU/Yocto.
- Implementation must complete timing/CDC/DRC/I/O review and exports the
  bitstream-inclusive XSA to `../runtime-generated/bin_file/MSAP1_PL.xsa`.

## Maintaining this file

- Update this `AGENTS.md` in the same change when durable hierarchy, interface,
  address-map, generated-source, or verification conventions change.
- Keep run-specific warnings and bring-up results in reports or test/status
  documentation rather than here.
