onerror {quit -code 1 -force}
onbreak {quit -code 1 -force}
exec node sim/make_rgb_expected.mjs --small
if {![file exists sim/work]} {vlib sim/work}
vmap work sim/work
vlog source/undistort/ud_coord.v source/undistort/ud_tile_ram.v source/undistort/ud_engine.v
vlog -sv sim/tb_rgb_engine.sv
vsim -c work.tb_rgb_engine
run -all
quit -code 0 -force
