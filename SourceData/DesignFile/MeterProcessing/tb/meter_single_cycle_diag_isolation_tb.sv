`timescale 1ns/1ps

// Regression for the authoritative/diagnostic single-cycle stream split.
//
// The 221-word m_result stream is the lossless input to R5C1 aggregation.
// The 64-word M_AXIS_SCYC stream is an optional diagnostic view.  A stopped
// or congested diagnostic consumer must never stall m_result or fill the
// converted-frame FIFO.  Keep diagnostic TREADY low for the entire test and
// run for more records than the diagnostic FIFO can retain; authoritative
// packets must continue and the input-frame drop counter must remain zero.
module meter_single_cycle_diag_isolation_tb;
  logic clock = 1'b0;
  logic resetn = 1'b0;
  always #5 clock = ~clock;

  localparam int FRAMES_PER_CYCLE = 8;
  localparam int TEST_CYCLES = 24;
  localparam int FRAME_GAP = 600;
  localparam int RESULT_WORDS = 221;

  logic frame_accept = 1'b0;
  logic [383:0] frame_data = '0;
  logic [47:0] frame_keep = '1;
  logic [383:0] frame_user = '0;
  logic cycle_boundary = 1'b0;
  logic [31:0] cycle_sequence = 32'd100;
  logic apply_toggle = 1'b0;
  logic [63:0] pl_tick = 64'd50_000;

  wire [31:0] diagnostic_tdata;
  wire [3:0] diagnostic_tkeep;
  wire diagnostic_tvalid;
  wire diagnostic_tlast;
  wire [31:0] result_tdata;
  wire result_tvalid;
  logic result_tready = 1'b1;
  wire [31:0] drop_count;

  int result_word = 0;
  int result_packets = 0;
  bit diagnostic_became_valid = 1'b0;
  longint sample_index = 64'd1000;

  meter_single_cycle_hls_shim dut (
    .aclk(clock),
    .aresetn(resetn),
    .frame_accept_i(frame_accept),
    .frame_data_i(frame_data),
    .frame_keep_i(frame_keep),
    .frame_user_i(frame_user),
    .cycle_boundary_i(cycle_boundary),
    .cycle_sequence_i(cycle_sequence),
    .cycle_mode_i(1'b1),
    .block_nominal_hz_i(8'd50),
    .block_flags_i(3'b001),
    .shadow_generation_i(32'd1),
    .shadow_sample_rate_i(32'd32000),
    .shadow_valid_mask_i(8'h7F),
    .shadow_enable_i(1'b1),
    .shadow_dc_remove_i(1'b0),
    .config_apply_toggle_i(apply_toggle),
    .pl_tick_i(pl_tick),
    .frequency_millihz_i(32'd50000),
    .frequency_status_i(32'h0000_0032),
    .m_axis_scyc_tdata(diagnostic_tdata),
    .m_axis_scyc_tkeep(diagnostic_tkeep),
    .m_axis_scyc_tvalid(diagnostic_tvalid),
    .m_axis_scyc_tready(1'b0),
    .m_axis_scyc_tlast(diagnostic_tlast),
    .m_result_tdata(result_tdata),
    .m_result_tvalid(result_tvalid),
    .m_result_tready(result_tready),
    .drop_count_o(drop_count)
  );

  always @(posedge clock) begin
    if (!resetn) begin
      result_word <= 0;
      result_packets <= 0;
      diagnostic_became_valid <= 1'b0;
    end else begin
      if (diagnostic_tvalid)
        diagnostic_became_valid <= 1'b1;

      if (result_tvalid && result_tready) begin
        if (result_word == RESULT_WORDS - 1) begin
          result_word <= 0;
          result_packets <= result_packets + 1;
        end else begin
          result_word <= result_word + 1;
        end
      end
    end
  end

  task automatic send_frame(input bit closes_cycle);
    // Drive mixed-language DUT inputs away from the VHDL rising-edge sample.
    // Assigning immediately after @(posedge clock) races the VHDL process and
    // can make an accepted frame disappear under a different simulator order.
    @(negedge clock);
    frame_user[31:0] = sample_index[31:0];
    frame_user[105:74] = sample_index[63:32];
    sample_index = sample_index + 1;
    pl_tick = pl_tick + 10;

    frame_accept = 1'b1;
    @(posedge clock);
    @(negedge clock);
    frame_accept = 1'b0;

    // grid_cycle_timing registers the close indication one cycle after the
    // crossing frame.  The shim deliberately samples it while that frame is
    // staged, so reproduce that alignment here.
    cycle_boundary = closes_cycle;
    if (closes_cycle)
      cycle_sequence = cycle_sequence + 1;
    @(posedge clock);
    @(negedge clock);
    cycle_boundary = 1'b0;
    repeat (FRAME_GAP - 2) @(posedge clock);
  endtask

  task automatic wait_for_result_packet(input int expected_packets);
    int wait_cycles = 0;
    while (result_packets < expected_packets && wait_cycles < 500_000) begin
      @(posedge clock);
      wait_cycles = wait_cycles + 1;
    end
    assert (result_packets >= expected_packets)
      else $fatal(1,
        "authoritative result stalled at packet %0d: completed=%0d words=%0d diagnostic_valid=%0b input_drops=%0d",
        expected_packets, result_packets, result_word, diagnostic_tvalid,
        drop_count);
  endtask

  initial begin
    for (int lane = 0; lane < 8; ++lane) begin
      frame_data[lane*48 +: 48] = 48'((lane + 1) << 16);
      frame_user[128 + lane*32 +: 32] = 32'((lane + 1) * 100);
    end
    frame_user[63:32] = 32'd1;
    frame_user[71:64] = 8'h7F;

    repeat (8) @(posedge clock);
    @(negedge clock);
    resetn = 1'b1;
    repeat (8) @(posedge clock);

    // APPLY carrier, followed by the synchronization cycle discarded by the
    // engine's await-boundary rule.
    apply_toggle = 1'b1;
    send_frame(1'b0);
    for (int frame = 0; frame < FRAMES_PER_CYCLE; ++frame)
      send_frame(frame == FRAMES_PER_CYCLE - 1);

    // Twenty-four records exceed the 16-record diagnostic queue.  The final
    // eight diagnostic records must be discarded atomically while every
    // authoritative result continues to R5C1.  Wait for each authoritative
    // result before beginning the next artificial eight-sample cycle.  The
    // tiny cycle is deliberately useful for simulation speed, but without
    // this wait it would request grid-cycle finalization much faster than a
    // real 50/60 Hz input and test finalizer throughput instead of diagnostic
    // stream isolation.
    for (int cycle = 0; cycle < TEST_CYCLES; ++cycle) begin
      for (int frame = 0; frame < FRAMES_PER_CYCLE; ++frame)
        send_frame(frame == FRAMES_PER_CYCLE - 1);
      wait_for_result_packet(cycle + 1);
    end

    repeat (1000) @(posedge clock);

    assert (diagnostic_became_valid)
      else $fatal(1, "diagnostic stream never produced a record");
    assert (result_packets == TEST_CYCLES && result_word == 0)
      else $fatal(1,
        "authoritative result packets %0d with %0d trailing words, expected %0d complete packets",
        result_packets, result_word, TEST_CYCLES);
    assert (drop_count == 0)
      else $fatal(1, "single-cycle shim dropped %0d input frames", drop_count);

    $display("PASS: diagnostic backpressure isolated (%0d authoritative packets, zero input drops)",
             result_packets);
    $finish;
  end

  initial begin
    #50ms;
    $fatal(1, "timeout");
  end
endmodule
