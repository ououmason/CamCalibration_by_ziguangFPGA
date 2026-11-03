# Gamma 接入与小范围仿真

视频通路：DDR/矫正输出 → 去雾及等延迟旁路 → RGB 三通道 gamma → HDMI 输出。

| 按键 | 引脚 | 功能 |
| --- | --- | --- |
| key[0] | C22 | 原有矫正开关 |
| key[1] | C23 | 原有去雾开关 |
| key[2] | B22 | gamma 开关 |
| key[3] | A22 | HE 开关，现已接入 gamma 后 |

gamma 使用已有 256 项 LUT，未修改映射值。修复原 LUT 数据组合输出、DE 寄存输出的错拍问题，两者现在均经过一个寄存器。新增 gamma_video 同步延迟 HS/VS/DE，并对旁路保持相同延迟。消隐 RGB 输出零，复位清除输出有效信号。

按键沿用 ud_key_toggle 的极性、消抖时间和按下翻转逻辑。gamma 默认关闭；跨时钟同步后，在 VS 上升且 DE=0 时更新模式，避免帧内切换。HE 接入说明和 RAM IP 配置见 source/img_process/HE/README.md。

不修改 `.pds`。请在自己的工程文件管理中加入 `source/img_process/gamma/gamma_table.v` 和 `source/img_process/gamma/gamma_video.v`。

在工程根目录运行：

```powershell
powershell -ExecutionPolicy Bypass -File sim/run_gamma.ps1
```

需要 ModelSim 的 `vsim` 在 PATH 中，也可分别运行 `vsim -c -do sim/gamma.do -l sim/gamma.log`、`gamma_chain.do`、`gamma_system.do`。

- tb_gamma_video：各 RGB 通道覆盖全部 256 个输入值；检查 gamma/旁路、HS/VS/DE、消隐、抖动、长按、释放、帧边界切换和处理中复位。
- tb_gamma_chain：复用已有 DCP 数值参考模型，测试 7×6 视频、可变消隐和 DE 空洞，覆盖去雾/gamma 四种开关组合。AIR_SCALE=45875 对应当前 DCP LUT 的 omega=0.7。
- tb_gamma_system：复用已有 32×24 矫正系统和 DDR 行为模型，接上真实 DCP 和 gamma，检查最终视频流。原系统检查继续验证矫正输出帧及 DDR 事务。

gamma_expected.hex 是现有 gamma 映射的固定快照，不依赖运行时 DUT 输出生成。测试不修改 HE、矫正或去雾源码。

本次验证范围是 RTL 小尺寸仿真与顶层语法编译，未执行全工程综合、布局布线或上板验证。
