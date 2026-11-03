`timescale 1ns/1ps
`default_nettype none
// t is unsigned Q1.8 (256 = 1.0). omega is embedded in dcp_air_lut; regenerate with gen_lut.ps1.
module t_computer #(
    parameter integer T_MIN = 38
)(
    input wire clk, rst_n,
    input wire vsync_in, hsync_in, de_in,
    input wire [23:0] pix_in_I,
    input wire [7:0] pix_in_I_dark, A_prev,
    output wire vsync_out, hsync_out, de_out,
    output wire [23:0] pix_out_I,
    output wire [7:0] A_out,
    output reg [8:0] t
);
    wire [15:0] reciprocal;
    dcp_air_lut lut(.address(A_prev), .value(reciprocal));
    reg [15:0] recip_d;
    reg [7:0] dark_d;
    reg [23:0] product;
    reg [26:0] video [0:2];
    reg [7:0] air [0:2];
    integer i;
    assign {vsync_out,hsync_out,de_out,pix_out_I}=video[2];
    assign A_out=air[2];
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            recip_d<=0; dark_d<=0; product<=0; t<=9'd256;
            for(i=0;i<3;i=i+1) begin video[i]<=0; air[i]<=0; end
        end else begin
            video[0]<={vsync_in,hsync_in,de_in,pix_in_I}; air[0]<=A_prev;
            for(i=1;i<3;i=i+1) begin video[i]<=video[i-1]; air[i]<=air[i-1]; end
            recip_d<=reciprocal; dark_d<=pix_in_I_dark;
            product<=dark_d * recip_d;
            if (product[23:8] >= (256-T_MIN)) t<=T_MIN;
            else t<=9'd256-product[16:8];
        end
    end
endmodule
`default_nettype wire
