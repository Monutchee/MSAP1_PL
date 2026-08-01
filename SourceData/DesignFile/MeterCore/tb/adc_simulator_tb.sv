`timescale 1ns/1ps

module adc_simulator_tb;
  logic clock = 1'b0;
  logic resetn = 1'b0;
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

  adc_simulator #(.G_ACLK_HZ(1000), .G_PACKET_FRAMES(2)) dut (
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

  task automatic write_reg(input logic [7:0] address, input logic [31:0] data);
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

  task automatic read_reg(input logic [7:0] address, output logic [31:0] data);
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

  task automatic consume_frame(input integer expected_ch0,
                               input bit expected_packet_last);
    integer beat;
    begin
      beat = 0;
      while (beat < 8) begin
        axis_ready = 1'b0;
        wait (axis_valid);
        #1ps;
        assert (axis_keep == 4'hf) else $fatal(1, "bad simulator TKEEP");
        if (beat == 0)
          assert ($signed(axis_data) == expected_ch0)
            else $fatal(1, "CH0 mismatch: expected %0d got %0d", expected_ch0, $signed(axis_data));
        else
          assert ($signed(axis_data) == 0)
            else $fatal(1, "disabled channel %0d was not zero: %0d", beat, $signed(axis_data));
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

  initial begin : watchdog
    #500_000;
    $fatal(1, "ADC simulator test timed out");
  end

  initial begin
    repeat (5) @(posedge clock);
    resetn = 1'b1;

    read_reg(8'h00, value);
    assert (value == 32'h5349_4d31) else $fatal(1, "bad simulator identifier");

    // 100 frame/s on a 1 kHz test clock.  CH0 is a 1000-count sine;
    // phase advances by 90 degrees per frame.  Other channels are invalid.
    write_reg(8'h0c, 32'd100);
    write_reg(8'h14, 32'h0000_0001);
    write_reg(8'h18, 32'h1234_5678);
    write_reg(8'h40, 32'd1000);
    write_reg(8'h80, 32'h4000_0000);
    write_reg(8'h08, 32'h0000_0003);
    write_reg(8'h1c, 32'h0000_0001);

    axis_ready = 1'b0;
    wait (axis_valid);
    held_data = axis_data;
    repeat (6) begin
      @(posedge clock);
      assert (axis_valid && axis_data == held_data)
        else $fatal(1, "simulator output changed under backpressure");
    end
    consume_frame(0, 1'b0);
    consume_frame(999, 1'b1);
    consume_frame(0, 1'b0);
    consume_frame(-1000, 1'b1);

    read_reg(8'h30, value);
    assert (value == 32'h1234_5678) else $fatal(1, "active generation mismatch");
    assert (source_select && frame_rate_valid && frame_rate == 100)
      else $fatal(1, "active simulator status mismatch");
    assert (frame_count >= 4) else $fatal(1, "frame counter did not advance");
    assert (saturation_count == 0) else $fatal(1, "unexpected saturation");
    // The deliberate six-cycle stall is longer than this accelerated test
    // configuration's two-cycle inter-frame margin.  The generator must keep
    // the offered beat stable and explicitly count the sample tick it cannot
    // represent, rather than silently shifting the simulated timebase.
    read_reg(8'h3c, value);
    assert (value != 0) else $fatal(1, "backpressure did not update missed-sample counter");

    // A deliberately excessive peak must clamp rather than wrap.
    // Stop before changing the active bank, matching the source transaction
    // contract used by the RPU controller.
    axis_ready = 1'b1;
    write_reg(8'h08, 32'h0000_0000);
    write_reg(8'h1c, 32'h0000_0001);
    wait (!source_select);
    write_reg(8'h40, 32'h0100_0000);
    write_reg(8'h60, 32'h4000_0000);
    write_reg(8'h80, 32'h0000_0000);
    write_reg(8'h08, 32'h0000_0003);
    axis_ready = 1'b0;
    write_reg(8'h1c, 32'h0000_0001);
    wait (axis_valid);
    consume_frame(8388607, 1'b0);
    assert (saturation_count != 0) else $fatal(1, "saturation was not counted");

    $display("PASS: adc_simulator_tb");
    $finish;
  end
endmodule
