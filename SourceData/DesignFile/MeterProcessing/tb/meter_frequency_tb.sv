`timescale 1ns/1ps

module meter_frequency_tb;
  logic clock = 1'b0;
  logic resetn = 1'b0;
  logic frame_accept = 1'b0;
  logic [511:0] frame_data = '0;
  logic [63:0] frame_keep = '1;
  logic [383:0] frame_user = '0;
  logic [31:0] generation = 32'h1234_0001;
  logic [31:0] sample_rate = 32'd1000;
  logic [31:0] control = 32'h0000_0a63;
  logic [31:0] window_samples = 32'd100;
  logic [31:0] minimum_millihz = 32'd40000;
  logic [31:0] maximum_millihz = 32'd70000;
  logic [31:0] hysteresis_uv = 32'd1000000;
  logic apply_toggle = 1'b0;

  wire [31:0] active_control;
  wire [31:0] active_window;
  wire [31:0] active_minimum;
  wire [31:0] active_maximum;
  wire [31:0] active_hysteresis;
  wire [31:0] status;
  wire [31:0] frequency_millihz;
  wire [31:0] period_q16;
  wire [31:0] measurement_sequence;
  wire [31:0] rejected_count;

  always #5 clock = ~clock;

  meter_frequency dut (
    .aclk(clock),
    .aresetn(resetn),
    .frame_accept_i(frame_accept),
    .frame_data_i(frame_data),
    .frame_keep_i(frame_keep),
    .frame_user_i(frame_user),
    .config_generation_i(generation),
    .config_sample_rate_i(sample_rate),
    .config_control_i(control),
    .config_window_samples_i(window_samples),
    .config_minimum_millihz_i(minimum_millihz),
    .config_maximum_millihz_i(maximum_millihz),
    .config_hysteresis_uv_i(hysteresis_uv),
    .config_apply_toggle_i(apply_toggle),
    .active_control_o(active_control),
    .active_window_samples_o(active_window),
    .active_minimum_millihz_o(active_minimum),
    .active_maximum_millihz_o(active_maximum),
    .active_hysteresis_uv_o(active_hysteresis),
    .status_o(status),
    .frequency_millihz_o(frequency_millihz),
    .period_q16_samples_o(period_q16),
    .measurement_sequence_o(measurement_sequence),
    .rejected_count_o(rejected_count)
  );

  task automatic apply_configuration(
    input logic [31:0] new_generation,
    input logic [31:0] new_control,
    input logic [31:0] new_window);
    begin
      @(negedge clock);
      generation = new_generation;
      control = new_control;
      window_samples = new_window;
      apply_toggle = ~apply_toggle;
      repeat (20) @(posedge clock);
      assert (active_control == new_control)
        else $fatal(1, "frequency control did not apply");
    end
  endtask

  task automatic send_sample(
    input int unsigned sample_index,
    input longint signed microvolts);
    logic signed [63:0] q16_value;
    begin
      q16_value = microvolts <<< 16;
      @(negedge clock);
      frame_data = '0;
      frame_data[(6 * 64) +: 64] = q16_value;
      frame_user = '0;
      frame_user[31:0] = sample_index;
      frame_user[63:32] = generation;
      frame_user[71:64] = 8'h40;
      frame_accept = 1'b1;
      @(negedge clock);
      frame_accept = 1'b0;
      // Thirteen clocks keep a 50 Hz crossing interval above the estimator's
      // bounded three-division latency while avoiding a needlessly long unit
      // simulation. Standalone synthesis verifies the real 99.999 MHz domain.
      repeat (13) @(posedge clock);
    end
  endtask

  task automatic drive_50_hz_from(
    input int unsigned first_sample_index,
    input int unsigned sample_count);
    begin
      for (int unsigned sample_index = 0;
           sample_index < sample_count; sample_index++)
        send_sample(first_sample_index + sample_index,
          (sample_index % 20) < 10 ? -64'sd2000000 : 64'sd2000000);
      repeat (260) @(posedge clock);
    end
  endtask

  task automatic drive_50_hz(input int unsigned sample_count);
    drive_50_hz_from(0, sample_count);
  endtask

  task automatic verify_sine(
    input int unsigned new_generation,
    input int unsigned new_sample_rate,
    input int unsigned expected_millihz);
    int unsigned sample_count;
    longint signed microvolts;
    real frequency_hz;
    real angle;
    int signed error_millihz;
    begin
      sample_rate = new_sample_rate;
      apply_configuration(new_generation, 32'h0000_0a63,
                          new_sample_rate);
      frequency_hz = expected_millihz / 1000.0;
      sample_count = $rtoi((new_sample_rate / frequency_hz) * 12.0) + 4;
      for (int unsigned sample_index = 0;
           sample_index < sample_count; sample_index++) begin
        // Arbitrary startup phase prevents the test from accidentally aligning
        // crossings to exact sample boundaries.
        angle = (6.283185307179586 * frequency_hz * sample_index /
                 new_sample_rate) + 0.37;
        microvolts = $rtoi(2_000_000.0 * $sin(angle));
        send_sample(sample_index, microvolts);
      end
      repeat (260) @(posedge clock);
      error_millihz = $signed(frequency_millihz) -
                       $signed(expected_millihz);
      if (error_millihz < 0)
        error_millihz = -error_millihz;
      assert (status[1] && error_millihz <= 1)
        else $fatal(1,
          "%0d Hz at %0d SPS measured %0d mHz (error %0d mHz)",
          expected_millihz / 1000, new_sample_rate,
          frequency_millihz, error_millihz);
    end
  endtask

  initial begin
    repeat (8) @(posedge clock);
    resetn = 1'b1;
    repeat (20) @(posedge clock);

    // Rolling 10 cycles: the first result needs 11 positive crossings.
    apply_configuration(32'h1234_0001, 32'h0000_0a63, 32'd1000);
    drive_50_hz(225);
    assert (status[1] && frequency_millihz == 32'd50000 &&
            status[23:16] == 8'd10)
      else $fatal(1, "rolling-cycle result is incorrect: %0d mHz status=%h",
                  frequency_millihz, status);

    // Single-cycle mode becomes valid after two qualified crossings.
    apply_configuration(32'h1234_0002, 32'h0000_0161, 32'd1000);
    drive_50_hz(45);
    assert (status[1] && frequency_millihz == 32'd50000 &&
            status[23:16] == 8'd1)
      else $fatal(1, "single-cycle result is incorrect");

    // A 100 ms time window spans five complete 50 Hz cycles.
    apply_configuration(32'h1234_0003, 32'h0000_0a65, 32'd100);
    drive_50_hz(130);
    assert (status[1] && frequency_millihz == 32'd50000 &&
            status[23:16] >= 8'd5)
      else $fatal(1, "rolling-time result is incorrect");

    // A Q16 timestamp is intentionally a modulo-2^48 value. Verify that
    // rolling-cycle subtraction remains correct when the 32-bit capture
    // sample sequence wraps.
    apply_configuration(32'h1234_0004, 32'h0000_0a63, 32'd1000);
    drive_50_hz_from(32'hffff_ff80, 225);
    assert (status[1] && frequency_millihz == 32'd50000 &&
            status[23:16] == 8'd10)
      else $fatal(1, "sequence-wrap result is incorrect");

    // Exercise the supported sample-rate range and the configured 40-70 Hz
    // limits using sinusoidal VLA input and non-zero startup phase.
    verify_sine(32'h1234_0101, 1_000, 50_000);
    verify_sine(32'h1234_0102, 2_000, 50_000);
    verify_sine(32'h1234_0103, 4_000, 50_000);
    verify_sine(32'h1234_0104, 8_000, 50_000);
    verify_sine(32'h1234_0105, 16_000, 50_000);
    verify_sine(32'h1234_0106, 32_000, 50_000);
    verify_sine(32'h1234_0107, 64_000, 50_000);
    verify_sine(32'h1234_0108, 128_000, 50_000);
    verify_sine(32'h1234_0201, 32_000, 40_000);
    verify_sine(32'h1234_0202, 32_000, 60_000);
    verify_sine(32'h1234_0203, 32_000, 70_000);

    assert (rejected_count == 0)
      else $fatal(1, "valid waveform produced rejected crossings");
    $display("PASS: meter_frequency_tb");
    $finish;
  end
endmodule
