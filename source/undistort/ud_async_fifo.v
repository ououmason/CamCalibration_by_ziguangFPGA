`timescale 1ns/1ps
`default_nettype none

// ============================================================================
// ud_async_fifo : 双时钟异步 FIFO（Gray 指针 + 三级同步，跨时钟域同步核心）
// ============================================================================
//
// 【作用】
// 本模块是"三条时间线"之间的桥梁：把数据在 pclk -> clk 以及 clk -> oclk
// 之间安全地跨时钟域传递。本设计不去跨越时钟域采样"多比特数据"或"握手信号"，
// 而是用标准的"二进制指针 -> Gray 码 -> 三级同步 -> 反 Gray"方法传递读写指针，
// 数据本身原样存储在 RAM 里，由指针的跨域比较决定满/空/水位。
//
// 【关键实现】
//   - 写侧 wclk：wp 为二进制写指针，wg = gray(wp) 是其 Gray 码形式。
//   - 读侧 rclk：rp 为二进制读指针，rg = gray(rp)。
//   - 写侧把读指针 rg 经 rg1/rg2 三级同步后与 wg 比较算出 wready（满）与 wlevel。
//   - 读侧把写指针 wg 经 wg1/wg2 三级同步后算出 fetch（非空）与 rlevel。
//   - Gray 码相邻只变 1 位，可避免跨域同步时出现中间态导致指针误判。
//
//   wready = wg != {~rg2[高2位], rg2[其余]}   // Gray 满判断（写指针赶上读指针一圈）
//   fetch  = (!valid_q || rready) && (rg != wg2)  // 非空且需要取数
//
// 【读侧预取寄存器】
//   读侧有一个单字预取：valid_q/data_q。fetch 时从 mem 取下一字写入 data_q，
//   同时 valid_q 置 1；rready 时 valid_q 清 0。这使 rvalid/rdata 与 clk 同步，
//   消费端可直接握手，不需要额外读延迟。
//
// 【复位约定】
//   两侧各有独立复位 wrst_n/rrst_n，需同时置位。不在每个 VS 单独清 FIFO，
//   防止帧间残留指针错位。
// ============================================================================
module ud_async_fifo #(
    parameter WIDTH = 256,
    parameter ABITS = 8
) (
    input  wire                 wclk,
    input  wire                 wrst_n,
    input  wire [WIDTH-1:0]     wdata,
    input  wire                 wvalid,
    output wire                 wready,
    output wire [ABITS:0]       wlevel,
    input  wire                 rclk,
    input  wire                 rrst_n,
    output wire [WIDTH-1:0]     rdata,
    output wire                 rvalid,
    input  wire                 rready,
    output wire [ABITS:0]       rlevel
);

    reg [WIDTH-1:0] mem [0:(1 << ABITS) - 1];
    reg [ABITS:0] wp;   // 二进制写指针
    reg [ABITS:0] wg;   // Gray 码写指针
    reg [ABITS:0] rp;   // 二进制读指针
    reg [ABITS:0] rg;   // Gray 码读指针

    // 跨域同步链（异步寄存器防亚稳态链，双/三级触发器）
    (* async_reg = "true" *) reg [ABITS:0] rg1;   // 写侧采到的读指针（1 级）
    (* async_reg = "true" *) reg [ABITS:0] rg2;   // 写侧采到的读指针（2 级）
    (* async_reg = "true" *) reg [ABITS:0] wg1;   // 读侧采到的写指针（1 级）
    (* async_reg = "true" *) reg [ABITS:0] wg2;   // 读侧采到的写指针（2 级）

    reg [WIDTH-1:0] data_q;   // 读侧预取数据
    reg             valid_q;  // 读侧预取有效

    // 写指针前进量：写入 1 则 +1
    wire [ABITS:0] wn = wp + (wvalid && wready);
    // 新 Gray 码 = (二进制右移 1) 异或 二进制
    wire [ABITS:0] wgn = (wn >> 1) ^ wn;
    // 读侧取数条件：预取空或正在被读走，且 FIFO 非空
    wire fetch = (!valid_q || rready) && (rg != wg2);
    wire [ABITS:0] rn = rp + fetch;

    // Gray 码转二进制
    function [ABITS:0] ungray;
        input [ABITS:0] g;
        integer i;
        begin
            ungray[ABITS] = g[ABITS];
            for (i = ABITS - 1; i >= 0; i = i - 1)
                ungray[i] = ungray[i + 1] ^ g[i];
        end
    endfunction

    // 满：写 Gray 与 "读 Gray 高两位取反" 相等（相差一圈）
    assign wready = wg != {~rg2[ABITS:ABITS-1], rg2[ABITS-2:0]};
    // 写侧水位 = 写指针 - 同步后的读指针
    assign wlevel = wp - ungray(rg2);
    // 读侧水位 = 同步后的写指针 - 读指针 + 预取有效
    assign rlevel = ungray(wg2) - rp + valid_q;
    assign rvalid = valid_q;
    assign rdata = data_q;

    // 写 RAM
    always @(posedge wclk)
        if (wvalid && wready)
            mem[wp[ABITS-1:0]] <= wdata;

    // 读 RAM（fetch 时取下一字）
    always @(posedge rclk)
        if (fetch)
            data_q <= mem[rp[ABITS-1:0]];

    // 写指针更新（含读指针同步链）
    always @(posedge wclk or negedge wrst_n)
        if (!wrst_n) begin
            wp <= 0;
            wg <= 0;
            rg1 <= 0;
            rg2 <= 0;
        end else begin
            wp <= wn;
            wg <= wgn;
            rg1 <= rg;
            rg2 <= rg1;
        end

    // 读指针更新（含写指针同步链 + 预取寄存器）
    always @(posedge rclk or negedge rrst_n)
        if (!rrst_n) begin
            rp <= 0;
            rg <= 0;
            wg1 <= 0;
            wg2 <= 0;
            valid_q <= 0;
        end else begin
            wg1 <= wg;
            wg2 <= wg1;
            rp <= rn;
            rg <= (rn >> 1) ^ rn;
            if (fetch)
                valid_q <= 1;
            else if (rready)
                valid_q <= 0;
        end

endmodule

`default_nettype wire