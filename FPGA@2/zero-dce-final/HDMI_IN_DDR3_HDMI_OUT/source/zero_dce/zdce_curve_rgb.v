`timescale 1ns/1ps
// Eight fully pipelined shared-parameter iterations: 24 clocks, 1 RGB/clock.
module zdce_curve_rgb (
    input wire clk, input wire rst_n,
    input wire vs_in, input wire hs_in, input wire de_in,
    input wire [23:0] rgb_in, input wire [47:0] alpha_in,
    output wire vs_out, output wire hs_out, output wire de_out,
    output wire [23:0] rgb_out
);
    wire [47:0] pixels [0:8];
    wire [47:0] alpha [0:8];
    reg [23:0] vs_pipe, hs_pipe, de_pipe;
    assign pixels[0] = {rgb_in[23:16],rgb_in[23:16],
                        rgb_in[15:8],rgb_in[15:8],rgb_in[7:0],rgb_in[7:0]};
    assign alpha[0] = alpha_in;
    genvar s,c;
    generate for (s=0;s<8;s=s+1) begin: iteration
        for (c=0;c<3;c=c+1) begin: color
            zdce_curve_stage stage (
                .clk(clk),.rst_n(rst_n),
                .x_in(pixels[s][16*c+:16]),.a_in(alpha[s][16*c+:16]),
                .x_out(pixels[s+1][16*c+:16]),.a_out(alpha[s+1][16*c+:16])
            );
        end
    end endgenerate
    always @(posedge clk) begin
        if (!rst_n) begin vs_pipe<=0; hs_pipe<=0; de_pipe<=0; end
        else begin
            vs_pipe<={vs_pipe[22:0],vs_in};
            hs_pipe<={hs_pipe[22:0],hs_in};
            de_pipe<={de_pipe[22:0],de_in};
        end
    end
    assign vs_out=vs_pipe[23];
    assign hs_out=hs_pipe[23];
    assign de_out=de_pipe[23];
    assign rgb_out=de_out ? {pixels[8][47:40],pixels[8][31:24],pixels[8][15:8]} : 24'd0;
endmodule
