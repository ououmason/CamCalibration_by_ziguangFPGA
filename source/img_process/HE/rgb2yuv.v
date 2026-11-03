`timescale 1ns/1ps
`default_nettype none
// BT.601 full range, three registers, rounded and saturated.
module rgb2yuv(
    input wire clk,
    input wire [7:0] r_in,g_in,b_in,
    input wire vs_in,hs_in,de_in,
    output wire [7:0] y_out,u_out,v_out,
    output wire vs_out,hs_out,de_out,
    input wire [7:0] video_enhance_lightdown_num,
    input wire video_enhance_lightdown_sw,
    input wire [7:0] video_enhance_darkup_num,
    input wire video_enhance_darkup_sw,
    input wire rst_n
);
    reg signed [18:0] ys,us,vs,yr,ur,vr;
    reg [7:0] yq,uq,vq;
    reg [2:0] vp,hp,dp;
    wire signed [18:0] r={11'd0,r_in},g={11'd0,g_in},b={11'd0,b_in};
    wire [7:0] add_y=video_enhance_darkup_sw && yq<video_enhance_darkup_num ?
        (video_enhance_darkup_num-yq)>>3 : 8'd0;
    wire [7:0] sub_y=video_enhance_lightdown_sw && yq>video_enhance_lightdown_num ?
        (yq-video_enhance_lightdown_num)>>3 : 8'd0;
    function [7:0] sat;
        input signed [18:0] n;
        begin
            if(n<0) sat=0;
            else if(n>255) sat=255;
            else sat=n[7:0];
        end
    endfunction
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            ys<=0;us<=0;vs<=0;yr<=0;ur<=0;vr<=0;
            yq<=0;uq<=128;vq<=128;vp<=0;hp<=0;dp<=0;
        end else begin
            ys<=77*r+150*g+29*b;
            us<=-43*r-85*g+128*b;
            vs<=128*r-107*g-21*b;
            yr<=ys+19'sd128;
            ur<=us+19'sd32896;
            vr<=vs+19'sd32896;
            yq<=sat(yr>>>8);uq<=sat(ur>>>8);vq<=sat(vr>>>8);
            vp<={vp[1:0],vs_in};hp<={hp[1:0],hs_in};dp<={dp[1:0],de_in};
        end
    end
    assign y_out=sat($signed({11'd0,yq})+$signed({11'd0,add_y})-$signed({11'd0,sub_y}));
    assign u_out=uq;assign v_out=vq;
    assign vs_out=vp[2];assign hs_out=hp[2];assign de_out=dp[2];
endmodule
`default_nettype wire
