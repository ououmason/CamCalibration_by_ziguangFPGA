# 灰度畸变矫正源码

本目录是对已验证 DDR 灰度工程的源码扩展。`HDMI_UNDISTORT` 完整复制了原工程；原有 IP、PDS 工程文件和实现脚本未修改。FDC 在 2026-09-10 增加了按键 C23 约束；历史 bit 文件和实现报告不能代表当前源码的结果。

## 在 PDS 中接入

1. 打开 **HDMI_UNDISTORT** 内的 `HDMI_IN_DDR3_YCbCr.pds`，不要打开原目录中的同名工程。
2. 将本目录的九个 `.v` 文件添加到设计源文件。原顶层名称和文件位置保持不变：`source/rtl/HDMI_IN_DDR3_YCbCr_top.v` 已接入 `ud_system`。新增顶层输入 `key`；原 `heart_beat_led` 输出现用于矫正模式指示。
3. 保留原 DDR3、PLL、cfg_pll、HDMI 配置 IP 和约束。原 `fram_buf`、`wr_buf` 等模块不再被新顶层实例化，可暂时留在工程中。
4. ROM 使用 `source/undistort/rom/map.hex`。路径相对于工程根目录；综合报告中应确认 ROM 初始化成功。若 PDS 的综合工作目录不同，在 PDS 中设置该初始化文件的解析路径。
5. 由你运行 PDS 的综合、映射、时序分析和下载。本次没有运行或修改这些步骤。

## 单击切换与第一灯指示

上电或复位后默认输出灰度原图，第一灯灭。每次有效按下切换一次模式：开启矫正时第一灯亮，再单击关闭矫正、灯灭。松开不切换，长按不重复触发。

| 信号 | 管脚 | 来源/用途 |
| --- | --- | --- |
| `key` | C23 | `2_7_key_led_test/2_7_key_led_test/2_7_key_led_test/source/key_led_test.fdc` 中的按键 |
| `heart_beat_led` | A20 | 同一示例的 `led[0]`，第一个灯；替换原心跳闪烁 |

示例按 `key` 的高低电平决定流水灯方向，没有消抖，也没有注明实际按下极性。此版默认 `KEY_ACTIVE_LOW=1`、`LED_ACTIVE_LOW=0`；若实板极性不同，在顶层参数中调整。第一灯复用原 A20 约束，不新增其他模式灯，也不引入示例的八灯移位逻辑。

按键逻辑 `ud_key_toggle` 放在已有 `ud_reset.v` 中；27 MHz `sys_clk` 下按下、释放均需稳定 540000 周期（20 ms）。切换状态经双触发器同步到 DDR 用户时钟域，每次开始处理完整源帧时锁存为 `proc_enable`；处理中不响应模式变化，显示仍只在帧边界选取完整结果。LED 指示用户选定模式，画面会在消抖及已有帧缓存延迟后切换。

关闭矫正时使用 `ud_system.v` 内的 `ud_frame_copy`，以最多 16 拍、每拍 32 字节突发直接复制灰度源帧到结果帧；先收齐突发再写，单次缓冲 512 字节。旁路不查坐标表、不插值或裁剪，因此末行末列也与灰度源帧完全一致。它与矫正核心共用帧所有权、DDR 适配器和 HDMI 显示路径。无需向 PDS 添加额外 `.v` 文件或 IP。

目标器件沿用 PG2L100H-6 FBG676，DDR 用户时钟约 125 MHz，输出像素时钟 148.5 MHz。`MEM_DQ_WIDTH` 必须保持 32；宽度参数仅保留原顶层接口兼容性，不表示此版本支持其他 DDR 数据位宽。

## 数据与坐标

输入为 1920x1080 的 RGB888 并行视频，DE 标记有效像素，正极性 VS 上升沿开始帧。输入先按原工程截取 RGB565，再按原展开方式恢复到 8 位并计算 `Y=(77R+150G+29B)>>8`。Y 以完整 8 位存入 DDR；输出三个通道均为 Y。HS 保留板级引脚，由 DE 边沿统计输入行。

固定标定参数来自根目录 `rec_picture.m`。控制点先使用 MATLAB 的一基坐标公式计算、裁剪，再减 1 转为零基源坐标。ROM 有 121x69=8349 项，行优先，每项 48 位：高 24 位 V，低 24 位 U，各为无符号 12 位整数加 12 位小数。

坐标表通过 `ud_engine.v` 内的 `ud_map_rom` 单端口同步读取，使用 `syn_romstyle="block_rom"` 指定块 ROM 推断。状态 1～4 共用一个地址端口发出四次读取，状态 2～5 接收对应控制点，状态 7 才计算源块范围。ROM 输出寄存器不复位，控制点有效性由装载状态保证。该子模块在已有 `.v` 文件内，无需向 PDS 添加新文件。

修正后应从综合阶段重新运行，检查 `correction/engine/map_rom` 映射为 DRM；不应再出现原先 `rom_4`～`rom_11` 八组大容量分布式 ROM。LUT 应明显下降、DRM 相应增加，实际数量及 Place/Route 耗时以重新综合后的报告为准。

输出每 16x16 像素为一个块，顺序读取四个控制点。常规坐标权重分母为 16，最右网格为 15，最下为 7。最后一个输出块高 8；坐标网格跨度 7 与输出 8 行是不同概念。权重为 U1.16，能表示端点 1，坐标只在完成两个方向插值后舍入到 U12.12。

随后以坐标整数部分读取 `P00/P10/P01/P11`，使用 12 位小数权重进行像素插值；最后加 `2^23`、右移 24 位并限制到 255。中间乘加结果不提前截断。两路相邻输出像素并行计算。

当前只支持宽度为 32 的倍数、高度为 16 的倍数或余 8，且源块预取范围不超过下面的缓存容量。不要仅改 W/H 就用于任意格式；必须同时生成适配 ROM、视频时序和参考向量。

## 存储与帧所有权

内部地址均为字节地址，DDR 保存行优先灰度，每行 1920 字节、每帧 2073600 字节。

| 用途 | 三个槽位基址 | 单槽分配 |
| --- | --- | --- |
| 输入源帧 | 0x000000、0x200000、0x400000 | 2 MiB |
| 矫正结果帧 | 0x600000、0x800000、0xA00000 | 2 MiB |

源帧状态为 FREE -> CAPTURE -> READY -> PROCESS -> FREE；结果帧为 FREE -> PROCESS -> READY -> DISPLAY -> FREE。只有完整帧的全部写突发完成后才能发布 READY。处理中源帧和显示中结果帧禁止被写入；源帧无空槽时整帧丢弃，结果槽不足时等待。显示在 VS 帧边界选最新 READY，丢弃其他旧 READY；没有新结果则重复上一结果。旧显示槽在其所有读请求返回后才释放。

块预取由四个定点控制点的最小/最大值确定，双线性坐标始终在其包围矩形内。当前 ROM 最大邻域为 18x18；读取横向扩展到 32 字节边界，两组源缓存各为 64x32 字节。填充一组时计算另一组。缓存按 x/y 奇偶分成四个银行，每银行的两个端口服务两路计算，填充和计算通过所有权隔离。

两组结果带缓存每组 16x1920 字节。计算按块写入，写回端重新按行连续输出 256 位数据，最多 16 拍一个突发。接收、显示各使用 256 项跨时钟 FIFO，即各约 8 KiB 像素容量，另含帧标记。

## 时序对齐

接收和计算不要求同时走到同一个坐标。接收流携带帧号和字节偏移，EOF 描述符确认行数和像素数；先完整存帧，再由输出坐标驱动读取。

DDR 适配器最多保留 16 个读事务，分配不同 ID，记录缓存位置标签和每个事务的返回拍计数。跨 ID 返回次序变化时，仍通过 ID 将数据写入正确的缓存地址。同 ID 的拍必须保持顺序。返回端没有 ready，所以发命令前必须预留容量；显示仅保留一个未完成突发，维持光栅顺序。

源块收齐才发布 available。块内计算延迟固定：坐标 3 级、RAM 1 级、像素插值 3 级；输出地址、带号和块尾标记走相同长度流水线。块释放发生在最后一对结果被写入后。此处的固定延迟只用于片上确定延迟流水线，不用于猜测 DDR 返回时间。

显示时钟持续产生同步信号。输出数据带显示 epoch，旧 epoch 的 FIFO 数据被丢弃，避免帧切换时残留数据混入新帧。欠载后本帧剩余部分输出黑色，下个帧边界恢复。启动尚无结果时输出黑场。

复位异步置位、各时钟域同步释放；FIFO 两侧共同复位，不在每个 VS 单独清 FIFO。发生输入缺失或错位时废弃源帧；部分写突发先收尾再释放槽位。

## DDR 接口与资源

`ud_ddr_port` 对接的是现有 Pango 用户口，**不是标准 AXI4**。读写地址送 IP 前右移 2 位；一个 256 位拍对应 32 字节/8 个 IP 地址单位。AR/AW 用 valid/ready，写数据按该口的 wready 消耗，写完成等待 wusero_last；没有 AXI WVALID、B 或 RREADY 接口。WSTRB 全 1，所有写入均为完整 32 字节字，不作局部字节更新。

不需要新增 DDR 或浮点/除法 IP。片上 RAM/ROM/FIFO 使用可综合 RTL推断；如 PDS 没有推断成所需存储器，请在保持接口和读延迟的前提下换成 Pango 存储器 IP。不要将缓存综合为大规模寄存器后直接忽略资源报告。

当前定点 ROM 的对齐预取流量约 6.904 MB/帧，加接收写、结果写和显示读，60 fps 理想有效流量约 **787.5 MB/s**。这不包括刷新、读写切换和行激活开销。

PDS 中需确认输入/输出像素时钟和 DDR 用户时钟均受约束，异步 FIFO Gray 指针跨域约束、输入输出延迟及复位同步链正确。原 FDC 仅作为板级基线，不能用它的历史时序报告证明新逻辑满足要求。时序约束由用户在 PDS 中维护。

## 仿真和参考

在工程根目录运行，测试失败退出码非零，默认不记录全量波形：

```powershell
node tools/generate.mjs --small
node tools/generate.mjs --small --capture
node tools/generate.mjs
& D:/Software/modelsim/win64/vsim.exe -c -do sim/engine.do -l sim/engine.log
& D:/Software/modelsim/win64/vsim.exe -c -do sim/system.do -l sim/system.log
& D:/Software/modelsim/win64/vsim.exe -c -do sim/recovery.do -l sim/recovery.log
& D:/Software/modelsim/win64/vsim.exe -c -do sim/pattern.do -l sim/pattern.log
& D:/Software/modelsim/win64/vsim.exe -c -do sim/full_engine.do -l sim/full.log
& D:/Software/modelsim/win64/vsim.exe -c -do sim/full_system.do -l sim/full_system.log
& D:/Software/modelsim/win64/vsim.exe -c -do sim/key.do -l sim/key.log
& D:/Software/modelsim/win64/vsim.exe -c -do sim/mode_switch.do -l sim/mode_switch.log
& D:/Software/modelsim/win64/vsim.exe -c -do sim/frame_copy.do -l sim/frame_copy.log
```

常规开发只需运行小尺寸测试；完整 1080p 验证用于算法或调度发生变化时。模型覆盖握手间隙、可变读延迟及跨 ID 返回顺序变化，但不代替真实 DDR PHY、电气及 PDS 布局布线验证。

MATLAB 独立参考位于本目录：`addpath('source/undistort'); ud_reference(false)`。它校验 ROM 与定点结果，报告相对原浮点稀疏网格算法的误差。`ud_reference(false,'camera.png')` 可检查实际 1080p 图片。当前目录没有相机原图，随工程的测试图均为合成数据，不作为镜头标定精度证明。

调试信号在顶层 `correction` 层级：`proc_enable`、`processing_cycles`、`dropped_frames`、`capture.overflow_count`、`display.underflow_count`、`port.protocol_error`、`engine.fault`、`bypass.fault`。第一灯仅指示用户选择的矫正模式；HDMI 和 DDR 初始化状态输出沿用原连接。
