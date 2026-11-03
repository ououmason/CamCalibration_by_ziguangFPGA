`timescale 1ns/1ps
// Reuse the DCP numerical reference and its short, varied video stimulus.
module tb_gamma_chain;
    // Match the current dehaze LUT (Omega=0.7, scale=45875).
    tb_dcp_dehaze #(.AIR_SCALE(45875)) source();
    wire [23:0] selected, result;
    wire vo,ho,eo;
    reg gamma_enable=0, dehaze_enable=0;
    reg [23:0] raw_pipe[0:7];
    reg prev_vs=0, dehaze_mode=0;
    reg [1:0] dh_sync=0;
    reg [26:0] expected;
    reg input_vs_d=0;
    reg [7:0] lut[0:255];
    integer frames=0,checks=0,i;
    integer modes[0:3]='{0,0,0,0};
    dcp_output_select select_stage(source.clk,source.rst_n,dehaze_enable,
        source.vo,source.rgb,source.result,selected);
    gamma_video gamma_stage(source.clk,source.rst_n,gamma_enable,
        source.vo,source.ho,source.eo,selected,vo,ho,eo,result);
    initial $readmemh("sim/gamma_expected.hex",lut);
    // Change independent controls well before each downstream frame boundary.
    always @(posedge source.clk) begin
        input_vs_d <= source.vs;
        if(source.vs && !input_vs_d) begin
            frames++;
            dehaze_enable=(frames%4)>=2;
            gamma_enable=(frames%2)==1;
        end
    end
    always @(posedge source.clk) begin
        if(!source.rst_n) begin
            for(i=0;i<8;i++) raw_pipe[i]=0;
            prev_vs=0; dehaze_mode=0; dh_sync=0;
        end else begin
            // Gamma samples the selected stream before this edge.
            expected={source.vo,source.ho,source.eo,24'd0};
            if(source.eo) begin
                expected[23:0]=dehaze_mode ? source.result : raw_pipe[7];
                if(gamma_stage.enabled)
                    expected[23:0]={lut[expected[23:16]],lut[expected[15:8]],lut[expected[7:0]]};
                modes[{dehaze_mode,gamma_stage.enabled}]++;
            end
            if(source.vo && !prev_vs) dehaze_mode=dh_sync[1];
            prev_vs=source.vo; dh_sync={dh_sync[0],dehaze_enable};
            for(i=7;i>0;i--) raw_pipe[i]=raw_pipe[i-1];
            raw_pipe[0]=source.rgb;
            #2;
            if({vo,ho,eo,result} !== expected) $fatal(1,"DCP + gamma alignment expected=%h got=%h",expected,{vo,ho,eo,result});
            checks++;
        end
    end
    final begin
        for(integer m=0;m<4;m++)
            if(modes[m]==0) $error("missing combination %0d",m);
        $display("PASS DCP + gamma chain checks=%0d combinations=%0d/%0d/%0d/%0d",checks,modes[0],modes[1],modes[2],modes[3]);
    end
endmodule
