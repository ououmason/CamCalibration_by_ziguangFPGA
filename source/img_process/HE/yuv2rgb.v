`timescale 1ns/1ps
`default_nettype none
// BT.601 full range, four registers. Keep signed high bits until saturation.
module yuv2rgb(
    input wire clk,
    input wire [7:0] y_in,u_in,v_in,
    input wire vs_in,hs_in,de_in,
    output reg [7:0] r_out,g_out,b_out,
    output wire vs_out,hs_out,de_out,
    input wire rst_n
);
    wire signed [19:0] du=$signed({12'd0,u_in})-20'sd128;
    wire signed [19:0] dv=$signed({12'd0,v_in})-20'sd128;
    reg signed [19:0] yy,rv,gu,gv,bu;
    reg signed [19:0] rs,gs,bs,rr,gr,br;
    reg [3:0] vp,hp,dp;
    function [7:0] sat;
        input signed [19:0] n;
        begin
            if(n<0) sat=0;
            else if(n>255) sat=255;
            else sat=n[7:0];
        end
    endfunction
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            yy<=0;rv<=0;gu<=0;gv<=0;bu<=0;
            rs<=0;gs<=0;bs<=0;rr<=0;gr<=0;br<=0;
            r_out<=0;g_out<=0;b_out<=0;vp<=0;hp<=0;dp<=0;
        end else begin
            yy<=$signed({12'd0,y_in})*20'sd256;
            rv<=dv*20'sd359;gu<=du*20'sd88;gv<=dv*20'sd183;bu<=du*20'sd454;
            rs<=yy+rv;gs<=yy-gu-gv;bs<=yy+bu;
            rr<=(rs+20'sd128)>>>8;gr<=(gs+20'sd128)>>>8;br<=(bs+20'sd128)>>>8;
            r_out<=sat(rr);g_out<=sat(gr);b_out<=sat(br);
            vp<={vp[2:0],vs_in};hp<={hp[2:0],hs_in};dp<={dp[2:0],de_in};
        end
    end
    assign vs_out=vp[3];assign hs_out=hp[3];assign de_out=dp[3];
endmodule
`default_nettype wire
