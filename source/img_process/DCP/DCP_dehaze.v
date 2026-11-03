`timescale 1ns/1ps
`default_nettype none
module DCP_dehaze #(
    parameter integer IMAGE_WIDTH = 1920,
    parameter integer T_MIN = 38,
    parameter [7:0] A_INIT = 8'd255
)(
    input wire clk, rst_n,
    input wire vsync_in, hsync_in, de_in,
    input wire [23:0] pix_in_I,
    output wire vsync_out, hsync_out, de_out,
    output wire [23:0] pix_out_J,
    output wire [7:0] A_now
);
    // synthesis translate_off
    initial begin
        if (IMAGE_WIDTH < 1) $fatal(1,"IMAGE_WIDTH must be >= 1");
        if (T_MIN < 16 || T_MIN > 256) $fatal(1,"T_MIN must be 16..256");
    end
    // synthesis translate_on
    wire v0,h0,e0,v1,h1,e1;
    wire [23:0] rgb0,rgb1;
    wire [7:0] dark,air0,air1;
    wire [8:0] transmission;
    dark_tunnel #(.IMAGE_WIDTH(IMAGE_WIDTH),.A_INIT(A_INIT)) dark_stage(
        .clk(clk),.rst_n(rst_n),.vsync_in(vsync_in),.hsync_in(hsync_in),.de_in(de_in),
        .pix_in_I(pix_in_I),.vsync_out(v0),.hsync_out(h0),.de_out(e0),
        .pix_out_I(rgb0),.pix_out_I_dark(dark),.A_prev(air0),.A_now(A_now));
    t_computer #(.T_MIN(T_MIN)) t_stage(
        .clk(clk),.rst_n(rst_n),.vsync_in(v0),.hsync_in(h0),.de_in(e0),
        .pix_in_I(rgb0),.pix_in_I_dark(dark),.A_prev(air0),
        .vsync_out(v1),.hsync_out(h1),.de_out(e1),.pix_out_I(rgb1),.A_out(air1),.t(transmission));
    J_recovery #(.T_MIN(T_MIN)) recovery_stage(
        .clk(clk),.rst_n(rst_n),.vsync_in(v1),.hsync_in(h1),.de_in(e1),
        .pix_in_I(rgb1),.A_prev(air1),.t(transmission),
        .vsync_out(vsync_out),.hsync_out(hsync_out),.de_out(de_out),.pix_out_J(pix_out_J));
endmodule
// Frame-safe bypass: raw RGB is delayed by the same eight registers as DCP.
// enable_async is synchronized here; mode changes only in output VS blanking.
module dcp_output_select (
    input wire clk, rst_n, enable_async,
    input wire vsync_out,
    input wire [23:0] raw_rgb, dehazed_rgb,
    output wire [23:0] rgb_out
);
    (* async_reg = "true" *) reg [1:0] enable_sync;
    reg vs_d, enabled;
    reg [23:0] raw_pipe [0:7];
    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            enable_sync<=0; vs_d<=0; enabled<=0;
            for(i=0;i<8;i=i+1) raw_pipe[i]<=0;
        end else begin
            enable_sync <= {enable_sync[0],enable_async};
            vs_d <= vsync_out;
            if(vsync_out && !vs_d) enabled <= enable_sync[1];
            raw_pipe[0] <= raw_rgb;
            for(i=1;i<8;i=i+1) raw_pipe[i]<=raw_pipe[i-1];
        end
    end
    assign rgb_out = enabled ? dehazed_rgb : raw_pipe[7];
endmodule
`default_nettype wire
