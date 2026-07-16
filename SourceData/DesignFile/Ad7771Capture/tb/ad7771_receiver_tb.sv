`timescale 1ns / 1ps

module ad7771_receiver_tb;

    logic         adc_dclk = 1'b0;
    logic         receiver_reset = 1'b1;
    logic         capture_enable = 1'b0;
    logic         adc_drdy_n = 1'b0;
    logic [3:0]   adc_dout = 4'b0;
    logic         frame_sink_full = 1'b0;
    logic [255:0] frame_data;
    logic         frame_valid;
    logic         receiver_busy;
    logic [31:0]  frame_count;
    logic [31:0]  overflow_count;
    logic [31:0]  header_error_count;
    logic [31:0]  alert_count;

    logic [31:0] words [0:7];
    logic [63:0] lanes [0:3];
    logic signed [31:0] expected_samples [0:7];

    integer bit_index;
    integer channel;

    always #20 adc_dclk = ~adc_dclk;

    ad7771_receiver dut (
        .adc_dclk,
        .receiver_reset,
        .capture_enable,
        .adc_drdy_n,
        .adc_dout,
        .frame_sink_full,
        .frame_data,
        .frame_valid,
        .receiver_busy,
        .frame_count,
        .overflow_count,
        .header_error_count,
        .alert_count
    );

    task automatic build_frame(input logic corrupt_header,
                               input logic raise_alert);
        logic [7:0] header;
        logic [23:0] sample;
        begin
            for (channel = 0; channel < 8; channel = channel + 1) begin
                sample = (channel[0]) ? (24'hff0000 + channel) :
                                        (24'h001000 + channel);
                header = {raise_alert && (channel == 4), channel[2:0], 4'h0};
                if (corrupt_header && (channel == 6))
                    header[6:4] = 3'd1;
                words[channel] = {header, sample};
                expected_samples[channel] = {{8{sample[23]}}, sample};
            end

            lanes[0] = {words[0], words[1]};
            lanes[1] = {words[2], words[3]};
            lanes[2] = {words[4], words[5]};
            lanes[3] = {words[6], words[7]};
        end
    endtask

    task automatic send_frame(input integer idle_cycles);
        begin
            // DRDY_N is normally low. It rises one DCLK cycle before a new
            // frame, then falls as DOUT changes from the previous LSB to the
            // new header MSB. DOUT is sampled on the following falling edge.
            adc_drdy_n <= 1'b0;
            repeat (idle_cycles) @(posedge adc_dclk);

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

            // Let the receiver sample the final LSB before returning.
            @(negedge adc_dclk);
            #1;
        end
    endtask

    task automatic check_samples;
        begin
            for (channel = 0; channel < 8; channel = channel + 1) begin
                if ($signed(frame_data[channel*32 +: 32]) !== expected_samples[channel])
                    $fatal(1, "CH%0d mismatch: got %08x expected %08x",
                           channel, frame_data[channel*32 +: 32],
                           expected_samples[channel]);
            end
        end
    endtask

    initial begin
        repeat (4) @(posedge adc_dclk);
        receiver_reset <= 1'b0;
        capture_enable <= 1'b1;

        build_frame(1'b0, 1'b0);
        send_frame(3);
        wait (frame_valid);
        check_samples();
        if (frame_count != 1 || overflow_count != 0 ||
            header_error_count != 0 || alert_count != 0)
            $fatal(1, "unexpected counters after good frame");

        // DRDY_N stays low between frames. No additional frame may be
        // generated until a new high-to-low transition occurs.
        repeat (80) @(negedge adc_dclk);
        if (frame_count != 1 || receiver_busy)
            $fatal(1, "low DRDY_N level generated a duplicate frame");

        @(posedge adc_dclk);
        build_frame(1'b1, 1'b1);
        send_frame(2);
        wait (frame_valid);
        check_samples();
        if (frame_count != 2 || header_error_count != 1 || alert_count != 1)
            $fatal(1, "header/alert counters did not increment");

        @(posedge adc_dclk);
        frame_sink_full <= 1'b1;
        build_frame(1'b0, 1'b0);
        send_frame(2);
        repeat (2) @(posedge adc_dclk);
        if (frame_count != 3 || overflow_count != 1 || frame_valid)
            $fatal(1, "overflow handling failed");

        // Disabling capture while DRDY_N is low must not create a false edge
        // when capture is enabled again.
        capture_enable <= 1'b0;
        frame_sink_full <= 1'b0;
        repeat (4) @(negedge adc_dclk);
        capture_enable <= 1'b1;
        repeat (8) @(negedge adc_dclk);
        if (frame_count != 3 || receiver_busy)
            $fatal(1, "capture re-enable generated a false frame");

        build_frame(1'b0, 1'b0);
        send_frame(2);
        wait (frame_valid);
        check_samples();
        if (frame_count != 4 || header_error_count != 1 ||
            alert_count != 1 || overflow_count != 1)
            $fatal(1, "receiver did not resynchronize after re-enable");

        $display("PASS: ad7771_receiver_tb");
        $finish;
    end

endmodule
