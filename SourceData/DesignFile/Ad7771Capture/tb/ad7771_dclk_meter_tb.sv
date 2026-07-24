`timescale 1ns / 1ps

module ad7771_dclk_meter_tb;

    logic        reference_clk = 1'b0;
    logic        reference_resetn = 1'b0;
    logic        adc_dclk = 1'b0;
    logic        adc_drdy_n = 1'b1;
    logic [31:0] dclk_frequency_hz;
    logic        dclk_valid;
    logic [31:0] drdy_frequency_hz;
    logic        drdy_valid;

    always #5  reference_clk = ~reference_clk;
    always #20 adc_dclk = ~adc_dclk;

    ad7771_dclk_meter #(
        // Scale the production one-second observation interval down to 100
        // reference-clock cycles so the same snapshot logic simulates quickly.
        .REFERENCE_CLOCK_HZ(100)
    ) dut (
        .reference_clk,
        .reference_resetn,
        .adc_dclk,
        .adc_drdy_n,
        .frequency_hz_o(dclk_frequency_hz),
        .valid_o(dclk_valid),
        .drdy_frequency_hz_o(drdy_frequency_hz),
        .drdy_valid_o(drdy_valid)
    );

    // Generate one qualified DRDY_N high-to-low transition every eight DCLK
    // cycles. A one-microsecond simulated measurement window therefore
    // observes three or four transitions, depending on the CDC boundary.
    initial begin : generate_drdy
        forever begin
            repeat (7) @(negedge adc_dclk);
            adc_drdy_n <= 1'b0;
            @(negedge adc_dclk);
            adc_drdy_n <= 1'b1;
        end
    end

    initial begin : watchdog
        #20_000;
        $fatal(1, "DCLK/DRDY meter test timed out");
    end

    initial begin
        repeat (8) @(posedge reference_clk);
        reference_resetn <= 1'b1;

        wait (dclk_valid && drdy_valid);
        @(posedge reference_clk);

        if (dclk_frequency_hz < 32'd24 ||
            dclk_frequency_hz > 32'd26)
            $fatal(1, "DCLK measurement mismatch: %0d",
                   dclk_frequency_hz);
        if (drdy_frequency_hz < 32'd3 ||
            drdy_frequency_hz > 32'd4)
            $fatal(1, "DRDY measurement mismatch: %0d",
                   drdy_frequency_hz);

        $display("PASS: ad7771_dclk_meter_tb");
        $finish;
    end

endmodule
