`timescale 1ns/1ps
// One outstanding burst; rotate and raster requests alternate when both wait.
module rotate_read_arb #(parameter AW=28, parameter PRIORITY_A=0)(
    input clk,rst_n,
    input [AW-1:0] a_addr,input [3:0] a_len,input a_valid,output a_ready,
    output a_rvalid,
    input [AW-1:0] b_addr,input b_valid,output b_ready,output b_rvalid,
    output [AW-1:0] araddr,output [3:0] arlen,output arvalid,input arready,
    input rvalid,rlast
);
    reg active,owner,prefer_b;
    wire choose_b=b_valid && (!a_valid || (!PRIORITY_A && prefer_b));
    // Latch a grant before exposing ARVALID: address remains stable on stalls.
    reg grant_valid,grant_b;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin active<=0; owner<=0; prefer_b<=0; grant_valid<=0; grant_b<=0; end
        else begin
            if(!active && !grant_valid && (a_valid || b_valid)) begin
                grant_valid<=1; grant_b<=choose_b;
            end
            if(arvalid && arready) begin
                grant_valid<=0; active<=1; owner<=grant_b; prefer_b<=!grant_b;
            end
            if(active && rvalid && rlast) active<=0;
        end
    end
    assign arvalid=grant_valid && !active;
    assign araddr=grant_b ? b_addr:a_addr;
    assign arlen=grant_b ? 4'd0:a_len;
    assign a_ready=arvalid && !grant_b && arready;
    assign b_ready=arvalid && grant_b && arready;
    assign a_rvalid=active && !owner && rvalid;
    assign b_rvalid=active && owner && rvalid;
endmodule
