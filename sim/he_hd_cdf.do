onerror {quit -code 1 -force}
onbreak {quit -code 1 -force}
if {![file exists sim/he_work]} {vlib sim/he_work}
vmap work sim/he_work
do sim/he_ip_compile.do
vlog source/img_process/HE/hist_equalization.v
vlog -sv sim/tb_he_hd_cdf.sv
vsim -c -voptargs=+acc work.tb_he_hd_cdf
run -all
quit -code 0 -force
