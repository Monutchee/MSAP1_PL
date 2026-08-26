# Common HLS definitions

Single-definition home for everything more than one HLS component shares.
A value defined here is defined **nowhere else** in C++: components
include these headers instead of restating geometry, types, beat layouts,
or record word maps.

| Header | Owns |
|---|---|
| `include/metering_types.hpp` | channel geometry, IEC 61000-4-30 block geometry, block flags, scalar types (samples, Q16 lanes, micro-units, the 64-bit sample index) |
| `include/single_cycle_packet.hpp` | the 221-word SingleCycle sufficient-statistics packet consumed by the R5C1 interval owner |
| `include/measurement_record.hpp` | the 256-byte record: common envelope (words 0–12), format-word reservation table, MTR1-v3 / MTR2-v2 interior maps, `record_image_t`, `record_axis_t`, `clear_record`, `serialize_record<FORMAT>` |

## Using from a component

Add the include root next to the component's own `src` in
`hls_config.cfg` (paths are relative to the component directory):

```ini
syn.cflags=-Isrc -I../../common/include
tb.cflags=-Isrc -I../../common/include
```

`run_hls.sh` needs no change — flags travel with the component config.

## Rules

- **One definition.** If a constant is needed by two components, it moves
  here; a component-local copy is a review defect. Temporary duplicates
  during migration are listed below and carry a pinning `static_assert`
  in `test/common_headers_test.cpp` so they cannot drift silently.
- **Boundary lock-step.** Any PL/R5C1 boundary that carries one of these
  packets mirrors the offsets here and says so at its declaration; focused
  exporter and decoder tests catch drift.
- **Software ships with hardware.** The record envelope and word maps
  bind the APU decoder (`MSAP1_APU common/msap1/meter/meter_record.hpp`).
  A change here and the APU change land in the same release — the kernel
  framing is positional, so there is no version negotiation on the wire.
- **Framing is inviolable.** 64 × 32-bit beats per record, TLAST on beat
  63, TKEEP full. `serialize_record` is the only sanctioned emitter.

## Current ownership map (2026-08-25)

| Definition | Current normative source | Consumer |
|---|---|---|
| Record envelope + MTR1-v3/MTR2-v2 maps | **normative here** | R5C1 record construction and APU decoding |
| SingleCycle packet | `include/single_cycle_packet.hpp` | PL exporter and R5C1 interval owner |
| Interval aggregate state/result | `include/agg_block_result.hpp` | R5C1 only |
| VHDL boundary mirrors | `measurement_record_bus_pkg.vhd` and `meter_r5_aggregation_pkg.vhd` | PL-to-R5C1 packet export |

There is no PL aggregation implementation, packaged aggregation IP, shim, or
fallback branch. Historical trial and migration documents under `doc/` are
explicitly marked as superseded.

## Verifying

```sh
common/test/run_test.sh   # g++ csim-style unit test (layout pins, pack/unpack, serializer framing)
```

Runs with the Vitis include tree (`XILINX_VITIS`, default
`/opt/Xilinx/2025.2/Vitis`); no Vivado/Vitis license or project needed.
