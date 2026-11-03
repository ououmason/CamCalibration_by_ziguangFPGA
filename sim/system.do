onerror {quit -code 1 -force}
onbreak {quit -code 1 -force}
if {![file exists sim/work]} {vlib sim/work}
vmap work sim/work
vlog source/undistort/*.v
vlog -sv sim/tb_system.sv
vsim -c -voptargs=+acc work.tb_system
run -all
quit -code 0 -force
