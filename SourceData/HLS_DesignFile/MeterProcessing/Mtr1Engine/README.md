# Mtr1Engine — the MTR1 basic (10/12 cycle) measurement engine

The Vitis HLS (2025.2) rewrite of the retired VHDL pair
`meter_rms.vhd` + `MeterResultHub_Wrapper.vhd` (git history): per-channel
accumulation over one IEC 61000-4-30 basic block, block finalization
(mean, mean-corrected RMS, raw-count RMS with 128-bit accumulators and
floor/truncate semantics), MTR1-v3 record construction (`0x00010003`),
and AXIS serialization — one IP, three streams. It is the meter's sole
MTR1 record source and the sole producer of the basic-result beats the
MTR2 aggregation engine consumes.

## Layout

- `src/mtr1_engine.hpp` — normative contract: the 1264-bit sample beat
  layout (mirrored in lock step by
  `DesignFile/MeterProcessing/meter_mtr1_hls_shim.vhd`), the arithmetic
  and window rules pinned to the retired RTL, and the accepted
  divergences. Record map and result beat come from
  `../../common/include/` so nothing is defined twice across engines.
- `src/mtr1_engine.cpp` — the engine: single-shot free-running process
  (the proven cosim-safe pattern); serial per-lane arithmetic
  (PIPELINE-off loops, shared divider/root from `metrology_math.hpp`);
  finalize ≈ 15 µs inline against the ~200 ms block cadence, absorbed by
  the shim's 8-deep beat FIFO. Both AXIS masters keep their boundary
  registers — a raw HLS axis master gates TVALID on TREADY (AXI-illegal)
  and deadlocks against a TVALID-gated reader.
- `test/mtr1_engine_tb.cpp` — golden bench with an independent
  binary-search root and content-addressed record matching; covers
  saturation, truncation-toward-zero means, masks, defensive clears,
  APPLY, cycle/legacy closes, and drop stress. Runs identically in C
  simulation and C/RTL co-simulation.
- `hls_config.cfg` — part, 10 ns clock, `-I../../common/include`,
  `syn.rtl.reset=state`.
- Build/registration: the shared component-agnostic flow — `run_hls.sh`
  (→ `../../ip_repo/Mtr1Engine/`), `refresh_hls_ip.tcl`,
  `register_hls_components.tcl` (tracked XCI at
  `SourceData/IP/hls_mtr1_engine_ip/`, `SUPPORTS_MODREF=1`); `mnc HLS
  build` chains everything. Non-project check flows bind the packaged
  RTL via `DesignFile/MeterProcessing/tb/hls_mtr1_engine_ip.v`.

## Interface and integration

Free-running (`ap_ctrl_none`); never backpressures measurement. One
sample beat in per accepted converted frame (grid_cycle_timing owns every
block boundary — the close marker and close-latched provenance ride the
beat); one 64-beat MTR1-v3 record out per closed block, TLAST on beat 63
(`serialize_record`); one `basic_result_beat_t` out per block for the
MTR2 engine. Health counters ride in the record (words 11/12 are
constant 0 by construction: emission is blocking and every close is
finalized); `record_word_tap` republishes them to the processing
registers. Hosted by `meter_mtr1_hls_shim.vhd`, which stages each frame
one cycle so a closing beat carries its own block's just-latched
provenance, buffers up to eight beats across the inline finalize, and
mirrors the APPLY commit for the register file.

Verified by the engine's own csim/cosim bench, the whole-chain
`tb/meter_record_stream_tb.sv`, `check_meter_core.tcl`, and the
module-reference/synthesis checks.
