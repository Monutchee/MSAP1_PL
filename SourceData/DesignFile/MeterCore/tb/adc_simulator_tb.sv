`timescale 1ns/1ps

// Unit test for the ADC simulator's deterministic infrastructure plus an
// end-to-end fidelity spot check through the packaged HLS waveform
// engine (whose mathematics is exhaustively verified by its own
// csim/cosim golden testbench).
//
// Covered here: register file and version, shadow/APPLY banking, scheduler
// pacing with the engine in the loop, AXIS framing/TLAST across packets,
// backpressure hold, missed-sample accounting, DC offset, noise
// liveness/bounds, preserve-phase APPLY versus restarting APPLY, rail
// clamping with saturation counting, the COUNTER_CLEAR strobes, and the
// event sequencer (half-cycle alignment, duration, channel mask, repeat,
// cancel, scale clamp).
module adc_simulator_tb;
  // 10 kHz virtual clock rate with a 100 frame/s configuration: one frame
  // tick every 100 clocks, comfortably above the engine's compute latency
  // so nominal operation misses no ticks.
  localparam int unsigned ACLK_HZ = 10000;
  localparam int unsigned FRAME_RATE = 100;

  logic clock = 1'b0;
  logic resetn = 1'b0;
  logic [11:0] awaddr = '0;
  logic awvalid = 1'b0;
  wire awready;
  logic [31:0] wdata = '0;
  logic [3:0] wstrb = 4'hf;
  logic wvalid = 1'b0;
  wire wready;
  wire [1:0] bresp;
  wire bvalid;
  logic bready = 1'b1;
  logic [11:0] araddr = '0;
  logic arvalid = 1'b0;
  wire arready;
  wire [31:0] rdata;
  wire [1:0] rresp;
  wire rvalid;
  logic rready = 1'b1;
  wire [31:0] axis_data;
  wire [3:0] axis_keep;
  wire axis_valid;
  logic axis_ready = 1'b0;
  wire axis_last;
  wire source_select;
  wire [31:0] frame_count;
  wire [31:0] frame_rate;
  wire frame_rate_valid;
  wire [31:0] saturation_count;

  logic [31:0] value;
  logic [31:0] held_data;

  always #5 clock = ~clock;

  adc_simulator #(.G_ACLK_HZ(ACLK_HZ), .G_PACKET_FRAMES(2)) dut (
    .aclk(clock), .aresetn(resetn),
    .s_axi_awaddr(awaddr), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
    .s_axi_wdata(wdata), .s_axi_wstrb(wstrb), .s_axi_wvalid(wvalid), .s_axi_wready(wready),
    .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
    .s_axi_araddr(araddr), .s_axi_arvalid(arvalid), .s_axi_arready(arready),
    .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rvalid(rvalid), .s_axi_rready(rready),
    .m_axis_tdata(axis_data), .m_axis_tkeep(axis_keep), .m_axis_tvalid(axis_valid),
    .m_axis_tready(axis_ready), .m_axis_tlast(axis_last),
    .source_select_o(source_select), .frame_count_o(frame_count),
    .frame_rate_hz_o(frame_rate), .frame_rate_valid_o(frame_rate_valid),
    .saturation_count_o(saturation_count)
  );

  task automatic write_reg(input logic [11:0] address, input logic [31:0] data);
    begin
      @(negedge clock);
      awaddr = address;
      wdata = data;
      awvalid = 1'b1;
      wvalid = 1'b1;
      do @(posedge clock); while (!(awready && wready));
      @(negedge clock);
      awvalid = 1'b0;
      wvalid = 1'b0;
      do @(posedge clock); while (!bvalid);
      assert (bresp == 2'b00) else $fatal(1, "simulator AXI write failed");
    end
  endtask

  task automatic read_reg(input logic [11:0] address, output logic [31:0] data);
    begin
      @(negedge clock);
      araddr = address;
      arvalid = 1'b1;
      do @(posedge clock); while (!arready);
      @(negedge clock);
      arvalid = 1'b0;
      do @(posedge clock); while (!rvalid);
      assert (rresp == 2'b00) else $fatal(1, "simulator AXI read failed");
      data = rdata;
    end
  endtask

  // Consume one 8-beat frame. CH0 must match expected_ch0 within
  // tolerance; all other channels must be exactly zero (single-channel
  // mask configurations only).
  task automatic consume_frame(input integer expected_ch0,
                               input integer tolerance,
                               input bit expected_packet_last);
    integer beat;
    integer got;
    begin
      beat = 0;
      while (beat < 8) begin
        axis_ready = 1'b0;
        wait (axis_valid);
        #1ps;
        assert (axis_keep == 4'hf) else $fatal(1, "bad simulator TKEEP");
        got = $signed(axis_data);
        if (beat == 0)
          assert ((got >= expected_ch0 - tolerance) &&
                  (got <= expected_ch0 + tolerance))
            else $fatal(1, "CH0 mismatch: expected %0d +/- %0d got %0d",
                        expected_ch0, tolerance, got);
        else
          assert (got == 0)
            else $fatal(1, "disabled channel %0d was not zero: %0d", beat, got);
        assert (axis_last == (expected_packet_last && beat == 7))
          else $fatal(1, "simulator TLAST mismatch at beat %0d", beat);
        @(negedge clock);
        axis_ready = 1'b1;
        @(negedge clock);
        axis_ready = 1'b0;
        beat++;
      end
    end
  endtask

  // Consume one frame and hand CH0 and CH1 back (event mask checks).
  task automatic consume_frame_pair(output integer ch0, output integer ch1,
                                    input bit expected_packet_last);
    integer beat;
    begin
      beat = 0;
      while (beat < 8) begin
        axis_ready = 1'b0;
        wait (axis_valid);
        #1ps;
        if (beat == 0) ch0 = $signed(axis_data);
        if (beat == 1) ch1 = $signed(axis_data);
        assert (axis_last == (expected_packet_last && beat == 7))
          else $fatal(1, "simulator TLAST mismatch at beat %0d", beat);
        @(negedge clock);
        axis_ready = 1'b1;
        @(negedge clock);
        axis_ready = 1'b0;
        beat++;
      end
    end
  endtask

  // Consume one frame and hand CH0 back to the caller (noise checks).
  task automatic consume_frame_ch0(output integer ch0,
                                   input bit expected_packet_last);
    integer beat;
    begin
      beat = 0;
      while (beat < 8) begin
        axis_ready = 1'b0;
        wait (axis_valid);
        #1ps;
        if (beat == 0) ch0 = $signed(axis_data);
        assert (axis_last == (expected_packet_last && beat == 7))
          else $fatal(1, "simulator TLAST mismatch at beat %0d", beat);
        @(negedge clock);
        axis_ready = 1'b1;
        @(negedge clock);
        axis_ready = 1'b0;
        beat++;
      end
    end
  endtask

  // Stop generation and commit, so shadow edits never race a running
  // frame (the RPU controller's source-transaction contract).
  task automatic stop_and_apply_idle;
    begin
      axis_ready = 1'b1;
      write_reg(12'h008, 32'h0000_0000);
      write_reg(12'h01c, 32'h0000_0001);
      wait (!source_select);
      axis_ready = 1'b0;
    end
  endtask

  // The engine's amplitude convention for a full-scale-accurate
  // expectation: peak * sin(turns) * 131071/131072.
  function automatic integer expected_sine(input integer peak, input real turns);
    real ideal;
    begin
      ideal = peak * $sin(2.0 * 3.14159265358979323846 * turns) *
              (131071.0 / 131072.0);
      expected_sine = integer'($floor(ideal + 0.5));
    end
  endfunction

  // The golden helper rounds to nearest; the engine floors after its
  // single peak multiply, so exact-value checks carry a small tolerance
  // exactly like the pre-existing consume_frame() comparisons.
  function automatic bit near(input integer got, input integer want,
                              input integer tol);
    near = (got >= want - tol) && (got <= want + tol);
  endfunction

  integer event_ch0;
  integer event_ch1;
  integer noise_sample;
  integer noise_min;
  integer noise_max;
  integer sample_a;
  bit packet_last_phase;

  initial begin : watchdog
    #5_000_000;
    $fatal(1, "ADC simulator test timed out");
  end

  initial begin
    repeat (5) @(posedge clock);
    resetn = 1'b1;

    read_reg(12'h000, value);
    assert (value == 32'h5349_4d31) else $fatal(1, "bad simulator identifier");
    read_reg(12'h004, value);
    assert (value == 32'h0001_0003) else $fatal(1, "bad simulator version");

    // --- Cardinal sine values, banking, framing, backpressure. ----------
    // CH0 is a 1000-count sine; phase advances by 90 degrees per frame.
    write_reg(12'h00c, FRAME_RATE);
    write_reg(12'h014, 32'h0000_0001);
    write_reg(12'h018, 32'h1234_5678);
    write_reg(12'h040, 32'd1000);
    write_reg(12'h080, 32'h4000_0000);
    write_reg(12'h008, 32'h0000_0003);
    write_reg(12'h01c, 32'h0000_0001);

    axis_ready = 1'b0;
    wait (axis_valid);
    held_data = axis_data;
    repeat (6) begin
      @(posedge clock);
      assert (axis_valid && axis_data == held_data)
        else $fatal(1, "simulator output changed under backpressure");
    end
    consume_frame(0, 0, 1'b0);
    consume_frame(999, 0, 1'b1);
    consume_frame(0, 0, 1'b0);
    consume_frame(-1000, 0, 1'b1);

    read_reg(12'h030, value);
    assert (value == 32'h1234_5678) else $fatal(1, "active generation mismatch");
    assert (source_select && frame_rate_valid && frame_rate == FRAME_RATE)
      else $fatal(1, "active simulator status mismatch");
    assert (frame_count >= 4) else $fatal(1, "frame counter did not advance");
    assert (saturation_count == 0) else $fatal(1, "unexpected saturation");
    read_reg(12'h03c, value);
    assert (value == 0) else $fatal(1, "nominal pacing must not miss samples");

    // --- Arbitrary-angle fidelity through the real datapath. ------------
    // 30 degrees at a 1e6-count peak: the HLS golden bench pins the exact
    // arithmetic; this spot check proves the VHDL passes phase/peak
    // through unmangled (the legacy 8-bit table would land ~24 counts
    // off at this angle for this peak; tolerance here is +/-8).
    stop_and_apply_idle;
    write_reg(12'h040, 32'd1000000);
    write_reg(12'h060, 32'h1555_5555);
    write_reg(12'h080, 32'h0000_0000);
    write_reg(12'h008, 32'h0000_0003);
    axis_ready = 1'b0;
    write_reg(12'h01c, 32'h0000_0001);
    consume_frame(expected_sine(1000000, 1.0 / 12.0), 8, 1'b0);

    // --- DC offset: exact pass-through when the sine path is silent. ----
    stop_and_apply_idle;
    write_reg(12'h040, 32'd0);
    write_reg(12'h060, 32'h0000_0000);
    write_reg(12'h08c, 32'd12345);
    write_reg(12'h008, 32'h0000_0003);
    axis_ready = 1'b0;
    write_reg(12'h01c, 32'h0000_0001);
    consume_frame(12345, 0, 1'b0);
    read_reg(12'h0b0, value);
    assert (value == 32'd12345) else $fatal(1, "active DC readback mismatch");

    // --- Noise: alive, bounded, and changing frame to frame. ------------
    stop_and_apply_idle;
    write_reg(12'h08c, 32'd0);
    write_reg(12'h0d0, 32'd100000);
    write_reg(12'h008, 32'h0000_0003);
    axis_ready = 1'b0;
    write_reg(12'h01c, 32'h0000_0001);
    noise_min = 32'h7fffffff;
    noise_max = -32'h7fffffff;
    packet_last_phase = 1'b0;
    repeat (8) begin
      consume_frame_ch0(noise_sample, packet_last_phase);
      packet_last_phase = ~packet_last_phase;
      assert (noise_sample >= -100000 && noise_sample <= 100000)
        else $fatal(1, "noise sample %0d exceeds the configured level", noise_sample);
      if (noise_sample < noise_min) noise_min = noise_sample;
      if (noise_sample > noise_max) noise_max = noise_sample;
    end
    assert (noise_max > noise_min)
      else $fatal(1, "noise did not fluctuate across frames");
    read_reg(12'h100, value);
    assert (value == 32'd100000) else $fatal(1, "active noise readback mismatch");

    // --- Preserve-phase APPLY: waveform and packet framing continue. ----
    // 45 degrees per frame; after two frames the accumulator sits at 90
    // degrees and the packet index at 0 of the next 2-frame packet.
    stop_and_apply_idle;
    write_reg(12'h0d0, 32'd0);
    write_reg(12'h040, 32'd1000);
    write_reg(12'h080, 32'h2000_0000);
    write_reg(12'h008, 32'h0000_0003);
    axis_ready = 1'b0;
    write_reg(12'h01c, 32'h0000_0001);
    consume_frame(0, 0, 1'b0);
    consume_frame(expected_sine(1000, 0.125), 1, 1'b1);
    // Double the amplitude with CONTROL.preserve set: the very next frame
    // must continue at 90 degrees with the new peak, and TLAST cadence
    // must not restart.
    write_reg(12'h040, 32'd2000);
    write_reg(12'h008, 32'h0000_0007);
    write_reg(12'h01c, 32'h0000_0001);
    consume_frame(1999, 0, 1'b0);
    consume_frame(expected_sine(2000, 0.375), 1, 1'b1);

    // A plain APPLY (preserve clear) restarts phase and packet framing.
    write_reg(12'h008, 32'h0000_0003);
    write_reg(12'h01c, 32'h0000_0001);
    consume_frame(0, 0, 1'b0);
    consume_frame(expected_sine(2000, 0.125), 1, 1'b1);

    // --- Harmonic slot: shadow/APPLY banking and the sample changes. -----
    // Exact harmonic arithmetic is pinned by the HLS golden bench; this
    // check proves the VHDL banks the slot words and packs them through.
    stop_and_apply_idle;
    write_reg(12'h040, 32'd1000);
    write_reg(12'h080, 32'h4000_0000);
    // Slot 0: 2nd harmonic on CH0 at 50% of the fundamental, +90 degrees.
    write_reg(12'h200, 32'h8000_0102);
    write_reg(12'h204, 32'h4000_0000);
    read_reg(12'h220, value);
    assert (value == 0) else $fatal(1, "harmonic slot active before APPLY");
    write_reg(12'h008, 32'h0000_0003);
    axis_ready = 1'b0;
    write_reg(12'h01c, 32'h0000_0001);
    // Frame 0: fundamental sin(0) = 0, harmonic 0.5 * 1000 * sin(90 deg).
    consume_frame(expected_sine(500, 0.25), 2, 1'b0);
    read_reg(12'h220, value);
    assert (value == 32'h8000_0102)
      else $fatal(1, "active harmonic word0 readback mismatch");
    read_reg(12'h224, value);
    assert (value == 32'h4000_0000)
      else $fatal(1, "active harmonic word1 readback mismatch");
    // Silence the slot again for the scenarios that follow.
    write_reg(12'h200, 32'd0);
    write_reg(12'h204, 32'd0);

    // --- Missed-sample accounting under deliberate overrun. -------------
    // 5000 frame/s ticks every 2 clocks; a frame needs far longer, so the
    // scheduler must count misses rather than slide the timebase.
    stop_and_apply_idle;
    write_reg(12'h00c, 32'd5000);
    write_reg(12'h008, 32'h0000_0003);
    axis_ready = 1'b1;
    write_reg(12'h01c, 32'h0000_0001);
    repeat (400) @(posedge clock);
    read_reg(12'h03c, value);
    assert (value != 0) else $fatal(1, "overrun did not update missed-sample counter");
    read_reg(12'h020, value);
    assert (value[4]) else $fatal(1, "missed-sample status bit not set");

    // --- Saturation counting and COUNTER_CLEAR strobes. -----------------
    stop_and_apply_idle;
    write_reg(12'h00c, FRAME_RATE);
    write_reg(12'h040, 32'h0100_0000);
    write_reg(12'h060, 32'h4000_0000);
    write_reg(12'h080, 32'h0000_0000);
    write_reg(12'h008, 32'h0000_0003);
    axis_ready = 1'b0;
    write_reg(12'h01c, 32'h0000_0001);
    consume_frame(8388607, 0, 1'b0);
    assert (saturation_count != 0) else $fatal(1, "saturation was not counted");
    read_reg(12'h020, value);
    assert (value[3]) else $fatal(1, "saturation status bit not set");

    stop_and_apply_idle;
    write_reg(12'h0ac, 32'h0000_0007);
    read_reg(12'h038, value);
    assert (value == 0) else $fatal(1, "saturation counter did not clear");
    read_reg(12'h03c, value);
    assert (value == 0) else $fatal(1, "missed-sample counter did not clear");
    read_reg(12'h034, value);
    assert (value == 0) else $fatal(1, "frame counter did not clear");
    read_reg(12'h020, value);
    assert (!value[3] && !value[4])
      else $fatal(1, "sticky status bits survived the counter clear");

    // --- Event sequencer (M12). -----------------------------------------
    // Geometry: a 90-degree-per-frame phase step puts a half-cycle
    // boundary (the accumulator MSB flipping) after every second frame,
    // and a 45-degree channel offset keeps every sample off a zero
    // crossing so an amplitude change is unambiguous.
    //
    // Arming happens while generation is STOPPED -- no frames, so no
    // boundaries, so the armed state is guaranteed to survive to the
    // start -- and the start is a preserve-phase APPLY, which is exactly
    // the case the sequencer must not have cancelled.
    stop_and_apply_idle;
    write_reg(12'h014, 32'h0000_0003);   // CH0 and CH1 enabled
    write_reg(12'h040, 32'd1000);        // CH0 peak
    write_reg(12'h044, 32'd1000);        // CH1 peak
    write_reg(12'h060, 32'h2000_0000);   // CH0 +45 degrees
    write_reg(12'h064, 32'h2000_0000);   // CH1 +45 degrees
    write_reg(12'h080, 32'h4000_0000);   // 90 degrees per frame
    write_reg(12'h008, 32'h0000_0007);   // source + enable + preserve
    // Event: half amplitude on CH0 only, two half cycles, no repeat.
    write_reg(12'h300, 32'h0000_0001);   // channel mask CH0
    write_reg(12'h304, 32'h0000_8000);   // 0.5 in Q16
    write_reg(12'h308, 32'h0000_0002);   // duration 2 half cycles
    read_reg(12'h31c, value);
    assert (value == 32'h0001_0000)
      else $fatal(1, "event scale must stay unity before the trigger");
    read_reg(12'h310, value);
    assert (value == 32'h0000_0000) else $fatal(1, "event active before arming");
    write_reg(12'h30c, 32'h0000_0001);   // ARM
    read_reg(12'h310, value);
    assert (value[0] && !value[1])
      else $fatal(1, "arming must leave the sequencer armed, not running");
    read_reg(12'h318, value);
    assert (value == 32'h0000_0001) else $fatal(1, "active event control mismatch");
    read_reg(12'h31c, value);
    assert (value == 32'h0000_8000) else $fatal(1, "active event scale mismatch");

    axis_ready = 1'b0;
    write_reg(12'h01c, 32'h0000_0001);   // preserve-phase APPLY starts it
    // Frames 0/1 precede the first boundary: full amplitude on both lanes.
    consume_frame_pair(event_ch0, event_ch1, 1'b0);
    assert (near(event_ch0, expected_sine(1000, 0.125), 2) && event_ch1 == event_ch0)
      else $fatal(1, "pre-event frame 0 mismatch: %0d / %0d", event_ch0, event_ch1);
    consume_frame_pair(event_ch0, event_ch1, 1'b1);
    assert (near(event_ch0, expected_sine(1000, 0.375), 2))
      else $fatal(1, "pre-event frame 1 mismatch: %0d", event_ch0);
    // The boundary after frame 1 starts the burst: CH0 halves, CH1 --
    // outside the event mask -- does not move.
    consume_frame_pair(event_ch0, event_ch1, 1'b0);
    assert (near(event_ch0, expected_sine(500, 0.625), 2))
      else $fatal(1, "sag frame 2 mismatch: %0d", event_ch0);
    assert (near(event_ch1, expected_sine(1000, 0.625), 2))
      else $fatal(1, "CH1 is off the event mask and must not dip: %0d", event_ch1);
    read_reg(12'h310, value);
    assert (value[1] && !value[0])
      else $fatal(1, "sequencer must report running during the burst");
    consume_frame_pair(event_ch0, event_ch1, 1'b1);
    assert (near(event_ch0, expected_sine(500, 0.875), 2))
      else $fatal(1, "sag frame 3 mismatch: %0d", event_ch0);
    // Second programmed half cycle.
    consume_frame_pair(event_ch0, event_ch1, 1'b0);
    assert (near(event_ch0, expected_sine(500, 0.125), 2))
      else $fatal(1, "sag frame 4 mismatch: %0d", event_ch0);
    consume_frame_pair(event_ch0, event_ch1, 1'b1);
    assert (near(event_ch0, expected_sine(500, 0.375), 2))
      else $fatal(1, "sag frame 5 mismatch: %0d", event_ch0);
    // The boundary after frame 5 ends it: full amplitude returns and the
    // completed-burst counter advances exactly once.
    consume_frame_pair(event_ch0, event_ch1, 1'b0);
    assert (near(event_ch0, expected_sine(1000, 0.625), 2))
      else $fatal(1, "post-event frame 6 mismatch: %0d", event_ch0);
    read_reg(12'h310, value);
    assert (value[2:0] == 3'b000 && value[31:16] == 16'd1)
      else $fatal(1, "one completed burst expected, status %08x", value);

    // --- Repeat: the burst comes back on its programmed period. ---------
    // Duration 2 half cycles, period 4 half cycles -- two half cycles on,
    // two off. Arming again while stopped keeps the geometry exact.
    stop_and_apply_idle;
    write_reg(12'h008, 32'h0000_0007);
    write_reg(12'h300, 32'h0000_0101);   // CH0 mask + repeat
    write_reg(12'h308, 32'h0004_0002);   // period 4, duration 2
    write_reg(12'h30c, 32'h0000_0005);   // ARM + clear the burst counter
    axis_ready = 1'b0;
    write_reg(12'h01c, 32'h0000_0001);
    consume_frame_pair(event_ch0, event_ch1, 1'b0);  // frame 0, full
    consume_frame_pair(event_ch0, event_ch1, 1'b1);  // frame 1, full
    consume_frame_pair(event_ch0, event_ch1, 1'b0);  // frames 2..5 sag
    assert (near(event_ch0, expected_sine(500, 0.625), 2))
      else $fatal(1, "repeat burst 1 did not start: %0d", event_ch0);
    consume_frame_pair(event_ch0, event_ch1, 1'b1);
    consume_frame_pair(event_ch0, event_ch1, 1'b0);
    consume_frame_pair(event_ch0, event_ch1, 1'b1);
    consume_frame_pair(event_ch0, event_ch1, 1'b0);  // frames 6..9 clear
    assert (near(event_ch0, expected_sine(1000, 0.625), 2))
      else $fatal(1, "repeat gap did not restore amplitude: %0d", event_ch0);
    consume_frame_pair(event_ch0, event_ch1, 1'b1);
    consume_frame_pair(event_ch0, event_ch1, 1'b0);
    consume_frame_pair(event_ch0, event_ch1, 1'b1);
    consume_frame_pair(event_ch0, event_ch1, 1'b0);  // frames 10.. sag again
    assert (near(event_ch0, expected_sine(500, 0.625), 2))
      else $fatal(1, "repeat burst 2 did not fire: %0d", event_ch0);
    read_reg(12'h310, value);
    assert (value[31:16] == 16'd1)
      else $fatal(1, "exactly one burst should have completed, status %08x", value);

    // --- CANCEL drops the envelope and does not count a burst. ----------
    write_reg(12'h30c, 32'h0000_0002);
    consume_frame_pair(event_ch0, event_ch1, 1'b1);
    assert (near(event_ch0, expected_sine(1000, 0.875), 2))
      else $fatal(1, "cancel did not restore amplitude: %0d", event_ch0);
    read_reg(12'h310, value);
    assert (value[2:0] == 3'b000 && value[31:16] == 16'd1)
      else $fatal(1, "cancel must not complete a burst, status %08x", value);

    // --- Scale clamp and the zero-duration guard. -----------------------
    stop_and_apply_idle;
    write_reg(12'h304, 32'h0010_0000);   // 16.0, past the 4.0 cap
    write_reg(12'h308, 32'h0000_0002);
    write_reg(12'h30c, 32'h0000_0001);
    read_reg(12'h31c, value);
    assert (value == 32'h0004_0000)
      else $fatal(1, "event scale must clamp at 4.0, got %08x", value);
    write_reg(12'h30c, 32'h0000_0002);   // cancel before the guard check
    write_reg(12'h308, 32'h0000_0000);   // zero duration
    write_reg(12'h30c, 32'h0000_0001);
    read_reg(12'h310, value);
    assert (value[2:0] == 3'b000)
      else $fatal(1, "a zero-duration arm must be ignored, status %08x", value);

    $display("PASS: adc_simulator_tb");
    $finish;
  end
endmodule
