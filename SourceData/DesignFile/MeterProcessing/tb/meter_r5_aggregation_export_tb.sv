`timescale 1ns/1ps

module meter_r5_aggregation_export_tb;
  localparam int RESULT_WORDS = 221;
  localparam int CONTEXT_WORDS = 13;
  localparam int PAYLOAD_WORDS = RESULT_WORDS + CONTEXT_WORDS;
  localparam int FRAME_WORDS = 4 + PAYLOAD_WORDS + 1;
  localparam logic [31:0] MAGIC = 32'h3147_4741;
  localparam logic [31:0] CONTRACT = 32'h0000_0001;

  logic clock = 1'b0;
  logic resetn = 1'b0;
  logic result_word_valid = 1'b0;
  wire result_word_ready;
  logic [31:0] result_word = '0;

  logic cycle_locked = 1'b1;
  logic cycle_fallback = 1'b0;
  logic [31:0] generation = 32'h1111_0001;
  logic [31:0] sample_rate = 32'd32000;
  logic [7:0] valid_mask = 8'h7f;
  logic enable = 1'b1;
  logic dc_remove = 1'b1;
  logic apply_toggle = 1'b0;
  logic [31:0] frequency_status = 32'h0000_0001;
  logic [31:0] frequency_period = 32'h0222_0000;
  logic [31:0] frequency_sequence = 32'h0000_0042;
  logic [31:0] frame_count = 32'h1000_0001;
  logic [31:0] header_errors = 32'h0000_0002;
  logic [31:0] overflows = 32'h0000_0003;
  logic [31:0] alerts = 32'h0000_0004;
  logic [63:0] target_sample = 64'h0123_4567_89ab_cdef;
  logic target_valid = 1'b1;
  logic target_update = 1'b0;

  wire [31:0] axis_data;
  wire [3:0] axis_keep;
  wire axis_valid;
  logic axis_ready = 1'b0;
  wire axis_last;

  wire [31:0] accepted_packets;
  wire [31:0] dropped_packets;
  wire [31:0] transmitted_packets;
  wire [31:0] framing_errors;
  wire [31:0] last_sequence;
  wire [7:0] queue_level;
  wire [31:0] status;

  logic [31:0] observed [0:(2 * FRAME_WORDS) - 1];
  logic observed_last [0:(2 * FRAME_WORDS) - 1];
  int observed_count = 0;
  int ready_counter = 0;

  always #5 clock = ~clock;

  meter_r5_aggregation_export #(
    // Exercise the cutover behavior: the exporter owns READY and reserves a
    // complete R5 input packet before accepting SingleCycle word zero.
    .G_AUTHORITATIVE_INPUT(1'b1)
  ) dut (
    .aclk(clock),
    .aresetn(resetn),
    .result_word_valid_i(result_word_valid),
    .result_word_ready_o(result_word_ready),
    .result_word_i(result_word),
    .cycle_locked_i(cycle_locked),
    .cycle_fallback_i(cycle_fallback),
    .shadow_generation_i(generation),
    .shadow_sample_rate_i(sample_rate),
    .shadow_valid_mask_i(valid_mask),
    .shadow_enable_i(enable),
    .shadow_dc_remove_i(dc_remove),
    .config_apply_toggle_i(apply_toggle),
    .frequency_status_i(frequency_status),
    .frequency_period_i(frequency_period),
    .frequency_sequence_i(frequency_sequence),
    .capture_frame_count_i(frame_count),
    .capture_header_errors_i(header_errors),
    .capture_overflows_i(overflows),
    .capture_alerts_i(alerts),
    .ten_minute_target_sample_i(target_sample),
    .ten_minute_target_valid_i(target_valid),
    .ten_minute_target_update_i(target_update),
    .m_axis_tdata(axis_data),
    .m_axis_tkeep(axis_keep),
    .m_axis_tvalid(axis_valid),
    .m_axis_tready(axis_ready),
    .m_axis_tlast(axis_last),
    .accepted_packet_count_o(accepted_packets),
    .dropped_packet_count_o(dropped_packets),
    .transmitted_packet_count_o(transmitted_packets),
    .framing_error_count_o(framing_errors),
    .last_sequence_o(last_sequence),
    .queue_level_o(queue_level),
    .status_o(status)
  );

  // Exercise arbitrary stalls without using random state that would make a
  // failing waveform difficult to reproduce.
  always_ff @(posedge clock) begin
    if (!resetn) begin
      ready_counter <= 0;
      axis_ready <= 1'b0;
    end else begin
      ready_counter <= ready_counter + 1;
      axis_ready <= (ready_counter % 7 != 1) && (ready_counter % 11 != 4);
    end
  end

  always_ff @(posedge clock) begin
    if (resetn && axis_valid && axis_ready) begin
      if (observed_count >= 2 * FRAME_WORDS)
        $fatal(1, "exporter produced extra output words");
      if (axis_keep !== 4'hf)
        $fatal(1, "TKEEP was not 0xf at output word %0d", observed_count);
      observed[observed_count] <= axis_data;
      observed_last[observed_count] <= axis_last;
      observed_count <= observed_count + 1;
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

  function automatic logic [31:0] result_value(
    input logic [31:0] seq,
    input int index);
    if (index == 0)
      return seq;
    return seq ^ (32'h0102_0304 * index);
  endfunction

  function automatic logic [31:0] expected_context(
    input int packet,
    input int index);
    begin
      case (packet)
        0: case (index)
          0: return 32'h1111_0001;
          1: return 32'd32000;
          2: return 32'h0000_0b7f;
          3: return 32'h0000_0001;
          4: return 32'h0222_0000;
          5: return 32'h0000_0042;
          6: return 32'h1000_0001;
          7: return 32'h0000_0002;
          8: return 32'h0000_0003;
          9: return 32'h0000_0004;
          10: return 32'h89ab_cdef;
          11: return 32'h0123_4567;
          12: return 32'h0000_0001;
          default: return 'x;
        endcase
        default: case (index)
          0: return 32'h2222_0002;
          1: return 32'd128000;
          2: return 32'h0000_14a5;
          3: return 32'haaaa_0003;
          4: return 32'hbbbb_0004;
          5: return 32'hcccc_0005;
          6: return 32'hdddd_0006;
          7: return 32'heeee_0007;
          8: return 32'hffff_0008;
          9: return 32'h1111_0009;
          10: return 32'h7654_3210;
          11: return 32'hfedc_ba98;
          12: return 32'h0000_0002;
          default: return 'x;
        endcase
      endcase
    end
  endfunction

  task automatic set_second_context;
    begin
      generation = 32'h2222_0002;
      sample_rate = 32'd128000;
      valid_mask = 8'ha5;
      enable = 1'b0;
      dc_remove = 1'b0;
      apply_toggle = 1'b1;
      cycle_locked = 1'b0;
      cycle_fallback = 1'b1;
      frequency_status = 32'haaaa_0003;
      frequency_period = 32'hbbbb_0004;
      frequency_sequence = 32'hcccc_0005;
      frame_count = 32'hdddd_0006;
      header_errors = 32'heeee_0007;
      overflows = 32'hffff_0008;
      alerts = 32'h1111_0009;
      target_sample = 64'hfedc_ba98_7654_3210;
      target_valid = 1'b0;
      target_update = 1'b1;
    end
  endtask

  task automatic send_packet(
    input logic [31:0] seq,
    input bit alter_context_after_word_zero);
    begin
      for (int index = 0; index < RESULT_WORDS; index++) begin
        @(negedge clock);
        result_word = result_value(seq, index);
        result_word_valid = 1'b1;
        // VALID remains asserted and the word remains stable until the
        // exporter accepts it.  Word zero may wait while a whole-packet
        // reservation is unavailable; later words must proceed from that
        // reservation without creating a partial packet.
        do @(posedge clock); while (!result_word_ready);
        // Move the live context after the accepting edge, outside the DUT's
        // sampling region, so the test has no mixed-language scheduling race.
        if (index == 0 && alter_context_after_word_zero)
          #1 set_second_context();
      end
      @(negedge clock);
      result_word_valid = 1'b0;
      result_word = '0;
    end
  endtask

  task automatic verify_packet(
    input int packet,
    input logic [31:0] seq);
    logic [31:0] expected;
    logic [31:0] crc;
    int base;
    begin
      base = packet * FRAME_WORDS;
      crc = 32'hffff_ffff;
      for (int index = 0; index < FRAME_WORDS; index++) begin
        case (index)
          0: expected = MAGIC;
          1: expected = CONTRACT;
          2: expected = PAYLOAD_WORDS;
          3: expected = seq;
          default: begin
            if (index < 4 + RESULT_WORDS)
              expected = result_value(seq, index - 4);
            else if (index < FRAME_WORDS - 1)
              expected = expected_context(packet, index - 4 - RESULT_WORDS);
            else
              expected = ~crc;
          end
        endcase
        if (observed[base + index] !== expected)
          $fatal(1,
            "packet %0d word %0d mismatch: got %08x expected %08x",
            packet, index, observed[base + index], expected);
        if (observed_last[base + index] !== (index == FRAME_WORDS - 1))
          $fatal(1, "packet %0d word %0d TLAST mismatch", packet, index);
        if (index != FRAME_WORDS - 1)
          crc = crc32c_word(crc, expected);
      end
    end
  endtask

  initial begin
    repeat (8) @(posedge clock);
    resetn = 1'b1;
    // XPM reset-busy signals may remain asserted for several common clocks.
    repeat (12) @(posedge clock);

    // The first context is captured with result word zero. Change every live
    // input immediately afterward and prove that the queued packet retains
    // the original coherent snapshot.
    send_packet(32'h0000_0101, 1'b1);
    send_packet(32'h0000_0202, 1'b0);

    fork
      begin
        wait (observed_count == 2 * FRAME_WORDS);
      end
      begin
        repeat (10000) @(posedge clock);
        $fatal(1, "timed out waiting for exported packets");
      end
    join_any
    disable fork;
    repeat (4) @(posedge clock);

    verify_packet(0, 32'h0000_0101);
    verify_packet(1, 32'h0000_0202);
    if (accepted_packets !== 32'd2 || dropped_packets !== 32'd0 ||
        transmitted_packets !== 32'd2 || framing_errors !== 32'd0)
      $fatal(1,
        "counter mismatch accepted=%0d dropped=%0d transmitted=%0d errors=%0d",
        accepted_packets, dropped_packets, transmitted_packets, framing_errors);
    if (last_sequence !== 32'h0000_0202 || queue_level !== 0)
      $fatal(1, "last sequence or queue level mismatch");
    if (!status[0] || status[1] || status[2])
      $fatal(1, "unexpected exporter status %08x", status);

    $display("PASS: meter_r5_aggregation_export_tb");
    $finish;
  end
endmodule
