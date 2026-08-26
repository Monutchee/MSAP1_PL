// SPDX-License-Identifier: MIT
//
// M16 streaming anti-alias/rational conditioner.
//
// The production profile accepts the preserved seven raw signed 24-bit ADC
// lanes at 32 kframe/s and emits 4,096 simultaneous real samples for an exact
// 6,400-frame 10/12-cycle basic block. It is a 16/25 rational resampler with
// a 1,025-tap, 16-phase, Q20 Kaiser low-pass prototype. Only one 65-tap phase
// is evaluated per output, using one time-shared multiplier over seven lanes.
// The composite passband is flat through 7.62 kHz and the first alias band is
// below -79 dB; every phase is normalized to exact unity DC gain.
//
// The prototype group delay is exactly 32 source frames. Delaying the block
// markers by that amount makes output sample n correspond to source position
// n*25/16 while retaining the original block's provenance. This branch is
// observational and has no input READY. A phase costs 65*7=455 clocks, well
// below the 3,124-clock minimum frame spacing at 32 kSPS/99.999 MHz. Any
// violated service interval is counted and invalidates the affected window.

`timescale 1ns/1ps

module meter_spectral_conditioner #(
    parameter int CHANNELS               = 7,
    parameter int SAMPLE_WIDTH           = 24,
    parameter int CONTEXT_BITS           = 576,
    parameter int EXPECTED_SOURCE_FRAMES = 6400,
    parameter int OUTPUT_FRAMES          = 4096,
    parameter int SOURCE_RATE_HZ         = 32000
) (
    input  logic                             aclk,
    input  logic                             aresetn,

    input  logic                             frame_accept_i,
    input  logic [255:0]                     raw_frame_i,
    input  logic [383:0]                     frame_user_i,
    input  logic                             frame_closes_block_i,

    input  logic                             grid_locked_i,
    input  logic [7:0]                       grid_nominal_hz_i,
    input  logic [7:0]                       grid_cycle_count_i,
    input  logic                             config_enable_i,
    input  logic                             config_apply_toggle_i,
    input  logic [31:0]                      source_frame_rate_i,
    input  logic                             source_frame_rate_valid_i,
    input  logic [31:0]                      frequency_millihz_i,
    input  logic                             frequency_valid_i,
    input  logic [255:0]                     active_scale_q16_i,
    input  logic [31:0]                      emit_drops_i,

    output logic [CONTEXT_BITS-1:0]          m_axis_context_tdata,
    output logic                             m_axis_context_tvalid,
    input  logic                             m_axis_context_tready,

    output logic [CHANNELS*SAMPLE_WIDTH-1:0] m_axis_frame_tdata,
    output logic                             m_axis_frame_tvalid,
    input  logic                             m_axis_frame_tready,
    output logic                             m_axis_frame_tlast,
    output logic                             m_axis_frame_fault,

    output logic [31:0]                      completed_blocks_o,
    output logic [31:0]                      invalid_blocks_o,
    output logic [31:0]                      service_overruns_o
);
    localparam int PHASE_COUNT      = 16;
    localparam int PHASE_TAPS       = 65;
    localparam int PROTOTYPE_TAPS   = 1025;
    localparam int FILTER_DELAY     = 32;
    localparam int COEFFICIENT_BITS = 21;
    localparam int COEFFICIENT_FRAC = 20;
    localparam int RATE_NUMERATOR   = 16;
    localparam int RATE_DENOMINATOR = 25;
    localparam int FRAME_WIDTH      = CHANNELS * SAMPLE_WIDTH;
    localparam int ROM_WORDS        = PHASE_COUNT * PHASE_TAPS;

    typedef enum logic [2:0] {
        S_IDLE,
        S_DECIDE,
        S_PREFETCH,
        S_MAC,
        S_STORE,
        S_CLOSE
    } state_t;
    state_t state;

    logic signed [SAMPLE_WIDTH-1:0] history [0:CHANNELS-1][0:PHASE_TAPS-1];
    logic [$clog2(PHASE_TAPS)-1:0] write_pointer;
    logic [$clog2(PHASE_TAPS)-1:0] captured_pointer;
    logic [$clog2(PHASE_TAPS+1)-1:0] history_count;
    logic current_history_valid;

    logic [FILTER_DELAY-1:0] start_delay;
    logic [FILTER_DELAY-1:0] close_delay;
    logic current_delayed_start;
    logic current_delayed_close;

    logic source_start_pending;
    logic [31:0] source_block_count;
    logic [31:0] pending_close_count;
    logic        pending_close_profile_valid;
    logic [31:0] pending_close_generation;
    logic [CONTEXT_BITS-1:0] pending_start_context;
    logic        pending_start_profile_valid;

    logic spectral_synced;
    logic block_active;
    logic block_profile_valid;
    logic [31:0] block_generation;
    logic first_after_discontinuity;
    logic block_service_fault;
    logic [31:0] block_input_count;
    logic [31:0] produced_count;
    logic [31:0] input_index;

    logic [FRAME_WIDTH-1:0] pending_frame;
    logic pending_frame_valid;
    logic [FRAME_WIDTH-1:0] computed_frame;
    logic pending_close_fault;

    logic [31:0] completed_blocks;
    logic [31:0] invalid_blocks;
    logic [31:0] service_overruns;
    logic apply_seen;

    logic [3:0] mac_phase;
    logic [2:0] mac_channel;
    logic [6:0] mac_tap;
    logic [6:0] rom_fetch_tap;
    logic signed [55:0] mac_accumulator;
    logic signed [SAMPLE_WIDTH-1:0] mac_sample;
    logic signed [COEFFICIENT_BITS-1:0] mac_coefficient;
    logic signed [SAMPLE_WIDTH+COEFFICIENT_BITS-1:0] mac_product;
    logic [10:0] coefficient_address;
    logic [COEFFICIENT_BITS-1:0] coefficient_data;
    logic coefficient_enable;
    integer history_address;

    // A synchronous block ROM keeps the 16 independently normalized phases
    // out of LUT muxes. Phases 1..15 have 64 prototype taps and use a zero pad
    // at address 64 so the MAC controller remains constant-latency.
    xpm_memory_sprom #(
        .MEMORY_SIZE         (ROM_WORDS * COEFFICIENT_BITS),
        .MEMORY_PRIMITIVE    ("block"),
        .ECC_MODE            ("no_ecc"),
        .MEMORY_INIT_FILE    ("meter_spectral_conditioner_q20.mem"),
        .MEMORY_INIT_PARAM   (""),
        .USE_MEM_INIT        (1),
        .WAKEUP_TIME         ("disable_sleep"),
        .AUTO_SLEEP_TIME     (0),
        .MESSAGE_CONTROL     (0),
        .MEMORY_OPTIMIZATION ("true"),
        .CASCADE_HEIGHT      (0),
        .SIM_ASSERT_CHK      (1),
        .READ_DATA_WIDTH_A   (COEFFICIENT_BITS),
        .ADDR_WIDTH_A        (11),
        .READ_RESET_VALUE_A  ("0"),
        .READ_LATENCY_A      (1),
        .RST_MODE_A          ("SYNC")
    ) coefficient_rom (
        .sleep          (1'b0),
        .clka           (aclk),
        .rsta           (!aresetn),
        .ena            (coefficient_enable),
        .regcea         (1'b1),
        .addra          (coefficient_address),
        .injectsbiterra (1'b0),
        .injectdbiterra (1'b0),
        .douta          (coefficient_data),
        .sbiterra       (),
        .dbiterra       ()
    );

    function automatic logic signed [SAMPLE_WIDTH-1:0] polyphase_saturate(
        input logic signed [55:0] accumulated);
        logic signed [55:0] shifted;
        begin
            shifted = accumulated >>> COEFFICIENT_FRAC;
            if (shifted > 56'sd8388607)
                polyphase_saturate = 24'sh7fffff;
            else if (shifted < -56'sd8388608)
                polyphase_saturate = 24'sh800000;
            else
                polyphase_saturate = shifted[SAMPLE_WIDTH-1:0];
        end
    endfunction

    function automatic logic profile_is_qualified(
        input logic locked,
        input logic [7:0] nominal,
        input logic [7:0] cycles,
        input logic enabled,
        input logic [31:0] frame_rate,
        input logic frame_rate_valid,
        input logic frequency_valid);
        begin
            profile_is_qualified = enabled && locked && frame_rate_valid &&
                frequency_valid && frame_rate == SOURCE_RATE_HZ &&
                ((nominal == 8'd50 && cycles == 8'd10) ||
                 (nominal == 8'd60 && cycles == 8'd12));
        end
    endfunction

    initial begin
        if (CHANNELS != 7 || SAMPLE_WIDTH != 24)
            $error("meter_spectral_conditioner production geometry is 7x24-bit");
        if (EXPECTED_SOURCE_FRAMES * RATE_NUMERATOR !=
            OUTPUT_FRAMES * RATE_DENOMINATOR)
            $error("conditioner source/output geometry is not an exact 16/25 ratio");
        if (CONTEXT_BITS < 576)
            $error("conditioner context is too narrow");
        if (PROTOTYPE_TAPS != PHASE_COUNT * (PHASE_TAPS - 1) + 1)
            $error("conditioner polyphase prototype geometry is inconsistent");
    end

    always_comb begin
        coefficient_address = mac_phase * PHASE_TAPS + rom_fetch_tap;
        history_address = $unsigned(captured_pointer);
        history_address = history_address - $unsigned(mac_tap);
        if (history_address < 0)
            history_address = history_address + PHASE_TAPS;
        mac_sample = history[mac_channel][history_address];
        mac_coefficient = $signed(coefficient_data);
        mac_product = mac_sample * mac_coefficient;
    end

    assign completed_blocks_o = completed_blocks;
    assign invalid_blocks_o = invalid_blocks;
    assign service_overruns_o = service_overruns;

    always_ff @(posedge aclk) begin : conditioner_sequencer
        logic [CONTEXT_BITS-1:0] context_value;
        logic [31:0] accepted_source_count;
        logic start_now;
        logic profile_now;
        logic signed [55:0] accumulated_value;
        logic [31:0] next_input_index;
        logic [31:0] target_numerator;
        logic [31:0] target_input_index;
        logic output_due;
        logic close_geometry_valid;
        logic close_fault;

        if (!aresetn) begin
            state                       <= S_IDLE;
            write_pointer               <= '0;
            captured_pointer            <= '0;
            history_count               <= '0;
            current_history_valid       <= 1'b0;
            start_delay                 <= '0;
            close_delay                 <= '0;
            current_delayed_start       <= 1'b0;
            current_delayed_close       <= 1'b0;
            source_start_pending        <= 1'b1;
            source_block_count          <= '0;
            pending_close_count         <= '0;
            pending_close_profile_valid <= 1'b0;
            pending_close_generation    <= '0;
            pending_start_context       <= '0;
            pending_start_profile_valid <= 1'b0;
            spectral_synced             <= 1'b0;
            block_active                <= 1'b0;
            block_profile_valid         <= 1'b0;
            block_generation            <= '0;
            first_after_discontinuity   <= 1'b1;
            block_service_fault         <= 1'b0;
            block_input_count           <= '0;
            produced_count              <= '0;
            input_index                 <= '0;
            pending_frame               <= '0;
            pending_frame_valid         <= 1'b0;
            computed_frame              <= '0;
            pending_close_fault         <= 1'b0;
            m_axis_context_tdata        <= '0;
            m_axis_context_tvalid       <= 1'b0;
            m_axis_frame_tdata          <= '0;
            m_axis_frame_tvalid         <= 1'b0;
            m_axis_frame_tlast          <= 1'b0;
            m_axis_frame_fault          <= 1'b0;
            completed_blocks            <= '0;
            invalid_blocks              <= '0;
            service_overruns            <= '0;
            apply_seen                  <= 1'b0;
            mac_phase                   <= '0;
            mac_channel                 <= '0;
            mac_tap                     <= '0;
            rom_fetch_tap               <= '0;
            mac_accumulator             <= '0;
            coefficient_enable          <= 1'b0;
            for (int channel = 0; channel < CHANNELS; channel++) begin
                for (int tap = 0; tap < PHASE_TAPS; tap++)
                    history[channel][tap] <= '0;
            end
        end else begin
            if (m_axis_context_tvalid && m_axis_context_tready)
                m_axis_context_tvalid <= 1'b0;
            if (m_axis_frame_tvalid && m_axis_frame_tready) begin
                m_axis_frame_tvalid <= 1'b0;
                m_axis_frame_tlast <= 1'b0;
                m_axis_frame_fault <= 1'b0;
            end

            if (config_apply_toggle_i != apply_seen) begin
                // Keep raw history continuous, but discard marker and phase
                // state so no spectral block spans two configurations.
                apply_seen                  <= config_apply_toggle_i;
                start_delay                 <= '0;
                close_delay                 <= '0;
                current_delayed_start       <= 1'b0;
                current_delayed_close       <= 1'b0;
                source_start_pending        <= 1'b1;
                source_block_count          <= '0;
                spectral_synced             <= 1'b0;
                block_active                <= 1'b0;
                block_profile_valid         <= 1'b0;
                block_generation            <= '0;
                pending_frame_valid         <= 1'b0;
                first_after_discontinuity   <= 1'b1;
                block_service_fault         <= 1'b0;
                coefficient_enable          <= 1'b0;
                state                       <= S_IDLE;
            end else begin
                if (frame_accept_i && state != S_IDLE) begin
                    // Never stall acquisition; mark the affected family bad.
                    if (service_overruns != 32'hffffffff)
                        service_overruns <= service_overruns + 1'b1;
                    block_service_fault <= 1'b1;
                end

                case (state)
                    S_IDLE: begin
                        coefficient_enable <= 1'b0;
                        if (frame_accept_i) begin
                            start_now = source_start_pending;
                            profile_now = profile_is_qualified(
                                grid_locked_i, grid_nominal_hz_i,
                                grid_cycle_count_i, config_enable_i,
                                source_frame_rate_i, source_frame_rate_valid_i,
                                frequency_valid_i);
                            accepted_source_count = start_now
                                ? 32'd1 : source_block_count + 1'b1;

                            for (int channel = 0; channel < CHANNELS; channel++)
                                history[channel][write_pointer] <=
                                    raw_frame_i[channel*32 +: SAMPLE_WIDTH];
                            captured_pointer <= write_pointer;
                            if (write_pointer == PHASE_TAPS - 1)
                                write_pointer <= '0;
                            else
                                write_pointer <= write_pointer + 1'b1;
                            if (history_count < PHASE_TAPS)
                                history_count <= history_count + 1'b1;
                            current_history_valid <=
                                history_count >= PHASE_TAPS - 1;

                            current_delayed_start <=
                                start_delay[FILTER_DELAY-1];
                            current_delayed_close <=
                                close_delay[FILTER_DELAY-1];
                            start_delay <= {
                                start_delay[FILTER_DELAY-2:0], start_now};
                            close_delay <= {
                                close_delay[FILTER_DELAY-2:0],
                                frame_closes_block_i};

                            if (start_now) begin
                                context_value = '0;
                                context_value[31:0] = frame_user_i[63:32];
                                context_value[63:32] = source_frame_rate_i;
                                context_value[95:64] = EXPECTED_SOURCE_FRAMES;
                                context_value[103:96] = frame_user_i[71:64];
                                context_value[111:104] = '0;
                                context_value[119:112] = grid_nominal_hz_i;
                                context_value[127:120] = grid_cycle_count_i;
                                context_value[135:128] = 8'd127;
                                context_value[143:136] = 8'd1;
                                context_value[191:160] = frequency_millihz_i;
                                context_value[255:192] = {
                                    frame_user_i[105:74], frame_user_i[31:0]};
                                context_value[543:320] =
                                    active_scale_q16_i[223:0];
                                pending_start_context <= context_value;
                                pending_start_profile_valid <= profile_now;
                                source_start_pending <= 1'b0;
                            end

                            source_block_count <= accepted_source_count;
                            if (frame_closes_block_i) begin
                                pending_close_count <= accepted_source_count;
                                pending_close_profile_valid <= profile_now;
                                pending_close_generation <= frame_user_i[63:32];
                                source_block_count <= '0;
                                source_start_pending <= 1'b1;
                            end
                            state <= S_DECIDE;
                        end
                    end

                    S_DECIDE: begin
                        if (!current_history_valid) begin
                            state <= S_IDLE;
                        end else if (current_delayed_start && spectral_synced) begin
                            // Reserve the frontend bank before sample zero.
                            if (!m_axis_context_tvalid ||
                                m_axis_context_tready) begin
                                context_value = pending_start_context;
                                context_value[104] = grid_locked_i;
                                context_value[105] =
                                    pending_start_profile_valid;
                                context_value[106] =
                                    first_after_discontinuity;
                                context_value[107] = 1'b0;
                                context_value[287:256] = emit_drops_i;
                                m_axis_context_tdata <= context_value;
                                m_axis_context_tvalid <= 1'b1;

                                block_active <= 1'b1;
                                block_profile_valid <=
                                    pending_start_profile_valid;
                                block_generation <=
                                    pending_start_context[31:0];
                                block_input_count <= 1;
                                produced_count <= '0;
                                input_index <= '0;
                                pending_frame_valid <= 1'b0;
                                mac_phase <= '0;
                                mac_channel <= '0;
                                mac_tap <= '0;
                                rom_fetch_tap <= '0;
                                mac_accumulator <= '0;
                                coefficient_enable <= 1'b1;
                                state <= S_PREFETCH;
                            end
                        end else if (current_delayed_close &&
                                     !spectral_synced) begin
                            // The first complete block primes history and
                            // marker alignment. Publication starts next block.
                            spectral_synced <= 1'b1;
                            block_active <= 1'b0;
                            pending_frame_valid <= 1'b0;
                            first_after_discontinuity <= 1'b1;
                            block_service_fault <= 1'b0;
                            state <= S_IDLE;
                        end else if (block_active) begin
                            next_input_index = input_index + 1'b1;
                            block_input_count <= block_input_count + 1'b1;
                            input_index <= next_input_index;

                            if (current_delayed_close) begin
                                close_geometry_valid =
                                    pending_close_count ==
                                        EXPECTED_SOURCE_FRAMES &&
                                    block_input_count + 1'b1 ==
                                        EXPECTED_SOURCE_FRAMES &&
                                    produced_count == OUTPUT_FRAMES &&
                                    pending_close_profile_valid ==
                                        block_profile_valid &&
                                    pending_close_generation ==
                                        block_generation &&
                                    !block_service_fault;
                                pending_close_fault <=
                                    !close_geometry_valid;
                                coefficient_enable <= 1'b0;
                                state <= S_CLOSE;
                            end else begin
                                target_numerator =
                                    produced_count * RATE_DENOMINATOR;
                                target_input_index =
                                    target_numerator >> 4;
                                output_due = produced_count < OUTPUT_FRAMES &&
                                    target_input_index == next_input_index;
                                if (output_due) begin
                                    mac_phase <= target_numerator[3:0];
                                    mac_channel <= '0;
                                    mac_tap <= '0;
                                    rom_fetch_tap <= '0;
                                    mac_accumulator <= '0;
                                    coefficient_enable <= 1'b1;
                                    state <= S_PREFETCH;
                                end else begin
                                    state <= S_IDLE;
                                end
                            end
                        end else begin
                            state <= S_IDLE;
                        end
                    end

                    // One cycle lets the synchronous ROM return tap zero.
                    S_PREFETCH: begin
                        rom_fetch_tap <= 1;
                        state <= S_MAC;
                    end

                    S_MAC: begin
                        accumulated_value = (mac_tap == 0)
                            ? {{11{mac_product[44]}}, mac_product}
                            : mac_accumulator +
                              {{11{mac_product[44]}}, mac_product};
                        if (mac_tap == PHASE_TAPS - 1) begin
                            computed_frame[
                                mac_channel*SAMPLE_WIDTH +: SAMPLE_WIDTH]
                                <= polyphase_saturate(accumulated_value);
                            mac_accumulator <= '0;
                            mac_tap <= '0;
                            if (mac_channel == CHANNELS - 1) begin
                                mac_channel <= '0;
                                coefficient_enable <= 1'b0;
                                state <= S_STORE;
                            end else begin
                                // Tap zero for the next lane was prefetched
                                // while the final tap accumulated.
                                mac_channel <= mac_channel + 1'b1;
                                rom_fetch_tap <= 1;
                            end
                        end else begin
                            mac_accumulator <= accumulated_value;
                            mac_tap <= mac_tap + 1'b1;
                            if (mac_tap == PHASE_TAPS - 2)
                                rom_fetch_tap <= '0;
                            else
                                rom_fetch_tap <= mac_tap + 2;
                        end
                    end

                    S_STORE: begin
                        if (!m_axis_frame_tvalid || m_axis_frame_tready) begin
                            if (pending_frame_valid) begin
                                m_axis_frame_tdata <= pending_frame;
                                m_axis_frame_tvalid <= 1'b1;
                                m_axis_frame_tlast <= 1'b0;
                                m_axis_frame_fault <= 1'b0;
                            end
                            pending_frame <= computed_frame;
                            pending_frame_valid <= 1'b1;
                            produced_count <= produced_count + 1'b1;
                            state <= S_IDLE;
                        end
                    end

                    S_CLOSE: begin
                        if (!m_axis_frame_tvalid || m_axis_frame_tready) begin
                            close_fault = pending_close_fault ||
                                block_service_fault ||
                                (frame_accept_i && state != S_IDLE);
                            m_axis_frame_tdata <= pending_frame;
                            m_axis_frame_tvalid <= 1'b1;
                            m_axis_frame_tlast <= 1'b1;
                            m_axis_frame_fault <= close_fault;
                            pending_frame_valid <= 1'b0;
                            block_active <= 1'b0;
                            if (!close_fault) begin
                                if (completed_blocks != 32'hffffffff)
                                    completed_blocks <= completed_blocks + 1'b1;
                                first_after_discontinuity <= 1'b0;
                            end else begin
                                if (invalid_blocks != 32'hffffffff)
                                    invalid_blocks <= invalid_blocks + 1'b1;
                                first_after_discontinuity <= 1'b1;
                            end
                            block_service_fault <= 1'b0;
                            state <= S_IDLE;
                        end
                    end

                    default: state <= S_IDLE;
                endcase
            end
        end
    end
endmodule
