// SPDX-License-Identifier: MIT
//
// M16 vendor-neutral spectral window buffer and channel scheduler.
//
// The upstream conditioner must deliver exactly FFT_LENGTH simultaneous
// seven-channel frames for every grid-synchronous 10/12-cycle basic block.
// It must present one 576-bit context beat before the first frame and assert
// TLAST on frame FFT_LENGTH-1.  This module never backpressures sample data:
// when both banks are occupied it accepts and discards the complete window,
// then reports the loss through dropped_windows.
//
// A completed bank is serialized CH0..CH6 into one real-valued complex frame
// per channel.  The context beat is emitted before those seven frames.  The
// intended downstream chain is:
//
//   meter_spectral_frontend -> AMD/Xilinx XFFT -> hls_harmonic_engine
//                  context --------------------> hls_harmonic_engine

`timescale 1ns/1ps

module meter_spectral_frontend #(
    parameter int CHANNELS     = 7,
    parameter int SAMPLE_WIDTH = 24,
    parameter int FFT_LENGTH   = 4096,
    parameter int CONTEXT_BITS = 576,
    // Production must retain the default XPM URAM implementation.  The
    // behavioral alternative exists only for small, vendor-library-free TBs.
    parameter bit USE_XPM      = 1'b1
) (
    input  logic                                  aclk,
    input  logic                                  aresetn,

    input  logic [CONTEXT_BITS-1:0]               s_axis_context_tdata,
    input  logic                                  s_axis_context_tvalid,
    output logic                                  s_axis_context_tready,

    input  logic [CHANNELS*SAMPLE_WIDTH-1:0]      s_axis_frame_tdata,
    input  logic                                  s_axis_frame_tvalid,
    output logic                                  s_axis_frame_tready,
    input  logic                                  s_axis_frame_tlast,
    // A conditioner/profile/geometry fault invalidates the complete bank
    // even when its AXIS frame count and TLAST happen to look correct.
    input  logic                                  s_axis_frame_fault,

    output logic [CONTEXT_BITS-1:0]               m_axis_context_tdata,
    output logic                                  m_axis_context_tvalid,
    input  logic                                  m_axis_context_tready,

    output logic [2*SAMPLE_WIDTH-1:0]             m_axis_fft_tdata,
    output logic                                  m_axis_fft_tvalid,
    input  logic                                  m_axis_fft_tready,
    output logic                                  m_axis_fft_tlast,

    output logic                                  busy,
    output logic [31:0]                           completed_windows,
    output logic [31:0]                           dropped_windows,
    output logic [31:0]                           malformed_windows
);
    localparam int FRAME_WIDTH = CHANNELS * SAMPLE_WIDTH;
    localparam int ADDR_WIDTH  = (FFT_LENGTH <= 2) ? 1 : $clog2(FFT_LENGTH);
    localparam int CH_WIDTH    = (CHANNELS <= 2) ? 1 : $clog2(CHANNELS);

    // HarmonicEngine context word positions.  The frontend owns the complete
    // source-window drop snapshot at [319:288].
    localparam int CONTEXT_RESULT_DROPS_LSB = 288;

    typedef enum logic [2:0] {
        S_IDLE,
        S_CONTEXT,
        S_READ,
        S_WAIT_1,
        S_WAIT_2,
        S_SEND
    } scheduler_state_t;

    logic [CONTEXT_BITS-1:0] context_bank [0:1];
    logic [FRAME_WIDTH-1:0] bank_data [0:1];
    logic [1:0] bank_ready;
    logic       bank_preference;

    logic       capture_active;
    logic       capture_bank;
    logic       capture_discard;
    logic       capture_framing_fault;
    logic [ADDR_WIDTH-1:0] capture_index;

    scheduler_state_t scheduler_state;
    logic       active_bank;
    logic [CH_WIDTH-1:0] channel_index;
    logic [ADDR_WIDTH-1:0] fft_index;

    logic context_fire;
    logic frame_fire;
    logic read_enable;
    logic release_bank_now;
    logic bank_0_available;
    logic bank_1_available;
    logic selected_bank;
    logic selected_bank_available;
    logic [CONTEXT_BITS-1:0] context_with_drops;
    logic window_active;
    logic effective_bank;
    logic effective_discard;
    logic effective_fault;
    logic [ADDR_WIDTH-1:0] effective_index;
    logic expected_last;
    logic memory_write_enable;

    initial begin
        if (CHANNELS < 1 || CHANNELS > 8)
            $error("meter_spectral_frontend CHANNELS must be 1..8");
        if (FFT_LENGTH < 2 || (FFT_LENGTH & (FFT_LENGTH - 1)) != 0)
            $error("meter_spectral_frontend FFT_LENGTH must be a power of two");
        if (CONTEXT_BITS < 320)
            $error("meter_spectral_frontend context is too narrow");
    end

    // Context producers may wait between windows.  Sample data is an
    // observer branch and is therefore always consumed, even if it must be
    // discarded; it can never stall ADC acquisition or the main metrology
    // path.
    assign s_axis_context_tready = !capture_active;
    assign s_axis_frame_tready = 1'b1;
    assign context_fire = s_axis_context_tvalid && s_axis_context_tready;
    assign frame_fire = s_axis_frame_tvalid;
    assign read_enable = scheduler_state == S_READ;

    // A bank completing its final output transfer is reusable on this clock
    // edge.  This avoids an unnecessary dropped block if the next context
    // arrives on exactly the release cycle.
    assign release_bank_now = scheduler_state == S_SEND &&
                              m_axis_fft_tvalid && m_axis_fft_tready &&
                              fft_index == FFT_LENGTH - 1 &&
                              channel_index == CHANNELS - 1;
    assign bank_0_available = !bank_ready[0] ||
                              (release_bank_now && active_bank == 1'b0);
    assign bank_1_available = !bank_ready[1] ||
                              (release_bank_now && active_bank == 1'b1);

    always_comb begin
        selected_bank = bank_preference;
        if (bank_preference == 1'b0) begin
            if (bank_0_available)
                selected_bank = 1'b0;
            else if (bank_1_available)
                selected_bank = 1'b1;
        end else begin
            if (bank_1_available)
                selected_bank = 1'b1;
            else if (bank_0_available)
                selected_bank = 1'b0;
        end
        selected_bank_available = selected_bank ? bank_1_available
                                                 : bank_0_available;

        context_with_drops = s_axis_context_tdata;
        context_with_drops[CONTEXT_RESULT_DROPS_LSB +: 32] =
            dropped_windows;

        window_active = capture_active || context_fire;
        effective_bank = capture_active ? capture_bank : selected_bank;
        effective_discard = capture_active ? capture_discard
                                           : !selected_bank_available;
        effective_fault = (capture_active ? capture_framing_fault : 1'b0) |
                          s_axis_frame_fault;
        effective_index = capture_active ? capture_index : '0;
        expected_last = effective_index == FFT_LENGTH - 1;
        memory_write_enable = aresetn && frame_fire && window_active &&
                              !effective_discard && !effective_fault;
    end

    assign busy = capture_active || bank_ready != 2'b00 ||
                  scheduler_state != S_IDLE;

    generate
        if (USE_XPM) begin : g_xpm_banks
            // Explicit XPM simple-dual-port banks map the wide 4K windows to
            // six K26 URAMs (three per bank). This preserves scarce BRAM for
            // XFFT and the rest of the block design. XPM also pins the
            // two-cycle scheduler read latency.
            for (genvar bank = 0; bank < 2; bank++) begin : g_window_bank
                localparam logic BANK_ID = bank;
                logic unused_sbiterr;
                logic unused_dbiterr;

                xpm_memory_sdpram #(
                    .MEMORY_SIZE        (FFT_LENGTH * FRAME_WIDTH),
                    .MEMORY_PRIMITIVE   ("ultra"),
                    .CLOCKING_MODE      ("common_clock"),
                    .ECC_MODE           ("no_ecc"),
                    .MEMORY_INIT_FILE   ("none"),
                    .USE_MEM_INIT       (0),
                    .SIM_ASSERT_CHK     (1),
                    .WRITE_DATA_WIDTH_A (FRAME_WIDTH),
                    .BYTE_WRITE_WIDTH_A (FRAME_WIDTH),
                    .ADDR_WIDTH_A       (ADDR_WIDTH),
                    .READ_DATA_WIDTH_B  (FRAME_WIDTH),
                    .ADDR_WIDTH_B       (ADDR_WIDTH),
                    .READ_LATENCY_B     (2),
                    .WRITE_MODE_B       ("read_first")
                ) window_bank_i (
                    .sleep          (1'b0),
                    .clka           (aclk),
                    .ena            (memory_write_enable &&
                                     effective_bank == BANK_ID),
                    .wea            (1'b1),
                    .addra          (effective_index),
                    .dina           (s_axis_frame_tdata),
                    .injectsbiterra (1'b0),
                    .injectdbiterra (1'b0),
                    .clkb           (aclk),
                    .rstb           (!aresetn),
                    .enb            (read_enable && active_bank == BANK_ID),
                    .regceb         (1'b1),
                    .addrb          (fft_index),
                    .doutb          (bank_data[bank]),
                    .sbiterrb       (unused_sbiterr),
                    .dbiterrb       (unused_dbiterr)
                );
            end
        end else begin : g_behavioral_banks
            logic [FRAME_WIDTH-1:0] window_bank_0 [0:FFT_LENGTH-1];
            logic [FRAME_WIDTH-1:0] window_bank_1 [0:FFT_LENGTH-1];
            logic [FRAME_WIDTH-1:0] read_stage [0:1];

            always_ff @(posedge aclk) begin
                if (memory_write_enable) begin
                    if (effective_bank == 1'b0)
                        window_bank_0[effective_index] <= s_axis_frame_tdata;
                    else
                        window_bank_1[effective_index] <= s_axis_frame_tdata;
                end
                if (read_enable) begin
                    read_stage[0] <= window_bank_0[fft_index];
                    read_stage[1] <= window_bank_1[fft_index];
                end
                bank_data[0] <= read_stage[0];
                bank_data[1] <= read_stage[1];
            end
        end
    endgenerate

    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            bank_ready             <= 2'b00;
            bank_preference        <= 1'b0;
            capture_active         <= 1'b0;
            capture_bank           <= 1'b0;
            capture_discard        <= 1'b0;
            capture_framing_fault  <= 1'b0;
            capture_index          <= '0;
            scheduler_state        <= S_IDLE;
            active_bank            <= 1'b0;
            channel_index          <= '0;
            fft_index              <= '0;
            m_axis_context_tdata   <= '0;
            m_axis_context_tvalid  <= 1'b0;
            m_axis_fft_tdata       <= '0;
            m_axis_fft_tvalid      <= 1'b0;
            m_axis_fft_tlast       <= 1'b0;
            completed_windows      <= '0;
            dropped_windows        <= '0;
            malformed_windows      <= '0;
        end else begin
            // Reserve a bank with the context.  If neither bank is free, the
            // following frame window is consumed but deliberately discarded.
            if (context_fire) begin
                capture_active        <= 1'b1;
                capture_bank          <= selected_bank;
                capture_discard       <= !selected_bank_available;
                capture_framing_fault <= 1'b0;
                capture_index         <= '0;
                if (selected_bank_available) begin
                    context_bank[selected_bank] <= context_with_drops;
                    bank_preference <= !selected_bank;
                end else if (dropped_windows != 32'hffffffff) begin
                    dropped_windows <= dropped_windows + 1'b1;
                end
            end

            if (frame_fire) begin
                if (capture_active || context_fire) begin
                    if (effective_discard) begin
                        if (s_axis_frame_tlast)
                            capture_active <= 1'b0;
                    end else if (s_axis_frame_fault) begin
                        // An explicit upstream fault has whole-window scope.
                        // Count it once, suppress this beat's memory write,
                        // and consume through TLAST to regain alignment.
                        if (!capture_framing_fault &&
                            malformed_windows != 32'hffffffff)
                            malformed_windows <= malformed_windows + 1'b1;
                        if (s_axis_frame_tlast) begin
                            capture_active <= 1'b0;
                        end else begin
                            capture_active        <= 1'b1;
                            capture_framing_fault <= 1'b1;
                        end
                    end else if (effective_fault) begin
                        // A missing expected TLAST already invalidated this
                        // block.  Consume through the eventual TLAST to regain
                        // frame alignment without counting the same fault twice.
                        if (s_axis_frame_tlast)
                            capture_active <= 1'b0;
                    end else if (s_axis_frame_tlast != expected_last) begin
                        if (malformed_windows != 32'hffffffff)
                            malformed_windows <= malformed_windows + 1'b1;
                        if (s_axis_frame_tlast) begin
                            // Early TLAST: this bank was never published.
                            capture_active <= 1'b0;
                        end else begin
                            // Missing TLAST at the exact endpoint: discard any
                            // trailing beats until the producer finally closes.
                            capture_active        <= 1'b1;
                            capture_framing_fault <= 1'b1;
                        end
                    end else if (expected_last) begin
                        bank_ready[effective_bank] <= 1'b1;
                        capture_active <= 1'b0;
                    end else begin
                        capture_index <= effective_index + 1'b1;
                    end
                end else if (s_axis_frame_tlast) begin
                    // A complete orphan frame arrived without its context.
                    if (malformed_windows != 32'hffffffff)
                        malformed_windows <= malformed_windows + 1'b1;
                end
            end

            case (scheduler_state)
                S_IDLE: begin
                    m_axis_context_tvalid <= 1'b0;
                    m_axis_fft_tvalid <= 1'b0;
                    m_axis_fft_tlast <= 1'b0;
                    if (bank_ready[0]) begin
                        active_bank <= 1'b0;
                        m_axis_context_tdata <= context_bank[0];
                        m_axis_context_tvalid <= 1'b1;
                        scheduler_state <= S_CONTEXT;
                    end else if (bank_ready[1]) begin
                        active_bank <= 1'b1;
                        m_axis_context_tdata <= context_bank[1];
                        m_axis_context_tvalid <= 1'b1;
                        scheduler_state <= S_CONTEXT;
                    end
                end

                S_CONTEXT: begin
                    if (m_axis_context_tvalid && m_axis_context_tready) begin
                        m_axis_context_tvalid <= 1'b0;
                        channel_index <= '0;
                        fft_index <= '0;
                        scheduler_state <= S_READ;
                    end
                end

                S_READ: begin
                    scheduler_state <= S_WAIT_1;
                end

                S_WAIT_1: scheduler_state <= S_WAIT_2;

                S_WAIT_2: scheduler_state <= S_SEND;

                S_SEND: begin
                    if (!m_axis_fft_tvalid) begin
                        m_axis_fft_tdata <= {
                            {SAMPLE_WIDTH{1'b0}},
                            bank_data[active_bank]
                                [channel_index*SAMPLE_WIDTH +: SAMPLE_WIDTH]
                        };
                        m_axis_fft_tlast <= fft_index == FFT_LENGTH - 1;
                        m_axis_fft_tvalid <= 1'b1;
                    end else if (m_axis_fft_tready) begin
                        m_axis_fft_tvalid <= 1'b0;
                        if (fft_index == FFT_LENGTH - 1) begin
                            if (channel_index == CHANNELS - 1) begin
                                bank_ready[active_bank] <= 1'b0;
                                if (completed_windows != 32'hffffffff)
                                    completed_windows <= completed_windows + 1'b1;
                                scheduler_state <= S_IDLE;
                            end else begin
                                channel_index <= channel_index + 1'b1;
                                fft_index <= '0;
                                scheduler_state <= S_READ;
                            end
                        end else begin
                            fft_index <= fft_index + 1'b1;
                            scheduler_state <= S_READ;
                        end
                    end
                end

                default: scheduler_state <= S_IDLE;
            endcase
        end
    end
endmodule
