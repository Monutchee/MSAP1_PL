# Measurement path HLS rewrite + AMD AXIS transport — implementation plan

Status: detailed implementation plan, revision 3, 2026-08-15, branch
`feat/hls_mtr1`. Supersedes revision 2 (same file, git history) after
design review resolved the open decisions:

- **Transport arbitration = AMD IP in the block design.** MeterCore
  exposes one standard AXIS master per producer; `axis_data_fifo`
  (packet mode) + `axis_switch` (arbitrate-on-TLAST) + the existing meter
  DMA live in `TopDesign.bd`. The custom VHDL FIFO/arbiter from rev 2 is
  dropped. Stock, well-verified AMD IP is preferred wherever the problem
  is standard streaming transport.
- **No backward compatibility required.** The system is pre-production
  and all components (PL, APU, RPU, kernel) ship together, so record
  maps, register semantics, and internal contracts may change freely as
  long as PL and software change in the same release. What we keep, we
  keep because it is *good*, not because it is deployed.
- **Maximize HLS.** Everything numerical or structural (calculation,
  record construction, serialization) moves to C++/Vitis HLS for
  readability and maintainability. VHDL remains only where the design
  touches hardware or owns sample-domain timing: ADC interface, capture,
  CDC, conversion, grid-cycle timing, register files.

## 1. Where we are today (as-built, verified 2026-08-15)

```
MeterResultHub_Wrapper          aggregate_record_producer
 (MTR1 assembler, VHDL)          (MTR2 assembler, VHDL)
        │                              ▲
        │                   CycleAggregator (HLS) + shim
        └────────────┬─────────────────┘
                     ▼
      measurement_record_arbiter        ← output registered since 85ee806
      (2:1, 2048b, fixed priority)
                     ▼
      MeterPacketizer_Wrapper (64-beat 32b serializer)
                     ▼
      AXIS 32b → AXI meter DMA S2MM → DDR ring (8 × 256 B)
```

Already true, so not part of this plan's work:

- The minimal fix for the live record-emission fault has landed
  (`85ee806` registered arbiter output; `ffac3eb` phase-sweep bench, 213
  alignments × 3 backpressure regimes, functionally exonerating the
  transport). The **72 h soak** remains — Gate G0, §3.
- MTR2 *calculation* is already HLS (CycleAggregator,
  `cycle_aggregator.hpp/.cpp` normative), consumed as a packaged-IP XCI
  inside the MeterCore module reference (`SUPPORTS_MODREF=1`), built by
  the generic `run_hls.sh` / `refresh_hls_ip.tcl` /
  `register_hls_components.tcl` flow. This plan reuses that entire
  toolflow unchanged.
- Waveform/bulk traffic already has its own DMA path (unchanged).

Constraints that stay binding because the *kernel framing* is positional
(these are current-release contracts, not legacy compatibility):

| Contract | Where enforced |
|---|---|
| One DMA period = one 256-byte record; no in-band boundary detection; a short packet leaves stale tail bytes **silently**, a long packet phase-shifts the ring **permanently** | `msap1_dma_meter.c:19,41` (256 B × 8 ring), `msap1_dma_core.c:177-179,275-333` |
| Userspace batches by `sizeof(MeterRecord)`; `static_assert(sizeof == 256)` | `meter_dma_reader.cpp:68-80`, `meter_record.hpp:243-245` |
| `header_valid()` = magic ∧ known format ∧ word 2 == 256 | `meter_record.hpp:112-119` |
| Continuity is tracked per format with independent counters; nothing depends on MTR1/MTR2 interleave order | `record_ingestor.cpp:152-157`, `record_ingestor.hpp:198-209` |
| RPU never touches record content (capture control + health mirrors only) | `MSAP1_RPU/common/include/metering.hpp:56-64` |

**The 64-beat / 256-byte packet invariant remains the hardest safety
requirement.** Every producer, HLS or otherwise, emits exactly 64 × 32-bit
beats with TLAST on beat 63, always.

## 2. Confirmed decisions

- **D1 — TDATA is 32-bit.** Confirmed after review. Rationale: (a) the
  record envelope and both word maps are *defined* in 32-bit words — a
  32-bit stream makes beat index ≡ word index, which keeps golden benches,
  ILA captures, and the APU's forensic word dumps trivially alignable;
  (b) the meter DMA and BD are already 32-bit — 64-bit would add a width
  converter or DMA reconfig purely to halve a beat count nobody is short
  of (aggregate record traffic is < 0.1 % of link bandwidth; a record
  drains in 0.64 µs either way); (c) narrower FIFOs and switch. 64-bit
  buys nothing here; revisit only if a future producer's *sustained* rate
  approaches link capacity (none planned does).
- **D2 — AMD AXIS infrastructure in the BD.** MeterCore exposes
  `M_AXIS_MTR1`, `M_AXIS_MTR2` (and later one master per producer);
  FIFO/switch/DMA wiring happens in `TopDesign.bd` (owner: block-design
  side — the PL work signals when the wrapper ports are ready; §8 has the
  exact IP configuration to apply).
- **D3 — the record envelope is kept, record interiors may change.**
  Word 0 magic / word 1 format / word 2 size=256 / word 3 per-producer
  sequence / 64-bit sample-domain timestamp stays — it is the right
  envelope and the kernel/APU framing is built on it. Interior word maps
  (counters, field placement) may be cleaned up during the HLS rewrite;
  `meter_record.hpp` and the decoder registry update in the same release.
- **D4 — framing stays positional, records stay 256 B.** Fixed geometry
  is load-bearing in kernel, reader, and validator; nothing about the HLS
  rewrite needs a different size. TKEEP is constant `0xF`.
- **D5 — new quantities (power, harmonics, …) are new producers/record
  types**, added through the §9 template after the MTR1/MTR2 rewrite
  lands. MTR1 today is mean/RMS/frequency; the rewrite reproduces that
  scope first.

## 3. Gate G0 — RESOLVED 2026-08-16: the soak failed

G0 asked whether the shim/event class is clean. **It is not.** Episode E
began 2026-08-16 00:54:55 UTC on the `85ee806` bitstream — deployment
verified by md5 chain end-to-end (`fa3450dc` .bit → SDT export →
`a58b7ddd` firmware .bin on target) — with the signature unchanged: one
basic record lost per window, that window's aggregate delivered **twice,
bit-perfect**, zero kernel overruns, zero drop counters anywhere.

What that buys, and what it costs:

- **The transport is now exonerated in hardware**, not merely in
  simulation. The registered arbiter is still correct and stays, but it
  was not the cause. §12's row "the un-exonerated shim/event fault class
  rides into the new architecture" is no longer a risk to watch — it is a
  **confirmed defect this plan must fix and prove fixed**.
- **The duplication was localized to the shim's event boundary.** Live
  registers during episode E: the HLS engine's own beat counters
  (`AGG_RECORD_COUNT` 0x7C and its mirror `HLS_AGG_REG_RECORD_COUNT`
  0x90, both carried *inside* the aggregate beat) advance **exactly once
  per window**, while the APU receives that aggregate **twice**. The
  doubling therefore happens after the core counts its output beat and
  before the record reaches the DMA — i.e. in the level→event conversion
  at `meter_cycle_aggregator_hls_shim.vhd:200-203`, which latches
  `out_valid = '1'` into a single-cycle event with **no edge detection**
  while `m_aggregate_TREADY` is hardwired `'1'`. Any TVALID lasting two
  cycles produces two identical events, hence two bit-perfect records.
- **Honest counterpoint that must be tested, not assumed:** a purely
  static version of that bug would duplicate *every* aggregate, always —
  not episodically. Either the core's TVALID duration is
  state/timing-dependent, or the trigger at that interface is physical.
  Do not treat the shim reading as proven until §11.0/REG-1 reproduces it.
- **The lost basic record is still functionally unexplained.** The hub
  and the shim consume the *same* `result_valid` net
  (`meter_core.vhd:731,768`); the engine demonstrably received slot-9's
  beat (its counters advanced) while the hub apparently did not emit that
  record. Divergent sampling of one fan-out net by two destinations is the
  remaining candidate — which is a *design-rule* problem (§11.2/INV-4),
  and the new architecture must not reproduce the pattern.

Consequences for this plan:

1. This rewrite is no longer only a scaling change; it is the **fix
   vehicle** for a live defect. It must therefore satisfy the
   reproduce-then-fix criterion (§11.0) rather than assume the rewrite
   incidentally cures it.
2. Every deploying step now carries the §11.8 hardware acceptance bar,
   and the APU forensics stay in place permanently (§11.4/CNT-4).
3. No hardware-deploying step is blocked on further soaking of `85ee806`
   — that experiment has returned its answer. The device continues to run
   it as a **fault generator**: episodes recur 2–4×/day and every one is
   now fully instrumented, so it remains the best available source of
   evidence while the rewrite proceeds.

## 4. Target architecture

```
        MeterCore module reference (VHDL shell, HLS engines inside)
┌──────────────────────────────────────────────────────────────────┐
│ AD7771 capture / conversion / source mux / CDC          (VHDL)   │
│ grid_cycle_timing, zero-crossing, frequency estimator   (VHDL)   │
│ sample-event shim: frames + block-close + provenance    (VHDL)   │
│        │                                                          │
│        ▼                                                          │
│ Mtr1Engine (HLS): accumulate → finalize → build MTR1              │
│   record → serialize                                              │
│        │ m_result (basic-result beats)     │ M_AXIS_MTR1 (32b)    │
│        ▼                                   │                      │
│ CycleAggregator (HLS, extended): aggregate │                      │
│   15 results → build MTR2 record → serialize                      │
│                                            │ M_AXIS_MTR2 (32b)    │
└────────────────────────────────────────────┼──────────────────────┘
                                             ▼   TopDesign.bd
                    axis_data_fifo ×N (packet mode, 32b)
                                             ▼
                    axis_switch (N:1, arbitrate-on-TLAST, round-robin)
                                             ▼
                    AXI meter DMA S2MM → DDR ring (8 × 256 B)
```

Retired to git history at cutover: `meter_rms`, `MeterResultHub_Wrapper`,
`aggregate_record_producer`, `measurement_record_arbiter`,
`MeterPacketizer_Wrapper`, and the result-beat half of
`meter_cycle_aggregator_hls_shim` (the aggregator then speaks
stream-to-stream with Mtr1Engine).

Placement decision — HLS engines stay **inside the MeterCore module
reference** (the proven CycleAggregator XCI pattern), not in the BD:
the BD boundary then carries only narrow, standard, stable AXIS
interfaces, and the whole metering pipeline (engines included) remains
simulable by the existing non-project xsim check scripts. The BD gets
only transport IP.

## 5. Common contracts (define first, everything depends on them)

### 5.1 Record envelope + shared C++ serializer

**Created 2026-08-16:** `SourceData/HLS_DesignFile/common/` — the
single-definition home for everything the engines share, so no value is
declared twice across HLS modules (`metering_types.hpp` geometry/types,
`basic_result_beat.hpp` the §5.4 beat, `measurement_record.hpp` the
envelope + word maps + `serialize_record<Format>`; rules and migration
map in its README; g++ unit test `common/test/run_test.sh` pins layouts
and framing). `measurement_record_bus_pkg.vhd` keeps a mirrored comment
block until the last VHDL consumer retires. Contents:

- Envelope: word 0 magic `0x3152544D`; word 1 format
  (`0x00010003` MTR1-v3, `0x00020002` MTR2-v2 — new words, since interiors
  change and nothing is deployed); word 2 size = 256; word 3 per-producer
  monotone sequence; 64-bit first-sample timestamp at a per-format fixed
  position. Format-word reservation table for energy/demand/harmonics/PQ
  lives here, agreed with `meter_record.hpp`.
- `template <uint32_t Format> void serialize_record(const RecordWords&,
  hls::stream<axis32_t>&)` — the handoff's shared-format/per-producer-
  instance helper: each engine synthesizes its own serializer from one
  implementation; 64 beats, TKEEP `0xF`, TLAST at 63, by construction.
- Counter model (the CycleAggregator precedent, now uniform): every
  producer's health counters **ride inside its record**; AXI-Lite mirrors
  are "as of the last emitted record". Cleaned MTR1-v3 interior: the six
  capture words (frames/header-errors/fifo-overflows/alerts) keep their
  block, words 12/13 become `emit_drops` (engine could not hand a record
  to transport) and `result_drops` (engine missed a window — must stay 0);
  the retired hub/packetizer counters disappear.

### 5.2 Never-backpressure rule, restated for HLS

Measurement is never stalled by transport. Concretely, each engine is a
free-running kernel (`ap_ctrl_none`) with `#pragma HLS DATAFLOW`:
`accumulate` (II=1 on sample beats) → internal result stream (depth 2) →
`emit` (serialize to `m_axis`). The accumulate process **never blocks on
emission**: it writes the result stream non-blocking; on full it drops
the completed result and increments `emit_drops`. The emit process may
stall on `m_axis` backpressure mid-record — bounded by the BD FIFO drain
(µs) and harmless because accumulation is decoupled. A partially-emitted
record cannot reach the DMA: the packet-mode FIFO forwards nothing until
TLAST arrives.

### 5.3 Sample-event beat (VHDL shim → Mtr1Engine)

One beat per accepted converted frame: 8 × 32b samples, valid mask, the
64-bit free-running sample index, `frame_closes_block`, and — on the
closing beat — the latched provenance (first-sample index, cycle count,
nominal Hz, flags), active generation, the frequency-block snapshot
(millihz/status/period/sequence from `meter_frequency`), and the capture
diagnostic counters. The RTL owns all timing decisions
(`grid_cycle_timing` marks the closing frame; the engine never re-derives
IEC boundaries). Layout is normative in `mtr1_engine.hpp`; the shim
mirrors it in lock step (the aggregator rule, `AGENTS.md`).

### 5.4 Basic-result beat (Mtr1Engine → CycleAggregator)

The existing `basic_measurement_result_t` content
(`measurement_record_bus_pkg.vhd:41-59`) becomes an HLS-to-HLS AXIS
stream: Mtr1Engine's `m_result` replaces the VHDL-assembled event the
aggregator's shim builds today. Same fields, one producer, one consumer,
defined in the shared header.

## 6. Mtr1Engine (new HLS component)

`SourceData/HLS_DesignFile/MeterProcessing/Mtr1Engine/` — CycleAggregator
layout: `src/mtr1_engine.hpp/.cpp` normative, `test/mtr1_engine_tb.cpp`,
`hls_config.cfg` (`part=xck26-sfvc784-2LV-c`, `clock=10ns`,
`syn.top=hls_mtr1_engine`), `vitis-comp.json`. `run_hls.sh` and the
registration script need nothing new.

Scope — a *rewrite*, not a port, of `meter_rms` + `MeterResultHub`:

- Per-channel Σx, Σx² across the block; mean-corrected RMS
  `sqrt((N·Σx² − (Σx)²)/N²)`, zero-referenced raw RMS counts, mean;
  128-bit accumulator widths and floor division/root semantics are
  **specified in the header and proven by the C golden model** — the
  contract is the math, not bit-equality with the retired VHDL.
- Config (dc_remove, valid mask, fallback window) commits on APPLY
  exactly as today (shim carries the toggle; first block after APPLY is
  flagged, config never changes mid-block).
- Builds and serializes the MTR1-v3 record itself
  (`serialize_record<MTR1_V3>`), emits `m_result` beats for the
  aggregator, maintains sequence + drop counters in-record.
- Performance envelope is generous: ≤ 32 kframes/s at 100 MHz ⇒ ≥ 3125
  cycles/frame; finalization has the ~200 ms block period. Apply the
  trial's area lessons from day one (serial arithmetic, explicit lane
  pack/unpack, LUTRAM bindings — the unshaped first schedule of the
  aggregator was 6× the final area; reviewing the csynth report is part
  of the exit criteria, not optional).

Validation without a hardware shadow (accepted, since nothing is
deployed): (a) C golden model + full stimulus set (constant/varying
inputs, DC offsets, mask changes, APPLY mid-block, fallback close,
overflow saturation, sequence wrap) as csim **and** cosim; (b) **captured
ADC vectors** from the bench target replayed through the C model,
compared offline against records produced by today's production
bitstream — real-data equivalence without a compare block or dual
deployment; (c) xsim integration bench through the real shim.

## 7. CycleAggregator extension (MTR2 all-HLS)

- New input: `s_basic` consumes Mtr1Engine's `m_result` stream (replaces
  the shim-assembled event beat). Aggregation math, eligibility rules,
  and counters are already HLS and unchanged.
- New output: builds and serializes the MTR2-v2 record itself
  (`serialize_record<MTR2_V2>`); `aggregate_record_producer.vhd` and the
  shim's result-beat adaptation retire.
- The twelve-scenario golden bench extends with record-image checks; the
  two documented APPLY-race divergences remain documented behavior.
- Migrates its local `CAGG_IN_*` beat constants to the common
  `basic_result_beat.hpp` (byte-identical; pinned by static_asserts in
  `common/test/`), and its `CAGG_OUT_*` beat retires with the shim's
  result half.
- Optional rename lands here if desired, since this step already rebuilds
  the packaged IP, XCI, shim, and bench bindings: prefer `Mtr2Engine`
  (named by the record it emits, matching `Mtr1Engine`; stays correct if
  the algorithm evolves, and future tiers get their own engine names) or
  `Cycles150_180Aggregator` (matches the APU `MeasurementPeriod` enum).
  Do not rename outside this step — the name is woven into the IP VLNV,
  `ip_repo/`, the tracked XCI, and the bench module binding, and churning
  that surface mid-incident costs comparability for zero function.

## 8. MeterCore boundary + block-design work (handoff checklist)

PL side exposes on `MeterCore_Wrapper` (X_INTERFACE_INFO attributes as on
the existing `M_AXIS_METER`, one interface per producer, all on `aclk`):

- `M_AXIS_MTR1`: `tdata(31:0)`, `tkeep(3:0)`, `tvalid`, `tready`, `tlast`
- `M_AXIS_MTR2`: same signal set

**Signal to the BD owner** comes when these ports exist and
`check_metering_module_references.tcl` passes. BD work then (IP
Integrator, then export the Tcl under `SourceData/Script/` per the repo
rule):

1. Two `axis_data_fifo`: TDATA 4 bytes, **packet mode = true** (nothing
   forwards until TLAST — this is the store-and-forward guarantee),
   depth 256 (4 records; one 18K BRAM each at most), single clock
   (`aclk`), HAS_TKEEP/HAS_TLAST = 1.
2. One `axis_switch`: NUM_SI = 2 (grows per producer), NUM_MI = 1,
   TDATA 4 bytes, **ARB_ON_TLAST = 1, ARB_ON_MAX_XFERS = 0** (grant locks
   until the packet's TLAST; round-robin among requesting slaves; no
   TDEST needed with a single master — software demuxes by format word).
3. `M_AXIS_MTR1 → fifo0 → switch S00`, `M_AXIS_MTR2 → fifo1 → switch
   S01`, `switch M00 → meter DMA S2MM` (replacing today's direct
   `M_AXIS_METER` connection; that port retires from the wrapper).
4. Validate BD, regenerate outputs, refresh the managed wrapper; ILA on
   the switch master + each FIFO's `prog_full`/counts as desired.

Growth rule (future producers): PL adds `M_AXIS_<NAME>`; BD adds one
FIFO + one switch slave port. No existing producer or IP is touched.

## 9. Future-producer template (energy / demand / harmonics / PQ events)

PL: one new HLS component (engine + `serialize_record<Format>` output) →
wrapper export → BD FIFO + switch port (events: depth 2048 / 32 records,
never newest-wins — burst records are individually precious; overflow is
a counted, in-record, sticky-flagged rarity).

APU (all six touch points are mandatory — from the ingestor survey):
`meter_record.hpp` format constant + accessors + `header_valid()`
whitelist; `MeterDecoderRegistry::with_builtin_decoders()`
(`meter_data.cpp:593-612`); a per-format arm in
`record_ingestor.cpp:389-393` continuity/caching; `RecordKind`
(`meter_data.hpp:26-32`, `power = 2` already reserved);
`MeasurementPeriod` + hardcoded `period_count = 4` (`meter_data.hpp:149`)
if a new period tier appears; fan-out (`meter_publication_catalog.cpp`,
`meter_history.cpp`, snapshot provider).

Decide **before** the PQ-event producer: does it share this ring or get
its own DMA channel (different burstiness/latency/retention — §13 Q2)?

## 10. Implementation order (commit-sized)

**Status 2026-08-16 (implementation session):** steps 1–6 are code-complete
on `feat/hls_mtr1`: both engines pass csim + C/RTL cosim and are packaged
(`Mtr1Engine` 10.0k LUT / 9.7k FF / 82 DSP; extended `CycleAggregator`
4.7k LUT / 4.4k FF / 16 DSP); the retired VHDL (meter_rms, hub,
arbiter, packetizer, aggregate producer, old shim, VoltageRms wrapper and
their benches) is deleted; meter_core/MeterCore_Wrapper rewired
(`M_AXIS_MTR1`/`M_AXIS_MTR2` exported); `record_word_tap` +
`meter_mtr1_hls_shim` added; check scripts and `meter_core_tb` retargeted;
a new whole-chain `meter_record_stream_tb` (TB-1/INV-1/INV-2/ADV-2)
guards the exported streams. It has already earned its keep: it caught a
real valid/ready deadly embrace between the two engines'
`register_mode=off` ports (raw HLS axis master gates TVALID on TREADY —
exactly the interface-class bug family of episode E) that C/RTL cosim
cannot see; fixed by restoring the m_result master's boundary register.
The full headless check matrix is green: both xsim suites
(`check_metering_pipeline`, `check_meter_core`), BD interface inference
(`M_AXIS_MTR1`/`M_AXIS_MTR2` inferred with correct clock associations),
and `check_metering_synthesis MeterCore_Wrapper` — **WNS +1.859 ns at
100 MHz, zero failing endpoints, zero critical warnings** (the retired
record path lived at ~0.5 ns), 15.8k LUT / 24.0k FF / 15.5 BRAM /
112 DSP for the whole MeterCore. IMP-1 holds: no record-path endpoint
near the worst slack. Remaining before step 8:
`register_hls_components.tcl` in the project session (new
`hls_mtr1_engine_ip` XCI + aggregator XCI upgrade — run it in the GUI's
Tcl console if the project is open there, per the repo rule), then the
§8 block-design wiring.

1. **[now]** §5 contracts: **headers created and unit-tested**
   (`SourceData/HLS_DesignFile/common/`, 2026-08-16); remaining: the
   MTR1-v3/MTR2-v2 maps and format-word reservation table reviewed and
   agreed with the APU side (§13 Q4) — a review gate, not code.
2. **[now]** Mtr1Engine C model + golden bench, csim green; capture ADC
   vectors from the bench target and run the offline record comparison
   (§6 b) against the current bitstream's records.
3. **[G0 completes]** incident closing entry.
4. Mtr1Engine cosim + csynth shaping; sample-event shim VHDL
   (`meter_mtr1_hls_shim.vhd`); xsim integration bench.
5. CycleAggregator extension (§7): `s_basic` input + MTR2-v2 packet
   output; extended golden bench; cosim.
6. MeterCore rewire: shim → Mtr1Engine → CycleAggregator chain in;
   `meter_rms` / hub / arbiter / packetizer / `aggregate_record_producer`
   out; export `M_AXIS_MTR1/MTR2`; full check-script matrix
   (`check_metering_pipeline`, `check_meter_core`,
   `check_metering_module_references`,
   `check_metering_synthesis MeterCore_Wrapper`).
7. **→ signal the BD owner**; BD wiring per §8; BD validation; bitstream;
   implementation timing/resource delta recorded.
8. APU/RPU same-release updates: `meter_record.hpp` v3/v2 maps + decoder
   registry + ingestor; RPU health-mirror register list if the AXI-Lite
   map changed. (Kernel driver: no change — geometry is identical.)
9. On-target soak ≥ 72 h: zero rejection events, `invalid_records` and
   `sequence_gaps` flat, health `healthy`; scoreboard the per-format
   sequence continuity under sustained collision (MTR1×MTR2 alignment
   happens naturally every 15th block).
10. First new producer through §9 (recommend harmonics or energy —
    periodic, shallow FIFO, exercises the template without the PQ burst
    questions); PQ events last, after §13 Q1/Q2.

## 11. Verification — test criteria

This section is prescriptive because the 2026-08-13..16 fault passed
every test the project had. Criteria below are numbered so steps in §10
can cite them as exit gates, and so a reviewer can check coverage rather
than judge effort.

### 11.0 Evasion analysis — why the existing suite missed a live defect

| Fault property | Why the suite missed it | Criterion that closes it |
|---|---|---|
| Duplication originates in the VHDL shim's level→event conversion | The phase-sweep bench (`ffac3eb`) drove the *record producers* directly; shim and packaged HLS core sat outside the test boundary | TB-1 (boundary includes real IP), TB-2 (no stubs on the fault path) |
| Requires TVALID held ≥ 2 cycles | Nothing ever held a valid high: HLS cosim drives its own well-behaved handshake, and the xsim benches pulsed valids for one cycle | ADV-1 (valid-duration sweep) |
| One basic record disappears with no counter movement | No test asserted events-in ⇒ records-out; benches checked record *content*, never *conservation* | INV-1 (exactly-once), CNT-1..3 (counter honesty) |
| Two consumers of one event strobe diverge | No rule and no test about event fan-out | INV-4 (fan-out equality), DR-3 (design rule) |
| Episodic, not static | Simulation cannot express it; only hardware can | HW-1..3 (acceptance soak with statistical basis) |
| Recurred for three days across two bitstreams before being characterized | Loss was silent end-to-end; forensics had to be built mid-incident | CNT-4 (forensics are a product feature, not a debug aid) |

**Reproduce-then-fix (REP).** Before the rewrite is credited with fixing
the live defect, one of the following must hold, and which one must be
stated in the incident log:

- **REP-A (preferred):** the duplicate is reproduced in simulation
  against the *packaged* CycleAggregator IP through the current shim —
  e.g. `m_aggregate_TVALID` observed high ≥ 2 consecutive cycles with
  TREADY = 1, yielding two identical events. The new architecture then
  demonstrably lacks the mechanism, and REG-1 pins it forever.
- **REP-B:** simulation cannot reproduce it (the interface is
  functionally clean at every alignment), in which case the cause is
  physical at that interface, the rewrite's claim rests on removing the
  interface rather than on a proven mechanism, and HW-1 is the *only*
  evidence of cure. This must be written down explicitly, not implied.

### 11.1 Test boundary (TB)

- **TB-1 — the integration bench spans the whole chain, with real IP.**
  From injected sample/block-close events through the *packaged* HLS
  components (bound exactly as the build binds them — the
  `hls_cycle_aggregator_ip.v` wrapper pattern in
  `check_metering_pipeline.tcl`) to the exported `M_AXIS_MTR1` /
  `M_AXIS_MTR2` beats. Behavioural stand-ins for an engine are permitted
  only in *unit* benches, never in the integration bench.
- **TB-2 — no stub may sit on a path that has ever produced a field
  fault.** Any module between a measurement event and the DMA stream is
  in-boundary, permanently.
- **TB-3 — the bench drives only what the hardware drives.** Stimulus
  enters at the sample/event boundary; nothing may inject directly into
  a producer's record port, because that is precisely the shortcut that
  hid this defect.

### 11.2 Global invariants (INV) — asserted in *every* bench, always on

- **INV-1 — exactly-once conservation.** For N injected block-close
  events: exactly N MTR1 packets, exactly ⌊N/15⌋ MTR2 packets, each
  sequence value appearing **exactly once**, sequences strictly monotone
  per format. Duplicates and losses are equally fatal. (This single
  assertion detects the entire observed fault family.)
- **INV-2 — framing.** Every packet is exactly 64 beats; TLAST only on
  beat 63; TKEEP constant `0xF`; word 0 magic, word 1 a known format,
  word 2 == 256. A packet of any other length fails the run.
- **INV-3 — no interleave.** Between a packet's first beat and its TLAST,
  no beat from another producer appears on the shared stream.
- **INV-4 — event fan-out equality.** Where one event strobe feeds
  multiple consumers, each consumer's observed event count is asserted
  equal at end of run. (Direct regression for the unexplained basic-record
  loss.)
- **INV-5 — record content is golden.** Word-for-word comparison against
  the model for every emitted record, not merely header spot-checks.

### 11.3 Adversarial interface suite (ADV) — for every valid/ready interface in the chain

- **ADV-1 — valid-duration sweep.** Hold the producing side's TVALID for
  1, 2, 3, 5, 8, 64 consecutive cycles (with TREADY high) and assert
  **exactly one** event/record results per logical item. *This is the
  direct regression for the episode-E duplication mechanism and is
  mandatory on every level→event conversion in the design.*
- **ADV-2 — ready-stall sweep.** Deassert TREADY for 0..80 cycles at
  every beat position within a packet; assert TDATA/TLAST hold stable,
  no beat is lost or repeated, and the packet completes intact.
- **ADV-3 — alignment sweep.** Every relative offset of MTR1 vs MTR2
  emission across a full packet drain (the `ffac3eb` methodology,
  re-targeted at the exported masters), under three TREADY regimes:
  always-ready, 50 % duty, LFSR-random.
- **ADV-4 — back-to-back.** Producers emitting with zero idle gap, and a
  producer emitting again during another's drain.
- **ADV-5 — reset/recovery.** Reset asserted mid-packet: after release,
  the first packet is complete and well-framed (no half packet reaches
  the DMA).
- **ADV-6 — SVA protocol binding.** Bind AXIS property checks to every
  stream interface (TVALID stable until TREADY; payload stable while
  stalled; no TLAST outside beat 63) so violations fail *any* bench that
  happens to exercise them, not only the bench written for them.

### 11.4 Counter honesty (CNT)

Every drop counter in the current design read **zero through five
episodes** while records vanished. Counters that are never tested are
decoration.

- **CNT-1 — every discard path increments a counter.** No code path may
  silently drop, replace, or skip a record or event.
- **CNT-2 — every counter has a test that forces its condition and
  asserts it increments.** A counter without such a test fails review.
- **CNT-3 — accounting identity per stage**, asserted at end of run:
  `accepted = emitted + dropped` for each stage, and end-to-end
  `events_in = records_out + drops_total`.
- **CNT-4 — end-of-chain forensics are permanent.** The APU rejection
  logging (raw words on every rejection path, suppression-counted) and
  the per-format continuity tracking stay in the product. They are the
  only reason this fault was characterized at all; they are not debug
  scaffolding to be removed after the rewrite.

### 11.5 Regression corpus (REG) — field faults become permanent tests

Each entry is a named test case that must run in CI forever:

- **REG-1 — aggregate duplication.** Level→event conversion with a
  multi-cycle valid produces exactly one record (see ADV-1). Derived from
  episodes A–E.
- **REG-2 — basic-record loss at a fixed window slot.** Inject 15×N
  block-close events; assert no MTR1 sequence is absent, with the
  scoreboard reporting slot-mod-15 of any miss (the diagnostic that
  identified the stuck slot).
- **REG-3 — hybrid record.** No emitted record may mix fields from two
  logical sources; enforced by INV-5 golden comparison plus an explicit
  check that a record's timing/sample-index words are never zero when its
  header is valid (the exact 2026-08-15 signature).
- **REG-4 — exit burst.** After any injected disturbance, the stream
  resumes with no multi-record gap: the burst-loss signature
  (`(1 − slot) mod 15 + 1` records) must be unreproducible by
  construction.
- **REG-5 — 64-beat framing under every stall pattern** (ADV-2/ADV-5),
  because a short packet is silent in the kernel and a long one
  permanently phase-shifts the ring.

### 11.6 Per-engine HLS verification (unchanged, plus)

- C golden bench (csim + cosim, unchanged test source); captured-vector
  offline comparison for Mtr1Engine; record-image checks; area/timing
  review of every csynth report.
- **New:** cosim must include a TREADY-stalling and a
  TVALID-observation case — the default cosim driver's well-behaved
  handshake is what let ADV-1's failure mode survive. Where cosim cannot
  express it, the RTL integration bench must (TB-1).

### 11.7 Implementation gates (IMP)

- **IMP-1 — no record-path endpoint in the design's worst-100 timing
  paths.** Should be trivially true once nothing wider than 32 bits
  crosses a producer boundary.
- **IMP-2 — design rules (DR), checkable by review or script:**
  - **DR-1** no wide (> 32-bit) combinational path terminating in a
    capture register across a module boundary;
  - **DR-2** every module boundary is a registered valid/ready handoff;
  - **DR-3** no event strobe fans out combinationally to two consumers —
    each consumer gets its own registered copy or its own stream;
  - **DR-4** no level→event conversion without explicit edge detection;
  - **DR-5** store-and-forward at packet granularity (only complete
    packets are forwarded).
- **IMP-3 — resource/timing delta vs the current build recorded** in the
  step's commit message.

### 11.8 Hardware acceptance (HW)

- **HW-1 — soak with a stated statistical basis.** The current fault
  recurs 2–4×/day; a clean interval of **72 h** is ≳ 8× the longest
  observed inter-episode gap and ≳ 200× the mean. Acceptance = 72 h with
  zero `meter_record_stale_rejected` / `_config_rejected` /
  `_decode_rejected`, `invalid_records` flat, `sequence_gaps` flat,
  health `healthy`. Record the boot time and leave the environmental
  sampler running.
- **HW-2 — no change during the soak.** One variable, one system. Any
  reflash, config apply, or unnecessary reboot restarts the clock; do
  not reboot after a suspected event before collecting the journal
  (volatile storage).
- **HW-3 — A/B where possible.** If the fault generator is still
  available on the old bitstream, run the new build against the same
  grid/thermal conditions; identical conditions with opposite outcomes is
  much stronger evidence than absence alone.
- **HW-4 — block accounting on target.** `RESULT_SEQ == aggregates × 15
  + ineligible + in-flight` must reconcile exactly at spot checks
  throughout the soak (the check that exonerated the PL computation
  pipeline in every episode).

### 11.9 Transport IP configuration

`axis_data_fifo` / `axis_switch` are trusted as verified AMD IP; their
*configuration* is what this project verifies: packet-mode enabled
(store-and-forward, DR-5), arbitration on TLAST (INV-3), depths per §9,
and a BD-level simulation smoke test with packet-interleave attempt and
DMA-side backpressure. On target, any `emit_drops` movement at product
rates is a fault (CNT-3).

## 12. Risks

| Risk | Mitigation |
|---|---|
| Non-64-beat packet desynchronizes the DMA ring (silent for short packets) | `serialize_record` emits 64 beats by construction; packet-mode FIFO forwards only complete packets; global sim assertion; release blocker |
| Numerical regression vs the proven `meter_rms` (no bit-exact gate anymore) | Math contract specified in the header; golden model; **captured-vector offline comparison against production records** before cutover |
| HLS area blow-up (trial saw 6× before shaping) | Trial lessons applied from day one; csynth review is an exit criterion per step |
| Beat-layout drift between C++ and the VHDL shim | One normative header; shim mirrors in lock step; integration bench catches drift (the aggregator rule) |
| Emit-path stall backpressures measurement | §5.2 dataflow decoupling + non-blocking result handoff + `emit_drops`; accumulation cannot stall by construction |
| **The shim/event defect is confirmed live (§3) and could be reproduced by any new event plumbing** | DR-3/DR-4 make the mechanism unrepresentable; ADV-1 tests every level→event conversion; REP forces the mechanism to be reproduced or its absence of proof stated; INV-1 fails the build on any duplicate |
| The rewrite is credited with a cure it did not deliver (fault is physical at an interface the rewrite happens to move) | REP-B must be written down explicitly when reproduction fails; HW-1/HW-3 are then the sole evidence and are treated as such in the incident log |
| The basic-record loss has no identified functional mechanism, so a rewrite may carry it forward | INV-4 + DR-3 target the fan-out pattern directly; REG-2 fails on any absent sequence and reports its slot |
| Big-bang cutover (engine + transport + record maps in one release) | Nothing is deployed to production; staged *verification* replaces staged deployment: steps 2/4/5 each have their own green gate before step 6 integrates |
| BD/PL interface churn per new producer | Bounded and mechanical: one wrapper port + one FIFO + one switch port; documented growth rule (§8) |

## 13. Open questions

1. FIFO depths: 4 records for periodic producers confirmed cheap; what
   is the real worst-case PQ-event burst (drives the 32-record figure)?
2. PQ events: shared ring or own DMA channel? Decide before that
   producer exists.
3. Frequency estimator (`meter_frequency`): stays VHDL now (proven,
   observational, sample-domain zero-crossing capture is
   hardware-adjacent). Candidate for a later HLS migration of the
   *estimator arithmetic* only — worth it, or leave permanently?
4. MTR1-v3 interior word map: exact cleaned layout to be fixed in
   `measurement_record.hpp` at step 1 and reviewed against
   `meter_record.hpp` accessors before any RTL work.
