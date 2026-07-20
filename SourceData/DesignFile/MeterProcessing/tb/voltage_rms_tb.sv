`timescale 1ns/1ps

module voltage_rms_tb;
  logic clock = 1'b0;
  logic resetn = 1'b0;
  logic [511:0] sample_data = '0;
  logic [63:0] sample_keep = {64{1'b1}};
  logic [383:0] sample_user = '0;
  logic sample_valid = 1'b0;
  wire sample_ready;
  logic sample_last = 1'b1;
  logic [31:0] config_generation = 32'd7;
  logic [31:0] config_sample_rate = 32'd20;
  logic [31:0] config_window = 32'd4;
  logic [7:0] config_mask = 8'h70;
  logic config_enable = 1'b1;
  logic config_dc_remove = 1'b1;
  logic config_apply_toggle = 1'b0;
  wire [31:0] active_generation;
  wire [31:0] status;
  wire result_valid;
  wire [31:0] result_sequence;
  wire [31:0] result_generation;
  wire [31:0] result_sample_rate;
  wire [31:0] result_window;
  wire [7:0] result_mask;
  wire [31:0] result_status;
  wire [511:0] result_mean;
  wire [511:0] result_rms;
  wire [255:0] result_rms_count;
  wire [31:0] result_drop_count;

  always #5 clock = ~clock;

  voltage_rms dut (
    .aclk(clock), .aresetn(resetn),
    .s_axis_tdata(sample_data), .s_axis_tkeep(sample_keep), .s_axis_tuser(sample_user),
    .s_axis_tvalid(sample_valid), .s_axis_tready(sample_ready),
    .s_axis_tlast(sample_last),
    .config_generation_i(config_generation),
    .config_sample_rate_i(config_sample_rate),
    .config_window_samples_i(config_window),
    .config_valid_mask_i(config_mask), .config_enable_i(config_enable),
    .config_dc_remove_i(config_dc_remove),
    .config_apply_toggle_i(config_apply_toggle),
    .active_generation_o(active_generation), .status_o(status),
    .result_valid_o(result_valid), .result_sequence_o(result_sequence),
    .result_generation_o(result_generation),
    .result_sample_rate_o(result_sample_rate),
    .result_window_samples_o(result_window),
    .result_valid_mask_o(result_mask), .result_status_o(result_status),
    .result_mean_q16_o(result_mean), .result_rms_q16_o(result_rms),
    .result_rms_count_o(result_rms_count),
    .result_drop_count_o(result_drop_count)
  );

  task automatic send_frame(
    input integer signed channel4,
    input integer signed channel5,
    input integer signed channel6
  );
    begin
      @(negedge clock);
      sample_data = '0;
      sample_data[4*64 +: 64] = 64'(channel4) <<< 16;
      sample_data[5*64 +: 64] = 64'(channel5) <<< 16;
      sample_data[6*64 +: 64] = 64'(channel6) <<< 16;
      sample_user[128 + 4*32 +: 32] = 32'(channel4);
      sample_user[128 + 5*32 +: 32] = 32'(channel5);
      sample_user[128 + 6*32 +: 32] = 32'(channel6);
      sample_valid = 1'b1;
      @(posedge clock);
      assert (sample_ready);
      @(negedge clock);
      sample_valid = 1'b0;
    end
  endtask

  task automatic check_result(input int expected_sequence);
    begin
      do @(posedge clock); while (!result_valid);
      assert (result_sequence == expected_sequence);
      assert (result_generation == 7);
      assert (result_sample_rate == 20 && result_window == 4);
      assert (result_mask == 8'h70);
      assert ($signed(result_mean[4*64 +: 64]) == (64'sd10 <<< 16));
      assert ($signed(result_mean[5*64 +: 64]) == (64'sd20 <<< 16));
      assert ($signed(result_mean[6*64 +: 64]) == (-64'sd7 <<< 16));
      assert ($signed(result_rms[4*64 +: 64]) == (64'sd3 <<< 16));
      assert ($signed(result_rms[5*64 +: 64]) == (64'sd4 <<< 16));
      assert ($signed(result_rms[6*64 +: 64]) == (64'sd5 <<< 16));
      assert (result_rms_count[4*32 +: 32] == 3);
      assert (result_rms_count[5*32 +: 32] == 4);
      assert (result_rms_count[6*32 +: 32] == 5);
      assert (result_drop_count == 0);
    end
  endtask

  initial begin
    repeat (5) @(posedge clock);
    resetn = 1'b1;
    @(negedge clock);
    config_apply_toggle = 1'b1;
    sample_user[63:32] = 32'd7;
    sample_user[71:64] = 8'h70;
    repeat (2) @(posedge clock);

    send_frame(13, 24, -2);
    send_frame(7, 16, -12);
    send_frame(13, 24, -2);
    send_frame(7, 16, -12);
    check_result(1);

    send_frame(13, 24, -2);
    send_frame(7, 16, -12);
    send_frame(13, 24, -2);
    send_frame(7, 16, -12);
    check_result(2);

    $display("voltage_rms_tb PASS");
    $finish;
  end

  initial begin
    #200000;
    $fatal(1, "voltage_rms_tb timeout");
  end
endmodule
