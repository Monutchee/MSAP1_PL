# Common HLS definitions

Single-definition home for everything more than one HLS component shares.
A value defined here is defined **nowhere else** in C++: components
include these headers instead of restating geometry, types, beat layouts,
or record word maps.

| Header | Owns |
|---|---|
| `include/metering_types.hpp` | channel geometry, IEC 61000-4-30 block geometry, block flags, scalar types (samples, Q16 lanes, micro-units, the 64-bit sample index) |
| `include/basic_result_beat.hpp` | the Basic result event beat (808 bits): layout constants, `basic_result_t`, explicit `pack`/`unpack` — the MTR1-engine → aggregator stream contract |
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
- **Shim lock-step.** Any VHDL shim that carries one of these beats
  mirrors the offsets here and says so at its declaration; the
  integration/equivalence benches catch drift (the aggregation-engine rule,
  `AGENTS.md`).
- **Software ships with hardware.** The record envelope and word maps
  bind the APU decoder (`MSAP1_APU common/msap1/meter/meter_record.hpp`).
  A change here and the APU change land in the same release — the kernel
  framing is positional, so there is no version negotiation on the wire.
- **Framing is inviolable.** 64 × 32-bit beats per record, TLAST on beat
  63, TKEEP full. `serialize_record` is the only sanctioned emitter.

## Status / migration map (2026-08-16)

| Definition | Current normative source | Migrates |
|---|---|---|
| Record envelope + MTR1-v3/MTR2-v2 maps | **normative here** — both engines emit them; APU-side review/update (plan §13 Q4) ships in the same release | PL side done |
| Basic result beat | **this header** (the MTR2 engine migrated at its record-output extension; the old `CAGG_IN_*` constants are gone) | done |
| Aggregate output beat (`CAGG_OUT_*`) | retired — the extended aggregator emits records, not beats | done |
| VHDL mirrors (`measurement_record_bus_pkg.vhd`, shim constants) | comment-linked mirrors | retire with their last VHDL consumer |

Plan: `doc/future_plan/measurement_record_transport_redesign.md` §5.

## Verifying

```sh
common/test/run_test.sh   # g++ csim-style unit test (layout pins, pack/unpack, serializer framing)
```

Runs with the Vitis include tree (`XILINX_VITIS`, default
`/opt/Xilinx/2025.2/Vitis`); no Vivado/Vitis license or project needed.
