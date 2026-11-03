`timescale 1ns/1ps
// Double-buffered coefficient map. Four parity banks provide four bilinear
// neighbors per clock without four copies of the map. Even GRID_W/H required.
// Align-corners interpolation, as in nn.UpsamplingBilinear2d. 5-clock latency.
module zdce_curve_map #(
    parameter integer IMAGE_W=1920,
    parameter integer IMAGE_H=1080,
    parameter integer GRID_W=30,
    parameter integer GRID_H=18
)(
    input wire clk, input wire rst_n,
    input wire map_we, input wire write_bank,
    input wire [7:0] map_x, input wire [7:0] map_y,
    input wire [47:0] map_data,
    input wire read_bank, input wire map_valid,
    input wire vs_in, input wire hs_in, input wire de_in,
    input wire [23:0] rgb_in,
    output wire vs_out, output wire hs_out, output wire de_out,
    output wire [23:0] rgb_out, output wire [47:0] alpha_out
);
    localparam integer HALF_W=GRID_W/2;
    localparam integer Q=GRID_W*GRID_H/4;
    localparam integer RX=(16777216+(IMAGE_W-1)/2)/(IMAGE_W-1);
    localparam integer RY=(16777216+(IMAGE_H-1)/2)/(IMAGE_H-1);
    (* ram_style="block",syn_ramstyle="block_ram" *) reg [47:0] m00 [0:2*Q-1];
    (* ram_style="block",syn_ramstyle="block_ram" *) reg [47:0] m01 [0:2*Q-1];
    (* ram_style="block",syn_ramstyle="block_ram" *) reg [47:0] m10 [0:2*Q-1];
    (* ram_style="block",syn_ramstyle="block_ram" *) reg [47:0] m11 [0:2*Q-1];
    // Coordinates, data and WE are registered together by the CNN. Avoid
    // combinational division/modulo of its flat address on the RAM port.
    wire [15:0] waddr=write_bank*Q+(map_y>>1)*HALF_W+(map_x>>1);
    reg vs_d;
    reg [11:0] x,y;
    reg [11:0] rx_rem,ry_rem;
    reg [7:0] gx,gy;
    wire [7:0] gx1=(gx==GRID_W-1) ? gx : gx+1'b1;
    wire [7:0] gy1=(gy==GRID_H-1) ? gy : gy+1'b1;
    wire [7:0] even_x=gx[0] ? gx1 : gx;
    wire [7:0] odd_x=gx[0] ? gx : gx1;
    wire [7:0] even_y=gy[0] ? gy1 : gy;
    wire [7:0] odd_y=gy[0] ? gy : gy1;
    wire [15:0] a00=read_bank*Q+(even_y>>1)*HALF_W+(even_x>>1);
    wire [15:0] a01=read_bank*Q+(even_y>>1)*HALF_W+(odd_x>>1);
    wire [15:0] a10=read_bank*Q+(odd_y>>1)*HALF_W+(even_x>>1);
    wire [15:0] a11=read_bank*Q+(odd_y>>1)*HALF_W+(odd_x>>1);
    wire [31:0] fx_scaled=rx_rem*RX+32'd2048;
    wire [31:0] fy_scaled=ry_rem*RY+32'd2048;
    wire [12:0] fx=(fx_scaled[24:12]>4096) ? 13'd4096 : fx_scaled[24:12];
    wire [12:0] fy=(fy_scaled[24:12]>4096) ? 13'd4096 : fy_scaled[24:12];
    wire [12:0] next_rx={1'b0,rx_rem}+GRID_W-1;
    wire [12:0] next_ry={1'b0,ry_rem}+GRID_H-1;
    reg [47:0] q00,q01,q10,q11;
    reg [1:0] select00,select01,select10,select11;
    reg [12:0] fx1,fy1,fy2,fy3;
    reg [4:0] vs_pipe,hs_pipe,de_pipe,valid_pipe;
    reg [23:0] rgb_pipe [0:4];
    function [47:0] select_corner;
        input [1:0] s;
        input [47:0] c00,c01,c10,c11;
        begin case(s)
            0:select_corner=c00; 1:select_corner=c01;
            2:select_corner=c10; default:select_corner=c11;
        endcase end
    endfunction
    wire [47:0] c00=select_corner(select00,q00,q01,q10,q11);
    wire [47:0] c01=select_corner(select01,q00,q01,q10,q11);
    wire [47:0] c10=select_corner(select10,q00,q01,q10,q11);
    wire [47:0] c11=select_corner(select11,q00,q01,q10,q11);
    genvar color;
    generate for(color=0;color<3;color=color+1) begin: interpolate
        wire signed [15:0] p00=c00[color*16+:16];
        wire signed [15:0] p01=c01[color*16+:16];
        wire signed [15:0] p10=c10[color*16+:16];
        wire signed [15:0] p11=c11[color*16+:16];
        wire signed [16:0] top_diff=$signed({p01[15],p01})-$signed({p00[15],p00});
        wire signed [16:0] bot_diff=$signed({p11[15],p11})-$signed({p10[15],p10});
        reg signed [30:0] top_product,bot_product,vert_product;
        reg signed [15:0] top_base2,bot_base2,top3,bot3,top4,alpha5;
        wire signed [16:0] vert_diff=$signed({bot3[15],bot3})-$signed({top3[15],top3});
        wire signed [31:0] top_step=($signed({top_product[30],top_product})+32'sd2048)>>>12;
        wire signed [31:0] bot_step=($signed({bot_product[30],bot_product})+32'sd2048)>>>12;
        wire signed [31:0] vert_step=($signed({vert_product[30],vert_product})+32'sd2048)>>>12;
        always @(posedge clk) begin
            if(!rst_n) begin
                top_product<=0; bot_product<=0; vert_product<=0;
                top_base2<=0; bot_base2<=0; top3<=0; bot3<=0; top4<=0; alpha5<=0;
            end else begin
                top_product<=top_diff*$signed({1'b0,fx1});
                bot_product<=bot_diff*$signed({1'b0,fx1});
                top_base2<=p00; bot_base2<=p10;
                top3<=top_base2+top_step; bot3<=bot_base2+bot_step;
                vert_product<=vert_diff*$signed({1'b0,fy3}); top4<=top3;
                alpha5<=top4+vert_step;
            end
        end
        assign alpha_out[color*16+:16]=valid_pipe[4] ? alpha5 : 16'd0;
    end endgenerate
    integer i;
    always @(posedge clk) begin
        if(map_we) begin
            case({map_y[0],map_x[0]})
                0:m00[waddr]<=map_data;
                1:m01[waddr]<=map_data;
                2:m10[waddr]<=map_data;
                3:m11[waddr]<=map_data;
            endcase
        end
        if(de_in) begin
            q00<=m00[a00]; q01<=m01[a01]; q10<=m10[a10]; q11<=m11[a11];
        end
    end
    always @(posedge clk) begin
        if(!rst_n) begin
            vs_d<=0; x<=0; y<=0; gx<=0; gy<=0; rx_rem<=0; ry_rem<=0;
            fx1<=0; fy1<=0; fy2<=0; fy3<=0;
            select00<=0; select01<=0; select10<=0; select11<=0;
            vs_pipe<=0; hs_pipe<=0; de_pipe<=0; valid_pipe<=0;
            for(i=0;i<5;i=i+1) rgb_pipe[i]<=0;
        end else begin
            vs_d<=vs_in;
            vs_pipe<={vs_pipe[3:0],vs_in};
            hs_pipe<={hs_pipe[3:0],hs_in};
            de_pipe<={de_pipe[3:0],de_in};
            valid_pipe<={valid_pipe[3:0],map_valid};
            rgb_pipe[0]<=rgb_in;
            for(i=1;i<5;i=i+1) rgb_pipe[i]<=rgb_pipe[i-1];
            fx1<=fx; fy1<=fy; fy2<=fy1; fy3<=fy2;
            select00<={gy[0],gx[0]}; select01<={gy[0],gx1[0]};
            select10<={gy1[0],gx[0]}; select11<={gy1[0],gx1[0]};
            if(vs_in && !vs_d) begin
                x<=0; y<=0; gx<=0; gy<=0; rx_rem<=0; ry_rem<=0;
            end else if(de_in) begin
                if(x==IMAGE_W-1) begin
                    x<=0; gx<=0; rx_rem<=0; y<=y+1'b1;
                    if(gy<GRID_H-1) begin
                        if(next_ry>=IMAGE_H-1) begin
                            gy<=gy+1'b1; ry_rem<=next_ry-(IMAGE_H-1);
                        end else ry_rem<=next_ry;
                    end
                end else begin
                    x<=x+1'b1;
                    if(gx<GRID_W-1) begin
                        if(next_rx>=IMAGE_W-1) begin
                            gx<=gx+1'b1; rx_rem<=next_rx-(IMAGE_W-1);
                        end else rx_rem<=next_rx;
                    end
                end
            end
        end
    end
    assign vs_out=vs_pipe[4]; assign hs_out=hs_pipe[4]; assign de_out=de_pipe[4];
    assign rgb_out=rgb_pipe[4];
endmodule
