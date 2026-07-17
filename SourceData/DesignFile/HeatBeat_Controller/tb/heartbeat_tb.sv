`timescale 1ns/1ps

module heartbeat_tb;
    logic clk = 1'b0;
    logic reset_n = 1'b0;
    wire heartbeat;

    always #5ns clk = ~clk;

    // Eight hertz produces a four-cycle half period at a one-hertz blink rate.
    HeartBeat #(
        .c_CLK_FREQ_HZ(8),
        .c_BLINK_HZ(1)
    ) dut (
        .clk(clk),
        .reset_n(reset_n),
        .heartbeat(heartbeat)
    );

    initial begin
        #1ns;
        if (heartbeat !== 1'b0)
            $fatal(1, "heartbeat did not initialize low");

        repeat (2) @(posedge clk);
        @(negedge clk);
        reset_n = 1'b1;

        repeat (3) @(posedge clk);
        #1ns;
        if (heartbeat !== 1'b0)
            $fatal(1, "heartbeat toggled before four active clock edges");

        @(posedge clk);
        #1ns;
        if (heartbeat !== 1'b1)
            $fatal(1, "heartbeat did not rise on the fourth active clock edge");

        repeat (4) @(posedge clk);
        #1ns;
        if (heartbeat !== 1'b0)
            $fatal(1, "heartbeat did not fall after the next half period");

        reset_n = 1'b0;
        #1ns;
        if (heartbeat !== 1'b0)
            $fatal(1, "heartbeat did not clear while reset was asserted");

        $display("PASS: heartbeat_tb");
        $finish;
    end
endmodule
