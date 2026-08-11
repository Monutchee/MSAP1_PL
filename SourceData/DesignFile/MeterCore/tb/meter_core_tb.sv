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

  logic [7:0] wave_awaddr = '0;
  logic wave_awvalid = 1'b0;
  wire wave_awready;
  logic [31:0] wave_wdata = '0;
  logic [3:0] wave_wstrb = 4'hf;
  logic wave_wvalid = 1'b0;
  wire wave_wready;
  wire [1:0] wave_bresp;
  wire wave_bvalid;
  logic wave_bready = 1'b1;
  logic [7:0] wave_araddr = '0;
  logic wave_arvalid = 1'b0;
  wire wave_arready;
  wire [31:0] wave_rdata;
  wire [1:0] wave_rresp;
  wire wave_rvalid;
  logic wave_rready = 1'b1;

  logic [7:0] sim_awaddr = '0;
  logic sim_awvalid = 1'b0;
  wire sim_awready;
  logic [31:0] sim_wdata = '0;
  logic [3:0] sim_wstrb = 4'hf;
  logic sim_wvalid = 1'b0;
  wire sim_wready;
  wire [1:0] sim_bresp;
  wire sim_bvalid;
  logic sim_bready = 1'b1;
  logic [7:0] sim_araddr = '0;
  logic sim_arvalid = 1'b0;
  wire sim_arready;
  wire [31:0] sim_rdata;
  wire [1:0] sim_rresp;
  wire sim_rvalid;
  logic sim_rready = 1'b1;

  wire [31:0] meter_tdata;
  wire [3:0] meter_tkeep;
  wire meter_tvalid;
  logic meter_tready = 1'b0;
  wire meter_tlast;

  wire [31:0] waveform_tdata;
  wire [3:0] waveform_tkeep;
  wire waveform_tvalid;
  logic waveform_tready = 1'b0;
  wire waveform_tlast;

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
    .s_axi_waveform_awaddr(wave_awaddr),
    .s_axi_waveform_awvalid(wave_awvalid),
    .s_axi_waveform_awready(wave_awready),
    .s_axi_waveform_wdata(wave_wdata),
    .s_axi_waveform_wstrb(wave_wstrb),
    .s_axi_waveform_wvalid(wave_wvalid),
    .s_axi_waveform_wready(wave_wready),
    .s_axi_waveform_bresp(wave_bresp),
    .s_axi_waveform_bvalid(wave_bvalid),
    .s_axi_waveform_bready(wave_bready),
    .s_axi_waveform_araddr(wave_araddr),
    .s_axi_waveform_arvalid(wave_arvalid),
    .s_axi_waveform_arready(wave_arready),
    .s_axi_waveform_rdata(wave_rdata),
    .s_axi_waveform_rresp(wave_rresp),
    .s_axi_waveform_rvalid(wave_rvalid),
    .s_axi_waveform_rready(wave_rready),
    .s_axi_simulator_awaddr(sim_awaddr),
    .s_axi_simulator_awvalid(sim_awvalid),
    .s_axi_simulator_awready(sim_awready),
    .s_axi_simulator_wdata(sim_wdata),
    .s_axi_simulator_wstrb(sim_wstrb),
    .s_axi_simulator_wvalid(sim_wvalid),
    .s_axi_simulator_wready(sim_wready),
    .s_axi_simulator_bresp(sim_bresp),
    .s_axi_simulator_bvalid(sim_bvalid),
    .s_axi_simulator_bready(sim_bready),
    .s_axi_simulator_araddr(sim_araddr),
    .s_axi_simulator_arvalid(sim_arvalid),
    .s_axi_simulator_arready(sim_arready),
    .s_axi_simulator_rdata(sim_rdata),
    .s_axi_simulator_rresp(sim_rresp),
    .s_axi_simulator_rvalid(sim_rvalid),
    .s_axi_simulator_rready(sim_rready),
    .m_axis_meter_tdata(meter_tdata),
    .m_axis_meter_tkeep(meter_tkeep),
    .m_axis_meter_tvalid(meter_tvalid),
    .m_axis_meter_tready(meter_tready),
    .m_axis_meter_tlast(meter_tlast),
    .m_axis_waveform_tdata(waveform_tdata),
    .m_axis_waveform_tkeep(waveform_tkeep),
    .m_axis_waveform_tvalid(waveform_tvalid),
    .m_axis_waveform_tready(waveform_tready),
    .m_axis_waveform_tlast(waveform_tlast),
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

  task automatic waveform_write(input logic [7:0] address,
                                input logic [31:0] value);
    begin
      @(negedge clock);
      wave_awaddr = address;
      wave_wdata = value;
      wave_awvalid = 1'b1;
      wave_wvalid = 1'b1;
      do @(posedge clock); while (!(wave_awready && wave_wready));
      @(negedge clock);
      wave_awvalid = 1'b0;
      wave_wvalid = 1'b0;
      do @(posedge clock); while (!wave_bvalid);
      assert (wave_bresp == 2'b00) else $fatal(1, "waveform AXI write failed");
    end
  endtask

  task automatic waveform_read(input logic [7:0] address,
                               output logic [31:0] value);
    begin
      @(negedge clock);
      wave_araddr = address;
      wave_arvalid = 1'b1;
      do @(posedge clock); while (!wave_arready);
      @(negedge clock);
      wave_arvalid = 1'b0;
      do @(posedge clock); while (!wave_rvalid);
      assert (wave_rresp == 2'b00) else $fatal(1, "waveform AXI read failed");
      value = wave_rdata;
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

  // Serial transmission of whatever build_* task last placed in lanes[].
  task automatic transmit_frame;
    begin
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

  task automatic send_frame(input integer frame_number);
    begin
      build_frame(frame_number);
      transmit_frame();
    end
  endtask

  // Frame with a synthetic grid waveform on CH6/Va: +10 for the first half
  // of a 20-frame cycle, -10 for the second half. The rising edge at each
  // cycle start gives the zero-crossing detector one qualified crossing per
  // cycle once the hysteresis is configured below the amplitude.
  task automatic send_grid_frame(input integer cycle_position);
    logic [7:0] header;
    logic signed [23:0] grid_sample;
    begin
      build_frame(cycle_position);
      grid_sample = (cycle_position % 20) < 10 ? 24'sd10 : -24'sd10;
      header = {1'b0, 3'd6, 4'h0};
      words[6] = {header, grid_sample};
      lanes[0] = {words[0], words[1]};
      lanes[1] = {words[2], words[3]};
      lanes[2] = {words[4], words[5]};
      lanes[3] = {words[6], words[7]};
      transmit_frame();
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
                                  input logic [31:0] expected_timing,
                                  input logic [31:0] expected_first_sample,
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
        1: assert (meter_tdata == 32'h0001_0002) else $fatal(1, "bad record format");
        2: assert (meter_tdata == 32'd256) else $fatal(1, "bad record length");
        3: assert (meter_tdata == expected_sequence) else $fatal(1, "bad result sequence");
        4: assert (meter_tdata == expected_generation) else $fatal(1, "bad generation");
        5: assert (meter_tdata == 32'd20) else $fatal(1, "bad sample rate");
        6: assert (meter_tdata == 32'd4) else $fatal(1, "bad RMS window");
        7: assert (meter_tdata[7:0] == 8'h7f) else $fatal(1, "bad valid mask");
        8: assert (meter_tdata == 0) else $fatal(1, "unexpected result status");
        15: assert (meter_tdata == expected_timing)
          else $fatal(1, "bad timing word %08h, expected %08h",
                      meter_tdata, expected_timing);
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
        60: assert (meter_tdata == expected_first_sample)
          else $fatal(1, "bad first sample %0d, expected %0d",
                      meter_tdata, expected_first_sample);
        61: assert (meter_tdata == 0) else $fatal(1, "bad first sample high");
        62: assert (meter_tdata == 0) else $fatal(1, "word 62 not reserved");
        63: assert (meter_tdata == 0) else $fatal(1, "word 63 not reserved");
        default: ;
      endcase
    end
  endtask

  task automatic consume_record(input integer expected_sequence,
                                input integer expected_generation,
                                input logic [31:0] expected_timing,
                                input logic [31:0] expected_first_sample,
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
                           expected_timing, expected_first_sample,
                           rms0, rms1, rms2, rms3,
                           rms4, rms5, rms6);
          word_index = word_index + 1;
        end
      end
      @(negedge clock);
      meter_tready = 1'b0;
    end
  endtask

  // Consume one record checking only the header and basic-block timing
  // words. Used by the cycle-mode scenario, whose channel values follow the
  // grid waveform rather than the fixed legacy pattern.
  task automatic consume_timing_record(input integer expected_sequence,
                                       input integer expected_generation,
                                       input logic [31:0] expected_count,
                                       input logic [31:0] expected_timing,
                                       input logic [31:0] expected_first_sample);
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
          case (word_index)
            0: assert (meter_tdata == 32'h3152_544d) else $fatal(1, "bad MTR1 magic");
            1: assert (meter_tdata == 32'h0001_0002) else $fatal(1, "bad record format");
            2: assert (meter_tdata == 32'd256) else $fatal(1, "bad record length");
            3: assert (meter_tdata == expected_sequence) else $fatal(1, "bad result sequence");
            4: assert (meter_tdata == expected_generation) else $fatal(1, "bad generation");
            6: assert (meter_tdata == expected_count)
              else $fatal(1, "bad block sample count %0d, expected %0d",
                          meter_tdata, expected_count);
            15: assert (meter_tdata == expected_timing)
              else $fatal(1, "bad timing word %08h, expected %08h",
                          meter_tdata, expected_timing);
            60: assert (meter_tdata == expected_first_sample)
              else $fatal(1, "bad first sample %0d, expected %0d",
                          meter_tdata, expected_first_sample);
            61: assert (meter_tdata == 0) else $fatal(1, "bad first sample high");
            default: ;
          endcase
          word_index = word_index + 1;
        end
      end
      @(negedge clock);
      meter_tready = 1'b0;
    end
  endtask

  // Configure a cycle-mode generation: 50 Hz nominal with 2 cycles per
  // block (kept small for simulation), hysteresis below the +/-10 grid
  // amplitude so crossings qualify, and a fallback window that neither
  // expires before the first crossing nor unlocks between 20-frame cycles.
  // Frame with an 8-frame-period grid waveform on CH6 (four +10 samples,
  // four -10). Used by the aggregation scenario so 10-cycle blocks stay
  // short enough to simulate: one block = 80 frames.
  task automatic send_grid_frame8(input integer cycle_position);
    logic [7:0] header;
    logic signed [23:0] grid_sample;
    begin
      build_frame(cycle_position);
      grid_sample = (cycle_position % 8) < 4 ? 24'sd10 : -24'sd10;
      header = {1'b0, 3'd6, 4'h0};
      words[6] = {header, grid_sample};
      lanes[0] = {words[0], words[1]};
      lanes[1] = {words[2], words[3]};
      lanes[2] = {words[4], words[5]};
      lanes[3] = {words[6], words[7]};
      transmit_frame();
    end
  endtask

  // Cycle-mode configuration with REAL Class A shape (50 Hz -> 10 cycles
  // per block) so the aggregator accepts the blocks. The fallback window
  // (800) exceeds the relock time and the stale threshold (200) exceeds
  // the 8-frame cycle spacing.
  task automatic configure_meter_aggregate(input logic [31:0] generation);
    begin
      conversion_write(8'h10, generation);
      conversion_write(8'h14, 32'h0000_007f);
      for (int index = 0; index < 8; index++)
        conversion_write(8'h18 + index * 4, 32'd65536);
      conversion_write(8'h08, 32'h0000_0003);

      processing_write(8'h10, generation);
      processing_write(8'h14, 32'd20);
      processing_write(8'h18, 32'd800);
      processing_write(8'h1c, 32'h0000_007f);
      processing_write(8'h40, 32'd5);
      processing_write(8'h6c, 32'h0001_320a);
      processing_write(8'h08, 32'h0000_0003);

      repeat (8) @(posedge clock);
      processing_read(8'h20, read_value);
      assert (read_value == generation)
        else $fatal(1, "aggregate-mode generation mismatch");
      processing_read(8'h70, read_value);
      assert (read_value == 32'h0001_320a)
        else $fatal(1, "aggregate-mode grid configuration mismatch");
    end
  endtask

  // Consume one MTR2 aggregate record and check every meaningful word.
  task automatic consume_mtr2_record(input integer expected_sequence,
                                     input integer expected_generation,
                                     input logic [31:0] expected_samples,
                                     input logic [31:0] expected_first_basic,
                                     input logic [31:0] expected_last_basic,
                                     input logic [31:0] expected_shape,
                                     input logic [31:0] expected_first_lo);
    integer word_index;
    begin
      @(negedge clock);
      meter_tready = 1'b1;
      word_index = 0;
      while (word_index < 64) begin
        @(posedge clock);
        if (meter_tvalid && meter_tready) begin
          assert (meter_tkeep == 4'hf) else $fatal(1, "MTR2 bad TKEEP");
          assert (meter_tlast == (word_index == 63))
            else $fatal(1, "MTR2 TLAST at word %0d", word_index);
          case (word_index)
            0: assert (meter_tdata == 32'h3152_544d) else $fatal(1, "MTR2 magic");
            1: assert (meter_tdata == 32'h0002_0001) else $fatal(1, "MTR2 format");
            2: assert (meter_tdata == 32'd256) else $fatal(1, "MTR2 length");
            3: assert (meter_tdata == expected_sequence) else $fatal(1, "MTR2 sequence");
            4: assert (meter_tdata == expected_generation) else $fatal(1, "MTR2 generation");
            5: assert (meter_tdata == 32'd20) else $fatal(1, "MTR2 sample rate");
            6: assert (meter_tdata == expected_samples)
              else $fatal(1, "MTR2 samples %0d != %0d", meter_tdata, expected_samples);
            7: assert (meter_tdata == 32'h7f) else $fatal(1, "MTR2 mask");
            // complete=1, frequency invalid (no DRDY baseline in sim),
            // no arithmetic error.
            8: assert (meter_tdata == 32'h0000_0002)
              else $fatal(1, "MTR2 status %08h", meter_tdata);
            9: assert (meter_tdata == expected_first_basic)
              else $fatal(1, "MTR2 first basic");
            10: assert (meter_tdata == expected_last_basic)
              else $fatal(1, "MTR2 last basic");
            11: assert (meter_tdata == expected_shape)
              else $fatal(1, "MTR2 shape %08h != %08h", meter_tdata, expected_shape);
            12: assert (meter_tdata == expected_first_lo)
              else $fatal(1, "MTR2 first sample %0d", meter_tdata);
            13: assert (meter_tdata == 0) else $fatal(1, "MTR2 first sample high");
            // Uniform blocks: the aggregate equals the per-block RMS in
            // micro-units (zero-referenced, no DC removal).
            16: assert (meter_tdata == 32'd22) else $fatal(1, "MTR2 CH0: %0d", meter_tdata);
            17: assert (meter_tdata == 0) else $fatal(1, "MTR2 CH0 high");
            18: assert (meter_tdata == 32'd20) else $fatal(1, "MTR2 CH1: %0d", meter_tdata);
            20: assert (meter_tdata == 32'd8) else $fatal(1, "MTR2 CH2: %0d", meter_tdata);
            22: assert (meter_tdata == 32'd5) else $fatal(1, "MTR2 CH3: %0d", meter_tdata);
            24: assert (meter_tdata == 32'd10) else $fatal(1, "MTR2 CH4: %0d", meter_tdata);
            26: assert (meter_tdata == 32'd20) else $fatal(1, "MTR2 CH5: %0d", meter_tdata);
            28: assert (meter_tdata == 32'd10) else $fatal(1, "MTR2 CH6: %0d", meter_tdata);
            30: assert (meter_tdata == 0) else $fatal(1, "MTR2 CH7 must be zero");
            32: assert (meter_tdata == 0) else $fatal(1, "MTR2 frequency must be invalid");
            62: assert (meter_tdata == 0) else $fatal(1, "MTR2 word 62 reserved");
            63: assert (meter_tdata == 0) else $fatal(1, "MTR2 word 63 reserved");
            default: ;
          endcase
          word_index = word_index + 1;
        end
      end
      @(negedge clock);
      meter_tready = 1'b0;
    end
  endtask

  task automatic configure_meter_cycle(input logic [31:0] generation);
    begin
      conversion_write(8'h10, generation);
      conversion_write(8'h14, 32'h0000_007f);
      for (int index = 0; index < 8; index++)
        conversion_write(8'h18 + index * 4, 32'd65536);
      conversion_write(8'h08, 32'h0000_0003);

      processing_write(8'h10, generation);
      processing_write(8'h14, 32'd20);
      processing_write(8'h18, 32'd120);
      processing_write(8'h1c, 32'h0000_007f);
      processing_write(8'h40, 32'd5);
      processing_write(8'h6c, 32'h0001_3202);
      processing_write(8'h08, 32'h0000_0003);

      repeat (8) @(posedge clock);
      processing_read(8'h20, read_value);
      assert (read_value == generation)
        else $fatal(1, "cycle-mode generation mismatch");
      processing_read(8'h70, read_value);
      assert (read_value == 32'h0001_3202)
        else $fatal(1, "grid active configuration mismatch");
    end
  endtask

  initial begin : watchdog
    #12_000_000;
    $fatal(1, "MeterCore integration test timed out");
  end

  initial begin
    repeat (8) @(posedge clock);
    resetn = 1'b1;

    configure_meter(32'd42, 1'b1);
    waveform_write(8'h08, 32'h0000_0001);
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

    // Cycle timing is enabled by default but CH6 never crosses zero with
    // the legacy pattern and the 1 V default hysteresis, so blocks close on
    // the free-run fallback: word 15 carries nominal 60 Hz, zero cycles,
    // and the fallback flag (plus first-block after each APPLY).
    consume_record(1, 42, 32'h0006_003c, 32'd1, 10, 2, 4, 5, 3, 4, 5);
    consume_record(2, 42, 32'h0002_003c, 32'd5, 10, 2, 4, 5, 3, 4, 5);

    configure_meter(32'd43, 1'b0);
    for (int frame = 8; frame < 12; frame++)
      send_frame(frame);
    consume_record(3, 43, 32'h0006_003c, 32'd9, 22, 20, 8, 5, 10, 20, 8);

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
    waveform_read(8'h28, read_value);
    assert (read_value == 12)
      else $fatal(1, "waveform frame sequence mismatch");
    waveform_read(8'h30, read_value);
    assert (read_value == 0)
      else $fatal(1, "waveform branch dropped frames before its FIFO filled");

    // ---- Cycle-mode scenario: 50 Hz nominal, 2 cycles per basic block ----
    // The grid waveform on CH6 has a 20-frame period, so each basic block
    // spans 40 frames. Startup is unlocked, so the first qualified crossing
    // (frame position 20, absolute sample 33) closes a 21-sample partial
    // block flagged fallback + first-block; the following blocks are
    // crossing-aligned, exactly 2 cycles / 40 samples each, and gapless:
    // first sample 13, then 34, then 74.
    configure_meter_cycle(32'd44);
    // Consume each record after its closing crossing so the packetizer's
    // two-deep latest-wins buffer never has to replace a pending record.
    for (int position = 0; position <= 20; position++)
      send_grid_frame(position);
    consume_timing_record(4, 44, 32'd21, 32'h0006_0032, 32'd13);
    for (int position = 21; position <= 60; position++)
      send_grid_frame(position);
    consume_timing_record(5, 44, 32'd40, 32'h0001_0232, 32'd34);
    for (int position = 61; position <= 100; position++)
      send_grid_frame(position);
    consume_timing_record(6, 44, 32'd40, 32'h0001_0232, 32'd74);

    repeat (20) @(posedge clock);
    capture_read(8'h10, read_value);
    assert (read_value == 113)
      else $fatal(1, "cycle-mode frame count mismatch: %0d", read_value);
    processing_read(8'h28, read_value);
    assert (read_value == 0) else $fatal(1, "cycle-mode RMS result drop");
    processing_read(8'h74, read_value);
    assert (read_value[0]) else $fatal(1, "grid timing not locked");
    waveform_read(8'h28, read_value);
    assert (read_value == 113)
      else $fatal(1, "waveform sample index low word mismatch");

    // ---- 150-cycle aggregation scenario: 50 Hz, real 10-cycle blocks ----
    // The relock block (9 samples, abs 114..122) is ineligible; the next 15
    // locked 80-sample blocks (r8..r22) form exactly one 150-cycle
    // aggregate: first sample 123, 1200 samples, uniform channel values so
    // the aggregate equals the per-block RMS.
    configure_meter_aggregate(32'd45);
    for (int position = 0; position <= 8; position++)
      send_grid_frame8(position);
    consume_timing_record(7, 45, 32'd9, 32'h0006_0032, 32'd114);
    for (int block = 0; block < 15; block++) begin
      for (int position = 9 + block * 80; position <= 88 + block * 80;
           position++)
        send_grid_frame8(position);
      consume_timing_record(8 + block, 45, 32'd80, 32'h0001_0a32,
                            32'd123 + block * 80);
    end
    consume_mtr2_record(1, 45, 32'd1200, 32'd8, 32'd22,
                        32'h0096_320f, 32'd123);

    repeat (20) @(posedge clock);
    capture_read(8'h10, read_value);
    assert (read_value == 1322)
      else $fatal(1, "aggregate scenario frame count: %0d", read_value);
    // AGG_RECORD_COUNT updates at the engine's emit and the MTR2 record
    // follows through the producer/packetizer; poll rather than assume
    // any ordering between record consumption and the register.
    begin : wait_aggregate_record_count
      int guard = 0;
      processing_read(8'h7c, read_value);
      while (read_value != 1 && guard < 50) begin
        repeat (100) @(posedge clock);
        processing_read(8'h7c, read_value);
        guard += 1;
      end
    end
    assert (read_value == 1) else $fatal(1, "aggregate record count");
    processing_read(8'h84, read_value);
    assert (read_value == 7)
      else $fatal(1, "aggregate ineligible count: %0d", read_value);
    processing_read(8'h80, read_value);
    assert (read_value == 0) else $fatal(1, "unexpected aggregate resets");
    processing_read(8'h88, read_value);
    assert (read_value == 0) else $fatal(1, "unexpected continuity errors");
    processing_read(8'h8c, read_value);
    assert (read_value == 0) else $fatal(1, "unexpected aggregate drops");
    processing_read(8'h28, read_value);
    assert (read_value == 0) else $fatal(1, "RMS result drop in aggregation");
    processing_read(8'h2c, read_value);
    assert (read_value == 0) else $fatal(1, "packetizer drop in aggregation");

    $display("PASS: meter_core_tb");
    $finish;
  end
endmodule
