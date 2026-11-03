`timescale 1ns/1ps
// Existing 32x24 correction/DDR behavioral test checks corrected RGB first.
// Append real DCP and gamma, checking the final video stream independently.
module tb_gamma_system;
    tb_system source();
    wire dv,dh,dd,gv,gh,gd;
    wire [23:0] drgb,grgb;
    reg [7:0] lut[0:255];
    reg [26:0] expected;
    integer checked=0;
    DCP_dehaze #(.IMAGE_WIDTH(32)) dehaze(
        .clk(source.oclk),.rst_n(source.rst),
        .vsync_in(source.ovs),.hsync_in(source.ohs),.de_in(source.ode),.pix_in_I(source.rgb),
        .vsync_out(dv),.hsync_out(dh),.de_out(dd),.pix_out_J(drgb),.A_now());
    gamma_video gamma_stage(source.oclk,source.rst,1'b1,dv,dh,dd,drgb,gv,gh,gd,grgb);
    initial $readmemh("sim/gamma_expected.hex",lut);
    always @(posedge source.oclk) begin
        if(source.rst) begin
            expected={dv,dh,dd,24'd0};
            if(dd) begin
                if(!gamma_stage.enabled) $fatal(1,"gamma not enabled before active video");
                expected[23:0]={lut[drgb[23:16]],lut[drgb[15:8]],lut[drgb[7:0]]};
                checked++;
            end
            #1;
            if({gv,gh,gd,grgb} !== expected) $fatal(1,"correction + DCP + gamma stream mismatch");
        end
    end
    final begin
        if(checked<32*24) $error("insufficient corrected output pixels");
        else $display("PASS correction + DCP + gamma output checked=%0d",checked);
    end
endmodule
