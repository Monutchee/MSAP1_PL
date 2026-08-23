// SPDX-License-Identifier: MIT
//
// A4 harmonic-engine sizing prototype.
//
// This module is intentionally not connected to MeterCore.  It measures the
// storage and steering cost of the architecture proposed for M15:
//
//   accepted seven-channel frames -> ping/pong window buffers
//       -> channel scheduler -> Hann window -> one shared FFT
//
// Input samples are normalized signed 24-bit values.  M15 will define the
// production normalization from the internal Q16 conversion path; using 24
// bits here matches the ADC information content and avoids charging the FFT
// for unused engineering-unit headroom.

`timescale 1ns/1ps

module spectral_frontend #(
    parameter int CHANNELS       = 7,
    parameter int SAMPLE_WIDTH   = 24,
    parameter int WINDOW_WIDTH   = 18,
    parameter int WINDOW_SAMPLES = 3200,
    parameter int FFT_LENGTH     = 4096,
    parameter string WINDOW_FILE = "hann.mem"
) (
    input  logic                                  aclk,
    input  logic                                  aresetn,

    input  logic [CHANNELS*SAMPLE_WIDTH-1:0]      s_axis_frame_tdata,
    input  logic                                  s_axis_frame_tvalid,
    output logic                                  s_axis_frame_tready,

    output logic [2*SAMPLE_WIDTH-1:0]             m_axis_fft_tdata,
    output logic                                  m_axis_fft_tvalid,
    input  logic                                  m_axis_fft_tready,
    output logic                                  m_axis_fft_tlast,

    output logic                                  busy,
    output logic [31:0]                           completed_windows,
    output logic [31:0]                           dropped_windows
);
    localparam int FRAME_WIDTH = CHANNELS * SAMPLE_WIDTH;
    localparam int ADDR_WIDTH  = $clog2(WINDOW_SAMPLES);
    localparam int CH_WIDTH    = (CHANNELS <= 2) ? 1 : $clog2(CHANNELS);
    localparam int FFT_WIDTH   = $clog2(FFT_LENGTH);

    typedef enum logic [2:0] {
        S_IDLE,
        S_READ,
        S_WAIT_1,
        S_WAIT_2,
        S_MULTIPLY,
        S_SEND
    } scheduler_state_t;

    logic [1:0] bank_ready;
    logic       write_bank;
    logic       active_bank;
    logic [ADDR_WIDTH-1:0] write_index;
    logic [ADDR_WIDTH-1:0] read_address;
    logic [FFT_WIDTH-1:0]  fft_index;
    logic [CH_WIDTH-1:0]   read_channel;
    scheduler_state_t      scheduler_state;

    logic [FRAME_WIDTH-1:0] bank_data [0:1];
    logic [WINDOW_WIDTH-1:0] window_coefficient;
    logic signed [SAMPLE_WIDTH-1:0] selected_sample;
    logic signed [SAMPLE_WIDTH+WINDOW_WIDTH:0] product;
    logic signed [SAMPLE_WIDTH-1:0] scaled_product;
    logic read_enable;

    assign s_axis_frame_tready = !bank_ready[write_bank];
    assign busy = (scheduler_state != S_IDLE) || (bank_ready != 2'b00);
    assign read_enable = (scheduler_state == S_READ) &&
                         (fft_index < WINDOW_SAMPLES);
    assign read_address = fft_index[ADDR_WIDTH-1:0];
    assign selected_sample = $signed(
        bank_data[active_bank][read_channel*SAMPLE_WIDTH +: SAMPLE_WIDTH]
    );
    assign scaled_product = product >>> (WINDOW_WIDTH - 1);

    // A wide memory per bank stores all seven simultaneous channels.  This is
    // materially more BRAM-efficient than fourteen narrow per-channel RAMs,
    // and the 7:1 read mux is paid only once in the shared scheduler.
    for (genvar bank = 0; bank < 2; bank++) begin : g_window_bank
        localparam logic BANK_ID = bank;
        logic unused_sbiterr;
        logic unused_dbiterr;

        xpm_memory_sdpram #(
            .MEMORY_SIZE        (WINDOW_SAMPLES * FRAME_WIDTH),
            .MEMORY_PRIMITIVE   ("block"),
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
            .WRITE_MODE_B       ("no_change")
        ) window_bank_i (
            .sleep          (1'b0),
            .clka           (aclk),
            .ena            (s_axis_frame_tvalid && s_axis_frame_tready &&
                             (write_bank == BANK_ID)),
            .wea            (1'b1),
            .addra          (write_index),
            .dina           (s_axis_frame_tdata),
            .injectsbiterra (1'b0),
            .injectdbiterra (1'b0),
            .clkb           (aclk),
            .rstb           (!aresetn),
            .enb            (read_enable && (active_bank == BANK_ID)),
            .regceb         (1'b1),
            .addrb          (read_address),
            .doutb          (bank_data[bank]),
            .sbiterrb       (unused_sbiterr),
            .dbiterrb       (unused_dbiterr)
        );
    end

    // The same ROM is shared by every channel because the scheduler presents
    // channels serially to one FFT.  Q1.17 coefficients implement a Hann
    // window.  The deterministic initialization file is generated by the A4
    // Tcl flow for the selected analysis window.
    xpm_memory_sprom #(
        .MEMORY_SIZE        (WINDOW_SAMPLES * WINDOW_WIDTH),
        .MEMORY_PRIMITIVE   ("block"),
        .MEMORY_INIT_FILE   (WINDOW_FILE),
        .USE_MEM_INIT       (1),
        .SIM_ASSERT_CHK     (1),
        .READ_DATA_WIDTH_A  (WINDOW_WIDTH),
        .ADDR_WIDTH_A       (ADDR_WIDTH),
        .READ_LATENCY_A     (2)
    ) window_rom_i (
        .sleep          (1'b0),
        .clka           (aclk),
        .rsta           (!aresetn),
        .ena            (read_enable),
        .regcea         (1'b1),
        .addra          (read_address),
        .injectsbiterra (1'b0),
        .injectdbiterra (1'b0),
        .douta          (window_coefficient),
        .sbiterra       (),
        .dbiterra       ()
    );

    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            bank_ready        <= 2'b00;
            write_bank        <= 1'b0;
            active_bank       <= 1'b0;
            write_index       <= '0;
            fft_index         <= '0;
            read_channel      <= '0;
            scheduler_state   <= S_IDLE;
            m_axis_fft_tdata  <= '0;
            m_axis_fft_tvalid <= 1'b0;
            m_axis_fft_tlast  <= 1'b0;
            product           <= '0;
            completed_windows <= '0;
            dropped_windows   <= '0;
        end else begin
            if (s_axis_frame_tvalid && s_axis_frame_tready) begin
                if (write_index == WINDOW_SAMPLES - 1) begin
                    bank_ready[write_bank] <= 1'b1;
                    write_bank             <= !write_bank;
                    write_index            <= '0;
                end else begin
                    write_index <= write_index + 1'b1;
                end
            end else if (s_axis_frame_tvalid && !s_axis_frame_tready) begin
                // The production observer cannot backpressure acquisition.
                // This prototype exposes the overload condition instead of
                // pretending that a missed analysis window was accepted.
                dropped_windows <= dropped_windows + 1'b1;
            end

            case (scheduler_state)
                S_IDLE: begin
                    m_axis_fft_tvalid <= 1'b0;
                    m_axis_fft_tlast  <= 1'b0;
                    if (bank_ready[0]) begin
                        active_bank     <= 1'b0;
                        read_channel    <= '0;
                        fft_index       <= '0;
                        scheduler_state <= S_READ;
                    end else if (bank_ready[1]) begin
                        active_bank     <= 1'b1;
                        read_channel    <= '0;
                        fft_index       <= '0;
                        scheduler_state <= S_READ;
                    end
                end

                S_READ: begin
                    // FFT_LENGTH is a power of two.  Samples after the exact
                    // 10-cycle window are zero padded rather than stored.
                    if (fft_index < WINDOW_SAMPLES)
                        scheduler_state <= S_WAIT_1;
                    else begin
                        scheduler_state <= S_SEND;
                    end
                end

                S_WAIT_1: scheduler_state <= S_WAIT_2;
                S_WAIT_2: scheduler_state <= S_MULTIPLY;

                S_MULTIPLY: begin
                    // Q1.17 window multiplication.  The leading zero makes the
                    // coefficient positive when cast to a signed operand.
                    product <= selected_sample *
                               $signed({1'b0, window_coefficient});
                    scheduler_state <= S_SEND;
                end

                S_SEND: begin
                    if (!m_axis_fft_tvalid) begin
                        m_axis_fft_tdata  <= {
                            {SAMPLE_WIDTH{1'b0}},
                            (fft_index < WINDOW_SAMPLES) ?
                                scaled_product : {SAMPLE_WIDTH{1'b0}}
                        };
                        m_axis_fft_tlast  <= (fft_index == FFT_LENGTH - 1);
                        m_axis_fft_tvalid <= 1'b1;
                    end else if (m_axis_fft_tready) begin
                        m_axis_fft_tvalid <= 1'b0;
                        if (fft_index == FFT_LENGTH - 1) begin
                            if (read_channel == CHANNELS - 1) begin
                                bank_ready[active_bank] <= 1'b0;
                                completed_windows <= completed_windows + 1'b1;
                                scheduler_state <= S_IDLE;
                            end else begin
                                read_channel <= read_channel + 1'b1;
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
