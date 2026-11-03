`timescale 1ns/1ps
`default_nettype none
// RGB -> YUV (3) -> HE (1) -> RGB (4): eight registers in both modes.
module he_video #(
    parameter integer IMAGE_WIDTH=1920,
    parameter integer IMAGE_HEIGHT=1080
)(
    input wire clk, rst_n, enable_async,
    input wire vs_in, hs_in, de_in,
    input wire [23:0] rgb_in,
    output wire vs_out, hs_out, de_out,
    output wire [23:0] rgb_out
);
    (* async_reg="true" *) reg [1:0] enable_sync;
    reg enabled,vs_d;
    reg [7:0] enable_pipe;
    reg [23:0] raw_pipe[0:7];
    reg [7:0] u_q,v_q;
    reg [3:0] valid_pipe;
    integer i;
    wire yv,yh,yd,hv,hh,hd,map_valid;
    wire [7:0] y,u,v,equalized_y;
    wire [23:0] processed;

    rgb2yuv to_yuv(
        .clk(clk),.rst_n(rst_n),.r_in(rgb_in[23:16]),.g_in(rgb_in[15:8]),.b_in(rgb_in[7:0]),
        .vs_in(vs_in),.hs_in(hs_in),.de_in(de_in),
        .y_out(y),.u_out(u),.v_out(v),.vs_out(yv),.hs_out(yh),.de_out(yd),
        .video_enhance_lightdown_num(8'd0),.video_enhance_lightdown_sw(1'b0),
        .video_enhance_darkup_num(8'd0),.video_enhance_darkup_sw(1'b0));
    hist_equalization #(.H_DISP(IMAGE_WIDTH),.V_DISP(IMAGE_HEIGHT)) equalizer(
        .clk(clk),.rst_n(rst_n),.Y_hsync(yh),.Y_vsync(yv),.Y_data(y),.Y_de(yd),
        .hist_hsync(hh),.hist_vsync(hv),.hist_data(equalized_y),.hist_de(hd),.hist_valid(map_valid));
    yuv2rgb to_rgb(
        .clk(clk),.rst_n(rst_n),.y_in(equalized_y),.u_in(u_q),.v_in(v_q),
        .vs_in(hv),.hs_in(hh),.de_in(hd),.r_out(processed[23:16]),
        .g_out(processed[15:8]),.b_out(processed[7:0]),
        .vs_out(vs_out),.hs_out(hs_out),.de_out(de_out));

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            enable_sync<=0;enabled<=0;vs_d<=0;enable_pipe<=0;
            u_q<=128;v_q<=128;valid_pipe<=0;
            for(i=0;i<8;i=i+1) raw_pipe[i]<=0;
        end else begin
            enable_sync<={enable_sync[0],enable_async};
            vs_d<=vs_in;
            if(vs_in && !vs_d && !de_in) enabled<=enable_sync[1];
            enable_pipe<={enable_pipe[6:0],enabled};
            raw_pipe[0]<=rgb_in;
            for(i=1;i<8;i=i+1) raw_pipe[i]<=raw_pipe[i-1];
            // Chroma follows the one-edge mapping RAM read.
            u_q<=u;v_q<=v;
            valid_pipe<={valid_pipe[2:0],map_valid};
        end
    end
    // Startup and disabled mode preserve exact input RGB, avoiding conversion loss.
    assign rgb_out=de_out ? ((enable_pipe[7] && valid_pipe[3]) ? processed : raw_pipe[7]) : 24'd0;
endmodule
`default_nettype wire
