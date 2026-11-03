onerror {quit -code 1 -force}
onbreak {quit -code 1 -force}
if {![file exists sim/he_work]} {vlib sim/he_work}
vmap work sim/he_work
do sim/he_ip_compile.do
vlog source/undistort/ud_reset.v
vlog source/img_process/HE/*.v
vlog source/rtl/HDMI_IN_DDR3_YCbCr_top.v
vlog -sv sim/tb_he_video.sv
vsim -c -voptargs=+acc work.tb_he_video
run -all
quit -code 0 -force
