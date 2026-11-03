onerror {quit -code 1 -force}
onbreak {quit -code 1 -force}
if {![file exists sim/gamma_work]} {vlib sim/gamma_work}
vmap work sim/gamma_work
vlog source/undistort/ud_reset.v
vlog source/img_process/gamma/*.v
vlog source/img_process/DCP/DCP_dehaze.v source/img_process/DCP/dark_tunnel.v source/img_process/DCP/t_computer.v source/img_process/DCP/J_recovery.v source/img_process/DCP/dcp_recip_lut.v
vlog source/rtl/HDMI_IN_DDR3_YCbCr_top.v
vlog -sv sim/tb_gamma_video.sv sim/tb_dcp_dehaze.sv sim/tb_gamma_chain.sv
if {[info exists GAMMA_CHAIN]} {
    vsim -c -voptargs=+acc work.tb_gamma_chain
} else {
    vsim -c work.tb_gamma_video
}
run -all
quit -code 0 -force
