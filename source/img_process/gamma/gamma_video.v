`timescale 1ns/1ps
`default_nettype none

// One register of latency in both modes; RGB and timing stay aligned.
module gamma_video (
    input wire clk, rst_n, enable_async,
    input wire vs_in, hs_in, de_in,
    input wire [23:0] rgb_in,
    output wire vs_out, hs_out, de_out,
    output wire [23:0] rgb_out
);
    (* async_reg = "true" *) reg [1:0] enable_sync;
    reg enabled, vs_d;
    reg vs_q, hs_q, de_q;
    reg [23:0] raw_q;
    wire [23:0] mapped;

    gamma_lookuptable lut_r(
        .video_clk(clk), .video_data(rgb_in[23:16]), .video_de(de_in),
        .gamma_de(), .gamma_data(mapped[23:16]));
    gamma_lookuptable lut_g(
        .video_clk(clk), .video_data(rgb_in[15:8]), .video_de(de_in),
        .gamma_de(), .gamma_data(mapped[15:8]));
    gamma_lookuptable lut_b(
        .video_clk(clk), .video_data(rgb_in[7:0]), .video_de(de_in),
        .gamma_de(), .gamma_data(mapped[7:0]));

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            enable_sync <= 0;
            enabled <= 0;
            vs_d <= 0;
            vs_q <= 0; hs_q <= 0; de_q <= 0;
            raw_q <= 0;
        end else begin
            enable_sync <= {enable_sync[0], enable_async};
            vs_d <= vs_in;
            // Commit in vertical blanking, never within active video.
            if (vs_in && !vs_d && !de_in) enabled <= enable_sync[1];
            vs_q <= vs_in; hs_q <= hs_in; de_q <= de_in;
            raw_q <= rgb_in;
        end
    end

    assign vs_out = vs_q;
    assign hs_out = hs_q;
    assign de_out = de_q;
    assign rgb_out = de_q ? (enabled ? mapped : raw_q) : 24'd0;
endmodule

`default_nettype wire
