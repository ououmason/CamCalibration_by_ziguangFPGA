onerror {quit -code 1 -force}
onbreak {quit -code 1 -force}
if {![file exists sim/he_work]} {vlib sim/he_work}
vmap work sim/he_work
do sim/he_ip_compile.do
vlog source/img_process/HE/hist_equalization.v
vlog -sv sim/tb_he_short_blank.sv
vsim -c -voptargs=+acc work.tb_he_short_blank
run -all
quit -code 0 -force
