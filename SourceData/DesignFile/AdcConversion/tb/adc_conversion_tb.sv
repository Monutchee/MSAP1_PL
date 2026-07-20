`timescale 1ns/1ps

module adc_conversion_tb;
  logic clock = 1'b0;
  logic resetn = 1'b0;

  logic [31:0] raw_data = '0;
  logic [3:0] raw_keep = 4'hf;
  logic raw_valid = 1'b0;
  wire raw_ready;
  logic raw_last = 1'b0;

  wire [511:0] converted_data;
  wire [63:0] converted_keep;
  wire [383:0] converted_user;
  wire converted_valid;
  logic converted_ready = 1'b0;
  wire converted_last;

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

  AdcConversion_Wrapper dut (
    .aclk(clock), .aresetn(resetn),
    .s_axis_raw_tdata(raw_data), .s_axis_raw_tkeep(raw_keep),
    .s_axis_raw_tvalid(raw_valid), .s_axis_raw_tready(raw_ready),
    .s_axis_raw_tlast(raw_last),
    .m_axis_converted_tdata(converted_data),
    .m_axis_converted_tkeep(converted_keep),
    .m_axis_converted_tuser(converted_user),
    .m_axis_converted_tvalid(converted_valid),
    .m_axis_converted_tready(converted_ready),
    .m_axis_converted_tlast(converted_last),
    .s_axi_config_awaddr(awaddr), .s_axi_config_awvalid(awvalid),
    .s_axi_config_awready(awready), .s_axi_config_wdata(wdata),
    .s_axi_config_wstrb(wstrb), .s_axi_config_wvalid(wvalid),
    .s_axi_config_wready(wready), .s_axi_config_bresp(bresp),
    .s_axi_config_bvalid(bvalid), .s_axi_config_bready(bready),
    .s_axi_config_araddr(araddr), .s_axi_config_arvalid(arvalid),
    .s_axi_config_arready(arready), .s_axi_config_rdata(rdata),
    .s_axi_config_rresp(rresp), .s_axi_config_rvalid(rvalid),
    .s_axi_config_rready(rready)
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
    repeat (5) @(posedge clock);
    resetn = 1'b1;

    axi_write_data_first(8'h10, 32'd42);
    axi_write(8'h14, 32'h0000_0070);
    for (int channel_index = 0; channel_index < 8; channel_index++)
      axi_write(8'h18 + (channel_index * 4), 32'd65536);
    axi_write(8'h08, 32'h0000_0003); // enable and APPLY

    repeat (3) @(posedge clock);
    send_raw(32'sd11, 1'b0);
    send_raw(-32'sd12, 1'b0);
    send_raw(32'sd13, 1'b0);
    send_raw(-32'sd14, 1'b0);
    send_raw(32'sd100, 1'b0);
    send_raw(-32'sd200, 1'b0);
    send_raw(32'sd300, 1'b0);
    send_raw(32'sd400, 1'b1);

    wait (converted_valid);
    assert (!raw_ready) else $fatal(1, "input was not backpressured");
    assert ($signed(converted_data[4*64 +: 64]) == (64'sd100 <<< 16));
    assert ($signed(converted_data[5*64 +: 64]) == (-64'sd200 <<< 16));
    assert ($signed(converted_data[6*64 +: 64]) == (64'sd300 <<< 16));
    assert (converted_data[0*64 +: 64] == 0);
    assert (converted_data[7*64 +: 64] == 0);
    assert (converted_user[31:0] == 1);
    assert (converted_user[63:32] == 42);
    assert (converted_user[71:64] == 8'h70);
    assert (converted_user[73]);
    assert ($signed(converted_user[128 + 4*32 +: 32]) == 32'sd100);
    assert ($signed(converted_user[128 + 5*32 +: 32]) == -32'sd200);
    assert ($signed(converted_user[128 + 6*32 +: 32]) == 32'sd300);
    assert (converted_keep == {64{1'b1}} && converted_last);

    converted_ready = 1'b1;
    @(posedge clock);
    $display("adc_conversion_tb PASS");
    $finish;
  end

  initial begin
    #100000;
    $fatal(1, "adc_conversion_tb timeout");
  end
endmodule
