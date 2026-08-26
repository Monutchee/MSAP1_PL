`timescale 1ns/1ps

module meter_spectral_conditioner_tb;
    localparam int CHANNELS = 7;
    localparam int SOURCE_FRAMES = 100;
    localparam int OUTPUT_FRAMES = 64;

    logic aclk = 1'b0;
    logic aresetn = 1'b0;
    always #5 aclk = ~aclk;

    logic frame_accept_i;
    logic [255:0] raw_frame_i;
    logic [383:0] frame_user_i;
    logic frame_closes_block_i;
    logic grid_locked_i;
    logic [7:0] grid_nominal_hz_i;
    logic [7:0] grid_cycle_count_i;
    logic config_enable_i;
    logic config_apply_toggle_i;
    logic [31:0] source_frame_rate_i;
    logic source_frame_rate_valid_i;
    logic [31:0] frequency_millihz_i;
    logic frequency_valid_i;
    logic [255:0] active_scale_q16_i;
    logic [31:0] emit_drops_i;
    logic [575:0] m_axis_context_tdata;
    logic m_axis_context_tvalid;
    logic m_axis_context_tready;
    logic [167:0] m_axis_frame_tdata;
    logic m_axis_frame_tvalid;
    logic m_axis_frame_tready;
    logic m_axis_frame_tlast;
    logic m_axis_frame_fault;
    logic [31:0] completed_blocks_o;
    logic [31:0] invalid_blocks_o;
    logic [31:0] service_overruns_o;

    int source_index = 0;
    int context_count = 0;
    int output_count = 0;

    meter_spectral_conditioner #(
        .EXPECTED_SOURCE_FRAMES(SOURCE_FRAMES),
        .OUTPUT_FRAMES(OUTPUT_FRAMES)
    ) dut (.*);

    task automatic fail(input string message);
        $display("FAIL: %s", message);
        $fatal(1);
    endtask

    task automatic send_source_frame(input bit closes_block);
        @(negedge aclk);
        raw_frame_i = '0;
        for (int channel = 0; channel < CHANNELS; channel++)
            raw_frame_i[channel*32 +: 24] = 24'sd1000 + channel;
        source_index++;
        frame_user_i = '0;
        frame_user_i[31:0] = source_index;
        frame_user_i[63:32] = 32'h12345678;
        frame_user_i[71:64] = 8'h7f;
        frame_accept_i = 1'b1;
        frame_closes_block_i = closes_block;
        @(posedge aclk);
        @(negedge aclk);
        frame_accept_i = 1'b0;
        frame_closes_block_i = 1'b0;
        // Production has >3,100 clocks/frame.  The focused TB retains a
        // smaller but still contract-compliant service interval.
        repeat (520) @(posedge aclk);
    endtask

    always @(posedge aclk) begin
        if (aresetn && m_axis_context_tvalid && m_axis_context_tready) begin
            context_count++;
            if (m_axis_context_tdata[31:0] != 32'h12345678 ||
                m_axis_context_tdata[95:64] != SOURCE_FRAMES ||
                m_axis_context_tdata[103:96] != 8'h7f ||
                m_axis_context_tdata[119:112] != 50 ||
                m_axis_context_tdata[127:120] != 10 ||
                m_axis_context_tdata[135:128] != 127 ||
                m_axis_context_tdata[143:136] != 1 ||
                m_axis_context_tdata[191:160] != 50000 ||
                m_axis_context_tdata[255:192] != 101)
                fail("conditioner context/provenance mismatch");
            if (!m_axis_context_tdata[104] ||
                !m_axis_context_tdata[105] ||
                !m_axis_context_tdata[106])
                fail("qualified first-family flags mismatch");
        end
        if (aresetn && m_axis_frame_tvalid && m_axis_frame_tready) begin
            output_count++;
            for (int channel = 0; channel < CHANNELS; channel++) begin
                if ($signed(m_axis_frame_tdata[channel*24 +: 24]) !=
                    1000 + channel)
                    fail("DC gain or channel order mismatch");
            end
            if (m_axis_frame_fault)
                fail("qualified block carried a frame fault");
            if (m_axis_frame_tlast != (output_count == OUTPUT_FRAMES))
                fail("conditioned TLAST position mismatch");
        end
    end

    initial begin
        frame_accept_i = 1'b0;
        raw_frame_i = '0;
        frame_user_i = '0;
        frame_closes_block_i = 1'b0;
        grid_locked_i = 1'b1;
        grid_nominal_hz_i = 8'd50;
        grid_cycle_count_i = 8'd10;
        config_enable_i = 1'b1;
        config_apply_toggle_i = 1'b0;
        source_frame_rate_i = 32'd32000;
        source_frame_rate_valid_i = 1'b1;
        frequency_millihz_i = 32'd50000;
        frequency_valid_i = 1'b1;
        active_scale_q16_i = '0;
        for (int channel = 0; channel < 8; channel++)
            active_scale_q16_i[channel*32 +: 32] = 32'h00010000;
        emit_drops_i = 0;
        m_axis_context_tready = 1'b1;
        m_axis_frame_tready = 1'b1;

        repeat (5) @(posedge aclk);
        aresetn = 1'b1;

        // Block 0 primes the centered polyphase prototype. Block 1 is the
        // first publishable family. Thirty-two following frames flush its
        // exact integer source-frame group delay.
        for (int sample = 0; sample < SOURCE_FRAMES; sample++)
            send_source_frame(sample == SOURCE_FRAMES - 1);
        for (int sample = 0; sample < SOURCE_FRAMES; sample++)
            send_source_frame(sample == SOURCE_FRAMES - 1);
        // The next source block begins during the active block's 32-frame
        // marker-delay flush. Its qualification must not overwrite the
        // already active block's snapshot.
        grid_locked_i = 1'b0;
        for (int sample = 0; sample < 32; sample++)
            send_source_frame(1'b0);

        wait (completed_blocks_o == 1);
        repeat (10) @(posedge aclk);
        if (context_count != 1 || output_count != OUTPUT_FRAMES ||
            invalid_blocks_o != 0 || service_overruns_o != 0)
            fail("conditioner block/counter geometry mismatch");

        $display("meter_spectral_conditioner PASS");
        $finish;
    end

    initial begin
        repeat (200000) @(posedge aclk);
        fail("timeout");
    end
endmodule
