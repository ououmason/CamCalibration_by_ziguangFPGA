`timescale 1ns/1ps
// 1920x1080 -> 30x18, bilinear resize (no antialiasing).
// Select the four pixels around each low-resolution pixel center, not every
// tile-width pixel. Only GRID_W pair sums are retained; no full line buffer.
// VS must be active high and aligned to RGB/DE. There is no backpressure.
module zdce_thumbnail #(
    parameter integer IMAGE_W = 1920,
    parameter integer IMAGE_H = 1080,
    parameter integer GRID_W = 30,
    parameter integer GRID_H = 18
)(
    input wire clk, input wire rst_n,
    input wire vs_in, input wire de_in, input wire [23:0] rgb_in,
    input wire [1:0] bank_free,
    output reg thumb_we, output reg thumb_bank,
    output reg [15:0] thumb_addr, output reg [23:0] thumb_data,
    output reg frame_done, output reg done_bank,
    output reg frame_drop_sticky
);
    localparam integer SX = IMAGE_W / GRID_W;
    localparam integer SY = IMAGE_H / GRID_H;
    reg vs_d, capturing, capture_bank;
    reg [11:0] x, y, phase_x, phase_y;
    reg [7:0] tile_x, tile_y;
    reg [23:0] left_pixel;
    (* ram_style="distributed", syn_ramstyle="distributed_ram" *)
    reg [26:0] upper_pair [0:GRID_W-1];
    wire [8:0] pair_r = {1'b0,left_pixel[23:16]} + {1'b0,rgb_in[23:16]};
    wire [8:0] pair_g = {1'b0,left_pixel[15:8]} + {1'b0,rgb_in[15:8]};
    wire [8:0] pair_b = {1'b0,left_pixel[7:0]} + {1'b0,rgb_in[7:0]};
    wire [26:0] upper = upper_pair[tile_x];
    wire [10:0] sum_r = {2'b0,upper[26:18]} + {2'b0,pair_r} + 11'd2;
    wire [10:0] sum_g = {2'b0,upper[17:9]} + {2'b0,pair_g} + 11'd2;
    wire [10:0] sum_b = {2'b0,upper[8:0]} + {2'b0,pair_b} + 11'd2;
    always @(posedge clk) begin
        if (!rst_n) begin
            vs_d<=0; capturing<=0; capture_bank<=0;
            x<=0; y<=0; phase_x<=0; phase_y<=0; tile_x<=0; tile_y<=0;
            thumb_we<=0; thumb_bank<=0; thumb_addr<=0; thumb_data<=0;
            frame_done<=0; done_bank<=0; frame_drop_sticky<=0;
            left_pixel<=0;
        end else begin
            vs_d <= vs_in;
            thumb_we <= 0;
            frame_done <= 0;
            if (vs_in && !vs_d) begin
                x<=0; y<=0; phase_x<=0; phase_y<=0; tile_x<=0; tile_y<=0;
                capturing <= |bank_free;
                capture_bank <= bank_free[0] ? 1'b0 : 1'b1;
                if (!(|bank_free)) frame_drop_sticky <= 1;
            end else if (de_in) begin
                if (capturing && (y < IMAGE_H) &&
                    ((phase_y == SY/2-1) || (phase_y == SY/2))) begin
                    if (phase_x == SX/2-1) left_pixel <= rgb_in;
                    if (phase_x == SX/2) begin
                        if (phase_y == SY/2-1)
                            upper_pair[tile_x] <= {pair_r,pair_g,pair_b};
                        else begin
                            thumb_we <= 1;
                            thumb_bank <= capture_bank;
                            thumb_addr <= tile_y*GRID_W + tile_x;
                            thumb_data <= {sum_r[9:2],sum_g[9:2],sum_b[9:2]};
                            // Completion and final write share a registered bus.
                            // The scheduler starts the core on the next cycle.
                            if ((tile_y == GRID_H-1) && (tile_x == GRID_W-1)) begin
                                frame_done <= 1;
                                done_bank <= capture_bank;
                                capturing <= 0;
                            end
                        end
                    end
                end
                if (x == IMAGE_W-1) begin
                    x<=0; y<=y+1'b1; phase_x<=0; tile_x<=0;
                    if (phase_y == SY-1) begin
                        phase_y<=0; tile_y<=tile_y+1'b1;
                    end else phase_y<=phase_y+1'b1;
                end else begin
                    x<=x+1'b1;
                    if (phase_x == SX-1) begin
                        phase_x<=0; tile_x<=tile_x+1'b1;
                    end else phase_x<=phase_x+1'b1;
                end
            end
        end
    end
endmodule
