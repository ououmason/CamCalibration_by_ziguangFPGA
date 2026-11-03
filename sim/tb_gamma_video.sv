`timescale 1ns/1ps
module tb_gamma_video;
    reg clk=0; always #5 clk=~clk;
    reg rst_n=0, key=1, vs=0, hs=0, de=0;
    reg [23:0] rgb=0;
    wire enable, vo, ho, eo;
    wire [23:0] result;
    reg [7:0] lut[0:255];
    integer checks=0, mapped_checks=0, raw_checks=0, i;
    reg mode=0, old_vs=0;
    reg [1:0] enable_history=0;
    reg [26:0] expected;
    ud_key_toggle #(.DEBOUNCE_CYCLES(4)) key_control(clk,rst_n,key,enable,);
    gamma_video dut(clk,rst_n,enable,vs,hs,de,rgb,vo,ho,eo,result);

    initial $readmemh("sim/gamma_expected.hex",lut);
    always @(posedge clk) begin
        if(!rst_n) begin
            mode=0; old_vs=0; enable_history=0;
            #1;
            if({vo,ho,eo,result} !== 27'd0) $fatal(1,"reset output");
        end else begin
            if(vs && !old_vs && !de) mode=enable_history[1];
            old_vs=vs;
            enable_history={enable_history[0],enable};
            expected={vs,hs,de,24'd0};
            if(de) begin
                expected[23:0]=mode ? {lut[rgb[23:16]],lut[rgb[15:8]],lut[rgb[7:0]]} : rgb;
                if(mode) mapped_checks++; else raw_checks++;
            end
            #1;
            if({vo,ho,eo,result} !== expected)
                $fatal(1,"gamma/timing mode=%b input=%h expected=%h got=%h",mode,rgb,expected,{vo,ho,eo,result});
            checks++;
        end
    end
    task tick(input bit v,h,e,input reg [23:0] c);
        @(negedge clk); vs=v; hs=h; de=e; rgb=c;
    endtask
    task sweep;
        for(i=0;i<256;i++) begin
            tick(0,1,1,{8'(i),8'(255-i),8'(i^85)});
            if(i%17==0) tick(0,0,0,24'hffffff);
        end
    endtask
    task click(input bit target);
        // Bounce is shorter than the debounce threshold.
        key=0; repeat(2) tick(0,1,1,24'h123456);
        key=1; repeat(8) tick(0,1,1,24'h123456);
        if(enable!==!target) $fatal(1,"bounce toggled mode");
        key=0; repeat(24) tick(0,1,1,24'h123456);
        if(enable!==target) $fatal(1,"click/hold mode");
        key=1; repeat(12) tick(0,1,1,24'h123456);
        if(enable!==target) $fatal(1,"release mode");
    endtask
    task frame_start;
        tick(1,0,0,0); tick(1,0,0,0); tick(0,0,0,0);
    endtask
    initial begin
        repeat(3) tick(0,0,0,0); rst_n=1;
        repeat(6) tick(0,0,0,0);
        frame_start(); sweep();
        click(1); sweep(); // Still bypass until next VS.
        frame_start(); sweep();
        click(0); sweep(); // Still gamma until next VS.
        frame_start(); sweep();
        // Reset with active pixels in flight, then enable again.
        click(1); frame_start(); tick(0,1,1,24'h808080);
        rst_n=0; repeat(3) tick(0,0,0,0); rst_n=1;
        repeat(8) tick(0,0,0,0);
        frame_start(); sweep(); click(1); frame_start(); sweep();
        tick(0,0,0,0); tick(0,0,0,0);
        if(mapped_checks<768 || raw_checks<768) $fatal(1,"coverage");
        $display("PASS gamma LUT RGB sweep, timing, debounce, frame switching, reset: checks=%0d mapped=%0d bypass=%0d",checks,mapped_checks,raw_checks);
        $finish;
    end
    initial begin #100000; $fatal(1,"timeout"); end
endmodule
