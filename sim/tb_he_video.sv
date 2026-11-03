`timescale 1ns/1ps
module tb_he_video;
    `include "sim/he_vector_count.vh"
    reg clk=0;always #5 clk=~clk;
    reg rst_n=0,key=1,vs=0,hs=0,de=0;
    reg [23:0] rgb=0;
    wire enabled,vo,ho,eo;
    wire [23:0] result;
    reg [31:0] stimulus[0:VECTOR_COUNT-1];
    reg [26:0] reference[0:VECTOR_COUNT-1];
    reg [26:0] queue[0:7];
    integer t,i,j,checks=0,pixels=0;
    ud_key_toggle #(.DEBOUNCE_CYCLES(4)) key_control(clk,rst_n,key,enabled,);
    he_video #(.IMAGE_WIDTH(16),.IMAGE_HEIGHT(16)) dut(
        clk,rst_n,enabled,vs,hs,de,rgb,vo,ho,eo,result);
    initial begin
        $readmemh("sim/he_input.hex",stimulus);
        $readmemh("sim/he_expected.hex",reference);
        for(j=0;j<8;j++)queue[j]=0;
        for(t=0;t<VECTOR_COUNT;t++)begin
            @(negedge clk);
            {rst_n,key,vs,hs,de,rgb}=stimulus[t][28:0];
            @(posedge clk);
            if(!rst_n)for(i=0;i<8;i++)queue[i]=0;
            else begin
                for(i=7;i>0;i--)queue[i]=queue[i-1];
                queue[0]=reference[t];
            end
            #1;
            if({vo,ho,eo,result}!==queue[7])
                $fatal(1,"HE cycle=%0d expected=%h got=%h mode=%b map=%b state=%d",t,queue[7],{vo,ho,eo,result},dut.enabled,dut.equalizer.map_ready,dut.equalizer.state);
            checks++;
            if(eo)pixels++;
        end
        $display("PASS HE independent CDF/RGB, repeated bins, holes, malformed frame, keys, bypass, reset: cycles=%0d pixels=%0d",checks,pixels);
        $finish;
    end
endmodule
