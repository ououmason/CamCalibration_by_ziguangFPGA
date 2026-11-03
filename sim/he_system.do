onerror {quit -code 1 -force}
onbreak {quit -code 1 -force}
if {![file exists sim/he_work]} {vlib sim/he_work}
vmap work sim/he_work
do sim/he_ip_compile.do
vlog source/undistort/*.v
vlog source/img_process/gamma/*.v source/img_process/HE/*.v
vlog source/img_process/DCP/DCP_dehaze.v source/img_process/DCP/dark_tunnel.v source/img_process/DCP/t_computer.v source/img_process/DCP/J_recovery.v source/img_process/DCP/dcp_recip_lut.v
vlog -sv +define+HE_SYSTEM +define+PATTERN sim/tb_system.sv sim/tb_he_system.sv
vsim -c -voptargs=+acc work.tb_he_system
run -all
quit -code 0 -force
