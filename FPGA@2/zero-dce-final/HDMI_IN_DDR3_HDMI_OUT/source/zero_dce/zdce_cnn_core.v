`timescale 1ns/1ps
// Official Zero-DCE++ graph, 32 channels, INT16, 8 pointwise MAC lanes.
// Single clock; no vendor primitives. All large arrays have synchronous reads.
// Feature banks are channel-major: channel*PIXELS + y*GRID_W + x.
// DW completes before PW starts, allowing the dead source bank to be reused.
module zdce_cnn_core #(
    parameter integer GRID_W = 30,
    parameter integer GRID_H = 18,
    parameter DW_WEIGHT_FILE = "source/zero_dce/weights/dw_weight.mem",
    parameter DW_BIAS_FILE = "source/zero_dce/weights/dw_bias.mem",
    parameter PW0_FILE = "source/zero_dce/weights/pw_weight_0.mem",
    parameter PW1_FILE = "source/zero_dce/weights/pw_weight_1.mem",
    parameter PW2_FILE = "source/zero_dce/weights/pw_weight_2.mem",
    parameter PW3_FILE = "source/zero_dce/weights/pw_weight_3.mem",
    parameter PW4_FILE = "source/zero_dce/weights/pw_weight_4.mem",
    parameter PW5_FILE = "source/zero_dce/weights/pw_weight_5.mem",
    parameter PW6_FILE = "source/zero_dce/weights/pw_weight_6.mem",
    parameter PW7_FILE = "source/zero_dce/weights/pw_weight_7.mem",
    parameter PW_BIAS_FILE = "source/zero_dce/weights/pw_bias.mem",
    parameter TANH_FILE = "source/zero_dce/weights/tanh.mem"
)(
    input wire clk, input wire rst_n,
    input wire thumb_we, input wire thumb_bank,
    input wire [15:0] thumb_addr, input wire [23:0] thumb_data,
    input wire start, input wire start_bank,
    output wire busy, output reg done,
    output reg curve_we, output reg [15:0] curve_addr,
    output reg [7:0] curve_x, output reg [7:0] curve_y,
    output reg [47:0] curve_data,
    output reg [31:0] cycles_last,
    output reg range_overflow_sticky
);
    localparam integer P = GRID_W*GRID_H;
    localparam [3:0] IDLE=0, DW_RUN=1, DW_DRAIN=2,
                     PW_RUN=3, PW_DRAIN=4, PW_STORE=5,
                     TANH_READ=6, TANH_SAVE=7,
                     TANH_QUANT=8, TANH_ABS=9, TANH_INDEX=10,
                     PW_FLUSH=11;
    reg [3:0] state;
    reg [2:0] layer;
    reg job_bank;
    reg [31:0] cycles;
    assign busy = (state != IDLE);

    // A=x1, B=x2, C=x3 then x6, D=x4 then x5. Concats use address
    // selection instead of a fifth/sixth 64-channel feature allocation.
    (* ram_style="block", syn_ramstyle="block_ram" *) reg signed [15:0] fa [0:32*P-1];
    (* ram_style="block", syn_ramstyle="block_ram" *) reg signed [15:0] fb [0:32*P-1];
    (* ram_style="block", syn_ramstyle="block_ram" *) reg signed [15:0] fc [0:32*P-1];
    (* ram_style="block", syn_ramstyle="block_ram" *) reg signed [15:0] fd [0:32*P-1];
    (* ram_style="block", syn_ramstyle="block_ram" *) reg signed [15:0] depth [0:64*P-1];
    (* ram_style="block", syn_ramstyle="block_ram" *) reg [23:0] thumbnail0 [0:P-1];
    (* ram_style="block", syn_ramstyle="block_ram" *) reg [23:0] thumbnail1 [0:P-1];

    (* rom_style="block", syn_romstyle="block_rom" *) reg signed [15:0] dw_weight [0:2618];
    (* rom_style="block", syn_romstyle="block_rom" *) reg signed [31:0] dw_bias [0:290];
    (* rom_style="block", syn_romstyle="block_rom" *) reg signed [15:0] pw0 [0:971];
    (* rom_style="block", syn_romstyle="block_rom" *) reg signed [15:0] pw1 [0:971];
    (* rom_style="block", syn_romstyle="block_rom" *) reg signed [15:0] pw2 [0:971];
    (* rom_style="block", syn_romstyle="block_rom" *) reg signed [15:0] pw3 [0:971];
    (* rom_style="block", syn_romstyle="block_rom" *) reg signed [15:0] pw4 [0:971];
    (* rom_style="block", syn_romstyle="block_rom" *) reg signed [15:0] pw5 [0:971];
    (* rom_style="block", syn_romstyle="block_rom" *) reg signed [15:0] pw6 [0:971];
    (* rom_style="block", syn_romstyle="block_rom" *) reg signed [15:0] pw7 [0:971];
    (* rom_style="distributed", syn_romstyle="distributed_rom" *) reg [255:0] pw_bias [0:24];
    (* rom_style="block", syn_romstyle="block_rom" *) reg [15:0] tanh_lut [0:512];
    initial begin
        $readmemh(DW_WEIGHT_FILE,dw_weight); $readmemh(DW_BIAS_FILE,dw_bias);
        $readmemh(PW0_FILE,pw0); $readmemh(PW1_FILE,pw1);
        $readmemh(PW2_FILE,pw2); $readmemh(PW3_FILE,pw3);
        $readmemh(PW4_FILE,pw4); $readmemh(PW5_FILE,pw5);
        $readmemh(PW6_FILE,pw6); $readmemh(PW7_FILE,pw7);
        $readmemh(PW_BIAS_FILE,pw_bias); $readmemh(TANH_FILE,tanh_lut);
    end
    function [6:0] input_channels;
        input [2:0] l;
        begin case(l)
            0: input_channels=3;
            1,2,3: input_channels=32;
            default: input_channels=64;
        endcase end
    endfunction
    function [11:0] dw_base;
        input [2:0] l;
        begin case(l)
            0:dw_base=0; 1:dw_base=27; 2:dw_base=315; 3:dw_base=603;
            4:dw_base=891; 5:dw_base=1467; default:dw_base=2043;
        endcase end
    endfunction
    function [8:0] db_base;
        input [2:0] l;
        begin case(l)
            0:db_base=0; 1:db_base=3; 2:db_base=35; 3:db_base=67;
            4:db_base=99; 5:db_base=163; default:db_base=227;
        endcase end
    endfunction
    function [9:0] pw_base;
        input [2:0] l;
        begin case(l)
            0:pw_base=0; 1:pw_base=12; 2:pw_base=140; 3:pw_base=268;
            4:pw_base=396; 5:pw_base=652; default:pw_base=908;
        endcase end
    endfunction
    // Activation format: signed 16 bit, 10 fractional bits. Bias is Q22.
    // Round before shifting, then saturate; never wrap at a ReLU boundary.
    function signed [15:0] quant_signed;
        input signed [39:0] sum;
        reg signed [40:0] q;
        begin
            q=($signed({sum[39],sum})+41'sd2048) >>> 12;
            if(q>32767) quant_signed=16'sh7fff;
            else if(q < -32768) quant_signed=16'sh8000;
            else quant_signed=q[15:0];
        end
    endfunction
    function signed [15:0] quant_relu;
        input signed [39:0] sum;
        begin quant_relu=(sum < 0) ? 16'sd0 : quant_signed(sum); end
    endfunction
    function overflows;
        input signed [39:0] sum;
        reg signed [40:0] q;
        begin
            q=($signed({sum[39],sum})+41'sd2048) >>> 12;
            overflows=(q>32767)||(q < -32768);
        end
    endfunction
    function signed [15:0] normalize;
        input [7:0] pixel;
        reg [16:0] expanded;
        begin expanded={1'b0,pixel,pixel}+17'd32; normalize=expanded>>6; end
    endfunction

    reg [5:0] dc;
    reg [15:0] dp;
    reg [7:0] dx,dy;
    reg [3:0] tap;
    wire [6:0] cin=input_channels(layer);
    reg [2:0] source_bank;
    reg padding;
    integer offset, neighbor;
    reg [15:0] fm_raddr;
    reg [15:0] thumb_raddr;
    always @* begin
        case(layer)
            0:source_bank=4;
            1:source_bank=0;
            2:source_bank=1;
            3:source_bank=2;
            4:source_bank=dc[5] ? 3 : 2;
            5:source_bank=dc[5] ? 3 : 1;
            default:source_bank=dc[5] ? 2 : 0;
        endcase
        offset=0; padding=0;
        case(tap)
            0:begin offset=-GRID_W-1; padding=(dx==0)||(dy==0); end
            1:begin offset=-GRID_W; padding=(dy==0); end
            2:begin offset=-GRID_W+1; padding=(dx==GRID_W-1)||(dy==0); end
            3:begin offset=-1; padding=(dx==0); end
            4:begin offset=0; padding=0; end
            5:begin offset=1; padding=(dx==GRID_W-1); end
            6:begin offset=GRID_W-1; padding=(dx==0)||(dy==GRID_H-1); end
            7:begin offset=GRID_W; padding=(dy==GRID_H-1); end
            8:begin offset=GRID_W+1; padding=(dx==GRID_W-1)||(dy==GRID_H-1); end
            default:begin offset=0; padding=1; end
        endcase
        neighbor=padding ? 0 : dp+offset;
        fm_raddr=dc[4:0]*P+neighbor;
        thumb_raddr=neighbor;
    end

    // Split border decode / address arithmetic from the high-fanout RAM
    // address nets. Delay the complete request, including the last DW tap,
    // so DW_DRAIN also commits the read issued on the final DW_RUN edge.
    (* syn_preserve=1, syn_keep=1 *) reg [15:0] fm_raddr_r;
    reg [15:0] thumb_raddr_r;
    reg [11:0] dw_weight_addr_r;
    reg [8:0] dw_bias_addr_r;
    reg dw_req_valid,dw_req_pad,dw_req_first,dw_req_last;
    reg [2:0] dw_req_source;
    reg [1:0] dw_req_color;
    reg [15:0] dw_req_addr;

    reg signed [15:0] fa_q,fb_q,fc_q,fd_q,dw_wq;
    reg [23:0] raw_q;
    reg signed [31:0] dw_bq;
    reg [2:0] dw_source_q;
    reg [1:0] dw_color_q;
    reg dw_pad_q, dw_valid_q, dw_first_q, dw_last_q;
    reg [15:0] dw_addr_q;
    reg signed [15:0] dw_selected;
    always @* begin
        case(dw_source_q)
            0:dw_selected=fa_q;
            1:dw_selected=fb_q;
            2:dw_selected=fc_q;
            3:dw_selected=fd_q;
            default:case(dw_color_q)
                0:dw_selected=normalize(raw_q[23:16]);
                1:dw_selected=normalize(raw_q[15:8]);
                default:dw_selected=normalize(raw_q[7:0]);
            endcase
        endcase
        if (dw_pad_q) dw_selected=0;
    end
    // Register bank/color selection, normalization and padding before the MAC.
    // Keep weight, bias, valid, first/last and output address on the same beat.
    reg signed [15:0] dw_input,dw_weight_i;
    reg signed [31:0] dw_bias_i;
    reg dw_valid_i,dw_first_i,dw_last_i;
    reg [15:0] dw_addr_i;
    reg dw_valid_m,dw_first_m,dw_last_m;
    reg signed [31:0] dw_product, dw_bias_m;
    reg [15:0] dw_addr_m;
    reg signed [39:0] dw_acc;
    wire signed [39:0] dw_product_ext={{8{dw_product[31]}},dw_product};
    wire signed [39:0] dw_sum=dw_first_m ?
        $signed({{8{dw_bias_m[31]}},dw_bias_m})+dw_product_ext : dw_acc+dw_product_ext;
    // Separate accumulation, quantization and RAM write. In particular, never
    // feed the RAM with quant_signed(dw_sum): that puts the accumulator adder,
    // rounding carry chain, saturation mux and RAM routing in one clock.
    reg dw_last_a;
    reg [15:0] dw_addr_a;
    reg depth_valid_w,depth_overflow_w;
    reg [15:0] depth_addr_w;
    reg signed [15:0] depth_data_w;
    wire depth_we=depth_valid_w;

    reg [15:0] pp;
    reg [1:0] pg;
    reg [6:0] pi;
    reg [2:0] store_lane;
    wire [15:0] depth_raddr=pi*P+pp;
    wire [9:0] pw_raddr=pw_base(layer)+pg*cin+pi;
    wire [4:0] pb_raddr=layer*4+pg;
    reg signed [15:0] depth_q;
    reg signed [15:0] pw_wq [0:7];
    reg [255:0] pw_bq;
    reg pw_valid_q,pw_first_q,pw_last_q;
    // Isolate the cascaded depth RAM read from the eight PW MAC inputs.
    // Preserve this beat so the long, shared RAM net is not a MAC input path.
    (* syn_preserve=1, syn_keep=1 *) reg signed [15:0] pw_input;
    reg signed [15:0] pw_weight_i [0:7];
    reg [255:0] pw_bias_i;
    reg pw_valid_i,pw_first_i,pw_last_i;
    reg pw_valid_m,pw_first_m,pw_last_m;
    reg signed [31:0] pw_product [0:7];
    reg [255:0] pw_bias_m;
    reg signed [39:0] pw_acc [0:7];
    reg [1:0] destination;
    always @* begin
        case(layer)
            0:destination=0; 1:destination=1; 2:destination=2;
            3,4:destination=3; default:destination=2;
        endcase
    end
    // A registered RAM write beat removes APM -> lane mux -> quantize ->
    // feature RAM from the reported critical path. Capture destination too:
    // layer changes must not reroute the last buffered write into another RAM.
    reg fm_we,fm_overflow_w;
    reg [1:0] fm_destination_w;
    reg [15:0] fm_waddr;
    reg signed [15:0] fm_wdata;
    // Register each operation before the ROM address. The former single-cycle
    // lane mux -> quantize -> abs -> round -> clamp -> ROM path failed setup.
    // The final layer has only RGB outputs; keep its mux to three MAC lanes.
    reg signed [39:0] tanh_acc;
    always @* begin
        case(store_lane)
            0:tanh_acc=pw_acc[0];
            1:tanh_acc=pw_acc[1];
            2:tanh_acc=pw_acc[2];
            default:tanh_acc=40'sd0;
        endcase
    end
    reg signed [15:0] tanh_input;
    reg [16:0] tanh_magnitude;
    wire [16:0] tanh_rounded=tanh_magnitude+17'd8;
    reg [9:0] tanh_index;
    reg [15:0] tanh_q;
    reg tanh_negative;
    wire signed [15:0] tanh_value=tanh_negative ? -$signed(tanh_q) : $signed(tanh_q);
    reg [47:0] curve_pack;

    // Memory ports. No reset/clear loops on feature RAM or coefficient ROM.
    always @(posedge clk) begin
        if (rst_n && thumb_we && !thumb_bank) thumbnail0[thumb_addr]<=thumb_data;
        if (rst_n && thumb_we && thumb_bank) thumbnail1[thumb_addr]<=thumb_data;
        if (rst_n && dw_req_valid) begin
            if(dw_req_source==0) fa_q<=fa[fm_raddr_r];
            if(dw_req_source==1) fb_q<=fb[fm_raddr_r];
            if(dw_req_source==2) fc_q<=fc[fm_raddr_r];
            if(dw_req_source==3) fd_q<=fd[fm_raddr_r];
            if(dw_req_source==4) begin
                if(job_bank) raw_q<=thumbnail1[thumb_raddr_r];
                else raw_q<=thumbnail0[thumb_raddr_r];
            end
            dw_wq<=dw_weight[dw_weight_addr_r];
            dw_bq<=dw_bias[dw_bias_addr_r];
        end
        if (rst_n && fm_we) begin
            case(fm_destination_w)
                0:fa[fm_waddr]<=fm_wdata;
                1:fb[fm_waddr]<=fm_wdata;
                2:fc[fm_waddr]<=fm_wdata;
                3:fd[fm_waddr]<=fm_wdata;
            endcase
        end
        if (rst_n && depth_we) depth[depth_addr_w]<=depth_data_w;
        if (rst_n && state==PW_RUN) begin
            depth_q<=depth[depth_raddr];
            pw_wq[0]<=pw0[pw_raddr]; pw_wq[1]<=pw1[pw_raddr];
            pw_wq[2]<=pw2[pw_raddr]; pw_wq[3]<=pw3[pw_raddr];
            pw_wq[4]<=pw4[pw_raddr]; pw_wq[5]<=pw5[pw_raddr];
            pw_wq[6]<=pw6[pw_raddr]; pw_wq[7]<=pw7[pw_raddr];
            pw_bq<=pw_bias[pb_raddr];
        end
        if (rst_n && state==TANH_READ) begin
            tanh_q<=tanh_lut[tanh_index];
            tanh_negative<=tanh_input[15];
        end
    end

    integer lane;
    always @(posedge clk) begin
        if (!rst_n) begin
            fm_raddr_r<=0; thumb_raddr_r<=0;
            dw_weight_addr_r<=0; dw_bias_addr_r<=0;
            dw_req_valid<=0; dw_req_pad<=0; dw_req_first<=0; dw_req_last<=0;
            dw_req_source<=0; dw_req_color<=0; dw_req_addr<=0;
            dw_valid_q<=0; dw_first_q<=0; dw_last_q<=0; dw_pad_q<=0;
            dw_source_q<=0; dw_color_q<=0; dw_addr_q<=0;
            dw_input<=0; dw_weight_i<=0; dw_bias_i<=0;
            dw_valid_i<=0; dw_first_i<=0; dw_last_i<=0; dw_addr_i<=0;
            dw_valid_m<=0; dw_first_m<=0; dw_last_m<=0;
            dw_product<=0; dw_bias_m<=0; dw_addr_m<=0; dw_acc<=0;
            dw_last_a<=0; dw_addr_a<=0;
            depth_valid_w<=0; depth_overflow_w<=0; depth_addr_w<=0; depth_data_w<=0;
            pw_valid_q<=0; pw_first_q<=0; pw_last_q<=0;
            pw_input<=0; pw_bias_i<=0;
            pw_valid_i<=0; pw_first_i<=0; pw_last_i<=0;
            pw_valid_m<=0; pw_first_m<=0; pw_last_m<=0; pw_bias_m<=0;
            fm_we<=0; fm_overflow_w<=0; fm_destination_w<=0;
            fm_waddr<=0; fm_wdata<=0;
            for(lane=0;lane<8;lane=lane+1) begin
                pw_weight_i[lane]<=0; pw_product[lane]<=0; pw_acc[lane]<=0;
            end
        end else begin
            dw_req_valid<=(state==DW_RUN);
            if(state==DW_RUN) begin
                fm_raddr_r<=fm_raddr; thumb_raddr_r<=thumb_raddr;
                dw_weight_addr_r<=dw_base(layer)+dc*9+tap;
                dw_bias_addr_r<=db_base(layer)+dc;
                dw_req_first<=(tap==0); dw_req_last<=(tap==8);
                dw_req_pad<=padding; dw_req_source<=source_bank;
                dw_req_color<=dc[1:0]; dw_req_addr<=dc*P+dp;
            end
            dw_valid_q<=dw_req_valid;
            dw_first_q<=dw_req_first; dw_last_q<=dw_req_last;
            dw_pad_q<=dw_req_pad; dw_source_q<=dw_req_source; dw_color_q<=dw_req_color;
            dw_addr_q<=dw_req_addr;
            dw_valid_i<=dw_valid_q;
            dw_first_i<=dw_first_q; dw_last_i<=dw_last_q; dw_addr_i<=dw_addr_q;
            if(dw_valid_q) begin
                dw_input<=dw_selected; dw_weight_i<=dw_wq; dw_bias_i<=dw_bq;
            end
            dw_valid_m<=dw_valid_i;
            dw_first_m<=dw_first_i; dw_last_m<=dw_last_i; dw_addr_m<=dw_addr_i;
            if(dw_valid_i) begin dw_product<=dw_input*dw_weight_i; dw_bias_m<=dw_bias_i; end
            if(dw_valid_m) dw_acc<=dw_sum;
            dw_last_a<=dw_valid_m && dw_last_m;
            if(dw_valid_m && dw_last_m) dw_addr_a<=dw_addr_m;
            depth_valid_w<=dw_last_a;
            if(dw_last_a) begin
                depth_data_w<=quant_signed(dw_acc);
                depth_overflow_w<=overflows(dw_acc);
                depth_addr_w<=dw_addr_a;
            end
            pw_valid_q<=(state==PW_RUN);
            pw_first_q<=(pi==0); pw_last_q<=(pi==cin-1);
            pw_valid_i<=pw_valid_q; pw_first_i<=pw_first_q; pw_last_i<=pw_last_q;
            if(pw_valid_q) begin
                pw_input<=depth_q; pw_bias_i<=pw_bq;
                for(lane=0;lane<8;lane=lane+1) pw_weight_i[lane]<=pw_wq[lane];
            end
            pw_valid_m<=pw_valid_i; pw_first_m<=pw_first_i; pw_last_m<=pw_last_i;
            if(pw_valid_i) begin
                pw_bias_m<=pw_bias_i;
                for(lane=0;lane<8;lane=lane+1) pw_product[lane]<=pw_input*pw_weight_i[lane];
            end
            if(pw_valid_m) begin
                for(lane=0;lane<8;lane=lane+1) begin
                    if(pw_first_m)
                        pw_acc[lane]<=$signed(pw_bias_m[32*lane+:32]) +
                                      $signed({{8{pw_product[lane][31]}},pw_product[lane]});
                    else pw_acc[lane]<=pw_acc[lane] +
                                      $signed({{8{pw_product[lane][31]}},pw_product[lane]});
                end
            end
            fm_we<=(state==PW_STORE);
            if(state==PW_STORE) begin
                fm_waddr<=(pg*8+store_lane)*P+pp;
                fm_wdata<=quant_relu(pw_acc[store_lane]);
                fm_destination_w<=destination;
                fm_overflow_w<=overflows(pw_acc[store_lane]) && !pw_acc[store_lane][39];
            end
        end
    end

    always @(posedge clk) begin
        if(!rst_n) begin
            state<=IDLE; layer<=0; job_bank<=0;
            dc<=0; dp<=0; dx<=0; dy<=0; tap<=0;
            pp<=0; pg<=0; pi<=0; store_lane<=0;
            done<=0; curve_we<=0; curve_addr<=0; curve_data<=0; curve_pack<=0;
            curve_x<=0; curve_y<=0;
            tanh_input<=0; tanh_magnitude<=0; tanh_index<=0;
            cycles<=0; cycles_last<=0; range_overflow_sticky<=0;
        end else begin
            done<=0; curve_we<=0;
            if(busy) cycles<=cycles+1'b1;
            if(depth_we && depth_overflow_w) range_overflow_sticky<=1;
            if(fm_we && fm_overflow_w) range_overflow_sticky<=1;
            case(state)
                IDLE:if(start) begin
                    job_bank<=start_bank; layer<=0; dc<=0; dp<=0; dx<=0; dy<=0; tap<=0;
                    pp<=0; pg<=0; pi<=0; cycles<=0; state<=DW_RUN;
                end
                DW_RUN:begin
                    if(tap==8) begin
                        tap<=0;
                        if(dp==P-1) begin
                            dp<=0; dx<=0; dy<=0;
                            if(dc==cin-1) state<=DW_DRAIN;
                            else dc<=dc+1'b1;
                        end else begin
                            dp<=dp+1'b1;
                            if(dx==GRID_W-1) begin dx<=0; dy<=dy+1'b1; end
                            else dx<=dx+1'b1;
                        end
                    end else tap<=tap+1'b1;
                end
                DW_DRAIN:if(depth_we && (depth_addr_w==cin*P-1)) begin
                    pp<=0; pg<=0; pi<=0; state<=PW_RUN;
                end
                PW_RUN:begin
                    if(pi==cin-1) begin pi<=0; state<=PW_DRAIN; end
                    else pi<=pi+1'b1;
                end
                PW_DRAIN:if(pw_valid_m && pw_last_m) begin
                    store_lane<=0;
                    state<=(layer==6) ? TANH_QUANT : PW_STORE;
                end
                PW_STORE:begin
                    if(store_lane==7) begin
                        store_lane<=0; pi<=0;
                        if(pg==3) begin
                            pg<=0;
                            if(pp==P-1) begin
                                state<=PW_FLUSH;
                            end else begin pp<=pp+1'b1; state<=PW_RUN; end
                        end else begin pg<=pg+1'b1; state<=PW_RUN; end
                    end else store_lane<=store_lane+1'b1;
                end
                PW_FLUSH:if(fm_we) begin
                    // This edge commits the final feature before DW reads it.
                    layer<=layer+1'b1; dc<=0; dp<=0; dx<=0; dy<=0; tap<=0;
                    state<=DW_RUN;
                end
                TANH_QUANT:begin
                    tanh_input<=quant_signed(tanh_acc);
                    state<=TANH_ABS;
                end
                TANH_ABS:begin
                    tanh_magnitude<=tanh_input[15] ?
                        -$signed({tanh_input[15],tanh_input}) : {1'b0,tanh_input};
                    state<=TANH_INDEX;
                end
                TANH_INDEX:begin
                    tanh_index<=(tanh_rounded>=17'd8192) ? 10'd512 : tanh_rounded[13:4];
                    state<=TANH_READ;
                end
                TANH_READ:state<=TANH_SAVE;
                TANH_SAVE:begin
                    case(store_lane)
                        0:curve_pack[47:32]<=tanh_value;
                        1:curve_pack[31:16]<=tanh_value;
                        default:curve_pack[15:0]<=tanh_value;
                    endcase
                    if(store_lane==2) begin
                        curve_data<={curve_pack[47:16],tanh_value};
                        curve_addr<=pp; curve_we<=1;
                        // DW leaves dx/dy at zero. Reuse them as the final
                        // layer's raster counters during PW; no divider or
                        // extra coordinate counter is needed in the map RAM.
                        curve_x<=dx; curve_y<=dy;
                        if(pp==P-1) begin
                            state<=IDLE; done<=1; cycles_last<=cycles+1'b1;
                        end else begin
                            pp<=pp+1'b1; pg<=0; pi<=0; state<=PW_RUN;
                            if(dx==GRID_W-1) begin dx<=0; dy<=dy+1'b1; end
                            else dx<=dx+1'b1;
                        end
                    end else begin store_lane<=store_lane+1'b1; state<=TANH_QUANT; end
                end
                default:state<=IDLE;
            endcase
        end
    end
endmodule
