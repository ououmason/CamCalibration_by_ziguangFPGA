`timescale 1ns/1ps
module tb_frame_copy;
    localparam BYTES=1920*1080*3;
    reg clk=0;always #4 clk=~clk;
    reg rst_n=0,start=0,rr=0,wr=0,rv=0;
    wire busy,done,fault,req,wvalid;
    wire [31:0] cycles,ra,wa;
    wire [3:0] len;wire [15:0] tag;
    reg [15:0] rt=0;reg [255:0] rd=0;
    wire [255:0] wd;
    ud_frame_copy #(.FRAME_BYTES(BYTES)) dut(clk,rst_n,start,32'h800000,32'h2000000,
        busy,done,fault,cycles,req,rr,ra,len,tag,rv,rt,rd,wvalid,wr,wa,wd);
    integer tick=0,base=0,remaining=0,beat=0,delay_until=0,written=0,k;
    function [7:0] source_pixel(input integer offset);
        integer pixel;
        integer channel;
        begin
            pixel=(offset/96)*32+offset%32;
            channel=(offset%96)/32;
            source_pixel=((pixel%1920)*3+(pixel/1920)*5) ^ (pixel>>7) ^ (channel*85);
        end
    endfunction
    initial begin
        repeat(4) @(negedge clk);rst_n=1;
        @(negedge clk);start=1;@(negedge clk);start=0;
    end
    always @(negedge clk) if(rst_n) begin
        tick++;rr=tick%7!=0;wr=tick%5!=0;rv=0;
        if(remaining!=0 && tick>=delay_until && tick%3!=0) begin
            rv=1;rt=beat;
            for(k=0;k<32;k++)rd[k*8+:8]=source_pixel(base+beat*32+k);
        end
        if(tick>2083333) $fatal(1,"bypass exceeded one 60 Hz frame period");
    end
    always @(posedge clk) if(rst_n) begin
        if(req && rr) begin
            if(remaining!=0 || ra<32'h800000 || ra+(len+1)*32>32'h800000+BYTES) $fatal(1,"bad read request");
            base=ra-32'h800000;beat=0;remaining=len+1;delay_until=tick+13;
        end
        if(rv) begin remaining--;beat++;end
        if(wvalid && wr) begin
            if(wa!==32'h2000000+written) $fatal(1,"nonsequential/missing write");
            for(k=0;k<32;k++)if(wd[k*8+:8]!==source_pixel(written+k))$fatal(1,"bypass pixel mismatch %d",written+k);
            written+=32;
        end
        if(fault) $fatal(1,"copy fault");
        if(done) begin
            if(written!=BYTES) $fatal(1,"truncated frame %d",written);
            $display("PASS full RGB bypass: %d exact bytes, %d cycles, %.3f ms at 125 MHz",written,cycles,cycles/125000.0);
            $finish;
        end
    end
endmodule
