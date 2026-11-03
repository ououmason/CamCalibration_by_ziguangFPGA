`timescale 1ns/1ps
`default_nettype none
// Causal 3x3 minimum. RAMs require synchronous READ_FIRST behavior.
module dark_tunnel #(
    parameter integer IMAGE_WIDTH = 1920,
    parameter [7:0] A_INIT = 8'd255
)(
    input wire clk, rst_n,
    input wire vsync_in, hsync_in, de_in,
    input wire [23:0] pix_in_I,
    output reg vsync_out, hsync_out, de_out,
    output reg [23:0] pix_out_I,
    output reg [7:0] pix_out_I_dark,
    output reg [7:0] A_prev,
    output wire [7:0] A_now
);
    localparam integer AW = (IMAGE_WIDTH <= 1) ? 1 : $clog2(IMAGE_WIDTH);
    function [7:0] mn;
        input [7:0] a,b;
        begin mn = (a < b) ? a : b; end
    endfunction
    function [7:0] mx;
        input [7:0] a,b;
        begin mx = (a > b) ? a : b; end
    endfunction
    wire [7:0] pmin = mn(mn(pix_in_I[23:16],pix_in_I[15:8]),pix_in_I[7:0]);
    wire [7:0] pmax = mx(mx(pix_in_I[23:16],pix_in_I[15:8]),pix_in_I[7:0]);
    reg [AW-1:0] x;
    reg [1:0] rows;
    reg bank, vs_d, seen;
    reg [7:0] left1,left2,frame_max,air;
    wire sof = vsync_in && !vs_d;
    wire [7:0] horizontal = (x == 0) ? pmin :
                              (x == 1) ? mn(pmin,left1) : mn(pmin,mn(left1,left2));
    reg [7:0] line0 [0:IMAGE_WIDTH-1];
    reg [7:0] line1 [0:IMAGE_WIDTH-1];
    reg [7:0] q0,q1,h_d,a_d;
    reg [1:0] rows_d;
    reg [23:0] rgb_d;
    reg v_d,h_sync_d,en_d;
    assign A_now = frame_max;
    // No RAM reset: row count masks stale/uninitialized data each frame.
    always @(posedge clk) begin
        if (rst_n && de_in && !sof) begin
            q0 <= line0[x];
            q1 <= line1[x];
            if (!bank) line0[x] <= horizontal;
            else       line1[x] <= horizontal;
        end
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x<=0; rows<=0; bank<=0; vs_d<=0; seen<=0;
            left1<=0; left2<=0; frame_max<=0;
            air <= (A_INIT == 0) ? 8'd1 : A_INIT;
            h_d<=0; a_d<=0; rows_d<=0; rgb_d<=0;
            v_d<=0; h_sync_d<=0; en_d<=0;
            vsync_out<=0; hsync_out<=0; de_out<=0;
            pix_out_I<=0; pix_out_I_dark<=0; A_prev<=0;
        end else begin
            vs_d <= vsync_in;
            if (sof) begin
                x<=0; rows<=0; bank<=0; seen<=0; frame_max<=0;
                left1<=0; left2<=0;
                if (seen) air <= (frame_max == 0) ? 8'd1 : frame_max;
            end else if (de_in) begin
                seen<=1;
                frame_max<=mx(frame_max,pmax);
                left2<=left1; left1<=pmin;
                if (x == IMAGE_WIDTH-1) begin
                    x<=0; bank<=!bank;
                    if (rows != 2) rows<=rows+1'b1;
                end else x<=x+1'b1;
            end
            h_d<=horizontal; rows_d<=rows; rgb_d<=pix_in_I; a_d<=air;
            v_d<=vsync_in; h_sync_d<=hsync_in; en_d<=de_in && !sof;
            vsync_out<=v_d; hsync_out<=h_sync_d; de_out<=en_d;
            pix_out_I<=rgb_d; A_prev<=a_d;
            if (rows_d == 0) pix_out_I_dark<=h_d;
            else if (rows_d == 1) pix_out_I_dark<=mn(h_d,q0);
            else pix_out_I_dark<=mn(h_d,mn(q0,q1));
        end
    end
endmodule
`default_nettype wire
