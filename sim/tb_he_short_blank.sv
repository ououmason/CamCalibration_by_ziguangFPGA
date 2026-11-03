`timescale 1ns/1ps
module tb_he_short_blank;
    reg clk=0;always #5 clk=~clk;
    reg rst_n=0,v=0,h=0,e=0;
    reg [7:0] y=0,expected_y=0;
    wire vo,ho,eo,valid;
    wire [7:0] result;
    integer checks=0,i;
    hist_equalization #(.H_DISP(16),.V_DISP(1)) dut(
        clk,rst_n,h,v,y,e,ho,vo,result,eo,valid);
    always @(posedge clk)begin
        #1;
        if(rst_n)begin
            if({vo,ho,eo}!=={v,h,e})$fatal(1,"short blank sync");
            if(e)begin
                if(result!==expected_y)$fatal(1,"short blank pixel expected=%d got=%d",expected_y,result);
                checks++;
            end
        end
    end
    task tick(input bit vv,ee,input integer yy,expect_y);
        @(negedge clk);v=vv;h=ee;e=ee;y=yy;expected_y=expect_y;
    endtask
    task blank(input integer n);repeat(n)tick(0,0,0,0);endtask
    task start;tick(1,0,0,0);tick(1,0,0,0);tick(0,0,0,0);endtask
    initial begin
        blank(4);rst_n=1;blank(300);start();blank(10);
        for(i=0;i<16;i++)tick(0,1,64,64);
        // Begin the next frame before map calculation finishes.
        start();blank(4);
        for(i=0;i<16;i++)tick(0,1,i,i);
        blank(9500);
        if(dut.map_ready!==0 || dut.map_pending!==1)$fatal(1,"late table exposed before VS");
        start();blank(1000);
        // Late table is now committed; short-blank statistics frame was discarded.
        for(i=0;i<256;i++)tick(0,1,i,i);
        start();blank(1000);
        // An oversized frame must not overwrite the last valid map.
        for(i=0;i<16;i++)tick(0,1,i*16,i*16);
        blank(10);tick(0,0,0,0);
        $display("PASS HE short blank, deferred map commit, discarded/oversized frames: pixels=%d",checks);
        $finish;
    end
endmodule
