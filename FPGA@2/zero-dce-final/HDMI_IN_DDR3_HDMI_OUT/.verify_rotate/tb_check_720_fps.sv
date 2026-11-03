`timescale 1ns/1ps
module tb_check_720_fps;
 wire [3:0] done;
 rotate_scale_case #(.OW(1280),.OH(720),.SW(960),.SH(540),.C(65536),.S(0)) a(done[0]);
 rotate_scale_case #(.OW(1280),.OH(720),.SW(960),.SH(540),.C(46341),.S(46341)) b(done[1]);
 rotate_scale_case #(.OW(1280),.OH(720),.SW(960),.SH(540),.C(0),.S(65536)) c(done[2]);
 rotate_scale_case #(.OW(1280),.OH(720),.SW(960),.SH(540),.C(-46341),.S(46341)) d(done[3]);
 initial begin wait(&done); $finish; end
endmodule
