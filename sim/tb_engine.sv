`timescale 1ns/1ps
module tb_engine;
`ifdef FULL
    localparam W=1920,H=1080, MAP="rom/map.hex",SRC="rom/source.hex",EXP="rom/expected.hex";
`else
    localparam W=32,H=24, MAP="sim/vectors_small/map.hex",SRC="sim/vectors_small/source.hex",EXP="sim/vectors_small/expected.hex";
`endif
    reg clk=0;always #4 clk=~clk;
    reg rst_n=0,start=0;
    wire busy,done,fault,rv,wv;
    wire [31:0] cycles,ra,wa;wire [3:0] len;wire [15:0] tag;
    wire [255:0] wd;
    reg ready=0,wready=0,sv=0;
    reg [255:0] sd;
    reg [15:0] st;
    ud_engine #(.W(W),.H(H),.ROM_FILE(MAP)) dut(clk,rst_n,start,32'd0,32'h600000,
        busy,done,fault,cycles,rv,ready,ra,len,tag,sv,st,sd,wv,wready,wa,wd);
    reg [7:0] source[0:W*H-1],expected[0:W*H-1];
    bit seen[0:W*H-1];
    integer qa[0:255],qt[0:255],qd[0:255];
    integer head=0,tail=0,tick=0,words=0,errors=0,addr,k,j;
    integer seed=32'h45aef21;
    initial begin
        $readmemh(SRC,source);$readmemh(EXP,expected);
        repeat(5) @(negedge clk);rst_n=1;
        repeat(3) @(negedge clk);start=1;@(negedge clk);start=0;
    end
    always @(negedge clk) if(rst_n) begin
        tick=tick+1;ready=(tail-head<200 && tick%7!=0);wready=tick%5!=0;sv=0;
        if(head<tail && tick>=qd[head%256]) begin
            st=qt[head%256];
            for(j=0;j<32;j++) begin
                if(qa[head%256]+j>=W*H) $fatal(1,"read outside source");
                sd[j*8+:8]=source[qa[head%256]+j];
            end
            head=head+1;sv=1;
        end
        if(tick>4000000) $fatal(1,"watchdog: ls=%d available=%b cb=%d running=%d draining=%d",dut.ls,dut.available,dut.cb,dut.running,dut.draining);
    end
    always @(posedge clk) if(rst_n) begin
        if(rv && ready) begin
            for(k=0;k<=len;k++) begin qa[tail%256]=ra+32*k;qt[tail%256]=tag+k;qd[tail%256]=tick+10+(tail%19);tail=tail+1;end
        end
        if(wv && wready) begin
            addr=wa-32'h600000;
            if(addr<0 || addr+31>=W*H) $fatal(1,"write address %h",wa);
            for(k=0;k<32;k++) begin
                if(seen[addr+k]) $fatal(1,"duplicate pixel %d",addr+k);
                seen[addr+k]=1;
                if(wd[k*8+:8] !== expected[addr+k]) begin
                    if(errors<8)$display("mismatch %d got %h expected %h",addr+k,wd[k*8+:8],expected[addr+k]);
                    errors=errors+1;
                end
            end
            words=words+1;
        end
        if(fault) $fatal(1,"engine fault");
        if(done) begin
            if(errors || words!=W*H/32) $fatal(1,"errors=%d words=%d",errors,words);
            $display("PASS engine %dx%d: %d pixels, %d cycles, %.3f ms at 125 MHz",W,H,W*H,cycles,cycles/125000.0);
            if(W==1920 && cycles>2083333) $fatal(1,"60 fps processing budget exceeded");
            $finish;
        end
    end
endmodule
