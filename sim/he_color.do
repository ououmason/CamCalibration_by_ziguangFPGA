onerror {quit -code 1 -force}
onbreak {quit -code 1 -force}
if {![file exists sim/he_work]} {vlib sim/he_work}
vmap work sim/he_work
vlog source/img_process/HE/rgb2yuv.v source/img_process/HE/yuv2rgb.v
vlog -sv sim/tb_he_color.sv
vsim -c work.tb_he_color
run -all
quit -code 0 -force
