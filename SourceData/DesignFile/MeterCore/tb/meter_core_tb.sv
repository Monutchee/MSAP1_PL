`timescale 1ns/1ps

module meter_core_tb;
  logic clock = 1'b0;
  logic resetn = 1'b0;

  logic [7:0] cap_awaddr = '0;
  logic cap_awvalid = 1'b0;
  wire cap_awready;
  logic [31:0] cap_wdata = '0;
  logic [3:0] cap_wstrb = 4'hf;
  logic cap_wvalid = 1'b0;
  wire cap_wready;
  wire [1:0] cap_bresp;
  wire cap_bvalid;
  logic cap_bready = 1'b1;
  logic [7:0] cap_araddr = '0;
  logic cap_arvalid = 1'b0;
  wire cap_arready;
  wire [31:0] cap_rdata;
  wire [1:0] cap_rresp;
  wire cap_rvalid;
  logic cap_rready = 1'b1;

  logic [7:0] conv_awaddr = '0;
  logic conv_awvalid = 1'b0;
  wire conv_awready;
  logic [31:0] conv_wdata = '0;
  logic [3:0] conv_wstrb = 4'hf;
  logic conv_wvalid = 1'b0;
  wire conv_wready;
  wire [1:0] conv_bresp;
  wire conv_bvalid;
  logic conv_bready = 1'b1;
  logic [7:0] conv_araddr = '0;
  logic conv_arvalid = 1'b0;
  wire conv_arready;
  wire [31:0] conv_rdata;
  wire [1:0] conv_rresp;
  wire conv_rvalid;
  logic conv_rready = 1'b1;

  logic [7:0] proc_awaddr = '0;
  logic proc_awvalid = 1'b0;
  wire proc_awready;
  logic [31:0] proc_wdata = '0;
  logic [3:0] proc_wstrb = 4'hf;
  logic proc_wvalid = 1'b0;
  wire proc_wready;
  wire [1:0] proc_bresp;
  wire proc_bvalid;
  logic proc_bready = 1'b1;
  logic [7:0] proc_araddr = '0;
  logic proc_arvalid = 1'b0;
  wire proc_arready;
  wire [31:0] proc_rdata;
  wire [1:0] proc_rresp;
  wire proc_rvalid;
  logic proc_rready = 1'b1;

  wire [31:0] meter_tdata;
  wire [3:0] meter_tkeep;
  wire meter_tvalid;
  logic meter_tready = 1'b0;
  wire meter_tlast;

  logic adc_dclk = 1'b0;
  logic adc_drdy_n = 1'b0;
  logic [3:0] adc_dout = '0;
  wire adc_reset_n;
  wire adc_start_n;
  wire adc_convst_sar;

  logic [31:0] words [0:7];
  logic [63:0] lanes [0:3];
  logic [31:0] read_value;
  logic [31:0] stalled_word;
  logic stalled_last;
  integer channel;
  integer bit_index;

  always #5 clock = ~clock;
  always #20 adc_dclk = ~adc_dclk;

  MeterCore_Wrapper dut (
    .aclk(clock),
    .aresetn(resetn),
    .s_axi_capture_awaddr(cap_awaddr),
    .s_axi_capture_awvalid(cap_awvalid),
    .s_axi_capture_awready(cap_awready),
    .s_axi_capture_wdata(cap_wdata),
    .s_axi_capture_wstrb(cap_wstrb),
    .s_axi_capture_wvalid(cap_wvalid),
    .s_axi_capture_wready(cap_wready),
    .s_axi_capture_bresp(cap_bresp),
    .s_axi_capture_bvalid(cap_bvalid),
    .s_axi_capture_bready(cap_bready),
    .s_axi_capture_araddr(cap_araddr),
    .s_axi_capture_arvalid(cap_arvalid),
    .s_axi_capture_arready(cap_arready),
    .s_axi_capture_rdata(cap_rdata),
    .s_axi_capture_rresp(cap_rresp),
    .s_axi_capture_rvalid(cap_rvalid),
    .s_axi_capture_rready(cap_rready),
    .s_axi_conversion_awaddr(conv_awaddr),
    .s_axi_conversion_awvalid(conv_awvalid),
    .s_axi_conversion_awready(conv_awready),
    .s_axi_conversion_wdata(conv_wdata),
    .s_axi_conversion_wstrb(conv_wstrb),
    .s_axi_conversion_wvalid(conv_wvalid),
    .s_axi_conversion_wready(conv_wready),
    .s_axi_conversion_bresp(conv_bresp),
    .s_axi_conversion_bvalid(conv_bvalid),
    .s_axi_conversion_bready(conv_bready),
    .s_axi_conversion_araddr(conv_araddr),
    .s_axi_conversion_arvalid(conv_arvalid),
    .s_axi_conversion_arready(conv_arready),
    .s_axi_conversion_rdata(conv_rdata),
    .s_axi_conversion_rresp(conv_rresp),
    .s_axi_conversion_rvalid(conv_rvalid),
    .s_axi_conversion_rready(conv_rready),
    .s_axi_processing_awaddr(proc_awaddr),
    .s_axi_processing_awvalid(proc_awvalid),
    .s_axi_processing_awready(proc_awready),
    .s_axi_processing_wdata(proc_wdata),
    .s_axi_processing_wstrb(proc_wstrb),
    .s_axi_processing_wvalid(proc_wvalid),
    .s_axi_processing_wready(proc_wready),
    .s_axi_processing_bresp(proc_bresp),
    .s_axi_processing_bvalid(proc_bvalid),
    .s_axi_processing_bready(proc_bready),
    .s_axi_processing_araddr(proc_araddr),
    .s_axi_processing_arvalid(proc_arvalid),
    .s_axi_processing_arready(proc_arready),
    .s_axi_processing_rdata(proc_rdata),
    .s_axi_processing_rresp(proc_rresp),
    .s_axi_processing_rvalid(proc_rvalid),
    .s_axi_processing_rready(proc_rready),
    .m_axis_meter_tdata(meter_tdata),
    .m_axis_meter_tkeep(meter_tkeep),
    .m_axis_meter_tvalid(meter_tvalid),
    .m_axis_meter_tready(meter_tready),
    .m_axis_meter_tlast(meter_tlast),
    .adc_dclk(adc_dclk),
    .adc_drdy_n(adc_drdy_n),
    .adc_dout(adc_dout),
    .adc_reset_n(adc_reset_n),
    .adc_start_n(adc_start_n),
    .adc_convst_sar(adc_convst_sar)
  );

  task automatic capture_write(input logic [7:0] address,
                               input logic [31:0] value);
    begin
      @(negedge clock);
      cap_awaddr = address;
      cap_wdata = value;
      cap_awvalid = 1'b1;
      cap_wvalid = 1'b1;
      do @(posedge clock); while (!(cap_awready && cap_wready));
      @(negedge clock);
      cap_awvalid = 1'b0;
      cap_wvalid = 1'b0;
      do @(posedge clock); while (!cap_bvalid);
      assert (cap_bresp == 2'b00) else $fatal(1, "capture AXI write failed");
    end
  endtask

  task automatic conversion_write(input logic [7:0] address,
                                  input logic [31:0] value);
    begin
      @(negedge clock);
      conv_awaddr = address;
      conv_wdata = value;
      conv_awvalid = 1'b1;
      conv_wvalid = 1'b1;
      do @(posedge clock); while (!(conv_awready && conv_wready));
      @(negedge clock);
      conv_awvalid = 1'b0;
      conv_wvalid = 1'b0;
      do @(posedge clock); while (!conv_bvalid);
      assert (conv_bresp == 2'b00) else $fatal(1, "conversion AXI write failed");
    end
  endtask

  task automatic processing_write(input logic [7:0] address,
                                  input logic [31:0] value);
    begin
      @(negedge clock);
      proc_awaddr = address;
      proc_wdata = value;
      proc_awvalid = 1'b1;
      proc_wvalid = 1'b1;
      do @(posedge clock); while (!(proc_awready && proc_wready));
      @(negedge clock);
      proc_awvalid = 1'b0;
      proc_wvalid = 1'b0;
      do @(posedge clock); while (!proc_bvalid);
      assert (proc_bresp == 2'b00) else $fatal(1, "processing AXI write failed");
    end
  endtask

  task automatic capture_read(input logic [7:0] address,
                              output logic [31:0] value);
    begin
      @(negedge clock);
      cap_araddr = address;
      cap_arvalid = 1'b1;
      do @(posedge clock); while (!cap_arready);
      @(negedge clock);
      cap_arvalid = 1'b0;
      do @(posedge clock); while (!cap_rvalid);
      assert (cap_rresp == 2'b00) else $fatal(1, "capture AXI read failed");
      value = cap_rdata;
    end
  endtask

  task automatic conversion_read(input logic [7:0] address,
                                 output logic [31:0] value);
    begin
      @(negedge clock);
      conv_araddr = address;
      conv_arvalid = 1'b1;
      do @(posedge clock); while (!conv_arready);
      @(negedge clock);
      conv_arvalid = 1'b0;
      do @(posedge clock); while (!conv_rvalid);
      assert (conv_rresp == 2'b00) else $fatal(1, "conversion AXI read failed");
      value = conv_rdata;
    end
  endtask

  task automatic processing_read(input logic [7:0] address,
                                 output logic [31:0] value);
    begin
      @(negedge clock);
      proc_araddr = address;
      proc_arvalid = 1'b1;
      do @(posedge clock); while (!proc_arready);
      @(negedge clock);
      proc_arvalid = 1'b0;
      do @(posedge clock); while (!proc_rvalid);
      assert (proc_rresp == 2'b00) else $fatal(1, "processing AXI read failed");
      value = proc_rdata;
    end
  endtask

  task automatic build_frame(input integer frame_number);
    logic [7:0] header;
    logic signed [23:0] sample;
    begin
      for (channel = 0; channel < 8; channel = channel + 1) begin
        case (channel)
          0: sample = frame_number[0] ? 24'sd30 : 24'sd10;
          1: sample = frame_number[0] ? 24'sd22 : 24'sd18;
          2: sample = frame_number[0] ? -24'sd4 : -24'sd12;
          3: sample = frame_number[0] ? 24'sd5 : -24'sd5;
          4: sample = frame_number[0] ? 24'sd13 : 24'sd7;
          5: sample = frame_number[0] ? 24'sd24 : 24'sd16;
          6: sample = frame_number[0] ? -24'sd12 : -24'sd2;
          default: sample = 24'sd100 + channel;
        endcase
        header = {1'b0, channel[2:0], 4'h0};
        words[channel] = {header, sample};
      end

      lanes[0] = {words[0], words[1]};
      lanes[1] = {words[2], words[3]};
      lanes[2] = {words[4], words[5]};
      lanes[3] = {words[6], words[7]};
    end
  endtask

  task automatic send_frame(input integer frame_number);
    begin
      build_frame(frame_number);
      adc_drdy_n = 1'b0;
      repeat (3) @(posedge adc_dclk);
      @(posedge adc_dclk);
      adc_drdy_n = 1'b1;
      @(posedge adc_dclk);
      adc_drdy_n = 1'b0;
      adc_dout = {lanes[3][63], lanes[2][63], lanes[1][63], lanes[0][63]};

      for (bit_index = 62; bit_index >= 0; bit_index = bit_index - 1) begin
        @(posedge adc_dclk);
        adc_dout = {lanes[3][bit_index], lanes[2][bit_index],
                    lanes[1][bit_index], lanes[0][bit_index]};
      end
      @(negedge adc_dclk);
      #1;
    end
  endtask

  task automatic configure_meter(input logic [31:0] generation,
                                 input bit remove_dc);
    begin
      conversion_write(8'h10, generation);
      conversion_write(8'h14, 32'h0000_007f);
      for (int index = 0; index < 8; index++)
        conversion_write(8'h18 + index * 4, 32'd65536);
      conversion_write(8'h08, 32'h0000_0003);

      processing_write(8'h10, generation);
      processing_write(8'h14, 32'd20);
      processing_write(8'h18, 32'd4);
      processing_write(8'h1c, 32'h0000_007f);
      processing_write(8'h08, remove_dc ? 32'h0000_0007 : 32'h0000_0003);

      repeat (8) @(posedge clock);
      conversion_read(8'h38, read_value);
      assert (read_value == generation)
        else $fatal(1, "conversion generation mismatch");
      processing_read(8'h20, read_value);
      assert (read_value == generation)
        else $fatal(1, "processing generation mismatch");
      processing_read(8'h08, read_value);
      assert (read_value[2] == remove_dc)
        else $fatal(1, "processing DC-removal configuration mismatch");
    end
  endtask

  task automatic check_meter_word(input integer word_index,
                                  input integer expected_sequence,
                                  input integer expected_generation,
                                  input integer rms0,
                                  input integer rms1,
                                  input integer rms2,
                                  input integer rms3,
                                  input integer rms4,
                                  input integer rms5,
                                  input integer rms6);
    begin
      case (word_index)
        0: assert (meter_tdata == 32'h3152_544d) else $fatal(1, "bad MTR1 magic");
        1: assert (meter_tdata == 32'h0001_0001) else $fatal(1, "bad record format");
        2: assert (meter_tdata == 32'd256) else $fatal(1, "bad record length");
        3: assert (meter_tdata == expected_sequence) else $fatal(1, "bad result sequence");
        4: assert (meter_tdata == expected_generation) else $fatal(1, "bad generation");
        5: assert (meter_tdata == 32'd20) else $fatal(1, "bad sample rate");
        6: assert (meter_tdata == 32'd4) else $fatal(1, "bad RMS window");
        7: assert (meter_tdata[7:0] == 8'h7f) else $fatal(1, "bad valid mask");
        8: assert (meter_tdata == 0) else $fatal(1, "unexpected result status");
        10: assert (meter_tdata == 0) else $fatal(1, "header errors are non-zero");
        11: assert (meter_tdata == 0) else $fatal(1, "FIFO overflows are non-zero");
        12: assert (meter_tdata == 0) else $fatal(1, "packetizer drops are non-zero");
        13: assert (meter_tdata == 0) else $fatal(1, "hub drops are non-zero");
        14: assert (meter_tdata == 0) else $fatal(1, "ADC alerts are non-zero");
        16: assert ($signed(meter_tdata) == 20) else $fatal(1, "CH0 mean mismatch");
        17: assert (meter_tdata == 0) else $fatal(1, "CH0 mean high mismatch");
        18: assert (meter_tdata == rms0) else $fatal(1, "CH0 raw RMS mismatch");
        19: assert ($signed(meter_tdata) == rms0) else $fatal(1, "CH0 RMS mismatch");
        20: assert (meter_tdata == 0) else $fatal(1, "CH0 RMS high mismatch");
        21: assert ($signed(meter_tdata) == 20) else $fatal(1, "CH1 mean mismatch");
        22: assert (meter_tdata == 0) else $fatal(1, "CH1 mean high mismatch");
        23: assert (meter_tdata == rms1) else $fatal(1, "CH1 raw RMS mismatch");
        24: assert ($signed(meter_tdata) == rms1) else $fatal(1, "CH1 RMS mismatch");
        25: assert (meter_tdata == 0) else $fatal(1, "CH1 RMS high mismatch");
        26: assert ($signed(meter_tdata) == -8) else $fatal(1, "CH2 mean mismatch");
        27: assert (meter_tdata == 32'hffff_ffff) else $fatal(1, "CH2 mean high mismatch");
        28: assert (meter_tdata == rms2) else $fatal(1, "CH2 raw RMS mismatch");
        29: assert ($signed(meter_tdata) == rms2) else $fatal(1, "CH2 RMS mismatch");
        30: assert (meter_tdata == 0) else $fatal(1, "CH2 RMS high mismatch");
        31: assert ($signed(meter_tdata) == 0) else $fatal(1, "CH3 mean mismatch");
        32: assert (meter_tdata == 0) else $fatal(1, "CH3 mean high mismatch");
        33: assert (meter_tdata == rms3) else $fatal(1, "CH3 raw RMS mismatch");
        34: assert ($signed(meter_tdata) == rms3) else $fatal(1, "CH3 RMS mismatch");
        35: assert (meter_tdata == 0) else $fatal(1, "CH3 RMS high mismatch");
        36: assert ($signed(meter_tdata) == 10) else $fatal(1, "CH4 mean mismatch");
        37: assert (meter_tdata == 0) else $fatal(1, "CH4 mean high mismatch");
        38: assert (meter_tdata == rms4) else $fatal(1, "CH4 raw RMS mismatch: %0d", meter_tdata);
        39: assert ($signed(meter_tdata) == rms4) else $fatal(1, "CH4 RMS mismatch: %0d", $signed(meter_tdata));
        40: assert (meter_tdata == 0) else $fatal(1, "CH4 RMS high mismatch");
        41: assert ($signed(meter_tdata) == 20) else $fatal(1, "CH5 mean mismatch");
        42: assert (meter_tdata == 0) else $fatal(1, "CH5 mean high mismatch");
        43: assert (meter_tdata == rms5) else $fatal(1, "CH5 raw RMS mismatch: %0d", meter_tdata);
        44: assert ($signed(meter_tdata) == rms5) else $fatal(1, "CH5 RMS mismatch: %0d", $signed(meter_tdata));
        45: assert (meter_tdata == 0) else $fatal(1, "CH5 RMS high mismatch");
        46: assert ($signed(meter_tdata) == -7) else $fatal(1, "CH6 mean mismatch");
        47: assert (meter_tdata == 32'hffff_ffff) else $fatal(1, "CH6 mean high mismatch");
        48: assert (meter_tdata == rms6) else $fatal(1, "CH6 raw RMS mismatch: %0d", meter_tdata);
        49: assert ($signed(meter_tdata) == rms6) else $fatal(1, "CH6 RMS mismatch: %0d", $signed(meter_tdata));
        50: assert (meter_tdata == 0) else $fatal(1, "CH6 RMS high mismatch");
        default: ;
      endcase
    end
  endtask

  task automatic consume_record(input integer expected_sequence,
                                input integer expected_generation,
                                input integer rms0,
                                input integer rms1,
                                input integer rms2,
                                input integer rms3,
                                input integer rms4,
                                input integer rms5,
                                input integer rms6);
    integer word_index;
    begin
      @(negedge clock);
      meter_tready = 1'b1;
      word_index = 0;
      while (word_index < 64) begin
        @(posedge clock);
        if (meter_tvalid && meter_tready) begin
          assert (meter_tkeep == 4'hf) else $fatal(1, "bad meter TKEEP");
          assert (meter_tlast == (word_index == 63))
            else $fatal(1, "meter TLAST at word %0d", word_index);
          check_meter_word(word_index, expected_sequence, expected_generation,
                           rms0, rms1, rms2, rms3,
                           rms4, rms5, rms6);
          word_index = word_index + 1;
        end
      end
      @(negedge clock);
      meter_tready = 1'b0;
    end
  endtask

  initial begin : watchdog
    #1_000_000;
    $fatal(1, "MeterCore integration test timed out");
  end

  initial begin
    repeat (8) @(posedge clock);
    resetn = 1'b1;

    configure_meter(32'd42, 1'b1);
    capture_write(8'h04, 32'h0000_0005);
    repeat (20) @(posedge adc_dclk);

    assert (adc_reset_n && !adc_start_n && !adc_convst_sar)
      else $fatal(1, "ADC control outputs mismatch");

    for (int frame = 0; frame < 4; frame++)
      send_frame(frame);

    wait (meter_tvalid);
    stalled_word = meter_tdata;
    stalled_last = meter_tlast;
    repeat (12) begin
      @(posedge clock);
      assert (meter_tvalid && meter_tdata == stalled_word &&
              meter_tlast == stalled_last)
        else $fatal(1, "meter output changed under DMA backpressure");
    end

    // Capture another complete window while the first DMA record is stalled.
    for (int frame = 4; frame < 8; frame++)
      send_frame(frame);
    repeat (20) @(posedge clock);
    capture_read(8'h10, read_value);
    assert (read_value == 8)
      else $fatal(1, "capture stalled behind meter DMA: %0d frames", read_value);

    consume_record(1, 42, 10, 2, 4, 5, 3, 4, 5);
    consume_record(2, 42, 10, 2, 4, 5, 3, 4, 5);

    configure_meter(32'd43, 1'b0);
    for (int frame = 8; frame < 12; frame++)
      send_frame(frame);
    consume_record(3, 43, 22, 20, 8, 5, 10, 20, 8);

    repeat (20) @(posedge clock);
    capture_read(8'h10, read_value);
    assert (read_value == 12) else $fatal(1, "final frame count mismatch");
    capture_read(8'h14, read_value);
    assert (read_value == 0) else $fatal(1, "unexpected FIFO overflow");
    capture_read(8'h18, read_value);
    assert (read_value == 0) else $fatal(1, "unexpected header error");
    capture_read(8'h1c, read_value);
    assert (read_value == 0) else $fatal(1, "unexpected ADC alert");
    processing_read(8'h28, read_value);
    assert (read_value == 0) else $fatal(1, "unexpected RMS result drop");
    processing_read(8'h2c, read_value);
    assert (read_value == 0) else $fatal(1, "unexpected packetizer drop");

    $display("PASS: meter_core_tb");
    $finish;
  end
endmodule
