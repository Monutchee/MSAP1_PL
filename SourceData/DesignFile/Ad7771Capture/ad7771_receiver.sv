`timescale 1ns / 1ps

// AD7771 four-DOUT receiver.
//
// The converter drives DOUT0..3 and DRDY_N synchronously to DCLK.  DRDY_N is
// low for most of the conversion interval, pulses high before the next frame,
// and falls when the new frame starts.  In the selected four-lane format each
// lane carries two 32-bit channel words:
//
//   DOUT0: CH0, CH1    DOUT1: CH2, CH3
//   DOUT2: CH4, CH5    DOUT3: CH6, CH7
//
// Each channel word is an 8-bit header followed by a signed 24-bit sample,
// MSB first.  The receiver emits one packed 256-bit frame with eight
// sign-extended 32-bit samples.  Sample 0 occupies bits [31:0].
module ad7771_receiver (
    input  logic         adc_dclk,
    input  logic         receiver_reset,
    input  logic         capture_enable,
    input  logic         adc_drdy_n,
    input  logic [3:0]   adc_dout,
    input  logic         frame_sink_full,

    output logic [255:0] frame_data,
    output logic         frame_valid,
    output logic         receiver_busy,
    output logic [31:0]  frame_count,
    output logic [31:0]  overflow_count,
    output logic [31:0]  header_error_count,
    output logic [31:0]  alert_count
);

    logic [63:0] lane_shift [0:3];
    logic [5:0]  bits_captured;
    logic        adc_drdy_n_previous;

    logic [63:0] lane_next [0:3];
    logic [31:0] channel_word [0:7];
    logic [7:0]  channel_header [0:7];
    logic [255:0] frame_data_next;
    logic        headers_valid;
    logic        alert_present;

    always_comb begin
        for (int lane = 0; lane < 4; lane = lane + 1)
            lane_next[lane] = {lane_shift[lane][62:0], adc_dout[lane]};

        channel_word[0] = lane_next[0][63:32];
        channel_word[1] = lane_next[0][31:0];
        channel_word[2] = lane_next[1][63:32];
        channel_word[3] = lane_next[1][31:0];
        channel_word[4] = lane_next[2][63:32];
        channel_word[5] = lane_next[2][31:0];
        channel_word[6] = lane_next[3][63:32];
        channel_word[7] = lane_next[3][31:0];

        headers_valid = 1'b1;
        alert_present = 1'b0;
        for (int channel = 0; channel < 8; channel = channel + 1) begin
            channel_header[channel] = channel_word[channel][31:24];
            if (channel_header[channel][6:4] != channel[2:0])
                headers_valid = 1'b0;
            if (channel_header[channel][7])
                alert_present = 1'b1;
        end

        // XPM FIFO width conversion reads the least-significant 32-bit word
        // first, so pack CH0 in the least-significant word.
        frame_data_next = {
            {{8{channel_word[7][23]}}, channel_word[7][23:0]},
            {{8{channel_word[6][23]}}, channel_word[6][23:0]},
            {{8{channel_word[5][23]}}, channel_word[5][23:0]},
            {{8{channel_word[4][23]}}, channel_word[4][23:0]},
            {{8{channel_word[3][23]}}, channel_word[3][23:0]},
            {{8{channel_word[2][23]}}, channel_word[2][23:0]},
            {{8{channel_word[1][23]}}, channel_word[1][23:0]},
            {{8{channel_word[0][23]}}, channel_word[0][23:0]}
        };
    end

    // DOUT changes between words around the rising half-cycle and is
    // guaranteed for at least 20 ns on each side of DCLK's falling edge.
    // DRDY falls just after a rising edge, so the following falling edge is
    // the first safe point at which to capture the MSB.
    always_ff @(negedge adc_dclk) begin
        if (receiver_reset) begin
            for (int lane = 0; lane < 4; lane = lane + 1)
                lane_shift[lane] <= 64'b0;
            bits_captured     <= 6'b0;
            adc_drdy_n_previous <= 1'b0;
            frame_valid       <= 1'b0;
            frame_data        <= 256'b0;
            receiver_busy     <= 1'b0;
            frame_count       <= 32'b0;
            overflow_count    <= 32'b0;
            header_error_count <= 32'b0;
            alert_count       <= 32'b0;
        end else begin
            adc_drdy_n_previous <= adc_drdy_n;
            frame_valid <= 1'b0;

            if (!capture_enable) begin
                bits_captured <= 6'b0;
                receiver_busy <= 1'b0;
            end else if (!receiver_busy) begin
                // DOUT changes after the DCLK rising edge on which DRDY_N
                // falls.  The following DCLK falling edge is therefore the
                // first safe point at which to sample the new header MSB.
                //
                // Detect the edge rather than the low level. DRDY_N remains
                // low between frames; level detection would continuously
                // deserialize repeated LSB data and lose frame alignment.
                if (adc_drdy_n_previous && !adc_drdy_n) begin
                    for (int lane = 0; lane < 4; lane = lane + 1)
                        lane_shift[lane] <= {63'b0, adc_dout[lane]};
                    bits_captured <= 6'd1;
                    receiver_busy <= 1'b1;
                end
            end else begin
                for (int lane = 0; lane < 4; lane = lane + 1)
                    lane_shift[lane] <= lane_next[lane];

                if (bits_captured == 6'd63) begin
                    receiver_busy <= 1'b0;
                    bits_captured <= 6'b0;
                    frame_count   <= frame_count + 1'b1;

                    if (!headers_valid)
                        header_error_count <= header_error_count + 1'b1;
                    if (alert_present)
                        alert_count <= alert_count + 1'b1;

                    if (frame_sink_full)
                        overflow_count <= overflow_count + 1'b1;
                    else begin
                        frame_data  <= frame_data_next;
                        frame_valid <= 1'b1;
                    end
                end else begin
                    bits_captured <= bits_captured + 1'b1;
                end
            end
        end
    end

endmodule
