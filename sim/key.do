onerror {quit -code 1 -force}
onbreak {quit -code 1 -force}
if {![file exists sim/work]} {vlib sim/work}
vmap work sim/work
vlog source/undistort/ud_reset.v
vlog -sv sim/tb_key_toggle.sv
vsim -c work.tb_key_toggle
run -all
quit -code 0 -force
