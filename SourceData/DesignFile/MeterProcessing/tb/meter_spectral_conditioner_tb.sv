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
    logic [31:0] configured_frame_rate_i;
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
    int expected_first_sample = 101;
    bit expected_profile_qualified = 1'b1;

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
        // Production has >3,100 clocks/frame at 32 kSPS. The adaptive
        // two-stage RAM/MAC pipeline needs about 930 clocks per output; this
        // focused cadence retains margin without simulating wall-clock time.
        repeat (1000) @(posedge aclk);
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
                m_axis_context_tdata[255:192] != expected_first_sample) begin
                $display("CTX gen=%h count=%0d mask=%h nominal=%0d cycles=%0d max=%0d profile=%0d frequency=%0d first=%0d",
                    m_axis_context_tdata[31:0],
                    m_axis_context_tdata[95:64],
                    m_axis_context_tdata[103:96],
                    m_axis_context_tdata[119:112],
                    m_axis_context_tdata[127:120],
                    m_axis_context_tdata[135:128],
                    m_axis_context_tdata[143:136],
                    m_axis_context_tdata[191:160],
                    m_axis_context_tdata[255:192]);
                fail("conditioner context/provenance mismatch");
            end
            if (!m_axis_context_tdata[104] ||
                m_axis_context_tdata[105] !== expected_profile_qualified ||
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
            if (m_axis_frame_tlast !=
                ((output_count % OUTPUT_FRAMES) == 0))
                fail("conditioned TLAST position mismatch");
        end
    end

    task automatic run_endpoint_quantized_block(input int frame_delta);
        int context_before;
        int output_before;
        int completed_before;
        int invalid_before;
        int published_frames;
        context_before = context_count;
        output_before = output_count;
        completed_before = completed_blocks_o;
        invalid_before = invalid_blocks_o;
        published_frames = SOURCE_FRAMES + frame_delta;

        @(negedge aclk);
        grid_locked_i = 1'b1;
        config_apply_toggle_i = ~config_apply_toggle_i;
        repeat (3) @(posedge aclk);

        // The exact block after APPLY primes the centered filter. The next
        // block represents the same continuous nominal interval with its
        // crossing quantized to one adjacent ADC frame.
        for (int sample = 0; sample < SOURCE_FRAMES; sample++)
            send_source_frame(sample == SOURCE_FRAMES - 1);
        expected_first_sample = source_index + 1;
        for (int sample = 0; sample < published_frames; sample++)
            send_source_frame(sample == published_frames - 1);
        for (int sample = 0; sample < 32; sample++)
            send_source_frame(1'b0);

        wait (completed_blocks_o == completed_before + 1);
        repeat (10) @(posedge aclk);
        if (context_count != context_before + 1 ||
            output_count != output_before + OUTPUT_FRAMES ||
            invalid_blocks_o != invalid_before ||
            service_overruns_o != 0)
            fail("endpoint-quantized block was not normalized");
    endtask

    task automatic run_rate_qualification_block(
        input int measured_rate,
        input bit expect_qualified
    );
        int context_before;
        int output_before;
        int completed_before;
        int invalid_before;
        context_before = context_count;
        output_before = output_count;
        completed_before = completed_blocks_o;
        invalid_before = invalid_blocks_o;

        @(negedge aclk);
        expected_profile_qualified = expect_qualified;
        source_frame_rate_i = measured_rate;
        grid_locked_i = 1'b1;
        config_apply_toggle_i = ~config_apply_toggle_i;
        repeat (3) @(posedge aclk);

        // Prime one block, publish the next, and flush profile 1's group
        // delay. Qualification changes only the context validity bit; exact
        // block geometry and the conditioned output remain structural.
        for (int sample = 0; sample < SOURCE_FRAMES; sample++)
            send_source_frame(sample == SOURCE_FRAMES - 1);
        expected_first_sample = source_index + 1;
        for (int sample = 0; sample < SOURCE_FRAMES; sample++)
            send_source_frame(sample == SOURCE_FRAMES - 1);
        for (int sample = 0; sample < 32; sample++)
            send_source_frame(1'b0);

        wait (completed_blocks_o == completed_before + 1);
        repeat (10) @(posedge aclk);
        if (context_count != context_before + 1 ||
            output_count != output_before + OUTPUT_FRAMES ||
            invalid_blocks_o != invalid_before ||
            service_overruns_o != 0)
            fail("rate-qualification block geometry mismatch");
    endtask

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
        configured_frame_rate_i = 32'd32000;
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

        // Block 0 primes the centered polyphase prototype. Begin the first
        // publishable family, then APPLY while its context/window is live.
        // Conditioner-owned AXIS state must be abandoned atomically.
        for (int sample = 0; sample < SOURCE_FRAMES; sample++)
            send_source_frame(sample == SOURCE_FRAMES - 1);
        for (int sample = 0; sample < SOURCE_FRAMES / 2; sample++)
            send_source_frame(1'b0);
        @(negedge aclk);
        config_apply_toggle_i = ~config_apply_toggle_i;
        repeat (3) @(posedge aclk);
        context_count = 0;
        output_count = 0;
        expected_first_sample = 201;

        // The remainder of the interrupted source block becomes a discarded
        // priming block. The next complete block is publishable, and 32 more
        // source frames flush profile 1's exact group delay.
        for (int sample = SOURCE_FRAMES / 2;
             sample < SOURCE_FRAMES; sample++)
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

        run_endpoint_quantized_block(-1);
        run_endpoint_quantized_block(1);
        if (completed_blocks_o != 3 || context_count != 3 ||
            output_count != 3 * OUTPUT_FRAMES || invalid_blocks_o != 0)
            fail("endpoint-quantization regression counter mismatch");

        // The 32 kSPS production tolerance is 1% + 2 Hz = 322 Hz. A
        // one-count DRDY measurement difference is valid; the first value
        // beyond the upper bound remains explicitly unqualified.
        run_rate_qualification_block(32001, 1'b1);
        run_rate_qualification_block(32323, 1'b0);
        if (completed_blocks_o != 5 || context_count != 5 ||
            output_count != 5 * OUTPUT_FRAMES || invalid_blocks_o != 0)
            fail("rate-tolerance regression counter mismatch");

        $display("meter_spectral_conditioner PASS");
        $finish;
    end

    initial begin
        repeat (1600000) @(posedge aclk);
        fail("timeout");
    end
endmodule
