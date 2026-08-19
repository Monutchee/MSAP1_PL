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

  logic [11:0] sim_awaddr = '0;
  logic sim_awvalid = 1'b0;
  wire sim_awready;
  logic [31:0] sim_wdata = '0;
  logic [3:0] sim_wstrb = 4'hf;
  logic sim_wvalid = 1'b0;
  wire sim_wready;
  wire [1:0] sim_bresp;
  wire sim_bvalid;
  logic sim_bready = 1'b1;
  logic [11:0] sim_araddr = '0;
  logic sim_arvalid = 1'b0;
  wire sim_arready;
  wire [31:0] sim_rdata;
  wire [1:0] sim_rresp;
  wire sim_rvalid;
  logic sim_rready = 1'b1;

  // The HLS engines emit records directly on separate producer streams:
  // MTR1 basic records on mtr1_*, MTR2 aggregate records on mtr2_*.
  wire [31:0] mtr1_tdata;
  wire [3:0] mtr1_tkeep;
  wire mtr1_tvalid;
  logic mtr1_tready = 1'b0;
  wire mtr1_tlast;

  wire [31:0] mtr2_tdata;
  wire [3:0] mtr2_tkeep;
  wire mtr2_tvalid;
  logic mtr2_tready = 1'b0;
  wire mtr2_tlast;

  // Single-cycle diagnostic stream: drained continuously; a passive
  // monitor checks framing and format, and the final block requires at
  // least one complete SCYC record (the MTR2 scenario spans 180 cycles).
  wire [31:0] scyc_tdata;
  wire [3:0] scyc_tkeep;
  wire scyc_tvalid;
  wire scyc_tlast;
  int scyc_beats = 0;
  int scyc_records = 0;

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
    .m_axis_mtr1_tdata(mtr1_tdata),
    .m_axis_mtr1_tkeep(mtr1_tkeep),
    .m_axis_mtr1_tvalid(mtr1_tvalid),
    .m_axis_mtr1_tready(mtr1_tready),
    .m_axis_mtr1_tlast(mtr1_tlast),
    .m_axis_mtr2_tdata(mtr2_tdata),
    .m_axis_mtr2_tkeep(mtr2_tkeep),
    .m_axis_mtr2_tvalid(mtr2_tvalid),
    .m_axis_mtr2_tready(mtr2_tready),
    .m_axis_mtr2_tlast(mtr2_tlast),
    .m_axis_scyc_tdata(scyc_tdata),
    .m_axis_scyc_tkeep(scyc_tkeep),
    .m_axis_scyc_tvalid(scyc_tvalid),
    .m_axis_scyc_tready(1'b1),
    .m_axis_scyc_tlast(scyc_tlast),
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
      processing_write(8'h18, 32'd192);
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
                                  input logic [31:0] expected_count,
                                  input logic [31:0] expected_status,
                                  input logic [31:0] expected_timing,
                                  input logic [31:0] expected_first_sample,
                                  input logic [31:0] expected_last_sample,
                                  input integer rms0,
                                  input integer rms1,
                                  input integer rms2,
                                  input integer rms3,
                                  input integer rms4,
                                  input integer rms5,
                                  input integer rms6);
    begin
      case (word_index)
        0: assert (mtr1_tdata == 32'h3152_544d) else $fatal(1, "bad MTR1 magic");
        1: assert (mtr1_tdata == 32'h0001_0004) else $fatal(1, "bad record format");
        2: assert (mtr1_tdata == 32'd256) else $fatal(1, "bad record length");
        3: assert (mtr1_tdata == expected_sequence) else $fatal(1, "bad result sequence");
        4: assert (mtr1_tdata == expected_generation) else $fatal(1, "bad generation");
        5: assert (mtr1_tdata == 32'd20) else $fatal(1, "bad sample rate");
        6: assert (mtr1_tdata == expected_count)
          else $fatal(1, "bad block sample count: got %0d expected %0d",
                      mtr1_tdata, expected_count);
        7: assert (mtr1_tdata[7:0] == 8'h7f) else $fatal(1, "bad valid mask");
        8: assert (mtr1_tdata == expected_status)
          else $fatal(1, "bad status %08h, expected %08h", mtr1_tdata,
                      expected_status);
        9: assert (mtr1_tdata == expected_first_sample)
          else $fatal(1, "bad first sample %0d, expected %0d",
                      mtr1_tdata, expected_first_sample);
        10: assert (mtr1_tdata == 0) else $fatal(1, "bad first sample high");
        11: assert (mtr1_tdata == 0) else $fatal(1, "emit drops are non-zero");
        12: assert (mtr1_tdata == 0) else $fatal(1, "result drops are non-zero");
        13: assert (mtr1_tdata == expected_timing)
          else $fatal(1, "bad timing word %08h, expected %08h",
                      mtr1_tdata, expected_timing);
        14: assert (mtr1_tdata == expected_last_sample)
          else $fatal(1, "bad last sample %0d, expected %0d",
                      mtr1_tdata, expected_last_sample);
        15: assert (mtr1_tdata == 0) else $fatal(1, "bad last sample high");
        16: assert ($signed(mtr1_tdata) == 20) else $fatal(1, "CH0 mean mismatch");
        17: assert (mtr1_tdata == 0) else $fatal(1, "CH0 mean high mismatch");
        18: assert (mtr1_tdata == rms0) else $fatal(1, "CH0 raw RMS mismatch");
        19: assert ($signed(mtr1_tdata) == rms0) else $fatal(1, "CH0 RMS mismatch");
        20: assert (mtr1_tdata == 0) else $fatal(1, "CH0 RMS high mismatch");
        21: assert ($signed(mtr1_tdata) == 20) else $fatal(1, "CH1 mean mismatch");
        22: assert (mtr1_tdata == 0) else $fatal(1, "CH1 mean high mismatch");
        23: assert (mtr1_tdata == rms1) else $fatal(1, "CH1 raw RMS mismatch");
        24: assert ($signed(mtr1_tdata) == rms1) else $fatal(1, "CH1 RMS mismatch");
        25: assert (mtr1_tdata == 0) else $fatal(1, "CH1 RMS high mismatch");
        26: assert ($signed(mtr1_tdata) == -8) else $fatal(1, "CH2 mean mismatch");
        27: assert (mtr1_tdata == 32'hffff_ffff) else $fatal(1, "CH2 mean high mismatch");
        28: assert (mtr1_tdata == rms2) else $fatal(1, "CH2 raw RMS mismatch");
        29: assert ($signed(mtr1_tdata) == rms2) else $fatal(1, "CH2 RMS mismatch");
        30: assert (mtr1_tdata == 0) else $fatal(1, "CH2 RMS high mismatch");
        31: assert ($signed(mtr1_tdata) == 0) else $fatal(1, "CH3 mean mismatch");
        32: assert (mtr1_tdata == 0) else $fatal(1, "CH3 mean high mismatch");
        33: assert (mtr1_tdata == rms3) else $fatal(1, "CH3 raw RMS mismatch");
        34: assert ($signed(mtr1_tdata) == rms3) else $fatal(1, "CH3 RMS mismatch");
        35: assert (mtr1_tdata == 0) else $fatal(1, "CH3 RMS high mismatch");
        36: assert ($signed(mtr1_tdata) == 10) else $fatal(1, "CH4 mean mismatch");
        37: assert (mtr1_tdata == 0) else $fatal(1, "CH4 mean high mismatch");
        38: assert (mtr1_tdata == rms4) else $fatal(1, "CH4 raw RMS mismatch: %0d", mtr1_tdata);
        39: assert ($signed(mtr1_tdata) == rms4) else $fatal(1, "CH4 RMS mismatch: %0d", $signed(mtr1_tdata));
        40: assert (mtr1_tdata == 0) else $fatal(1, "CH4 RMS high mismatch");
        41: assert ($signed(mtr1_tdata) == 20) else $fatal(1, "CH5 mean mismatch");
        42: assert (mtr1_tdata == 0) else $fatal(1, "CH5 mean high mismatch");
        43: assert (mtr1_tdata == rms5) else $fatal(1, "CH5 raw RMS mismatch: %0d", mtr1_tdata);
        44: assert ($signed(mtr1_tdata) == rms5) else $fatal(1, "CH5 RMS mismatch: %0d", $signed(mtr1_tdata));
        45: assert (mtr1_tdata == 0) else $fatal(1, "CH5 RMS high mismatch");
        46: assert ($signed(mtr1_tdata) == -7) else $fatal(1, "CH6 mean mismatch");
        47: assert (mtr1_tdata == 32'hffff_ffff) else $fatal(1, "CH6 mean high mismatch");
        48: assert (mtr1_tdata == rms6) else $fatal(1, "CH6 raw RMS mismatch: %0d", mtr1_tdata);
        49: assert ($signed(mtr1_tdata) == rms6) else $fatal(1, "CH6 RMS mismatch: %0d", $signed(mtr1_tdata));
        50: assert (mtr1_tdata == 0) else $fatal(1, "CH6 RMS high mismatch");
        // Word 60 is the capture frame count at block close; it varies per
        // scenario and is left unchecked here.
        61: assert (mtr1_tdata == 0) else $fatal(1, "header errors are non-zero");
        62: assert (mtr1_tdata == 0) else $fatal(1, "FIFO overflows are non-zero");
        63: assert (mtr1_tdata == 0) else $fatal(1, "ADC alerts are non-zero");
        default: ;
      endcase
    end
  endtask

  // Every BASIC-v4 record is followed on the same stream by its POWER-v1
  // companion (same sequence). Word-exact power content is pinned by the
  // HLS bench and the record-stream bench; here the framing, format, and
  // shared envelope are verified and the record is drained so the stream
  // stays aligned for the next block.
  task automatic drain_power_record(input integer expected_sequence);
    integer word_index;
    begin
      @(negedge clock);
      mtr1_tready = 1'b1;
      word_index = 0;
      while (word_index < 64) begin
        @(posedge clock);
        if (mtr1_tvalid && mtr1_tready) begin
          assert (mtr1_tkeep == 4'hf) else $fatal(1, "bad POWER TKEEP");
          assert (mtr1_tlast == (word_index == 63))
            else $fatal(1, "POWER TLAST at word %0d", word_index);
          case (word_index)
            0: assert (mtr1_tdata == 32'h3152_544d)
              else $fatal(1, "bad POWER magic");
            1: assert (mtr1_tdata == 32'h0007_0001)
              else $fatal(1, "bad POWER format: %08h", mtr1_tdata);
            3: assert (mtr1_tdata == expected_sequence)
              else $fatal(1, "POWER sequence %0d, expected %0d",
                          mtr1_tdata, expected_sequence);
            default: ;
          endcase
          word_index = word_index + 1;
        end
      end
      @(negedge clock);
      mtr1_tready = 1'b0;
    end
  endtask

  // ... and the POWER record by its PHASOR-v1 companion (M9), the third
  // record of the block triple. Same drain contract as above: framing,
  // format, and sequence pinned here; value words pinned by the HLS
  // bench and the record-stream bench.
  task automatic drain_phasor_record(input integer expected_sequence);
    integer word_index;
    begin
      @(negedge clock);
      mtr1_tready = 1'b1;
      word_index = 0;
      while (word_index < 64) begin
        @(posedge clock);
        if (mtr1_tvalid && mtr1_tready) begin
          assert (mtr1_tkeep == 4'hf) else $fatal(1, "bad PHASOR TKEEP");
          assert (mtr1_tlast == (word_index == 63))
            else $fatal(1, "PHASOR TLAST at word %0d", word_index);
          case (word_index)
            0: assert (mtr1_tdata == 32'h3152_544d)
              else $fatal(1, "bad PHASOR magic");
            1: assert (mtr1_tdata == 32'h0008_0001)
              else $fatal(1, "bad PHASOR format: %08h", mtr1_tdata);
            3: assert (mtr1_tdata == expected_sequence)
              else $fatal(1, "PHASOR sequence %0d, expected %0d",
                          mtr1_tdata, expected_sequence);
            default: ;
          endcase
          word_index = word_index + 1;
        end
      end
      @(negedge clock);
      mtr1_tready = 1'b0;
    end
  endtask

  // ... and the UNBALANCE-v1 record (M10), fourth of the block quad.
  task automatic drain_unbalance_record(input integer expected_sequence);
    integer word_index;
    begin
      @(negedge clock);
      mtr1_tready = 1'b1;
      word_index = 0;
      while (word_index < 64) begin
        @(posedge clock);
        if (mtr1_tvalid && mtr1_tready) begin
          assert (mtr1_tkeep == 4'hf) else $fatal(1, "bad UNBAL TKEEP");
          assert (mtr1_tlast == (word_index == 63))
            else $fatal(1, "UNBAL TLAST at word %0d", word_index);
          case (word_index)
            0: assert (mtr1_tdata == 32'h3152_544d)
              else $fatal(1, "bad UNBAL magic");
            1: assert (mtr1_tdata == 32'h0009_0001)
              else $fatal(1, "bad UNBAL format: %08h", mtr1_tdata);
            3: assert (mtr1_tdata == expected_sequence)
              else $fatal(1, "UNBAL sequence %0d, expected %0d",
                          mtr1_tdata, expected_sequence);
            default: ;
          endcase
          word_index = word_index + 1;
        end
      end
      @(negedge clock);
      mtr1_tready = 1'b0;
    end
  endtask

  task automatic consume_record(input integer expected_sequence,
                                input integer expected_generation,
                                input logic [31:0] expected_count,
                                input logic [31:0] expected_status,
                                input logic [31:0] expected_timing,
                                input logic [31:0] expected_first_sample,
                                input logic [31:0] expected_last_sample,
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
      mtr1_tready = 1'b1;
      word_index = 0;
      while (word_index < 64) begin
        @(posedge clock);
        if (mtr1_tvalid && mtr1_tready) begin
          assert (mtr1_tkeep == 4'hf) else $fatal(1, "bad MTR1 TKEEP");
          assert (mtr1_tlast == (word_index == 63))
            else $fatal(1, "MTR1 TLAST at word %0d", word_index);
          check_meter_word(word_index, expected_sequence, expected_generation,
                           expected_count, expected_status,
                           expected_timing, expected_first_sample,
                           expected_last_sample,
                           rms0, rms1, rms2, rms3,
                           rms4, rms5, rms6);
          word_index = word_index + 1;
        end
      end
      @(negedge clock);
      mtr1_tready = 1'b0;
      drain_power_record(expected_sequence);
      drain_phasor_record(expected_sequence);
      drain_unbalance_record(expected_sequence);
    end
  endtask

  // Consume one record checking only the header and basic-block timing
  // words. Used by the cycle-mode scenario, whose channel values follow the
  // grid waveform rather than the fixed legacy pattern.
  task automatic consume_timing_record(input integer expected_sequence,
                                       input integer expected_generation,
                                       input logic [31:0] expected_count,
                                       input logic [31:0] expected_status,
                                       input logic [31:0] expected_timing,
                                       input logic [31:0] expected_first_sample);
    integer word_index;
    begin
      @(negedge clock);
      mtr1_tready = 1'b1;
      word_index = 0;
      while (word_index < 64) begin
        @(posedge clock);
        if (mtr1_tvalid && mtr1_tready) begin
          assert (mtr1_tkeep == 4'hf) else $fatal(1, "bad MTR1 TKEEP");
          assert (mtr1_tlast == (word_index == 63))
            else $fatal(1, "MTR1 TLAST at word %0d", word_index);
          case (word_index)
            0: assert (mtr1_tdata == 32'h3152_544d) else $fatal(1, "bad MTR1 magic");
            1: assert (mtr1_tdata == 32'h0001_0004) else $fatal(1, "bad record format");
            2: assert (mtr1_tdata == 32'd256) else $fatal(1, "bad record length");
            3: assert (mtr1_tdata == expected_sequence) else $fatal(1, "bad result sequence");
            4: assert (mtr1_tdata == expected_generation) else $fatal(1, "bad generation");
            8: assert (mtr1_tdata == expected_status)
              else $fatal(1, "bad status %08h, expected %08h", mtr1_tdata,
                          expected_status);
            6: assert (mtr1_tdata == expected_count)
              else $fatal(1, "bad block sample count %0d, expected %0d",
                          mtr1_tdata, expected_count);
            9: assert (mtr1_tdata == expected_first_sample)
              else $fatal(1, "bad first sample %0d, expected %0d",
                          mtr1_tdata, expected_first_sample);
            10: assert (mtr1_tdata == 0) else $fatal(1, "bad first sample high");
            13: assert (mtr1_tdata == expected_timing)
              else $fatal(1, "bad timing word %08h, expected %08h",
                          mtr1_tdata, expected_timing);
            default: ;
          endcase
          word_index = word_index + 1;
        end
      end
      @(negedge clock);
      mtr1_tready = 1'b0;
      drain_power_record(expected_sequence);
      drain_phasor_record(expected_sequence);
      drain_unbalance_record(expected_sequence);
    end
  endtask

  // Configure a cycle-mode generation: 50 Hz nominal with 2 cycles per
  // block (kept small for simulation), hysteresis below the +/-10 grid
  // amplitude so crossings qualify, and a fallback window that neither
  // expires before the first crossing nor unlocks between 20-frame cycles.
  // Frame with a 16-frame-period grid waveform on CH6 (eight +10
  // samples, eight -10). Used by the aggregation scenario: one block =
  // 160 frames, short enough to simulate while every cycle still spans
  // >= ~5k clocks (the per-cycle finalize pacing contract).
  task automatic send_grid_frame16(input integer cycle_position);
    logic [7:0] header;
    logic signed [23:0] grid_sample;
    begin
      build_frame(cycle_position);
      grid_sample = (cycle_position % 16) < 8 ? 24'sd10 : -24'sd10;
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

  // Consume one MTR2 aggregate record from the MTR2 stream and check every
  // meaningful word.
  task automatic consume_mtr2_record(input integer expected_sequence,
                                     input integer expected_generation,
                                     input logic [31:0] expected_samples,
                                     input logic [31:0] expected_first_basic,
                                     input logic [31:0] expected_last_basic,
                                     input logic [31:0] expected_shape,
                                     input logic [31:0] expected_first_lo,
                                     input logic [31:0] expected_ineligible);
    integer word_index;
    begin
      @(negedge clock);
      mtr2_tready = 1'b1;
      word_index = 0;
      while (word_index < 64) begin
        @(posedge clock);
        if (mtr2_tvalid && mtr2_tready) begin
          assert (mtr2_tkeep == 4'hf) else $fatal(1, "MTR2 bad TKEEP");
          assert (mtr2_tlast == (word_index == 63))
            else $fatal(1, "MTR2 TLAST at word %0d", word_index);
          case (word_index)
            0: assert (mtr2_tdata == 32'h3152_544d) else $fatal(1, "MTR2 magic");
            1: assert (mtr2_tdata == 32'h0002_0002) else $fatal(1, "MTR2 format");
            2: assert (mtr2_tdata == 32'd256) else $fatal(1, "MTR2 length");
            3: assert (mtr2_tdata == expected_sequence) else $fatal(1, "MTR2 sequence");
            4: assert (mtr2_tdata == expected_generation) else $fatal(1, "MTR2 generation");
            5: assert (mtr2_tdata == 32'd20) else $fatal(1, "MTR2 sample rate");
            6: assert (mtr2_tdata == expected_samples)
              else $fatal(1, "MTR2 samples %0d != %0d", mtr2_tdata, expected_samples);
            7: assert (mtr2_tdata == 32'h7f) else $fatal(1, "MTR2 mask");
            // complete=1, frequency invalid (no DRDY baseline in sim),
            // no arithmetic error.
            8: assert (mtr2_tdata == 32'h0000_0002)
              else $fatal(1, "MTR2 status %08h", mtr2_tdata);
            9: assert (mtr2_tdata == expected_first_lo)
              else $fatal(1, "MTR2 first sample %0d", mtr2_tdata);
            10: assert (mtr2_tdata == 0) else $fatal(1, "MTR2 first sample high");
            11: assert (mtr2_tdata == 0) else $fatal(1, "MTR2 emit drops");
            12: assert (mtr2_tdata == 0) else $fatal(1, "MTR2 result drops");
            13: assert (mtr2_tdata == expected_shape)
              else $fatal(1, "MTR2 shape %08h != %08h", mtr2_tdata, expected_shape);
            14: assert (mtr2_tdata == expected_first_basic)
              else $fatal(1, "MTR2 first basic");
            15: assert (mtr2_tdata == expected_last_basic)
              else $fatal(1, "MTR2 last basic");
            // Uniform blocks: the aggregate equals the per-block RMS in
            // micro-units (zero-referenced, no DC removal).
            16: assert (mtr2_tdata == 32'd22) else $fatal(1, "MTR2 CH0: %0d", mtr2_tdata);
            17: assert (mtr2_tdata == 0) else $fatal(1, "MTR2 CH0 high");
            18: assert (mtr2_tdata == 32'd20) else $fatal(1, "MTR2 CH1: %0d", mtr2_tdata);
            20: assert (mtr2_tdata == 32'd8) else $fatal(1, "MTR2 CH2: %0d", mtr2_tdata);
            22: assert (mtr2_tdata == 32'd5) else $fatal(1, "MTR2 CH3: %0d", mtr2_tdata);
            24: assert (mtr2_tdata == 32'd10) else $fatal(1, "MTR2 CH4: %0d", mtr2_tdata);
            26: assert (mtr2_tdata == 32'd20) else $fatal(1, "MTR2 CH5: %0d", mtr2_tdata);
            28: assert (mtr2_tdata == 32'd10) else $fatal(1, "MTR2 CH6: %0d", mtr2_tdata);
            30: assert (mtr2_tdata == 0) else $fatal(1, "MTR2 CH7 must be zero");
            32: assert (mtr2_tdata == 0) else $fatal(1, "MTR2 frequency must be invalid");
            // Engine diagnostics ride in the record: no resets or continuity
            // errors in a clean run; ineligible blocks are scenario-driven.
            // One reset: the cycle-mode scenario's eligible second block
            // opened an aggregate that the aggregation APPLY discarded.
            33: assert (mtr2_tdata == 1) else $fatal(1, "MTR2 reset count");
            34: assert (mtr2_tdata == expected_ineligible)
              else $fatal(1, "MTR2 ineligible count %0d != %0d",
                          mtr2_tdata, expected_ineligible);
            35: assert (mtr2_tdata == 0) else $fatal(1, "MTR2 continuity count");
            62: assert (mtr2_tdata == 0) else $fatal(1, "MTR2 word 62 reserved");
            63: assert (mtr2_tdata == 0) else $fatal(1, "MTR2 word 63 reserved");
            default: ;
          endcase
          word_index = word_index + 1;
        end
      end
      @(negedge clock);
      mtr2_tready = 1'b0;
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
    #60_000_000;
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

    // The merge chain needs 12 whole cycles (60 Hz nominal) per basic
    // record. With window=192 and the default grid config (12 cycles) the
    // synthetic fallback cadence fires a cycle boundary every 16 frames
    // (>= ~5k clocks per cycle: the pacing contract the per-cycle
    // finalize needs at this bench's compressed frame rate); the
    // single-cycle tier discards up to the first boundary (sample 16),
    // so the first block spans 12 x 16 samples, 17..208.
    for (int frame = 0; frame < 208; frame++)
      send_frame(frame);

    $display("TB: scenario A frames sent, awaiting record 1");
    fork : record1_watch
      begin
        wait (mtr1_tvalid);
      end
      begin
        // Bounded diagnostic: if the record does not appear, dump the
        // fabric's own view before the watchdog kills the run.
        repeat (60000) @(posedge clock);
        capture_read(8'h10, read_value);
        $display("TB-DIAG capture frames: %0d", read_value);
        processing_read(8'h74, read_value);
        $display("TB-DIAG grid status: %08h", read_value);
        processing_read(8'h98, read_value);
        $display("TB-DIAG scyc shim drops: %0d", read_value);
        processing_read(8'h28, read_value);
        $display("TB-DIAG result drops: %0d", read_value);
        processing_read(8'h0c, read_value);
        $display("TB-DIAG processing status: %08h", read_value);
        wait (mtr1_tvalid);
      end
    join_any
    disable record1_watch;
    stalled_word = mtr1_tdata;
    stalled_last = mtr1_tlast;
    repeat (12) begin
      @(posedge clock);
      assert (mtr1_tvalid && mtr1_tdata == stalled_word &&
              mtr1_tlast == stalled_last)
        else $fatal(1, "MTR1 output changed under DMA backpressure");
    end

    // Capture continues while the first DMA record is stalled (the
    // single-cycle shim FIFO absorbs the backpressured chain).
    for (int frame = 208; frame < 212; frame++)
      send_frame(frame);
    repeat (20) @(posedge clock);
    capture_read(8'h10, read_value);
    assert (read_value == 212)
      else $fatal(1, "capture stalled behind meter DMA: %0d frames", read_value);

    // CH6 never crosses zero with the legacy pattern and the 1 V default
    // hysteresis, so the chain runs on synthetic fallback cycles: word 13
    // carries nominal 60 Hz, 12 cycles, and the fallback flag (plus
    // first-block after each APPLY); status bit 2 marks the first block.
    $display("TB: consuming record 1");
    consume_record(1, 42, 32'd192, 32'h4, 32'h0006_0c3c, 32'd17, 32'd208,
                   10, 2, 4, 5, 3, 4, 5);
    for (int frame = 212; frame < 400; frame++)
      send_frame(frame);
    $display("TB: consuming record 2");
    consume_record(2, 42, 32'd192, 32'h0, 32'h0002_0c3c, 32'd209, 32'd400,
                   10, 2, 4, 5, 3, 4, 5);

    configure_meter(32'd43, 1'b0);
    for (int frame = 400; frame < 608; frame++)
      send_frame(frame);
    $display("TB: consuming record 3");
    consume_record(3, 43, 32'd192, 32'h4, 32'h0006_0c3c, 32'd417, 32'd608,
                   22, 20, 8, 5, 10, 20, 8);

    repeat (20) @(posedge clock);
    capture_read(8'h10, read_value);
    assert (read_value == 608) else $fatal(1, "final frame count mismatch");
    capture_read(8'h14, read_value);
    assert (read_value == 0) else $fatal(1, "unexpected FIFO overflow");
    capture_read(8'h18, read_value);
    assert (read_value == 0) else $fatal(1, "unexpected header error");
    capture_read(8'h1c, read_value);
    assert (read_value == 0) else $fatal(1, "unexpected ADC alert");
    processing_read(8'h28, read_value);
    assert (read_value == 0) else $fatal(1, "unexpected RMS result drop");
    processing_read(8'h2c, read_value);
    assert (read_value == 0) else $fatal(1, "unexpected emit drop");
    waveform_read(8'h28, read_value);
    assert (read_value == 608)
      else $fatal(1, "waveform frame sequence mismatch");
    // The waveform branch's ring is far shorter than this scenario's 608
    // frames, so overflow drops are expected here; its no-early-drop
    // property is pinned by the waveform branch's own bench.

    // ---- Cycle-mode scenario: 50 Hz nominal, real 10-cycle blocks -------
    // The grid waveform on CH6 has a 20-frame period. Startup is unlocked:
    // synthetic boundaries run every 12 samples (window 120 / 10 cycles)
    // until the first qualified crossing (position 20, absolute sample
    // 629) relocks cycle counting. The single-cycle tier discards up to
    // the first boundary (sample 620). The relock-seam cycle (621..629)
    // still carries the PREVIOUS nominal — the grid publishes the closed
    // block's nominal one block late by design — so the merge tier
    // discards it on the nominal change (no result may mix nominals) and
    // block 1 is the ten crossing-aligned cycles 630..829, marked
    // first-after-gap; block 2 is 830..1029, clean and gapless.
    configure_meter_cycle(32'd44);
    for (int position = 0; position <= 220; position++)
      send_grid_frame(position);
    $display("TB: consuming record 4");
    fork : record4_watch
      begin
        wait (mtr1_tvalid);
      end
      begin
        repeat (100000) @(posedge clock);
        $display("TB-DIAG4 scyc records so far: %0d", scyc_records);
        capture_read(8'h10, read_value);
        $display("TB-DIAG4 capture frames: %0d", read_value);
        processing_read(8'h74, read_value);
        $display("TB-DIAG4 grid status: %08h", read_value);
        processing_read(8'h98, read_value);
        $display("TB-DIAG4 scyc shim drops: %0d", read_value);
        wait (mtr1_tvalid);
      end
    join_any
    disable record4_watch;
    consume_timing_record(4, 44, 32'd200, 32'h4, 32'h0005_0a32, 32'd630);
    for (int position = 221; position <= 420; position++)
      send_grid_frame(position);
    $display("TB: consuming record 5");
    consume_timing_record(5, 44, 32'd200, 32'h0, 32'h0001_0a32, 32'd830);

    repeat (20) @(posedge clock);
    capture_read(8'h10, read_value);
    assert (read_value == 1029)
      else $fatal(1, "cycle-mode frame count mismatch: %0d", read_value);
    processing_read(8'h28, read_value);
    assert (read_value == 0) else $fatal(1, "cycle-mode RMS result drop");
    processing_read(8'h74, read_value);
    assert (read_value[0]) else $fatal(1, "grid timing not locked");
    waveform_read(8'h28, read_value);
    assert (read_value == 1029)
      else $fatal(1, "waveform sample index low word mismatch");

    // ---- 150-cycle aggregation scenario: 50 Hz, real 10-cycle blocks ----
    // After the APPLY the single-cycle tier discards up to the relock
    // crossing (position 16, absolute sample 1046); the seam has no
    // nominal change this time (50 both sides), so block 6 (samples
    // 1047..1206) merges from the first whole cycle, carries the
    // first-block flag, and is ineligible; the next 15 locked 160-sample
    // blocks (r7..r21) form exactly one 150-cycle aggregate: first
    // sample 1207, 2400 samples, uniform channel values so the aggregate
    // equals the per-block RMS.
    configure_meter_aggregate(32'd45);
    for (int position = 0; position <= 176; position++)
      send_grid_frame16(position);
    $display("TB: consuming record 6");
    consume_timing_record(6, 45, 32'd160, 32'h4, 32'h0005_0a32, 32'd1047);
    for (int block = 0; block < 15; block++) begin
      for (int position = 177 + block * 160; position <= 336 + block * 160;
           position++)
        send_grid_frame16(position);
      $display("TB: consuming record %0d", 7 + block);
      consume_timing_record(7 + block, 45, 32'd160, 32'h0, 32'h0001_0a32,
                            32'd1207 + block * 160);
    end
    // Five earlier basic results were ineligible for aggregation (the
    // three fallback blocks of the first scenario, the relock-seam block
    // 4, and the first-flagged block 6); the cycle-mode block 5 was
    // eligible and its partial aggregate was discarded by the APPLY,
    // which the reset counter records.
    $display("TB: consuming MTR2");
    consume_mtr2_record(1, 45, 32'd2400, 32'd7, 32'd21,
                        32'h0096_320f, 32'd1207, 32'd5);

    repeat (20) @(posedge clock);
    capture_read(8'h10, read_value);
    assert (read_value == 3606)
      else $fatal(1, "aggregate scenario frame count: %0d", read_value);
    // AGG_RECORD_COUNT updates at the engine's emit; the record just
    // consumed was emitted directly on the MTR2 stream, so the counter
    // should already read 1 — poll defensively rather than assume the
    // exact update cycle.
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
    assert (read_value == 5)
      else $fatal(1, "aggregate ineligible count: %0d", read_value);
    processing_read(8'h80, read_value);
    assert (read_value == 1)
      else $fatal(1, "aggregate resets: %0d (the APPLY-discarded open aggregate)",
                  read_value);
    processing_read(8'h88, read_value);
    assert (read_value == 0) else $fatal(1, "unexpected continuity errors");
    processing_read(8'h8c, read_value);
    assert (read_value == 0) else $fatal(1, "unexpected aggregate drops");
    processing_read(8'h28, read_value);
    assert (read_value == 0) else $fatal(1, "RMS result drop in aggregation");
    processing_read(8'h2c, read_value);
    assert (read_value == 0) else $fatal(1, "emit drop in aggregation");

    $display("PASS: meter_core_tb");
    $finish;
  end

  // Passive SCYC monitor: 64-beat framing, magic and format on word 0/1.
  always @(posedge clock) begin
    if (scyc_tvalid) begin
      assert (scyc_tkeep == 4'hf) else $fatal(1, "SCYC TKEEP");
      if (scyc_beats == 0)
        assert (scyc_tdata == 32'h3152544d)
          else $fatal(1, "SCYC record magic mismatch: %08x", scyc_tdata);
      if (scyc_beats == 1)
        assert (scyc_tdata == 32'h000A0005)
          else $fatal(1, "SCYC record format mismatch: %08x", scyc_tdata);
      assert (scyc_tlast == (scyc_beats == 63))
        else $fatal(1, "SCYC TLAST misplaced at beat %0d", scyc_beats);
      if (scyc_beats == 63) begin
        scyc_beats <= 0;
        scyc_records <= scyc_records + 1;
        $display("TB: SCYC record %0d complete at %t",
                 scyc_records + 1, $time);
      end else begin
        scyc_beats <= scyc_beats + 1;
      end
    end
  end

  final begin
    assert (scyc_records > 0)
      else $fatal(1, "no single-cycle diagnostic record was produced");
  end

endmodule
