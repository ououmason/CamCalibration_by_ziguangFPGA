`timescale 1ns/1ps
`default_nettype none
module J_recovery #(
    parameter integer T_MIN = 38
)(
    input wire clk, rst_n,
    input wire vsync_in, hsync_in, de_in,
    input wire [23:0] pix_in_I,
    input wire [7:0] A_prev,
    input wire [8:0] t,
    output wire vsync_out, hsync_out, de_out,
    output reg [23:0] pix_out_J
);
    // T_MIN must be 16..256; maximum reciprocal is 4096 (13 bits).
    wire [8:0] tc = (t < T_MIN) ? T_MIN : ((t > 256) ? 9'd256 : t);
    wire [12:0] reciprocal;
    dcp_t_lut lut(.address(tc),.value(reciprocal));
    reg signed [8:0] dr,dg,db;
    reg signed [13:0] gain;
    reg signed [22:0] pr,pg,pb;
    reg [7:0] a0,a1;
    reg [2:0] vp,hp,ep;
    function [7:0] restore;
        input signed [22:0] p;
        input [7:0] a;
        reg signed [23:0] result;
        begin
            result = (p >>> 8) + $signed({1'b0,a});
            if (result < 0) restore=0;
            else if (result > 255) restore=255;
            else restore=result[7:0];
        end
    endfunction
    assign vsync_out=vp[2];
    assign hsync_out=hp[2];
    assign de_out=ep[2];
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dr<=0; dg<=0; db<=0; gain<=0;
            pr<=0; pg<=0; pb<=0; a0<=0; a1<=0;
            vp<=0; hp<=0; ep<=0; pix_out_J<=0;
        end else begin
            vp<={vp[1:0],vsync_in}; hp<={hp[1:0],hsync_in}; ep<={ep[1:0],de_in};
            dr<=$signed({1'b0,pix_in_I[23:16]})-$signed({1'b0,A_prev});
            dg<=$signed({1'b0,pix_in_I[15:8]})-$signed({1'b0,A_prev});
            db<=$signed({1'b0,pix_in_I[7:0]})-$signed({1'b0,A_prev});
            gain<=$signed({1'b0,reciprocal}); a0<=A_prev; a1<=a0;
            pr<=dr*gain; pg<=dg*gain; pb<=db*gain;
            pix_out_J<={restore(pr,a1),restore(pg,a1),restore(pb,a1)};
        end
    end
endmodule
`default_nettype wire
