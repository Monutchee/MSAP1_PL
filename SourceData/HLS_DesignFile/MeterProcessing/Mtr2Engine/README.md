# Mtr2Engine — the 150/180-cycle aggregation engine

The Vitis HLS (2025.2) implementation of the IEC 61000-4-30 150/180-cycle
aggregation contract and the meter's production MTR2 record source. It
consumes the MTR1 engine's basic-result beats and emits complete MTR2-v2
records (`0x00020002`) on a 32-bit AXIS stream — aggregation, record
construction, and serialization in one IP. The functional rules — 15
eligible Basic results, `floor(sqrt(floor(sum(x_i^2)/15)))` per RMS lane,
`floor(sum(f_i)/15)` for frequency, the eligibility/seeding/continuity
handling — are pinned by `src/mtr2_engine.hpp` (normative) together with
the shared contracts in `../../common/include/`.

History: born as the `CycleAggregator` trial against a hand-written VHDL
engine and promoted after a bit-exact compared hardware deployment
(numbers in `doc/hls_cycle_aggregator_trial.md`; the RTL engine, the
compare block, the event-beat output, and the old event shim all live in
git history).

## Layout

- `src/mtr2_engine.hpp` — normative contract; the input beat and record
  map come from `../../common/include/` (`basic_result_beat.hpp`,
  `measurement_record.hpp`) so nothing is defined twice across engines.
- `src/mtr2_engine.cpp` — the engine. Area-shaped: serial divide by 15
  and the shared multiplier-free restoring root (`mtr_math.hpp`) in
  PIPELINE-off loops; worst-case finalize ≈ 14 µs against a ~200 ms
  event period.
- `test/mtr2_engine_tb.cpp` — the twelve golden scenarios (originally
  ported from the retired RTL engine's bench) with an independent
  binary-search root, now checking every emitted record word-for-word.
  Runs identically in C simulation and C/RTL co-simulation.
- `hls_config.cfg` — part, 10 ns clock, `-I../../common/include`,
  `syn.rtl.reset=state` so `ap_rst_n` re-zeroes the counters.
- Build/registration: the shared component-agnostic flow — `run_hls.sh`
  (csim → csynth → cosim → package → `../../ip_repo/Mtr2Engine/`),
  `refresh_hls_ip.tcl`, `register_hls_components.tcl` (tracked XCI at
  `SourceData/IP/hls_mtr2_engine_ip/`, `SUPPORTS_MODREF=1`); `mnc HLS
  build` chains everything. Non-project check flows bind the packaged
  RTL via `DesignFile/MeterProcessing/tb/hls_mtr2_engine_ip.v`.

## Interface and integration

Free-running (`ap_ctrl_none`); never backpressures measurement. One
`basic_result_beat_t` in per Basic result (the APPLY toggle level rides
inside the beat); one 64-beat MTR2-v2 record out per completed aggregate,
TLAST on beat 63 (`serialize_record`, the DMA-ring framing invariant by
construction). Diagnostics ride in record words 33..35 and the sequence
word; `record_word_tap` republishes them to the `AGG_*` registers, "as of
the last emitted aggregate". Accepted APPLY-race divergences are
documented in `src/mtr2_engine.hpp`.

`meter_core.vhd` hosts the engine through the thin
`MeterProcessing/meter_mtr2_hls_shim.vhd` (the structural twin of the
MTR1 shim: it only instantiates the packaged IP and adapts the boundary
signals — deliberately no buffering and no event conversion). Verified
by the engine's own csim/cosim bench, the whole-chain
`tb/meter_record_stream_tb.sv`, `check_meter_core.tcl`, and the
module-reference/synthesis checks.

## Extending (10-minute / 2-hour tiers)

The higher Class A tiers aggregate this engine's tier the same way this
engine aggregates Basic results: reuse the pattern — result stream in,
records out via `serialize_record<new format>`, counters in-record — with
a new format word from the reservation table in
`common/include/measurement_record.hpp` and a new engine folder following
this template. No new build or registration scripts are needed.
