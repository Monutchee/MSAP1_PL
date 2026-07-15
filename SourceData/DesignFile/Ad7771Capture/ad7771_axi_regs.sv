`timescale 1ns / 1ps

module ad7771_axi_regs (
    input  logic         s_axi_aclk,
    input  logic         s_axi_aresetn,

    input  logic [7:0]   s_axi_awaddr,
    input  logic         s_axi_awvalid,
    output logic         s_axi_awready,
    input  logic [31:0]  s_axi_wdata,
    input  logic [3:0]   s_axi_wstrb,
    input  logic         s_axi_wvalid,
    output logic         s_axi_wready,
    output logic [1:0]   s_axi_bresp,
    output logic         s_axi_bvalid,
    input  logic         s_axi_bready,

    input  logic [7:0]   s_axi_araddr,
    input  logic         s_axi_arvalid,
    output logic         s_axi_arready,
    output logic [31:0]  s_axi_rdata,
    output logic [1:0]   s_axi_rresp,
    output logic         s_axi_rvalid,
    input  logic         s_axi_rready,

    output logic         capture_enable,
    output logic         fifo_reset,
    output logic         adc_reset_n,
    output logic         adc_start_n,
    output logic         adc_convst_sar,
    output logic [15:0]  packet_frames,

    input  logic         receiver_busy,
    input  logic         fifo_full,
    input  logic         fifo_empty,
    input  logic         fifo_overflow_sticky,
    input  logic         header_error_sticky,
    input  logic         alert_sticky,
    input  logic         adc_drdy_n,
    input  logic         fifo_wr_reset_busy,
    input  logic         fifo_rd_reset_busy,
    input  logic [31:0]  frame_count,
    input  logic [31:0]  overflow_count,
    input  logic [31:0]  header_error_count,
    input  logic [31:0]  alert_count,
    input  logic [31:0]  packet_count
);

    localparam logic [31:0] VERSION = 32'h0001_0000;
    localparam logic [31:0] IDENTIFIER = 32'h4144_3731; // "AD71"
    // START on the AD7771 is a positive synchronization pulse, not an
    // active-low conversion enable.  This design synchronizes through the
    // SPI_SYNC bit, so START remains low unless software deliberately pulses
    // control_reg[3].
    localparam logic [31:0] CONTROL_RESET = 32'h0000_0002;

    logic [31:0] control_reg;
    logic [31:0] packet_frames_reg;
    logic [31:0] read_data_mux;
    logic        write_fire;
    logic        read_fire;

    function automatic logic [31:0] apply_write_strobes(
        input logic [31:0] old_value,
        input logic [31:0] new_value,
        input logic [3:0]  strobes
    );
        logic [31:0] result;
        begin
            result = old_value;
            for (int byte_index = 0; byte_index < 4; byte_index = byte_index + 1)
                if (strobes[byte_index])
                    result[byte_index*8 +: 8] = new_value[byte_index*8 +: 8];
            return result;
        end
    endfunction

    assign capture_enable = control_reg[0];
    assign fifo_reset     = control_reg[1];
    assign adc_reset_n    = control_reg[2];
    assign adc_start_n    = control_reg[3];
    assign adc_convst_sar = control_reg[4];
    assign packet_frames  = packet_frames_reg[15:0];

    assign s_axi_awready = s_axi_aresetn && !s_axi_bvalid &&
                           s_axi_awvalid && s_axi_wvalid;
    assign s_axi_wready  = s_axi_aresetn && !s_axi_bvalid &&
                           s_axi_awvalid && s_axi_wvalid;
    assign write_fire = s_axi_awready && s_axi_awvalid &&
                        s_axi_wready && s_axi_wvalid;
    assign s_axi_bresp = 2'b00;

    assign s_axi_arready = s_axi_aresetn && !s_axi_rvalid;
    assign read_fire = s_axi_arready && s_axi_arvalid;
    assign s_axi_rresp = 2'b00;

    always_ff @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            control_reg      <= CONTROL_RESET;
            packet_frames_reg <= 32'd256;
            s_axi_bvalid     <= 1'b0;
        end else begin
            if (write_fire) begin
                case (s_axi_awaddr[7:2])
                    6'h01: control_reg <= apply_write_strobes(
                        control_reg, s_axi_wdata, s_axi_wstrb);
                    6'h02: packet_frames_reg <= apply_write_strobes(
                        packet_frames_reg, s_axi_wdata, s_axi_wstrb);
                    default: begin end
                endcase
                s_axi_bvalid <= 1'b1;
            end else if (s_axi_bvalid && s_axi_bready) begin
                s_axi_bvalid <= 1'b0;
            end
        end
    end

    always_comb begin
        case (s_axi_araddr[7:2])
            6'h00: read_data_mux = VERSION;
            6'h01: read_data_mux = control_reg;
            6'h02: read_data_mux = packet_frames_reg;
            6'h03: read_data_mux = {
                22'b0,
                fifo_rd_reset_busy,
                fifo_wr_reset_busy,
                adc_drdy_n,
                alert_sticky,
                header_error_sticky,
                fifo_overflow_sticky,
                fifo_empty,
                fifo_full,
                receiver_busy,
                capture_enable
            };
            6'h04: read_data_mux = frame_count;
            6'h05: read_data_mux = overflow_count;
            6'h06: read_data_mux = header_error_count;
            6'h07: read_data_mux = alert_count;
            6'h08: read_data_mux = packet_count;
            6'h09: read_data_mux = 32'h0008_0420; // 8 channels, 4 lanes, 32-bit AXIS
            6'h0a: read_data_mux = IDENTIFIER;
            default: read_data_mux = 32'b0;
        endcase
    end

    always_ff @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            s_axi_rdata  <= 32'b0;
            s_axi_rvalid <= 1'b0;
        end else begin
            if (read_fire) begin
                s_axi_rdata  <= read_data_mux;
                s_axi_rvalid <= 1'b1;
            end else if (s_axi_rvalid && s_axi_rready) begin
                s_axi_rvalid <= 1'b0;
            end
        end
    end

endmodule
