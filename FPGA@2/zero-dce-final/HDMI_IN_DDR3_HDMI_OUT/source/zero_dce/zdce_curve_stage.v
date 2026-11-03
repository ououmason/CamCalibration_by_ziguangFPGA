`timescale 1ns/1ps
// One official-code iteration: x <- x + a*(x*x-x).
// x: unsigned Q0.16, a: signed Q2.14. Three clocks, II=1.
// 65535 represents white; complement uses 65536, with saturated endpoints.
module zdce_curve_stage (
    input wire clk, input wire rst_n,
    input wire [15:0] x_in, input wire signed [15:0] a_in,
    output reg [15:0] x_out, output reg signed [15:0] a_out
);
    reg [32:0] parabola;
    reg [15:0] x1, x2;
    reg signed [15:0] a1, a2;
    reg signed [32:0] delta;
    wire [16:0] complement = 17'd65536 - {1'b0,x_in};
    wire signed [33:0] rounded_delta =
        ($signed({delta[32],delta}) + 34'sd8192) >>> 14;
    wire signed [34:0] candidate =
        $signed({19'd0,x2}) - $signed({rounded_delta[33],rounded_delta});
    always @(posedge clk) begin
        if (!rst_n) begin
            parabola<=0; x1<=0; x2<=0; a1<=0; a2<=0;
            delta<=0; x_out<=0; a_out<=0;
        end else begin
            parabola <= x_in * complement;
            x1<=x_in; a1<=a_in;
            delta <= a1 * $signed({1'b0,parabola[31:16]});
            x2<=x1; a2<=a1;
            if (candidate < 0) x_out<=0;
            else if (candidate > 35'sd65535) x_out<=16'hffff;
            else x_out<=candidate[15:0];
            a_out<=a2;
        end
    end
endmodule
