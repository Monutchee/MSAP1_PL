`timescale 1ns/1ps

// Phase-sweep exhaustion of the record transport: hub + aggregate producer
// -> arbiter -> packetizer, wired exactly as meter_core.vhd.
//
// Purpose (2026-08-15 field incident): during fault episodes the APU
// receives one duplicated MTR2 aggregate and loses one MTR1 basic record
// per aggregate window, with every drop counter reading zero. This bench
// answers ONE question: can the RTL produce a duplicate or a loss
// FUNCTIONALLY, at any relative alignment of the two producers' emissions
// and any AXIS backpressure pattern? A pass here means the fault cannot be
// a functional handshake bug and must be physical (timing) — the
// elimination the investigation needs.
//
// Method: emit a basic/aggregate pair at every relative offset from -3 to
// +67 cycles (covering aggregate-first, same-cycle, every alignment across
// the packetizer's 64-beat drain, and past it), under three AXIS ready
// regimes (always ready, 50% duty, LFSR-random). A scoreboard demands every
// emitted record is delivered EXACTLY once, every packet is exactly 64
// beats, and no drop counter moves (pacing keeps both records inside the
// packetizer's active+pending capacity, so any counted drop is a bug too).
module record_transport_phase_tb;
  logic clock = 1'b0;
  logic resetn = 1'b0;

  // --- hub (MTR1 producer) inputs -----------------------------------------
  logic voltage_valid = 1'b0;
  logic [31:0] result_sequence = 32'd0;
  logic [511:0] voltage_mean = '0;
  logic [511:0] voltage_rms = '0;
  logic [255:0] voltage_rms_count = '0;
  wire [2047:0] basic_record;
  wire basic_valid;
  wire basic_ready;
  wire [31:0] hub_drop_count;

  // --- aggregate (MTR2) producer inputs ------------------------------------
  logic aggregate_valid_in = 1'b0;
  logic [31:0] aggregate_sequence_in = 32'd0;
  wire [2047:0] aggregate_record;
  wire aggregate_valid;
  wire aggregate_ready;
  wire [31:0] aggregate_drop_count;

  // --- arbiter -> packetizer -> AXIS ---------------------------------------
  wire [2047:0] bus_record;
  wire bus_valid;
  wire bus_ready;
  wire [31:0] axis_data;
  wire [3:0] axis_keep;
  wire axis_valid;
  logic axis_ready = 1'b1;
  wire axis_last;
  wire [31:0] packet_drop_count;

  always #5 clock = ~clock;

  MeterResultHub_Wrapper hub (
    .aclk(clock), .aresetn(resetn),
    .voltage_result_valid_i(voltage_valid),
    .result_sequence_i(result_sequence), .config_generation_i(32'd17),
    .sample_rate_i(32'd32000), .window_samples_i(32'd6400),
    .voltage_valid_mask_i(8'h70), .result_status_i(32'd0),
    .voltage_mean_q16_i(voltage_mean), .voltage_rms_q16_i(voltage_rms),
    .voltage_rms_count_i(voltage_rms_count),
    .current_valid_mask_i(8'h00), .current_mean_q16_i(512'd0),
    .current_rms_q16_i(512'd0),
    .current_rms_count_i(256'd0),
    .capture_frame_count_i(32'd12345),
    .capture_header_errors_i(32'd0), .capture_overflows_i(32'd0),
    .capture_alerts_i(32'd0),
    .frequency_millihz_i(32'd60002),
    .frequency_status_i(32'd7),
    .frequency_period_q16_i(32'd0),
    .frequency_sequence_i(32'd0),
    .packetizer_drop_count_i(packet_drop_count),
    .block_first_sample_i(64'h0000_0001_8000_0021),
    .block_cycle_count_i(8'd12), .block_nominal_hz_i(8'd60),
    .block_flags_i(3'b001),
    .record_data_o(basic_record), .record_valid_o(basic_valid),
    .record_ready_i(basic_ready), .hub_drop_count_o(hub_drop_count)
  );

  aggregate_record_producer aggregate_producer (
    .aclk(clock), .aresetn(resetn),
    .aggregate_valid_i(aggregate_valid_in),
    .aggregate_sequence_i(aggregate_sequence_in),
    .aggregate_generation_i(32'd17),
    .aggregate_sample_rate_i(32'd32000),
    .aggregate_samples_i(32'd96000),
    .aggregate_valid_mask_i(8'h7f),
    .aggregate_arithmetic_i(1'b0),
    .aggregate_freq_valid_i(1'b1),
    .aggregate_first_seq_i(32'd1),
    .aggregate_last_seq_i(32'd15),
    .aggregate_nominal_i(8'd60),
    .aggregate_cycles_i(16'd180),
    .aggregate_first_sample_i(64'h0000_0001_8000_0021),
    .aggregate_rms_q16_i(512'd0),
    .aggregate_freq_millihz_i(32'd60000),
    .record_data_o(aggregate_record), .record_valid_o(aggregate_valid),
    .record_ready_i(aggregate_ready), .drop_count_o(aggregate_drop_count)
  );

  measurement_record_arbiter arbiter (
    .basic_record_i(basic_record),
    .basic_valid_i(basic_valid),
    .basic_ready_o(basic_ready),
    .aggregate_record_i(aggregate_record),
    .aggregate_valid_i(aggregate_valid),
    .aggregate_ready_o(aggregate_ready),
    .m_record_o(bus_record),
    .m_valid_o(bus_valid),
    .m_ready_i(bus_ready)
  );

  MeterPacketizer_Wrapper packetizer (
    .aclk(clock), .aresetn(resetn), .record_data_i(bus_record),
    .record_valid_i(bus_valid), .record_ready_o(bus_ready),
    .m_axis_meter_tdata(axis_data), .m_axis_meter_tkeep(axis_keep),
    .m_axis_meter_tvalid(axis_valid), .m_axis_meter_tready(axis_ready),
    .m_axis_meter_tlast(axis_last), .drop_count_o(packet_drop_count)
  );

  // --- scoreboard -----------------------------------------------------------
  logic [31:0] packet_words [0:63];
  int beat_in_packet = 0;
  int rx_basic [$];
  int rx_aggregate [$];
  int tx_basic [$];
  int tx_aggregate [$];

  always @(posedge clock) begin
    if (axis_valid && axis_ready) begin
      packet_words[beat_in_packet] = axis_data;
      assert (axis_keep == 4'hf) else $fatal(1, "bad TKEEP");
      assert (axis_last == (beat_in_packet == 63))
        else $fatal(1, "TLAST at beat %0d of a packet", beat_in_packet);
      if (axis_last) begin
        assert (packet_words[0] == 32'h3152_544d)
          else $fatal(1, "bad magic 0x%08h", packet_words[0]);
        assert (packet_words[2] == 32'd256)
          else $fatal(1, "bad size word %0d", packet_words[2]);
        case (packet_words[1])
          32'h0001_0002: rx_basic.push_back(int'(packet_words[3]));
          32'h0002_0001: rx_aggregate.push_back(int'(packet_words[3]));
          default: $fatal(1, "unknown format 0x%08h", packet_words[1]);
        endcase
        beat_in_packet = 0;
      end else begin
        beat_in_packet = beat_in_packet + 1;
      end
    end
  end

  // --- stimulus -------------------------------------------------------------
  int basic_seq_next = 100;
  int aggregate_seq_next = 9000;

  // Emit one basic pulse at cycle 0 and one aggregate pulse at cycle
  // `aggregate_offset` (may be negative: aggregate first), then drain.
  task automatic emit_pair(input int aggregate_offset, input int drain_cycles);
    int first_cycle;
    int last_cycle;
    first_cycle = (aggregate_offset < 0) ? aggregate_offset : 0;
    last_cycle = ((aggregate_offset > 0) ? aggregate_offset : 0) + 1;
    @(negedge clock);
    for (int c = first_cycle; c <= last_cycle; c++) begin
      if (c == 0) begin
        result_sequence = basic_seq_next;
        voltage_valid = 1'b1;
        tx_basic.push_back(basic_seq_next);
        basic_seq_next++;
      end else if (c == 1) begin
        voltage_valid = 1'b0;
      end
      if (c == aggregate_offset) begin
        aggregate_sequence_in = aggregate_seq_next;
        aggregate_valid_in = 1'b1;
        tx_aggregate.push_back(aggregate_seq_next);
        aggregate_seq_next++;
      end else if (c == aggregate_offset + 1) begin
        aggregate_valid_in = 1'b0;
      end
      @(negedge clock);
    end
    voltage_valid = 1'b0;
    aggregate_valid_in = 1'b0;
    repeat (drain_cycles) @(negedge clock);
  endtask

  function automatic int count_occurrences(ref int received [$],
                                           input int wanted);
    int total = 0;
    foreach (received[i])
      if (received[i] == wanted) total++;
    return total;
  endfunction

  task automatic check_exactly_once;
    assert (rx_basic.size() == tx_basic.size())
      else $fatal(1, "basic count: sent %0d received %0d",
                  tx_basic.size(), rx_basic.size());
    assert (rx_aggregate.size() == tx_aggregate.size())
      else $fatal(1, "aggregate count: sent %0d received %0d",
                  tx_aggregate.size(), rx_aggregate.size());
    foreach (tx_basic[i]) begin
      automatic int n = count_occurrences(rx_basic, tx_basic[i]);
      assert (n == 1)
        else $fatal(1, "basic seq %0d delivered %0d times", tx_basic[i], n);
    end
    foreach (tx_aggregate[i]) begin
      automatic int n = count_occurrences(rx_aggregate, tx_aggregate[i]);
      assert (n == 1)
        else $fatal(1, "aggregate seq %0d delivered %0d times",
                    tx_aggregate[i], n);
    end
    assert (hub_drop_count == 0 && aggregate_drop_count == 0 &&
            packet_drop_count == 0)
      else $fatal(1, "unexpected drops: hub %0d aggregate %0d packetizer %0d",
                  hub_drop_count, aggregate_drop_count, packet_drop_count);
  endtask

  // AXIS ready regimes.
  logic [15:0] lfsr = 16'hACE1;
  int ready_mode = 0;  // 0: always, 1: 50% duty, 2: LFSR
  always @(negedge clock) begin
    case (ready_mode)
      0: axis_ready <= 1'b1;
      1: axis_ready <= ~axis_ready;
      2: begin
        lfsr <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
        axis_ready <= lfsr[0];
      end
    endcase
  end

  initial begin
    repeat (5) @(posedge clock);
    resetn = 1'b1;
    voltage_mean[4*64 +: 64] = 64'sd100 <<< 16;
    voltage_rms[4*64 +: 64] = 64'sd230000000 <<< 16;
    voltage_rms_count[4*32 +: 32] = 32'd596820;

    // Sweep 1: DMA always ready (the product's normal condition).
    ready_mode = 0;
    for (int offset = -3; offset <= 67; offset++)
      emit_pair(offset, 200);

    // Sweep 2: 50% duty backpressure (drain boundary lands differently
    // against every offset).
    ready_mode = 1;
    for (int offset = -3; offset <= 67; offset++)
      emit_pair(offset, 360);

    // Sweep 3: pseudo-random backpressure.
    ready_mode = 2;
    for (int offset = -3; offset <= 67; offset++)
      emit_pair(offset, 500);

    ready_mode = 0;
    repeat (600) @(negedge clock);
    check_exactly_once();
    $display("emitted %0d basic + %0d aggregate records across 213 phase pairs",
             tx_basic.size(), tx_aggregate.size());
    $display("record_transport_phase_tb PASS");
    $finish;
  end

  initial begin
    #2_000_000;
    $fatal(1, "record_transport_phase_tb timeout");
  end
endmodule
