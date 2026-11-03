`timescale 1ns/1ps
module tb_dcp_dehaze;
    parameter W=7;
    parameter TM=38;
    parameter AIR_SCALE=49152;
    reg clk=0; always #5 clk=~clk;
    reg rst_n=0,vs=0,hs=0,de=0;
    reg [23:0] rgb=0;
    wire vo,ho,eo;
    wire [23:0] result;
    wire [7:0] anow;
    DCP_dehaze #(.IMAGE_WIDTH(W),.T_MIN(TM)) dut(
        .clk(clk),.rst_n(rst_n),.vsync_in(vs),.hsync_in(hs),.de_in(de),.pix_in_I(rgb),
        .vsync_out(vo),.hsync_out(ho),.de_out(eo),.pix_out_J(result),.A_now(anow));
    integer pixels[0:31][0:63];
    integer x=0,y=0,air=255,peak=0,seen=0,prevvs=0;
    integer rr,gg,bb,dark,yy,xx,dy,dx,p,tval,jr,jg,jb,i;
    integer checked=0;
    reg [26:0] expected[0:7];
    function integer mn(input integer a,b); mn=a<b?a:b; endfunction
    function integer mx(input integer a,b); mx=a>b?a:b; endfunction
    function integer recover(input integer c,a,t);
        integer z;
        begin z=(((c-a)*(65536/t)) >>> 8)+a;
            recover=z<0?0:(z>255?255:z); end
    endfunction
    always @(posedge clk) begin
        if(!rst_n) begin
            x=0;y=0;air=255;peak=0;seen=0;prevvs=0;
            for(i=0;i<8;i=i+1) expected[i]=0;
        end else begin
            for(i=7;i>0;i=i-1) expected[i]=expected[i-1];
            expected[0]={vs,hs,de,24'd0};
            if(vs && !prevvs) begin
                if(seen) air=mx(peak,1);
                peak=0;seen=0;x=0;y=0;
            end
            if(de) begin
                rr=rgb[23:16];gg=rgb[15:8];bb=rgb[7:0];
                pixels[y][x]=mn(mn(rr,gg),bb);
                dark=255;
                for(dy=0;dy<3;dy=dy+1)
                    for(dx=0;dx<3;dx=dx+1) begin
                        yy=mx(y-dy,0);xx=mx(x-dx,0);
                        dark=mn(dark,pixels[yy][xx]);
                    end
                p=(dark*(AIR_SCALE/air)) >> 8;
                tval=mx(TM,256-p);
                jr=recover(rr,air,tval);jg=recover(gg,air,tval);jb=recover(bb,air,tval);
                expected[0][23:0]={jr[7:0],jg[7:0],jb[7:0]};
                peak=mx(peak,mx(rr,mx(gg,bb)));seen=1;
                if(x==W-1) begin x=0;y=y+1;end else x=x+1;
            end
            prevvs=vs;
            #1;
            if({vo,ho,eo} !== expected[7][26:24]) $fatal(1,"sync mismatch");
            if(eo) begin
                if(result !== expected[7][23:0])
                    $fatal(1,"pixel %0d expected %h got %h",checked,expected[7][23:0],result);
                checked=checked+1;
            end
            if(anow !== peak[7:0]) $fatal(1,"A_now mismatch");
        end
    end
    task tick(input bit v,h,e,input reg [23:0] c);
        @(negedge clk);vs=v;hs=h;de=e;rgb=c;
    endtask
    integer f,r,c;
    reg [23:0] sample;
    initial begin
        repeat(3) @(negedge clk);rst_n=1;
        for(f=0;f<10;f=f+1) begin
            tick(1,0,0,0);tick(1,0,0,0);tick(0,0,0,0);
            for(r=0;r<6;r=r+1) begin
                for(c=0;c<W;c=c+1) begin
                    case(f)
                        0: sample=24'h000000;
                        1: sample=24'hffffff;
                        2: sample=24'h808080;
                        3: sample=(c%2)?24'hff0080:24'h00ff80;
                        default: sample=$random;
                    endcase
                    tick(0,1,1,sample);
                    if(f==5 && c%2==0) tick(0,1,0,24'hffffff);
                end
                // Exercise contiguous lines and variable blanking.
                if(f!=6) repeat(r%3+1) tick(0,0,0,0);
            end
        end
        repeat(12) tick(0,0,0,0);
        // Reset with pixels still in flight, then restart with dirty RAM.
        tick(1,0,0,0);tick(0,0,0,0);tick(0,1,1,24'h123456);
        @(negedge clk);rst_n=0;
        repeat(2) @(negedge clk);
        de=0;rst_n=1;
        tick(1,0,0,0);tick(0,0,0,0);
        for(c=0;c<W;c=c+1) tick(0,1,1,24'hff80ff);
        repeat(12) tick(0,0,0,0);
        $display("PASS DCP W=%0d T_MIN=%0d checked=%0d",W,TM,checked);$finish;
    end
endmodule
