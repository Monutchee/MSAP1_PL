`timescale 1ns / 1ps

module ad7771_capture (
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 s_axi_aclk CLK" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME s_axi_aclk, ASSOCIATED_BUSIF S_AXI:M_AXIS, ASSOCIATED_RESET s_axi_aresetn" *)
    input  logic         s_axi_aclk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 s_axi_aresetn RST" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME s_axi_aresetn, POLARITY ACTIVE_LOW" *)
    input  logic         s_axi_aresetn,

    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWADDR" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME S_AXI, PROTOCOL AXI4LITE, DATA_WIDTH 32, ADDR_WIDTH 8, ID_WIDTH 0, AWUSER_WIDTH 0, ARUSER_WIDTH 0, WUSER_WIDTH 0, RUSER_WIDTH 0, BUSER_WIDTH 0, READ_WRITE_MODE READ_WRITE" *)
    input  logic [7:0]   s_axi_awaddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWVALID" *)
    input  logic         s_axi_awvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWREADY" *)
    output logic         s_axi_awready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WDATA" *)
    input  logic [31:0]  s_axi_wdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WSTRB" *)
    input  logic [3:0]   s_axi_wstrb,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WVALID" *)
    input  logic         s_axi_wvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WREADY" *)
    output logic         s_axi_wready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI BRESP" *)
    output logic [1:0]   s_axi_bresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI BVALID" *)
    output logic         s_axi_bvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI BREADY" *)
    input  logic         s_axi_bready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARADDR" *)
    input  logic [7:0]   s_axi_araddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARVALID" *)
    input  logic         s_axi_arvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARREADY" *)
    output logic         s_axi_arready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RDATA" *)
    output logic [31:0]  s_axi_rdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RRESP" *)
    output logic [1:0]   s_axi_rresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RVALID" *)
    output logic         s_axi_rvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RREADY" *)
    input  logic         s_axi_rready,

    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS TDATA" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME M_AXIS, TDATA_NUM_BYTES 4, TUSER_WIDTH 0, HAS_TREADY 1, HAS_TLAST 1, HAS_TKEEP 1" *)
    output logic [31:0]  m_axis_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS TKEEP" *)
    output logic [3:0]   m_axis_tkeep,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS TVALID" *)
    output logic         m_axis_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS TREADY" *)
    input  logic         m_axis_tready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS TLAST" *)
    output logic         m_axis_tlast,

    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 adc_dclk CLK" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME adc_dclk, FREQ_HZ 8192000" *)
    input  logic         adc_dclk,
    input  logic         adc_drdy_n,
    input  logic [3:0]   adc_dout,
    output logic         adc_reset_n,
    output logic         adc_start_n,
    output logic         adc_convst_sar
);

    logic capture_enable;
    logic capture_enable_dclk;
    logic fifo_reset;
    logic [15:0] packet_frames;

    logic [255:0] frame_data;
    logic frame_valid;
    logic receiver_busy_dclk;
    logic receiver_busy_axi;
    logic [31:0] frame_count_dclk;
    logic [31:0] overflow_count_dclk;
    logic [31:0] header_error_count_dclk;
    logic [31:0] alert_count_dclk;
    logic [31:0] frame_count_axi;
    logic [31:0] overflow_count_axi;
    logic [31:0] header_error_count_axi;
    logic [31:0] alert_count_axi;

    logic fifo_rst_axi;
    logic fifo_rst_dclk;
    logic fifo_full;
    logic fifo_full_axi;
    logic fifo_empty;
    logic fifo_overflow;
    logic fifo_underflow;
    logic fifo_wr_reset_busy;
    logic fifo_wr_reset_busy_axi;
    logic fifo_rd_reset_busy;
    logic fifo_read_enable;
    logic [31:0] fifo_data_out;
    logic adc_drdy_n_axi;

    logic [18:0] beat_in_packet;
    logic [18:0] beats_per_packet;
    logic [31:0] packet_count;

    assign beats_per_packet = (packet_frames == 16'b0) ? 19'd8 :
                              {packet_frames, 3'b000};

    // Register the combined request before the CDC synchronizer.  This avoids
    // combinational logic on a reset-domain crossing and is safe because the
    // AXI clock continues running while peripheral_aresetn is asserted.
    always_ff @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn)
            fifo_rst_axi <= 1'b1;
        else
            fifo_rst_axi <= fifo_reset;
    end

    xpm_cdc_single #(
        .DEST_SYNC_FF(2),
        .INIT_SYNC_FF(1),
        .SIM_ASSERT_CHK(1),
        .SRC_INPUT_REG(1)
    ) capture_enable_cdc (
        .src_clk(s_axi_aclk),
        .src_in(capture_enable),
        .dest_clk(adc_dclk),
        .dest_out(capture_enable_dclk)
    );

    // XPM_FIFO_ASYNC requires its common reset to be synchronous to wr_clk.
    // Synchronize both assertion and release into the ADC clock domain; the
    // FIFO then distributes reset safely to its read-clock side internally.
    xpm_cdc_sync_rst #(
        .DEST_SYNC_FF(4),
        .INIT(1),
        .INIT_SYNC_FF(1),
        .SIM_ASSERT_CHK(1)
    ) fifo_reset_cdc (
        .src_rst(fifo_rst_axi),
        .dest_clk(adc_dclk),
        .dest_rst(fifo_rst_dclk)
    );

    ad7771_receiver receiver (
        .adc_dclk(adc_dclk),
        .receiver_reset(fifo_wr_reset_busy),
        .capture_enable(capture_enable_dclk),
        .adc_drdy_n(adc_drdy_n),
        .adc_dout(adc_dout),
        .frame_sink_full(fifo_full),
        .frame_data(frame_data),
        .frame_valid(frame_valid),
        .receiver_busy(receiver_busy_dclk),
        .frame_count(frame_count_dclk),
        .overflow_count(overflow_count_dclk),
        .header_error_count(header_error_count_dclk),
        .alert_count(alert_count_dclk)
    );

    xpm_fifo_async #(
        .CDC_SYNC_STAGES(2),
        .DOUT_RESET_VALUE("0"),
        .ECC_MODE("no_ecc"),
        // One FIFO entry is one simultaneous eight-channel conversion.
        // 512 frames provide 4 ms of elasticity at the maximum 128 kSPS
        // rate while block RAM supports the 256-to-32-bit width conversion.
        .FIFO_MEMORY_TYPE("block"),
        .FIFO_READ_LATENCY(0),
        .FIFO_WRITE_DEPTH(512),
        .FULL_RESET_VALUE(0),
        .READ_DATA_WIDTH(32),
        .READ_MODE("fwft"),
        .RELATED_CLOCKS(0),
        .SIM_ASSERT_CHK(1),
        .USE_ADV_FEATURES("0000"),
        .WRITE_DATA_WIDTH(256),
        .WR_DATA_COUNT_WIDTH(10),
        .RD_DATA_COUNT_WIDTH(13)
    ) frame_fifo (
        .rst(fifo_rst_dclk),
        .wr_clk(adc_dclk),
        .wr_en(frame_valid),
        .din(frame_data),
        .full(fifo_full),
        .overflow(fifo_overflow),
        .wr_rst_busy(fifo_wr_reset_busy),
        .rd_clk(s_axi_aclk),
        .rd_en(fifo_read_enable),
        .dout(fifo_data_out),
        .empty(fifo_empty),
        .underflow(fifo_underflow),
        .rd_rst_busy(fifo_rd_reset_busy),
        .sleep(1'b0),
        .injectsbiterr(1'b0),
        .injectdbiterr(1'b0),
        .prog_full(),
        .wr_data_count(),
        .almost_full(),
        .wr_ack(),
        .prog_empty(),
        .rd_data_count(),
        .almost_empty(),
        .data_valid(),
        .sbiterr(),
        .dbiterr()
    );

    assign m_axis_tdata  = fifo_data_out;
    assign m_axis_tkeep  = 4'hf;
    assign m_axis_tvalid = !fifo_empty && !fifo_rd_reset_busy && !fifo_reset;
    assign m_axis_tlast  = m_axis_tvalid &&
                           (beat_in_packet == (beats_per_packet - 1'b1));
    assign fifo_read_enable = m_axis_tvalid && m_axis_tready;

    always_ff @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn || fifo_reset || fifo_rd_reset_busy) begin
            beat_in_packet <= 19'b0;
            packet_count   <= 32'b0;
        end else if (fifo_read_enable) begin
            if (m_axis_tlast) begin
                beat_in_packet <= 19'b0;
                packet_count   <= packet_count + 1'b1;
            end else begin
                beat_in_packet <= beat_in_packet + 1'b1;
            end
        end
    end

    xpm_cdc_gray #(.DEST_SYNC_FF(2), .INIT_SYNC_FF(1), .WIDTH(32))
        frame_count_cdc (
            .src_clk(adc_dclk), .src_in_bin(frame_count_dclk),
            .dest_clk(s_axi_aclk), .dest_out_bin(frame_count_axi));
    xpm_cdc_gray #(.DEST_SYNC_FF(2), .INIT_SYNC_FF(1), .WIDTH(32))
        overflow_count_cdc (
            .src_clk(adc_dclk), .src_in_bin(overflow_count_dclk),
            .dest_clk(s_axi_aclk), .dest_out_bin(overflow_count_axi));
    xpm_cdc_gray #(.DEST_SYNC_FF(2), .INIT_SYNC_FF(1), .WIDTH(32))
        header_error_count_cdc (
            .src_clk(adc_dclk), .src_in_bin(header_error_count_dclk),
            .dest_clk(s_axi_aclk), .dest_out_bin(header_error_count_axi));
    xpm_cdc_gray #(.DEST_SYNC_FF(2), .INIT_SYNC_FF(1), .WIDTH(32))
        alert_count_cdc (
            .src_clk(adc_dclk), .src_in_bin(alert_count_dclk),
            .dest_clk(s_axi_aclk), .dest_out_bin(alert_count_axi));

    xpm_cdc_single #(.DEST_SYNC_FF(2), .INIT_SYNC_FF(1), .SRC_INPUT_REG(1))
        receiver_busy_cdc (
            .src_clk(adc_dclk), .src_in(receiver_busy_dclk),
            .dest_clk(s_axi_aclk), .dest_out(receiver_busy_axi));
    xpm_cdc_single #(.DEST_SYNC_FF(2), .INIT_SYNC_FF(1), .SRC_INPUT_REG(1))
        fifo_full_cdc (
            .src_clk(adc_dclk), .src_in(fifo_full),
            .dest_clk(s_axi_aclk), .dest_out(fifo_full_axi));
    xpm_cdc_single #(.DEST_SYNC_FF(2), .INIT_SYNC_FF(1), .SRC_INPUT_REG(1))
        fifo_wr_busy_cdc (
            .src_clk(adc_dclk), .src_in(fifo_wr_reset_busy),
            .dest_clk(s_axi_aclk), .dest_out(fifo_wr_reset_busy_axi));
    xpm_cdc_single #(.DEST_SYNC_FF(2), .INIT_SYNC_FF(1), .SRC_INPUT_REG(1))
        adc_drdy_cdc (
            .src_clk(adc_dclk), .src_in(adc_drdy_n),
            .dest_clk(s_axi_aclk), .dest_out(adc_drdy_n_axi));

    ad7771_axi_regs registers (
        .s_axi_aclk,
        .s_axi_aresetn,
        .s_axi_awaddr,
        .s_axi_awvalid,
        .s_axi_awready,
        .s_axi_wdata,
        .s_axi_wstrb,
        .s_axi_wvalid,
        .s_axi_wready,
        .s_axi_bresp,
        .s_axi_bvalid,
        .s_axi_bready,
        .s_axi_araddr,
        .s_axi_arvalid,
        .s_axi_arready,
        .s_axi_rdata,
        .s_axi_rresp,
        .s_axi_rvalid,
        .s_axi_rready,
        .capture_enable,
        .fifo_reset,
        .adc_reset_n,
        .adc_start_n,
        .adc_convst_sar,
        .packet_frames,
        .receiver_busy(receiver_busy_axi),
        .fifo_full(fifo_full_axi),
        .fifo_empty,
        .fifo_overflow_sticky(overflow_count_axi != 0),
        .header_error_sticky(header_error_count_axi != 0),
        .alert_sticky(alert_count_axi != 0),
        .adc_drdy_n(adc_drdy_n_axi),
        .fifo_wr_reset_busy(fifo_wr_reset_busy_axi),
        .fifo_rd_reset_busy(fifo_rd_reset_busy),
        .frame_count(frame_count_axi),
        .overflow_count(overflow_count_axi),
        .header_error_count(header_error_count_axi),
        .alert_count(alert_count_axi),
        .packet_count
    );

endmodule
