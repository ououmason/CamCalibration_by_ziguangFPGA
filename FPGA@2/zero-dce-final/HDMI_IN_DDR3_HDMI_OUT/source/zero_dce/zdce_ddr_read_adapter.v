`timescale 1ns/1ps
// Connect this directly to fram_buf read outputs. rd_buf delays DE and RGB by
// two clocks relative to sync_vg; align both syncs before entering the CNN.
// CNN and OSD add 33 pixel clocks; a board output register adds 1.
module zdce_ddr_read_adapter (
    input wire pix_clk, input wire rst_n,
    input wire enhance_enable,
    output wire enhance_active,
    input wire overlay_enable,
    output wire overlay_active,
    input wire sync_vs, input wire sync_hs,
    input wire vout_de, input wire [15:0] rgb565,
    output wire vs_out, output wire hs_out, output wire de_out,
    output wire [23:0] rgb_out,
    output wire cnn_busy, output wire curve_ready,
    output wire [31:0] cnn_cycles_last,
    output wire range_overflow_sticky, output wire frame_drop_sticky
);
    reg [1:0] vs_delay,hs_delay;
    always @(posedge pix_clk) begin
        if(!rst_n) begin vs_delay<=0; hs_delay<=0; end
        else begin
            vs_delay<={vs_delay[0],sync_vs};
            hs_delay<={hs_delay[0],sync_hs};
        end
    end
    wire [23:0] rgb888={rgb565[15:11],rgb565[15:13],
                        rgb565[10:5],rgb565[10:9],
                        rgb565[4:0],rgb565[4:2]};
    zdce_video video (
        .clk(pix_clk),.rst_n(rst_n),
        .enhance_enable(enhance_enable),
        .enhance_active(enhance_active),
        .overlay_enable(overlay_enable),.overlay_active(overlay_active),
        .vs_in(vs_delay[1]),.hs_in(hs_delay[1]),.de_in(vout_de),.rgb_in(rgb888),
        .vs_out(vs_out),.hs_out(hs_out),.de_out(de_out),.rgb_out(rgb_out),
        .cnn_busy(cnn_busy),.curve_ready(curve_ready),.cnn_cycles_last(cnn_cycles_last),
        .range_overflow_sticky(range_overflow_sticky),.frame_drop_sticky(frame_drop_sticky)
    );
endmodule
