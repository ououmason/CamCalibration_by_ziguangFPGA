`timescale 1ns/1ps
`default_nettype none

// ============================================================================
// ud_capture : 输入捕获（像素时钟域 pclk，RGB888 每 32 像素打包）
// ============================================================================
//
// 【三条时间线之一：捕获时间线】
// 本模块运行在输入像素时钟 pclk 域，无背压（HDMI 输入不能被反压）。
// 每 32 像素依次输出 R[32]、G[32]、B[32] 三个 256 位字。
// 每个字附带控制信息，形成一个 305 位捕获包。
//
// 【捕获包格式 [304:0]】
//   [304]    : bad，本帧是否已发现错误
//   [303:288]: frame，帧号（16 位，每帧递增）
//   [287:256]: byte offset，本包首字节在帧内的字节偏移（32 字节粒度）
//   [255:0]  : 当前颜色通道的 32 个 8 位像素
//
//   特殊的 EOF（帧结束）包在下一个 VS 处生成：byte offset = 0xFFFFFFFF 标记，
//   正文清零。EOF 描述符被下游用于校验整帧行数/像素数是否匹配 W*H。
//
// 【同步与错误检测】
//   行数由 DE 下降沿统计（prev_de && !de），列数由 de 有效期间的 x 计数。
//   VS 上升沿（!prev_vs && vs）标志上一帧结束、新帧开始。若上一帧存在
//   行数 != H 或像素数 != W*H，则产生 bad 帧标记。缺行/多行都会被捕获。
//
//   count 统计本帧已收像素，每组 32 像素产生三个字；
//   byte offset 为组号*96 + 通道号*32。
// ============================================================================
module ud_capture #(
    parameter W = 1920,
    parameter H = 1080
) (
    input  wire           pclk,
    input  wire           prst_n,
    input  wire           vs,
    input  wire           de,
    input  wire [7:0]     red,
    input  wire [7:0]     green,
    input  wire [7:0]     blue,
    output wire [304:0]   data,
    output wire           valid,
    input  wire           ready,
    output reg  [31:0]    overflow_count
);

    // Match the RGB data delay to the VS/DE delay without quantizing colors.
    reg [7:0] r0, r1, r;
    reg [7:0] g0, g1, g;
    reg [7:0] b0, b1, b;

    // ---- vs/de 的延迟链，用于检测边沿 ----
    reg [2:0] vd;
    reg [2:0] dd;

    reg prev_vs;
    reg prev_de;

    reg [15:0] frame;      // 帧号
    reg [21:0] count;      // 本帧已收像素数（22 位足以容纳 1920*1080）

    reg [255:0] pack_r;
    reg [255:0] pack_g;
    reg [255:0] pack_b;
    reg [255:0] pending_g;
    reg [255:0] pending_b;
    reg [1:0] pending_channel;
    reg [31:0] pending_offset;
    reg [304:0] packet;    // 最终捕获包
    reg packet_valid;
    reg active;            // 是否处于活跃帧捕获中
    reg bad;               // 本帧错误标志

    reg [11:0] x;          // 当前行内像素计数
    reg [11:0] line;       // 当前帧行计数

    assign data = packet;
    assign valid = packet_valid;

    always @(posedge pclk) begin
        r0 <= red;
        r1 <= r0;
        r <= r1;
        g0 <= green;
        g1 <= g0;
        g <= g1;
        b0 <= blue;
        b1 <= b0;
        b <= b1;
    end

    always @(posedge pclk or negedge prst_n) begin
        if (!prst_n) begin
            vd <= 0;
            dd <= 0;
            prev_vs <= 0;
            frame <= 0;
            count <= 0;
            pack_r <= 0;
            pack_g <= 0;
            pack_b <= 0;
            pending_g <= 0;
            pending_b <= 0;
            pending_channel <= 0;
            pending_offset <= 0;
            packet_valid <= 0;
            active <= 0;
            bad <= 0;
            x <= 0;
            line <= 0;
            prev_de <= 0;
            overflow_count <= 0;
        end else begin
            // 延迟链与边沿检测
            vd <= {vd[1:0], vs};
            dd <= {dd[1:0], de};
            prev_vs <= vd[2];
            prev_de <= dd[2];

            // 握手：若上一包已被消费端取走(ready)，则清 valid。
            // 由于捕获侧无背压，当 packet_valid 仍为高且消费端未 ready 时，
            // 下面产生新包的分支会走 else 置 bad 并 overflow 计数，丢弃新数据。
            if (packet_valid && ready)
                packet_valid <= 0;

            if (pending_channel != 0 && (!packet_valid || ready)) begin
                packet <= {bad, frame, pending_offset +
                           (pending_channel == 1 ? 32'd32 : 32'd64),
                           pending_channel == 1 ? pending_g : pending_b};
                packet_valid <= 1;
                pending_channel <= pending_channel == 1 ? 2'd2 : 2'd0;
            end

            // ---- VS 上升沿：帧边界 ----
            if (!prev_vs && vd[2]) begin
                // 校验上一帧，包括缺行/多行
                if (active) begin
                    if (!packet_valid || ready) begin
                        // 产生 EOF 包，bad 综合行数/像素数错误
                        packet <= {bad || line != H || count != W * H, frame, 32'hffffffff, 256'd0};
                        packet_valid <= 1;
                    end else
                        overflow_count <= overflow_count + 1;
                end
                // 新帧开始
                frame <= frame + 1;
                pending_channel <= 0;
                count <= 0;
                active <= 1;
                bad <= 0;
                x <= 0;
                line <= 0;
            end

            // ---- DE 下降沿：行结束，检查行宽并换行 ----
            if (prev_de && !dd[2] && active) begin
                if (x != W)
                    bad <= 1;
                x <= 0;
                line <= line + 1;
            end

            // ---- DE 有效期间：逐像素捕获 ----
            if (dd[2] && active) begin
                count <= count + 1;
                x <= x + 1;
                pack_r[count[4:0] * 8 +: 8] <= r;
                pack_g[count[4:0] * 8 +: 8] <= g;
                pack_b[count[4:0] * 8 +: 8] <= b;
                if (x >= W || line >= H)
                    bad <= 1;
                // 每 32 像素打包输出一次
                if (count[4:0] == 31) begin
                    if ((!packet_valid || ready) && pending_channel == 0) begin
                        // [304] bad; [303:288] frame; [287:256] byte offset
                        packet <= {bad || x >= W || line >= H, frame,
                                   (count >> 5) * 32'd96, r, pack_r[247:0]};
                        pending_g <= {g, pack_g[247:0]};
                        pending_b <= {b, pack_b[247:0]};
                        pending_offset <= (count >> 5) * 32'd96;
                        pending_channel <= 1;
                        packet_valid <= 1;
                    end else begin
                        bad <= 1;
                        overflow_count <= overflow_count + 1;
                    end
                end
            end
        end
    end

endmodule

`default_nettype wire
