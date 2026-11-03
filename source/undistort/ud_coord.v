`timescale 1ns/1ps
`default_nettype none

// ============================================================================
// ud_coord : 双线性坐标插值（定点流水线，3 级延迟）
// ============================================================================
// 功能：给定一个输出块 4 个角在源图上的控制点（c00/c10/c01/c11），以及
//       该输出像素在块内的归一化位置权重（tx, ty），计算该输出像素对应
//       的源图坐标（U12.12 无符号定点：高 12 位整数 + 低 12 位小数）。
//
// 定点格式：
//   - 控制点 cxx   : U12.12（24 位无符号，12 位整数 + 12 位小数）
//   - 权重 tx, ty  : U1.16（17 位无符号，1 位整数 + 16 位小数，可表示 0~1）
//   - 输出 coord   : U12.12（24 位，与 cxx 同格式）
//
// 双线性插值公式（先水平 x 方向，再垂直 y 方向）：
//   top = c00*(1-tx) + c10*tx
//   bot = c01*(1-tx) + c11*tx
//   coord = top*(1-ty) + bot*ty
//
// 三级流水线实现（匹配 3 拍延迟，由 valid 打 3 拍对齐输出）：
//   第 1 拍：并行计算 4 个水平乘积 a/b/c/d
//   第 2 拍：累加得 top/bot（同时把 ty 再打两拍得到 ty2，用于对拍）
//   第 3 拍：垂直累加 + 四舍五入（加 2^31 后右移 32 位，取高 24 位）
//
// 定标分析（关键：为什么最后右移 32 而不是 48/64）：
//   a ~ c*d 的位宽：c 为 U12.12(24b)，(1-tx) 为 U1.16(17b)，乘积为 U13.28(41b)
//   top/bot 同为 U13.28(41b)（存 42 位留进位余量）
//   top*(1-ty2)：U13.28 * U1.16 = U14.44(58b)
//   最后加 2^31 后取 total[55:32]，等效 “(U14.44 右移 32 再保留 24 位)”
//   即得到 U12.12 的坐标，2^31 实现对第 32 位（小数 MSB）的四舍五入。
// ============================================================================
module ud_coord (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         valid,
    input  wire [23:0]  c00,
    input  wire [23:0]  c10,
    input  wire [23:0]  c01,
    input  wire [23:0]  c11,
    input  wire [16:0]  tx,
    input  wire [16:0]  ty,
    output reg  [23:0]  coord,
    output reg          out_valid
);

    // ---- 第 1 拍：水平方向 4 个乘积 ----
    // a = c00*(1-tx), b = c10*tx, c = c01*(1-tx), d = c11*tx
    // (17'd65536 - tx) 即 1-tx，因为 U1.16 的 1 = 65536。
    reg [40:0] a;
    reg [40:0] b;
    reg [40:0] c;
    reg [40:0] d;

    // ---- 第 2 拍：垂直两端各自累加 ----
    // top = a + b (上边两控制点水平插值)
    // bot = c + d (下边两控制点水平插值)
    reg [41:0] top;
    reg [41:0] bot;

    // ty 延迟链，使 ty 与 top/bot 的时序对齐（ty 需在第 3 拍与 top/bot 同时出现）
    reg [16:0] ty1;
    reg [16:0] ty2;

    // valid 延迟链，使 out_valid 与 coord 同拍输出
    reg v1;
    reg v2;

    // ---- 第 3 拍：垂直插值 + 四舍五入 ----
    // total = top*(1-ty2) + bot*ty2 + 2^31
    // 2^31 (59'd2147483648) 用于在右移 32 位前做四舍五入。
    wire [58:0] total = top * (17'd65536 - ty2) + bot * ty2 + 59'd2147483648;

    always @(posedge clk) begin
        // 第 1 拍（组合输入 -> 寄存器 a/b/c/d）
        a <= c00 * (17'd65536 - tx);
        b <= c10 * tx;
        c <= c01 * (17'd65536 - tx);
        d <= c11 * tx;
        // 第 2 拍
        top <= a + b;
        bot <= c + d;
        ty1 <= ty;
        ty2 <= ty1;
        // 第 3 拍：total 是纯组合，取 [55:32] 得 U12.12 的 24 位结果
        coord <= total[55:32];
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v1 <= 0;
            v2 <= 0;
            out_valid <= 0;
        end else begin
            // valid 打 3 拍，与 coord 的 3 拍延迟严格对齐
            v1 <= valid;
            v2 <= v1;
            out_valid <= v2;
        end
    end

endmodule

// ============================================================================
// ud_bilinear : 双线性像素插值（8 位灰度像素，3 拍延迟）
// ============================================================================
// 功能：坐标计算完成后，取出源图 2x2 邻域像素 p00/p10/p01/p11，用 12 位
//       小数权重 fx/fy 做双线性插值，得到最终灰度值。
//
// 公式（与 ud_coord 同一结构，但像素为 8 位、权重为 U0.12）：
//   top = p00*(1-fx) + p10*fx
//   bot = p01*(1-fx) + p11*fx
//   pixel = top*(1-fy) + bot*fy
//
// 定标分析：
//   p*(1-fx)：8b * 13b = 21b（存 21 位）
//   top/bot：22b
//   top*(1-fy2)：22b * 13b = 35b
//   加 2^23 后取 sum[31:24]，等效右移 24 位取整，2^23 做四舍五入再到 8 位。
//   (|sum[35:32]) 为溢出饱和：任一高 4 位非零说明结果 >255，饱和到 255。
// ============================================================================
module ud_bilinear (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        valid,
    input  wire [7:0]  p00,
    input  wire [7:0]  p10,
    input  wire [7:0]  p01,
    input  wire [7:0]  p11,
    input  wire [11:0] fx,
    input  wire [11:0] fy,
    output reg  [7:0]  pixel,
    output reg         out_valid
);

    // 第 1 拍：水平 4 个乘积（13'd4096 = U0.12 的 1）
    reg [20:0] a;
    reg [20:0] b;
    reg [20:0] c;
    reg [20:0] d;

    // 第 2 拍：垂直两端累加
    reg [21:0] top;
    reg [21:0] bot;

    // fy 延迟链，对齐到第 3 拍
    reg [11:0] fy1;
    reg [11:0] fy2;

    reg v1;
    reg v2;

    // 第 3 拍：垂直插值 + 四舍五入（+2^23）+ 溢出饱和
    wire [35:0] sum = top * (13'd4096 - {1'b0, fy2}) + bot * {1'b0, fy2} + 36'd8388608;

    always @(posedge clk) begin
        a <= p00 * (13'd4096 - {1'b0, fx});
        b <= p10 * {1'b0, fx};
        c <= p01 * (13'd4096 - {1'b0, fx});
        d <= p11 * {1'b0, fx};
        top <= a + b;
        bot <= c + d;
        fy1 <= fy;
        fy2 <= fy1;
        // 溢出饱和到 255，否则取 [31:24] 得到 8 位结果
        pixel <= (|sum[35:32]) ? 8'd255 : sum[31:24];
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v1 <= 0;
            v2 <= 0;
            out_valid <= 0;
        end else begin
            v1 <= valid;
            v2 <= v1;
            out_valid <= v2;
        end
    end

endmodule

`default_nettype wire