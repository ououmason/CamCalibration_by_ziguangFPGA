`timescale 1ns/1ps
`default_nettype none

// ============================================================================
// ud_engine : 畸变矫正计算核心（源块预取 + 坐标/像素双线性流水线 + 结果写回）
// ============================================================================
//
// 【整体数据流】
//   1. 加载 ROM：按 16x16 输出块顺序读入该块 4 个角控制点（U/V 各 24 位 U12.12）。
//   2. 计算源块包围矩形：由 4 个控制点的 min/max 得到预取范围，
//      发出字节寻址的突发读请求（DDR），把源块读入片上 tile 缓存。
//   3. 逐像素计算：对块内每个输出像素，用 ud_coord 双线性插值得到源坐标，
//      三个通道共用坐标和源块范围，并行插值得到 RGB888 像素。
//   4. 结果写回：每 32 像素按 R/G/B 三个 256 位字写回 DDR。
//
// 【两条时间线之一：计算时间线（核心时钟 clk 域）】
//   本模块运行在 DDR 用户时钟 clk（约 125MHz）域，是整个矫正的"生产"端。
//   它并不逐像素跟踪显示扫描位置，而是由外部 ud_system 以帧粒度启动，
//   按输出块顺序独立推进。与显示时间线仅通过帧所有权/epoch 机制间接同步。
//
// 【块内固定延迟流水线（与显示时间线无关的片上对齐）】
//   坐标计算(ud_coord，3 拍) -> tile_ram 采样(1 拍) -> 像素插值(ud_bilinear，3 拍)，
//   共计 7 拍固定延迟。输出写地址、结果带号、块末标记均通过 address_pipe[0..7]、
//   bank_pipe、last_pipe 走相同长度的移位链，保证地址与数据同拍到达。
//   注意：此处的固定延迟只用于片上deterministic流水线，不用于猜测 DDR 返回时间。
//   DDR 返回用 tag/ID 匹配（见 ud_ddr_port），与这条片上流水线解耦。
//
// 【输出 strip（结果带）双缓冲】
//   结果按行带状缓冲（每带 16 行 x 1920 像素 x 3 通道），两个 bank 交替填充和写回。
//   一个带写满后，按连续 256 位突发写回 DDR，避免结果像素零散写。
// ============================================================================
module ud_engine #(
    parameter W = 1920,
    parameter H = 1080,
    parameter ROM_FILE = "rom/map.hex"
) (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         start,
    input  wire [31:0]  src_base,
    input  wire [31:0]  dst_base,
    output reg          busy,
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
    output wire [255:0] wr_data
);

    // ---- 输出块网格参数 ----
    // NX/NY：完整 16x16 块数（含不完整边块）；GC/GR：控制点网格列/行数
    localparam NX = (W + 15) / 16;
    localparam NY = (H + 15) / 16;
    localparam GC = (W - 1 + 15) / 16 + 1;
    localparam GR = (H - 1 + 15) / 16 + 1;
    localparam WORDS = W / 32;   // 每行 256 位字数（1920/32 = 60）

    // 计算足以表示 depth 个地址的 bit 数（向上取整 log2）
    function integer address_bits;
        input integer depth;
        integer n;
        begin
            address_bits = 0;
            for (n = depth - 1; n > 0; n = n >> 1)
                address_bits = address_bits + 1;
            if (address_bits == 0)
                address_bits = 1;
        end
    endfunction

    localparam ROM_ABITS = address_bits(GC * GR);

    // ---- 装载控制点与源块范围 ----
    reg [31:0] source;          // 源帧基址
    reg [31:0] target;          // 结果帧基址
    reg [47:0] corner [0:7];    // 相邻两块的 4 角控制点：低 24 位 U，高 24 位 V
    reg [11:0] bx [0:1];        // 当前填充块的起始 x（字节）
    reg [11:0] by [0:1];        // 当前填充块的起始 y（行）
    reg [11:0] sx [0:1];        // 源块预取起始 x（32 像素对齐）
    reg [11:0] sy [0:1];        // 源块预取起始 y
    reg [5:0]  sh [0:1];        // 源块预取高度（行数）
    reg        two_words [0:1]; // 源块预取宽度是否跨两个 32 像素组
    reg [1:0]  available;       // 对应 bank 是否已填充好
    reg        lb;              // load bank：当前正在填充/装载的组（0/1）
    reg        cb;              // compute bank：当前正在计算的组（0/1）
    reg [3:0]  ls;              // 装载状态机（0..7）
    reg [11:0] lx;              // 当前装载块的块列号
    reg [11:0] ly;              // 当前装载块的块行号
    reg [5:0]  issue_row;       // 已发出的源块读行数
    reg [7:0]  received;        // 已收到的源块读响应数
    reg        load_end;        // 所有块是否已装载完
    reg [ROM_ABITS-1:0] rom_addr;
    wire [47:0] rom_q;
    wire rom_en = busy && !load_end && ls >= 1 && ls <= 4;   // 只在这 4 个状态读 ROM

    // ---- ROM 读地址选择（在唯一的同步读端口前选地址）----
    // 状态 1..4 依次发出 {ly,lx} 块 4 个角的地址；ROM 输出在下一状态可用。
    always @* begin
        case (ls)
            1: rom_addr = ly * GC + lx;
            2: rom_addr = ly * GC + lx + 1;
            3: rom_addr = (ly + 1) * GC + lx;
            4: rom_addr = (ly + 1) * GC + lx + 1;
            default: rom_addr = 0;
        endcase
    end

    ud_map_rom #(
        .DEPTH(GC * GR),
        .ABITS(ROM_ABITS),
        .ROM_FILE(ROM_FILE)
    ) map_rom (
        .clk(clk),
        .en(rom_en),
        .addr(rom_addr),
        .q(rom_q)
    );

    // ---- 从 corner 中取出当前块(lb 组)的 4 个角 U/V 分量 ----
    // corner[{lb,2'd0}] 即 corner[lb*4+0]，依次类推
    wire [23:0] u0 = corner[{lb, 2'd0}][23:0];
    wire [23:0] u1 = corner[{lb, 2'd1}][23:0];
    wire [23:0] u2 = corner[{lb, 2'd2}][23:0];
    wire [23:0] u3 = corner[{lb, 2'd3}][23:0];
    wire [23:0] v0 = corner[{lb, 2'd0}][47:24];
    wire [23:0] v1 = corner[{lb, 2'd1}][47:24];
    wire [23:0] v2 = corner[{lb, 2'd2}][47:24];
    wire [23:0] v3 = corner[{lb, 2'd3}][47:24];

    function [23:0] min4;
        input [23:0] a;
        input [23:0] b;
        input [23:0] c;
        input [23:0] d;
        reg [23:0] e;
        reg [23:0] f;
        begin
            e = (a < b) ? a : b;
            f = (c < d) ? c : d;
            min4 = (e < f) ? e : f;
        end
    endfunction

    function [23:0] max4;
        input [23:0] a;
        input [23:0] b;
        input [23:0] c;
        input [23:0] d;
        reg [23:0] e;
        reg [23:0] f;
        begin
            e = (a > b) ? a : b;
            f = (c > d) ? c : d;
            max4 = (e > f) ? e : f;
        end
    endfunction

    // ---- 源块包围矩形（由 4 角控制点 min/max 决定）----
    wire [23:0] ulo = min4(u0, u1, u2, u3);
    wire [23:0] uhi = max4(u0, u1, u2, u3);
    wire [23:0] vlo = min4(v0, v1, v2, v3);
    wire [23:0] vhi = max4(v0, v1, v2, v3);
    // 取整数部分（高 12 位），x 终点 +1 使区间闭合；y 同理
    wire [11:0] xmax = uhi[23:12] + 12'd1;
    wire [11:0] ymax = vhi[23:12] + 12'd1;
    wire [11:0] height = ymax - vlo[23:12] + 12'd1;   // 源块高度（行数）

    // ---- DDR 读请求（字节寻址突发）----
    // 状态 ls==6 且还有行未发：逐行发出读请求
    assign rd_valid = busy && ls == 6 && issue_row < sh[lb];
    assign rd_addr  = source + (sy[lb] + issue_row) * W * 3 + (sx[lb] >> 5) * 96;
    assign rd_len   = two_words[lb] ? 4'd5 : 4'd2;
    assign rd_tag   = {7'd0, lb, issue_row[4:0], 3'd0};

    // 源块装载完成：所有行已发出且响应已全部收到
    wire [7:0] expected_beats = two_words[lb] ? sh[lb] * 8'd6 : sh[lb] * 8'd3;
    wire load_complete = ls == 6 && issue_row == sh[lb] && received == expected_beats;

    // ---- 输出 strip（结果带）内存 ----
    // 32 个字节 bank（每 bank 存 16 行 x 1920 字节中的部分），一次写一对。
    reg [1:0] strip_full;               // strip bank 是否已满
    reg [11:0] strip_y [0:1];           // strip 起始行
    reg [4:0]  strip_h [0:1];           // strip 高度（行数）
    reg wb;                             // 正在写回的 strip bank
    reg [10:0] wi;
    reg [1:0] write_channel;
    reg out_pending;                    // 是否有输出字待写
    reg [255:0] out_data;               // 输出数据
    wire [767:0] strip_q;
    wire strip_fetch = strip_full[wb] && !out_pending;   // 开始取下一字
    reg fetch_d;

    assign wr_valid = out_pending;
    assign wr_data  = out_data;
    assign wr_addr  = target + strip_y[wb] * W * 3 + wi * 96 + {write_channel, 5'd0};
    wire write_fire = wr_valid && wr_ready;

    // ---- 块内计算流水线控制 ----
    reg running;        // 当前块正在计算
    reg draining;       // 当前块计算已结束、等待流水线排空
    reg [3:0] px;       // 块内输出像素列偏移（步进 2，双 lane）
    reg [3:0] py;       // 块内输出像素行偏移
    wire strip_bank = by[cb][4];        // 行 bit4 决定 strip 奇偶 bank
    wire begin_tile = busy && !running && !draining && available[cb] && !strip_full[strip_bank];
    wire launch = running;              // 计算使能（驱动 ud_coord 的 valid）
    // 块内最后一个像素：px==14 且 py 为该块实际行高-1
    wire tile_last = (px == 14 && py == ((by[cb] + 16 > H) ? H - by[cb] - 1 : 15));

    // ---- 权重函数：把块内位置换算成 U1.16 归一化权重 ----
    // 常规块跨度 16（权重 = pos<<12）；最右块跨度 15；最下块跨度 7。
    // span 为 15/7 时用常量分母表做整数除法近似，16 时直接左移 12 位。
    function [16:0] weight;
        input [4:0] pos;
        input [4:0] span;
        begin
            case (span)
                15: weight = (pos * 32'd65536 + 7) / 15;
                7:  weight = (pos * 32'd65536 + 3) / 7;
                16: weight = {pos, 12'd0};
                default: weight = 0;
            endcase
        end
    endfunction

    // 块内实际跨度（边界块可能不足 16）
    wire [4:0] dx = (bx[cb] + 16 >= W) ? W - 1 - bx[cb] : 16;
    wire [4:0] dy = (by[cb] + 16 >= H) ? H - 1 - by[cb] : 16;
    // 两个相邻输出像素的 x 权重（lane0=lane 用 tx0，lane1=tx1）
    wire [16:0] tx0 = weight({1'b0, px}, dx);
    wire [16:0] tx1 = weight({1'b0, px} + 5'd1, dx);
    wire [16:0] ty = weight({1'b0, py}, dy);

    // ---- 双 lane 计算信号 ----
    wire [23:0] cu [0:1];      // lane 的 U 坐标结果（U12.12）
    wire [23:0] cv [0:1];      // lane 的 V 坐标结果（U12.12）
    wire coord_valid [0:1];
    wire [31:0] samples [0:2][0:1];
    wire [7:0] result [0:2][0:1];
    wire result_valid [0:2][0:1];

    reg [11:0] fx [0:1];       // 像素插值 x 小数权重
    reg [11:0] fy [0:1];       // 像素插值 y 小数权重
    reg sample_valid;          // 像素插值有效（来自 coord_valid[0]）
    reg [7:0] last_pipe;       // 块末标记移位链（8 位）
    reg [14:0] address_pipe [0:7];   // 输出写地址移位链（8 级）
    reg bank_pipe [0:7];       // strip bank 移位链（8 级）
    integer i;
    genvar lane;
    genvar color_lane;
    genvar tile_channel;
    genvar strip_channel;

    // ---- 双 lane 并行：两条坐标/插值流水线 ----
    // lane0 处理 px 处像素，lane1 处理 px+1 处像素，共享同一套控制点与 ty。
    generate
        for (lane = 0; lane < 2; lane = lane + 1) begin : LANE
            wire [16:0] tx = (lane == 0) ? tx0 : tx1;

            // U 方向坐标插值
            ud_coord ux (
                clk,
                rst_n,
                launch,
                corner[{cb, 2'd0}][23:0],
                corner[{cb, 2'd1}][23:0],
                corner[{cb, 2'd2}][23:0],
                corner[{cb, 2'd3}][23:0],
                tx,
                ty,
                cu[lane],
                coord_valid[lane]
            );

            // V 方向坐标插值（注意：位置参数按模块定义传，输出 cv[lane]）
            ud_coord vy (
                clk,
                rst_n,
                launch,
                corner[{cb, 2'd0}][47:24],
                corner[{cb, 2'd1}][47:24],
                corner[{cb, 2'd2}][47:24],
                corner[{cb, 2'd3}][47:24],
                tx,
                ty,
                cv[lane],
                /* coord_valid not used for vy output */
            );

            // 采样坐标的小数部分（fx,fy），与采样结果对齐
            always @(posedge clk) begin
                fx[lane] <= cu[lane][11:0];
                fy[lane] <= cv[lane][11:0];
            end

            // 像素双线性插值
            for (color_lane = 0; color_lane < 3; color_lane = color_lane + 1) begin : COLOR
                ud_bilinear bil (
                    clk, rst_n, sample_valid,
                    samples[color_lane][lane][7:0],
                    samples[color_lane][lane][15:8],
                    samples[color_lane][lane][23:16],
                    samples[color_lane][lane][31:24],
                    fx[lane], fy[lane],
                    result[color_lane][lane], result_valid[color_lane][lane]
                );
            end
        end
    endgenerate

    // ---- 源坐标 -> tile_ram 本地坐标 ----
    // coord 整数部分减去源块起始 sx/sy，得到块内偏移。x 取 6 位、y 取 5 位。
    wire [11:0] local_x0 = cu[0][23:12] - sx[cb];
    wire [11:0] local_x1 = cu[1][23:12] - sx[cb];
    wire [11:0] local_y0 = cv[0][23:12] - sy[cb];
    wire [11:0] local_y1 = cv[1][23:12] - sy[cb];

    // ---- 源块 tile 缓存 ----
    // rsp_tag[6]：组；rsp_tag[5:0]：字/行索引；cb 为采样组。
    wire [1:0] rsp_channel = (rsp_tag[2:0] >= 3) ? rsp_tag[2:0] - 3 : rsp_tag[2:0];
    wire [5:0] fill_word = {rsp_tag[7:3], rsp_tag[2:0] >= 3};
    generate for (tile_channel = 0; tile_channel < 3; tile_channel = tile_channel + 1) begin : TILES
        ud_tile_ram tiles (
            clk, rsp_valid && rsp_channel == tile_channel,
            rsp_tag[8], fill_word, rsp_data, cb,
            local_x0[5:0], local_x1[5:0],
            local_y0[4:0], local_y1[4:0],
            samples[tile_channel][0], samples[tile_channel][1]
        );
    end endgenerate

    // ---- 输出 strip 内存阵列（32 个字节 bank）----
    // 每个 bank 存 2*16*WORDS 字节（即 16 行 x 1920 字节的一行块），
    // 写端口按地址流水线 index 写入 result，读端口按 strip_fetch 输出。
    genvar bank;
    generate
        for (bank = 0; bank < 32; bank = bank + 1) begin : STRIP
          for (strip_channel = 0; strip_channel < 3; strip_channel = strip_channel + 1) begin : COLOR
            reg [7:0] mem [0:2 * 16 * WORDS - 1];
            reg [7:0] q;
            wire [14:0] wa = address_pipe[6];
            wire [10:0] index = bank_pipe[6] * 16 * WORDS + (wa >> 5);
            always @(posedge clk) begin
                // 双 lane 结果按 wa 的低 5 位（字节 offset）决定写入哪个 bank
                if (result_valid[strip_channel][0] && wa[4:0] == bank)
                    mem[index] <= result[strip_channel][0];
                else if (result_valid[strip_channel][1] && wa[4:0] + 5'd1 == bank)
                    mem[index] <= result[strip_channel][1];
                if (strip_fetch)
                    q <= mem[wb * 16 * WORDS + wi];
            end
            assign strip_q[strip_channel * 256 + bank * 8 +: 8] = q;
          end
        end
    endgenerate

    // ---- 主控制状态机 ----
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy <= 0;
            done <= 0;
            fault <= 0;
            cycles <= 0;
            ls <= 0;
            lb <= 0;
            cb <= 0;
            lx <= 0;
            ly <= 0;
            available <= 0;
            load_end <= 0;
            issue_row <= 0;
            received <= 0;
            running <= 0;
            draining <= 0;
            px <= 0;
            py <= 0;
            last_pipe <= 0;
            sample_valid <= 0;
            strip_full <= 0;
            wb <= 0;
            wi <= 0;
            write_channel <= 0;
            out_pending <= 0;
            fetch_d <= 0;
        end else begin
            done <= 0;
            // 像素插值的 valid 来自坐标 valid（U 通道），两者延迟相同
            sample_valid <= coord_valid[0];
            // 块末标记与地址/bank 同走 8 级移位链
            last_pipe <= {last_pipe[6:0], launch && tile_last};
            address_pipe[0] <= py * W + bx[cb] + px;
            bank_pipe[0] <= strip_bank;
            for (i = 1; i < 8; i = i + 1) begin
                address_pipe[i] <= address_pipe[i - 1];
                bank_pipe[i] <= bank_pipe[i - 1];
            end
            fetch_d <= strip_fetch;
            if (fetch_d) begin
                out_data <= strip_q[write_channel * 256 +: 256];
                out_pending <= 1;
            end
            if (busy)
                cycles <= cycles + 1;

            // 启动：锁存源/目标基址，进入装载
            if (start && !busy) begin
                source <= src_base;
                target <= dst_base;
                busy <= 1;
                cycles <= 0;
                fault <= 0;
                ls <= 0;
                lb <= 0;
                cb <= 0;
                lx <= 0;
                ly <= 0;
                available <= 0;
                load_end <= 0;
                strip_full <= 0;
                wb <= 0;
                wi <= 0;
                write_channel <= 0;
                out_pending <= 0;
                fetch_d <= 0;
            end

            // 装载状态机（未结束时）
            if (busy && !load_end)
                case (ls)
                    0: if (!available[lb] && !(cb == lb && (running || draining))) begin
                        // 该组还空着，且不与当前计算组冲突，才开始装载新块
                        bx[lb] <= lx * 16;
                        by[lb] <= ly * 16;
                        ls <= 1;
                    end
                    // 注：rom_q 属于前一状态发出的地址
                    1: ls <= 2;
                    2: begin
                        corner[{lb, 2'd0}] <= rom_q;
                        ls <= 3;
                    end
                    3: begin
                        corner[{lb, 2'd1}] <= rom_q;
                        ls <= 4;
                    end
                    4: begin
                        corner[{lb, 2'd2}] <= rom_q;
                        ls <= 5;
                    end
                    5: begin
                        corner[{lb, 2'd3}] <= rom_q;
                        ls <= 7;
                    end
                    7: begin
                        // 计算源块范围并准备读
                        sx[lb] <= {ulo[23:17], 5'd0};       // 32 像素对齐
                        sy[lb] <= vlo[23:12];
                        sh[lb] <= height[5:0];
                        two_words[lb] <= xmax[11:5] != ulo[23:17];
                        issue_row <= 0;
                        received <= 0;
                        ls <= 6;
                        // 超范围保护：源块高度或宽度超出缓存容量则 fault 并结束
                        if (height > 32 || xmax - {ulo[23:17], 5'd0} >= 64) begin
                            fault <= 1;
                            busy <= 0;
                        end
                    end
                    6: begin
                        // 发出读请求与接收响应
                        if (rd_valid && rd_ready)
                            issue_row <= issue_row + 1;
                        if (rsp_valid)
                            received <= received + 1;
                        if (load_complete) begin
                            available[lb] <= 1;    // 该组可用
                            lb <= ~lb;             // 切换到另一组装载
                            ls <= 0;
                            if (lx == NX - 1) begin
                                lx <= 0;
                                ly <= ly + 1;
                                if (ly == NY - 1)
                                    load_end <= 1;  // 全部块已装载
                            end else
                                lx <= lx + 1;
                        end
                    end
                    default: ls <= 0;
                endcase

            // 开始计算一个块
            if (begin_tile) begin
                running <= 1;
                px <= 0;
                py <= 0;
                available[cb] <= 0;
            end

            // 块内像素扫描：px 步进 2（双 lane），到 14 则换行
            if (running) begin
                if (px == 14) begin
                    px <= 0;
                    py <= py + 1;
                end else
                    px <= px + 2;
                if (tile_last) begin
                    running <= 0;
                    draining <= 1;   // 进入排空，等待流水线尾
                end
            end

            // 块末流水线尾到达：结果已全部写入 strip
            if (last_pipe[6] && result_valid[0][0]) begin
                draining <= 0;
                cb <= ~cb;   // 切换计算组
                // 若该块是 strip 的最末块，标记 strip 满，准备写回
                if (bx[cb] == W - 16) begin
                    strip_full[strip_bank] <= 1;
                    strip_y[strip_bank] <= by[cb];
                    strip_h[strip_bank] <= (by[cb] + 16 > H) ? H - by[cb] : 16;
                end
            end

            // 结果写回：一个字写完
            if (write_fire) begin
                out_pending <= 0;
                if (write_channel != 2)
                    write_channel <= write_channel + 1'b1;
                else if (wi == strip_h[wb] * WORDS - 1) begin
                    // 当前 strip 写完
                    strip_full[wb] <= 0;
                    wb <= ~wb;
                    wi <= 0;
                    write_channel <= 0;
                    // 最后一个 strip 写回完成则整帧结束
                    if (strip_y[wb] + strip_h[wb] == H) begin
                        busy <= 0;
                        done <= 1;
                    end
                end else begin
                    wi <= wi + 1;
                    write_channel <= 0;
                end
            end
        end
    end

endmodule

// ============================================================================
// ud_map_rom : 坐标控制点 ROM（同步单端口，块 ROM 推断）
// ============================================================================
// 保存输出块 4 角在源图上的控制点。每项 48 位 = {V[23:0], U[23:0]}，
// 各为 U12.12 无符号定点。复位不复位输出寄存器，控制点有效性由外层
// 装载状态机保证。
//
// 综合属性 syn_romstyle = "block_rom" 指示 Pango 综合器把该寄存器数组
// 推断为块 ROM（DRM），而不是分布式 ROM 或大堆寄存器。
// ============================================================================
module ud_map_rom #(
    parameter DEPTH = 8349,
    parameter ABITS = 14,
    parameter ROM_FILE = "rom/map.hex"
) (
    input  wire                 clk,
    input  wire                 en,
    input  wire [ABITS-1:0]     addr,
    output reg [47:0]           q
);

    reg [47:0] mem [0:DEPTH-1] /* synthesis syn_romstyle = "block_rom" */;
    initial $readmemh(ROM_FILE, mem);
    always @(posedge clk)
        if (en)
            q <= mem[addr];

endmodule

`default_nettype wire
