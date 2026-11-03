`timescale 1ns/1ps
// Independent integer reference across extremes and random values.
module tb_he_color;
    reg clk=0;always #5 clk=~clk;
    reg rst_n=0,v=0,h=0,e=0;
    reg [7:0] a=0,b=0,c=0;
    wire [7:0] y,u,w,r,g,bb;
    wire fv,fh,fe,rv,rh,re;
    integer i,j,aa,bi,ci,checks=0;
    reg [26:0] forward[0:2],inverse[0:3];
    integer yy,uu,vv,rr,gg,blue;
    rgb2yuv f(clk,a,b,c,v,h,e,y,u,w,fv,fh,fe,8'd0,1'b0,8'd0,1'b0,rst_n);
    yuv2rgb z(clk,a,b,c,v,h,e,r,g,bb,rv,rh,re,rst_n);
    function integer sat(input integer n);sat=n<0?0:(n>255?255:n);endfunction
    always @(posedge clk)begin
        if(!rst_n)begin
            for(j=0;j<3;j++)forward[j]=0;
            for(j=0;j<4;j++)inverse[j]=0;
        end else begin
            for(j=2;j>0;j--)forward[j]=forward[j-1];
            for(j=3;j>0;j--)inverse[j]=inverse[j-1];
            yy=sat((77*integer'(a)+150*integer'(b)+29*integer'(c)+128)>>>8);
            uu=sat((-43*integer'(a)-85*integer'(b)+128*integer'(c)+32896)>>>8);
            vv=sat((128*integer'(a)-107*integer'(b)-21*integer'(c)+32896)>>>8);
            rr=sat((256*integer'(a)+359*(integer'(c)-128)+128)>>>8);
            gg=sat((256*integer'(a)-88*(integer'(b)-128)-183*(integer'(c)-128)+128)>>>8);
            blue=sat((256*integer'(a)+454*(integer'(b)-128)+128)>>>8);
            forward[0]={v,h,e,yy[7:0],uu[7:0],vv[7:0]};
            inverse[0]={v,h,e,rr[7:0],gg[7:0],blue[7:0]};
            #1;
            if(fe && {fv,fh,fe,y,u,w}!==forward[2])$fatal(1,"RGB to YUV saturation/rounding");
            if(re && {rv,rh,re,r,g,bb}!==inverse[3])$fatal(1,"YUV to RGB saturation/rounding");
            if(fe && re)checks++;
        end
    end
    initial begin
        repeat(3)@(negedge clk);rst_n=1;
        for(aa=0;aa<256;aa++)for(bi=0;bi<3;bi++)for(ci=0;ci<3;ci++)begin
            @(negedge clk);a=aa;b=(bi==0?0:(bi==1?128:255));c=(ci==0?0:(ci==1?128:255));
            v=aa[0];h=aa[1];e=1;
        end
        for(i=0;i<4096;i++)begin
            @(negedge clk);{a,b,c}=$random;v=i[0];h=i[1];e=1;
        end
        @(negedge clk);e=0;
        repeat(8)@(negedge clk);
        $display("PASS HE RGB/YUV independent signed rounding and saturation checks=%0d",checks);$finish;
    end
endmodule
