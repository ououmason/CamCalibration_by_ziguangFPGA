# Generated at 2026-10-10 19:42

set_arch -family Logos2 -device PG2L100H -package FBG676 -speedgrade -6
add_design "D:/EEprjs_plans/2026EE_Competiton_Ziguang/ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ/fpga_code/HDMI_UNDISTORT/ipcore/he_hist_ram/rtl/ipm_distributed_sdpram_v1_3_he_hist_ram.v"
add_design "D:/EEprjs_plans/2026EE_Competiton_Ziguang/ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ/fpga_code/HDMI_UNDISTORT/ipcore/he_hist_ram/he_hist_ram.v"
compile -top_module he_hist_ram
synthesize -ads
