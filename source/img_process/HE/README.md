# HE 接入与 RAM IP 配置

视频通路：DDR/矫正 → 去雾及旁路 → gamma → HE → HDMI。A22 / key[3] 控制 HE，沿用原按键消抖翻转，默认关闭；在 VS 上升且 DE=0 时提交开关状态。

## 当前生成的两个 IP

| 模块名（必须匹配） | 类型 | 数据位宽 | 深度 | 地址位宽 | 数量 |
| --- | --- | ---: | ---: | ---: | ---: |
| he_hist_ram | 分布式简单双口 RAM | 32 bit | 256 | 8 bit | 1 |
| he_map_ram | 分布式简单双口 RAM | 8 bit | 512 | 9 bit | 1 |

已核对 `ipcore/he_hist_ram` 和 `ipcore/he_map_ram` 中重新生成的 RTL：两者均为 `OUT_REG=1`、`RST_TYPE="ASYNC"`。直接实例化实际 IP，无额外适配层或外部读寄存器。

当前连接与时序：

- `wr_clk` 和 `rd_clk` 都连接像素时钟 clk。
- **`OUT_REG=1`：组合存储器读值由 IP 内的 q_reg 在上升沿采样，严格一拍同步读。** 不再增加外部输出寄存器；不要改回 OUT_REG=0，否则数据与同步信号错拍。
- **同地址读写返回 OLD_DATA（写入前旧数据）。** 生成的 RTL 在同一边沿寄存旧读值、非阻塞更新 RAM，直方图统计的前递逻辑已按该行为验证。
- 高有效 `rst` 连接 `!rst_n`，清除 IP 输出寄存器，不清除 RAM 内容。HE 复位后用 256 拍清零直方图，并屏蔽未初始化映射表；不需要初始化文件。
- 读端始终工作；`wr_en` 控制写口，无额外握手。

实际 IP 顶层接口如下，HE RTL 已按这些模块名和端口名直接连接：

```verilog
module he_hist_ram(
    input wr_clk, rd_clk, wr_en, rst,
    input [7:0] wr_addr, rd_addr,
    input [31:0] wr_data,
    output [31:0] rd_data
);
endmodule

module he_map_ram(
    input wr_clk, rd_clk, wr_en, rst,
    input [8:0] wr_addr, rd_addr,
    input [7:0] wr_data,
    output [7:0] rd_data
);
endmodule
```

逻辑存储量：8192 + 4096 = 12288 bit；实际物理 RAM 块数以 IP 生成器和综合报告为准。

## RTL 行为

- RGB↔YUV 使用全范围 BT.601 的整数系数，采用四舍五入、有符号中间值和 0..255 饱和；均衡只改变 Y，U/V 与 Y 同步延迟。
- 使用全局限幅 HE：每个 bin 上限为 `ceil(总像素数/128)`，1080p 为 16200；超过上限的计数均匀分配到 256 个 bin，余数依次分配到低地址 bin，总计数保持不变。重新分配后允许略超初始限幅值。
- 使用重分配直方图生成 `HE=floor(255*CDF/总像素数)`，最终 LUT 为 `floor((3*原灰度+HE)/4)`，即 25% 均衡强度；不做 CDF_min 全幅拉伸，避免再次放大低对比度噪声。
- 原始直方图最大与最小有效灰度之差不超过 8 时，整张 LUT 使用恒等映射；黑场、恒定灰度及窄范围暗噪声保持原亮度。该判断使用上一完整帧统计，不是空间降噪滤波。
- 直方图只统计 DE=1 的像素，VS 使用当前工程的高有效消隐同步脉冲。连续相同灰度及 A/B/A 地址读写冲突通过前递处理。
- 已完成帧的像素数必须严格等于宽×高。短帧、长帧及统计期间被映射生成占用的帧均丢弃统计，保持最近有效映射。
- VS 上升时开始生成上一帧映射；增加 512 拍预扫描统计超额计数与灰度范围，再用串行恢复除法精确归一化，完整生成约 9474 个像素时钟。两组 256 项映射表放在一个 512 深度 RAM 中，写入后台组，不修改当前帧正在使用的表。沿用两个现有 RAM IP 和八级像素通路，gamma 与顶层连接未修改。
- 正常情况下，VS 至首个有效像素应留至少 9476 拍。当前 1080p 时序的 VS 加后沿约 41×2200=90200 拍，足够完成生成。
- 若消隐过短，当前活动画面继续用旧映射；新表完成后仅在后续 VS 提交，同时丢弃未能完整统计的帧，避免撕裂。
- 上电、复位后以及首个完整直方图尚未生成时，HE 输出原 RGB；关闭 HE 时也是原 RGB 精确旁路，不经过有损颜色往返转换。统计在关闭时继续工作，便于下一次开启。
- HE 输出和旁路均经过八级寄存器（3 + 1 + 4），HS/VS/DE 对齐，每拍可处理一个像素。8 个寄存器表示采样边沿后第 7 个后续边沿更新输出。

## 工程与仿真

`.pds` 未修改。自行加入此目录四个 RTL 文件（he_video.v、hist_equalization.v、rgb2yuv.v、yuv2rgb.v）及生成的两个 IP。rgb2yuv / yuv2rgb 增加了 rst_n；hist_equalization 增加 hist_valid。

仿真通过 sim/he_ip_compile.do 编译 `ipcore` 中实际生成的两个 IP 及其底层 RTL，已验证一拍读延迟、重复地址冲突和复位。旧 sim/he_ram_models.v 已不参与仿真，**不要与同名生成 IP 同时加入工程**。此前用于 OUT_REG=0 的 he_ram_adapter.v 已删除，工程列表中若曾加入该文件，请移除。

从工程根目录执行：

```powershell
powershell -ExecutionPolicy Bypass -File sim/run_he.ps1
```

需要 node 与 ModelSim vsim 在 PATH 中。脚本通过 sim/make_he_vectors.cjs 生成独立整数参考输入/期望文件，并检查仿真日志里的 Fatal / Error。

测试包括：

- he：16×16 多帧、全灰度、黑白图、彩色、随机、同灰度连续及交替地址、DE 空洞、短帧、按键抖动/长按/释放、帧内按键后下一帧生效、关闭旁路、复位；独立 CDF/RGB 逐像素参考。
- he_short_blank：不足消隐、延迟提交、统计丢弃、超长帧、旧表保持。
- he_color：RGB/YUV 整数参考、随机与饱和边界，防止溢出后回绕。
- he_hd_cdf：注入六组 1080p 直方图，覆盖双峰、全黑、恒定灰度、暗噪声、均匀分布及集中峰与稀疏离群点；检查全部 1536 项、单调性、相邻灰度增益和低对比度保护。
- he_system：32×24 矫正/DDR 行为模型 + 真实去雾 + gamma + HE，独立参考检查最终输出；仅 HE_SYSTEM 宏调整现有系统 testbench 的仿真消隐长度。

目前已完成使用实际生成 IP 的全部 HE RTL 仿真和顶层语法编译，未执行全工程综合、布局布线或上板测试。
