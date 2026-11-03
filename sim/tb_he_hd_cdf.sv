`timescale 1ns/1ps
// Focused 1080p arithmetic check: seed completed histogram, avoiding millions
// of identical stimulus pixels. The real RAM reads, divider and map writes run.
module tb_he_hd_cdf;
    reg clk=0;always #5 clk=~clk;
    reg rst_n=0,v=0,e=0;
    reg [7:0] y=0;
    wire [7:0] result;
    wire valid;
    integer i;
    integer scenario,k,previous;
    localparam FRAME_PIXELS=1920*1080;
    integer histogram[0:255],mapping[0:255];
    `include "sim/he_reference.vh"
    hist_equalization dut(
        .clk(clk),.rst_n(rst_n),.Y_hsync(1'b0),.Y_vsync(v),.Y_data(y),.Y_de(e),
        .hist_hsync(),.hist_vsync(),.hist_data(result),.hist_de(),.hist_valid(valid));
    initial begin
        repeat(3)@(negedge clk);rst_n=1;
        repeat(260)@(negedge clk);
        for(scenario=0;scenario<6;scenario++)begin
        e=0;
        // Drain the previous scenario's pending read-modify-write before
        // injecting a new completed histogram into the actual RAM.
        repeat(3)@(negedge clk);
        for(k=0;k<256;k++)histogram[k]=0;
        case(scenario)
            0: begin histogram[0]=1036800;histogram[128]=1036800;end
            1: histogram[0]=FRAME_PIXELS;
            2: histogram[128]=FRAME_PIXELS;
            3: for(k=48;k<=52;k++)histogram[k]=FRAME_PIXELS/5;
            4: for(k=0;k<256;k++)histogram[k]=FRAME_PIXELS/256;
            5: begin histogram[30]=FRAME_PIXELS-1;histogram[220]=1;end
        endcase
        build_reference();
        for(k=0;k<256;k++)
            dut.histogram_ram.u_ipm_distributed_sdpram_he_hist_ram.mem[k]=histogram[k];
        dut.pixel_count=2073600;dut.frame_started=1;dut.frame_ok=1;
        v=1;repeat(3)@(negedge clk);v=0;
        repeat(9500)@(negedge clk);
        if(!dut.map_ready)$fatal(1,"HD mapping not complete");
        for(i=0;i<256;i++)begin
            @(negedge clk);e=1;y=i;
            @(posedge clk);#1;
            if(!valid || result!==mapping[i])
                $fatal(1,"HD CDF bin %0d got %d",i,result);
            if(i>0 && result<previous)$fatal(1,"nonmonotonic mapping");
            if(i>0 && result-previous>2)$fatal(1,"excessive adjacent luma gain");
            if(scenario>=1 && scenario<=3 && result!=i)$fatal(1,"flat/noise protection");
            previous=result;
        end
        end
        $display("PASS HE 1080p: six histograms, 1536 LUT entries, monotonicity, noise gain and flat-frame protection");$finish;
    end
endmodule
