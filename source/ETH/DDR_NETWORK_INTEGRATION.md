# DDR 结果帧网口接入

本次只做源码连接、分析和 `vlog -lint` 静态编译，没有运行仿真、综合、布局布线或下载。

## 数据路径

`ud_system` 已显示的完整 DDR 结果帧槽位 → 独立 DDR 读通道 → R/G/B 平面转 RGB888 → `../ipcore/eth_pkt_fifo` → 整包缓存 → 现有 `udp_ip_mac_top` → 现有 `rgmii_interface`。

取的是 `ddr_rgb` 对应的 DDR 结果，位于去雾、Gamma、直方图均衡之前。实际从同一 DDR 槽位重新读取，避免 HDMI 像素流不可反压的问题。发送期间保留该槽位的额外引用，即使 HDMI 切换到其他帧也禁止覆写。显示读取优先，其次网口读取，最后计算读取；网口每次只保留一个 32 字节读事务，等待返回后才发下一个。网络标签使用 bit 13，显示使用 bit 15，现有计算标签不占用 bit 13。

网口忙时继续处理、显示新帧，当前网口帧发完后再锁住当时的显示结果帧。可能跳过中间帧，也可能重复发送仍在显示的同一个结果。千兆链路不能传输 1080p60 RGB888；当前逐包预缓存设计的理想发送上限约 12 fps，实际受 DDR、协议和接收端影响。UDP 不重传，网络丢包仍可能导致接收端丢弃不完整帧。

## 顶层端口

已移除未驱动的 `eth_tx_clk/eth_tx_en/eth_txd/eth_tx_req` 占位接口，换成：

| 端口 | 方向 | 宽度 |
|---|---|---|
| eth_rst_n_0 | 输出 | 1 |
| eth_rgmii_rxc_0 | 输入 | 1 |
| eth_rgmii_rx_ctl_0 | 输入 | 1 |
| eth_rgmii_rxd_0 | 输入 | 4 |
| eth_rgmii_txc_0 | 输出 | 1 |
| eth_rgmii_tx_ctl_0 | 输出 | 1 |
| eth_rgmii_txd_0 | 输出 | 4 |

没有添加 MDIO。PHY 复位跟随 `rstn_out`，不依赖 PHY RX 时钟 PLL 锁定，避免启动时等待闭环。RX PLL、移相 RX 时钟进入 `rgmii_interface`、TX IODELAY 配置均沿用已验证例程。要求千兆模式 RX 时钟 125 MHz；不支持自动适配百兆。网口 PLL 失锁会复位 FIFO 两侧和发送状态机，并在未完成 DDR 读返回后释放锁住的帧，不复位视频系统。

## PDS 源文件与 IP

新增设计源：`source/ETH/eth_ddr_video.v`。保留修改后的 `source/rtl/HDMI_IN_DDR3_YCbCr_top.v` 和 `source/undistort/ud_system.v`。

添加 ETH 下所有协议设计 `.v`，**不需要**例程顶层 `ethernet_test.v`、测试应用 `eth_udp_test.v`。Include 搜索目录添加 `source/ETH`，用于 `check_sum.vh`。

添加或确认：

- `ipcore/eth_pkt_fifo/eth_pkt_fifo.idf`：工程文件已有引用。保持异步 FIFO、32→32 位、深度 1024、`OUTPUT_REG=0`、`FAB_REG=0`。现有接口是同步读一拍，新增逻辑按该延迟取数。
- `ipcore/ref_clock/ref_clock.idf`：父目录已有 IP，当前 PDS 未发现引用。保持验证例程原配置。
- `udp_shift_register`：当前未找到实现，由你添加；端口 `din[7:0]、clk、rst、dout[7:0]`，`rst` 高有效，数据**连续延迟 8 拍**，无使能。这个延迟用于对齐 UDP 的 8 字节首部，不能改成普通一拍寄存器。
- `icmp_rx_ram_8_256`：当前未找到实现，由你添加。实际连接要求 8 位数据、11 位读写地址（2048 深度），双端口同步读 RAM；高有效读写复位，端口见 `icmp.v:337`。名字/旧注释的 256 深度与实际地址宽度不一致，应以源码接口为准。

新模块中的整包缓存为 RTL 推断 RAM，245×32 位，无需额外命名 IP。请检查综合是否按 RAM 推断。

父目录 `impl.tcl` 仍引用旧的、不存在的 `eth_img_pkt.v/udp_top.v/gmii_to_rgmii.v` 等文件；不能直接用它表示当前源码清单。本次未修改父目录 PDS、TCL、FDC。请在 PDS 中更新源清单，补齐 RGMII 引脚、时钟、IO 时序、PLL 生成时钟和异步 FIFO 跨域约束；引脚位置未推测填写。

## 地址和包格式

顶层参数默认 FPGA `192.168.1.11`，源 UDP 端口 `0x8080`，PC `192.168.1.105`，目标 UDP 端口 `1234`。MAC 保留验证例程的 `11:11:11:11:11:11`；这是组播位为 1 的地址，正式接入网络建议改成合法本地单播 MAC，例如 `02:11:11:11:11:11`。请按实板已验证配置选择。

每包应用数据 980 字节：20 字节 EVID 首部 + 960 字节 RGB。每帧 6480 包，包号从 0 开始，所有多字节首部字段为网络字节序。格式与父目录 `host_video_receiver.py` 一致，PC 运行 `python host_video_receiver.py --port 1234`。当前参数只适用于宽度为 32 倍数、总像素数为 320 倍数的图像；1920×1080 满足要求。

## 静态检查结果

2026-10-10 板上抓包出现 `32772 -> 53763 / BAD UDP LENGTH 56320`：新增发送器在 UDP 确认后比原例程提前一拍给出 `app_data_in_valid`，导致 UDP 首字节经过协议选择寄存器后，在 IP 计数 33（最后一个目的 IP 字节）处被覆盖。已添加 `T_START` 等待态，恢复原例程的启动延迟。逐拍分析：IP 计数 29 发出上层请求，30 观察确认，32 输出 UDP 首字节，33 经过选择寄存器，34 被 IP 采入；应用首字节同时进入 8 拍移位 IP，40 输出为 UDP 负载首字节。新增发送器及 IP 发送/选择模块静态编译 0 错误、0 警告，未仿真。重新综合下载后，UDP 首部应为 `80 80 04 D2 03 DC 00 00`，紧跟 `45 56 49 44`（EVID）；需实板抓包确认。

修改的顶层、`ud_system.v`、新增 `eth_ddr_video.v` 单独 `vlog -lint`：0 错误、0 警告。连同现有 `eth_pkt_fifo/ref_clock` IP 源码静态编译：0 错误、2 个原 IP 的 ECC 注入信号隐式声明警告。完整原有依赖在 ModelSim 严格编译下发现以下原有问题，未改变验证过的例程行为：

- `ETH/ip_layer.v:69` 重复声明输出 `ip_tx_req`。
- `ETH/rgmii_interface.v:197`、`:198` 先使用信号，`:206`、`:207` 再声明，触发隐式网线重复声明。
- `ETH/udp_tx.v:54` 先使用 `state/IDLE`，在后面才声明。
- `hdmi/ms72xx_ctl.v:47` 重复声明输出 `init_over_rx`。
- ETH 中还存在 `arp_reply_ack`、`icmp_rx_req`、`ip_tx_req` 的隐式网线警告。

因此“修改文件静态编译通过”不等于“完整工程已编译、综合或板测通过”。本次没有执行仿真，也没有证明实际网口吞吐、PHY 时序或资源占用。
