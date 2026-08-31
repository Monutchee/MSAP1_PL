`timescale 1ns/1ps

module meter_spectral_context_snapshot_tb;
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
    bit context_seen = 1'b0;
    logic [575:0] captured_context;

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
        source_index++;
        frame_user_i = '0;
        frame_user_i[31:0] = source_index;
        frame_user_i[63:32] = 32'h89abcdef;
        frame_user_i[71:64] = 8'h7f;
        frame_accept_i = 1'b1;
        frame_closes_block_i = closes_block;
        @(posedge aclk);
        @(negedge aclk);
        frame_accept_i = 1'b0;
        frame_closes_block_i = 1'b0;
        repeat (1000) @(posedge aclk);
    endtask

    always @(posedge aclk) begin
        if (aresetn && m_axis_context_tvalid && m_axis_context_tready) begin
            context_seen <= 1'b1;
            captured_context <= m_axis_context_tdata;
        end
    end

    initial begin
        frame_accept_i = 1'b0;
        raw_frame_i = '0;
        frame_user_i = '0;
        frame_closes_block_i = 1'b0;
        grid_locked_i = 1'b0;
        grid_nominal_hz_i = 8'd50;
        grid_cycle_count_i = 8'd10;
        config_enable_i = 1'b1;
        config_apply_toggle_i = 1'b0;
        configured_frame_rate_i = 32'd32000;
        source_frame_rate_i = 32'd32000;
        source_frame_rate_valid_i = 1'b1;
        frequency_millihz_i = 32'd0;
        frequency_valid_i = 1'b0;
        active_scale_q16_i = '0;
        emit_drops_i = 0;
        m_axis_context_tready = 1'b1;
        m_axis_frame_tready = 1'b1;

        repeat (5) @(posedge aclk);
        aresetn = 1'b1;

        // Prime the centered filter, then begin the publishable block while
        // frequency acquisition is still invalid immediately after APPLY.
        for (int sample = 0; sample < SOURCE_FRAMES; sample++)
            send_source_frame(sample == SOURCE_FRAMES - 1);
        send_source_frame(1'b0);

        // Lock arrives before the delayed context marker.  The emitted
        // context must retain the boundary snapshot (unlocked, 0 mHz), not
        // combine that frequency with this newer lock state.
        grid_locked_i = 1'b1;
        frequency_millihz_i = 32'd50000;
        frequency_valid_i = 1'b1;
        for (int sample = 1; sample < SOURCE_FRAMES; sample++)
            send_source_frame(sample == SOURCE_FRAMES - 1);
        for (int sample = 0; sample < 32; sample++)
            send_source_frame(1'b0);

        wait (context_seen);
        if (captured_context[191:160] != 32'd0)
            fail("frequency was not captured at the source-window boundary");
        if (captured_context[104])
            fail("newer grid lock was mixed into an older zero-frequency context");
        if (captured_context[105])
            fail("zero-frequency source-window context was marked qualified");

        $display("meter_spectral_context_snapshot PASS");
        $finish;
    end

    initial begin
        repeat (300000) @(posedge aclk);
        fail("timeout");
    end
endmodule
