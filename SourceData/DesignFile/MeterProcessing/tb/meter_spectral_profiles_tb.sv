`timescale 1ns/1ps

module meter_spectral_profiles_tb;
    localparam int CHANNELS = 7;
    localparam int OUTPUT_FRAMES = 512;
    localparam int PROFILE_1_SOURCE_FRAMES = 800;

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

    int source_index;
    int context_count;
    int output_count;
    int expected_profile;
    int expected_rate;
    int expected_source_frames;
    int expected_qualified_max;

    meter_spectral_conditioner #(
        .EXPECTED_SOURCE_FRAMES(PROFILE_1_SOURCE_FRAMES),
        .OUTPUT_FRAMES(OUTPUT_FRAMES)
    ) dut (.*);

    task automatic fail(input string message);
        $display("FAIL: %s", message);
        $fatal(1);
    endtask

    function automatic int numerator_for_rate(input int rate);
        return 512000 / rate;
    endfunction

    function automatic int frames_for_rate(input int rate);
        return OUTPUT_FRAMES * 25 / numerator_for_rate(rate);
    endfunction

    function automatic int delay_for_rate(input int rate);
        case (rate)
            128000: return 128;
             64000: return 64;
             32000: return 32;
            default: return 34;
        endcase
    endfunction

    function automatic int profile_for_rate(input int rate);
        case (rate)
             32000: return 1;
             64000: return 2;
            128000: return 3;
             16000: return 4;
              8000: return 5;
              4000: return 6;
              2000: return 7;
              1000: return 8;
            default: return 0;
        endcase
    endfunction

    function automatic int qualified_max_for_rate(input int rate);
        int passband;
        passband = rate >= 32000 ? 7620 : rate * 2 / 5;
        return (passband / 50) > 127 ? 127 : passband / 50;
    endfunction

    function automatic int cadence_for_rate(input int rate);
        case (rate)
            128000, 64000, 32000: return 700;
            16000: return 1500;
             8000: return 2800;
             4000: return 5400;
             2000: return 18000;
             1000: return 38000;
            default: return 1000;
        endcase
    endfunction

    task automatic send_source_frame(
        input bit closes_block,
        input int cadence
    );
        @(negedge aclk);
        raw_frame_i = '0;
        for (int channel = 0; channel < CHANNELS; channel++)
            raw_frame_i[channel*32 +: 24] = 24'sd2000 + channel;
        source_index++;
        frame_user_i = '0;
        frame_user_i[31:0] = source_index;
        frame_user_i[63:32] = 32'h51000000 | expected_profile;
        frame_user_i[71:64] = 8'h7f;
        frame_accept_i = 1'b1;
        frame_closes_block_i = closes_block;
        @(posedge aclk);
        @(negedge aclk);
        frame_accept_i = 1'b0;
        frame_closes_block_i = 1'b0;
        repeat (cadence) @(posedge aclk);
    endtask

    task automatic run_profile(input int rate);
        int source_frames;
        int cadence;
        int context_before;
        int output_before;
        int completed_before;
        source_frames = frames_for_rate(rate);
        cadence = cadence_for_rate(rate);
        expected_profile = profile_for_rate(rate);
        expected_rate = rate;
        expected_source_frames = source_frames;
        expected_qualified_max = qualified_max_for_rate(rate);
        $display("profile %0d start: rate=%0d frames=%0d cadence=%0d",
                 expected_profile, rate, source_frames, cadence);

        @(negedge aclk);
        configured_frame_rate_i = rate;
        source_frame_rate_i = rate;
        config_apply_toggle_i = ~config_apply_toggle_i;
        repeat (3) @(posedge aclk);

        context_before = context_count;
        output_before = output_count;
        completed_before = completed_blocks_o;

        // One complete block primes the centered profile. The second is
        // published; delay frames from the third close its compensated view.
        for (int sample = 0; sample < source_frames; sample++)
            send_source_frame(sample == source_frames - 1, cadence);
        // At 1 kSPS the 25-frame source block is shorter than the 69-tap
        // history. A second complete block is required before a delayed close
        // can prime publication alignment.
        if (rate == 1000)
            for (int sample = 0; sample < source_frames; sample++)
                send_source_frame(sample == source_frames - 1, cadence);
        for (int sample = 0; sample < source_frames; sample++)
            send_source_frame(sample == source_frames - 1, cadence);
        for (int sample = 0; sample < delay_for_rate(rate); sample++)
            send_source_frame(1'b0, cadence);

        $display("profile %0d driven: completed=%0d invalid=%0d overruns=%0d contexts=%0d outputs=%0d",
                 expected_profile, completed_blocks_o, invalid_blocks_o,
                 service_overruns_o, context_count, output_count);

        wait (completed_blocks_o == completed_before + 1);
        repeat (10) @(posedge aclk);
        if (context_count != context_before + 1 ||
            output_count != output_before + OUTPUT_FRAMES)
            fail("adaptive profile output geometry mismatch");
        if (invalid_blocks_o != 0 || service_overruns_o != 0)
            fail("adaptive profile reported a structural/service failure");
        $display("profile %0d PASS", expected_profile);
    endtask

    always @(posedge aclk) begin
        if (aresetn && m_axis_context_tvalid && m_axis_context_tready) begin
            context_count++;
            if (m_axis_context_tdata[63:32] != expected_rate ||
                m_axis_context_tdata[95:64] != expected_source_frames ||
                m_axis_context_tdata[135:128] != expected_qualified_max ||
                m_axis_context_tdata[143:136] != expected_profile)
                fail("adaptive context profile metadata mismatch");
            if (!m_axis_context_tdata[104] ||
                !m_axis_context_tdata[105] ||
                !m_axis_context_tdata[106])
                fail("adaptive qualified/first-family flags mismatch");
            if (m_axis_context_tdata[107] !=
                (expected_qualified_max < 127))
                fail("adaptive rate-limited flag mismatch");
        end
        if (aresetn && m_axis_frame_tvalid && m_axis_frame_tready) begin
            output_count++;
            for (int channel = 0; channel < CHANNELS; channel++)
                if ($signed(m_axis_frame_tdata[channel*24 +: 24]) !=
                    2000 + channel)
                    fail("adaptive profile DC gain/channel order mismatch");
            if (m_axis_frame_fault)
                fail("adaptive profile output carried a frame fault");
            if (m_axis_frame_tlast !=
                ((output_count % OUTPUT_FRAMES) == 0))
                fail("adaptive profile TLAST position mismatch");
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
        source_index = 0;
        context_count = 0;
        output_count = 0;
        expected_profile = 1;
        expected_rate = 32000;
        expected_source_frames = PROFILE_1_SOURCE_FRAMES;
        expected_qualified_max = 127;

        repeat (5) @(posedge aclk);
        aresetn = 1'b1;

        run_profile(32000);
        run_profile(64000);
        run_profile(128000);
        run_profile(16000);
        run_profile(8000);
        run_profile(4000);
        run_profile(2000);
        run_profile(1000);

        if (completed_blocks_o != 8 || context_count != 8 ||
            output_count != 8 * OUTPUT_FRAMES)
            fail("adaptive profile sweep counter mismatch");
        $display("meter_spectral_profiles PASS");
        $finish;
    end

    initial begin
        repeat (30000000) @(posedge aclk);
        $display("TIMEOUT profile=%0d completed=%0d invalid=%0d overruns=%0d contexts=%0d outputs=%0d",
                 expected_profile, completed_blocks_o, invalid_blocks_o,
                 service_overruns_o, context_count, output_count);
        fail("timeout");
    end
endmodule
