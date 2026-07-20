`timescale 1ns/1ps

module meter_packet_tb;
  logic clock = 1'b0;
  logic resetn = 1'b0;
  logic voltage_valid = 1'b0;
  logic [31:0] result_sequence = 32'd9;
  logic [31:0] generation = 32'd17;
  logic [31:0] sample_rate = 32'd32000;
  logic [31:0] window_samples = 32'd6400;
  logic [7:0] voltage_mask = 8'h70;
  logic [31:0] result_status = '0;
  logic [511:0] voltage_mean = '0;
  logic [511:0] voltage_rms = '0;
  logic [255:0] voltage_rms_count = '0;
  logic [7:0] current_mask = '0;
  logic [511:0] current_mean = '0;
  logic [511:0] current_rms = '0;
  logic [255:0] current_rms_count = '0;
  wire [2047:0] record_data;
  wire record_valid;
  wire record_ready;
  wire [31:0] hub_drop_count;
  wire [31:0] packet_drop_count;
  wire [31:0] axis_data;
  wire [3:0] axis_keep;
  wire axis_valid;
  logic axis_ready = 1'b1;
  wire axis_last;
  int beat_count = 0;
  int record_word;
  int record_index;

  always #5 clock = ~clock;

  MeterResultHub_Wrapper hub (
    .aclk(clock), .aresetn(resetn),
    .voltage_result_valid_i(voltage_valid),
    .result_sequence_i(result_sequence), .config_generation_i(generation),
    .sample_rate_i(sample_rate), .window_samples_i(window_samples),
    .voltage_valid_mask_i(voltage_mask), .result_status_i(result_status),
    .voltage_mean_q16_i(voltage_mean), .voltage_rms_q16_i(voltage_rms),
    .voltage_rms_count_i(voltage_rms_count),
    .current_valid_mask_i(current_mask), .current_mean_q16_i(current_mean),
    .current_rms_q16_i(current_rms),
    .current_rms_count_i(current_rms_count),
    .capture_frame_count_i(32'd12345),
    .capture_header_errors_i(32'd2), .capture_overflows_i(32'd3),
    .capture_alerts_i(32'd4),
    .packetizer_drop_count_i(packet_drop_count),
    .record_data_o(record_data), .record_valid_o(record_valid),
    .record_ready_i(record_ready), .hub_drop_count_o(hub_drop_count)
  );

  MeterPacketizer_Wrapper packetizer (
    .aclk(clock), .aresetn(resetn), .record_data_i(record_data),
    .record_valid_i(record_valid), .record_ready_o(record_ready),
    .m_axis_meter_tdata(axis_data), .m_axis_meter_tkeep(axis_keep),
    .m_axis_meter_tvalid(axis_valid), .m_axis_meter_tready(axis_ready),
    .m_axis_meter_tlast(axis_last), .drop_count_o(packet_drop_count)
  );

  task automatic publish_result(input logic [31:0] sequence_value);
    begin
      @(negedge clock);
      result_sequence = sequence_value;
      voltage_valid = 1'b1;
      @(negedge clock);
      voltage_valid = 1'b0;
      repeat (3) @(posedge clock);
    end
  endtask

  always @(posedge clock) begin
    if (axis_valid && axis_ready) begin
      record_word = beat_count % 64;
      record_index = beat_count / 64;
      case (record_word)
        0: assert (axis_data == 32'h3152_544d) else $fatal(1, "bad magic");
        1: assert (axis_data == 32'h0001_0001) else $fatal(1, "bad format");
        2: assert (axis_data == 32'd256) else $fatal(1, "bad length");
        3: begin
          case (record_index)
            0: assert (axis_data == 32'd9) else $fatal(1, "bad first sequence");
            1: assert (axis_data == 32'd10) else $fatal(1, "bad active sequence");
            2: assert (axis_data == 32'd12) else $fatal(1, "latest pending record not retained");
          endcase
        end
        4: assert (axis_data == 32'd17) else $fatal(1, "bad generation");
        5: assert (axis_data == 32'd32000) else $fatal(1, "bad sample rate");
        6: assert (axis_data == 32'd6400) else $fatal(1, "bad window");
        7: assert (axis_data == 32'h70) else $fatal(1, "bad valid mask");
        9: assert (axis_data == 32'd12345) else $fatal(1, "bad capture frame count");
        10: assert (axis_data == 32'd2) else $fatal(1, "bad header count");
        11: assert (axis_data == 32'd3) else $fatal(1, "bad overflow count");
        14: assert (axis_data == 32'd4) else $fatal(1, "bad alert count");
        38: assert (axis_data == 32'd596820) else $fatal(1, "bad channel RMS count");
      endcase
      assert (axis_keep == 4'hf) else $fatal(1, "bad TKEEP");
      assert (axis_last == (record_word == 63))
        else $fatal(1, "bad TLAST at beat %0d", beat_count);
      beat_count <= beat_count + 1;
    end
  end

  initial begin
    repeat (5) @(posedge clock);
    resetn = 1'b1;
    voltage_mean[4*64 +: 64] = 64'sd100 <<< 16;
    voltage_rms[4*64 +: 64] = 64'sd230000000 <<< 16;
    voltage_rms_count[4*32 +: 32] = 32'd596820;
    publish_result(32'd9);

    wait (beat_count == 8);
    @(negedge clock);
    axis_ready = 1'b0;
    repeat (5) begin
      @(posedge clock);
      assert (axis_valid && !axis_last) else $fatal(1, "output changed while stalled");
    end
    @(negedge clock);
    axis_ready = 1'b1;
    wait (beat_count == 64);
    assert (hub_drop_count == 0 && packet_drop_count == 0);

    @(negedge clock);
    axis_ready = 1'b0;
    publish_result(32'd10);
    publish_result(32'd11);
    publish_result(32'd12);
    assert (packet_drop_count == 1) else $fatal(1, "expected one pending-record replacement");
    @(negedge clock);
    axis_ready = 1'b1;
    wait (beat_count == 192);
    assert (hub_drop_count == 0 && packet_drop_count == 1);
    $display("meter_packet_tb PASS");
    $finish;
  end

  initial begin
    #100000;
    $fatal(1, "meter_packet_tb timeout");
  end
endmodule
