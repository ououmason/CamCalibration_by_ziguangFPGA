`timescale 1ns/1ps
`default_nettype none

// ============================================================================
// ud_tile_ram : 源块片内缓存（两组 64x32 字节，奇偶银行分片）
// ============================================================================
//
// 【作用】
// 畸变矫正需要按输出像素坐标从源图读取 2x2 邻域像素。源图整幅在 DDR 中，
// 逐像素随机访问代价极高。因此 ud_engine 会以 16x16 输出块为单位，根据该块
// 四个角控制点的包围矩形，预先把源图对应的一块（最大 18x18，横向扩展到 32
// 字节边界，两组各 64x32 字节）读入本片上缓存，再由双线性插值逐像素取用。
//
// 【双缓冲与所有权隔离】
// 缓存分两个 bank 组（fill_bank）。填充一组时对另一组采样计算，避免读写冲突：
// "fill 永不写入正在被采样的 tile"。fill_bank 表示当前填充到哪组，
// sample_bank 表示从哪组采样，二者由 ud_engine 交错切换（cb 域）。
//
// 【奇偶分片：两个物理端口的低延迟采样】
// 双线性插值需要 2x2 邻域：p00/p10/p01/p11。要让 4 个点在同一拍从 RAM 中取到，
// 就要让这 4 个点分散在不同的小 bank 中。本模块把 x/y 各按奇偶分成 4 个 bank
// （x 偶 y 偶、x 奇 y 偶、x 偶 y 奇、x 奇 y 奇），每个 bank 有独立的 mem
// 阵列，从而 x0/x1 两条采样通道（lane0/lane1）各自可在同一拍取出 4 个点。
//
// 采样时把 6 位整数坐标 x 拆成 [高1位|低5位]，6 位 x 整数实际只用 5 位（低5位
// 是块内地址，高1位参与跨字的对齐）。y 用 5 位。具体：
//   xa = x + (x 的奇偶不等于目标 bank 的奇偶 ? 1 : 0)   // 邻域修正 +1
//   ya = y + (y 奇偶不等于目标 bank 奇偶 ? 1 : 0)
//   地址 a = {ya[4:1], xa[5]}，即行高位+字选位。
//   这样 4 个 bank 分别覆盖 2x2 中不同奇偶位置的点。
// ============================================================================
module ud_tile_ram (
    input  wire          clk,
    input  wire          fill,          // 填充使能（DDR 响应有效）
    input  wire          fill_bank,     // 填充到哪组 bank（与 cb 相交错）
    input  wire [5:0]    fill_word,     // 填充字索引（来自 DDR 读响应 tag）
    input  wire [255:0]  fill_data,     // 填充的 32 字节数据
    input  wire          sample_bank,   // 采样哪组 bank
    input  wire [5:0]    x0,            // lane0 的块内 x 整数坐标（6 位）
    input  wire [5:0]    x1,            // lane1 的块内 x 整数坐标（6 位）
    input  wire [4:0]    y0,            // lane0 的块内 y 整数坐标（5 位）
    input  wire [4:0]    y1,            // lane1 的块内 y 整数坐标（5 位）
    output wire [31:0]   pixels0,       // lane0 采样的 4 个像素（2x2 打包）
    output wire [31:0]   pixels1        // lane1 采样的 4 个像素（2x2 打包）
);

    // 每个奇偶 bank 的 4 字节采集结果，q0/q1 分别对应 bank_d 选择后的两组
    wire [7:0] q0 [0:7];
    wire [7:0] q1 [0:7];

    // 采样坐标与 bank 的延迟对齐寄存器（RAM 读是 1 拍延迟）
    reg bank_d;
    reg xp0;
    reg yp0;
    reg xp1;
    reg yp1;

    genvar b;
    genvar k;
    genvar n;

    generate
        // b：两组填充分组；k：4 个奇偶 bank（x/y 各奇偶）
        for (b = 0; b < 2; b = b + 1) begin : B
            for (k = 0; k < 4; k = k + 1) begin : P
                reg [127:0] mem [0:31];    // 每 bank 128 位 x 32 深度

                // 邻域对齐：若请求点奇偶与目标 bank 奇偶不匹配则 +1 取相邻点
                wire [5:0] xa0 = x0 + ((x0[0] == (k % 2)) ? 6'd0 : 6'd1);
                wire [5:0] xa1 = x1 + ((x1[0] == (k % 2)) ? 6'd0 : 6'd1);
                wire [4:0] ya0 = y0 + ((y0[0] == (k / 2)) ? 5'd0 : 5'd1);
                wire [4:0] ya1 = y1 + ((y1[0] == (k / 2)) ? 5'd0 : 5'd1);

                // 读地址：{行高位 ya[4:1], 字选 xa[5]}
                wire [4:0] a0 = {ya0[4:1], xa0[5]};
                wire [4:0] a1 = {ya1[4:1], xa1[5]};
                // 写地址：{字高位 fill_word[5:2], 字奇偶 fill_word[0]}
                wire [4:0] wa = {fill_word[5:2], fill_word[0]};
                // 写使能：Filling 且组匹配，且字内半位匹配 k 的低半
                wire we = fill && fill_bank == b && fill_word[1] == (k / 2);

                // 填充数据重组：把 256 位按奇偶字节拆成两组 128 位
                wire [127:0] packed_data;
                for (n = 0; n < 16; n = n + 1) begin : PACK
                    assign packed_data[n * 8 +: 8] = fill_data[(2 * n + (k % 2)) * 8 +: 8];
                end

                reg [127:0] r0;
                reg [127:0] r1;
                reg [3:0] sel0;
                reg [3:0] sel1;

                always @(posedge clk) begin
                    if (we)
                        mem[wa] <= packed_data;   // 填充优先，本拍不读
                    else
                        r0 <= mem[a0];            // 否则读采样地址
                    r1 <= mem[a1];
                    sel0 <= xa0[4:1];            // 低 4 位字节选择
                    sel1 <= xa1[4:1];
                end

                assign q0[b * 4 + k] = r0[sel0 * 8 +: 8];
                assign q1[b * 4 + k] = r1[sel1 * 8 +: 8];
            end
        end
    endgenerate

    // bank_d/xp/yp 与 RAM 读寄存器同拍，用于最后拼接 4 个像素
    always @(posedge clk) begin
        bank_d <= sample_bank;
        xp0 <= x0[0];
        yp0 <= y0[0];
        xp1 <= x1[0];
        yp1 <= y1[0];
    end

    // 根据采样点的实际奇偶，从对应奇偶 bank 取出 4 个像素并按 p00/p10/p01/p11 打包
    // ~yp/~xp 用于补全 2x2 中与目标点奇偶互补的相邻字节。
    assign pixels0 = {q0[{bank_d, ~yp0, ~xp0}], q0[{bank_d, ~yp0, xp0}], q0[{bank_d, yp0, ~xp0}], q0[{bank_d, yp0, xp0}]};
    assign pixels1 = {q1[{bank_d, ~yp1, ~xp1}], q1[{bank_d, ~yp1, xp1}], q1[{bank_d, yp1, ~xp1}], q1[{bank_d, yp1, xp1}]};

endmodule

`default_nettype wire