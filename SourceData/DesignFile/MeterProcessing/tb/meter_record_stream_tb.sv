`timescale 1ns/1ps

// Whole-chain record-stream integration bench (verification plan TB-1).
//
// Drives converted-frame beats through the REAL shims and the PACKAGED
// hls_mtr1_engine and hls_mtr2_engine RTL (bound exactly as the build
// binds them), to both exported 32-bit AXIS record streams —
// no stubs anywhere on a path that has ever produced a field fault (TB-2),
// and stimulus enters only at the sample/event boundary (TB-3).
//
// Checks, per the verification plan:
//   INV-1  exactly-once conservation: 16 closed windows -> exactly 16
//          MTR1 records with sequences 1..16; 15 eligible basic results ->
//          exactly one MTR2 record with sequence 1; nothing extra.
//   INV-2  framing: every record is exactly 64 beats, TLAST only on beat
//          63, TKEEP/TSTRB full, magic/format/size correct — checked
//          beat-by-beat here and independently by the record_word_tap
//          framing watchdogs.
//   INV-5  golden content: every word of every record compared against
//          integer-exact expectations (constant DC per lane makes mean,
//          RMS, and the aggregate exact).
//   ADV-2  TREADY stall sweep: both record streams run against a duty-
//          cycled ready so beats are delivered under backpressure.
//   CNT    the shim FIFO drop counter and both tap-published drop words
//          must end at zero; the MTR2 diagnostics must show exactly the
//          one deliberately ineligible (first-after-APPLY) block.
//
// Frame cadence is 600 clocks — comfortably above the engine's inline
// finalize divided by the 8-deep shim FIFO, mirroring the real 3125-clock
// cadence contract (32 kSPS at 100 MHz).
module meter_record_stream_tb;
  logic clock = 1'b0;
  logic resetn = 1'b0;
  always #5 clock = ~clock;

  localparam int FRAMES_PER_WINDOW = 8;
  localparam int WINDOWS = 16;
  localparam int FRAME_GAP = 600;
  localparam logic [31:0] GENERATION = 32'd1;
  localparam logic [31:0] SAMPLE_RATE = 32'd32000;
  localparam logic [7:0] VALID_MASK = 8'h7F;

  // --- shim inputs ---------------------------------------------------------
  logic frame_accept = 1'b0;
  logic [511:0] frame_data = '0;
  logic [63:0] frame_keep = '1;
  logic [383:0] frame_user = '0;
  logic frame_closes = 1'b0;
  logic cycle_mode = 1'b1;
  logic [63:0] block_first_sample = 64'd1000;
  logic [7:0] block_cycle_count = 8'd10;
  logic [7:0] block_nominal = 8'd50;
  logic [2:0] block_flags = 3'b001;  // locked
  logic [31:0] shadow_generation = GENERATION;
  logic [31:0] shadow_sample_rate = SAMPLE_RATE;
  logic [31:0] shadow_window_samples = 32'd6400;
  logic [7:0] shadow_valid_mask = VALID_MASK;
  // dc_remove off: with constant per-lane DC the mean, the RMS, the raw
  // RMS count, and the 15-block aggregate are all integer-exact and
  // nonzero, so every channel word carries a distinctive value.
  logic shadow_enable = 1'b1;
  logic shadow_dc_remove = 1'b0;
  logic apply_toggle = 1'b0;
  logic [31:0] freq_millihz = 32'd49991;
  logic [31:0] freq_status = 32'h0000_0032;  // VALID (bit 1) + mode bits
  logic [31:0] freq_period = 32'h0014_0007;
  logic [31:0] freq_sequence = 32'd77;
  logic [31:0] cap_frames = 32'd0;
  logic [31:0] cap_headers = 32'd1;
  logic [31:0] cap_overflows = 32'd2;
  logic [31:0] cap_alerts = 32'd3;

  // --- record streams ------------------------------------------------------
  wire [31:0] mtr1_tdata;
  wire [3:0] mtr1_tkeep;
  wire mtr1_tvalid;
  logic mtr1_tready;
  wire mtr1_tlast;
  wire [807:0] result_tdata;
  wire result_tvalid;
  wire result_tready;
  wire [31:0] mtr2_tdata;
  wire mtr2_tvalid;
  logic mtr2_tready;
  wire [3:0] mtr2_tkeep;
  wire mtr2_tlast;

  wire [31:0] active_generation;
  wire active_enable;
  wire apply_seen;
  wire [31:0] shim_drop_count;

  meter_mtr1_hls_shim shim (
    .aclk(clock), .aresetn(resetn),
    .frame_accept_i(frame_accept),
    .frame_data_i(frame_data),
    .frame_keep_i(frame_keep),
    .frame_user_i(frame_user),
    .frame_closes_block_i(frame_closes),
    .cycle_mode_i(cycle_mode),
    .block_first_sample_i(block_first_sample),
    .block_cycle_count_i(block_cycle_count),
    .block_nominal_hz_i(block_nominal),
    .block_flags_i(block_flags),
    .shadow_generation_i(shadow_generation),
    .shadow_sample_rate_i(shadow_sample_rate),
    .shadow_window_samples_i(shadow_window_samples),
    .shadow_valid_mask_i(shadow_valid_mask),
    .shadow_enable_i(shadow_enable),
    .shadow_dc_remove_i(shadow_dc_remove),
    .config_apply_toggle_i(apply_toggle),
    .frequency_millihz_i(freq_millihz),
    .frequency_status_i(freq_status),
    .frequency_period_i(freq_period),
    .frequency_sequence_i(freq_sequence),
    .capture_frame_count_i(cap_frames),
    .capture_header_errors_i(cap_headers),
    .capture_overflows_i(cap_overflows),
    .capture_alerts_i(cap_alerts),
    .m_axis_mtr1_tdata(mtr1_tdata),
    .m_axis_mtr1_tkeep(mtr1_tkeep),
    .m_axis_mtr1_tvalid(mtr1_tvalid),
    .m_axis_mtr1_tready(mtr1_tready),
    .m_axis_mtr1_tlast(mtr1_tlast),
    .m_result_tdata(result_tdata),
    .m_result_tvalid(result_tvalid),
    .m_result_tready(result_tready),
    .active_generation_o(active_generation),
    .active_enable_o(active_enable),
    .apply_seen_o(apply_seen),
    .drop_count_o(shim_drop_count)
  );

  meter_mtr2_hls_shim aggregator (
    .aclk(clock), .aresetn(resetn),
    .s_result_tdata(result_tdata),
    .s_result_tvalid(result_tvalid),
    .s_result_tready(result_tready),
    .m_axis_mtr2_tdata(mtr2_tdata),
    .m_axis_mtr2_tkeep(mtr2_tkeep),
    .m_axis_mtr2_tvalid(mtr2_tvalid),
    .m_axis_mtr2_tready(mtr2_tready),
    .m_axis_mtr2_tlast(mtr2_tlast)
  );

  // Independent framing watchdogs (the in-fabric register taps).
  wire mtr1_framing_error, mtr2_framing_error;
  wire [31:0] mtr1_tap_sequence, mtr1_tap_status, mtr1_tap_emit, mtr1_tap_result;
  wire [31:0] mtr2_tap_sequence, mtr2_tap_reset, mtr2_tap_inelig, mtr2_tap_cont;
  record_word_tap mtr1_tap (
    .aclk(clock), .aresetn(resetn),
    .tdata_i(mtr1_tdata), .tvalid_i(mtr1_tvalid),
    .tready_i(mtr1_tready), .tlast_i(mtr1_tlast),
    .sequence_o(mtr1_tap_sequence), .status_o(mtr1_tap_status),
    .emit_drops_o(mtr1_tap_emit), .result_drops_o(mtr1_tap_result),
    .reset_count_o(), .ineligible_count_o(), .continuity_count_o(),
    .framing_error_o(mtr1_framing_error), .framing_error_count_o()
  );
  record_word_tap mtr2_tap (
    .aclk(clock), .aresetn(resetn),
    .tdata_i(mtr2_tdata), .tvalid_i(mtr2_tvalid),
    .tready_i(mtr2_tready), .tlast_i(mtr2_tlast),
    .sequence_o(mtr2_tap_sequence), .status_o(),
    .emit_drops_o(), .result_drops_o(),
    .reset_count_o(mtr2_tap_reset), .ineligible_count_o(mtr2_tap_inelig),
    .continuity_count_o(mtr2_tap_cont),
    .framing_error_o(mtr2_framing_error), .framing_error_count_o()
  );

  // ADV-2: duty-cycled ready on both streams.
  logic [3:0] ready_lfsr = 4'hA;
  always @(posedge clock) begin
    ready_lfsr <= {ready_lfsr[2:0], ready_lfsr[3] ^ ready_lfsr[2]};
    mtr1_tready <= ready_lfsr[0] | ready_lfsr[1];
    mtr2_tready <= ready_lfsr[1] | ready_lfsr[2];
  end

  // --- record collectors ---------------------------------------------------
  int mtr1_records = 0;
  int mtr1_beat = 0;
  logic [31:0] mtr1_word [0:63];
  int mtr2_records = 0;
  int mtr2_beat = 0;
  logic [31:0] mtr2_word [0:63];

  // --- golden helpers ------------------------------------------------------
  function automatic logic [63:0] lane_dc(input int lane);
    return 64'((lane + 1)) << 16;  // (lane+1).0 in Q16
  endfunction

  localparam logic [31:0] TIMING_WORD_BASE =
    32'd50 | (32'd10 << 8) | (32'h1 << 16);  // nominal, cycles, locked

  function automatic logic [63:0] window_first_sample(input int window_index);
    // Window 1 starts at 1000; each window advances by its sample count.
    return 64'd1000 + 64'(FRAMES_PER_WINDOW) * 64'(window_index - 1);
  endfunction

  task automatic check_mtr1_record();
    int w = mtr1_records;  // 1-based window index == record sequence
    logic [63:0] fs = window_first_sample(w);
    logic [31:0] expected;
    for (int i = 0; i < 64; ++i) begin
      expected = 32'h0;
      case (i)
        0: expected = 32'h3152_544D;
        1: expected = 32'h0001_0003;
        2: expected = 32'd256;
        3: expected = 32'(w);
        4: expected = GENERATION;
        5: expected = SAMPLE_RATE;
        // The APPLY-carrying frame is processed under the new
        // configuration; its generation tag already matches here, so it
        // joins window 1 (identical constant samples, so only the count
        // differs).
        6: expected = 32'(FRAMES_PER_WINDOW + ((w == 1) ? 1 : 0));
        7: expected = {24'h0, VALID_MASK};
        8: expected = 32'h0;
        9: expected = fs[31:0];
        10: expected = fs[63:32];
        11: expected = 32'h0;
        12: expected = 32'h0;
        13: expected = (w == 1) ? (TIMING_WORD_BASE | (32'h1 << 18))
                                : TIMING_WORD_BASE;
        56: expected = freq_millihz;
        57: expected = freq_status;
        58: expected = freq_period;
        59: expected = freq_sequence;
        60: expected = 32'(1000 + w);  // per-window capture frame count
        61: expected = cap_headers;
        62: expected = cap_overflows;
        63: expected = cap_alerts;
        default: begin
          // Channel block, dc_remove off: mean = lane+1 units, RMS of the
          // constant equals the constant (lane+1 units), raw RMS count
          // equals the constant raw sample.
          if (i >= 16 && i < 56) begin
            int lane = (i - 16) / 5;
            int field = (i - 16) % 5;
            if (lane < 7 && field == 0) expected = 32'(lane + 1);       // mean lo
            else if (lane < 7 && field == 2) expected = 32'((lane + 1) * 100);
            else if (lane < 7 && field == 3) expected = 32'(lane + 1);  // rms lo
            else expected = 32'h0;
          end
        end
      endcase
      assert (mtr1_word[i] == expected)
        else $fatal(1, "MTR1 record %0d word %0d: got %08h expected %08h",
                    w, i, mtr1_word[i], expected);
    end
  endtask

  task automatic check_mtr2_record();
    // One aggregate over eligible windows 2..16 (window 1 carries the
    // first-after-APPLY flag and must be rejected as ineligible).
    logic [63:0] fs = window_first_sample(2);
    logic [31:0] expected;
    for (int i = 0; i < 64; ++i) begin
      expected = 32'h0;
      case (i)
        0: expected = 32'h3152_544D;
        1: expected = 32'h0002_0002;
        2: expected = 32'd256;
        3: expected = 32'd1;
        4: expected = GENERATION;
        5: expected = SAMPLE_RATE;
        6: expected = 32'(15 * FRAMES_PER_WINDOW);
        7: expected = {24'h0, VALID_MASK};
        8: expected = 32'h1 << 1 | 32'h1 << 2;  // complete + freq valid
        9: expected = fs[31:0];
        10: expected = fs[63:32];
        13: expected = 32'd15 | (32'd50 << 8) | (32'd150 << 16);
        14: expected = 32'd2;   // first folded basic sequence
        15: expected = 32'd16;  // last folded basic sequence
        32: expected = freq_millihz;
        33: expected = 32'h0;  // reset_count
        34: expected = 32'd1;  // ineligible_count (the flagged window 1)
        35: expected = 32'h0;  // continuity_count
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
      assert (mtr2_word[i] == expected)
        else $fatal(1, "MTR2 record word %0d: got %08h expected %08h",
                    i, mtr2_word[i], expected);
    end
  endtask

  always @(posedge clock) begin
    if (resetn) begin
      if (mtr1_tvalid && mtr1_tready) begin
        assert (mtr1_tkeep == 4'hF) else $fatal(1, "MTR1 TKEEP not full");
        mtr1_word[mtr1_beat] <= mtr1_tdata;
        assert (mtr1_tlast == (mtr1_beat == 63))
          else $fatal(1, "MTR1 TLAST at beat %0d", mtr1_beat);
        if (mtr1_beat == 63) begin
          mtr1_beat <= 0;
          mtr1_records <= mtr1_records + 1;
        end else begin
          mtr1_beat <= mtr1_beat + 1;
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
          mtr2_records <= mtr2_records + 1;
        end else begin
          mtr2_beat <= mtr2_beat + 1;
        end
      end
      assert (!mtr1_framing_error && !mtr2_framing_error)
        else $fatal(1, "record tap framing watchdog fired");
    end
  end

  // Content checks run right after a record completes (the collector
  // arrays are written with nonblocking assignments, so wait one cycle).
  int mtr1_checked = 0;
  int mtr2_checked = 0;
  always @(posedge clock) begin
    if (mtr1_records > mtr1_checked) begin
      check_mtr1_record();
      mtr1_checked <= mtr1_records;
    end
    if (mtr2_records > mtr2_checked) begin
      check_mtr2_record();
      mtr2_checked <= mtr2_records;
    end
  end

  // --- stimulus ------------------------------------------------------------
  task automatic send_frame(input bit closes);
    frame_closes = closes;
    frame_accept = 1'b1;
    @(posedge clock);
    frame_accept = 1'b0;
    frame_closes = 1'b0;
    repeat (FRAME_GAP - 1) @(posedge clock);
  endtask

  initial begin
    // Converted samples: constant (lane+1).0 Q16 per lane; raw samples
    // constant (lane+1)*100; generation tag and full-frame TKEEP.
    for (int lane = 0; lane < 8; ++lane) begin
      frame_data[lane*64 +: 64] = lane_dc(lane);
      frame_user[128 + lane*32 +: 32] = 32'((lane + 1) * 100);
    end
    frame_user[63:32] = GENERATION;
    frame_user[71:64] = VALID_MASK;

    repeat (8) @(posedge clock);
    resetn = 1'b1;
    repeat (8) @(posedge clock);

    // APPLY: toggle, then one carrier frame (consumed, not accumulated).
    apply_toggle = 1'b1;
    send_frame(1'b0);
    assert (active_generation == GENERATION && active_enable)
      else $fatal(1, "shim APPLY mirror did not commit");

    for (int w = 1; w <= WINDOWS; ++w) begin
      block_first_sample = window_first_sample(w);
      block_flags = (w == 1) ? 3'b101 : 3'b001;  // first-after-APPLY once
      cap_frames = 32'(1000 + w);
      for (int f = 0; f < FRAMES_PER_WINDOW; ++f) begin
        send_frame(f == FRAMES_PER_WINDOW - 1);
      end
    end

    // Drain: the last finalize plus two 64-beat records under duty-cycled
    // ready complete well within this window.
    repeat (20000) @(posedge clock);

    assert (mtr1_records == WINDOWS)
      else $fatal(1, "MTR1 records %0d, expected %0d", mtr1_records, WINDOWS);
    assert (mtr2_records == 1)
      else $fatal(1, "MTR2 records %0d, expected 1", mtr2_records);
    assert (mtr1_checked == WINDOWS && mtr2_checked == 1)
      else $fatal(1, "content checks incomplete");
    assert (shim_drop_count == 0)
      else $fatal(1, "shim dropped %0d sample beats", shim_drop_count);
    assert (mtr1_tap_sequence == WINDOWS && mtr2_tap_sequence == 1)
      else $fatal(1, "tap sequences %0d/%0d", mtr1_tap_sequence,
                  mtr2_tap_sequence);
    assert (mtr1_tap_emit == 0 && mtr1_tap_result == 0)
      else $fatal(1, "MTR1 drop words nonzero");
    assert (mtr1_tap_status == 0)
      else $fatal(1, "MTR1 status nonzero");
    assert (mtr2_tap_reset == 0 && mtr2_tap_inelig == 1 && mtr2_tap_cont == 0)
      else $fatal(1, "MTR2 diagnostics %0d/%0d/%0d", mtr2_tap_reset,
                  mtr2_tap_inelig, mtr2_tap_cont);

    $display("PASS: meter_record_stream_tb (%0d MTR1 + %0d MTR2 records)",
             mtr1_records, mtr2_records);
    $finish;
  end

  initial begin
    #200ms;
    $fatal(1, "timeout");
  end
endmodule
