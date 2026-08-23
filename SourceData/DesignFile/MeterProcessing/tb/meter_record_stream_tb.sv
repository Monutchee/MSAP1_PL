`timescale 1ns/1ps

// Whole-chain record-stream integration bench (verification plan TB-1).
//
// Drives converted-frame beats through the REAL shims and the PACKAGED
// hls_single_cycle_engine and hls_aggregation_engine RTL (bound exactly as
// the build binds them) — the complete chain sample -> whole cycles ->
// 10/12-cycle blocks -> 150/180-cycle aggregate, to all three exported
// 32-bit AXIS record streams. Since A1 ONE engine owns both finalized
// tiers, so there is no longer an inter-tier beat to carry between two
// shims: the merged shim drives both record masters directly. No stubs
// anywhere on a path that has ever produced a field fault (TB-2), and
// stimulus enters only at the sample/event boundary (TB-3): the bench
// stands in for grid_cycle_timing, driving cycle boundaries explicitly.
//
// Checks, per the verification plan:
//   INV-1  exactly-once conservation: 160 whole cycles -> 16 BASIC, 16
//          POWER, 16 PHASOR, and 16 UNBAL records with sequences 1..16
//          (the block siblings share the BASIC sequence by design); 15
//          eligible blocks -> exactly one MTR2 record with sequence 1;
//          nothing extra.
//   INV-2  framing: every record is exactly 64 beats, TLAST only on beat
//          63, TKEEP full — checked beat-by-beat here and independently
//          by the record_word_tap framing watchdogs.
//   INV-5  golden content: every word of every BASIC/MTR2 record compared
//          against integer-exact expectations (constant DC per lane makes
//          mean, RMS, VLL, and the aggregate exact).
//   ADV-2  TREADY stall sweep: both checked record streams run against a
//          duty-cycled ready so beats are delivered under backpressure.
//   CNT    the single-cycle shim FIFO drop counter and the tap-published
//          drop words must end at zero; the MTR2 diagnostics must show
//          exactly the one ineligible (first-after-APPLY) block.
//
// Frame cadence is 600 clocks — comfortably above the engines' inline
// finalize divided by the 8-deep single-cycle shim FIFO, mirroring the
// real 3125-clock cadence contract (32 kSPS at 100 MHz).
module meter_record_stream_tb;
  logic clock = 1'b0;
  logic resetn = 1'b0;
  always #5 clock = ~clock;

  localparam int FRAMES_PER_CYCLE = 8;
  localparam int CYCLES_PER_BLOCK = 10;  // nominal 50 Hz
  localparam int BLOCKS = 16;
  localparam int FRAME_GAP = 600;
  localparam logic [31:0] GENERATION = 32'd1;
  localparam logic [31:0] SAMPLE_RATE = 32'd32000;
  localparam logic [7:0] VALID_MASK = 8'h7F;
  localparam longint FIRST_BLOCK_SAMPLE = 64'd1009;  // after carrier + sync

  // --- shim inputs ---------------------------------------------------------
  logic frame_accept = 1'b0;
  logic [383:0] frame_data = '0;
  logic [47:0] frame_keep = '1;
  logic [383:0] frame_user = '0;
  logic cycle_boundary = 1'b0;
  logic [31:0] cycle_sequence = 32'd100;
  logic cycle_mode = 1'b1;
  logic cycle_locked = 1'b1;
  logic cycle_fallback = 1'b0;
  logic [7:0] block_nominal = 8'd50;
  logic [2:0] block_flags = 3'b001;  // locked (single-cycle beat provenance)
  logic [31:0] shadow_generation = GENERATION;
  logic [31:0] shadow_sample_rate = SAMPLE_RATE;
  logic [7:0] shadow_valid_mask = VALID_MASK;
  // dc_remove off: with constant per-lane DC the mean, the RMS, the raw
  // RMS count, the VLL, and the 15-block aggregate are all integer-exact
  // and nonzero, so every channel word carries a distinctive value.
  logic shadow_enable = 1'b1;
  logic shadow_dc_remove = 1'b0;
  logic apply_toggle = 1'b0;
  logic [63:0] pl_tick = 64'd50_000;
  logic [31:0] freq_millihz = 32'd49991;
  logic [31:0] freq_status = 32'h0000_0032;  // VALID (bit 1) + mode bits
  logic [31:0] freq_period = 32'h0014_0007;
  logic [31:0] freq_sequence = 32'd77;
  logic [31:0] cap_frames = 32'd0;
  logic [31:0] cap_headers = 32'd1;
  logic [31:0] cap_overflows = 32'd2;
  logic [31:0] cap_alerts = 32'd3;

  // --- streams --------------------------------------------------------------
  wire [31:0] scyc_tdata;
  wire [3:0] scyc_tkeep;
  wire scyc_tvalid;
  wire scyc_tlast;
  wire [31:0] scyc_result_tdata;
  wire scyc_result_tvalid;
  wire scyc_result_tready;
  wire [31:0] basic_tdata;
  wire [3:0] basic_tkeep;
  wire basic_tvalid;
  logic basic_tready;
  wire basic_tlast;
  wire [31:0] mtr2_tdata;
  wire mtr2_tvalid;
  logic mtr2_tready;

  wire [3:0] mtr2_tkeep;
  wire mtr2_tlast;

  wire [31:0] active_generation;
  wire active_enable;
  wire apply_seen;
  wire [31:0] scyc_drop_count;

  meter_single_cycle_hls_shim scyc (
    .aclk(clock), .aresetn(resetn),
    .frame_accept_i(frame_accept),
    .frame_data_i(frame_data),
    .frame_keep_i(frame_keep),
    .frame_user_i(frame_user),
    .cycle_boundary_i(cycle_boundary),
    .cycle_sequence_i(cycle_sequence),
    .cycle_mode_i(cycle_mode),
    .block_nominal_hz_i(block_nominal),
    .block_flags_i(block_flags),
    .shadow_generation_i(shadow_generation),
    .shadow_sample_rate_i(shadow_sample_rate),
    .shadow_valid_mask_i(shadow_valid_mask),
    .shadow_enable_i(shadow_enable),
    .shadow_dc_remove_i(shadow_dc_remove),
    .config_apply_toggle_i(apply_toggle),
    .pl_tick_i(pl_tick),
    .frequency_millihz_i(freq_millihz),
    .frequency_status_i(freq_status),
    .m_axis_scyc_tdata(scyc_tdata),
    .m_axis_scyc_tkeep(scyc_tkeep),
    .m_axis_scyc_tvalid(scyc_tvalid),
    .m_axis_scyc_tready(1'b1),
    .m_axis_scyc_tlast(scyc_tlast),
    .m_result_tdata(scyc_result_tdata),
    .m_result_tvalid(scyc_result_tvalid),
    .m_result_tready(scyc_result_tready),
    .drop_count_o(scyc_drop_count)
  );

  meter_aggregation_hls_shim merge_tier (
    .aclk(clock), .aresetn(resetn),
    .s_result_tdata(scyc_result_tdata),
    .s_result_tvalid(scyc_result_tvalid),
    .s_result_tready(scyc_result_tready),
    .cycle_locked_i(cycle_locked),
    .cycle_fallback_i(cycle_fallback),
    .shadow_generation_i(shadow_generation),
    .shadow_sample_rate_i(shadow_sample_rate),
    .shadow_valid_mask_i(shadow_valid_mask),
    .shadow_enable_i(shadow_enable),
    .shadow_dc_remove_i(shadow_dc_remove),
    .config_apply_toggle_i(apply_toggle),
    .frequency_status_i(freq_status),
    .frequency_period_i(freq_period),
    .frequency_sequence_i(freq_sequence),
    .capture_frame_count_i(cap_frames),
    .capture_header_errors_i(cap_headers),
    .capture_overflows_i(cap_overflows),
    .capture_alerts_i(cap_alerts),
    .m_axis_basic_tdata(basic_tdata),
    .m_axis_basic_tkeep(basic_tkeep),
    .m_axis_basic_tvalid(basic_tvalid),
    .m_axis_basic_tready(basic_tready),
    .m_axis_basic_tlast(basic_tlast),
    .m_axis_agg_tdata(mtr2_tdata),
    .m_axis_agg_tkeep(mtr2_tkeep),
    .m_axis_agg_tvalid(mtr2_tvalid),
    .m_axis_agg_tready(mtr2_tready),
    .m_axis_agg_tlast(mtr2_tlast),
    .active_generation_o(active_generation),
    .active_enable_o(active_enable),
    .apply_seen_o(apply_seen)
  );

  // Independent framing watchdogs (the in-fabric register taps).
  wire basic_framing_error, mtr2_framing_error;
  wire [31:0] basic_tap_sequence, basic_tap_status, basic_tap_emit,
              basic_tap_result;
  wire [31:0] mtr2_tap_sequence, mtr2_tap_reset, mtr2_tap_inelig,
              mtr2_tap_cont;
  record_word_tap basic_tap (
    .aclk(clock), .aresetn(resetn),
    .tdata_i(basic_tdata), .tvalid_i(basic_tvalid),
    .tready_i(basic_tready), .tlast_i(basic_tlast),
    .sequence_o(basic_tap_sequence), .status_o(basic_tap_status),
    .emit_drops_o(basic_tap_emit), .result_drops_o(basic_tap_result),
    .reset_count_o(), .ineligible_count_o(), .continuity_count_o(),
    .framing_error_o(basic_framing_error), .framing_error_count_o()
  );
  record_word_tap #(.G_DIAG_FORMAT(32'h0002_0003)) mtr2_tap (
    .aclk(clock), .aresetn(resetn),
    .tdata_i(mtr2_tdata), .tvalid_i(mtr2_tvalid),
    .tready_i(mtr2_tready), .tlast_i(mtr2_tlast),
    .sequence_o(mtr2_tap_sequence), .status_o(),
    .emit_drops_o(), .result_drops_o(),
    .reset_count_o(mtr2_tap_reset), .ineligible_count_o(mtr2_tap_inelig),
    .continuity_count_o(mtr2_tap_cont),
    .framing_error_o(mtr2_framing_error), .framing_error_count_o()
  );

  // ADV-2: duty-cycled ready on both checked streams. NOTE the cadence
  // contract this bench must respect: the single-cycle engine finalizes
  // EVERY cycle (~2k clocks) and the merge tier adds its own stalls, so
  // a simulated cycle must span >= ~5k clocks or the 8-deep sample FIFO
  // (sized for the real 1.4M-clock cycles) congests and gap-marks every
  // block — a bench-pacing artifact, not a design property.
  logic [3:0] ready_lfsr = 4'hA;
  always @(posedge clock) begin
    ready_lfsr <= {ready_lfsr[2:0], ready_lfsr[3] ^ ready_lfsr[2]};
    basic_tready <= ready_lfsr[0] | ready_lfsr[1];
    mtr2_tready <= ready_lfsr[1] | ready_lfsr[2];
  end

  // --- record collectors ---------------------------------------------------
  int basic_records = 0;
  int power_records = 0;
  int phasor_records = 0;
  int unbal_records = 0;
  int basic_beat = 0;
  logic [31:0] basic_word [0:63];
  // Completed-record snapshot: BASIC and POWER stream back-to-back, so
  // the collector array starts refilling before a checker fires.
  logic [31:0] done_word [0:63];
  int mtr2_records = 0;
  int agg_power_records = 0;
  int agg_phasor_records = 0;
  int agg_unbal_records = 0;
  int mtr2_beat = 0;
  logic [31:0] mtr2_word [0:63];
  // Completed-record snapshot: the aggregate quad streams back to back,
  // so the collector refills before a checker fires (the same race the
  // basic side hit in M8).
  logic [31:0] mtr2_done [0:63];

  // --- golden helpers ------------------------------------------------------
  function automatic logic [63:0] lane_dc(input int lane);
    return 64'((lane + 1)) << 16;  // (lane+1).0 in Q16
  endfunction

  localparam logic [31:0] TIMING_WORD_BASE =
    32'd50 | (32'd10 << 8) | (32'h1 << 16);  // nominal, cycles, locked

  function automatic logic [63:0] block_first_sample(input int block_index);
    return 64'(FIRST_BLOCK_SAMPLE) +
           64'(FRAMES_PER_CYCLE * CYCLES_PER_BLOCK) * 64'(block_index - 1);
  endfunction

  task automatic check_basic_record();
    int w = basic_records;  // 1-based block index == record sequence
    logic [63:0] fs = block_first_sample(w);
    logic [63:0] ls = block_first_sample(w + 1) - 1;
    logic [31:0] expected;
    for (int i = 0; i < 64; ++i) begin
      expected = 32'h0;
      case (i)
        0: expected = 32'h3152_544D;
        1: expected = 32'h0001_0004;
        2: expected = 32'd256;
        3: expected = 32'(w);
        4: expected = GENERATION;
        5: expected = SAMPLE_RATE;
        6: expected = 32'(FRAMES_PER_CYCLE * CYCLES_PER_BLOCK);
        7: expected = {24'h0, VALID_MASK};
        // First block after reset/APPLY carries the discontinuity mark.
        8: expected = (w == 1) ? 32'h4 : 32'h0;
        9: expected = fs[31:0];
        10: expected = fs[63:32];
        11: expected = 32'h0;
        12: expected = 32'h0;
        13: expected = (w == 1) ? (TIMING_WORD_BASE | (32'h1 << 18))
                                : TIMING_WORD_BASE;
        14: expected = ls[31:0];
        15: expected = ls[63:32];
        // Merged VLL of constant lanes: |Va-Vb| = 1, |Vb-Vc| = 1,
        // |Vc-Va| = 2 units.
        51: expected = 32'd1;
        52: expected = 32'd1;
        53: expected = 32'd2;
        56: expected = freq_millihz;
        57: expected = freq_status;
        58: expected = freq_period;
        59: expected = freq_sequence;
        60: expected = 32'(1000 + w);  // per-block capture frame count
        61: expected = cap_headers;
        62: expected = cap_overflows;
        63: expected = cap_alerts;
        default: begin
          // Channel block, dc_remove off: mean = lane+1 units, RMS of the
          // constant equals the constant (lane+1 units), raw RMS count
          // equals the constant raw sample.
          if (i >= 16 && i < 51) begin
            int lane = (i - 16) / 5;
            int field = (i - 16) % 5;
            if (lane < 7 && field == 0) expected = 32'(lane + 1);       // mean lo
            else if (lane < 7 && field == 2) expected = 32'((lane + 1) * 100);
            else if (lane < 7 && field == 3) expected = 32'(lane + 1);  // rms lo
            else expected = 32'h0;
          end
        end
      endcase
      assert (done_word[i] == expected)
        else $fatal(1, "BASIC record %0d word %0d: got %08h expected %08h",
                    w, i, done_word[i], expected);
    end
  endtask

  // POWER-v1 companion: constant DC per lane makes every quantity exact.
  // Lane value (lane+1).0 Q16, dc_remove off: RMS = the constant, so
  // P = S = (v * i) in unit^2, PF = 1.0 exactly, crest = 1.0 exactly.
  task automatic check_power_record();
    int w = power_records;  // shares the basic sibling's sequence
    logic [63:0] fs = block_first_sample(w);
    logic [63:0] ls = block_first_sample(w + 1) - 1;
    logic [31:0] expected;
    for (int i = 0; i < 64; ++i) begin
      expected = 32'h0;
      case (i)
        0: expected = 32'h3152_544D;
        1: expected = 32'h0007_0001;
        2: expected = 32'd256;
        3: expected = 32'(w);
        4: expected = GENERATION;
        5: expected = SAMPLE_RATE;
        6: expected = 32'(FRAMES_PER_CYCLE * CYCLES_PER_BLOCK);
        7: expected = {24'h0, VALID_MASK};
        8: expected = (w == 1) ? 32'h4 : 32'h0;
        9: expected = fs[31:0];
        10: expected = fs[63:32];
        13: expected = (w == 1) ? (TIMING_WORD_BASE | (32'h1 << 18))
                                : TIMING_WORD_BASE;
        14: expected = ls[31:0];
        15: expected = ls[63:32];
        16: expected = 32'd7;   // P_A = Va(7) x Ia(1)
        18: expected = 32'd7;   // S_A
        20: expected = 32'd1000000;
        21: expected = 32'd12;  // P_B = Vb(6) x Ib(2)
        23: expected = 32'd12;
        25: expected = 32'd1000000;
        26: expected = 32'd15;  // P_C = Vc(5) x Ic(3)
        28: expected = 32'd15;
        30: expected = 32'd1000000;
        31: expected = 32'd34;  // totals
        33: expected = 32'd34;
        35: expected = 32'd1000000;
        default: begin
          if (i >= 36 && i < 43) expected = 32'd10000;  // crest = 1.0
        end
      endcase
      assert (done_word[i] == expected)
        else $fatal(1, "POWER record %0d word %0d: got %08h expected %08h",
                    w, i, done_word[i], expected);
    end
  endtask

  // PHASOR-v1 companion (M9): envelope and framing are pinned exactly;
  // the value words are NOT replicated here — constant-DC inputs make
  // the fundamental cross products floor-sensitive near zero, and the
  // exact-value proof lives in the engine's own golden bench, which
  // cosims the same packaged RTL. Structural pins: shared envelope and
  // anchors, no phasor-invalid bit (the bench frequency is valid), the
  // Va angle word exactly 0 (the reference convention), the
  // angle-reference-valid flag set, reserved words zero.
  task automatic check_phasor_record();
    int w = phasor_records;  // shares the basic sibling's sequence
    logic [63:0] fs = block_first_sample(w);
    logic [63:0] ls = block_first_sample(w + 1) - 1;
    assert (done_word[0] == 32'h3152_544D && done_word[1] == 32'h0008_0002 &&
            done_word[2] == 32'd256)
      else $fatal(1, "PHASOR record %0d envelope identity", w);
    assert (done_word[3] == 32'(w) && done_word[4] == GENERATION &&
            done_word[5] == SAMPLE_RATE &&
            done_word[6] == 32'(FRAMES_PER_CYCLE * CYCLES_PER_BLOCK) &&
            done_word[7] == {24'h0, VALID_MASK})
      else $fatal(1, "PHASOR record %0d correlation fields", w);
    assert (done_word[8] == ((w == 1) ? 32'h4 : 32'h0))
      else $fatal(1, "PHASOR record %0d status: got %08h", w, done_word[8]);
    assert (done_word[9] == fs[31:0] && done_word[10] == fs[63:32] &&
            done_word[14] == ls[31:0] && done_word[15] == ls[63:32])
      else $fatal(1, "PHASOR record %0d sample anchors", w);
    assert (done_word[13] == ((w == 1) ? (TIMING_WORD_BASE | (32'h1 << 18))
                                       : TIMING_WORD_BASE))
      else $fatal(1, "PHASOR record %0d timing word", w);
    assert (done_word[29] == 32'h0)
      else $fatal(1, "PHASOR record %0d: Va angle must be exactly 0, got %08h",
                  w, done_word[29]);
    assert (done_word[51][8])
      else $fatal(1, "PHASOR record %0d: angle reference must be valid", w);
    for (int i = 60; i < 64; ++i)
      assert (done_word[i] == 32'h0)
        else $fatal(1, "PHASOR record %0d reserved word %0d nonzero", w, i);
  endtask

  // UNBAL-v1 companion (M10): structural pins like the PHASOR checker —
  // envelope/anchors exact, value words pinned by the engine's golden
  // bench (constant-DC fundamentals make the components floor-sensitive
  // noise). The flags word must show the reference valid; the per-set
  // validity bits follow the near-zero fundamentals and are not pinned.
  task automatic check_unbal_record();
    int w = unbal_records;  // shares the basic sibling's sequence
    logic [63:0] fs = block_first_sample(w);
    logic [63:0] ls = block_first_sample(w + 1) - 1;
    assert (done_word[0] == 32'h3152_544D && done_word[1] == 32'h0009_0002 &&
            done_word[2] == 32'd256)
      else $fatal(1, "UNBAL record %0d envelope identity", w);
    assert (done_word[3] == 32'(w) && done_word[4] == GENERATION &&
            done_word[5] == SAMPLE_RATE &&
            done_word[6] == 32'(FRAMES_PER_CYCLE * CYCLES_PER_BLOCK) &&
            done_word[7] == {24'h0, VALID_MASK})
      else $fatal(1, "UNBAL record %0d correlation fields", w);
    assert (done_word[8] == ((w == 1) ? 32'h4 : 32'h0))
      else $fatal(1, "UNBAL record %0d status: got %08h", w, done_word[8]);
    assert (done_word[9] == fs[31:0] && done_word[10] == fs[63:32] &&
            done_word[14] == ls[31:0] && done_word[15] == ls[63:32])
      else $fatal(1, "UNBAL record %0d sample anchors", w);
    assert (done_word[13] == ((w == 1) ? (TIMING_WORD_BASE | (32'h1 << 18))
                                       : TIMING_WORD_BASE))
      else $fatal(1, "UNBAL record %0d timing word", w);
    assert (done_word[32][8])
      else $fatal(1, "UNBAL record %0d: angle reference must be valid", w);
    for (int i = 33; i < 64; ++i)
      assert (done_word[i] == 32'h0)
        else $fatal(1, "UNBAL record %0d reserved word %0d nonzero", w, i);
  endtask

  task automatic check_mtr2_record();
    // One aggregate over eligible blocks 2..16 (block 1 carries the
    // first-block flag and must be rejected as ineligible). AGG-v3
    // (M11): the whole-interval finalize of constant-DC lanes equals the
    // constants, so every legacy expectation carries over; the additive
    // words (36/37 last sample, 38..40 VLL) are exact too.
    logic [63:0] fs = block_first_sample(2);
    logic [63:0] ls = block_first_sample(17) - 1;
    logic [31:0] expected;
    for (int i = 0; i < 64; ++i) begin
      expected = 32'h0;
      case (i)
        0: expected = 32'h3152_544D;
        1: expected = 32'h0002_0003;
        2: expected = 32'd256;
        3: expected = 32'd1;
        4: expected = GENERATION;
        5: expected = SAMPLE_RATE;
        6: expected = 32'(15 * FRAMES_PER_CYCLE * CYCLES_PER_BLOCK);
        7: expected = {24'h0, VALID_MASK};
        8: expected = 32'h1 << 1 | 32'h1 << 2;  // complete + freq valid
        9: expected = fs[31:0];
        10: expected = fs[63:32];
        13: expected = 32'd15 | (32'd50 << 8) | (32'd150 << 16);
        14: expected = 32'd2;   // first folded basic sequence
        15: expected = 32'd16;  // last folded basic sequence
        32: expected = freq_millihz;
        33: expected = 32'h0;  // reset_count
        34: expected = 32'd1;  // ineligible_count (the flagged block 1)
        35: expected = 32'h0;  // continuity_count
        36: expected = ls[31:0];   // interval last-sample anchor
        37: expected = ls[63:32];
        38: expected = 32'd1;      // |Va-Vb| of the constant lanes
        39: expected = 32'd1;      // |Vb-Vc|
        40: expected = 32'd2;      // |Vc-Va|
        default: begin
          // Aggregate RMS of identical inputs equals the input: lane+1
          // units in the low word of each channel pair.
          if (i >= 16 && i < 32) begin
            int lane = (i - 16) / 2;
            int field = (i - 16) % 2;
            if (lane < 7 && field == 0) expected = 32'(lane + 1);
            else expected = 32'h0;
          end
        end
      endcase
      assert (mtr2_done[i] == expected)
        else $fatal(1, "MTR2 record word %0d: got %08h expected %08h",
                    i, mtr2_done[i], expected);
    end
  endtask

  always @(posedge clock) begin
    if (resetn) begin
      if (basic_tvalid && basic_tready) begin
        assert (basic_tkeep == 4'hF) else $fatal(1, "BASIC TKEEP not full");
        basic_word[basic_beat] <= basic_tdata;
        assert (basic_tlast == (basic_beat == 63))
          else $fatal(1, "BASIC TLAST at beat %0d", basic_beat);
        if (basic_beat == 63) begin
          basic_beat <= 0;
          for (int i = 0; i < 63; ++i)
            done_word[i] <= basic_word[i];
          done_word[63] <= basic_tdata;
          // The stream interleaves BASIC-v4, POWER-v1, PHASOR-v1, and
          // UNBAL-v1: word 1 (written 62 beats ago) routes the completed
          // record to its checker.
          if (basic_word[1] == 32'h0007_0001)
            power_records <= power_records + 1;
          else if (basic_word[1] == 32'h0008_0002)
            phasor_records <= phasor_records + 1;
          else if (basic_word[1] == 32'h0009_0002)
            unbal_records <= unbal_records + 1;
          else
            basic_records <= basic_records + 1;
        end else begin
          basic_beat <= basic_beat + 1;
        end
      end
      if (mtr2_tvalid && mtr2_tready) begin
        assert (mtr2_tkeep == 4'hF)
          else $fatal(1, "MTR2 TKEEP not full");
        mtr2_word[mtr2_beat] <= mtr2_tdata;
        assert (mtr2_tlast == (mtr2_beat == 63))
          else $fatal(1, "MTR2 TLAST at beat %0d", mtr2_beat);
        if (mtr2_beat == 63) begin
          mtr2_beat <= 0;
          for (int i = 0; i < 63; ++i)
            mtr2_done[i] <= mtr2_word[i];
          mtr2_done[63] <= mtr2_tdata;
          // The aggregate stream interleaves AGG-v3 and its siblings:
          // route by word 1 (all four are checked one cycle later).
          if (mtr2_word[1] == 32'h0010_0001)
            agg_power_records <= agg_power_records + 1;
          else if (mtr2_word[1] == 32'h0011_0002)
            agg_phasor_records <= agg_phasor_records + 1;
          else if (mtr2_word[1] == 32'h0012_0002)
            agg_unbal_records <= agg_unbal_records + 1;
          else
            mtr2_records <= mtr2_records + 1;
        end else begin
          mtr2_beat <= mtr2_beat + 1;
        end
      end
      assert (!basic_framing_error && !mtr2_framing_error)
        else $fatal(1, "record tap framing watchdog fired");
    end
  end

  // Content checks run right after a record completes (the collector
  // arrays are written with nonblocking assignments, so wait one cycle).
  int basic_checked = 0;
  int power_checked = 0;
  int phasor_checked = 0;
  int unbal_checked = 0;
  int mtr2_checked = 0;
  // AGG sibling checkers. Constant DC makes the whole-interval power
  // quantities equal the basic ones EXACTLY: P = S = v*i unit^2, PF 1.0,
  // crest 1.0. Phasor/unbalance siblings are pinned structurally (their
  // exact values live in the engine's golden bench).
  task automatic check_agg_power_record();
    logic [63:0] fs = block_first_sample(2);
    assert (mtr2_done[0] == 32'h3152_544D && mtr2_done[2] == 32'd256 &&
            mtr2_done[3] == 32'd1 && mtr2_done[4] == GENERATION &&
            mtr2_done[9] == fs[31:0] && mtr2_done[10] == fs[63:32])
      else $fatal(1, "AGG-POWER envelope");
    assert (mtr2_done[13] == (32'd15 | (32'd50 << 8) | (32'd150 << 16)) &&
            mtr2_done[14] == 32'd2 && mtr2_done[15] == 32'd16)
      else $fatal(1, "AGG-POWER shape/sequence-range words");
    assert (mtr2_done[16] == 32'd7 && mtr2_done[18] == 32'd7 &&
            mtr2_done[20] == 32'd1000000 && mtr2_done[21] == 32'd12 &&
            mtr2_done[26] == 32'd15 && mtr2_done[31] == 32'd34 &&
            mtr2_done[33] == 32'd34 && mtr2_done[35] == 32'd1000000)
      else $fatal(1, "AGG-POWER constant-DC values");
    for (int i = 36; i < 43; ++i)
      assert (mtr2_done[i] == 32'd10000)
        else $fatal(1, "AGG-POWER crest word %0d", i);
  endtask

  task automatic check_agg_phasor_record();
    assert (mtr2_done[0] == 32'h3152_544D && mtr2_done[3] == 32'd1 &&
            mtr2_done[14] == 32'd2 && mtr2_done[15] == 32'd16)
      else $fatal(1, "AGG-PHASOR envelope");
    assert (mtr2_done[29] == 32'h0)
      else $fatal(1, "AGG-PHASOR: Va angle must be exactly 0");
    assert (mtr2_done[51][8])
      else $fatal(1, "AGG-PHASOR: angle reference must be valid");
  endtask

  task automatic check_agg_unbal_record();
    assert (mtr2_done[0] == 32'h3152_544D && mtr2_done[3] == 32'd1 &&
            mtr2_done[14] == 32'd2 && mtr2_done[15] == 32'd16)
      else $fatal(1, "AGG-UNBAL envelope");
    assert (mtr2_done[32][8])
      else $fatal(1, "AGG-UNBAL: angle reference must be valid");
    for (int i = 33; i < 64; ++i)
      assert (mtr2_done[i] == 32'h0)
        else $fatal(1, "AGG-UNBAL reserved word %0d nonzero", i);
  endtask

  int agg_power_checked = 0;
  int agg_phasor_checked = 0;
  int agg_unbal_checked = 0;

  always @(posedge clock) begin
    if (basic_records > basic_checked) begin
      check_basic_record();
      basic_checked <= basic_records;
    end
    if (power_records > power_checked) begin
      check_power_record();
      power_checked <= power_records;
    end
    if (phasor_records > phasor_checked) begin
      check_phasor_record();
      phasor_checked <= phasor_records;
    end
    if (unbal_records > unbal_checked) begin
      check_unbal_record();
      unbal_checked <= unbal_records;
    end
    if (mtr2_records > mtr2_checked) begin
      check_mtr2_record();
      mtr2_checked <= mtr2_records;
    end
    if (agg_power_records > agg_power_checked) begin
      check_agg_power_record();
      agg_power_checked <= agg_power_records;
    end
    if (agg_phasor_records > agg_phasor_checked) begin
      check_agg_phasor_record();
      agg_phasor_checked <= agg_phasor_records;
    end
    if (agg_unbal_records > agg_unbal_checked) begin
      check_agg_unbal_record();
      agg_unbal_checked <= agg_unbal_records;
    end
  end

  // --- stimulus ------------------------------------------------------------
  longint sample_index = 64'd1000;

  task automatic send_frame(input bit closes);
    frame_user[31:0] = sample_index[31:0];
    frame_user[105:74] = sample_index[63:32];
    sample_index = sample_index + 1;
    pl_tick = pl_tick + 10;
    frame_accept = 1'b1;
    @(posedge clock);
    frame_accept = 1'b0;
    // grid_cycle_timing registers its strobes one clock after the
    // crossing frame; the shim samples them while that frame sits
    // staged, so the boundary must be driven on the FOLLOWING cycle.
    cycle_boundary = closes;
    if (closes) cycle_sequence = cycle_sequence + 1;
    @(posedge clock);
    cycle_boundary = 1'b0;
    repeat (FRAME_GAP - 2) @(posedge clock);
  endtask

  initial begin
    // Converted samples: constant (lane+1).0 Q16 per lane; raw samples
    // constant (lane+1)*100; generation tag and full-frame TKEEP.
    for (int lane = 0; lane < 8; ++lane) begin
      frame_data[lane*48 +: 48] = lane_dc(lane);
      frame_user[128 + lane*32 +: 32] = 32'((lane + 1) * 100);
    end
    frame_user[63:32] = GENERATION;
    frame_user[71:64] = VALID_MASK;

    repeat (8) @(posedge clock);
    resetn = 1'b1;
    repeat (8) @(posedge clock);

    // APPLY: toggle, then one carrier frame (index 1000, discarded by the
    // single-cycle await-boundary rule).
    apply_toggle = 1'b1;
    send_frame(1'b0);
    assert (active_generation == GENERATION && active_enable)
      else $fatal(1, "merge-tier APPLY mirror did not commit");

    // Sync cycle: samples 1001..1008, boundary on the last — discarded,
    // re-arming accumulation at a true cycle start (1009).
    for (int f = 0; f < FRAMES_PER_CYCLE; ++f)
      send_frame(f == FRAMES_PER_CYCLE - 1);

    for (int w = 1; w <= BLOCKS; ++w) begin
      for (int c = 0; c < CYCLES_PER_BLOCK; ++c) begin
        for (int f = 0; f < FRAMES_PER_CYCLE; ++f) begin
          send_frame(f == FRAMES_PER_CYCLE - 1);
          // The previous block's closing result (and its context sample)
          // lands within the single-cycle finalize latency plus the
          // aggregation engine's own invocation. Advance the capture
          // counter this block's record must carry only after that has
          // comfortably passed.
          //
          // Was c == 2, sized for the retired 10/12 engine's 6,684-clock
          // block close. Since A1 one engine owns both finalized tiers, so a
          // close costs more and the old margin let block w's record latch
          // block w+1's counter (observed: record 6 word 60 read 1007 for
          // 1006). c == 5 is half a block, ~24k clocks at FRAME_GAP=600.
          // This is a TEST timing margin, not a product requirement:
          // nothing downstream cares when a diagnostic capture counter is
          // sampled to within a few ms.
          if (c == 5 && f == 0) cap_frames = 32'(1000 + w);
        end
      end
    end

    // Drain: the last finalizes plus the 64-beat records under
    // duty-cycled ready complete well within this window.
    repeat (20000) @(posedge clock);

    assert (basic_records == BLOCKS)
      else $fatal(1, "BASIC records %0d, expected %0d", basic_records, BLOCKS);
    assert (power_records == BLOCKS)
      else $fatal(1, "POWER records %0d, expected %0d", power_records, BLOCKS);
    assert (phasor_records == BLOCKS)
      else $fatal(1, "PHASOR records %0d, expected %0d", phasor_records,
                  BLOCKS);
    assert (unbal_records == BLOCKS)
      else $fatal(1, "UNBAL records %0d, expected %0d", unbal_records,
                  BLOCKS);
    assert (mtr2_records == 1)
      else $fatal(1, "AGG records %0d, expected 1", mtr2_records);
    assert (agg_power_records == 1 && agg_phasor_records == 1 &&
            agg_unbal_records == 1)
      else $fatal(1, "AGG siblings %0d/%0d/%0d, expected 1 each",
                  agg_power_records, agg_phasor_records, agg_unbal_records);
    assert (basic_checked == BLOCKS && power_checked == BLOCKS &&
            phasor_checked == BLOCKS && unbal_checked == BLOCKS &&
            mtr2_checked == 1 && agg_power_checked == 1 &&
            agg_phasor_checked == 1 && agg_unbal_checked == 1)
      else $fatal(1, "content checks incomplete");
    assert (scyc_drop_count == 0)
      else $fatal(1, "single-cycle shim dropped %0d beats", scyc_drop_count);
    assert (basic_tap_sequence == BLOCKS && mtr2_tap_sequence == 1)
      else $fatal(1, "tap sequences %0d/%0d", basic_tap_sequence,
                  mtr2_tap_sequence);
    assert (basic_tap_emit == 0 && basic_tap_result == 0)
      else $fatal(1, "BASIC drop words nonzero");
    assert (basic_tap_status == 0)
      else $fatal(1, "BASIC status nonzero");
    assert (mtr2_tap_reset == 0 && mtr2_tap_inelig == 1 && mtr2_tap_cont == 0)
      else $fatal(1, "MTR2 diagnostics %0d/%0d/%0d", mtr2_tap_reset,
                  mtr2_tap_inelig, mtr2_tap_cont);

    $display("PASS: meter_record_stream_tb (%0d BASIC + %0d MTR2 records)",
             basic_records, mtr2_records);
    $finish;
  end

  initial begin
    #200ms;
    $fatal(1, "timeout");
  end
endmodule
