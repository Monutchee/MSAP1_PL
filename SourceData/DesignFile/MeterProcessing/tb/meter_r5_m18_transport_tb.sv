`timescale 1ns/1ps

module meter_r5_m18_transport_tb;
  localparam int PAYLOAD_WORDS = 4;
  localparam int FRAME_WORDS = 4 + PAYLOAD_WORDS + 1;
  localparam logic [31:0] MAGIC = 32'h3145_5150;

  logic clock = 1'b0;
  logic resetn = 1'b0;
  always #5 clock = ~clock;

  logic [31:0] packet_in_data = '0;
  logic [3:0] packet_in_keep = 4'hf;
  logic packet_in_valid = 1'b0;
  wire packet_in_ready;
  logic packet_in_last = 1'b0;
  wire [31:0] packet_out_data;
  wire [3:0] packet_out_keep;
  wire packet_out_valid;
  logic packet_out_ready = 1'b0;
  wire packet_out_last;
  wire [31:0] packet_accepted;
  wire [31:0] packet_dropped;
  wire [31:0] packet_transmitted;
  wire [31:0] packet_errors;

  logic [31:0] packet_observed [0:(2 * FRAME_WORDS) - 1];
  logic packet_observed_last [0:(2 * FRAME_WORDS) - 1];
  int packet_observed_count = 0;
  int ready_cycle = 0;

  meter_r5_fixed_packet_export #(
    .G_MAGIC(MAGIC),
    .G_PAYLOAD_WORDS(PAYLOAD_WORDS),
    .G_FIFO_DEPTH(16),
    .G_FIFO_COUNT_WIDTH(5),
    .G_PACKET_SLOTS(2)
  ) packetizer (
    .aclk(clock), .aresetn(resetn),
    .s_axis_tdata(packet_in_data), .s_axis_tkeep(packet_in_keep),
    .s_axis_tvalid(packet_in_valid), .s_axis_tready(packet_in_ready),
    .s_axis_tlast(packet_in_last),
    .m_axis_tdata(packet_out_data), .m_axis_tkeep(packet_out_keep),
    .m_axis_tvalid(packet_out_valid), .m_axis_tready(packet_out_ready),
    .m_axis_tlast(packet_out_last),
    .accepted_packet_count_o(packet_accepted),
    .dropped_packet_count_o(packet_dropped),
    .transmitted_packet_count_o(packet_transmitted),
    .framing_error_count_o(packet_errors)
  );

  always_ff @(posedge clock) begin
    if (resetn && packet_in_valid && !packet_in_ready)
      $fatal(1, "fixed packetizer backpressured its producer");
    if (resetn && packet_out_valid && packet_out_ready) begin
      if (packet_observed_count >= 2 * FRAME_WORDS)
        $fatal(1, "fixed packetizer emitted an extra word");
      if (packet_out_keep !== 4'hf)
        $fatal(1, "fixed packetizer emitted partial TKEEP");
      packet_observed[packet_observed_count] <= packet_out_data;
      packet_observed_last[packet_observed_count] <= packet_out_last;
      packet_observed_count <= packet_observed_count + 1;
    end
  end

  function automatic logic [31:0] crc32c_word(
    input logic [31:0] crc_in,
    input logic [31:0] word);
    logic [31:0] crc;
    logic [7:0] data_byte;
    begin
      crc = crc_in;
      for (int byte_index = 0; byte_index < 4; byte_index++) begin
        data_byte = word[(byte_index * 8) +: 8];
        crc ^= data_byte;
        for (int bit_index = 0; bit_index < 8; bit_index++) begin
          if (crc[0])
            crc = (crc >> 1) ^ 32'h82f6_3b78;
          else
            crc >>= 1;
        end
      end
      return crc;
    end
  endfunction

  function automatic logic [31:0] payload_value(input int packet, input int word);
    return 32'h1000_0000 + (packet << 8) + word;
  endfunction

  task automatic send_payload(input int packet, input bit malformed_last);
    begin
      for (int word = 0; word < PAYLOAD_WORDS; word++) begin
        @(negedge clock);
        packet_in_data = payload_value(packet, word);
        packet_in_valid = 1'b1;
        packet_in_last = malformed_last
          ? (word == 1)
          : (word == PAYLOAD_WORDS - 1);
        do @(posedge clock); while (!packet_in_ready);
      end
      @(negedge clock);
      packet_in_valid = 1'b0;
      packet_in_last = 1'b0;
    end
  endtask

  task automatic verify_packet(input int output_packet, input int input_packet);
    logic [31:0] expected;
    logic [31:0] crc;
    int base;
    begin
      base = output_packet * FRAME_WORDS;
      crc = 32'hffff_ffff;
      for (int word = 0; word < FRAME_WORDS; word++) begin
        case (word)
          0: expected = MAGIC;
          1: expected = 32'd1;
          2: expected = PAYLOAD_WORDS;
          3: expected = payload_value(input_packet, 0);
          FRAME_WORDS - 1: expected = ~crc;
          default: expected = payload_value(input_packet, word - 4);
        endcase
        if (packet_observed[base + word] !== expected)
          $fatal(1, "packet %0d word %0d got %08x expected %08x",
                 output_packet, word, packet_observed[base + word], expected);
        if (packet_observed_last[base + word] !== (word == FRAME_WORDS - 1))
          $fatal(1, "packet %0d word %0d TLAST mismatch", output_packet, word);
        if (word != FRAME_WORDS - 1)
          crc = crc32c_word(crc, expected);
      end
    end
  endtask

  logic [31:0] arb_data [0:4];
  logic [3:0] arb_keep [0:4];
  logic arb_valid [0:4];
  wire arb_ready [0:4];
  logic arb_last [0:4];
  wire [31:0] arb_out_data;
  wire [3:0] arb_out_keep;
  wire arb_out_valid;
  logic arb_out_ready = 1'b0;
  wire arb_out_last;
  int arb_word [0:4];
  int arb_packet [0:4];
  int arb_observed = 0;

  meter_axis_packet_arbiter_5to1 arbiter (
    .aclk(clock), .aresetn(resetn),
    .s0_axis_tdata(arb_data[0]), .s0_axis_tkeep(arb_keep[0]),
    .s0_axis_tvalid(arb_valid[0]), .s0_axis_tready(arb_ready[0]),
    .s0_axis_tlast(arb_last[0]),
    .s1_axis_tdata(arb_data[1]), .s1_axis_tkeep(arb_keep[1]),
    .s1_axis_tvalid(arb_valid[1]), .s1_axis_tready(arb_ready[1]),
    .s1_axis_tlast(arb_last[1]),
    .s2_axis_tdata(arb_data[2]), .s2_axis_tkeep(arb_keep[2]),
    .s2_axis_tvalid(arb_valid[2]), .s2_axis_tready(arb_ready[2]),
    .s2_axis_tlast(arb_last[2]),
    .s3_axis_tdata(arb_data[3]), .s3_axis_tkeep(arb_keep[3]),
    .s3_axis_tvalid(arb_valid[3]), .s3_axis_tready(arb_ready[3]),
    .s3_axis_tlast(arb_last[3]),
    .s4_axis_tdata(arb_data[4]), .s4_axis_tkeep(arb_keep[4]),
    .s4_axis_tvalid(arb_valid[4]), .s4_axis_tready(arb_ready[4]),
    .s4_axis_tlast(arb_last[4]),
    .m_axis_tdata(arb_out_data), .m_axis_tkeep(arb_out_keep),
    .m_axis_tvalid(arb_out_valid), .m_axis_tready(arb_out_ready),
    .m_axis_tlast(arb_out_last)
  );

  always_comb begin
    for (int source = 0; source < 5; source++) begin
      arb_valid[source] = arb_packet[source] < 2;
      arb_data[source] = 32'ha000_0000 | (source << 16) |
                         (arb_packet[source] << 8) | arb_word[source];
      arb_keep[source] = 4'hf;
      arb_last[source] = arb_word[source] == 1;
    end
  end

  always_ff @(posedge clock) begin
    if (!resetn) begin
      ready_cycle <= 0;
      for (int source = 0; source < 5; source++) begin
        arb_word[source] <= 0;
        arb_packet[source] <= 0;
      end
      arb_observed <= 0;
    end else begin
      ready_cycle <= ready_cycle + 1;
      for (int source = 0; source < 5; source++) begin
        if (arb_valid[source] && arb_ready[source]) begin
          if (arb_word[source] == 1) begin
            arb_word[source] <= 0;
            arb_packet[source] <= arb_packet[source] + 1;
          end else begin
            arb_word[source] <= arb_word[source] + 1;
          end
        end
      end
      if (arb_out_valid && arb_out_ready) begin
        int expected_source;
        int expected_packet;
        int expected_word;
        expected_source = (arb_observed / 2) % 5;
        expected_packet = arb_observed / 10;
        expected_word = arb_observed % 2;
        if (arb_out_data !== (32'ha000_0000 | (expected_source << 16) |
                              (expected_packet << 8) | expected_word))
          $fatal(1, "arbiter order/interleave mismatch at word %0d", arb_observed);
        if (arb_out_keep !== 4'hf || arb_out_last !== (expected_word == 1))
          $fatal(1, "arbiter sideband mismatch at word %0d", arb_observed);
        arb_observed <= arb_observed + 1;
      end
    end
  end

  initial begin
    repeat (8) @(posedge clock);
    resetn = 1'b1;
    repeat (12) @(posedge clock);

    // Hold the consumer off so only two whole payloads fit. A malformed TLAST
    // is counted but cannot alter the fixed packet boundary; the third payload
    // is consumed and discarded as a whole packet.
    send_payload(0, 1'b0);
    send_payload(1, 1'b1);
    send_payload(2, 1'b0);
    repeat (4) @(posedge clock);
    if (packet_accepted !== 2 || packet_dropped !== 1 || packet_errors !== 2)
      $fatal(1,
             "packetizer counters mismatch accepted=%0d dropped=%0d errors=%0d",
             packet_accepted, packet_dropped, packet_errors);

    packet_out_ready = 1'b1;
    arb_out_ready = 1'b1;
    fork
      begin
        wait (packet_observed_count == 2 * FRAME_WORDS && arb_observed == 20);
      end
      begin
        repeat (2000) @(posedge clock);
        $fatal(1, "timed out waiting for M18 transport outputs");
      end
    join_any
    disable fork;
    repeat (3) @(posedge clock);

    verify_packet(0, 0);
    verify_packet(1, 1);
    if (packet_transmitted !== 2)
      $fatal(1, "packetizer transmitted counter mismatch");
    $display("PASS: meter_r5_m18_transport_tb (CRC/drop/stall/fairness/no-interleave)");
    $finish;
  end
endmodule
