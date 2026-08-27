`timescale 1ns/1ps

module meter_spectral_frontend_tb;
    localparam int CHANNELS = 3;
    localparam int SAMPLE_WIDTH = 24;
    localparam int FFT_LENGTH = 8;
    localparam int CONTEXT_BITS = 576;

    logic aclk = 1'b0;
    logic aresetn = 1'b0;
    logic config_apply_toggle_i;
    always #5 aclk = ~aclk;

    logic [CONTEXT_BITS-1:0] s_context_data;
    logic s_context_valid;
    logic s_context_ready;
    logic [CHANNELS*SAMPLE_WIDTH-1:0] s_frame_data;
    logic s_frame_valid;
    logic s_frame_ready;
    logic s_frame_last;
    logic s_frame_fault;
    logic [CONTEXT_BITS-1:0] m_context_data;
    logic m_context_valid;
    logic m_context_ready;
    logic [2*SAMPLE_WIDTH-1:0] m_fft_data;
    logic m_fft_valid;
    logic m_fft_ready;
    logic m_fft_last;
    logic busy;
    logic [31:0] completed_windows;
    logic [31:0] dropped_windows;
    logic [31:0] malformed_windows;

    int output_beat = 0;
    int output_context = 0;
    logic verify_first_family = 1'b1;

    meter_spectral_frontend #(
        .CHANNELS(CHANNELS),
        .SAMPLE_WIDTH(SAMPLE_WIDTH),
        .FFT_LENGTH(FFT_LENGTH),
        .CONTEXT_BITS(CONTEXT_BITS),
        .USE_XPM(1'b0)
    ) dut (.*,
        .s_axis_context_tdata(s_context_data),
        .s_axis_context_tvalid(s_context_valid),
        .s_axis_context_tready(s_context_ready),
        .s_axis_frame_tdata(s_frame_data),
        .s_axis_frame_tvalid(s_frame_valid),
        .s_axis_frame_tready(s_frame_ready),
        .s_axis_frame_tlast(s_frame_last),
        .s_axis_frame_fault(s_frame_fault),
        .m_axis_context_tdata(m_context_data),
        .m_axis_context_tvalid(m_context_valid),
        .m_axis_context_tready(m_context_ready),
        .m_axis_fft_tdata(m_fft_data),
        .m_axis_fft_tvalid(m_fft_valid),
        .m_axis_fft_tready(m_fft_ready),
        .m_axis_fft_tlast(m_fft_last)
    );

    task automatic fail(input string message);
        $display("FAIL: %s", message);
        $fatal(1);
    endtask

    task automatic send_context(input int tag);
        @(negedge aclk);
        s_context_data = '0;
        s_context_data[31:0] = tag;
        s_context_valid = 1'b1;
        do @(posedge aclk); while (!s_context_ready);
        @(negedge aclk);
        s_context_valid = 1'b0;
    endtask

    task automatic send_window(input int tag, input int last_index);
        send_context(tag);
        for (int sample = 0; sample <= last_index; sample++) begin
            @(negedge aclk);
            for (int channel = 0; channel < CHANNELS; channel++)
                s_frame_data[channel*SAMPLE_WIDTH +: SAMPLE_WIDTH] =
                    tag * 1000 + channel * 100 + sample;
            s_frame_last = sample == last_index;
            s_frame_valid = 1'b1;
            @(posedge aclk);
            if (!s_frame_ready)
                fail("the observer input applied backpressure");
        end
        @(negedge aclk);
        s_frame_valid = 1'b0;
        s_frame_last = 1'b0;
        s_frame_fault = 1'b0;
    endtask

    always @(posedge aclk) begin
        if (aresetn && m_context_valid && m_context_ready) begin
            output_context <= output_context + 1;
            case (m_context_data[31:0])
                1, 3, 4, 9: if (m_context_data[319:288] != 0)
                    fail("pre-drop context carried the wrong snapshot");
                6: if (m_context_data[319:288] != 1)
                    fail("post-drop context did not carry the drop snapshot");
                default: fail("unexpected context reached the scheduler");
            endcase
        end
        if (aresetn && m_fft_valid && m_fft_ready) begin
            if (m_fft_data[47:24] != 0)
                fail("FFT imaginary input was not zero");
            if (verify_first_family) begin
                int channel;
                int sample;
                int expected;
                channel = output_beat / FFT_LENGTH;
                sample = output_beat % FFT_LENGTH;
                expected = 1000 + channel * 100 + sample;
                if ($signed(m_fft_data[23:0]) != expected)
                    fail("CH0..CHn sample scheduling mismatch");
                if (m_fft_last != (sample == FFT_LENGTH - 1))
                    fail("FFT TLAST position mismatch");
            end
            output_beat <= output_beat + 1;
            if (output_beat + 1 == CHANNELS * FFT_LENGTH)
                verify_first_family <= 1'b0;
        end
    end

    initial begin
        s_context_data = '0;
        s_context_valid = 1'b0;
        config_apply_toggle_i = 1'b0;
        s_frame_data = '0;
        s_frame_valid = 1'b0;
        s_frame_last = 1'b0;
        s_frame_fault = 1'b0;
        m_context_ready = 1'b1;
        m_fft_ready = 1'b1;

        repeat (4) @(posedge aclk);
        aresetn = 1'b1;

        // One complete family checks exact channel-major scheduling.
        send_window(1, FFT_LENGTH - 1);
        wait (completed_windows == 1);
        // The VHDL DUT's completed counter and this SystemVerilog
        // scoreboard's nonblocking final-beat increment cross language
        // scheduling regions. Sample them together on the following phase.
        @(negedge aclk);
        if (output_beat != CHANNELS * FFT_LENGTH || output_context != 1)
            fail("complete family geometry mismatch");

        // APPLY in the middle of a conditioner window must release capture
        // immediately. The next context/window is accepted without waiting
        // for a TLAST that belongs to the abandoned configuration.
        send_context(8);
        for (int sample = 0; sample < 3; sample++) begin
            @(negedge aclk);
            s_frame_data = sample;
            s_frame_valid = 1'b1;
            @(posedge aclk);
        end
        @(negedge aclk);
        s_frame_valid = 1'b0;
        config_apply_toggle_i = ~config_apply_toggle_i;
        repeat (2) @(posedge aclk);
        if (!s_context_ready)
            fail("APPLY did not release incomplete frontend capture");
        send_window(9, FFT_LENGTH - 1);
        wait (completed_windows == 2);
        if (malformed_windows != 0)
            fail("APPLY abort was incorrectly counted as malformed");

        // Early TLAST invalidates the bank and cannot reach the FFT.
        send_window(2, 3);
        repeat (10) @(posedge aclk);
        if (malformed_windows != 1 || completed_windows != 2)
            fail("malformed input window was not isolated");

        // Exact framing cannot make a conditioner/profile fault publishable.
        send_context(7);
        for (int sample = 0; sample < FFT_LENGTH; sample++) begin
            @(negedge aclk);
            s_frame_data = sample;
            s_frame_last = sample == FFT_LENGTH - 1;
            s_frame_fault = sample == FFT_LENGTH - 1;
            s_frame_valid = 1'b1;
            @(posedge aclk);
        end
        @(negedge aclk);
        s_frame_valid = 1'b0;
        s_frame_last = 1'b0;
        s_frame_fault = 1'b0;
        repeat (10) @(posedge aclk);
        if (malformed_windows != 2 || completed_windows != 2)
            fail("explicit conditioner fault was not isolated");

        // Hold the FFT, fill both banks, then prove that a third window is
        // consumed/dropped without backpressuring the input.
        m_fft_ready = 1'b0;
        send_window(3, FFT_LENGTH - 1);
        send_window(4, FFT_LENGTH - 1);
        send_window(5, FFT_LENGTH - 1);
        if (dropped_windows != 1)
            fail("full ping/pong pair did not count one dropped window");
        m_fft_ready = 1'b1;
        wait (completed_windows == 4);

        // The next accepted context must include the prior drop snapshot.
        send_window(6, FFT_LENGTH - 1);
        wait (completed_windows == 5);
        if (output_context != 5 || malformed_windows != 2 ||
            dropped_windows != 1)
            fail("frontend counters or accepted-context count mismatch");

        $display("meter_spectral_frontend PASS");
        $finish;
    end

    initial begin
        repeat (10000) @(posedge aclk);
        fail("timeout");
    end
endmodule
