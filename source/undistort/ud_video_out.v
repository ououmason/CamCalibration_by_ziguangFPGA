`timescale 1ns/1ps
`default_nettype none

// ============================================================================
// ud_video_out : 输出显示时间线（像素时钟域 oclk，连续产生同步信号）
// ============================================================================
//
// 【两条时间线之二：显示时间线】
// 本模块运行在输出像素时钟 oclk（148.5MHz）域，独立于核心计算时钟 clk。
// 它像普通时序发生器一样，连续产生 HS/VS/DE 与像素流，无法被打断/反压。
//
// 输入 data 为 {epoch, 256 位单通道数据}，每 32 像素按 R/G/B 三字到达，经 ud_async_fifo 跨钟
// 送来的 DDR 显示读数据。valid/ready 是与 FIFO 的握手。
//
// 【epoch 帧同步机制（与计算时间线的跨时钟同步核心）】
//   - data[256] 是"显示 epoch"位，由核心域（ud_system）在每一帧显示数据包中携带。
//   - 本模块在每帧起始（frame_start = h==0 && v==0）把内部 epoch 翻转一次，
//     并通过 frame_toggle（out_toggle）把该事件通报回核心域。
//   - 因此本模块内部 epoch 表示"当前正在显示的帧的代数"。
//   - stale = data[256] != epoch 表示 FIFO 里冒出来的是上一代（旧帧）残留数据，
//     这类数据直接丢弃，绝不混入新帧，避免帧切换时画面串帧。
//
// ready 的完整语义：
//   当 FIFO 端 valid 且（残帧需清空 / 已欠载 / 下一组尚未备齐）
//   时拉高 ready 取走数据。核心是"只在当前有效还能接收时握手"。
//
// 欠载处理：像素时钟不能被反压，若 active 区间没有可显示的字，则 fail=1，
//   本帧剩余像素输出 0（黑），underflow_count 计数，到下个 frame_start 恢复。
// ============================================================================
module ud_video_out #(
    parameter W = 1920,
    parameter H = 1080,
    parameter HT = 2200,
    parameter HS = 44,
    parameter HB = 148,
    parameter VT = 1125,
    parameter VS = 5,
    parameter VB = 36
) (
    input  wire          clk,
    input  wire          rst_n,
    output reg           frame_toggle,
    input  wire [256:0]  data,
    input  wire          valid,
    output wire          ready,
    output reg           hs,
    output reg           vs,
    output reg           de,
    output reg [23:0]    pixel,
    output reg [31:0]    underflow_count
);

    reg [11:0] h;        // 水平像素计数（0..HT-1）
    reg [11:0] v;        // 垂直行计数（0..VT-1）
    reg [4:0]  pos;      // 当前 256 位字内已输出到的字节位置（0..31）
    reg [255:0] current_r, current_g, current_b;
    reg [255:0] next_r, next_g, next_b;
    reg [1:0] load_channel;
    reg next_ready;
    reg have_word;       // 是否持有可用字
    reg failed;          // 本帧是否已欠载
    reg epoch;           // 显示端帧代数（每帧边界翻转）

    // active：有效像素区；frame_start：帧起始（同步信号归零点）
    wire active = h >= HS + HB && h < HS + HB + W && v >= VS + VB && v < VS + VB + H;
    wire frame_start = h == 0 && v == 0;
    // stale：输入数据属于旧 epoch，应丢弃
    wire stale = data[256] != epoch;

    // ready 组合逻辑（详见模块头注释）
    assign ready = valid && (stale || failed || (!next_ready && !frame_start));

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            h <= 0;
            v <= 0;
            pos <= 0;
            current_r <= 0;
            current_g <= 0;
            current_b <= 0;
            next_r <= 0;
            next_g <= 0;
            next_b <= 0;
            load_channel <= 0;
            next_ready <= 0;
            have_word <= 0;
            failed <= 0;
            epoch <= 0;
            frame_toggle <= 0;
            hs <= 0;
            vs <= 0;
            de <= 0;
            pixel <= 0;
            underflow_count <= 0;
        end else begin
            // ---- 同步信号发生器：行/场计数 ----
            if (h == HT - 1) begin
                h <= 0;
                if (v == VT - 1)
                    v <= 0;
                else
                    v <= v + 1;
            end else
                h <= h + 1;

            hs <= h < HS;
            vs <= v < VS;
            de <= active;
            pixel <= 0;   // 默认输出 0，active 内有字才会被覆盖

            if (frame_start) begin
                // ---- 帧边界：翻转 epoch 与 toggle，复位本帧状态 ----
                // 该 toggle 会经 ud_system 的同步链送回核心域，用于触发
                // 显示槽位切换（在帧边界选取最新的 READY 结果帧）。
                frame_toggle <= ~frame_toggle;
                epoch <= ~epoch;
                have_word <= 0;
                next_ready <= 0;
                load_channel <= 0;
                failed <= 0;
                pos <= 0;
            end else begin
                // 非帧边界：正常接收与输出
                if (ready && !stale && !failed) begin
                    case (load_channel)
                        0: begin next_r <= data[255:0]; load_channel <= 1; end
                        1: begin next_g <= data[255:0]; load_channel <= 2; end
                        2: begin
                            next_b <= data[255:0];
                            next_ready <= 1;
                            load_channel <= 0;
                        end
                    endcase
                end
                if (!have_word && next_ready && !failed) begin
                    current_r <= next_r;
                    current_g <= next_g;
                    current_b <= next_b;
                    next_ready <= 0;
                    have_word <= 1;
                end
                if (active) begin
                    if (have_word && !failed) begin
                        // 按字节从当前字中顺序取出像素
                        pixel <= {current_r[pos * 8 +: 8],
                                  current_g[pos * 8 +: 8],
                                  current_b[pos * 8 +: 8]};
                        pos <= pos + 1;
                        // 消费到最后一个字节时允许取下一个字
                        if (pos == 31) begin
                            have_word <= next_ready;
                            if (next_ready) begin
                                current_r <= next_r;
                                current_g <= next_g;
                                current_b <= next_b;
                                next_ready <= 0;
                            end
                        end
                    end else if (!failed) begin
                        // 无字可显示：欠载，本帧其余像素输出黑
                        failed <= 1;
                        have_word <= 0;
                        underflow_count <= underflow_count + 1;
                    end
                end
            end
        end
    end

endmodule

`default_nettype wire
