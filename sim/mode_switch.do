onerror {quit -code 1 -force}
onbreak {quit -code 1 -force}
exec node sim/make_rgb_expected.mjs --small
if {![file exists sim/work]} {vlib sim/work}
vmap work sim/work
vlog source/undistort/*.v source/rtl/HDMI_IN_DDR3_YCbCr_top.v
vlog -sv +define+PATTERN +define+MODE_SWITCH sim/tb_system.sv
vsim -c work.tb_system
run -all
quit -code 0 -force
