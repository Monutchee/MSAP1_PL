# HLS trial: 150/180-cycle aggregator

**Date:** 2026-08-11 · **Tools:** Vitis/Vivado 2025.2 · **Part:**
xck26-sfvc784-2LV-c (KR260) · **Clock:** 100 MHz metering `aclk`

## What was built

A Vitis HLS implementation of the IEC 61000-4-30 150/180-cycle
aggregation contract
(`SourceData/HLS_DesignFile/MeterProcessing/CycleAggregator`), integrated
into `meter_core` as a compared shadow of the production RTL engine. Both
engines consume the identical internal Basic result event; a compare
block scores field-for-field agreement on every aggregate into three new
read-only processing registers (`0x90` HLS record count, `0x94` mismatch
count, `0x98` shim drop count). The RTL engine remains the only MTR2
producer, so the record stream, the APU decoder, and the RPU contract are
untouched. No block-design or address-segment change was needed: the
trial lives entirely inside the MeterCore module-reference hierarchy.

## Verification status (all green)

| Stage | Result |
|---|---|
| C simulation, T1–T12 port of the RTL unit test + independent golden root | PASS |
| C/RTL co-simulation of the generated core (236 events, 12 aggregates) | PASS |
| `meter_aggregator_equivalence_tb` — RTL vs HLS through the real shim, xsim | PASS |
| `check_metering_pipeline.tcl` (all six unit benches) | PASS |
| `check_meter_core.tcl` (MeterCore + shadow + registers, mixed language) | PASS |
| `check_metering_module_references.tcl` (BD interface inference) | PASS |
| `check_metering_synthesis.tcl MeterCore_Wrapper` (with shadow inside) | PASS |

## Resource and timing comparison

Out-of-context synthesis at 100 MHz
(`Script/AI_gen/compare_aggregator_synthesis.tcl`; both engines meet
timing comfortably):

| Implementation | LUT | FF | DSP | BRAM | WNS |
|---|---|---|---|---|---|
| RTL engine (`meter_cycle_aggregator`) | 1,964 | 3,385 | 32 | 0 | +3.84 ns |
| HLS core (`hls_cycle_aggregator`) | 1,510 | 3,027 | 16 | 0 | +2.18 ns |
| HLS core + integration shim | 1,496 | 4,629 | 16 | 0 | +2.18 ns |

Worst-case per-event latency: RTL ≈ 20 µs (bit-serial divide + 64-step
binary-search root per channel), HLS ≈ 14.2 µs. Both are irrelevant
against the ~200 ms Basic result period; neither engine can be caught
busy by the next event.

Reading the table honestly:

- The **HLS core beats the RTL engine on LUTs (−23%) and DSPs (−50%)**.
  The DSP halving is algorithmic, not magic: the C implementation uses a
  multiplier-free restoring square root, while the RTL binary search
  spends a second 64×64 multiplier (16 DSPs) on squaring midpoints. The
  same algorithm swap in VHDL would close that gap.
- The **shim costs ~1.2k flip-flops**: the 808-bit event capture register
  and the 968-bit result latch that adapt the record-style event boundary
  to AXI4-Stream beats. That is the real price of mixing paradigms, and
  it recurs for every HLS module that shadows an event-style RTL block.
- **Out-of-the-box HLS was 6× worse than the table**: the first
  unconstrained schedule cost 25k LUT / 9.5k FF / 84 DSP because HLS
  optimized latency we do not need (divide-by-15 as a 132×134 reciprocal
  multiplier, fully unrolled square root). Three deliberate area shapings
  were required: PIPELINE-off serial arithmetic, explicit lane
  pack/unpack so the wide beats are wired instead of barrel-shifted, and
  a LUTRAM binding to stop Vivado spending 2 RAMB36 on 924 bits of
  accumulator. HLS productivity is real, but only with an engineer who
  reads the reports.

## Functional equivalence

Bit-exact agreement with the RTL engine on every aggregate field and on
the record/ineligible/continuity counters across the full unit-test
stimulus (constant/varying inputs, both nominals, fallback, generation /
nominal / rate changes, sample and sequence discontinuities, APPLY,
maximum magnitude, invalid frequency, sequence wrap). Two accepted
divergences, both requiring APPLY races inside one ~200 ms block period
that the product never performs (documented in `cycle_aggregator.hpp`):
an APPLY landing in the exact cycle of a Basic result event, and a double
APPLY with no intervening Basic result. `reset_count` is therefore
excluded from the hardware compare; everything else is compared.

## Effort comparison

| | RTL engine | HLS trial |
|---|---|---|
| Engine source | 518 lines VHDL | 413 lines C++ (incl. the normative beat-layout header) |
| Adaptation | — | 239-line VHDL shim + 120-line compare block |
| Unit verification | SV bench + golden model | C bench reused for csim **and** cosim; equivalence bench closes the loop |
| Change turnaround | edit → xsim | edit → `run_hls.sh` (~2 min) → integrate script → xsim |

The C testbench running unchanged against both the model and the
generated RTL is the standout workflow win; the snapshot/integration
choreography (HLS renames generated submodules on micro-architecture
changes) is the standout friction.

## Recommendation

For this block class — slow event rates, wide fixed-point arithmetic,
strict contracts — HLS is viable and competitive after area shaping, and
clearly faster to iterate on the *arithmetic*. The event-boundary
adaptation (shim + FF cost) and the generated-file churn are the recurring
taxes. For the planned 10-minute and 2-hour tiers, which reuse this exact
beat pattern with a different block count, extending the HLS component is
the natural next step: the shim pattern amortizes, and the C testbench
tiers stack. Keep the RTL engine as the production MTR2 producer until
the shadow has accumulated real hardware hours with
`HLS_AGG_MISMATCH_COUNT == 0` and `HLS_AGG_DROP_COUNT == 0`.

## Rebuild / re-verify

```sh
# From the workspace root: rebuild + verify + refresh the Vivado IP catalog.
<workspace>/mnc HLS build
# Or component-local, then refresh Vivado separately:
SourceData/HLS_DesignFile/run_hls.sh MeterProcessing/CycleAggregator
vivado -mode batch -source SourceData/Script/refresh_hls_ip.tcl
# Checks:
vivado -mode batch -source SourceData/Script/AI_gen/check_metering_pipeline.tcl
vivado -mode batch -source SourceData/Script/AI_gen/check_meter_core.tcl
vivado -mode batch -source SourceData/Script/AI_gen/check_metering_synthesis.tcl -tclargs MeterCore_Wrapper
vivado -mode batch -source SourceData/Script/AI_gen/compare_aggregator_synthesis.tcl
```

*(2026-08-11, later: the project now consumes the engine as a packaged-IP
customization — `HLS_DesignFile/ip_repo` + the XCI under `SourceData/IP/` —
instead of direct generated-Verilog references; `SUPPORTS_MODREF=1` was
verified for the packaged IP inside the MeterCore module reference.)*
