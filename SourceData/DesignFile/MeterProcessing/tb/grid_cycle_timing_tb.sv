`timescale 1ns/1ps

// Unit test for grid_cycle_timing.
//
// The DUT consumes the shared detector's combinational crossing view, so
// this bench drives crossing strobes directly and checks the block
// bookkeeping exactly:
//   * 50 Hz nominal -> 10 cycles per basic block, 60 Hz -> 12 cycles
//   * blocks stay gapless: first(N+1) = first(N) + count(N)
//   * off-nominal cycle lengths regroup by complete cycles, never by a
//     fixed sample count
//   * losing the reference falls back to the sample-count window and the
//     next qualified crossing re-locks, still gapless
//   * APPLY restarts block tracking and flags the first block
module grid_cycle_timing_tb;
  logic clock = 1'b0;
  logic resetn = 1'b0;

  logic frame_accept = 1'b0;
  logic [31:0] index_low = '0;
  logic [31:0] index_high = '0;
  logic rising = 1'b0;
  logic falling = 1'b0;
  logic reference_valid = 1'b1;
  logic [31:0] config_grid = '0;
  logic [31:0] config_window = 32'd100;
  logic apply_toggle = 1'b0;

  wire [31:0] active_grid;
  wire [31:0] status;
  wire frame_closes_block;
  wire cycle_mode;
  wire cycle_boundary;
  wire half_cycle_boundary;
  wire [31:0] cycle_sequence;
  wire [63:0] block_first_sample;
  wire [7:0] block_cycle_count;
  wire [7:0] block_nominal_hz;
  wire [2:0] block_flags;

  longint unsigned sample_index = 0;
  longint unsigned expected_first = 0;
  int close_count = 0;
  int half_cycle_count = 0;

  always #5 clock = ~clock;

  grid_cycle_timing dut (
    .aclk(clock),
    .aresetn(resetn),
    .frame_accept_i(frame_accept),
    .sample_index_low_i(index_low),
    .sample_index_high_i(index_high),
    .rising_crossing_i(rising),
    .falling_crossing_i(falling),
    .reference_valid_i(reference_valid),
    .config_grid_i(config_grid),
    .config_window_samples_i(config_window),
    .config_apply_toggle_i(apply_toggle),
    .active_grid_o(active_grid),
    .status_o(status),
    .frame_closes_block_o(frame_closes_block),
    .cycle_mode_o(cycle_mode),
    .cycle_boundary_o(cycle_boundary),
    .half_cycle_boundary_o(half_cycle_boundary),
    .cycle_sequence_o(cycle_sequence),
    .block_first_sample_o(block_first_sample),
    .block_cycle_count_o(block_cycle_count),
    .block_nominal_hz_o(block_nominal_hz),
    .block_flags_o(block_flags)
  );

  always @(posedge clock)
    if (half_cycle_boundary)
      half_cycle_count = half_cycle_count + 1;

  // One accepted frame. The crossing strobes model the detector's
  // combinational view, so they are only high while frame_accept is high.
  // Returns whether this frame closed a block.
  task automatic send_frame(input bit rise, input bit fall, input bit refv,
                            output bit closed);
    begin
      @(negedge clock);
      sample_index = sample_index + 1;
      index_low = sample_index[31:0];
      index_high = sample_index[63:32];
      rising = rise;
      falling = fall;
      reference_valid = refv;
      frame_accept = 1'b1;
      @(posedge clock);
      closed = frame_closes_block;
      @(negedge clock);
      frame_accept = 1'b0;
      rising = 1'b0;
      falling = 1'b0;
    end
  endtask

  // A complete simulated grid cycle: (frames_per_cycle - 1) plain frames,
  // then one frame carrying the rising crossing (with the matching falling
  // crossing half way through). Reports whether the crossing frame closed
  // the running block.
  task automatic send_cycle(input int frames_per_cycle, output bit closed);
    bit ignored;
    begin
      for (int i = 0; i < frames_per_cycle - 1; i++)
        send_frame(1'b0, i == (frames_per_cycle / 2) - 1, 1'b1, ignored);
      send_frame(1'b1, 1'b0, 1'b1, closed);
    end
  endtask

  // Every close must chain onto the previous block with no gap and no
  // overlap: first(N+1) = first(N) + count(N) = closing index + 1.
  task automatic check_close(input longint unsigned expected_count,
                             input int expected_cycles,
                             input bit expect_locked,
                             input bit expect_first_block,
                             input int expected_nominal);
    begin
      @(posedge clock); // closed-block registers update on the closing edge
      assert (block_first_sample == expected_first)
        else $fatal(1, "block first sample %0d, expected %0d",
                    block_first_sample, expected_first);
      assert (sample_index - block_first_sample + 1 == expected_count)
        else $fatal(1, "block spans %0d samples, expected %0d",
                    sample_index - block_first_sample + 1, expected_count);
      assert (block_cycle_count == expected_cycles)
        else $fatal(1, "block cycle count %0d, expected %0d",
                    block_cycle_count, expected_cycles);
      assert (block_flags[0] == expect_locked)
        else $fatal(1, "cycle_locked flag mismatch");
      assert (block_flags[1] == !expect_locked)
        else $fatal(1, "free_run_fallback flag mismatch");
      assert (block_flags[2] == expect_first_block)
        else $fatal(1, "first_block_after_apply flag mismatch");
      assert (block_nominal_hz == expected_nominal)
        else $fatal(1, "nominal frequency mismatch");
      expected_first = sample_index + 1;
      close_count = close_count + 1;
    end
  endtask

  task automatic apply_config(input int cycles, input int nominal,
                              input int window);
    begin
      @(negedge clock);
      config_grid = {15'd0, 1'b1, nominal[7:0], cycles[7:0]};
      config_window = window;
      apply_toggle = ~apply_toggle;
      repeat (2) @(posedge clock);
      assert (active_grid == config_grid)
        else $fatal(1, "active grid config readback mismatch");
      assert (cycle_mode) else $fatal(1, "cycle mode not active");
      // The next accepted frame opens the first block of the new config.
      expected_first = sample_index + 1;
    end
  endtask

  bit closed;
  longint unsigned counter_check;

  initial begin
    repeat (5) @(posedge clock);
    resetn = 1'b1;

    // ---- 50 Hz: 10 cycles per basic block, 8 frames per scaled cycle ----
    apply_config(10, 50, 100);

    // Startup is unlocked; the first qualified crossing closes the initial
    // partial block and re-locks. 8 frames -> block of 8 samples, 0 cycles.
    send_cycle(8, closed);
    assert (closed) else $fatal(1, "startup crossing did not close a block");
    check_close(8, 0, 1'b0, 1'b1, 50);

    // Locked operation: exactly 10 complete cycles close each block.
    for (int block = 0; block < 2; block++) begin
      for (int c = 0; c < 9; c++) begin
        send_cycle(8, closed);
        assert (!closed) else $fatal(1, "block closed after only %0d cycles", c + 1);
      end
      send_cycle(8, closed);
      assert (closed) else $fatal(1, "10th cycle did not close the block");
      check_close(80, 10, 1'b1, 1'b0, 50);
    end
    assert (status[0]) else $fatal(1, "not locked during cycle operation");

    // Off-nominal grid: 7- and 9-frame cycles still group 10 complete
    // cycles; the sample count follows the grid, not the configuration.
    for (int c = 0; c < 9; c++) send_cycle(7, closed);
    send_cycle(7, closed);
    assert (closed) else $fatal(1, "off-nominal fast block did not close");
    check_close(70, 10, 1'b1, 1'b0, 50);

    for (int c = 0; c < 9; c++) send_cycle(9, closed);
    send_cycle(9, closed);
    assert (closed) else $fatal(1, "off-nominal slow block did not close");
    check_close(90, 10, 1'b1, 1'b0, 50);

    // ---- Reference loss: fallback to the sample-count window ----
    // No crossings arrive; after window/4 stale samples the lock drops and
    // the block closes at the fallback window (100 samples), flagged.
    for (int i = 0; i < 99; i++) begin
      send_frame(1'b0, 1'b0, 1'b1, closed);
      assert (!closed) else $fatal(1, "fallback closed early at %0d", i + 1);
    end
    send_frame(1'b0, 1'b0, 1'b1, closed);
    assert (closed) else $fatal(1, "fallback window did not close the block");
    check_close(100, 0, 1'b0, 1'b0, 50);
    assert (!status[0]) else $fatal(1, "still locked without crossings");

    // Recovery: the next qualified crossing closes the partial fallback
    // block immediately and re-locks, keeping the chain gapless.
    for (int i = 0; i < 4; i++) send_frame(1'b0, 1'b0, 1'b1, closed);
    send_frame(1'b1, 1'b0, 1'b1, closed);
    assert (closed) else $fatal(1, "re-lock crossing did not close the block");
    check_close(5, 0, 1'b0, 1'b0, 50);

    for (int c = 0; c < 9; c++) send_cycle(8, closed);
    send_cycle(8, closed);
    assert (closed) else $fatal(1, "block after re-lock did not close");
    check_close(80, 10, 1'b1, 1'b0, 50);

    // ---- 60 Hz: 12 cycles per basic block, APPLY restarts cleanly ----
    counter_check = sample_index;
    apply_config(12, 60, 96);
    assert (sample_index == counter_check)
      else $fatal(1, "APPLY must never disturb the sample counter");

    send_cycle(8, closed); // re-acquire lock after the apply reset
    check_close(8, 0, 1'b0, 1'b1, 60);
    for (int c = 0; c < 11; c++) begin
      send_cycle(8, closed);
      assert (!closed) else $fatal(1, "60 Hz block closed after %0d cycles", c + 1);
    end
    send_cycle(8, closed);
    assert (closed) else $fatal(1, "12th cycle did not close the 60 Hz block");
    check_close(96, 12, 1'b1, 1'b0, 60);

    // Half-cycle boundaries: every simulated cycle carried one falling and
    // one rising crossing, so the strobe count must be twice the rising
    // count observed by cycle_sequence (plus the lone re-lock crossing).
    assert (half_cycle_count > 0 && cycle_sequence > 0)
      else $fatal(1, "cycle/half-cycle strobes missing");

    // ---- Closed-block provenance is atomic across APPLY ----
    // The 12-cycle 60 Hz block above is closed but its metadata may not
    // have been consumed yet (the RMS result is still in flight in the
    // real pipeline). Applying a 50 Hz configuration now must NOT relabel
    // the finished block: nominal, cycle count, first sample, and flags
    // all describe the block as it closed.
    counter_check = block_first_sample;
    @(negedge clock);
    config_grid = {15'd0, 1'b1, 8'd50, 8'd10};
    config_window = 32'd100;
    apply_toggle = ~apply_toggle;
    repeat (3) @(posedge clock);
    assert (block_nominal_hz == 60)
      else $fatal(1, "closed-block nominal relabeled by APPLY: %0d",
                  block_nominal_hz);
    assert (block_cycle_count == 12)
      else $fatal(1, "closed-block cycle count changed by APPLY");
    assert (block_first_sample == counter_check)
      else $fatal(1, "closed-block first sample changed by APPLY");
    assert (block_flags[0] && !block_flags[1])
      else $fatal(1, "closed-block flags changed by APPLY");
    // The new configuration is active for FUTURE blocks only.
    assert (active_grid == {15'd0, 1'b1, 8'd50, 8'd10})
      else $fatal(1, "50 Hz configuration did not become active");

    $display("PASS: grid_cycle_timing_tb");
    $finish;
  end

  initial begin
    #1_000_000;
    $fatal(1, "grid_cycle_timing_tb timeout");
  end
endmodule
