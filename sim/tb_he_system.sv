`timescale 1ns/1ps
module tb_he_system;
    tb_system source();
    wire dv,dh,dd,gv,gh,gd,hv,hh,hd;
    wire [23:0] drgb,grgb,hrgb;
    DCP_dehaze #(.IMAGE_WIDTH(32)) dehaze(
        .clk(source.oclk),.rst_n(source.rst),
        .vsync_in(source.ovs),.hsync_in(source.ohs),.de_in(source.ode),.pix_in_I(source.rgb),
        .vsync_out(dv),.hsync_out(dh),.de_out(dd),.pix_out_J(drgb),.A_now());
    gamma_video gamma_stage(source.oclk,source.rst,1'b1,dv,dh,dd,drgb,gv,gh,gd,grgb);
    he_video #(.IMAGE_WIDTH(32),.IMAGE_HEIGHT(24)) he_stage(
        source.oclk,source.rst,1'b1,gv,gh,gd,grgb,hv,hh,hd,hrgb);
    integer histogram[0:255],mapping[0:255];
    localparam FRAME_PIXELS=32*24;
    `include "sim/he_reference.vh"
    integer i,sum,pixels=0,r,g,b,y,u,v,yy,rr,gg,bb;
    integer checks=0,mapped_pixels=0;
    integer startup_cycles=0;
    reg frame_started=0;
    reg prev_vs=0,map_valid=0;
    reg [26:0] expected[0:7];
    function integer sat(input integer n);sat=n<0?0:(n>255?255:n);endfunction
    always @(posedge source.oclk) begin
        if(!source.rst)begin
            for(i=0;i<256;i++)begin histogram[i]=0;mapping[i]=i;end
            for(i=0;i<8;i++)expected[i]=0;
            prev_vs=0;map_valid=0;pixels=0;startup_cycles=0;frame_started=0;
        end else begin
            startup_cycles++;
            if(gv && !prev_vs)begin
                if(frame_started && pixels==32*24)begin
                    build_reference();
                    map_valid=1;
                end
                for(i=0;i<256;i++)histogram[i]=0;
                pixels=0;
                if(startup_cycles>260)frame_started=1;
            end
            prev_vs=gv;
            for(i=7;i>0;i--)expected[i]=expected[i-1];
            expected[0]={gv,gh,gd,24'd0};
            if(gd)begin
                r=grgb[23:16];g=grgb[15:8];b=grgb[7:0];
                y=sat((77*r+150*g+29*b+128)>>>8);
                u=sat((-43*r-85*g+128*b+32896)>>>8);
                v=sat((128*r-107*g-21*b+32896)>>>8);
                if(frame_started)begin histogram[y]++;pixels++;end
                if(map_valid)begin
                    yy=mapping[y];u=u-128;v=v-128;
                    rr=sat((256*yy+359*v+128)>>>8);
                    gg=sat((256*yy-88*u-183*v+128)>>>8);
                    bb=sat((256*yy+454*u+128)>>>8);
                    expected[0][23:0]={rr[7:0],gg[7:0],bb[7:0]};
                    mapped_pixels++;
                end else expected[0][23:0]=grgb;
                checks++;
            end
            #1;
            if({hv,hh,hd,hrgb}!==expected[7])
                $fatal(1,"correction/DCP/gamma/HE final stream expected=%h got=%h",expected[7],{hv,hh,hd,hrgb});
        end
    end
    final begin
        if(mapped_pixels<32*24)$error("HE full-chain mapping coverage");
        else $display("PASS correction + DCP + gamma + HE reference: pixels=%0d mapped=%0d",checks,mapped_pixels);
    end
endmodule
