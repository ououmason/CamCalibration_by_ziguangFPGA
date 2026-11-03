// Full-screen grid with signed decimal RGB coefficients in each source region.
// Fixed four-clock video latency, including bypass. No full-frame buffer.
module zdce_grid_overlay #(
    parameter integer IMAGE_W=1920, IMAGE_H=1080,
    parameter integer GRID_W=30, GRID_H=18
)(
    input wire clk, input wire rst_n,
    input wire overlay_enable, output reg overlay_active,
    input wire map_we, input wire write_bank,
    input wire [15:0] map_addr, input wire [47:0] map_data,
    input wire read_bank, input wire map_valid,
    input wire vs_in, input wire hs_in, input wire de_in,
    input wire [23:0] rgb_in,
    output wire vs_out, output wire hs_out, output wire de_out,
    output reg [23:0] rgb_out
);
    // Integral cells required, minimum 40x48 pixels. Default: 64x60.
    localparam integer CELL_W=IMAGE_W/GRID_W, CELL_H=IMAGE_H/GRID_H;
    localparam integer P=GRID_W*GRID_H, ADDR_W=$clog2(2*P);
    // Per channel: sign, integer digit (0/1), tenths, hundredths = 10 bits.
    (* ram_style="block", syn_ramstyle="block_ram" *) reg [29:0] tiles [0:2*P-1];
    reg wr0,wr1;
    reg [ADDR_W-1:0] wa0,wa1;
    reg [8:0] hundred_r,hundred_g,hundred_b;
    reg [29:0] bcd_data;
    function [8:0] to_hundred;
        input signed [15:0] a;
        reg [16:0] magnitude;
        reg [23:0] scaled;
        reg [7:0] n;
        begin
            magnitude=a[15] ? -$signed({a[15],a}) : {1'b0,a};
            // 100 = 64+32+4. Explicit constant shifts avoid a display DSP.
            scaled=({7'd0,magnitude}<<6)+({7'd0,magnitude}<<5)+
                   ({7'd0,magnitude}<<2)+24'd8192;
            n=(scaled>=24'd1638400) ? 8'd100 : scaled[21:14];
            to_hundred={a[15] && (n!=0),n};
        end
    endfunction
    function [9:0] to_bcd;
        input [8:0] h;
        reg [7:0] fraction;
        reg [3:0] tens,ones;
        begin
            fraction=(h[7:0]==100) ? 8'd0 : h[7:0];
            tens=fraction/10;
            ones=fraction-tens*10;
            to_bcd={h[8],(h[7:0]==100),tens,ones};
        end
    endfunction
    // Two conversion stages then RAM write; address and valid stay aligned.
    always @(posedge clk) begin
        if(!rst_n) begin
            wr0<=0; wr1<=0; wa0<=0; wa1<=0;
            hundred_r<=0; hundred_g<=0; hundred_b<=0; bcd_data<=0;
        end else begin
            wr0<=map_we; wr1<=wr0;
            if(map_we) begin
                wa0<=(write_bank ? P : 0)+map_addr;
                hundred_r<=to_hundred(map_data[47:32]);
                hundred_g<=to_hundred(map_data[31:16]);
                hundred_b<=to_hundred(map_data[15:0]);
            end
            if(wr0) begin
                wa1<=wa0;
                bcd_data<={to_bcd(hundred_r),to_bcd(hundred_g),to_bcd(hundred_b)};
            end
        end
    end
    reg [11:0] x,y,cx,cy;
    reg [7:0] gx;
    reg [ADDR_W-1:0] row_base;
    reg vs_d;
    wire on_grid=de_in && (cx==0 || cy==0 || x==IMAGE_W-1 || y==IMAGE_H-1);
    wire red_row=(cy>=8 && cy<16);
    wire green_row=(cy>=24 && cy<32);
    wire blue_row=(cy>=40 && cy<48);
    wire in_text=de_in && cx>=4 && cx<40 && (red_row || green_row || blue_row);
    // Only a 6-bit local coordinate enters character division/modulo.
    wire [5:0] text_x=cx[5:0]-6'd4;
    // Six 6x8 characters: R-0.85 / G+0.12 / B-1.00.
    reg [2:0] char0,char1,col0,col1,col2,row0,row1,row2;
    reg [1:0] color0,color1,color2;
    reg [ADDR_W-1:0] rd_addr;
    reg rd_enable;
    reg [29:0] tile_q;
    reg [3:0] vs_pipe,hs_pipe,de_pipe;
    reg [23:0] rgb0,rgb1,rgb2;
    reg [2:0] grid_pipe,text_pipe,show_pipe,valid_pipe;
    function [39:0] glyph;
        input [4:0] code;
        begin case(code)
            0:glyph=40'h03a33ae62e;
            1:glyph=40'h03884210c4;
            2:glyph=40'h07c444422e;
            3:glyph=40'h03e107420f;
            4:glyph=40'h0211f4a988;
            5:glyph=40'h03e107843f;
            6:glyph=40'h03a317842e;
            7:glyph=40'h008422221f;
            8:glyph=40'h03a317462e;
            9:glyph=40'h03a10f462e;
            10:glyph=40'h00000f8000;
            11:glyph=40'h00084f9080;
            13:glyph=40'h0108000000;
            14:glyph=40'h045257c62f;
            15:glyph=40'h03a31e862e;
            16:glyph=40'h03e317c62f;
            default:glyph=40'd0;
        endcase end
    endfunction
    reg [9:0] value;
    reg [4:0] code;
    always @* begin
        case(color1)
            0:value=tile_q[29:20];
            1:value=tile_q[19:10];
            default:value=tile_q[9:0];
        endcase
        case(char1)
            0:code=14+color1;
            1:code=valid_pipe[1] ? (value[9] ? 10 : 11) : 10;
            2:code=valid_pipe[1] ? {4'd0,value[8]} : 10;
            3:code=13;
            4:code=valid_pipe[1] ? {1'b0,value[7:4]} : 10;
            default:code=valid_pipe[1] ? {1'b0,value[3:0]} : 10;
        endcase
    end
    // Separate block RAM/channel/character selection from glyph lookup.
    reg [4:0] code_q;
    wire [39:0] dots=glyph(code_q);
    wire [5:0] bit_index=row2*5+col2;
    wire ink=(col2<5) && dots[bit_index];
    wire [23:0] text_color=(color2==0) ? 24'hff0000 :
                                  (color2==1) ? 24'h00ff00 : 24'h0000ff;
    // RAM is not reset; map_valid prevents unwritten/stale data being shown.
    always @(posedge clk) begin
        if(rst_n && wr1) tiles[wa1]<=bcd_data;
        if(rst_n && rd_enable) tile_q<=tiles[rd_addr];
    end
    always @(posedge clk) begin
        if(!rst_n) begin
            x<=0; y<=0; cx<=0; cy<=0; gx<=0; row_base<=0;
            vs_d<=0; overlay_active<=0; rd_addr<=0; rd_enable<=0;
            vs_pipe<=0; hs_pipe<=0; de_pipe<=0;
            rgb0<=0; rgb1<=0; rgb2<=0; rgb_out<=0; code_q<=0;
            grid_pipe<=0; text_pipe<=0; show_pipe<=0; valid_pipe<=0;
            char0<=0; char1<=0; col0<=0; col1<=0;
            row0<=0; row1<=0; color0<=0; color1<=0;
            col2<=0; row2<=0; color2<=0;
        end else begin
            vs_d<=vs_in;
            if(vs_in && !vs_d) begin
                x<=0; y<=0; cx<=0; cy<=0; gx<=0; row_base<=0;
                overlay_active<=overlay_enable;
            end else if(de_in) begin
                if(x==IMAGE_W-1) begin
                    x<=0; cx<=0; gx<=0; y<=y+1'b1;
                    if(cy==CELL_H-1) begin cy<=0; row_base<=row_base+GRID_W; end
                    else cy<=cy+1'b1;
                end else begin
                    x<=x+1'b1;
                    if(cx==CELL_W-1) begin cx<=0; gx<=gx+1'b1; end
                    else cx<=cx+1'b1;
                end
            end
            // Raster counters avoid pixel division by cell width/height.
            rd_enable<=de_in && overlay_active && map_valid;
            if(de_in) rd_addr<=(read_bank ? P : 0)+row_base+gx;
            char0<=text_x/6; col0<=text_x%6;
            row0<=cy[2:0]; color0<=red_row ? 0 : green_row ? 1 : 2;
            char1<=char0; col1<=col0; row1<=row0; color1<=color0;
            code_q<=code; col2<=col1; row2<=row1; color2<=color1;
            vs_pipe<={vs_pipe[2:0],vs_in};
            hs_pipe<={hs_pipe[2:0],hs_in};
            de_pipe<={de_pipe[2:0],de_in};
            rgb0<=rgb_in; rgb1<=rgb0; rgb2<=rgb1;
            grid_pipe<={grid_pipe[1:0],on_grid};
            text_pipe<={text_pipe[1:0],in_text};
            show_pipe<={show_pipe[1:0],overlay_active};
            valid_pipe<={valid_pipe[1:0],map_valid};
            if(show_pipe[2] && grid_pipe[2])
                rgb_out<=valid_pipe[2] ? 24'h40d080 : 24'hd0a040;
            else if(show_pipe[2] && text_pipe[2]) begin
                if(ink) rgb_out<=text_color;
                else rgb_out<={2'b00,rgb2[23:18],2'b00,rgb2[15:10],2'b00,rgb2[7:2]};
            end else rgb_out<=rgb2;
        end
    end
    assign vs_out=vs_pipe[3];
    assign hs_out=hs_pipe[3];
    assign de_out=de_pipe[3];
endmodule
