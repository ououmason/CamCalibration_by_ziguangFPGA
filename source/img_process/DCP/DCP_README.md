# DCP 去雾 RTL

`HDMI_IN_DDR3_YCbCr_top.v` 已将本模块接在 `ud_system` 的 DDR 结果帧显示读回之后，输出到 HDMI 之前。五个 RTL 文件已登记在 `HDMI_IN_DDR3_YCbCr.pds`，无需再手动加入工程。

## 接口约定

板级控制：C22 对应 `key[0]`，按下切换矫正；C23 对应 `key[1]`，按下切换去雾。两个按键独立消抖，默认低有效，上电均关闭，长按只切换一次。去雾开关跨时钟同步后在输出 VS 上升沿锁存，旁路 RGB 延迟同样为 8 级；HS/VS/DE 始终走 DCP 流水线。`heart_beat_led` 指示矫正状态。

顶层已取消 `rst_in` 外部复位端口。像素 PLL 与配置 PLL 均锁定后，各时钟域同步释放复位；配置域继续等待原有的 10,000 个 `cfg_clk` 周期，再释放 `rstn_out`，启动 HDMI 配置和 DDR 初始化。任一 PLL 失锁会重新复位，并清除两个按键的功能使能；视频链路在 DDR 初始化完成后启动。

- 单像素时钟 `clk`，低有效异步复位 `rst_n`，释放复位应同步到 `clk`。
- `pix_in_I[23:0] = {R[7:0], G[7:0], B[7:0]}`，输出格式相同。仅 `de_out=1` 时输出 RGB 有效。
- `vsync_in` 上升沿标记新帧，必须位于 `de_in=0` 的消隐期，并在第一有效像素之前至少一拍出现。低有效 VS 请在模块外先反相，输出按需要再反相。
- `IMAGE_WIDTH` 为每行有效像素数，默认 1920。内部按有效像素计数换行；HS 仅随流水线传递。每行必须恰好有 IMAGE_WIDTH 个有效像素。支持行内 DE 空洞、可变消隐和无消隐连续行。
- `A_now` 为当前帧已接收像素的最大 RGB 分量，在新帧 VS 上升沿清零。内部 `A_prev` 在该沿锁存上一帧最大值并保持整帧不变。空帧保持旧 A，全黑帧 A 钳位到 1，首帧使用 `A_INIT`（默认 255，设为 0 时钳位到 1）。最后一帧的 A 要到下一次 VS 上升沿才锁存。
- `T_MIN` 范围 16..256，默认 38（38/256≈0.148）；256 表示恢复级单位增益。

```verilog
DCP_dehaze #(.IMAGE_WIDTH(1920), .T_MIN(38)) u_dehaze (
    .clk(pixclk_in), .rst_n(video_rst_n),
    .vsync_in(vs_in), .hsync_in(hs_in), .de_in(de_in),
    .pix_in_I({r_in,g_in,b_in}),
    .vsync_out(dehaze_vs), .hsync_out(dehaze_hs), .de_out(dehaze_de),
    .pix_out_J({dehaze_r,dehaze_g,dehaze_b}), .A_now()
);
```

## 算法与定点数

调整去雾强度：在工程目录执行以下命令，脚本会在自身目录重新生成 `dcp_recip_lut.v`，然后重新综合并下载：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File source/img_process/DCP/gen_lut.ps1 -Omega 0.75
```

Omega 越小，去雾越温和；当前为 0.75，原版本为 0.9375，可试 0.65 或 0.70。脚本只修改倒数表，不修改 T_MIN；实际板级 T_MIN 在顶层 `ddr_result_dehaze` 实例设置，当前为 38。恢复级的 t 倒数表保持不变。仿真参考模型的 AIR_SCALE 参数应设置为 `floor(Omega*65536)`，当前为 49152。

先求每个像素 `min(R,G,B)`，再做 3×3 最小值滤波。窗口覆盖 `(x-2..x, y-2..y)`，上边界、左边界复制最近有效像素。因此输出像素对应当前输入坐标，不需要缓存两行原始 RGB。它是因果窗口，**不是以当前像素为中心的 3×3 窗口**。

为节省资源，A 为单个 8 位灰度标量，取 `max_frame(max(R,G,B))`。没有实现标准 DCP 的“暗通道前 0.1% 候选点筛选，再估计三通道大气光”，也没有导向滤波。强亮点、彩色光源或帧间亮度突变可能影响估计；小窗口的去雾强度和细节效果也与完整 DCP 不同。

实际整数运算（floor 表示向下取整）：

```text
KA = floor(49152 / max(A,1))      // omega=0.75, scale=floor(omega*65536)
penalty = floor(dark * KA / 256)
t = max(T_MIN, 256 - penalty)    // 9 位，256 代表 1.0
KT = floor(65536 / t)            // KT≈256/(t/256)
Jc = clamp(A + floor((Ic-A)*KT/256), 0, 255)
```

KA、KT 是 RTL case 常量表；没有运行时除法器。恢复差值及乘积采用有符号运算，负数右移向负无穷取整，最后饱和而非截断回绕。上一帧 A 较小时 penalty 可以超过 256，在减法前先钳位，避免无符号下溢。

## 流水线与资源

| 模块 | 寄存器级数 | 主要资源 |
|---|---:|---|
| dark_tunnel | 2 | 两行 8 位 RAM、最小值比较器、帧最大值比较器 |
| t_computer | 3 | 256×16 常量表、一次 8×16 乘法 |
| J_recovery | 3 | 透射率倒数常量表、三路有符号乘法、饱和逻辑 |

总计 8 级寄存器，无停顿时每拍一个像素。若输入在时钟沿 n 采样，输出在时钟沿 n+7 更新；同步信号和 DE 同样经过 8 个寄存器。消隐期间流水线继续推进，不按 DE 冻结。

行缓存总容量 `2*IMAGE_WIDTH*8` bit，1920 宽时为 30,720 bit（3,840 字节）。两个 RAM 按行轮换写入，均同步读取。RAM 没有复位和初始化，帧首行计数会屏蔽旧内容。RGB 只做少量寄存器延迟，无整帧缓存。

RTL 共四个乘法表达式，实际 DSP、RAM、LUT 数量及最高时钟频率以 PDS 综合和布局布线报告为准。case 倒数表可能映射成 LUT 逻辑，也可能被工具识别为 ROM。本次仅完成 RTL 仿真，未做器件综合或时序收敛。

## 若自行生成 IP

当前版本不依赖厂商 IP，可以直接综合。请检查综合报告是否把行缓存推断成块 RAM。若需要替换 `dark_tunnel` 的两个数组：

- 每个 RAM 数据宽度 8、深度 IMAGE_WIDTH，地址宽度 `max(1,ceil(log2(IMAGE_WIDTH)))`。
- 单时钟同步读，同地址读写必须返回**写入前旧数据（READ_FIRST / old data）**；不使用额外输出寄存器。当前周期送地址，在该时钟沿后获得旧数据。
- 两个 RAM 的读使能均为 `rst_n && de_in && !sof`；写使能分别再与 `!bank`、`bank` 相与。地址都是 x，写数据都是 horizontal。
- 禁止对 RAM 内容做逐项复位；保留现有行计数屏蔽逻辑。
- 若器件 RAM 不支持该碰撞语义，不能直接使用 write-first IP 替换，需调整缓存结构和时序。
- 倒数表目前是组合查表，后面已有寄存器。换成同步 ROM 时要替换对应的查表加寄存器这一级，不能再额外叠加一拍，否则须同时修改 RGB/A/同步延迟。

## 验证

`sim/tb_dcp_dehaze.sv` 使用独立逐像素整数参考模型检查 RGB、同步信号及 A_now；包含全黑、全白、灰度、彩色、随机多帧、可变消隐、行内 DE 空洞、连续行和流水线中途复位。用 W 参数覆盖窄图边界，用 TM 参数覆盖透射率下限和单位增益。
