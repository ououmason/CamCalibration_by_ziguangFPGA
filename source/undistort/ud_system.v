`timescale 1ns/1ps
`default_nettype none
// ============================================================================
// ud_system : 畸变矫正系统顶层（帧所有权 + 三条时间线的跨时钟域同步）
// ============================================================================
//
// 【三条时间线（三个独立时钟域）】
//   (1) 捕获时间线 pclk  ：输入像素时钟，ud_capture 每 32 个 RGB888 像素
//       产生连续的 R/G/B 三个 256 位捕获包。不能反压 HDMI。
//   (2) 计算时间线 clk   ：DDR 用户时钟(约125MHz)，ud_engine 按输出块顺序做
//       畸变矫正(或 ud_frame_copy 旁路直拷)。它不关心显示扫描位置。
//   (3) 显示时间线 oclk  ：输出像素时钟(148.5MHz)，ud_video_out 连续产生
//       HS/VS/DE 与像素流，不可被反压。
//
// 【两条时间线（计算 vs 显示）如何同步：帧所有权 + epoch】
//   计算线与显示线之间不交换像素级同步信号，也不要求"同时到达同一坐标"。
//   它们通过 DDR 里的三个结果帧槽位 + 状态机 + epoch 位间接同步：
//
//   1) 帧槽位所有权状态机：
//      源帧 : FREE -> CAPTURE -> READY -> PROCESS -> FREE
//      结果帧: FREE -> PROCESS -> READY -> DISPLAY -> FREE
//      只有完整帧写完后才发布 READY；处理中的源帧与显示中的结果帧禁止覆写。
//
//   2) 计算线在"有 READY 源 + 空闲结果槽"时启动 engine 处理，处理完成把结果
//      槽标为 READY。显示线只在 VS 帧边界(new_display)选取最新 READY 结果槽。
//
//   3) 跨时钟域的显示帧切换：
//      ud_video_out 每帧边界翻转 frame_toggle(out_toggle)，该信号经
//      toggle_sync 三级同步链回到 clk 域；clk 域比较 toggle_sync[2] != epoch
//      检测到 new_display，从而在显示时钟的帧边界安全地切换显示槽位。
//      旧显示槽在所有 DDR 读返回前保持锁定，避免读数被提前释放/覆写。
//
//   4) 显示数据携带 epoch 位：
//      显示读响应 tag[14] 作为 epoch 位，写进输出 FIFO 的 out_packet[256]。
//      ud_video_out 判断 data[256] != 本帧 epoch 时为 stale，丢弃旧帧残留，
//      防止帧切换时串帧。
//
// 【输入捕获如何进入计算域】
//   ud_capture 在 pclk 域打包，经 input_fifo(ud_async_fifo，Gray 指针异步
//   同步) 跨到 clk 域。捕获包带帧号[303:288]和字节偏移[287:256]，EOF 描述符
//   校验行数/像素数。先完整存帧，再由输出坐标驱动读取。
//
// 【复位】
//   三个时钟域各自用 ud_reset 做异步置位、同步释放；FIFO 两侧共同复位，
//   不在每个 VS 单独清 FIFO。
// ============================================================================
module ud_system #(
    parameter W = 1920,
    parameter H = 1080,
    parameter ROM_FILE = "rom/map.hex",
    parameter HT = 2200,
    parameter HS = 44,
    parameter HB = 148,
    parameter VT = 1125,
    parameter VS = 5,
    parameter VB = 36
) (
    input  wire                 clk,
    input  wire                 arst_n,
    input  wire                 pclk,
    input  wire                 oclk,
    input  wire                 vin_vs,
    input  wire                 vin_de,
    input  wire [7:0]           red,
    input  wire [7:0]           green,
    input  wire [7:0]           blue,

    output wire                 vout_hs,
    output wire                 vout_vs,
    output wire                 vout_de,
    output wire [23:0]          rgb,

    output wire [27:0]          axi_awaddr,
    output wire [3:0]           axi_awlen,
    output wire                 axi_awvalid,
    input  wire                 axi_awready,

    output wire [255:0]         axi_wdata,
    output wire [31:0]          axi_wstrb,
    input  wire                 axi_wready,
    input  wire                 axi_wlast,

    output wire [27:0]          axi_araddr,
    output wire [3:0]           axi_arlen,
    output wire [3:0]           axi_arid,
    output wire                 axi_arvalid,
    input  wire                 axi_arready,

    input  wire [255:0]         axi_rdata,
    input  wire [3:0]           axi_rid,
    input  wire                 axi_rvalid,
    input  wire                 axi_rlast,

    output wire                 error,
    output reg  [31:0]          dropped_frames,
    output wire [31:0]          processing_cycles,
    input  wire                 correction_enable,
    // Optional network reader, all signals in clk domain. Relative byte offsets.
    input  wire                 net_frame_request,
    output reg                  net_frame_valid,
    output reg [31:0]           net_frame_sequence,
    input  wire                 net_frame_release,
    input  wire                 net_read_request,
    output wire                 net_read_ready,
    input  wire [31:0]          net_read_offset,
    output wire                 net_read_data_valid,
    output wire [255:0]         net_read_data
);

    localparam FRAME_BYTES = W * H * 3;
    localparam FRAME_WORDS = FRAME_BYTES / 32;

    wire rst_n;
    wire prst_n;
    wire orst_n;

    ud_reset r0 (clk,  arst_n, rst_n);
    ud_reset r1 (pclk, arst_n, prst_n);
    ud_reset r2 (oclk, arst_n, orst_n);

    (* async_reg = "true" *) reg [1:0] mode_sync;
    reg proc_enable;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            mode_sync <= 0;
        else
            mode_sync <= {mode_sync[0], correction_enable};
    end

    wire [304:0] cap_in;
    wire [304:0] cap;
    wire         cap_in_valid;
    wire         cap_in_ready;
    wire         cap_valid;
    wire [8:0]   cap_level;
    wire         cap_ready;
    wire [31:0]  cap_overflows;

    ud_capture #(
        .W(W),
        .H(H)
    ) capture (
        pclk,
        prst_n,
        vin_vs,
        vin_de,
        red,
        green,
        blue,
        cap_in,
        cap_in_valid,
        cap_in_ready,
        cap_overflows
    );

    ud_async_fifo #(
        .WIDTH(305),
        .ABITS(8)
    ) input_fifo (
        pclk,
        prst_n,
        cap_in,
        cap_in_valid,
        cap_in_ready,
        ,
        clk,
        rst_n,
        cap,
        cap_valid,
        cap_ready,
        cap_level
    );

    reg [1:0] src_state [0:2];
    reg [1:0] dst_state [0:2];
    // Source: FREE, CAPTURE, READY, PROCESS. Result: FREE, PROCESS, READY, DISPLAY.
    reg [31:0] src_seq [0:2];
    reg [31:0] dst_seq [0:2];
    reg [31:0] sequence;

    reg [1:0] cap_slot;
    reg [1:0] proc_src;
    reg [1:0] proc_dst;
    reg [1:0] display_slot;
    reg net_active;
    reg [1:0] net_slot;
    reg [31:0] net_base;
    reg net_pending;

    reg cap_active;
    reg cap_bad;
    reg cap_commit;
    reg process_commit;
    reg display_valid;

    reg [15:0] cap_frame;
    reg [31:0] expected;

    reg [1:0] free_src;
    reg [1:0] free_dst;
    reg [1:0] ready_src;
    reg [1:0] ready_dst;

    reg has_free_src;
    reg has_free_dst;
    reg has_ready_src;
    reg has_ready_dst;

    integer i;
    integer j;

    always @* begin
        free_src = 0;
        free_dst = 0;
        ready_src = 0;
        ready_dst = 0;
        has_free_src = 0;
        has_free_dst = 0;
        has_ready_src = 0;
        has_ready_dst = 0;
        for (j = 2; j >= 0; j = j - 1) begin
            if (src_state[j] == 0) begin
                has_free_src = 1;
                free_src = j;
            end
            if (dst_state[j] == 0 && !(net_active && net_slot == j)) begin
                has_free_dst = 1;
                free_dst = j;
            end
            if (src_state[j] == 2 && (!has_ready_src || src_seq[j] > src_seq[ready_src])) begin
                has_ready_src = 1;
                ready_src = j;
            end
            if (dst_state[j] == 2 && (!has_ready_dst || dst_seq[j] > dst_seq[ready_dst])) begin
                has_ready_dst = 1;
                ready_dst = j;
            end
        end
    end

    wire cap_eof = cap[287:256] == 32'hffffffff;
    wire cap_new = cap_valid && !cap_eof && cap[287:256] == 0 && cap[303:288] != cap_frame;
    wire cap_good = cap_active && !cap_bad && !cap[304] && cap[303:288] == cap_frame && cap[287:256] == expected;

    wire [31:0] capture_address = {7'd0, cap_slot, 23'd0} + expected;

    wire engine_busy;
    wire engine_done;
    wire engine_fault;
    wire er_valid;
    wire er_ready;
    wire ew_valid;
    wire ew_ready;

    wire [31:0] er_addr;
    wire [31:0] ew_addr;
    wire [3:0]  er_len;
    wire [15:0] er_tag;
    wire [255:0] ew_data;

    reg engine_start;

    wire [31:0] src_base = {7'd0, proc_src, 23'd0};
    wire [31:0] dst_base = 32'h1800000 + {7'd0, proc_dst, 23'd0};

    wire response_valid;
    wire response_last;
    wire [15:0] response_tag;
    wire [255:0] response_data;

    wire corr_busy;
    wire corr_done;
    wire corr_fault;
    wire corr_rvalid;
    wire corr_wvalid;

    wire copy_busy;
    wire copy_done;
    wire copy_fault;
    wire copy_rvalid;
    wire copy_wvalid;

    wire [31:0] corr_cycles;
    wire [31:0] copy_cycles;
    wire [31:0] corr_raddr;
    wire [31:0] copy_raddr;
    wire [31:0] corr_waddr;
    wire [31:0] copy_waddr;

    wire [3:0] corr_len;
    wire [3:0] copy_len;
    wire [15:0] corr_tag;
    wire [15:0] copy_tag;
    wire [255:0] corr_data;
    wire [255:0] copy_data;

    wire process_response = response_valid && !response_tag[15] && !response_tag[13];

    // The mode is latched with the source/destination slots and cannot change in flight.
    ud_engine #(
        .W(W),
        .H(H),
        .ROM_FILE(ROM_FILE)
    ) engine (
        clk,
        rst_n,
        engine_start && proc_enable,
        src_base,
        dst_base,
        corr_busy,
        corr_done,
        corr_fault,
        corr_cycles,
        corr_rvalid,
        er_ready && proc_enable,
        corr_raddr,
        corr_len,
        corr_tag,
        process_response && proc_enable,
        response_tag,
        response_data,
        corr_wvalid,
        ew_ready && proc_enable,
        corr_waddr,
        corr_data
    );

    ud_frame_copy #(
        .FRAME_BYTES(FRAME_BYTES)
    ) bypass (
        clk,
        rst_n,
        engine_start && !proc_enable,
        src_base,
        dst_base,
        copy_busy,
        copy_done,
        copy_fault,
        copy_cycles,
        copy_rvalid,
        er_ready && !proc_enable,
        copy_raddr,
        copy_len,
        copy_tag,
        process_response && !proc_enable,
        response_tag,
        response_data,
        copy_wvalid,
        ew_ready && !proc_enable,
        copy_waddr,
        copy_data
    );

    assign engine_busy = corr_busy || copy_busy;
    assign engine_done = corr_done || copy_done;
    assign engine_fault = corr_fault || copy_fault;
    assign processing_cycles = proc_enable ? corr_cycles : copy_cycles;
    assign er_valid = proc_enable ? corr_rvalid : copy_rvalid;
    assign er_addr  = proc_enable ? corr_raddr  : copy_raddr;
    assign er_len   = proc_enable ? corr_len   : copy_len;
    assign er_tag   = proc_enable ? corr_tag   : copy_tag;
    assign ew_valid = proc_enable ? corr_wvalid : copy_wvalid;
    assign ew_addr  = proc_enable ? corr_waddr  : copy_waddr;
    assign ew_data  = proc_enable ? corr_data   : copy_data;

    wire out_toggle;
    (* async_reg = "true" *) reg [2:0] toggle_sync;
    reg epoch;
    wire new_display = toggle_sync[2] != epoch;

    reg [21:0] display_word;
    reg display_pending;
    reg [31:0] display_base;

    wire [256:0] out_packet;
    wire out_valid;
    wire out_ready;
    wire [8:0] out_level;
    wire [31:0] underflows;

    assign out_packet = {response_tag[14], response_data};

    // One display burst outstanding preserves raster order without a reorder RAM.
    wire display_response = response_valid && response_tag[15];
    wire [256:0] out_data;
    wire display_data_valid;
    wire display_data_ready;

    ud_async_fifo #(
        .WIDTH(257),
        .ABITS(8)
    ) output_fifo (
        clk,
        rst_n,
        out_packet,
        display_response,
        out_ready,
        out_level,
        oclk,
        orst_n,
        out_data,
        display_data_valid,
        display_data_ready,
        
    );

    ud_video_out #(
        .W(W),
        .H(H),
        .HT(HT),
        .HS(HS),
        .HB(HB),
        .VT(VT),
        .VS(VS),
        .VB(VB)
    ) display (
        oclk,
        orst_n,
        out_toggle,
        out_data,
        display_data_valid,
        display_data_ready,
        vout_hs,
        vout_vs,
        vout_de,
        rgb,
        underflows
    );

    wire dr_valid = display_valid && !display_pending && !new_display && display_word < FRAME_WORDS && out_level < 224;
    wire [3:0] dr_len = (FRAME_WORDS - display_word >= 16) ? 4'd15 : FRAME_WORDS - display_word - 1;
    wire ddr_rd_ready;

    // Display has a bounded burst, then compute can use all remaining read slots.
    wire nr_valid = net_active && !net_pending && net_read_request;
    assign net_read_ready = ddr_rd_ready && !dr_valid && net_active && !net_pending;
    assign net_read_data_valid = response_valid && !response_tag[15] && response_tag[13];
    assign net_read_data = response_data;
    assign er_ready = ddr_rd_ready && !dr_valid && !nr_valid;
    wire ddr_rd_valid = dr_valid || nr_valid || er_valid;
    wire [31:0] ddr_rd_addr = dr_valid ? display_base + (display_word << 5) :
                                         nr_valid ? net_base + net_read_offset : er_addr;
    wire [3:0] ddr_rd_len = dr_valid ? dr_len : nr_valid ? 4'd0 : er_len;
    wire [15:0] ddr_rd_tag = dr_valid ? {1'b1, epoch, 14'd0} : nr_valid ? 16'h2000 : er_tag;

    reg [1:0] writer;
    reg [4:0] write_count;
    reg prefer_engine;
    wire port_wr_ready;
    wire port_wr_idle;
    wire protocol_error;

    wire capture_write = writer == 1 && cap_valid && cap_good && !cap_eof;
    wire engine_write  = writer == 2 && ew_valid;
    wire capture_end   = expected == FRAME_BYTES - 32;
    wire engine_end    = ew_addr == dst_base + FRAME_BYTES - 32;
    wire burst_end     = write_count == 15 || (writer == 1 ? capture_end : engine_end);
    wire port_wr_valid = capture_write || engine_write;
    wire write_fire    = port_wr_valid && port_wr_ready;

    assign ew_ready = writer == 2 && port_wr_ready;

    wire capture_reject = cap_valid && !cap_new && !cap_eof && !cap_good;
    wire capture_flush  = writer == 1 && cap_valid && (!cap_good || cap_eof);

    assign cap_ready = !cap_commit && !cap_new && ((cap_eof && writer != 1) || (capture_reject && writer != 1) || (capture_write && port_wr_ready));

    ud_ddr_port port (
        clk,
        rst_n,
        ddr_rd_valid,
        ddr_rd_ready,
        ddr_rd_addr,
        ddr_rd_len,
        ddr_rd_tag,
        response_valid,
        response_tag,
        response_data,
        response_last,
        port_wr_valid,
        port_wr_ready,
        writer == 1 ? capture_address : ew_addr,
        writer == 1 ? cap[255:0] : ew_data,
        burst_end,
        capture_flush,
        port_wr_idle,
        protocol_error,
        axi_araddr,
        axi_arlen,
        axi_arid,
        axi_arvalid,
        axi_arready,
        axi_rdata,
        axi_rid,
        axi_rvalid,
        axi_rlast,
        axi_awaddr,
        axi_awlen,
        axi_awvalid,
        axi_awready,
        axi_wdata,
        axi_wstrb,
        axi_wready,
        axi_wlast
    );

    reg local_error;
    assign error = local_error || protocol_error || engine_fault;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < 3; i = i + 1) begin
                src_state[i] <= 0;
                dst_state[i] <= 0;
                src_seq[i]   <= 0;
                dst_seq[i]   <= 0;
            end
            sequence <= 0;
            cap_slot <= 0;
            proc_src <= 0;
            proc_dst <= 0;
            display_slot <= 0;
            net_active <= 0;
            net_slot <= 0;
            net_base <= 0;
            net_pending <= 0;
            net_frame_valid <= 0;
            net_frame_sequence <= 0;
            display_valid <= 0;
            cap_active <= 0;
            cap_bad <= 0;
            cap_commit <= 0;
            process_commit <= 0;
            cap_frame <= 0;
            expected <= 0;
            engine_start <= 0;
            proc_enable <= 0;
            writer <= 0;
            write_count <= 0;
            prefer_engine <= 0;
            dropped_frames <= 0;
            toggle_sync <= 0;
            epoch <= 0;
            display_word <= 0;
            display_pending <= 0;
            display_base <= 0;
            local_error <= 0;
        end else begin
            toggle_sync <= {toggle_sync[1:0], out_toggle};
            engine_start <= 0;
            net_frame_valid <= 0;
            // The extra reference prevents reuse even after DISPLAY becomes FREE.
            // Do not acquire on a display switch; latch one immutable result slot.
            if (!net_active && net_frame_request && display_valid && !new_display) begin
                net_active <= 1;
                net_slot <= display_slot;
                net_base <= display_base;
                net_frame_sequence <= dst_seq[display_slot];
                net_frame_valid <= 1;
            end
            if (nr_valid && net_read_ready)
                net_pending <= 1;
            if (net_read_data_valid)
                net_pending <= 0;
            if (net_frame_release && !net_pending && !nr_valid)
                net_active <= 0;
            if (display_response && !out_ready)
                local_error <= 1;
            if (dr_valid && ddr_rd_ready) begin
                display_word <= display_word + dr_len + 1;
                display_pending <= 1;
            end
            if (display_response && response_last)
                display_pending <= 0;

            // Keep the old display slot locked until all its DDR reads return.
            if (new_display && !display_pending) begin
                epoch <= toggle_sync[2];
                display_word <= 0;
                if (has_ready_dst) begin
                    if (display_valid)
                        dst_state[display_slot] <= 0;
                    for (i = 0; i < 3; i = i + 1)
                        if (dst_state[i] == 2)
                            dst_state[i] <= 0;
                    display_slot <= ready_dst;
                    display_base <= 32'h1800000 + {7'd0, ready_dst, 23'd0};
                    display_valid <= 1;
                    dst_state[ready_dst] <= 3;
                end
            end

            if (cap_new && !cap_commit && writer != 1 && port_wr_idle) begin
                if (cap_active) begin
                    src_state[cap_slot] <= 0;
                    dropped_frames <= dropped_frames + 1;
                end
                cap_frame <= cap[303:288];
                expected <= 0;
                cap_bad <= !has_free_src;
                cap_active <= has_free_src;
                if (has_free_src) begin
                    cap_slot <= free_src;
                    src_state[free_src] <= 1;
                end else
                    dropped_frames <= dropped_frames + 1;
            end

            if (cap_valid && cap_ready) begin
                if (cap_eof) begin
                    if (cap_active && !cap_bad && !cap[304] && cap[303:288] == cap_frame && expected == FRAME_BYTES)
                        cap_commit <= 1;
                    else if (cap_active) begin
                        src_state[cap_slot] <= 0;
                        cap_active <= 0;
                        dropped_frames <= dropped_frames + 1;
                    end
                end else if (capture_reject)
                    cap_bad <= 1;
            end

            if (cap_commit && port_wr_idle) begin
                cap_commit <= 0;
                cap_active <= 0;
                src_state[cap_slot] <= 2;
                src_seq[cap_slot] <= sequence;
                sequence <= sequence + 1;
            end

            if (!engine_busy && !engine_start && !engine_done && !process_commit && has_ready_src && has_free_dst) begin
                proc_enable <= mode_sync[1];
                proc_src <= ready_src;
                proc_dst <= free_dst;
                src_state[ready_src] <= 3;
                dst_state[free_dst] <= 1;
                engine_start <= 1;
            end

            if (engine_done)
                process_commit <= 1;

            if (process_commit && port_wr_idle) begin
                process_commit <= 0;
                src_state[proc_src] <= 0;
                dst_state[proc_dst] <= 2;
                dst_seq[proc_dst] <= src_seq[proc_src];
            end

            if (writer == 0 && port_wr_idle) begin
                if (cap_valid && cap_good && !cap_eof && !cap_new && cap_level >= ((FRAME_BYTES - expected >= 512) ? 16 : (FRAME_BYTES - expected) / 32) && (!ew_valid || !prefer_engine || cap_level > 192))
                    writer <= 1;
                else if (ew_valid)
                    writer <= 2;
                write_count <= 0;
            end

            if (write_fire) begin
                write_count <= write_count + 1;
                if (writer == 1)
                    expected <= expected + 32;
                if (burst_end) begin
                    writer <= 0;
                    prefer_engine <= writer == 1;
                end
            end

            if (capture_flush) begin
                writer <= 0;
                cap_bad <= 1;
            end
        end
    end

endmodule

// Exact RGB bypass, including the final row/column. No coordinate clamp or
// interpolation: one complete read burst is buffered before it can be written.
module ud_frame_copy #(
    parameter FRAME_BYTES = 2073600
) (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         start,
    input  wire [31:0]  src_base,
    input  wire [31:0]  dst_base,
    output wire         busy,
    output reg          done,
    output reg          fault,
    output reg [31:0]   cycles,
    output wire         rd_valid,
    input  wire         rd_ready,
    output wire [31:0]  rd_addr,
    output wire [3:0]   rd_len,
    output wire [15:0]  rd_tag,
    input  wire         rsp_valid,
    input  wire [15:0]  rsp_tag,
    input  wire [255:0] rsp_data,
    output wire         wr_valid,
    input  wire         wr_ready,
    output wire [31:0]  wr_addr,
    output reg  [255:0] wr_data
);

    localparam IDLE    = 0;
    localparam REQUEST = 1;
    localparam RECEIVE = 2;
    localparam FETCH   = 3;
    localparam WRITE   = 4;

    reg [2:0] state;
    reg [31:0] source;
    reg [31:0] target;
    reg [31:0] offset;
    reg [3:0]  index;
    reg [4:0]  received;
    reg [255:0] buffer [0:15];

    wire [31:0] remaining = (FRAME_BYTES - offset) >> 5;
    wire [4:0]  beats = remaining >= 16 ? 5'd16 : remaining[4:0];

    assign busy = state != IDLE;
    assign rd_valid = state == REQUEST;
    assign rd_addr = source + offset;
    assign rd_len = beats - 1'b1;
    assign rd_tag = 16'd0;
    assign wr_valid = state == WRITE;
    assign wr_addr = target + offset + {23'd0, index, 5'd0};

    always @(posedge clk) begin
        if (state == RECEIVE && rsp_valid)
            buffer[rsp_tag[3:0]] <= rsp_data;
        if (state == FETCH)
            wr_data <= buffer[index];
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            source <= 0;
            target <= 0;
            offset <= 0;
            index <= 0;
            received <= 0;
            done <= 0;
            fault <= 0;
            cycles <= 0;
        end else begin
            done <= 0;
            if (busy)
                cycles <= cycles + 1'b1;
            case (state)
                IDLE: if (start) begin
                    source <= src_base;
                    target <= dst_base;
                    offset <= 0;
                    index <= 0;
                    received <= 0;
                    cycles <= 0;
                    fault <= 0;
                    state <= REQUEST;
                end
                REQUEST: if (rd_ready) begin
                    received <= 0;
                    state <= RECEIVE;
                end
                RECEIVE: if (rsp_valid) begin
                    if (rsp_tag != {12'd0, received[3:0]} || received >= beats)
                        fault <= 1;
                    received <= received + 1'b1;
                    if (received + 1'b1 == beats) begin
                        index <= 0;
                        state <= FETCH;
                    end
                end
                FETCH: state <= WRITE;
                WRITE: if (wr_ready) begin
                    if ({1'b0, index} + 1'b1 == beats) begin
                        offset <= offset + {22'd0, beats, 5'd0};
                        if (offset + {22'd0, beats, 5'd0} == FRAME_BYTES) begin
                            done <= 1;
                            state <= IDLE;
                        end else
                            state <= REQUEST;
                    end else begin
                        index <= index + 1'b1;
                        state <= FETCH;
                    end
                end
                default: begin
                    state <= IDLE;
                    fault <= 1;
                end
            endcase
        end
    end

endmodule

`default_nettype wire
