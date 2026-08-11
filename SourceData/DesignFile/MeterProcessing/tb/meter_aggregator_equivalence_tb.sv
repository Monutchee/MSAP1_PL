`timescale 1ns/1ps

// RTL/HLS equivalence test for the 150/180-cycle aggregator trial.
//
// Drives the hand-written engine (meter_cycle_aggregator) and the HLS
// shadow (meter_cycle_aggregator_hls_shim wrapping the generated
// hls_cycle_aggregator core) with the identical Basic-result stimulus of
// the RTL unit test -- the twelve T1..T12 scenarios -- and requires the
// engines to agree field-for-field on every emitted aggregate, including
// the record/ineligible/continuity counters carried in the HLS beat.
// reset_count is not compared at pair level (the HLS engine samples the
// APPLY toggle level per beat, so its reset accounting is deferred to the
// next Basic result; values match at every emit in this stimulus, but the
// production compare block in meter_core also excludes it, and this bench
// mirrors that contract).
//
// Correctness against the golden arithmetic is the RTL unit test's and
// the HLS C testbench's job; this bench closes the loop by proving the
// two implementations and the shim's beat packing agree inside one
// simulation. Events are spaced wider than both engines' worst-case
// finalize so the shim's one-deep event capture never replaces a beat
// (drop_count must end at zero).
module meter_aggregator_equivalence_tb;
  logic clock = 1'b0;
  logic resetn = 1'b0;

  logic basic_valid = 1'b0;
  logic [31:0] b_seq = '0, b_gen = '0, b_rate = 32'd128000, b_count = '0;
  logic [7:0] b_mask = 8'h7f;
  logic [31:0] b_status = '0;
  logic [511:0] b_rms = '0;
  logic [63:0] b_first = '0;
  logic [7:0] b_cycles = '0, b_nominal = '0;
  logic [2:0] b_flags = 3'b001;
  logic [31:0] b_freq = 32'd60000;
  logic b_freq_valid = 1'b1;
  logic apply_toggle = 1'b0;

  // RTL engine outputs.
  wire r_valid;
  wire [31:0] r_seq, r_gen, r_rate, r_samples;
  wire [7:0] r_mask;
  wire r_arith, r_freq_valid;
  wire [31:0] r_first_seq, r_last_seq;
  wire [7:0] r_nominal;
  wire [15:0] r_cycles;
  wire [63:0] r_first_sample;
  wire [511:0] r_rms;
  wire [31:0] r_freq;
  wire [31:0] r_status, r_record, r_reset, r_inelig, r_cont;

  // HLS engine outputs.
  wire h_valid;
  wire [31:0] h_seq, h_gen, h_rate, h_samples;
  wire [7:0] h_mask;
  wire h_arith, h_freq_valid;
  wire [31:0] h_first_seq, h_last_seq;
  wire [7:0] h_nominal;
  wire [15:0] h_cycles;
  wire [63:0] h_first_sample;
  wire [511:0] h_rms;
  wire [31:0] h_freq;
  wire [31:0] h_record, h_reset, h_inelig, h_cont, h_drop;

  always #5 clock = ~clock;

  meter_cycle_aggregator_tbshim rtl_engine (
    .aclk(clock), .aresetn(resetn),
    .basic_valid_i(basic_valid), .basic_sequence_i(b_seq),
    .basic_generation_i(b_gen), .basic_sample_rate_i(b_rate),
    .basic_sample_count_i(b_count), .basic_valid_mask_i(b_mask),
    .basic_status_i(b_status), .basic_rms_q16_i(b_rms),
    .basic_first_sample_i(b_first), .basic_cycle_count_i(b_cycles),
    .basic_nominal_hz_i(b_nominal), .basic_flags_i(b_flags),
    .basic_freq_millihz_i(b_freq), .basic_freq_valid_i(b_freq_valid),
    .config_apply_toggle_i(apply_toggle),
    .aggregate_valid_o(r_valid), .aggregate_sequence_o(r_seq),
    .aggregate_generation_o(r_gen), .aggregate_sample_rate_o(r_rate),
    .aggregate_samples_o(r_samples), .aggregate_valid_mask_o(r_mask),
    .aggregate_arithmetic_o(r_arith), .aggregate_freq_valid_o(r_freq_valid),
    .aggregate_first_seq_o(r_first_seq), .aggregate_last_seq_o(r_last_seq),
    .aggregate_nominal_o(r_nominal), .aggregate_cycles_o(r_cycles),
    .aggregate_first_sample_o(r_first_sample), .aggregate_rms_q16_o(r_rms),
    .aggregate_freq_millihz_o(r_freq),
    .status_o(r_status), .record_count_o(r_record),
    .reset_count_o(r_reset), .ineligible_count_o(r_inelig),
    .continuity_count_o(r_cont)
  );

  meter_cycle_aggregator_hls_tbshim hls_engine (
    .aclk(clock), .aresetn(resetn),
    .basic_valid_i(basic_valid), .basic_sequence_i(b_seq),
    .basic_generation_i(b_gen), .basic_sample_rate_i(b_rate),
    .basic_sample_count_i(b_count), .basic_valid_mask_i(b_mask),
    .basic_status_i(b_status), .basic_rms_q16_i(b_rms),
    .basic_first_sample_i(b_first), .basic_cycle_count_i(b_cycles),
    .basic_nominal_hz_i(b_nominal), .basic_flags_i(b_flags),
    .basic_freq_millihz_i(b_freq), .basic_freq_valid_i(b_freq_valid),
    .config_apply_toggle_i(apply_toggle),
    .aggregate_valid_o(h_valid), .aggregate_sequence_o(h_seq),
    .aggregate_generation_o(h_gen), .aggregate_sample_rate_o(h_rate),
    .aggregate_samples_o(h_samples), .aggregate_valid_mask_o(h_mask),
    .aggregate_arithmetic_o(h_arith), .aggregate_freq_valid_o(h_freq_valid),
    .aggregate_first_seq_o(h_first_seq), .aggregate_last_seq_o(h_last_seq),
    .aggregate_nominal_o(h_nominal), .aggregate_cycles_o(h_cycles),
    .aggregate_first_sample_o(h_first_sample), .aggregate_rms_q16_o(h_rms),
    .aggregate_freq_millihz_o(h_freq),
    .record_count_o(h_record), .reset_count_o(h_reset),
    .ineligible_count_o(h_inelig), .continuity_count_o(h_cont),
    .drop_count_o(h_drop)
  );

  // ---- Drivers -----------------------------------------------------------
  int unsigned next_seq = 1;
  logic [63:0] next_first = 64'd1000;
  int unsigned aggregates_seen = 0;

  // The engines emit single-cycle valid pulses during the inter-event
  // spacing, long before the checking task runs; latch them sticky. The
  // checker clears the flags after each compared pair.
  bit r_sticky = 0, h_sticky = 0;
  always @(posedge clock) begin
    if (r_valid) r_sticky = 1;
    if (h_valid) h_sticky = 1;
  end

  // Wider than both engines' worst-case finalize (RTL ~2.1k cycles, HLS
  // ~1.5k) so no event ever lands while either engine is busy.
  localparam int EVENT_SPACING = 2600;

  task automatic send_basic(input logic [63:0] rms_ch [7],
                            input logic [31:0] generation,
                            input int nominal,
                            input logic [31:0] sample_count,
                            input logic [2:0] flags,
                            input logic [31:0] freq_millihz,
                            input bit freq_valid,
                            input bit chain_first = 1);
    begin
      @(negedge clock);
      b_seq = next_seq;
      b_gen = generation;
      b_nominal = nominal[7:0];
      b_cycles = (nominal == 50) ? 8'd10 : 8'd12;
      b_count = sample_count;
      b_flags = flags;
      b_freq = freq_millihz;
      b_freq_valid = freq_valid;
      b_first = next_first;
      b_rms = '0;
      for (int c = 0; c < 7; c++)
        b_rms[c*64 +: 64] = rms_ch[c];
      // Junk in the unused CH7 lane: both engines must ignore it.
      b_rms[7*64 +: 64] = 64'hDEAD_BEEF_CAFE_F00D;
      basic_valid = 1'b1;
      @(negedge clock);
      basic_valid = 1'b0;
      next_seq += 1;
      if (chain_first)
        next_first += 64'(sample_count);
      repeat (EVENT_SPACING) @(posedge clock);
    end
  endtask

  // Wait until BOTH engines have emitted one aggregate, then compare all
  // paired fields. The engines finish at different latencies; each side's
  // outputs hold until its next aggregate, so comparing after the slower
  // emit observes the same aggregate on both.
  task automatic expect_equal_aggregates(input string label);
    int guard;
    begin
      guard = 0;
      while (!(r_sticky && h_sticky) && guard < 8000) begin
        @(posedge clock);
        guard += 1;
      end
      assert (r_sticky) else $fatal(1, "%s: RTL engine never emitted", label);
      assert (h_sticky) else $fatal(1, "%s: HLS engine never emitted", label);
      aggregates_seen += 1;

      assert (h_seq == r_seq)
        else $fatal(1, "%s: sequence %0d != %0d", label, h_seq, r_seq);
      assert (h_gen == r_gen)
        else $fatal(1, "%s: generation", label);
      assert (h_rate == r_rate)
        else $fatal(1, "%s: sample rate", label);
      assert (h_samples == r_samples)
        else $fatal(1, "%s: samples", label);
      assert (h_mask == r_mask)
        else $fatal(1, "%s: valid mask", label);
      assert (h_arith == r_arith)
        else $fatal(1, "%s: arithmetic flag", label);
      assert (h_freq_valid == r_freq_valid)
        else $fatal(1, "%s: frequency valid", label);
      assert (h_first_seq == r_first_seq)
        else $fatal(1, "%s: first seq %08h != %08h",
                    label, h_first_seq, r_first_seq);
      assert (h_last_seq == r_last_seq)
        else $fatal(1, "%s: last seq", label);
      assert (h_nominal == r_nominal)
        else $fatal(1, "%s: nominal", label);
      assert (h_cycles == r_cycles)
        else $fatal(1, "%s: cycles", label);
      assert (h_first_sample == r_first_sample)
        else $fatal(1, "%s: first sample", label);
      for (int c = 0; c < 8; c++)
        assert (h_rms[c*64 +: 64] == r_rms[c*64 +: 64])
          else $fatal(1, "%s: CH%0d rms %0h != %0h",
                      label, c, h_rms[c*64 +: 64], r_rms[c*64 +: 64]);
      assert (h_freq == r_freq)
        else $fatal(1, "%s: frequency", label);
      assert (h_record == r_record)
        else $fatal(1, "%s: record count %0d != %0d",
                    label, h_record, r_record);
      assert (h_record == aggregates_seen)
        else $fatal(1, "%s: record count %0d != expected %0d",
                    label, h_record, aggregates_seen);
      assert (h_inelig == r_inelig)
        else $fatal(1, "%s: ineligible count", label);
      assert (h_cont == r_cont)
        else $fatal(1, "%s: continuity count", label);
      assert (h_reset == r_reset)
        else $fatal(1, "%s: reset count (stimulus has no APPLY race)", label);

      r_sticky = 0;
      h_sticky = 0;
    end
  endtask

  logic [63:0] rms_in [7];

  initial begin
    repeat (5) @(posedge clock);
    resetn = 1'b1;

    // ---- T1: constant 60 Hz inputs ---------------------------------------
    for (int c = 0; c < 7; c++) rms_in[c] = 64'((c + 1) * 1000) << 16;
    for (int b = 0; b < 15; b++)
      send_basic(rms_in, 32'd7, 60, 32'd25600, 3'b001, 32'd60000, 1);
    expect_equal_aggregates("T1");

    // ---- T2: varying 50 Hz inputs with varying sample counts -------------
    for (int b = 0; b < 15; b++) begin
      for (int c = 0; c < 7; c++) rms_in[c] = 64'd5000 << 16;
      rms_in[0] = 64'((b + 1) * 1000) << 16;
      send_basic(rms_in, 32'd8, 50, 32'd25600 + b, 3'b001, 32'd49990 + b, 1);
    end
    expect_equal_aggregates("T2");

    // ---- T3: fallback input invalidates the running set ------------------
    for (int c = 0; c < 7; c++) rms_in[c] = 64'd2000 << 16;
    for (int b = 0; b < 7; b++)
      send_basic(rms_in, 32'd9, 60, 32'd25600, 3'b001, 32'd60000, 1);
    send_basic(rms_in, 32'd9, 60, 32'd25600, 3'b010, 32'd60000, 1);
    for (int b = 0; b < 15; b++)
      send_basic(rms_in, 32'd9, 60, 32'd25600, 3'b001, 32'd60000, 1);
    expect_equal_aggregates("T3");

    // ---- T4: generation change mid-aggregate -----------------------------
    for (int b = 0; b < 8; b++)
      send_basic(rms_in, 32'd10, 60, 32'd25600, 3'b001, 32'd60000, 1);
    for (int b = 0; b < 15; b++)
      send_basic(rms_in, 32'd11, 60, 32'd25600, 3'b001, 32'd60000, 1);
    expect_equal_aggregates("T4");

    // ---- T5: nominal change mid-aggregate --------------------------------
    for (int b = 0; b < 8; b++)
      send_basic(rms_in, 32'd12, 60, 32'd25600, 3'b001, 32'd60000, 1);
    for (int b = 0; b < 15; b++)
      send_basic(rms_in, 32'd12, 50, 32'd25600, 3'b001, 32'd50000, 1);
    expect_equal_aggregates("T5");

    // ---- T6: sample discontinuity ----------------------------------------
    for (int b = 0; b < 8; b++)
      send_basic(rms_in, 32'd13, 60, 32'd25600, 3'b001, 32'd60000, 1);
    next_first += 64'd100;
    for (int b = 0; b < 15; b++)
      send_basic(rms_in, 32'd13, 60, 32'd25600, 3'b001, 32'd60000, 1);
    expect_equal_aggregates("T6");

    // ---- T7: APPLY terminates the partial aggregate -----------------------
    for (int b = 0; b < 8; b++)
      send_basic(rms_in, 32'd14, 60, 32'd25600, 3'b001, 32'd60000, 1);
    @(negedge clock);
    apply_toggle = ~apply_toggle;
    repeat (4) @(posedge clock);
    for (int b = 0; b < 15; b++)
      send_basic(rms_in, 32'd14, 60, 32'd25600, 3'b001, 32'd60000, 1);
    expect_equal_aggregates("T7");

    // ---- T8: maximum-magnitude inputs -------------------------------------
    for (int c = 0; c < 7; c++) rms_in[c] = 64'h7fffffffffffffff;
    for (int b = 0; b < 15; b++)
      send_basic(rms_in, 32'd15, 60, 32'd25600, 3'b001, 32'd60000, 1);
    expect_equal_aggregates("T8");

    // ---- T9: one invalid frequency input ----------------------------------
    for (int c = 0; c < 7; c++) rms_in[c] = 64'd3000 << 16;
    for (int b = 0; b < 15; b++)
      send_basic(rms_in, 32'd16, 60, 32'd25600, 3'b001, 32'd60000, b != 7);
    expect_equal_aggregates("T9");

    // ---- T10: Basic sequence gap ------------------------------------------
    for (int c = 0; c < 7; c++) rms_in[c] = 64'd4000 << 16;
    for (int b = 0; b < 8; b++)
      send_basic(rms_in, 32'd17, 60, 32'd25600, 3'b001, 32'd60000, 1);
    next_seq += 1;
    for (int b = 0; b < 15; b++)
      send_basic(rms_in, 32'd17, 60, 32'd25600, 3'b001, 32'd60000, 1);
    expect_equal_aggregates("T10");

    // ---- T11: uint32 sequence wrap ----------------------------------------
    next_seq = 32'hFFFF_FFF8;
    for (int b = 0; b < 15; b++)
      send_basic(rms_in, 32'd18, 60, 32'd25600, 3'b001, 32'd60000, 1);
    expect_equal_aggregates("T11");

    // ---- T12: sample-rate change mid-aggregate ----------------------------
    for (int b = 0; b < 8; b++)
      send_basic(rms_in, 32'd19, 60, 32'd25600, 3'b001, 32'd60000, 1);
    b_rate = 32'd32000;
    for (int b = 0; b < 15; b++)
      send_basic(rms_in, 32'd19, 60, 32'd25600, 3'b001, 32'd60000, 1);
    expect_equal_aggregates("T12");

    assert (aggregates_seen == 12)
      else $fatal(1, "aggregate count %0d != 12", aggregates_seen);
    assert (h_drop == 0)
      else $fatal(1, "HLS shim dropped %0d events", h_drop);

    $display("PASS: meter_aggregator_equivalence_tb");
    $finish;
  end

  initial begin
    // 236 events x 2600 cycles x 10 ns plus emit waits.
    #80_000_000;
    $fatal(1, "meter_aggregator_equivalence_tb timeout");
  end
endmodule
