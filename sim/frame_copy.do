onerror {quit -code 1 -force}
onbreak {quit -code 1 -force}
if {![file exists sim/work]} {vlib sim/work}
vmap work sim/work
vlog source/undistort/ud_system.v
vlog -sv sim/tb_frame_copy.sv
vsim -c work.tb_frame_copy
run -all
quit -code 0 -force
