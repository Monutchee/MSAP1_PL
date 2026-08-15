# Measurement record transport redesign — per-producer stream FIFOs

Status: design proposal, not implemented. Prepared 2026-08-15.
Scope: `MeterProcessing` record transport (producers → DMA). No change to
record layouts, DMA geometry, kernel driver, or APU software.

## 1. Why change anything

Two independent drivers:

**(a) The wide combinational arbiter is timing-marginal and is the prime
suspect in a live field fault.** Since 2026-08-13 the device has shown
self-clearing episodes in which exactly one basic (MTR1) record per
aggregate window arrives at the APU **partially written** — valid header
words 0–5, zeroed tail (`first_sample_index = 0`, zero nominal frequency in
word 15). Aggregates (MTR2) are never affected. Kernel DMA overruns are
zero and PL block accounting reconciles exactly, so the record is produced
and delivered but malformed at emission. See
`MSAP1_DOC/raw_doc/incident_logs/2026-08-14/ANALYSIS.md`.

The structural asymmetry that explains "MTR1 only" lives in
`measurement_record_arbiter.vhd:40-45`:

```vhdl
m_valid_o  <= basic_valid_i or aggregate_valid_i;
m_record_o <= basic_record_i when basic_valid_i = '1'
              else aggregate_record_i;
```

The mux's **resting state is the aggregate record**. When MTR2 is captured
by the packetizer there is no bus transition at all — structurally immune.
When MTR1 is captured, all 2,048 bits must switch from the aggregate
record's contents to the basic record's within one cycle. Bits that settle
late are captured at their previous value, and the previous value on the
tail words is the MTR2 layout's zero region. The routed design reports
**WNS 0.584 ns / WHS 0.010 ns** — formally met, thin enough for
temperature and voltage drift to erode in silicon, which also explains
episodic onset with no software trigger.

**(b) The architecture does not scale to the planned producer set.** The
current arbiter is a 2:1 mux of 2,048 bits. Energy, demand, harmonics and
PQ events would make it 6:1 of 2,048 bits — a deeper LUT tree on the path
that is already the design's weakest. Scaling the present structure makes
the fault class *more* likely, not less.

## 2. As-built architecture (verified against RTL, 2026-08-15)

There is **no shared hub FIFO**. `MeterResultHub` is the MTR1 record
assembler, not a shared stage. Each producer already owns a private
depth-1 register with newest-wins replacement and a drop counter:

```
MeterResultHub_Wrapper        (1 × 2048-bit reg, newest-wins, hub_drop_count → word 13)
   │
   ├──────────────┐
   │              ├─→ measurement_record_arbiter ─→ MeterPacketizer_Wrapper ─→ AXIS 32b ─→ AXI DMA S2MM ─→ DDR
   │              │      (combinational 2:1 mux,     (active + pending regs,
aggregate_record_producer      2048 bits wide)        64-beat serializer,
   (1 × 2048-bit reg,                                 drop_count → word 12)
    newest-wins, drop → 0x8C)
```

Key properties of the as-built design, all of which the redesign must
preserve:

| Property | Where enforced today |
|---|---|
| Transport never backpressures measurement | producers accept every result, replace pending, count drops (`MeterResultHub_Wrapper.vhd:184-188`, `aggregate_record_producer.vhd:138-142`) |
| Exactly 256 bytes = 64 beats per record | `MeterPacketizer_Wrapper.vhd:47-50`, `word_index` 0..63, `tlast` at 63 |
| Loss is counted, never silent | hub drop → MTR1 word 13, packetizer drop → word 12, aggregate drop → `0x8C`, HLS shim drop → `0x98` |
| Record layout is normative | `measurement_record_bus_pkg.vhd` (MTR2 word map), `MeterResultHub_Wrapper.vhd:91-182` (MTR1) |

Downstream contracts that constrain any redesign:

- The kernel driver maps **one DMA period = one 256-byte record**
  (`msap1_dma_meter.c`, `period_bytes = 256`), cyclic ring. A packet that
  is not exactly 64 beats would permanently desynchronize the ring, not
  just corrupt one record. **This is the hardest safety requirement.**
- The APU validates `magic / format / size` and tracks continuity per
  format with independent sequence counters
  (`record_ingestor.cpp`), so inter-stream *ordering* is not contractual.

## 3. Proposed architecture

Serialize **before** arbitration, so nothing wide is ever muxed:

```
MTR1 producer   ─→ serializer ─→ 32-bit packet FIFO ─┐
MTR2 producer   ─→ serializer ─→ 32-bit packet FIFO ─┤
Energy          ─→ serializer ─→ 32-bit packet FIFO ─┤   packet-boundary
Demand          ─→ serializer ─→ 32-bit packet FIFO ─┼─→   arbiter      ─→ AXIS 32b ─→ AXI DMA ─→ DDR
Harmonics       ─→ serializer ─→ 32-bit packet FIFO ─┤  (round-robin,
Events          ─→ serializer ─→ 32-bit packet FIFO ─┘   store-and-forward)
```

`MeterPacketizer_Wrapper` retires; its serialization role moves into each
producer's serializer, and its buffering role into the per-producer FIFOs.

### 3.1 Why this removes the fault class

1. **The widest arbitrated path becomes 32 bits.** A 6:1 mux of 32 bits is
   a single LUT level per bit — timing ceases to be a consideration
   regardless of producer count.
2. **Store-and-forward makes partial records structurally impossible.**
   The arbiter may grant a producer only when its FIFO holds a *complete*
   record (tracked by a packet counter incremented on the writer's last
   word). A record cannot begin streaming before it is fully written, so
   the "valid front, zeroed tail" failure has no mechanism.
3. **No shared resting state.** Each stream owns its FIFO output register;
   there is no bus whose idle value belongs to another producer.

### 3.2 Component design

**Serializer (per producer), `record_serializer.vhd`**

- Port: `record_i : measurement_record_t; valid_i; ready_o` (producer side),
  `m_tdata(31:0); m_tvalid; m_tready; m_tlast` (FIFO side).
- On `valid_i`, latch the 2,048-bit record into a staging register and emit
  its 64 words over 64 cycles, `tlast` on word 63.
- `ready_o` is asserted whenever the staging register is free. If a new
  record arrives while busy, apply the **existing newest-wins policy** into
  a single pending slot and increment the producer's drop counter — the
  behaviour producers already implement, moved one stage later.
- Cost per instance: one 2,048-bit register + 64:1 32-bit mux (the same
  logic `MeterPacketizer_Wrapper` contains today, replicated N times).

*Alternative considered:* drive the FIFO directly from the producer's
source signals with a word-index mux, eliminating the 2,048-bit staging
register entirely. This is legal because all record inputs are stable for
~200 ms (block-close provenance is latched and held —
`MeterProcessing/README.md`, "Grid-cycle timing"), far longer than the
0.64 µs serialization. It saves ~2 kFF per producer but requires
restructuring each producer's assembly logic. **Recommendation:** use the
staging register for the two existing producers (their assembly logic is
proven and the record layout is normative — do not touch it during a fault
investigation); let new producers write directly if resources demand it.

**Packet FIFO (per producer)**

32-bit wide, depth per producer (§3.4), with a **packet-complete counter**
(increment on write of `tlast`, decrement on read of `tlast`) exposed to
the arbiter as `packet_available`.

*Recommendation: write it in VHDL (~80 lines over an inferred BRAM), not
Xilinx AXIS Data FIFO IP.* Rationale: this project's build variability has
already been implicated once in a regenerated/repackaged IP
(`hls_cycle_aggregator_ip.xci` revision bump in the bitstream under
investigation), and an inferred FIFO has no `.xci`, no regeneration
surface, no packaging state, and is fully visible to the testbench. The
same argument applies to the arbiter (§3.3).

Overflow policy: **tail-drop** (discard the incoming record when the FIFO
cannot hold a complete one) with a per-producer counter, applied at the
serializer's input so a partially-written record can never enter the FIFO.
Note this is a deliberate semantic change from today's newest-wins at the
producer: with a FIFO ≥ 2 records deep, newest-wins can no longer be
expressed cleanly, and tail-drop preserves a contiguous *prefix*, which is
friendlier to the APU's continuity tracking. Both policies produce a
sequence gap on the APU side, so no software behaviour changes.

**Packet arbiter, `record_stream_arbiter.vhd`**

- N × (32-bit AXIS slave + `packet_available`), one 32-bit AXIS master.
- Grants only at packet boundaries; once granted, the winner streams all 64
  beats to `tlast` before any re-arbitration. **Never interleave beats** —
  a mid-packet switch corrupts two records and desynchronizes the DMA ring.
- Policy: **round-robin among producers with `packet_available`**. At the
  product rates (MTR1 5/s, MTR2 0.33/s, everything else slower except event
  bursts) the aggregate load is < 0.1 % of the AXIS bandwidth, so policy
  affects only collision ordering. Round-robin is starvation-free by
  construction, unlike today's fixed priority, which matters once six
  producers exist.
- Ordering note: today basic strictly precedes aggregate at a collision.
  Under round-robin that order may vary. Verified safe: the APU tracks
  independent per-format sequence counters and the historian dedups by
  stream cursor, so no consumer depends on inter-stream order.

### 3.3 What must not change

- **64 beats per packet, always.** Assert it in RTL (a beat counter that
  flags any `tlast` not at index 63) and in the testbench. This is the DMA
  ring's alignment invariant.
- Record layouts and word maps (`measurement_record_bus_pkg.vhd`, MTR1
  assembly in `MeterResultHub_Wrapper.vhd`).
- Drop counters must remain visible in the same places (MTR1 words 12/13,
  AXI-Lite `0x8C` / `0x98`). Map the new per-producer counters onto them:
  producer drop → the existing per-producer register; the retired
  packetizer's drop counter (word 12) becomes the *arbiter/FIFO* drop total
  so the APU-visible field keeps its meaning.
- Measurement engines are never backpressured.

### 3.4 Sizing

| Producer | Rate | Burstiness | Suggested depth |
|---|---|---|---|
| MTR1 basic | 5/s | periodic | 4 records (256 words) |
| MTR2 aggregate | 0.33/s | periodic | 4 records |
| Energy | ≤ 1/s | periodic | 4 records |
| Demand | ≤ 1/min | periodic | 4 records |
| Harmonics | ≤ 1/s | periodic | 4 records |
| **Events** | bursty | **bursty** | 32+ records (2,048 words) |

Depth-1 is adequate for every periodic producer (the DMA drains a record in
0.64 µs), so FIFOs are justified almost entirely by the **event** producer,
where a disturbance can emit several records within milliseconds and
newest-wins would silently discard them.

Resources: one 18K BRAM covers 512 × 32-bit = 8 records, so the periodic
producers can share small distributed-RAM FIFOs (4 records = 256 × 32 b)
and only the event FIFO needs a BRAM. Net flip-flop usage is roughly
unchanged: the retired packetizer frees 2 × 2,048 FF, the serializers add
one staging register each.

## 4. Phasing

**Phase 0 — minimal fix (separate change, ships first).**
Register the arbiter output in `measurement_record_arbiter.vhd`: a proper
two-stage valid/ready handoff so the packetizer captures from a register
that settled a full cycle earlier. ~20 lines, no interface change, no
software impact. This is the targeted fix for the live fault and must not
wait for this redesign.

**Phase 1 — introduce the transport for the two existing producers.**
Add `record_serializer`, `record_packet_fifo`, `record_stream_arbiter`;
retire `MeterPacketizer_Wrapper`; rewire in `meter_core.vhd:837-862`.
Acceptance: `meter_packet_tb.sv` passes **unchanged** — the AXIS output for
the existing two-producer case must be byte-identical.

**Phase 2 — add producers one at a time**, each with its own serializer +
FIFO + arbiter port, its own testbench case, and its own drop counter.

Phases 1 and 2 should not begin until the live fault is confirmed fixed by
Phase 0 plus a soak — a restructure during an open investigation risks
masking rather than fixing.

## 5. Verification

**Unit**

- `record_stream_arbiter_tb`: simultaneous requests from all N ports; assert
  no interleaving (every granted packet delivers exactly 64 beats before any
  other port is granted), round-robin fairness over many rounds, and that a
  port with an incomplete FIFO is never granted.
- `record_packet_fifo_tb`: fill/drain, packet-complete accounting, tail-drop
  at capacity with counter increment, and that a dropped record never
  partially enters the FIFO.
- `record_serializer_tb`: word order equals the record layout, `tlast` at
  word 63 exactly, newest-wins on the pending slot, drop counting.

**Integration**

- `meter_packet_tb.sv` unchanged must pass (regression on record content and
  ordering for the two-producer case).
- New case: MTR1 and MTR2 asserted in the same cycle, repeated across every
  phase offset in a 64-beat window — the exact stress that the current
  combinational mux fails. Assert both records emerge intact.
- Global assertion for the whole simulation: every AXIS packet is exactly 64
  beats; `tlast` never appears at another index.

**Implementation**

- `report_timing` on the arbiter/FIFO paths; expect the record-path WNS to
  leave the critical-path list entirely (target: no record-transport path in
  the worst 100).
- Compare BRAM/LUT/FF deltas against the current build.

**On target**

- The APU rejection forensics already deployed (`meter_record_stale_rejected`,
  `meter_record_config_rejected`, `meter_record_decode_rejected` with raw word
  dumps) is the acceptance instrument: a soak of ≥ 72 h — longer than the
  longest observed inter-episode gap — with **zero** rejection events and
  `invalid_records` flat.

## 6. Risks

| Risk | Mitigation |
|---|---|
| A non-64-beat packet desynchronizes the DMA ring permanently | Store-and-forward + RTL beat-count assertion + simulation-wide assertion; treat as a release blocker |
| Restructure masks rather than fixes the live fault | Phase 0 first; confirm the fix on the current architecture before restructuring |
| Drop semantics change (newest-wins → tail-drop) | Documented; APU sees a sequence gap either way; counters preserved in the same fields |
| Round-robin changes collision ordering | Verified no consumer depends on inter-stream order (independent sequence counters, cursor dedup) |
| Resource growth from N serializers | Staging register optional (§3.2 alternative); measure in Phase 1 before adding producers |
| New IP regeneration variability | Custom VHDL for FIFO and arbiter — no `.xci`, no packaging state |

## 7. Open questions for review

1. FIFO depths — is 4 records right for the periodic producers, and what is
   the real worst-case event burst?
2. Should PQ events eventually get their own DMA channel? They differ in
   burstiness, retention and latency expectations; sharing one 256-byte
   cyclic ring may be the wrong long-term fit.
3. Does any planned producer need a record size other than 256 bytes? The
   current DMA period geometry makes a second size expensive (it would need
   a second channel), so this should be decided before Phase 2.
4. Arbitration tiers: should events preempt periodic producers at packet
   boundaries, or is round-robin sufficient given the bandwidth headroom?
