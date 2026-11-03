`timescale 1ns/1ps
// Insert after the existing DDR readback, in the pix_clk domain. Reset must
// release synchronously to clk. VS is active high; DE covers exactly W*H pixels.
module zdce_video #(
    parameter integer IMAGE_W=1920,
    parameter integer IMAGE_H=1080,
    parameter integer GRID_W=30,
    parameter integer GRID_H=18
)(
    input wire clk, input wire rst_n,
    input wire enhance_enable,
    output wire enhance_active,
    input wire overlay_enable,
    output wire overlay_active,
    input wire vs_in, input wire hs_in, input wire de_in,
    input wire [23:0] rgb_in,
    output wire vs_out, output wire hs_out, output wire de_out,
    output wire [23:0] rgb_out,
    output wire cnn_busy, output reg curve_ready,
    output wire [31:0] cnn_cycles_last,
    output wire range_overflow_sticky,
    output wire frame_drop_sticky
);
    wire thumb_we,thumb_bank,thumb_done,thumb_done_bank;
    wire [15:0] thumb_addr;
    wire [23:0] thumb_data;
    reg [1:0] pending;
    reg job_bank;
    reg start;
    reg start_bank;
    wire cnn_done;
    reg active_map_bank;
    reg job_map_bank;
    reg map_pending;
    reg vs_d;
    reg enhance_frame;
    assign enhance_active=enhance_frame;
    // Stop thumbnail capture and CNN MACs when bypassed; keep HDMI timing and
    // its fixed-latency pixel pipeline running independently of compute reset.
    wire compute_rst_n=rst_n && enhance_frame;
    // Protect both queued inputs and the bank being processed. start occupies
    // one cycle before core busy asserts and is included in the reservation.
    wire [1:0] occupied=pending | ((cnn_busy || start) ?
                                  (job_bank ? 2'b10 : 2'b01) : 2'b00);
    wire [1:0] bank_free=~occupied;
    wire curve_we;
    wire [15:0] curve_addr;
    wire [7:0] curve_x,curve_y;
    wire [47:0] curve_data;
    zdce_thumbnail #(.IMAGE_W(IMAGE_W),.IMAGE_H(IMAGE_H),
                      .GRID_W(GRID_W),.GRID_H(GRID_H)) thumbnail (
        .clk(clk),.rst_n(compute_rst_n),.vs_in(vs_in),.de_in(de_in),.rgb_in(rgb_in),
        .bank_free(bank_free),.thumb_we(thumb_we),.thumb_bank(thumb_bank),
        .thumb_addr(thumb_addr),.thumb_data(thumb_data),
        .frame_done(thumb_done),.done_bank(thumb_done_bank),
        .frame_drop_sticky(frame_drop_sticky)
    );
    zdce_cnn_core #(.GRID_W(GRID_W),.GRID_H(GRID_H)) core (
        .clk(clk),.rst_n(compute_rst_n),.thumb_we(thumb_we),.thumb_bank(thumb_bank),
        .thumb_addr(thumb_addr),.thumb_data(thumb_data),
        .start(start),.start_bank(start_bank),.busy(cnn_busy),.done(cnn_done),
        .curve_we(curve_we),.curve_addr(curve_addr),.curve_data(curve_data),
        .curve_x(curve_x),.curve_y(curve_y),
        .cycles_last(cnn_cycles_last),.range_overflow_sticky(range_overflow_sticky)
    );
    // The switch is committed only in vertical blanking; it never resets sync.
    always @(posedge clk) begin
        if(!rst_n) begin
            vs_d<=0; enhance_frame<=0;
        end else begin
            vs_d<=vs_in;
            if(vs_in && !vs_d) enhance_frame<=enhance_enable;
        end
    end
    // Start a job only when the preceding output map has been published. Thus
    // the active bank cannot be overwritten mid-frame, even on delayed jobs.
    always @(posedge clk) begin
        if(!compute_rst_n) begin
            pending<=0; job_bank<=0; start<=0; start_bank<=0;
            active_map_bank<=0; job_map_bank<=1; map_pending<=0;
            curve_ready<=0;
        end else begin
            start<=0;
            if(thumb_done) pending[thumb_done_bank]<=1;
            if(!cnn_busy && !start && !cnn_done && !map_pending && (|pending)) begin
                job_bank<=pending[0] ? 1'b0 : 1'b1;
                start_bank<=pending[0] ? 1'b0 : 1'b1;
                pending[pending[0] ? 0 : 1]<=0;
                job_map_bank<=~active_map_bank;
                start<=1;
            end
            if(cnn_done) map_pending<=1;
            if(vs_in && !vs_d && map_pending) begin
                active_map_bank<=job_map_bank;
                map_pending<=0; curve_ready<=1;
            end
        end
    end
    wire map_vs,map_hs,map_de;
    wire [23:0] map_rgb;
    wire [47:0] map_alpha;
    zdce_curve_map #(.IMAGE_W(IMAGE_W),.IMAGE_H(IMAGE_H),
                     .GRID_W(GRID_W),.GRID_H(GRID_H)) coefficient_map (
        .clk(clk),.rst_n(rst_n),.map_we(curve_we && compute_rst_n),.write_bank(job_map_bank),
        .map_x(curve_x),.map_y(curve_y),.map_data(curve_data),
        .read_bank(active_map_bank),.map_valid(curve_ready && enhance_frame),
        .vs_in(vs_in),.hs_in(hs_in),.de_in(de_in),.rgb_in(rgb_in),
        .vs_out(map_vs),.hs_out(map_hs),.de_out(map_de),.rgb_out(map_rgb),.alpha_out(map_alpha)
    );
    wire curve_vs,curve_hs,curve_de;
    wire [23:0] curve_rgb;
    zdce_curve_rgb curve_pipeline (
        .clk(clk),.rst_n(rst_n),.vs_in(map_vs),.hs_in(map_hs),.de_in(map_de),
        .rgb_in(map_rgb),.alpha_in(map_alpha),
        .vs_out(curve_vs),.hs_out(curve_hs),.de_out(curve_de),.rgb_out(curve_rgb)
    );
    zdce_grid_overlay #(.IMAGE_W(IMAGE_W),.IMAGE_H(IMAGE_H),
                        .GRID_W(GRID_W),.GRID_H(GRID_H)) overlay (
        .clk(clk),.rst_n(rst_n),
        .overlay_enable(overlay_enable),.overlay_active(overlay_active),
        .map_we(curve_we && compute_rst_n),.write_bank(job_map_bank),
        .map_addr(curve_addr),.map_data(curve_data),
        .read_bank(active_map_bank),.map_valid(curve_ready && enhance_frame),
        .vs_in(curve_vs),.hs_in(curve_hs),.de_in(curve_de),.rgb_in(curve_rgb),
        .vs_out(vs_out),.hs_out(hs_out),.de_out(de_out),.rgb_out(rgb_out)
    );
endmodule
