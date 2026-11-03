`timescale 1ns/1ps
module tb_dehaze_select;
    reg clk=0; always #5 clk=~clk;
    reg rst_n=0, enable=0, vs=0;
    reg [23:0] raw=0;
    wire [23:0] rgb;
    reg [23:0] history[0:7];
    integer i, checks=0;
    reg expected_mode=0;
    dcp_output_select dut(clk,rst_n,enable,vs,raw,24'habcdef,rgb);
    always @(posedge clk) begin
        if(!rst_n) for(i=0;i<8;i=i+1) history[i]=0;
        else begin
            for(i=7;i>0;i=i-1) history[i]=history[i-1];
            history[0]=raw;
            #1;
            if(rgb !== (expected_mode ? 24'habcdef : history[7]))
                $fatal(1,"bypass alignment / frame mode mismatch");
            checks=checks+1;
        end
    end
    task cycles(input integer n);
        repeat(n) begin @(negedge clk); raw=raw+1; end
    endtask
    initial begin
        cycles(3);rst_n=1;
        cycles(15);enable=1;
        cycles(15);vs=1;expected_mode=1;
        cycles(4);vs=0;
        cycles(10);enable=0;
        cycles(15);vs=1;expected_mode=0;
        cycles(4);vs=0;
        cycles(15);rst_n=0;
        cycles(3);rst_n=1;
        cycles(12);
        $display("PASS bypass alignment, frame-only switching, reset (%0d checks)",checks);
        $finish;
    end
endmodule
