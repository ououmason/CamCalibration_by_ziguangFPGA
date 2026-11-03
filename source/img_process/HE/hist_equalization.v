`timescale 1ns/1ps
`default_nettype none
// Global contrast-limited HE: clip at twice the average bin population,
// redistribute all excess counts, then mix 25% HE with 75% original luma.
// Frames spanning <=8 gray levels use the identity map.
// Collect DE only, finalize on rising VS. Two mapping banks prevent tearing.
module hist_equalization #(
    parameter integer H_DISP=1920,
    parameter integer V_DISP=1080
)(
    input wire clk, rst_n,
    input wire Y_hsync, Y_vsync,
    input wire [7:0] Y_data,
    input wire Y_de,
    output reg hist_hsync, hist_vsync,
    output wire [7:0] hist_data,
    output reg hist_de,
    output reg hist_valid
);
    localparam [31:0] PIXEL_TOTAL=H_DISP*V_DISP;
    localparam [31:0] CLIP_LIMIT=(PIXEL_TOTAL+127)/128;
    localparam [2:0] INIT=0, COLLECT=1, FLUSH=2,
        READ_BIN=3, LOAD_BIN=4, DIVIDE=5, STORE=6;
    reg [2:0] state;
    reg [7:0] bin;
    reg vs_d, frame_started, frame_ok, active_seen;
    reg [31:0] pixel_count, cumulative;
    reg [31:0] excess;
    reg scan_pass, map_identity;
    reg [7:0] min_y,max_y;
    reg build_map, read_bank, map_ready, map_pending;
    reg pending_valid;
    reg [7:0] pending_addr;
    reg last_valid;
    reg [7:0] last_addr;
    reg [31:0] last_count;
    reg [31:0] numerator, quotient;
    reg [32:0] remainder;
    reg [5:0] bit_count;
    reg [7:0] raw_y;
    wire sof=Y_vsync && !vs_d;
    wire [31:0] hist_q;
    wire [7:0] map_q;
    wire [31:0] incremented =
        ((last_valid && last_addr==pending_addr) ? last_count : hist_q)+32'd1;
    wire hist_wren=rst_n && ((state==INIT) || (state==LOAD_BIN && !scan_pass) ||
        (state==COLLECT && pending_valid));
    wire [7:0] hist_wraddr=(state==COLLECT) ? pending_addr : bin;
    wire [31:0] hist_wdata=(state==COLLECT) ? incremented : 32'd0;
    wire [7:0] hist_rdaddr=(state==COLLECT) ? Y_data : bin;
    wire [32:0] shifted_remainder={remainder[31:0],numerator[31]};
    wire subtract_bit=shifted_remainder>={1'b0,PIXEL_TOTAL};
    wire [31:0] clipped_count=hist_q>CLIP_LIMIT ? CLIP_LIMIT : hist_q;
    wire [31:0] redistributed_count=clipped_count+(excess>>8)+
        ((bin<excess[7:0]) ? 32'd1 : 32'd0);
    wire [9:0] mixed_y={2'b0,bin}+{1'b0,bin,1'b0}+{2'b0,quotient[7:0]};
    wire [7:0] map_data=map_identity ? bin : mixed_y[9:2];
    wire map_wren=rst_n && state==STORE && build_map;

    // Generated distributed RAMs: OUT_REG=1 supplies one-edge OLD_DATA reads.
    // Both ports share the pixel clock; reset clears the IP output register.
    he_hist_ram histogram_ram(
        .wr_clk(clk), .rd_clk(clk), .rst(!rst_n),
        .wr_en(hist_wren), .wr_addr(hist_wraddr),
        .wr_data(hist_wdata), .rd_addr(hist_rdaddr), .rd_data(hist_q));
    he_map_ram mapping_ram(
        .wr_clk(clk), .rd_clk(clk), .rst(!rst_n),
        .wr_en(map_wren), .wr_addr({!read_bank,bin}),
        .wr_data(map_data),
        .rd_addr({read_bank,Y_data}), .rd_data(map_q));

    assign hist_data=hist_valid ? map_q : raw_y;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            hist_hsync<=0; hist_vsync<=0; hist_de<=0; hist_valid<=0;
            raw_y<=0;
            state<=INIT; bin<=0; vs_d<=0;
            frame_started<=0; frame_ok<=0; active_seen<=0;
            pixel_count<=0; cumulative<=0;
            excess<=0; scan_pass<=0; map_identity<=0;
            min_y<=255; max_y<=0;
            build_map<=0; read_bank<=0; map_ready<=0; map_pending<=0;
            pending_valid<=0; pending_addr<=0;
            last_valid<=0; last_addr<=0; last_count<=0;
            numerator<=0; quotient<=0; remainder<=0; bit_count<=0;
        end else begin
            hist_hsync<=Y_hsync; hist_vsync<=Y_vsync; hist_de<=Y_de;
            hist_valid<=map_ready; raw_y<=Y_data;
            vs_d<=Y_vsync;
            // One pending read-modify-write. Forward the immediately preceding
            // write to handle repeated gray levels AND A/B/A address hazards.
            pending_valid<=state==COLLECT && frame_started && frame_ok && Y_de && !sof;
            pending_addr<=Y_data;
            last_valid<=hist_wren && state==COLLECT;
            if(hist_wren && state==COLLECT) begin
                last_addr<=hist_wraddr; last_count<=hist_wdata;
            end
            if(Y_de) active_seen<=1;
            // If blanking is too short, discard this entire statistics frame.
            // Never expose a partly generated mapping to active video.
            if(Y_de && state!=COLLECT) frame_ok<=0;
            if(sof) begin
                active_seen<=0;
                if(map_pending) begin
                    read_bank<=!read_bank; map_ready<=1; map_pending<=0;
                end
                if(state!=COLLECT) frame_ok<=0;
            end
            case(state)
                INIT: begin
                    if(bin==255) begin state<=COLLECT; bin<=0; end
                    else bin<=bin+1'b1;
                end
                COLLECT: begin
                    if(sof) begin
                        frame_started<=1; frame_ok<=1; pixel_count<=0;
                        if(frame_started) begin
                            build_map<=frame_ok && pixel_count==PIXEL_TOTAL;
                            cumulative<=0; bin<=0; state<=FLUSH;
                            excess<=0; scan_pass<=1; map_identity<=0;
                            min_y<=255; max_y<=0;
                        end
                    end else if(frame_started && frame_ok && Y_de) begin
                        if(pixel_count<PIXEL_TOTAL+1) pixel_count<=pixel_count+1'b1;
                    end
                end
                FLUSH: state<=READ_BIN;
                READ_BIN: state<=LOAD_BIN;
                LOAD_BIN: begin
                    if(scan_pass) begin
                        // First pass preserves RAM and measures clipping excess
                        // and the original occupied range before redistribution.
                        excess<=excess+(hist_q-clipped_count);
                        if(hist_q!=0) begin
                            if(bin<min_y) min_y<=bin;
                            max_y<=bin;
                        end
                        if(bin==255) begin
                            scan_pass<=0; bin<=0;
                            map_identity<=((({1'b0,(hist_q!=0 ? bin : max_y)})-
                                {1'b0,min_y})<=9'd8);
                        end else bin<=bin+1'b1;
                        state<=READ_BIN;
                    end else begin
                    // Read old count before clearing this bin through the IP.
                    cumulative<=cumulative+redistributed_count;
                    numerator<=(cumulative+redistributed_count)*32'd255;
                    remainder<=0; quotient<=0; bit_count<=0;
                    if(build_map) state<=DIVIDE;
                    else state<=STORE;
                    end
                end
                DIVIDE: begin
                    numerator<={numerator[30:0],1'b0};
                    remainder<=subtract_bit ? shifted_remainder-{1'b0,PIXEL_TOTAL} : shifted_remainder;
                    quotient<={quotient[30:0],subtract_bit};
                    if(bit_count==31) state<=STORE;
                    else bit_count<=bit_count+1'b1;
                end
                STORE: begin
                    if(bin==255) begin
                        state<=COLLECT;
                        if(build_map) begin
                            if(!active_seen && !Y_de) begin
                                read_bank<=!read_bank; map_ready<=1;
                            end else map_pending<=1;
                        end
                    end else begin bin<=bin+1'b1; state<=READ_BIN; end
                end
                default: state<=INIT;
            endcase
        end
    end
    // synthesis translate_off
    initial begin
        if(H_DISP<1 || V_DISP<1 || H_DISP*V_DISP>16777215)
            $fatal(1,"HE frame size must be 1..16777215 pixels");
    end
    // synthesis translate_on
endmodule
`default_nettype wire
