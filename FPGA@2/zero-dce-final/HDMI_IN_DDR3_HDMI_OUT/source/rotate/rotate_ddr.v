`timescale 1ns/1ps
// Native DDR addresses count 32-bit words; one beat is 16 RGB565 pixels.
// Visit 16x16 output tiles and retain 64 source beats (2 KiB logical data).
// Four banks distinguish source-row parity and source-word-column parity,
// so a bilinear neighborhood needs at most one lookup per bank.
module rotate_ddr #(
    parameter integer AW=28, WIDTH=1920, HEIGHT=1080, FRAME_BITS=22,
    parameter integer SOURCE_WIDTH=WIDTH, SOURCE_HEIGHT=HEIGHT,
    parameter signed [31:0] COS_Q16=61584, SIN_Q16=22415, parameter DYNAMIC=0,
    parameter integer RENDER_INTERVAL_CYCLES=1, BILINEAR=1, TILE_HEIGHT=16
)(
    input clk,rst_n, input frame_done, input source_bank, input vsync,
    input signed [31:0] cos_q16,sin_q16,
    output capture_enable, output reg display_bank, output reg display_valid,
    output busy, output reg [AW-1:0] araddr, output arvalid, input arready,
    input [255:0] rdata, input rvalid,
    output [AW-1:0] awaddr, output awvalid, input awready,
    output [255:0] wdata, output wvalid, input wready, input wlast
);
    localparam WAIT_FRAME=0, MAP=1, READ_ADDR=2, READ_DATA=3,
               WRITE_ADDR=4, WRITE_DATA=5, WRITE_DONE=6, SWAP=7, DRAIN=8, PREP_COORD=9;
    localparam [AW-1:0] OUTPUT_BASE=(1<<24);
    localparam integer RATE_BITS=(RENDER_INTERVAL_CYCLES>1) ? $clog2(RENDER_INTERVAL_CYCLES):1;
    reg [3:0] state;
    reg [RATE_BITS-1:0] render_cooldown;
    reg src_bank,dst_bank,final_word;
    reg [AW-1:0] out_offset;
    reg [255:0] packed_data;
    reg [1:0] miss_bank;
    reg [3:0] miss_index;
    reg vs1,vs2,vs3;
    wire frame_edge=vs2 && !vs3;
    wire [11:0] x,y;
    wire signed [15:0] sx,sy;
    wire [7:0] fx,fy;
    wire in_range,last_pixel,coords_ready;
    wire start_render=capture_enable && frame_done;
    wire [11:0] px=sx[11:0], py=sy[11:0];
    // Replicate the last source row/column. Never read outside the frozen bank.
    wire [11:0] nx=(px==SOURCE_WIDTH-1 || !BILINEAR || fx==0) ? px:px+12'd1;
    wire [11:0] ny=(py==SOURCE_HEIGHT-1 || !BILINEAR || fy==0) ? py:py+12'd1;
    wire [1:0] b00={py[0],px[4]}, b01={py[0],nx[4]};
    wire [1:0] b10={ny[0],px[4]}, b11={ny[0],nx[4]};
    wire [3:0] needed,hit;
    wire [AW-1:0] request_addr[0:3];
    wire [3:0] request_index[0:3];
    wire [255:0] word_data[0:3];
    wire take=state==MAP && (!in_range || ((hit & needed)==needed));
    wire [31:0] output_index=y*WIDTH+x;
    genvar bank;
    generate for(bank=0;bank<4;bank=bank+1) begin: cache
        // Asynchronous small LUT/register cache, no reset on data RAM.
        reg [255:0] data[0:15];
        reg [AW-1:0] tags[0:15];
        reg [15:0] valid;
        wire [11:0] qx=(px[4]==(bank%2)) ? px:nx;
        wire [11:0] qy=(py[0]==(bank/2)) ? py:ny;
        wire [31:0] index=qy*SOURCE_WIDTH+qx;
        assign request_addr[bank]=(src_bank ? (1<<FRAME_BITS):0)+((index>>4)<<3);
        assign request_index[bank]=qy[4:1]^qx[8:5];
        assign needed[bank]=(b00==bank || b01==bank || b10==bank || b11==bank);
        assign hit[bank]=valid[request_index[bank]] && tags[request_index[bank]]==request_addr[bank];
        assign word_data[bank]=data[request_index[bank]];
        always @(posedge clk or negedge rst_n) begin
            if(!rst_n) valid<=0;
            else if(start_render) valid<=0;
            else if(state==READ_DATA && rvalid && miss_bank==bank) valid[miss_index]<=1;
        end
        always @(posedge clk) begin
            if(state==READ_DATA && rvalid && miss_bank==bank) begin
                data[miss_index]<=rdata; tags[miss_index]<=araddr;
            end
        end
    end endgenerate
    wire [15:0] p00=word_data[b00]>>(px[3:0]*16);
    wire [15:0] p01=word_data[b01]>>(nx[3:0]*16);
    wire [15:0] p10=word_data[b10]>>(px[3:0]*16);
    wire [15:0] p11=word_data[b11]>>(nx[3:0]*16);
    wire [7:0] weight_x=BILINEAR ? fx:8'd0;
    wire [7:0] weight_y=BILINEAR ? fy:8'd0;
    // Unsigned magnitude products avoid the PDS signed DSP extension pitfall.
    // Keep horizontal Q8 precision; round only once after vertical blending.
    function [13:0] horizontal;
        input [5:0] a,b; input [7:0] f;
        reg [5:0] delta; reg [13:0] product;
        begin
            delta=(b>=a) ? b-a:a-b; product=delta*f;
            horizontal=(b>=a) ? {a,8'd0}+product:{a,8'd0}-product;
        end
    endfunction
    function [5:0] vertical;
        input [13:0] a,b; input [7:0] f;
        reg [13:0] delta; reg [21:0] product,total;
        begin
            delta=(b>=a) ? b-a:a-b; product=delta*f;
            total=(b>=a) ? {a,8'd0}+product:{a,8'd0}-product;
            total=total+22'd32768; vertical=total[21:16];
        end
    endfunction
    // Register samples before the multipliers: cache lookup and interpolation
    // do not share one combinational timing path. One pixel per cycle on hits.
    reg sample_valid,sample_in_range;
    reg [3:0] sample_lane;
    reg [7:0] sample_fx,sample_fy;
    reg [15:0] sample00,sample01,sample10,sample11;
    reg h_valid,v_valid;
    reg [3:0] h_lane,v_lane;
    reg [7:0] h_fy;
    reg [13:0] hr0,hg0,hb0,hr1,hg1,hb1;
    reg [15:0] v_pixel;
    wire [5:0] vr=vertical(hr0,hr1,h_fy);
    wire [5:0] vg=vertical(hg0,hg1,h_fy);
    wire [5:0] vb=vertical(hb0,hb1,h_fy);
    rotate_coord #(.WIDTH(WIDTH),.HEIGHT(HEIGHT),.SOURCE_WIDTH(SOURCE_WIDTH),.SOURCE_HEIGHT(SOURCE_HEIGHT),.COS_Q16(COS_Q16),
        .SIN_Q16(SIN_Q16),.DYNAMIC(DYNAMIC),.BILINEAR(BILINEAR),.TILE_HEIGHT(TILE_HEIGHT)) coords(
        .clk(clk),.rst_n(rst_n),.cos_q16(cos_q16),.sin_q16(sin_q16),.start(start_render),
        .advance(take && !last_pixel),.x(x),.y(y),.frac_x(fx),.frac_y(fy),
        .src_x(sx),.src_y(sy),.in_bounds(in_range),.last(last_pixel),.ready(coords_ready));
    assign capture_enable=(state==WAIT_FRAME && render_cooldown==0);
    assign busy=(state!=WAIT_FRAME && state!=SWAP);
    assign arvalid=(state==READ_ADDR);
    assign awaddr=OUTPUT_BASE+(dst_bank ? (1<<FRAME_BITS):0)+out_offset;
    assign awvalid=(state==WRITE_ADDR);
    assign wvalid=(state==WRITE_DATA);
    assign wdata=packed_data;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=WAIT_FRAME; display_bank<=0; display_valid<=0; render_cooldown<=0;
            src_bank<=0; dst_bank<=1; final_word<=0; packed_data<=0; out_offset<=0;
            araddr<=0; miss_bank<=0; miss_index<=0; vs1<=0; vs2<=0; vs3<=0;
            h_valid<=0; v_valid<=0; h_lane<=0; v_lane<=0; h_fy<=0; v_pixel<=0;
            hr0<=0; hg0<=0; hb0<=0; hr1<=0; hg1<=0; hb1<=0;
            sample_valid<=0; sample_in_range<=0; sample_lane<=0; sample_fx<=0; sample_fy<=0;
            sample00<=0; sample01<=0; sample10<=0; sample11<=0;
        end else begin
            if(render_cooldown!=0) render_cooldown<=render_cooldown-1'b1;
            vs1<=vsync; vs2<=vs1; vs3<=vs2;
            sample_valid<=take; h_valid<=sample_valid; v_valid<=h_valid;
            if(take) begin
                sample_lane<=x[3:0]; sample_fx<=weight_x; sample_fy<=weight_y; sample_in_range<=in_range;
                sample00<=p00; sample01<=p01; sample10<=p10; sample11<=p11;
            end
            if(sample_valid) begin
                h_lane<=sample_lane; h_fy<=sample_fy;
                hr0<=sample_in_range ? horizontal({1'b0,sample00[15:11]},{1'b0,sample01[15:11]},sample_fx):14'd0;
                hg0<=sample_in_range ? horizontal(sample00[10:5],sample01[10:5],sample_fx):14'd0;
                hb0<=sample_in_range ? horizontal({1'b0,sample00[4:0]},{1'b0,sample01[4:0]},sample_fx):14'd0;
                hr1<=sample_in_range ? horizontal({1'b0,sample10[15:11]},{1'b0,sample11[15:11]},sample_fx):14'd0;
                hg1<=sample_in_range ? horizontal(sample10[10:5],sample11[10:5],sample_fx):14'd0;
                hb1<=sample_in_range ? horizontal({1'b0,sample10[4:0]},{1'b0,sample11[4:0]},sample_fx):14'd0;
            end
            if(h_valid) begin v_lane<=h_lane; v_pixel<={vr[4:0],vg,vb[4:0]}; end
            if(v_valid) begin
                packed_data[v_lane*16 +:16]<=v_pixel;
                if(v_lane==15) state<=WRITE_ADDR;
            end
            case(state)
                WAIT_FRAME: if(start_render) begin
                    render_cooldown<=RENDER_INTERVAL_CYCLES-1;
                    src_bank<=source_bank; dst_bank<=!display_bank; state<=PREP_COORD;
                end
                PREP_COORD: if(coords_ready) state<=MAP;
                MAP: if(take) begin
                    if(x[3:0]==15) begin
                        out_offset<=(output_index>>4)<<3; final_word<=last_pixel; state<=DRAIN;
                    end
                end else begin
                    if(needed[0] && !hit[0]) begin araddr<=request_addr[0]; miss_index<=request_index[0]; miss_bank<=0; end
                    else if(needed[1] && !hit[1]) begin araddr<=request_addr[1]; miss_index<=request_index[1]; miss_bank<=1; end
                    else if(needed[2] && !hit[2]) begin araddr<=request_addr[2]; miss_index<=request_index[2]; miss_bank<=2; end
                    else begin araddr<=request_addr[3]; miss_index<=request_index[3]; miss_bank<=3; end
                    state<=READ_ADDR;
                end
                READ_ADDR: if(arready) state<=READ_DATA;
                READ_DATA: if(rvalid) state<=MAP;
                DRAIN: begin end
                WRITE_ADDR: if(awready) state<=WRITE_DATA;
                WRITE_DATA: if(wready) begin
                    if(wlast) state<=final_word ? SWAP:MAP; else state<=WRITE_DONE;
                end
                WRITE_DONE: if(wlast) state<=final_word ? SWAP:MAP;
                SWAP: if(frame_edge) begin display_bank<=dst_bank; display_valid<=1; state<=WAIT_FRAME; end
                default: state<=WAIT_FRAME;
            endcase
        end
    end
endmodule
