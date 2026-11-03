`timescale 1ns/1ps
module tb_system;
`ifdef FULL
    localparam W=1920,H=1080,HT=2200,VT=1125,HS=44,HB=148,VS=5,VB=36;
    localparam MAP="source/undistort/rom/map.hex", TARGET_FRAMES=2,MAX_TICKS=15000000;
`else
`ifdef HE_SYSTEM
    // Allow the HE CDF builder to finish in vertical blanking.
    localparam W=32,H=24,HT=64,VT=200,HS=2,HB=8,VS=2,VB=150;
    localparam MAP="sim/vectors_small/map.hex", TARGET_FRAMES=4,MAX_TICKS=200000;
`else
    localparam W=32,H=24,HT=64,VT=40,HS=2,HB=8,VS=2,VB=4;
    localparam MAP="sim/vectors_small/map.hex", TARGET_FRAMES=8,MAX_TICKS=65000;
`endif
`endif
    reg clk=0,pclk=0,oclk=0;
    always #4 clk=~clk;
    always #3.367 pclk=~pclk;
    always #3.368 oclk=~oclk;
    reg rst=0;
    reg [11:0] ih=0,iv=0;
    reg [7:0] input_pixel=8'h60;
    reg in_vs=0,in_de=0;
    integer input_frame=0;
`ifdef PATTERN
    reg [7:0] expected[0:W*H-1];
    reg [7:0] expected_g[0:W*H-1],expected_b[0:W*H-1];
    integer ix,iy;
    initial begin
        $readmemh("sim/rgb_expected_small.hex",expected);
        $readmemh("sim/rgb_expected_small_g.hex",expected_g);
        $readmemh("sim/rgb_expected_small_b.hex",expected_b);
    end
`endif
    wire ohs,ovs,ode;wire [23:0] rgb;
    wire [7:0] gray=rgb[23:16];
    wire [27:0] awaddr,araddr;wire [3:0] awlen,arlen,arid;
    wire awvalid,arvalid;reg awready=0,arready=0,wready=0,wlast=0;
    wire [255:0] wdata;wire [31:0] wstrb;
    reg [255:0] rdata=0;reg [3:0] rid=0;reg rvalid=0,rlast=0;
    wire error;wire [31:0] dropped,cycles;
`ifdef MODE_SWITCH
    reg key=1;
    wire mode_enable,mode_led;
    ud_key_toggle #(.DEBOUNCE_CYCLES(8)) key_control(clk,rst,key,mode_enable,mode_led);
    reg [7:0] raw_expected[0:W*H-1];
    integer bypass_frames=0,corrected_frames=0,returned_frames=0,phase=0;
    bit match_raw=1,match_corrected=1,was_busy=0,previous_mode=0;
    initial begin
        $readmemh("sim/vectors_small/source.hex",raw_expected);
        wait(bypass_frames>=2);
        wait(dut.engine_busy);@(negedge clk);
        key=0;repeat(3) @(negedge clk);key=1;repeat(3) @(negedge clk);
        key=0;repeat(16) @(negedge clk);
        if(mode_enable!==1 || mode_led!==1) $fatal(1,"first click did not enable mode/LED");
        phase=1;
        wait(corrected_frames>=3);
        if(mode_enable!==1) $fatal(1,"holding key toggled repeatedly");
        key=1;repeat(16) @(negedge clk);
        if(mode_enable!==1 || mode_led!==1) $fatal(1,"release disabled latched mode");
        wait(dut.engine_busy && dut.port.occupied!=0);@(negedge clk);
        key=0;repeat(16) @(negedge clk);
        if(mode_enable!==0 || mode_led!==0) $fatal(1,"second click did not disable mode/LED");
        phase=2;
        key=1;
    end
    always @(posedge clk) if(rst) begin
        if(was_busy && dut.engine_busy && previous_mode!==dut.proc_enable) $fatal(1,"mode changed within a processed frame");
        was_busy=dut.engine_busy;previous_mode=dut.proc_enable;
    end
`else
    wire mode_enable=1'b1;
`endif
    ud_system #(.W(W),.H(H),.HT(HT),.HS(HS),.HB(HB),.VT(VT),.VS(VS),.VB(VB),
        .ROM_FILE(MAP)) dut(clk,rst,pclk,oclk,in_vs,in_de,
        input_pixel,
`ifdef PATTERN
        input_pixel^8'h5a,8'd255-input_pixel,
`else
        input_pixel+8'd17,input_pixel^8'h5a,
`endif
        ohs,ovs,ode,rgb,
        awaddr,awlen,awvalid,awready,wdata,wstrb,wready,wlast,
        araddr,arlen,arid,arvalid,arready,rdata,rid,rvalid,rlast,error,dropped,cycles,mode_enable);
    reg [7:0] mem[0:48*1024*1024-1];
    integer tick=0,waddr=0,wcount=0,wdelay=0,writes=0;
    integer max_processing_cycles=0,processed_frames=0;
    bit write_active=0;
    bit pending[0:15];
    integer addr[0:15],count[0:15],delay_until[0:15];
    integer chosen=-1,rr=0,k,n;
    initial begin #101 rst=1;end
    always @(negedge pclk) if(rst) begin
        in_vs=iv<VS;
        in_de=ih>=HS+HB && ih<HS+HB+W && iv>=VS+VB && iv<VS+VB+H;
`ifdef PATTERN
        ix=ih-HS-HB;iy=iv-VS-VB;
        input_pixel=((ix*3+iy*5)^((ix>>4)&1?127:0)^((iy>>4)&1?63:0))&255;
`endif
`ifdef FAULT
        if(input_frame==3 && ih==HS+HB+W-1 && iv==VS+VB+H-1) in_de=0;
`endif
        if(ih==HT-1) begin
            ih=0;
            if(iv==VT-1) begin
                iv=0;input_frame++;
                input_pixel=8'h40+((input_frame%3)*8'h28);
            end else iv++;
        end else ih++;
    end
    // Return read bursts across IDs in round-robin order, with gaps and varying latency.
    always @(negedge clk) if(rst) begin
        tick++;arready=tick%5!=0;awready=!write_active && tick%7!=0;
        wready=write_active && tick>=wdelay && tick%4!=0;
        wlast=wready && wcount==1;
        rvalid=0;rlast=0;chosen=-1;
        for(n=15;n>=0;n--) if(pending[(rr+n)%16] && tick>=delay_until[(rr+n)%16]) chosen=(rr+n)%16;
        if(chosen>=0 && tick%3!=0) begin
            rid=chosen;rvalid=1;rlast=count[chosen]==1;
            for(k=0;k<32;k++) rdata[k*8+:8]=mem[addr[chosen]+k];
            rr=(chosen+1)%16;
        end
        if(tick>MAX_TICKS) $fatal(1,"system watchdog writer=%d cap_active=%d expected=%d cap_level=%d engine_busy=%d error=%d",dut.writer,dut.cap_active,dut.expected,dut.cap_level,dut.engine_busy,error);
    end
    always @(posedge clk) if(rst) begin
        if(dut.engine_done) begin
            processed_frames++;
            if(cycles>max_processing_cycles) max_processing_cycles=cycles;
`ifdef FULL
            if(cycles>=2000000) $fatal(1,"RGB processing exceeded 16 ms: %d cycles",cycles);
`endif
        end
        if(awvalid && awready) begin
            if(write_active) $fatal(1,"overlapping write bursts");
            waddr=awaddr*4;wcount=awlen+1;wdelay=tick+4;write_active=1;
        end
        if(wready) begin
            for(k=0;k<32;k++) if(wstrb[k]) mem[waddr+k]=wdata[k*8+:8];
            waddr+=32;wcount--;writes++;
            if(wcount==0)write_active=0;
        end
        if(arvalid && arready) begin
            if(pending[arid]) $fatal(1,"ID reused while occupied");
            pending[arid]=1;addr[arid]=araddr*4;count[arid]=arlen+1;delay_until[arid]=tick+7+(arid%5);
        end
        if(rvalid) begin
            addr[rid]+=32;count[rid]--;
            if(rlast)pending[rid]=0;
        end
        if(error) $fatal(1,"system protocol/engine error");
        if(dut.cap_active && dut.engine_busy && dut.cap_slot==dut.proc_src) $fatal(1,"capture overwrites source");
        if(dut.display_valid && dut.engine_busy && dut.display_slot==dut.proc_dst) $fatal(1,"processing overwrites display");
    end
    reg prev_vs=0;
    integer output_frame=0,pixels=0,good_frames=0;
    reg [7:0] frame_gray=0;
    reg [23:0] frame_rgb=0;
    always @(negedge oclk) if(rst) begin
        if(ovs && !prev_vs) begin
            if(pixels!=0 && pixels!=W*H) $fatal(1,"display pixel count %d",pixels);
`ifdef MODE_SWITCH
            if(pixels==W*H && output_frame>=4) begin
                if(match_raw && !match_corrected) begin bypass_frames++;if(phase==2)returned_frames++;end
                else if(match_corrected && !match_raw) corrected_frames++;
                else $fatal(1,"mode frame is mixed or test image does not distinguish modes");
            end
            match_raw=1;match_corrected=1;
            if(returned_frames>=3) begin
                if(dropped || dut.cap_overflows || error) $fatal(1,"mode test dropped/corrupted frames");
                $display("PASS mode switch: %d RGB bypass frames, %d corrected frames, %d RGB bypass frames after second click",bypass_frames,corrected_frames,returned_frames);
                $finish;
            end
`endif
            if(pixels==W*H && frame_gray!=0)good_frames++;
            pixels=0;output_frame++;
`ifndef MODE_SWITCH
            if(good_frames==TARGET_FRAMES) begin
                if(dut.cap_overflows!=0) $fatal(1,"capture overflow");
`ifndef FAULT
                if(dropped!=0) $fatal(1,"unexpected dropped frames: %d",dropped);
`endif
`ifdef FAULT
                if(dropped==0) $fatal(1,"bad input frame was not rejected");
`endif
                $display("PASS system: %d intact nonblack display frames, %d DDR writes, drops=%d, processed=%d, max cycles=%d",good_frames,writes,dropped,processed_frames,max_processing_cycles);
                $finish;
            end
`endif
        end
        prev_vs=ovs;
        if(ode) begin
            if(pixels==0) begin
                frame_gray=gray;
                frame_rgb=rgb;
`ifndef PATTERN
                if(gray!=0 && gray!=96 && gray!=104 && gray!=144 && gray!=64) $fatal(1,"incorrect red %d",gray);
                if(rgb!=0 && rgb!=={gray,gray+8'd17,gray^8'h5a}) $fatal(1,"incorrect RGB %h",rgb);
`endif
            end
`ifdef PATTERN
`ifdef MODE_SWITCH
            if(output_frame>=4) begin
                if(rgb!=={raw_expected[pixels],raw_expected[pixels]^8'h5a,8'd255-raw_expected[pixels]}) match_raw=0;
                if(rgb!=={expected[pixels],expected_g[pixels],expected_b[pixels]}) match_corrected=0;
                if(!match_raw && !match_corrected) $fatal(1,"mixed/misaligned frame at pixel %d",pixels);
            end
`else
            if(output_frame>=4 && rgb!=={expected[pixels],expected_g[pixels],expected_b[pixels]})
                $fatal(1,"system pixel %d got %h expected %h",pixels,rgb,{expected[pixels],expected_g[pixels],expected_b[pixels]});
`endif
            if(output_frame>=4)frame_gray=1;
`else
            if(rgb!==frame_rgb) $fatal(1,"torn/misaligned display frame %d pixel %d got=%h first=%h",output_frame,pixels,rgb,frame_rgb);
`endif
            pixels++;
        end
    end
endmodule
