`timescale 1ns/1ps
// Inverse map for clockwise screen rotation (x right, y down).
// Coefficients latch at frame start; only additions run per pixel.
// Frame-origin products have constant image dimensions as one operand.
module rotate_coord #(
    parameter integer WIDTH=1920, HEIGHT=1080,
    parameter integer SOURCE_WIDTH=WIDTH, SOURCE_HEIGHT=HEIGHT,
    parameter signed [31:0] COS_Q16=61584, SIN_Q16=22415, parameter DYNAMIC=0,
    parameter integer BILINEAR=0, TILE_HEIGHT=1
)(
    input clk, rst_n, start, advance,
    input signed [31:0] cos_q16, sin_q16,
    output reg [11:0] x, y,
    output signed [15:0] src_x, src_y,
    output [7:0] frac_x,frac_y,
    output in_bounds, last,
    output reg ready
);
    localparam signed [63:0] CX=(SOURCE_WIDTH-1)*64'sd32768;
    localparam signed [63:0] CY=(SOURCE_HEIGHT-1)*64'sd32768;
    // Uniform inverse scaling: pixel centers map to source pixel centers.
    // 720p -> 1080p uses 2/3 source pixel per destination pixel.
    localparam integer RESIZE=(SOURCE_WIDTH!=WIDTH || SOURCE_HEIGHT!=HEIGHT);
    localparam [24:0] SCALE_Q24=((64'd16777216*SOURCE_WIDTH)+WIDTH/2)/WIDTH;
    function signed [31:0] scale_coefficient;
        input signed [31:0] coefficient;
        reg signed [56:0] extended_coefficient,accumulator;
        integer bit_index;
        begin
            extended_coefficient={{25{coefficient[31]}},coefficient};
            accumulator=0;
            for(bit_index=0;bit_index<25;bit_index=bit_index+1)
                if(SCALE_Q24[bit_index])
                    accumulator=accumulator+(extended_coefficient<<<bit_index);
            scale_coefficient=(accumulator+57'sd8388608)>>>24;
        end
    endfunction
    localparam signed [31:0] RESET_C=scale_coefficient(COS_Q16);
    localparam signed [31:0] RESET_S=scale_coefficient(SIN_Q16);
    localparam integer BIAS=BILINEAR ? 0:32768;
    // TILE_HEIGHT must be 1 or a power of two; WIDTH must be a multiple of 16.
    localparam integer TILE_SHIFT=$clog2(TILE_HEIGHT);
    localparam signed [31:0] X0=CX-(((WIDTH-1)*64'sd32768*RESET_C+(HEIGHT-1)*64'sd32768*RESET_S)>>>16)+BIAS;
    localparam signed [31:0] Y0=CY+(((WIDTH-1)*64'sd32768*RESET_S-(HEIGHT-1)*64'sd32768*RESET_C)>>>16)+BIAS;
    // Frame preparation is infrequent. Serialize the constant products so no
    // angle -> resize -> origin adder chain has to fit into one DDR cycle.
    localparam PREP_IDLE=0, PREP_SCALE=1, PREP_ROUND=2, PREP_DIM_INIT=3,
               PREP_DIM=4, PREP_SUM=5, PREP_LOAD=6;
    localparam [11:0] DX=WIDTH-1, DY=HEIGHT-1;
    reg [2:0] prep_state;
    reg [4:0] prep_bit;
    reg signed [56:0] scale_c,scale_s,shift_c,shift_s;
    reg signed [31:0] frame_c,frame_s;
    reg signed [47:0] dim_c,dim_s,xc,ys,xs,yc;
    reg signed [47:0] origin_x_product,origin_y_product;
    wire signed [31:0] raw_c=DYNAMIC ? cos_q16:COS_Q16;
    wire signed [31:0] raw_s=DYNAMIC ? sin_q16:SIN_Q16;
    wire signed [31:0] x0_now=CX-(origin_x_product>>>1)+BIAS;
    wire signed [31:0] y0_now=CY+(origin_y_product>>>1)+BIAS;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            prep_state<=PREP_IDLE; prep_bit<=0; ready<=0;
            scale_c<=0; scale_s<=0; shift_c<=0; shift_s<=0;
            frame_c<=RESET_C; frame_s<=RESET_S;
            dim_c<=0; dim_s<=0; xc<=0; ys<=0; xs<=0; yc<=0;
            origin_x_product<=0; origin_y_product<=0;
        end else if(start) begin
            prep_state<=PREP_SCALE; prep_bit<=0; ready<=0;
            scale_c<=0; scale_s<=0;
            shift_c<={{25{raw_c[31]}},raw_c};
            shift_s<={{25{raw_s[31]}},raw_s};
        end else begin
            case(prep_state)
                PREP_SCALE: begin
                    if(SCALE_Q24[prep_bit]) begin
                        scale_c<=scale_c+shift_c;
                        scale_s<=scale_s+shift_s;
                    end
                    shift_c<=shift_c<<<1; shift_s<=shift_s<<<1;
                    if(prep_bit==24) prep_state<=PREP_ROUND;
                    else prep_bit<=prep_bit+1'b1;
                end
                PREP_ROUND: begin
                    frame_c<=(scale_c+57'sd8388608)>>>24;
                    frame_s<=(scale_s+57'sd8388608)>>>24;
                    prep_state<=PREP_DIM_INIT;
                end
                PREP_DIM_INIT: begin
                    dim_c<={{16{frame_c[31]}},frame_c};
                    dim_s<={{16{frame_s[31]}},frame_s};
                    xc<=0; ys<=0; xs<=0; yc<=0; prep_bit<=0;
                    prep_state<=PREP_DIM;
                end
                PREP_DIM: begin
                    if(DX[prep_bit]) begin xc<=xc+dim_c; xs<=xs+dim_s; end
                    if(DY[prep_bit]) begin ys<=ys+dim_s; yc<=yc+dim_c; end
                    dim_c<=dim_c<<<1; dim_s<=dim_s<<<1;
                    if(prep_bit==11) prep_state<=PREP_SUM;
                    else prep_bit<=prep_bit+1'b1;
                end
                PREP_SUM: begin
                    origin_x_product<=xc+ys; origin_y_product<=xs-yc;
                    prep_state<=PREP_LOAD;
                end
                PREP_LOAD: begin ready<=1; prep_state<=PREP_IDLE; end
                default: prep_state<=PREP_IDLE;
            endcase
        end
    end
    reg signed [31:0] sx,sy,row_sx,row_sy;
    reg signed [31:0] tile_sx,tile_sy,band_sx,band_sy;
    reg [11:0] tile_y;
    // Replicate edge pixels for the half-pixel resize footprint. Rotated
    // coordinates outside the source rectangle still produce black.
    wire signed [31:0] sample_x=(RESIZE && sx<0) ? 32'sd0:
        (RESIZE && sx>(SOURCE_WIDTH-1)*65536) ? (SOURCE_WIDTH-1)*65536:sx;
    wire signed [31:0] sample_y=(RESIZE && sy<0) ? 32'sd0:
        (RESIZE && sy>(SOURCE_HEIGHT-1)*65536) ? (SOURCE_HEIGHT-1)*65536:sy;
    assign frac_x=sample_x[15:8];
    assign frac_y=sample_y[15:8];
    assign src_x=sample_x[31:16];
    assign src_y=sample_y[31:16];
    assign in_bounds=RESIZE ?
        (sx>=-32768 && sx<SOURCE_WIDTH*65536-32768 &&
         sy>=-32768 && sy<SOURCE_HEIGHT*65536-32768):
        (src_x>=0 && src_x<SOURCE_WIDTH && src_y>=0 && src_y<SOURCE_HEIGHT);
    assign last=(x==WIDTH-1 && y==HEIGHT-1);
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            x<=0; y<=0; sx<=X0; sy<=Y0; row_sx<=X0; row_sy<=Y0;
            tile_sx<=X0; tile_sy<=Y0; band_sx<=X0; band_sy<=Y0; tile_y<=0;
        end else if(prep_state==PREP_LOAD && !start) begin
            x<=0; y<=0; sx<=x0_now; sy<=y0_now; row_sx<=x0_now; row_sy<=y0_now;
            tile_sx<=x0_now; tile_sy<=y0_now; band_sx<=x0_now; band_sy<=y0_now; tile_y<=0;
        end else if(advance && ready && !start) begin
            // 16-pixel DDR words, visited in short vertical tiles. This keeps
            // nearby source rows resident even around 90/270 degree rotations.
            if(TILE_HEIGHT>1 && x[3:0]==15) begin
                if(y==tile_y+TILE_HEIGHT-1 || y==HEIGHT-1) begin
                    if(x==WIDTH-1) begin
                        x<=0; y<=y+1'b1; tile_y<=y+1'b1;
                        band_sx<=band_sx+(frame_s<<<TILE_SHIFT);
                        band_sy<=band_sy+(frame_c<<<TILE_SHIFT);
                        tile_sx<=band_sx+(frame_s<<<TILE_SHIFT);
                        tile_sy<=band_sy+(frame_c<<<TILE_SHIFT);
                        row_sx<=band_sx+(frame_s<<<TILE_SHIFT);
                        row_sy<=band_sy+(frame_c<<<TILE_SHIFT);
                        sx<=band_sx+(frame_s<<<TILE_SHIFT); sy<=band_sy+(frame_c<<<TILE_SHIFT);
                    end else begin
                        x<=x+1'b1; y<=tile_y;
                        tile_sx<=tile_sx+(frame_c<<<4); tile_sy<=tile_sy-(frame_s<<<4);
                        row_sx<=tile_sx+(frame_c<<<4); row_sy<=tile_sy-(frame_s<<<4);
                        sx<=tile_sx+(frame_c<<<4); sy<=tile_sy-(frame_s<<<4);
                    end
                end else begin
                    x<=x-15; y<=y+1'b1;
                    row_sx<=row_sx+frame_s; row_sy<=row_sy+frame_c;
                    sx<=row_sx+frame_s; sy<=row_sy+frame_c;
                end
            end else if(x==WIDTH-1) begin
                x<=0; y<=y+1'b1;
                row_sx<=row_sx+frame_s; row_sy<=row_sy+frame_c;
                sx<=row_sx+frame_s; sy<=row_sy+frame_c;
            end else begin
                x<=x+1'b1; sx<=sx+frame_c; sy<=sy-frame_s;
            end
        end
    end
endmodule
