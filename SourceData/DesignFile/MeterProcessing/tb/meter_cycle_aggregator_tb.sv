`timescale 1ns/1ps

// Unit test for meter_cycle_aggregator (via the record-port shim).
//
// The bench embeds a wide-integer golden model of the pinned aggregation
// arithmetic -- agg = floor(sqrt(floor(sum(x_i^2)/15))) for RMS lanes and
// floor(sum(f_i)/15) for frequency -- and drives synthetic Basic results
// covering: constant and deliberately varying inputs, 50 Hz (10-cycle) and
// 60 Hz (12-cycle) shapes, off-nominal sample-count variation, ineligible
// (fallback) inputs, generation change, nominal change, sample
// discontinuity, APPLY mid-aggregate, maximum-magnitude inputs, and an
// invalid frequency input.
module meter_cycle_aggregator_tb;
  logic clock = 1'b0;
  logic resetn = 1'b0;

  logic basic_valid = 1'b0;
  logic [31:0] b_seq = '0, b_gen = '0, b_rate = 32'd128000, b_count = '0;
  logic [7:0] b_mask = 8'h7f;
  logic [31:0] b_status = '0;
  logic [511:0] b_rms = '0;
  logic [63:0] b_first = '0;
  logic [7:0] b_cycles = '0, b_nominal = '0;
  logic [2:0] b_flags = 3'b001; // locked
  logic [31:0] b_freq = 32'd60000;
  logic b_freq_valid = 1'b1;
  logic apply_toggle = 1'b0;

  wire agg_valid;
  wire [31:0] agg_seq, agg_gen, agg_rate, agg_samples;
  wire [7:0] agg_mask;
  wire agg_arith, agg_freq_valid;
  wire [31:0] agg_first_seq, agg_last_seq;
  wire [7:0] agg_nominal;
  wire [15:0] agg_cycles;
  wire [63:0] agg_first_sample;
  wire [511:0] agg_rms;
  wire [31:0] agg_freq;
  wire [31:0] status, record_count, reset_count, ineligible_count,
              continuity_count;

  always #5 clock = ~clock;

  meter_cycle_aggregator_tbshim dut (
    .aclk(clock), .aresetn(resetn),
    .basic_valid_i(basic_valid), .basic_sequence_i(b_seq),
    .basic_generation_i(b_gen), .basic_sample_rate_i(b_rate),
    .basic_sample_count_i(b_count), .basic_valid_mask_i(b_mask),
    .basic_status_i(b_status), .basic_rms_q16_i(b_rms),
    .basic_first_sample_i(b_first), .basic_cycle_count_i(b_cycles),
    .basic_nominal_hz_i(b_nominal), .basic_flags_i(b_flags),
    .basic_freq_millihz_i(b_freq), .basic_freq_valid_i(b_freq_valid),
    .config_apply_toggle_i(apply_toggle),
    .aggregate_valid_o(agg_valid), .aggregate_sequence_o(agg_seq),
    .aggregate_generation_o(agg_gen), .aggregate_sample_rate_o(agg_rate),
    .aggregate_samples_o(agg_samples), .aggregate_valid_mask_o(agg_mask),
    .aggregate_arithmetic_o(agg_arith),
    .aggregate_freq_valid_o(agg_freq_valid),
    .aggregate_first_seq_o(agg_first_seq),
    .aggregate_last_seq_o(agg_last_seq),
    .aggregate_nominal_o(agg_nominal), .aggregate_cycles_o(agg_cycles),
    .aggregate_first_sample_o(agg_first_sample),
    .aggregate_rms_q16_o(agg_rms), .aggregate_freq_millihz_o(agg_freq),
    .status_o(status), .record_count_o(record_count),
    .reset_count_o(reset_count), .ineligible_count_o(ineligible_count),
    .continuity_count_o(continuity_count)
  );

  // ---- Golden model ------------------------------------------------------
  // floor(sqrt(floor(sum(v_i^2)/15))): identical rounding to the RTL.
  function automatic logic [63:0] golden_rms(input logic [63:0] v [15]);
    logic [131:0] acc;
    logic [131:0] mean;
    logic [127:0] radicand, square;
    logic [63:0] low, high, mid;
    logic [64:0] mid_sum;
    begin
      acc = '0;
      for (int i = 0; i < 15; i++)
        acc += 132'(v[i]) * 132'(v[i]);
      mean = acc / 132'd15;
      radicand = mean[127:0];
      low = '0;
      high = '1;
      for (int i = 0; i < 64; i++) begin
        mid_sum = {1'b0, low} + {1'b0, high} + 65'd1;
        mid = mid_sum[64:1];
        square = 128'(mid) * 128'(mid);
        if (square <= radicand) low = mid;
        else high = mid - 64'd1;
      end
      return low;
    end
  endfunction

  // ---- Drivers -----------------------------------------------------------
  int unsigned next_seq = 1;
  logic [63:0] next_first = 64'd1000;

  // One Basic result event. rms_all applies one value to CH0..CH6.
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
      basic_valid = 1'b1;
      @(negedge clock);
      basic_valid = 1'b0;
      next_seq += 1;
      if (chain_first)
        next_first += 64'(sample_count);
      // Cover the 7-cycle square/accumulate walk before the next event.
      repeat (12) @(posedge clock);
    end
  endtask

  task automatic wait_aggregate(output bit seen);
    int guard;
    begin
      seen = 0;
      guard = 0;
      while (!seen && guard < 5000) begin
        @(posedge clock);
        if (agg_valid) seen = 1;
        guard += 1;
      end
    end
  endtask

  task automatic expect_no_aggregate(input int cycles);
    begin
      repeat (cycles) begin
        @(posedge clock);
        assert (!agg_valid) else $fatal(1, "unexpected aggregate emitted");
      end
    end
  endtask

  logic [63:0] rms_in [7];
  logic [63:0] series [15];
  logic [63:0] expected;
  logic [63:0] first_sample_expect;
  logic [31:0] first_seq_expect;
  bit seen;

  initial begin
    repeat (5) @(posedge clock);
    resetn = 1'b1;

    // ---- T1: constant 60 Hz inputs -> aggregate equals the input --------
    for (int c = 0; c < 7; c++) rms_in[c] = 64'((c + 1) * 1000) << 16;
    first_sample_expect = next_first;
    first_seq_expect = next_seq;
    for (int b = 0; b < 15; b++)
      send_basic(rms_in, 32'd7, 60, 32'd25600, 3'b001, 32'd60000, 1);
    wait_aggregate(seen);
    assert (seen) else $fatal(1, "T1: no aggregate");
    assert (agg_seq == 1 && agg_gen == 7) else $fatal(1, "T1: header");
    assert (agg_samples == 15 * 25600) else $fatal(1, "T1: samples");
    assert (agg_cycles == 180 && agg_nominal == 60)
      else $fatal(1, "T1: shape %0d/%0d", agg_cycles, agg_nominal);
    assert (agg_first_seq == first_seq_expect &&
            agg_last_seq == first_seq_expect + 14)
      else $fatal(1, "T1: basic sequence span");
    assert (agg_first_sample == first_sample_expect)
      else $fatal(1, "T1: first sample");
    assert (agg_mask == 8'h7f && !agg_arith) else $fatal(1, "T1: mask/arith");
    for (int c = 0; c < 7; c++)
      assert (agg_rms[c*64 +: 64] == rms_in[c])
        else $fatal(1, "T1: CH%0d %0d != %0d", c,
                    agg_rms[c*64 +: 64], rms_in[c]);
    assert (agg_freq_valid && agg_freq == 32'd60000)
      else $fatal(1, "T1: frequency");
    assert (record_count == 1) else $fatal(1, "T1: record count");

    // ---- T2: varying 50 Hz inputs with varying sample counts ------------
    // CH0 ramps so an arithmetic mistake is visible; frequency ramps too.
    first_sample_expect = next_first;
    for (int b = 0; b < 15; b++) begin
      series[b] = 64'((b + 1) * 1000) << 16;
      for (int c = 0; c < 7; c++) rms_in[c] = 64'd5000 << 16;
      rms_in[0] = series[b];
      send_basic(rms_in, 32'd8, 50, 32'd25600 + b, 3'b001,
                 32'd49990 + b, 1);
    end
    wait_aggregate(seen);
    assert (seen) else $fatal(1, "T2: no aggregate");
    expected = golden_rms(series);
    assert (agg_rms[63:0] == expected)
      else $fatal(1, "T2: CH0 %0d != golden %0d", agg_rms[63:0], expected);
    assert (agg_rms[127:64] == (64'd5000 << 16))
      else $fatal(1, "T2: constant lane disturbed");
    assert (agg_cycles == 150 && agg_nominal == 50)
      else $fatal(1, "T2: shape");
    begin
      automatic logic [63:0] fsum = 0;
      for (int b = 0; b < 15; b++) fsum += 64'd49990 + b;
      assert (agg_freq == fsum / 15) else $fatal(1, "T2: frequency mean");
    end
    begin
      automatic logic [31:0] total = 0;
      for (int b = 0; b < 15; b++) total += 32'd25600 + b;
      assert (agg_samples == total) else $fatal(1, "T2: varying samples");
    end
    assert (agg_first_sample == first_sample_expect) else $fatal(1, "T2: first");
    assert (record_count == 2) else $fatal(1, "T2: record count");

    // ---- T3: fallback input invalidates the running set -----------------
    for (int c = 0; c < 7; c++) rms_in[c] = 64'd2000 << 16;
    for (int b = 0; b < 7; b++)
      send_basic(rms_in, 32'd9, 60, 32'd25600, 3'b001, 32'd60000, 1);
    // Fallback block: eligible=false, must reset and never seed.
    send_basic(rms_in, 32'd9, 60, 32'd25600, 3'b010, 32'd60000, 1);
    expect_no_aggregate(50);
    first_seq_expect = next_seq;
    first_sample_expect = next_first;
    for (int b = 0; b < 15; b++)
      send_basic(rms_in, 32'd9, 60, 32'd25600, 3'b001, 32'd60000, 1);
    wait_aggregate(seen);
    assert (seen) else $fatal(1, "T3: no aggregate after recovery");
    assert (agg_first_seq == first_seq_expect)
      else $fatal(1, "T3: aggregate must restart after the fallback block");
    assert (ineligible_count == 1) else $fatal(1, "T3: ineligible count");
    assert (record_count == 3) else $fatal(1, "T3: record count");

    // ---- T4: generation change mid-aggregate resets and reseeds ---------
    for (int b = 0; b < 8; b++)
      send_basic(rms_in, 32'd10, 60, 32'd25600, 3'b001, 32'd60000, 1);
    first_seq_expect = next_seq;
    for (int b = 0; b < 15; b++)
      send_basic(rms_in, 32'd11, 60, 32'd25600, 3'b001, 32'd60000, 1);
    wait_aggregate(seen);
    assert (seen && agg_gen == 11 && agg_first_seq == first_seq_expect)
      else $fatal(1, "T4: generation integrity");
    assert (record_count == 4) else $fatal(1, "T4: record count");

    // ---- T5: nominal change mid-aggregate resets and reseeds ------------
    for (int b = 0; b < 8; b++)
      send_basic(rms_in, 32'd12, 60, 32'd25600, 3'b001, 32'd60000, 1);
    first_seq_expect = next_seq;
    for (int b = 0; b < 15; b++)
      send_basic(rms_in, 32'd12, 50, 32'd25600, 3'b001, 32'd50000, 1);
    wait_aggregate(seen);
    assert (seen && agg_nominal == 50 && agg_cycles == 150 &&
            agg_first_seq == first_seq_expect)
      else $fatal(1, "T5: nominal integrity");
    assert (record_count == 5) else $fatal(1, "T5: record count");

    // ---- T6: sample discontinuity resets and reseeds ---------------------
    for (int b = 0; b < 8; b++)
      send_basic(rms_in, 32'd13, 60, 32'd25600, 3'b001, 32'd60000, 1);
    next_first += 64'd100; // break the chain
    first_seq_expect = next_seq;
    first_sample_expect = next_first;
    for (int b = 0; b < 15; b++)
      send_basic(rms_in, 32'd13, 60, 32'd25600, 3'b001, 32'd60000, 1);
    wait_aggregate(seen);
    assert (seen && agg_first_seq == first_seq_expect &&
            agg_first_sample == first_sample_expect)
      else $fatal(1, "T6: continuity integrity");
    assert (continuity_count == 1) else $fatal(1, "T6: continuity count");
    assert (record_count == 6) else $fatal(1, "T6: record count");

    // ---- T7: APPLY terminates the partial aggregate ----------------------
    for (int b = 0; b < 8; b++)
      send_basic(rms_in, 32'd14, 60, 32'd25600, 3'b001, 32'd60000, 1);
    @(negedge clock);
    apply_toggle = ~apply_toggle;
    repeat (4) @(posedge clock);
    first_seq_expect = next_seq;
    for (int b = 0; b < 15; b++)
      send_basic(rms_in, 32'd14, 60, 32'd25600, 3'b001, 32'd60000, 1);
    wait_aggregate(seen);
    assert (seen && agg_first_seq == first_seq_expect)
      else $fatal(1, "T7: APPLY must reset the partial aggregate");
    assert (record_count == 7) else $fatal(1, "T7: record count");

    // ---- T8: maximum-magnitude inputs cannot overflow --------------------
    for (int c = 0; c < 7; c++) rms_in[c] = 64'h7fffffffffffffff;
    for (int b = 0; b < 15; b++)
      send_basic(rms_in, 32'd15, 60, 32'd25600, 3'b001, 32'd60000, 1);
    wait_aggregate(seen);
    assert (seen) else $fatal(1, "T8: no aggregate");
    for (int c = 0; c < 7; c++)
      assert (agg_rms[c*64 +: 64] == 64'h7fffffffffffffff)
        else $fatal(1, "T8: CH%0d max-value aggregate mismatch", c);
    assert (!agg_arith) else $fatal(1, "T8: spurious arithmetic flag");
    assert (record_count == 8) else $fatal(1, "T8: record count");

    // ---- T9: one invalid frequency input invalidates the mean -----------
    for (int c = 0; c < 7; c++) rms_in[c] = 64'd3000 << 16;
    for (int b = 0; b < 15; b++)
      send_basic(rms_in, 32'd16, 60, 32'd25600, 3'b001, 32'd60000,
                 b != 7); // block 8 carries an invalid frequency
    wait_aggregate(seen);
    assert (seen) else $fatal(1, "T9: no aggregate");
    assert (!agg_freq_valid && agg_freq == 0)
      else $fatal(1, "T9: frequency must be flagged invalid");
    assert (agg_rms[63:0] == (64'd3000 << 16))
      else $fatal(1, "T9: RMS unaffected by frequency validity");
    assert (record_count == 9) else $fatal(1, "T9: record count");

    assert (reset_count > 0) else $fatal(1, "reset diagnostics missing");
    $display("PASS: meter_cycle_aggregator_tb");
    $finish;
  end

  initial begin
    #4_000_000;
    $fatal(1, "meter_cycle_aggregator_tb timeout");
  end
endmodule
