`timescale 1ns/1ps

module meter_record_axis_switch_tb;
    localparam int SOURCE_COUNT = 4;
    localparam int PACKETS_PER_SOURCE = 3;
    localparam int WORDS_PER_PACKET = 64;

    logic aclk = 1'b0;
    logic aresetn = 1'b0;
    logic [SOURCE_COUNT-1:0] s_axis_tvalid;
    wire  [SOURCE_COUNT-1:0] s_axis_tready;
    logic [SOURCE_COUNT*32-1:0] s_axis_tdata;
    logic [SOURCE_COUNT*4-1:0] s_axis_tkeep;
    logic [SOURCE_COUNT-1:0] s_axis_tlast;
    wire  [0:0] m_axis_tvalid;
    logic [0:0] m_axis_tready;
    wire  [31:0] m_axis_tdata;
    wire  [3:0] m_axis_tkeep;
    wire  [0:0] m_axis_tlast;
    wire  [SOURCE_COUNT-1:0] s_decode_err;

    int input_packet [0:SOURCE_COUNT-1];
    int input_word [0:SOURCE_COUNT-1];
    int output_packet [0:SOURCE_COUNT-1];
    int output_word [0:SOURCE_COUNT-1];
    int received_packets [0:SOURCE_COUNT-1];
    int active_source = -1;
    int last_packet_source = -1;
    int total_packets = 0;
    int cycle_count = 0;
    logic [15:0] ready_lfsr = 16'h1ace;
    logic test_passed = 1'b0;

    always #5 aclk = ~aclk;

    meter_record_axis_switch dut (
        .aclk(aclk),
        .aresetn(aresetn),
        .s_axis_tvalid(s_axis_tvalid),
        .s_axis_tready(s_axis_tready),
        .s_axis_tdata(s_axis_tdata),
        .s_axis_tkeep(s_axis_tkeep),
        .s_axis_tlast(s_axis_tlast),
        .m_axis_tvalid(m_axis_tvalid),
        .m_axis_tready(m_axis_tready),
        .m_axis_tdata(m_axis_tdata),
        .m_axis_tkeep(m_axis_tkeep),
        .m_axis_tlast(m_axis_tlast),
        .s_req_suppress('0),
        .s_decode_err(s_decode_err)
    );

    always_comb begin
        s_axis_tvalid = '0;
        s_axis_tdata = '0;
        s_axis_tkeep = '0;
        s_axis_tlast = '0;
        for (int source = 0; source < SOURCE_COUNT; source++) begin
            if (input_packet[source] < PACKETS_PER_SOURCE) begin
                s_axis_tvalid[source] = 1'b1;
                s_axis_tdata[source*32 +: 32] =
                    32'ha0000000 | (source << 24) |
                    (input_packet[source] << 16) | input_word[source];
                s_axis_tkeep[source*4 +: 4] = 4'hf;
                s_axis_tlast[source] =
                    (input_word[source] == WORDS_PER_PACKET-1);
            end
        end
    end

    initial begin
        repeat (10) @(posedge aclk);
        aresetn <= 1'b1;
    end

    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            ready_lfsr <= 16'h1ace;
            m_axis_tready <= 1'b0;
            cycle_count <= 0;
            for (int source = 0; source < SOURCE_COUNT; source++) begin
                input_packet[source] <= 0;
                input_word[source] <= 0;
            end
        end else begin
            ready_lfsr <= {ready_lfsr[14:0],
                           ready_lfsr[15] ^ ready_lfsr[13] ^
                           ready_lfsr[12] ^ ready_lfsr[10]};
            // Deterministic randomized backpressure, ready on roughly 75% of
            // cycles. No source observes READY unless it owns arbitration.
            m_axis_tready <= ready_lfsr[0] | ready_lfsr[3];
            cycle_count <= cycle_count + 1;
            if (cycle_count > 20000) begin
                $fatal(1, "Timeout: not every active input received service");
            end
            if (s_decode_err != '0) begin
                $fatal(1, "Unexpected AXIS switch decode error %b", s_decode_err);
            end
            for (int source = 0; source < SOURCE_COUNT; source++) begin
                if (s_axis_tvalid[source] && s_axis_tready[source]) begin
                    if (input_word[source] == WORDS_PER_PACKET-1) begin
                        input_word[source] <= 0;
                        input_packet[source] <= input_packet[source] + 1;
                    end else begin
                        input_word[source] <= input_word[source] + 1;
                    end
                end
            end
        end
    end

    always_ff @(posedge aclk) begin : output_scoreboard
        int source;
        int minimum_count;
        int maximum_count;
        logic [31:0] expected_data;

        if (!aresetn) begin
            active_source = -1;
            last_packet_source = -1;
            total_packets = 0;
            test_passed = 1'b0;
            for (int index = 0; index < SOURCE_COUNT; index++) begin
                output_packet[index] = 0;
                output_word[index] = 0;
                received_packets[index] = 0;
            end
        end else if (m_axis_tvalid[0] && m_axis_tready[0]) begin
            source = m_axis_tdata[31:24] - 8'ha0;
            if (source < 0 || source >= SOURCE_COUNT) begin
                $fatal(1, "Invalid source tag in %08x", m_axis_tdata);
            end
            expected_data = 32'ha0000000 | (source << 24) |
                            (output_packet[source] << 16) |
                            output_word[source];
            if (m_axis_tdata !== expected_data) begin
                $fatal(1, "Data/provenance mismatch: got %08x expected %08x",
                       m_axis_tdata, expected_data);
            end
            if (m_axis_tkeep !== 4'hf) begin
                $fatal(1, "TKEEP changed inside record: %x", m_axis_tkeep);
            end

            if (output_word[source] == 0) begin
                if (active_source != -1) begin
                    $fatal(1, "New packet began before prior packet TLAST");
                end
                if (source == last_packet_source) begin
                    $fatal(1, "True Round-Robin serviced source %0d twice in a row",
                           source);
                end
                active_source = source;
            end else if (active_source != source) begin
                $fatal(1, "Beat interleaving: active %0d, observed %0d",
                       active_source, source);
            end

            if (output_word[source] == WORDS_PER_PACKET-1) begin
                if (!m_axis_tlast[0]) begin
                    $fatal(1, "Missing TLAST on source %0d packet %0d",
                           source, output_packet[source]);
                end
                output_word[source] = 0;
                output_packet[source] = output_packet[source] + 1;
                received_packets[source] = received_packets[source] + 1;
                total_packets = total_packets + 1;
                active_source = -1;
                last_packet_source = source;

                minimum_count = received_packets[0];
                maximum_count = received_packets[0];
                for (int index = 1; index < SOURCE_COUNT; index++) begin
                    if (received_packets[index] < minimum_count)
                        minimum_count = received_packets[index];
                    if (received_packets[index] > maximum_count)
                        maximum_count = received_packets[index];
                end
                if (maximum_count - minimum_count > 1) begin
                    $fatal(1, "Round-Robin service skew exceeded one packet");
                end

                if (total_packets == SOURCE_COUNT*PACKETS_PER_SOURCE) begin
                    for (int index = 0; index < SOURCE_COUNT; index++) begin
                        if (received_packets[index] != PACKETS_PER_SOURCE) begin
                            $fatal(1, "Source %0d received only %0d packets",
                                   index, received_packets[index]);
                        end
                    end
                    test_passed = 1'b1;
                    $display("PASS: meter_record_axis_switch_tb");
                    $finish;
                end
            end else begin
                if (m_axis_tlast[0]) begin
                    $fatal(1, "Early TLAST on source %0d word %0d",
                           source, output_word[source]);
                end
                output_word[source] = output_word[source] + 1;
            end
        end
    end
endmodule
