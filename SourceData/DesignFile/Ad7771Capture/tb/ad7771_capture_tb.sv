`timescale 1ns / 1ps

module ad7771_capture_tb;

    logic         s_axi_aclk = 1'b0;
    logic         s_axi_aresetn = 1'b0;
    logic [7:0]   s_axi_awaddr = 8'b0;
    logic         s_axi_awvalid = 1'b0;
    logic         s_axi_awready;
    logic [31:0]  s_axi_wdata = 32'b0;
    logic [3:0]   s_axi_wstrb = 4'b0;
    logic         s_axi_wvalid = 1'b0;
    logic         s_axi_wready;
    logic [1:0]   s_axi_bresp;
    logic         s_axi_bvalid;
    logic         s_axi_bready = 1'b1;
    logic [7:0]   s_axi_araddr = 8'b0;
    logic         s_axi_arvalid = 1'b0;
    logic         s_axi_arready;
    logic [31:0]  s_axi_rdata;
    logic [1:0]   s_axi_rresp;
    logic         s_axi_rvalid;
    logic         s_axi_rready = 1'b1;

    logic [31:0]  m_axis_tdata;
    logic [3:0]   m_axis_tkeep;
    logic         m_axis_tvalid;
    logic         m_axis_tready = 1'b0;
    logic         m_axis_tlast;
    logic [31:0]  capture_frame_count;
    logic [31:0]  capture_overflow_count;
    logic [31:0]  capture_header_errors;
    logic [31:0]  capture_alert_count;

    logic         adc_dclk = 1'b0;
    logic         adc_drdy_n = 1'b0;
    logic [3:0]   adc_dout = 4'b0;
    logic         adc_reset_n;
    logic         adc_start_n;
    logic         adc_convst_sar;

    logic [31:0] words [0:7];
    logic [63:0] lanes [0:3];
    logic [31:0] expected_beats [0:15];
    logic [31:0] read_value;
    logic [31:0] stalled_data;
    logic        stalled_last;
    integer      bit_index;
    integer      channel;
    integer      beat_index;

    always #5  s_axi_aclk = ~s_axi_aclk;
    always #20 adc_dclk = ~adc_dclk;

    ad7771_capture #(
        // Shorten the one-second production measurement window for simulation.
        .S_AXI_CLOCK_HZ(100)
    ) dut (
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
        .m_axis_tdata,
        .m_axis_tkeep,
        .m_axis_tvalid,
        .m_axis_tready,
        .m_axis_tlast,
        .capture_frame_count,
        .capture_overflow_count,
        .capture_header_errors,
        .capture_alert_count,
        .adc_dclk,
        .adc_drdy_n,
        .adc_dout,
        .adc_reset_n,
        .adc_start_n,
        .adc_convst_sar
    );

    task automatic axi_write(input logic [7:0] address,
                             input logic [31:0] value,
                             input logic [3:0] strobes = 4'hf);
        begin
            @(negedge s_axi_aclk);
            s_axi_awaddr  <= address;
            s_axi_awvalid <= 1'b1;
            s_axi_wdata   <= value;
            s_axi_wstrb   <= strobes;
            s_axi_wvalid  <= 1'b1;

            do @(posedge s_axi_aclk);
            while (!(s_axi_awready && s_axi_wready));

            @(negedge s_axi_aclk);
            s_axi_awvalid <= 1'b0;
            s_axi_wvalid  <= 1'b0;
            s_axi_wstrb   <= 4'b0;

            wait (s_axi_bvalid);
            if (s_axi_bresp !== 2'b00)
                $fatal(1, "AXI write response error at %02x", address);
            @(posedge s_axi_aclk);
        end
    endtask

    task automatic axi_read(input logic [7:0] address,
                            output logic [31:0] value);
        begin
            @(negedge s_axi_aclk);
            s_axi_araddr  <= address;
            s_axi_arvalid <= 1'b1;

            do @(posedge s_axi_aclk);
            while (!s_axi_arready);

            @(negedge s_axi_aclk);
            s_axi_arvalid <= 1'b0;

            wait (s_axi_rvalid);
            if (s_axi_rresp !== 2'b00)
                $fatal(1, "AXI read response error at %02x", address);
            value = s_axi_rdata;
            @(posedge s_axi_aclk);
        end
    endtask

    task automatic build_frame(input integer frame_number);
        logic [7:0] header;
        logic signed [23:0] sample;
        begin
            for (channel = 0; channel < 8; channel = channel + 1) begin
                if (channel[0])
                    sample = -24'sd4096 - frame_number * 24'sd16 - channel;
                else
                    sample = 24'sd4096 + frame_number * 24'sd16 + channel;
                header = {1'b0, channel[2:0], 4'h0};
                words[channel] = {header, sample};
                expected_beats[frame_number * 8 + channel] =
                    {{8{sample[23]}}, sample};
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
            adc_drdy_n <= 1'b0;
            repeat (3) @(posedge adc_dclk);

            @(posedge adc_dclk);
            adc_drdy_n <= 1'b1;

            @(posedge adc_dclk);
            adc_drdy_n <= 1'b0;
            adc_dout <= {lanes[3][63], lanes[2][63],
                         lanes[1][63], lanes[0][63]};

            for (bit_index = 62; bit_index >= 0; bit_index = bit_index - 1) begin
                @(posedge adc_dclk);
                adc_dout <= {lanes[3][bit_index], lanes[2][bit_index],
                             lanes[1][bit_index], lanes[0][bit_index]};
            end

            @(negedge adc_dclk);
            #1;
        end
    endtask

    initial begin : watchdog
        #200_000;
        $fatal(1, "capture integration test timed out");
    end

    initial begin
        repeat (8) @(posedge s_axi_aclk);
        s_axi_aresetn <= 1'b1;

        // Two frames per packet makes TLAST observable after 16 AXI beats.
        axi_write(8'h08, 32'd2);
        // Enable capture, release FIFO reset, and deassert the ADC reset pin.
        axi_write(8'h04, 32'h0000_0005);
        repeat (20) @(posedge adc_dclk);

        if (!adc_reset_n || adc_start_n || adc_convst_sar)
            $fatal(1, "ADC control outputs do not match control register");

        send_frame(0);
        send_frame(1);

        wait (m_axis_tvalid);
        stalled_data = m_axis_tdata;
        stalled_last = m_axis_tlast;
        repeat (4) begin
            @(posedge s_axi_aclk);
            if (!m_axis_tvalid || m_axis_tdata !== stalled_data ||
                m_axis_tlast !== stalled_last)
                $fatal(1, "AXI stream changed while backpressured");
        end

        m_axis_tready <= 1'b1;
        beat_index = 0;
        while (beat_index < 16) begin
            @(posedge s_axi_aclk);
            if (m_axis_tvalid && m_axis_tready) begin
                if (m_axis_tdata !== expected_beats[beat_index])
                    $fatal(1, "beat %0d mismatch: got %08x expected %08x",
                           beat_index, m_axis_tdata, expected_beats[beat_index]);
                if (m_axis_tkeep !== 4'hf)
                    $fatal(1, "beat %0d has invalid TKEEP", beat_index);
                if (m_axis_tlast !== (beat_index == 15))
                    $fatal(1, "beat %0d has incorrect TLAST", beat_index);
                beat_index = beat_index + 1;
            end
        end
        m_axis_tready <= 1'b0;

        repeat (20) @(posedge s_axi_aclk);
        axi_read(8'h00, read_value);
        if (read_value !== 32'h0001_0000)
            $fatal(1, "version register mismatch");
        axi_read(8'h08, read_value);
        if (read_value !== 32'd2)
            $fatal(1, "configured packet-frame count mismatch: %0d",
                   read_value);
        axi_read(8'h10, read_value);
        if (read_value !== 32'd2)
            $fatal(1, "frame count mismatch: %0d", read_value);
        // The accepted-packet counter advances only when the final beat and
        // TLAST complete their AXI handshake. Backpressured or partial packets
        // must not be reported as delivered.
        axi_read(8'h20, read_value);
        if (read_value !== 32'd1)
            $fatal(1, "accepted packet count mismatch: %0d", read_value);
        axi_read(8'h0c, read_value);
        if (!read_value[10])
            $fatal(1, "DCLK frequency measurement never became valid");
        axi_read(8'h2c, read_value);
        // The test clocks are 100 MHz reference and 25 MHz DCLK. CDC snapshot
        // latency can move one edge across a window boundary.
        if (read_value < 32'd24 || read_value > 32'd26)
            $fatal(1, "DCLK frequency measurement mismatch: %0d", read_value);
        axi_read(8'h18, read_value);
        if (read_value !== 32'd0)
            $fatal(1, "unexpected header errors: %0d", read_value);
        axi_read(8'h24, read_value);
        if (read_value !== 32'h0008_0420)
            $fatal(1, "format descriptor mismatch");
        axi_read(8'h28, read_value);
        if (read_value !== 32'h4144_3731)
            $fatal(1, "identifier mismatch");

        $display("PASS: ad7771_capture_tb");
        $finish;
    end
endmodule
