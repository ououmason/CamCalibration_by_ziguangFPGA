onerror {quit -code 1 -force}
onbreak {quit -code 1 -force}
if {![file exists sim/gamma_work]} {vlib sim/gamma_work}
vmap work sim/gamma_work
vlog source/undistort/*.v
vlog source/img_process/gamma/*.v
vlog source/img_process/DCP/DCP_dehaze.v source/img_process/DCP/dark_tunnel.v source/img_process/DCP/t_computer.v source/img_process/DCP/J_recovery.v source/img_process/DCP/dcp_recip_lut.v
vlog -sv sim/tb_system.sv sim/tb_gamma_system.sv
vsim -c -voptargs=+acc work.tb_gamma_system
run -all
quit -code 0 -force
