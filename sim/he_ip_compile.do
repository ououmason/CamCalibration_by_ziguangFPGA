# Compile the actual generated IP implementations, not behavioral substitutes.
vlog ipcore/he_hist_ram/rtl/ipm_distributed_sdpram_v1_3_he_hist_ram.v ipcore/he_hist_ram/he_hist_ram.v
vlog ipcore/he_map_ram/rtl/ipm_distributed_sdpram_v1_3_he_map_ram.v ipcore/he_map_ram/he_map_ram.v
