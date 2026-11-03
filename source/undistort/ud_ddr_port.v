`timescale 1ns/1ps
`default_nettype none

// ============================================================================
// ud_ddr_port : DDR 读写适配器（Pango 用户口，非标准 AXI4）
// ============================================================================
//
// 【作用】
// 把系统内部"多读事务并发、按 tag 匹配、按字节寻址"的读写请求，适配到
// 现有 Pango DDR3 用户口（一个简化的类似 AXI 的接口，而非标准 AXI4）。
//
// 【读通道：多事务并发 + ID 匹配】
//   发起端(engine / frame_copy)可同时发出最多 16 个读突发，每个突发分配一个
//   4 位 ID（0..15）。适配器维护：
//     - occupied[16]   : ID 是否被占用
//     - tags[16]       : 每个 ID 对应的业务读标签(16 位)
//     - counts[16]     : 每个 ID 已返回的拍数
//     - lengths[16]    : 每个 ID 的突发长度
//   由于返回次序可能跨 ID 乱序（但同 ID 内拍序必须保持），适配器用 ID 匹配把
//   返回数据送回对应标签，保证缓存写入到正确位置。
//
//   返回端没有 ready，因此发读命令前必须预留容量（occupied 有空位才 rd_ready）。
//   显示读通常只保留一个未完成突发，以维持光栅顺序。
//
// 【写通道：成帧缓冲后整突发发出】
//   写数据先收集到 wbuf[16] 里，凑成一段连续突发后再发 AW+W。写不是标准 AXI4：
//     - 地址发 IP 前置右移 2 位（字节地址 -> 32 位字地址），每拍 32 字节对应
//       8 个 IP 地址单位。
//     - wstrb 全 1，写是完整 32 字节字，无局部字节使能。
//     - 写完等 wusero_last，无 B 响应、无 WVALID。
//
// 【地址换算】
//   本模块边界输入是字节地址，转 IP 时右移 2 位（axi_araddr = rd_addr[29:2]）。
//   输入地址必须 32 字节对齐（rd_addr[4:0]==0 || wr_addr[4:0]==0），否则 protocol_error。
// ============================================================================
module ud_ddr_port (
    input  wire         clk,
    input  wire         rst_n,

    input  wire         rd_valid,
    output wire         rd_ready,
    input  wire [31:0]  rd_addr,
    input  wire [3:0]   rd_len,
    input  wire [15:0]  rd_tag,

    output wire         rsp_valid,
    output wire [15:0]  rsp_tag,
    output wire [255:0] rsp_data,
    output wire         rsp_last,

    input  wire         wr_valid,
    output wire         wr_ready,
    input  wire [31:0]  wr_addr,
    input  wire [255:0]  wr_data,
    input  wire         wr_last,
    input  wire         wr_flush,

    output wire         wr_idle,
    output reg          protocol_error,

    output reg [27:0]   axi_araddr,
    output reg [3:0]    axi_arlen,
    output reg [3:0]    axi_arid,
    output reg          axi_arvalid,
    input  wire         axi_arready,

    input  wire [255:0] axi_rdata,
    input  wire [3:0]   axi_rid,
    input  wire         axi_rvalid,
    input  wire         axi_rlast,

    output wire [27:0]  axi_awaddr,
    output wire [3:0]   axi_awlen,
    output wire         axi_awvalid,
    input  wire         axi_awready,

    output wire [255:0] axi_wdata,
    output wire [31:0]  axi_wstrb,
    input  wire         axi_wready,
    input  wire         axi_wlast
);

    // ---- 读事务表 ----
    reg [15:0] occupied;         // 哪些 ID 正在使用
    reg [15:0] tags [0:15];      // ID -> 业务读标签
    reg [3:0]  counts [0:15];    // ID -> 已返回拍数
    reg [3:0]  lengths [0:15];   // ID -> 突发长度（拍数）
    reg        found;
    reg [3:0]  free_id;
    integer i;
    integer n;

    // 找空闲 ID（从高位优先）
    always @* begin
        found = 0;
        free_id = 0;
        for (n = 15; n >= 0; n = n - 1)
            if (!occupied[n]) begin
                found = 1;
                free_id = n;
            end
    end

    // rd_ready：有空闲 ID 且 AR 通道可发（无未完成 AR 或已被握手）
    assign rd_ready = found && (!axi_arvalid || axi_arready);
    // 返回有效：本 ID 有占用（即不是错误返回）
    assign rsp_valid = axi_rvalid && occupied[axi_rid];
    // 返回标签 = 该 ID 的原标签 + 已返回拍数（用于填充缓存位置）
    assign rsp_tag = tags[axi_rid] + counts[axi_rid];
    assign rsp_data = axi_rdata;
    assign rsp_last = axi_rlast;

    // ---- 写缓冲与时序 ----
    reg [255:0] wbuf [0:15];
    reg [255:0] wq;
    reg [31:0]  wbase;
    reg [4:0]   collected;
    reg [3:0]   wlen;
    reg [3:0]   index;
    reg [2:0]   state;

    assign wr_ready = state == 0;                 // 空闲态才接收写
    assign wr_idle = state == 0 && collected == 0;
    assign axi_awaddr = wbase[29:2];              // 字节地址 -> 字地址（右移 2）
    assign axi_awlen = wlen;
    assign axi_awvalid = state == 2;
    assign axi_wdata = wq;
    assign axi_wstrb = 32'hffffffff;              // 全字节使能

    // 写数据缓存（写接收、缓冲索引切换、发送期取数据）
    always @(posedge clk) begin
        if (wr_valid && wr_ready)
            wbuf[collected[3:0]] <= wr_data;
        if (state == 1)
            wq <= wbuf[0];
        if (state == 3 && axi_wready)
            wq <= wbuf[index + 4'd1];
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            occupied <= 0;
            axi_arvalid <= 0;
            axi_araddr <= 0;
            axi_arid <= 0;
            axi_arlen <= 0;
            protocol_error <= 0;
            state <= 0;
            collected <= 0;
            wbase <= 0;
            wlen <= 0;
            index <= 0;
            for (i = 0; i < 16; i = i + 1) begin
                counts[i] <= 0;
                tags[i] <= 0;
                lengths[i] <= 0;
            end
        end else begin
            // AR 握手完成则清 valid
            if (axi_arvalid && axi_arready)
                axi_arvalid <= 0;

            // ---- 读请求受理 ----
            if (rd_valid && rd_ready) begin
                occupied[free_id] <= 1;
                tags[free_id] <= rd_tag;
                counts[free_id] <= 0;
                lengths[free_id] <= rd_len;
                axi_arvalid <= 1;
                axi_araddr <= rd_addr[29:2];   // 字节 -> 字
                axi_arid <= free_id;
                axi_arlen <= rd_len;
                if (rd_addr[4:0] != 0)
                    protocol_error <= 1;       // 必须 32 字节对齐
            end

            // ---- 读返回 ----
            if (axi_rvalid) begin
                // 校验：ID 被占用，且 rlast 与拍数关系一致
                if (!occupied[axi_rid] || axi_rlast != (counts[axi_rid] == lengths[axi_rid]))
                    protocol_error <= 1;
                counts[axi_rid] <= counts[axi_rid] + 1;
                if (axi_rlast)
                    occupied[axi_rid] <= 0;    // 该 ID 释放
            end

            // ---- 写状态机 ----
            case (state)
                0: if (wr_flush && collected != 0) begin
                        // flush：把已收集的字也发出
                        wlen <= collected - 1;
                        state <= 1;
                   end else if (wr_valid) begin
                        // 收集写数据，校验地址连续与对齐
                        if (collected == 0)
                            wbase <= wr_addr;
                        else if (wr_addr != wbase + collected * 32)
                            protocol_error <= 1;
                        if (wr_addr[4:0] != 0)
                            protocol_error <= 1;
                        collected <= collected + 1;
                        if (collected == 15 || wr_last) begin
                            wlen <= collected[3:0];
                            state <= 1;
                        end
                   end
                1: begin
                    index <= 0;
                    state <= 2;
                end
                2: if (axi_awready)
                        state <= 3;
                3: if (axi_wready) begin
                        index <= index + 1;
                        if (index == wlen) begin
                            if (axi_wlast) begin
                                state <= 0;
                                collected <= 0;
                            end else
                                state <= 4;
                        end
                   end
                4: if (axi_wlast) begin
                        state <= 0;
                        collected <= 0;
                   end
                default: state <= 0;
            endcase
        end
    end

endmodule

`default_nettype wire