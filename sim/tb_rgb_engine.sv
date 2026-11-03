`timescale 1ns/1ps
module tb_rgb_engine;
`ifdef FULL
    localparam W=1920,H=1080,MAP="rom/map.hex",SRC="rom/source.hex",EXP="sim/rgb_expected_full.hex";
`else
    localparam W=32,H=24,MAP="sim/vectors_small/map.hex",SRC="sim/vectors_small/source.hex",EXP="sim/rgb_expected_small.hex";
`endif
    localparam BYTES=W*H*3;
    reg clk=0; always #4 clk=~clk;
    reg rst_n=0,start=0;
    wire busy,done,fault,rv,wv;
    wire [31:0] cycles,ra,wa;
    wire [3:0] len;
    wire [15:0] tag;
    wire [255:0] wd;
    reg ready=0,wready=0,sv=0;
    reg [255:0] sd;
    reg [15:0] st;
    ud_engine #(.W(W),.H(H),.ROM_FILE(MAP)) dut(
        clk,rst_n,start,32'd0,32'h1800000,
        busy,done,fault,cycles,rv,ready,ra,len,tag,sv,st,sd,wv,wready,wa,wd);
    reg [7:0] source[0:W*H-1], expected[0:W*H-1];
    bit seen[0:BYTES/32-1];
    integer qa[0:255],qt[0:255],qd[0:255];
    integer head=0,tail=0,tick=0,words=0,errors=0,addr,k,j,a,group,ch,pix;
    integer channel_errors[0:2]='{0,0,0};
    reg [7:0] want;
    initial begin
        $readmemh(SRC,source);
        $readmemh(EXP,expected);
        repeat(5) @(negedge clk); rst_n=1;
        repeat(3) @(negedge clk); start=1; @(negedge clk); start=0;
    end
    always @(negedge clk) if(rst_n) begin
        tick=tick+1;
        ready=(tail-head<200 && tick%7!=0);
        wready=tick%5!=0;
        sv=0;
        if(head<tail && tick>=qd[head%256]) begin
            st=qt[head%256];
            for(j=0;j<32;j++) begin
                a=qa[head%256]+j;
                if(a<0 || a>=BYTES) $fatal(1,"read outside source %d",a);
                group=a/96; ch=(a%96)/32; pix=group*32+a%32;
                sd[j*8+:8]=(ch==0) ? source[pix] : (ch==1 ? 8'd37 : 8'ha5);
            end
            head=head+1; sv=1;
        end
        if(tick>4000000) $fatal(1,"watchdog: ls=%d cb=%d",dut.ls,dut.cb);
    end
    always @(posedge clk) if(rst_n) begin
        if(rv && ready) begin
            for(k=0;k<=len;k++) begin
                qa[tail%256]=ra+32*k;
                qt[tail%256]=tag+k;
                qd[tail%256]=tick+10+(tail%19);
                tail=tail+1;
            end
        end
        if(wv && wready) begin
            addr=wa-32'h1800000;
            if(addr<0 || addr+31>=BYTES || addr%32!=0) $fatal(1,"write address %h",wa);
            if(seen[addr/32]) $fatal(1,"duplicate word %d",addr/32);
            seen[addr/32]=1;
            for(k=0;k<32;k++) begin
                a=addr+k; group=a/96; ch=(a%96)/32; pix=group*32+a%32;
                want=(ch==0) ? expected[pix] : (ch==1 ? 8'd37 : 8'ha5);
                if(wd[k*8+:8] !== want) begin
                    channel_errors[ch]=channel_errors[ch]+1;
                    if(errors<8) $display("mismatch %d ch=%d got=%h want=%h",pix,ch,wd[k*8+:8],want);
                    errors=errors+1;
                end
            end
            words=words+1;
        end
        if(fault) $fatal(1,"engine fault");
        if(done) begin
            if(errors || words!=BYTES/32) $fatal(1,"errors=%d channel=%d,%d,%d words=%d",errors,channel_errors[0],channel_errors[1],channel_errors[2],words);
            $display("PASS RGB engine %dx%d: %d pixels, %d cycles, %.3f ms",W,H,W*H,cycles,cycles/125000.0);
            if(W==1920 && cycles>=2000000) $fatal(1,"16 ms processing budget exceeded");
            $finish;
        end
    end
endmodule
