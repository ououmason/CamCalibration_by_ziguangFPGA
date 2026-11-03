`timescale 1ns/1ps
// Simulation only. Replace these modules with vendor IP in the FPGA project.
module he_hist_ram(
    input wire clock,wren,
    input wire [7:0] wraddress,rdaddress,
    input wire [31:0] data,
    output reg [31:0] q
);
    reg [31:0] mem[0:255];
    always @(posedge clock) begin
        q<=mem[rdaddress];
        if(wren) mem[wraddress]<=data;
    end
endmodule
module he_map_ram(
    input wire clock,wren,
    input wire [8:0] wraddress,rdaddress,
    input wire [7:0] data,
    output reg [7:0] q
);
    reg [7:0] mem[0:511];
    always @(posedge clock) begin
        q<=mem[rdaddress];
        if(wren) mem[wraddress]<=data;
    end
endmodule
