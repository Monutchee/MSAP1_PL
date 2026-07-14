`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 07/14/2026 01:00:15 PM
// Design Name: 
// Module Name: HeatBeat_Controller
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////


module HeartBeat(
    output wire heartbeat
    );


wire clk_raw;
    parameter c_CNT_10HZ = 10_000_000;
    reg [$clog2(c_CNT_10HZ)-1:0] count = 0;
    reg clk_10Hz = 0;

   //Setup the internal oscillator clock as the clock source
   STARTUPE3 #(
   )
   STARTUPE3_inst (
      .CFGMCLK(clk_raw)     // 1-bit output: Configuration internal oscillator clock output.
   );

   // Divide to 100Mhz clock to 10Hz
   always @(posedge clk_raw) begin
      count <= count + 1;
      if (count == c_CNT_10HZ-1) begin
           clk_10Hz<= !clk_10Hz;
           count <= 0;
      end
   end

   //Connect to led unit verilog
   assign heartbeat = clk_10Hz;

endmodule
