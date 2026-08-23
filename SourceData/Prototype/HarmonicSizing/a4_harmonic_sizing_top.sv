// SPDX-License-Identifier: MIT
// Standalone A4 wrapper around SpectralFrontend and one AMD FFT IP instance.

`timescale 1ns/1ps

`ifndef A4_FFT_LENGTH
`define A4_FFT_LENGTH 4096
`endif

`ifndef A4_WINDOW_SAMPLES
`define A4_WINDOW_SAMPLES 3200
`endif

module a4_harmonic_sizing_top (
    input  logic             aclk,
    input  logic             aresetn,
    input  logic [167:0]     s_axis_frame_tdata,
    input  logic             s_axis_frame_tvalid,
    output logic             s_axis_frame_tready,
    output logic [47:0]      m_axis_fft_tdata,
    output logic             m_axis_fft_tvalid,
    input  logic             m_axis_fft_tready,
    output logic             m_axis_fft_tlast,
    output logic             frontend_busy,
    output logic [31:0]      completed_windows,
    output logic [31:0]      dropped_windows,
    output logic [5:0]       fft_events
);
    logic [47:0] fft_input_data;
    logic        fft_input_valid;
    logic        fft_input_ready;
    logic        fft_input_last;
    logic        fft_config_valid;
    logic        fft_config_ready;

    always_ff @(posedge aclk) begin
        if (!aresetn)
            fft_config_valid <= 1'b1;
        else if (fft_config_valid && fft_config_ready)
            fft_config_valid <= 1'b0;
    end

    spectral_frontend #(
        .CHANNELS       (7),
        .SAMPLE_WIDTH   (24),
        .WINDOW_WIDTH   (18),
        .WINDOW_SAMPLES (`A4_WINDOW_SAMPLES),
        .FFT_LENGTH     (`A4_FFT_LENGTH),
        .WINDOW_FILE    ("hann.mem")
    ) frontend_i (
        .aclk                (aclk),
        .aresetn             (aresetn),
        .s_axis_frame_tdata  (s_axis_frame_tdata),
        .s_axis_frame_tvalid (s_axis_frame_tvalid),
        .s_axis_frame_tready (s_axis_frame_tready),
        .m_axis_fft_tdata    (fft_input_data),
        .m_axis_fft_tvalid   (fft_input_valid),
        .m_axis_fft_tready   (fft_input_ready),
        .m_axis_fft_tlast    (fft_input_last),
        .busy                (frontend_busy),
        .completed_windows   (completed_windows),
        .dropped_windows     (dropped_windows)
    );

    // Forward transform with a conservative per-stage scaling schedule.  A4
    // measures storage/compute resources; M15 will define the normative
    // block-floating/scaling contract together with bin calibration.
    a4_xfft fft_i (
        .aclk                         (aclk),
        .aresetn                      (aresetn),
        .s_axis_config_tdata          (32'h5555_5501),
        .s_axis_config_tvalid         (fft_config_valid),
        .s_axis_config_tready         (fft_config_ready),
        .s_axis_data_tdata            (fft_input_data),
        .s_axis_data_tvalid           (fft_input_valid),
        .s_axis_data_tready           (fft_input_ready),
        .s_axis_data_tlast            (fft_input_last),
        .m_axis_data_tdata            (m_axis_fft_tdata),
        .m_axis_data_tvalid           (m_axis_fft_tvalid),
        .m_axis_data_tready           (m_axis_fft_tready),
        .m_axis_data_tlast            (m_axis_fft_tlast),
        .event_frame_started          (fft_events[0]),
        .event_tlast_unexpected       (fft_events[1]),
        .event_tlast_missing          (fft_events[2]),
        .event_status_channel_halt    (fft_events[3]),
        .event_data_in_channel_halt   (fft_events[4]),
        .event_data_out_channel_halt  (fft_events[5])
    );
endmodule
