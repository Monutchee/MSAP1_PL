`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 07/14/2026 01:27:33 PM
// Design Name: 
// Module Name: HeatBeat_Wrapper
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


module HeatBeat_Wrapper(
    output wire heartbeat
    );
    
    HeartBeat u_heartbeat (
        .heartbeat(heartbeat)
    );
endmodule