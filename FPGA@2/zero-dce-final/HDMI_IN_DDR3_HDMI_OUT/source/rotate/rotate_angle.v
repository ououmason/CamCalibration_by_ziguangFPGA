`timescale 1ns/1ps
// Sequential CORDIC, Q30 vector / Q16 centidegree phase. No divider or multiplier.
module rotate_sincos(input clk,rst_n,start,input signed [31:0] angle_cdeg,
    output busy,output reg valid,output reg signed [31:0] cos_q16,sin_q16);
    localparam IDLE=0,MODULO=1,PREP=2,ITER=3,FINISH=4;
    reg [2:0] state; reg [5:0] count;
    reg [31:0] magnitude; reg negative; reg [15:0] remainder;
    wire [16:0] trial={remainder,magnitude[31]};
    reg signed [31:0] vx,vy,z;
    reg cos_negative,sin_negative;
    // Fold magnitude modulo 360 degrees into 0..90; restore signs separately.
    // 180..360 never relies on shifting a negative phase or implicit casts.
    wire [15:0] quadrant_phase=(remainder<=16'd9000) ? remainder:
        (remainder<=16'd18000) ? 16'd18000-remainder:
        (remainder<=16'd27000) ? remainder-16'd18000:16'd36000-remainder;
    function signed [31:0] atan_cdeg_q16; input [4:0] index; begin case(index)
            5'd0: atan_cdeg_q16=32'sd294912000;
            5'd1: atan_cdeg_q16=32'sd174096719;
            5'd2: atan_cdeg_q16=32'sd91987925;
            5'd3: atan_cdeg_q16=32'sd46694507;
            5'd4: atan_cdeg_q16=32'sd23437865;
            5'd5: atan_cdeg_q16=32'sd11730358;
            5'd6: atan_cdeg_q16=32'sd5866610;
            5'd7: atan_cdeg_q16=32'sd2933484;
            5'd8: atan_cdeg_q16=32'sd1466764;
            5'd9: atan_cdeg_q16=32'sd733385;
            5'd10: atan_cdeg_q16=32'sd366693;
            5'd11: atan_cdeg_q16=32'sd183346;
            5'd12: atan_cdeg_q16=32'sd91673;
            5'd13: atan_cdeg_q16=32'sd45837;
            5'd14: atan_cdeg_q16=32'sd22918;
            5'd15: atan_cdeg_q16=32'sd11459;
            5'd16: atan_cdeg_q16=32'sd5730;
            5'd17: atan_cdeg_q16=32'sd2865;
            5'd18: atan_cdeg_q16=32'sd1432;
            5'd19: atan_cdeg_q16=32'sd716;
            default: atan_cdeg_q16=0;
        endcase end endfunction
    assign busy=state!=IDLE;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin state<=IDLE; count<=0; magnitude<=0; remainder<=0; negative<=0;
            vx<=0; vy<=0; z<=0; cos_negative<=0; sin_negative<=0;
            valid<=0; cos_q16<=65536; sin_q16<=0; end
        else begin
            valid<=0;
            case(state)
                IDLE: if(start) begin
                    magnitude<=angle_cdeg[31] ? (~angle_cdeg+1'b1):angle_cdeg;
                    negative<=angle_cdeg[31]; remainder<=0; count<=0; state<=MODULO;
                end
                MODULO: begin
                    remainder<=trial>=36000 ? trial-36000:trial;
                    magnitude<=magnitude<<1;
                    if(count==31) state<=PREP; else count<=count+1'b1;
                end
                PREP: begin
                    vx<=32'sd652032874; vy<=0; count<=0;
                    cos_negative<=remainder>16'd9000 && remainder<16'd27000;
                    sin_negative<=negative ^ (remainder>16'd18000);
                    z<=$signed({quadrant_phase,16'd0});
                    state<=ITER;
                end
                ITER: begin
                    if(z>=0) begin vx<=vx-(vy>>>count); vy<=vy+(vx>>>count); z<=z-atan_cdeg_q16(count[4:0]); end
                    else begin vx<=vx+(vy>>>count); vy<=vy-(vx>>>count); z<=z+atan_cdeg_q16(count[4:0]); end
                    if(count==19) state<=FINISH; else count<=count+1'b1;
                end
                FINISH: begin
                    // Exact axes also make 360 degrees bit-identical to zero.
                    case(remainder)
                        16'd0: begin cos_q16<=32'sd65536; sin_q16<=32'sd0; end
                        16'd9000: begin cos_q16<=32'sd0; sin_q16<=negative ? -32'sd65536:32'sd65536; end
                        16'd18000: begin cos_q16<=-32'sd65536; sin_q16<=32'sd0; end
                        16'd27000: begin cos_q16<=32'sd0; sin_q16<=negative ? 32'sd65536:-32'sd65536; end
                        default: begin
                            cos_q16<=((cos_negative ? -vx:vx)+32'sd8192)>>>14;
                            sin_q16<=((sin_negative ? -vy:vy)+32'sd8192)>>>14;
                        end
                    endcase
                    valid<=1; state<=IDLE;
                end
                default: state<=IDLE;
            endcase
        end
    end
endmodule

// Bundled-data request/ack mailbox: the source holds all 32 bits until ack.
// Repeated updates are coalesced automatically to the most recent source value.
module rotate_angle #(parameter integer UPDATE_CYCLES=1)(input angle_clk,input clk,input rst_n,
    input signed [31:0] angle_y_cdeg,
    output signed [31:0] cos_q16,sin_q16);
    reg [1:0] src_reset,dst_reset;
    always @(posedge angle_clk or negedge rst_n)
        if(!rst_n) src_reset<=0; else src_reset<={src_reset[0],1'b1};
    always @(posedge clk or negedge rst_n)
        if(!rst_n) dst_reset<=0; else dst_reset<={dst_reset[0],1'b1};
    reg signed [31:0] held_angle;
    localparam integer TIMER_BITS=(UPDATE_CYCLES>1) ? $clog2(UPDATE_CYCLES):1;
    reg [TIMER_BITS-1:0] cooldown;
    reg request,ack;
    (* ASYNC_REG="TRUE" *) reg ack1,ack2,req1,req2;
    wire calc_busy; wire calc_start=(req2!=ack) && !calc_busy;
    always @(posedge angle_clk or negedge rst_n) begin
        if(!rst_n) begin held_angle<=0; request<=0; ack1<=0; ack2<=0; cooldown<=0; end
        else if(!src_reset[1]) begin held_angle<=0; request<=0; ack1<=0; ack2<=0; cooldown<=0; end
        else begin
            ack1<=ack; ack2<=ack1;
            if(cooldown!=0) cooldown<=cooldown-1'b1;
            if(request==ack2 && angle_y_cdeg!=held_angle && cooldown==0) begin
                held_angle<=angle_y_cdeg; request<=!request; cooldown<=UPDATE_CYCLES-1;
            end
        end
    end
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin req1<=0; req2<=0; ack<=0; end
        else if(!dst_reset[1]) begin req1<=0; req2<=0; ack<=0; end
        else begin req1<=request; req2<=req1; if(calc_start) ack<=req2; end
    end
    rotate_sincos calc(.clk(clk),.rst_n(dst_reset[1]),.start(calc_start),
        .angle_cdeg(held_angle),.busy(calc_busy),.valid(),.cos_q16(cos_q16),.sin_q16(sin_q16));
endmodule

