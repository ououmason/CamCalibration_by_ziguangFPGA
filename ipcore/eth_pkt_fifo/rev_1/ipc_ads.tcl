# Generated at 2026-10-05 18:14

set_arch -family Logos2 -device PG2L100H -package FBG676 -speedgrade -6
add_design "D:/EEprjs_plans/2026EE_Competiton_Ziguang/ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ/fpga_code/HDMI_UNDISTORT/ipcore/eth_pkt_fifo/rtl/ipm2l_fifo_ctrl_v1_1_eth_pkt_fifo.v"
add_design "D:/EEprjs_plans/2026EE_Competiton_Ziguang/ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ/fpga_code/HDMI_UNDISTORT/ipcore/eth_pkt_fifo/rtl/ipm2l_sdpram_v1_13_eth_pkt_fifo.v"
add_design "D:/EEprjs_plans/2026EE_Competiton_Ziguang/ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ/fpga_code/HDMI_UNDISTORT/ipcore/eth_pkt_fifo/rtl/ipm2l_fifo_v1_13_eth_pkt_fifo.v"
add_design "D:/EEprjs_plans/2026EE_Competiton_Ziguang/ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ/fpga_code/HDMI_UNDISTORT/ipcore/eth_pkt_fifo/eth_pkt_fifo.v"
compile -top_module eth_pkt_fifo
synthesize -ads
