`timescale 1ns/1ps

module adc_conversion_tb;
  logic clock = 1'b0;
  logic resetn = 1'b0;

  logic [31:0] raw_data = '0;
  logic [3:0] raw_keep = 4'hf;
  logic raw_valid = 1'b0;
  wire raw_ready;
  logic raw_last = 1'b0;

  wire [383:0] converted_data;
  wire [47:0] converted_keep;
  wire [383:0] converted_user;
  wire converted_valid;
  logic converted_ready = 1'b0;
  wire converted_last;
  wire [255:0] active_scale;

  logic [7:0] awaddr = '0;
  logic awvalid = 1'b0;
  wire awready;
  logic [31:0] wdata = '0;
  logic [3:0] wstrb = 4'hf;
  logic wvalid = 1'b0;
  wire wready;
  wire [1:0] bresp;
  wire bvalid;
  logic bready = 1'b1;
  logic [7:0] araddr = '0;
  logic arvalid = 1'b0;
  wire arready;
  wire [31:0] rdata;
  wire [1:0] rresp;
  wire rvalid;
  logic rready = 1'b1;

  always #5 clock = ~clock;

  adc_conversion dut (
    .aclk(clock), .aresetn(resetn),
    .s_axis_tdata(raw_data), .s_axis_tkeep(raw_keep),
    .s_axis_tvalid(raw_valid), .s_axis_tready(raw_ready),
    .s_axis_tlast(raw_last),
    .m_axis_tdata(converted_data), .m_axis_tkeep(converted_keep),
    .m_axis_tuser(converted_user), .m_axis_tvalid(converted_valid),
    .m_axis_tready(converted_ready), .m_axis_tlast(converted_last),
    .active_scale_q16_o(active_scale),
    .s_axi_awaddr(awaddr), .s_axi_awvalid(awvalid),
    .s_axi_awready(awready), .s_axi_wdata(wdata),
    .s_axi_wstrb(wstrb), .s_axi_wvalid(wvalid),
    .s_axi_wready(wready), .s_axi_bresp(bresp),
    .s_axi_bvalid(bvalid), .s_axi_bready(bready),
    .s_axi_araddr(araddr), .s_axi_arvalid(arvalid),
    .s_axi_arready(arready), .s_axi_rdata(rdata),
    .s_axi_rresp(rresp), .s_axi_rvalid(rvalid),
    .s_axi_rready(rready)
  );

  task automatic axi_write(input logic [7:0] address, input logic [31:0] value);
    begin
      @(negedge clock);
      awaddr = address;
      wdata = value;
      awvalid = 1'b1;
      wvalid = 1'b1;
      do @(posedge clock); while (!(awready && wready));
      @(negedge clock);
      awvalid = 1'b0;
      wvalid = 1'b0;
      do @(posedge clock); while (!bvalid);
      assert (bresp == 2'b00) else $fatal(1, "AXI write failed");
    end
  endtask

  task automatic axi_read(input logic [7:0] address, output logic [31:0] value);
    begin
      @(negedge clock);
      araddr = address;
      arvalid = 1'b1;
      do @(posedge clock); while (!arready);
      @(negedge clock);
      arvalid = 1'b0;
      do @(posedge clock); while (!rvalid);
      value = rdata;
      assert (rresp == 2'b00) else $fatal(1, "AXI read failed");
    end
  endtask

  task automatic axi_write_data_first(
    input logic [7:0] address,
    input logic [31:0] value
  );
    begin
      @(negedge clock);
      wdata = value;
      wvalid = 1'b1;
      awvalid = 1'b0;
      repeat (2) begin
        @(posedge clock);
        assert (!wready) else $fatal(1, "AXI write data was accepted without an address");
      end
      @(negedge clock);
      awaddr = address;
      awvalid = 1'b1;
      do @(posedge clock); while (!(awready && wready));
      @(negedge clock);
      awvalid = 1'b0;
      wvalid = 1'b0;
      do @(posedge clock); while (!bvalid);
      assert (bresp == 2'b00) else $fatal(1, "AXI data-first write failed");
    end
  endtask

  task automatic consume_output;
    begin
      converted_ready = 1'b1;
      @(posedge clock);
      @(negedge clock);
      converted_ready = 1'b0;
    end
  endtask

  task automatic apply_wiring(
    input logic [7:0] phase_map,
    input logic [3:0] direction_mask,
    input logic [31:0] generation
  );
    logic [31:0] active;
    begin
      axi_write(8'h10, generation);
      axi_write(8'h44, {20'b0, direction_mask, phase_map});
      axi_write(8'h08, 32'h0000_0003);
      active = 32'hffff_ffff;
      repeat (10) begin
        axi_read(8'h48, active);
        if (active == {20'b0, direction_mask, phase_map})
          break;
      end
      assert (active == {20'b0, direction_mask, phase_map})
        else $fatal(1, "active wiring did not commit");
    end
  endtask

  task automatic send_pattern;
    begin
      for (int channel = 0; channel < 8; channel++)
        send_raw(32'(signed'((channel + 1) * 11)), channel == 7);
    end
  endtask

  task automatic check_pattern(
    input logic [7:0] phase_map,
    input logic [3:0] direction_mask,
    input logic [31:0] generation
  );
    longint signed expected_raw;
    longint signed expected_converted;
    int destination;
    begin
      wait (converted_valid);
      assert (converted_user[63:32] == generation)
        else $fatal(1, "generation mismatch");
      assert (converted_user[71:64] == 8'h7f)
        else $fatal(1, "logical valid mask mismatch");
      for (int channel = 0; channel < 4; channel++) begin
        destination = (phase_map >> (channel * 2)) & 3;
        expected_raw = (channel + 1) * 11;
        expected_converted = expected_raw * (channel + 1) * 65536;
        if (direction_mask[channel]) begin
          expected_raw = -expected_raw;
          expected_converted = -expected_converted;
        end
        assert ($signed(converted_user[128 + destination*32 +: 32]) == expected_raw)
          else $fatal(1, "raw map mismatch: CH%0d -> lane %0d", channel, destination);
        assert ($signed(converted_data[destination*48 +: 48]) == expected_converted)
          else $fatal(1, "converted map mismatch: CH%0d -> lane %0d", channel, destination);
        assert (active_scale[destination*32 +: 32] == (channel + 1) * 65536)
          else $fatal(1, "scale provenance mismatch: CH%0d -> lane %0d", channel, destination);
      end
      for (int channel = 4; channel < 7; channel++) begin
        expected_raw = (channel + 1) * 11;
        expected_converted = expected_raw * (channel + 1) * 65536;
        assert ($signed(converted_user[128 + channel*32 +: 32]) == expected_raw);
        assert ($signed(converted_data[channel*48 +: 48]) == expected_converted);
      end
      assert (converted_data[7*48 +: 48] == 0);
      assert (converted_keep == {48{1'b1}} && converted_last);
      consume_output();
    end
  endtask

  task automatic send_raw(input logic signed [31:0] value, input bit last_value);
    begin
      @(negedge clock);
      raw_data = value;
      raw_last = last_value;
      raw_valid = 1'b1;
      do @(posedge clock); while (!raw_ready);
      @(negedge clock);
      raw_valid = 1'b0;
      raw_last = 1'b0;
    end
  endtask

  initial begin
    logic [31:0] value;
    logic [7:0] phase_map;
    logic [31:0] last_valid_wiring;
    int generation;
    repeat (5) @(posedge clock);
    resetn = 1'b1;

    axi_read(8'h00, value);
    assert (value == 32'h0001_0001) else $fatal(1, "conversion version mismatch");
    axi_write_data_first(8'h10, 32'd42);
    axi_write(8'h14, 32'h0000_007f);
    for (int channel_index = 0; channel_index < 8; channel_index++)
      axi_write(8'h18 + (channel_index * 4), (channel_index + 1) * 32'd65536);
    axi_write(8'h44, 32'h0000_00e4);
    axi_write(8'h08, 32'h0000_0003); // enable and APPLY

    send_pattern();
    check_pattern(8'he4, 4'h0, 32'd42);

    // APPLY during an open physical frame must not mix mappings or
    // generations. The old frame closes under ABC, then ACB takes effect.
    for (int channel = 0; channel < 4; channel++)
      send_raw(32'(signed'((channel + 1) * 11)), 1'b0);
    axi_write(8'h10, 32'd43);
    axi_write(8'h44, 32'h0000_00d8);
    axi_write(8'h08, 32'h0000_0003);
    for (int channel = 4; channel < 8; channel++)
      send_raw(32'(signed'((channel + 1) * 11)), channel == 7);
    check_pattern(8'he4, 4'h0, 32'd42);
    send_pattern();
    check_pattern(8'hd8, 4'h0, 32'd43);

    // Exhaust every one-to-one assignment and every physical direction mask.
    generation = 44;
    for (int ch0 = 0; ch0 < 4; ch0++)
      for (int ch1 = 0; ch1 < 4; ch1++)
        for (int ch2 = 0; ch2 < 4; ch2++)
          for (int ch3 = 0; ch3 < 4; ch3++)
            if (ch0 != ch1 && ch0 != ch2 && ch0 != ch3 &&
                ch1 != ch2 && ch1 != ch3 && ch2 != ch3) begin
              phase_map = ch0 | (ch1 << 2) | (ch2 << 4) | (ch3 << 6);
              for (int directions = 0; directions < 16; directions++) begin
                apply_wiring(phase_map, directions[3:0], generation);
                send_pattern();
                check_pattern(phase_map, directions[3:0], generation);
                generation++;
              end
            end

    // The explicit field example: CH1=A, CH3=B, CH0=C, CH2=N.
    apply_wiring(8'h72, 4'b1010, generation);
    send_pattern();
    check_pattern(8'h72, 4'b1010, generation);
    last_valid_wiring = 32'h0000_0a72;
    generation++;

    // Validity is already expressed in logical lanes. Under the mixed map,
    // logical A comes from CH1; only it and unchanged voltage lane CH4 pass.
    axi_write(8'h14, 32'h0000_0011);
    apply_wiring(8'h72, 4'h0, generation);
    send_pattern();
    wait (converted_valid);
    assert (converted_user[71:64] == 8'h11)
      else $fatal(1, "logical valid mask did not follow the routed lanes");
    assert ($signed(converted_data[0 +: 48]) == 48'sd2883584)
      else $fatal(1, "logical A was not sourced from physical CH1");
    for (int lane = 1; lane < 4; lane++)
      assert (converted_data[lane*48 +: 48] == 0)
        else $fatal(1, "invalid logical current lane %0d was not suppressed", lane);
    assert ($signed(converted_data[4*48 +: 48]) == 48'sd18022400)
      else $fatal(1, "unchanged voltage validity was not preserved");
    assert (converted_data[5*48 +: 48] == 0 &&
            converted_data[6*48 +: 48] == 0)
      else $fatal(1, "invalid voltage lanes were not suppressed");
    consume_output();
    last_valid_wiring = 32'h0000_0072;
    generation++;

    // Invalid maps acknowledge the write but do not replace ACTIVE state.
    axi_write(8'h10, generation);
    axi_write(8'h44, 32'h0000_0000);
    axi_write(8'h08, 32'h0000_0003);
    repeat (3) @(posedge clock);
    axi_read(8'h48, value);
    assert (value == last_valid_wiring) else $fatal(1, "invalid map committed");
    axi_read(8'h0c, value);
    assert (value[3]) else $fatal(1, "invalid map status was not reported");

    // Reserved direction/configuration bits are invalid rather than silently
    // masked into an apparently successful commit.
    axi_write(8'h10, generation + 1);
    axi_write(8'h44, 32'h0000_10e4);
    axi_write(8'h08, 32'h0000_0003);
    repeat (3) @(posedge clock);
    axi_read(8'h48, value);
    assert (value == last_valid_wiring)
      else $fatal(1, "reserved wiring bits committed");
    axi_read(8'h0c, value);
    assert (value[3]) else $fatal(1, "reserved wiring bits were not rejected");

    // Reversing the signed-24-bit minimum clamps raw and converted values.
    generation += 2;
    axi_write(8'h14, 32'h0000_007f);
    axi_write(8'h18, 32'h0100_0000);
    apply_wiring(8'he4, 4'b0001, generation);
    send_raw(-32'sd8388608, 1'b0);
    for (int channel = 1; channel < 8; channel++)
      send_raw(32'(signed'((channel + 1) * 11)), channel == 7);
    wait (converted_valid);
    assert ($signed(converted_user[128 +: 32]) == 32'sd8388607)
      else $fatal(1, "minimum raw current was not clamped");
    assert ($signed(converted_data[0 +: 48]) == 48'sh7fff_ffff_ffff)
      else $fatal(1, "minimum converted current was not clamped");
    axi_read(8'h0c, value);
    assert (value[2] && !value[3]) else $fatal(1, "saturation/status mismatch");
    consume_output();

    $display("adc_conversion_tb PASS");
    $finish;
  end

  initial begin
    #5000000;
    $fatal(1, "adc_conversion_tb timeout");
  end
endmodule
