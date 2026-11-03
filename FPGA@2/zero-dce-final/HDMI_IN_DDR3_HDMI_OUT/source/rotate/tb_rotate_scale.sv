`timescale 1ns/1ps
// Native DDR model and independent per-pixel inverse-map reference.
// Run tb_rotate_scale (four small angles) or tb_rotate_scale_full (1080p).
module rotate_scale_case #(parameter OW=96,OH=54,SW=64,SH=36,C=61584,S=22415)(output reg done=0);
 reg clk=0,rst=0,frame_done=0,vs=0;
 always #4 clk=~clk;
 wire [27:0] ra,wa; wire rv,av,wv,cap,bank,valid,busy; wire [255:0] wd;
 reg rr=0,ar=0,wr=0,wl=0,rdvalid=0; reg [255:0] rddata=0;
 rotate_ddr #(.WIDTH(OW),.HEIGHT(OH),.SOURCE_WIDTH(SW),.SOURCE_HEIGHT(SH),.DYNAMIC(1)) dut(
 .clk(clk),.rst_n(rst),.frame_done(frame_done),.source_bank(1'b0),.vsync(vs),
 .cos_q16(C),.sin_q16(S),.capture_enable(cap),.display_bank(bank),.display_valid(valid),.busy(busy),
 .araddr(ra),.arvalid(rv),.arready(rr),.rdata(rddata),.rvalid(rdvalid),
 .awaddr(wa),.awvalid(av),.awready(ar),.wdata(wd),.wvalid(wv),.wready(wr),.wlast(wl));
 function automatic integer pixel(input integer x,y);
  pixel=((x*37+y*193+13)%65535)+1;
 endfunction
 function automatic integer blend(input integer a,b,c,d,fx,fy);
  blend=(a*(256-fx)*(256-fy)+b*fx*(256-fy)+c*(256-fx)*fy+d*fx*fy+32768)/65536;
 endfunction
 function automatic [15:0] golden(input integer index);
  longint signed qx,qy; integer x,y,ix,iy,nx,ny,fx,fy,p0,p1,p2,p3,r,g,b,cs,ss;
  begin
   // Direct matrix evaluation (independent of tile traversal/accumulators).
   cs=$rtoi($floor(1.0*C*SW/OW+0.5)); ss=$rtoi($floor(1.0*S*SW/OW+0.5));
   x=index%OW; y=index/OW;
   qx=(SW-1)*32768-$rtoi($floor(((OW-1)*1.0*cs+(OH-1)*1.0*ss)/2.0))+x*cs+y*ss;
   qy=(SH-1)*32768+$rtoi($floor(((OW-1)*1.0*ss-(OH-1)*1.0*cs)/2.0))-x*ss+y*cs;
   golden=0;
   if(qx>=-32768 && qx<SW*65536-32768 && qy>=-32768 && qy<SH*65536-32768) begin
    if(qx<0) qx=0; if(qx>(SW-1)*65536) qx=(SW-1)*65536;
    if(qy<0) qy=0; if(qy>(SH-1)*65536) qy=(SH-1)*65536;
    ix=qx>>>16; iy=qy>>>16; fx=(qx>>8)&255; fy=(qy>>8)&255;
    nx=(ix==SW-1)?ix:ix+1; ny=(iy==SH-1)?iy:iy+1;
    p0=pixel(ix,iy); p1=pixel(nx,iy); p2=pixel(ix,ny); p3=pixel(nx,ny);
    r=blend((p0>>11)&31,(p1>>11)&31,(p2>>11)&31,(p3>>11)&31,fx,fy);
    g=blend((p0>>5)&63,(p1>>5)&63,(p2>>5)&63,(p3>>5)&63,fx,fy);
    b=blend(p0&31,p1&31,p2&31,p3&31,fx,fy); golden=(r<<11)|(g<<5)|b;
   end
  end
 endfunction
 integer cycles=0,words=0,waitr=0,waitw=0,base=0,write_index=0;
 reg rp=0,wp=0; reg [27:0] old_ra=0,old_wa=0; reg stalled_r=0,stalled_w=0;
 reg [OW*OH/16-1:0] seen='0;
 always @(posedge clk) if(rst && !done) begin
  cycles=cycles+1;
  if(stalled_r && (!rv || ra!=old_ra)) $fatal(1,"read address changed on stall");
  if(stalled_w && (!av || wa!=old_wa)) $fatal(1,"write address changed on stall");
  stalled_r=rv && !rr; stalled_w=av && !ar; old_ra=ra; old_wa=wa;
  if(rv && rr) begin
   if(rp || ra[2:0]!=0 || ra>=SW*SH/2) $fatal(1,"source read out of range %h",ra);
   rp=1; base=(ra>>3)*16; waitr=3+cycles%7;
  end
  if(rdvalid) rp=0;
  if(av && ar) begin
   if(wp || wa[2:0]!=0 || wa<28'h1400000 || wa>=28'h1400000+OW*OH/2)
    $fatal(1,"destination address out of range %h",wa);
   wp=1; write_index=(wa-28'h1400000)*2; waitw=3;
  end
  if(wr) begin
   if(!wv || !wp) $fatal(1,"write data not ready");
   if(seen[write_index/16]) $fatal(1,"duplicate output word");
   seen[write_index/16]=1;
   for(integer n=0;n<16;n=n+1)
    if(wd[n*16+:16]!==golden(write_index+n))
     $fatal(1,"pixel=%0d C=%0d S=%0d actual=%h expected=%h",write_index+n,C,S,wd[n*16+:16],golden(write_index+n));
   wp=0; words=words+1;
  end
  if(valid) begin
   if(words!=OW*OH/16 || !(&seen) || !bank) $fatal(1,"premature bank swap");
   $display("SCALE PASS: source=%0dx%0d output=%0dx%0d C=%0d S=%0d checked=%0d pixels cycles=%0d",SW,SH,OW,OH,C,S,words*16,cycles);
   done=1;
  end
  if(cycles>50000000) $fatal(1,"timeout");
 end
 always @(negedge clk) if(rst && !done) begin
  rr=!rp && cycles%5!=0; ar=!wp && cycles%7!=0;
  wr=0; wl=0; rdvalid=0; vs=(cycles%10000<20);
  if(rp) begin
   if(waitr>0) waitr=waitr-1;
   else begin
    rdvalid=1;
    for(integer n=0;n<16;n=n+1) rddata[n*16+:16]=pixel((base+n)%SW,(base+n)/SW);
   end
  end
  if(wp) begin
   if(waitw>0) waitw=waitw-1;
   else if(cycles%4!=0) begin wr=1; wl=1; end
  end
 end
 initial begin repeat(5) @(negedge clk); rst=1; repeat(5) @(negedge clk);
  frame_done=1; @(negedge clk); frame_done=0; end
endmodule
module tb_rotate_scale;
 wire [3:0] done;
 rotate_scale_case #(.C(65536),.S(0)) a(done[0]);
 rotate_scale_case b(done[1]);
 rotate_scale_case #(.C(0),.S(65536)) c(done[2]);
 rotate_scale_case #(.C(61584),.S(-22415)) d(done[3]);
 initial begin wait(&done); $finish; end
endmodule
module tb_rotate_scale_full;
 parameter C=61584,S=22415;
 wire done;
 rotate_scale_case #(.OW(1920),.OH(1080),.SW(1280),.SH(720),.C(C),.S(S)) a(done);
 initial begin wait(done); $finish; end
endmodule

// Current rotation window: 540p source scaled to 720p.
module tb_rotate_scale_720p;
 parameter C=61584,S=22415;
 wire done;
 rotate_scale_case #(.OW(1280),.OH(720),.SW(960),.SH(540),.C(C),.S(S)) a(done);
 initial begin wait(done); $finish; end
endmodule
