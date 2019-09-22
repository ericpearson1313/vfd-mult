#multi-cycle paths for sq_in_d and sq_out to sq_out

# Stage 0
set_multicycle_path -setup 2 -from [get_pins -of_object [get_cells -hier -filter {IS_SEQUENTIAL == true && NAME =~ *modsqr*/sq_out_reg* }]   -filter {IS_CLOCK == true }] -to [get_pins -of_object [get_cells -hier -filter {IS_SEQUENTIAL == true && NAME =~ *modsqr*/reduced_grid_sum_reg_reg* }] -filter {DIRECTION == IN && IS_CLOCK == false}]
set_multicycle_path -hold  1 -from [get_pins -of_object [get_cells -hier -filter {IS_SEQUENTIAL == true && NAME =~ *modsqr*/sq_out_reg* }]   -filter {IS_CLOCK == true }] -to [get_pins -of_object [get_cells -hier -filter {IS_SEQUENTIAL == true && NAME =~ *modsqr*/reduced_grid_sum_reg_reg* }] -filter {DIRECTION == IN && IS_CLOCK == false}]
set_multicycle_path -setup 2 -from [get_pins -of_object [get_cells -hier -filter {IS_SEQUENTIAL == true && NAME =~ *modsqr*/sq_out_reg* }]   -filter {IS_CLOCK == true }] -to [get_pins -of_object [get_cells -hier -filter {IS_SEQUENTIAL == true && NAME =~ *modsqr*/reduction_lut_/*b_addr_reg_reg* }] -filter {DIRECTION == IN && IS_CLOCK == false}]
set_multicycle_path -hold  1 -from [get_pins -of_object [get_cells -hier -filter {IS_SEQUENTIAL == true && NAME =~ *modsqr*/sq_out_reg* }]   -filter {IS_CLOCK == true }] -to [get_pins -of_object [get_cells -hier -filter {IS_SEQUENTIAL == true && NAME =~ *modsqr*/reduction_lut_/*b_addr_reg_reg* }] -filter {DIRECTION == IN && IS_CLOCK == false}]

#stage 1
set_multicycle_path -setup 2 -from [get_pins -of_object [get_cells -hier -filter {IS_SEQUENTIAL == true && NAME =~ *modsqr*/reduced_grid_sum_reg_reg* }]   -filter {IS_CLOCK == true }] -to [get_pins -of_object [get_cells -hier -filter {IS_SEQUENTIAL == true && NAME =~ *modsqr*/sq_out_reg* }] -filter {REF_PIN_NAME == D}]
set_multicycle_path -hold  1 -from [get_pins -of_object [get_cells -hier -filter {IS_SEQUENTIAL == true && NAME =~ *modsqr*/reduced_grid_sum_reg_reg* }]   -filter {IS_CLOCK == true }] -to [get_pins -of_object [get_cells -hier -filter {IS_SEQUENTIAL == true && NAME =~ *modsqr*/sq_out_reg* }] -filter {REF_PIN_NAME == D}]
set_multicycle_path -setup 2 -from [get_pins -of_object [get_cells -hier -filter {IS_SEQUENTIAL == true && NAME =~ *modsqr*/reduction_lut_/*b_addr_reg_reg* }]   -filter {IS_CLOCK == true }] -to [get_pins -of_object [get_cells -hier -filter {IS_SEQUENTIAL == true && NAME =~ *modsqr*/sq_out_reg* }] -filter {REF_PIN_NAME == D}]
set_multicycle_path -hold  1 -from [get_pins -of_object [get_cells -hier -filter {IS_SEQUENTIAL == true && NAME =~ *modsqr*/reduction_lut_/*b_addr_reg_reg* }]   -filter {IS_CLOCK == true }] -to [get_pins -of_object [get_cells -hier -filter {IS_SEQUENTIAL == true && NAME =~ *modsqr*/sq_out_reg* }] -filter {REF_PIN_NAME == D}]

# start multi-cycle paths.
set_multicycle_path -setup 6 -from [get_pins -of_object [get_cells -hier -filter {IS_SEQUENTIAL == true && NAME =~ *modsqr*/sq_in_d1_reg* }] -filter {IS_CLOCK == true }] -to [get_pins -of_object [get_cells -hier -filter {IS_SEQUENTIAL == true && NAME =~ *modsqr*/reduced_grid_sum_reg_reg* }] -filter {DIRECTION == IN && IS_CLOCK == false}]
set_multicycle_path -hold  5 -from [get_pins -of_object [get_cells -hier -filter {IS_SEQUENTIAL == true && NAME =~ *modsqr*/sq_in_d1_reg* }] -filter {IS_CLOCK == true }] -to [get_pins -of_object [get_cells -hier -filter {IS_SEQUENTIAL == true && NAME =~ *modsqr*/reduced_grid_sum_reg_reg* }] -filter {DIRECTION == IN && IS_CLOCK == false}]
set_multicycle_path -setup 6 -from [get_pins -of_object [get_cells -hier -filter {IS_SEQUENTIAL == true && NAME =~ *modsqr*/start_d1_reg* }] -filter {IS_CLOCK == true }] -to [get_pins -of_object [get_cells -hier -filter {IS_SEQUENTIAL == true && NAME =~ *modsqr*/reduced_grid_sum_reg_reg* }] -filter {DIRECTION == IN && IS_CLOCK == false}]
set_multicycle_path -hold  5 -from [get_pins -of_object [get_cells -hier -filter {IS_SEQUENTIAL == true && NAME =~ *modsqr*/start_d1_reg* }] -filter {IS_CLOCK == true }] -to [get_pins -of_object [get_cells -hier -filter {IS_SEQUENTIAL == true && NAME =~ *modsqr*/reduced_grid_sum_reg_reg* }] -filter {DIRECTION == IN && IS_CLOCK == false}]
set_multicycle_path -setup 6 -from [get_pins -of_object [get_cells -hier -filter {IS_SEQUENTIAL == true && NAME =~ *modsqr*/sq_in_d1_reg* }] -filter {IS_CLOCK == true }] -to [get_pins -of_object [get_cells -hier -filter {IS_SEQUENTIAL == true && NAME =~ *modsqr*/reduction_lut_/*b_addr_reg_reg* }] -filter {DIRECTION == IN && IS_CLOCK == false}]
set_multicycle_path -hold  5 -from [get_pins -of_object [get_cells -hier -filter {IS_SEQUENTIAL == true && NAME =~ *modsqr*/sq_in_d1_reg* }] -filter {IS_CLOCK == true }] -to [get_pins -of_object [get_cells -hier -filter {IS_SEQUENTIAL == true && NAME =~ *modsqr*/reduction_lut_/*b_addr_reg_reg* }] -filter {DIRECTION == IN && IS_CLOCK == false}]
set_multicycle_path -setup 6 -from [get_pins -of_object [get_cells -hier -filter {IS_SEQUENTIAL == true && NAME =~ *modsqr*/start_d1_reg* }] -filter {IS_CLOCK == true }] -to [get_pins -of_object [get_cells -hier -filter {IS_SEQUENTIAL == true && NAME =~ *modsqr*/reduction_lut_/*b_addr_reg_reg* }] -filter {DIRECTION == IN && IS_CLOCK == false}]
set_multicycle_path -hold  5 -from [get_pins -of_object [get_cells -hier -filter {IS_SEQUENTIAL == true && NAME =~ *modsqr*/start_d1_reg* }] -filter {IS_CLOCK == true }] -to [get_pins -of_object [get_cells -hier -filter {IS_SEQUENTIAL == true && NAME =~ *modsqr*/reduction_lut_/*b_addr_reg_reg* }] -filter {DIRECTION == IN && IS_CLOCK == false}]

# CDC circuit paths
set_max_delay -to [get_pins -of_object [get_cells -hier -filter {IS_SEQUENTIAL == true && NAME =~ *modsqr*/*_cdc1_reg* }] -filter {DIRECTION == IN && IS_CLOCK == false}] -datapath_only 8.0 

# sq_out output ports (max delay)
set_max_delay -from [get_pins -of_object [get_cells -hier -filter {IS_SEQUENTIAL == true && NAME =~ *modsqr*/sq_out_reg* }] -filter {IS_CLOCK == true }] -to [get_pins -of_object [get_cells -hier -filter {IS_SEQUENTIAL == true && NAME =~ *modsqr*/sq_out_stages_reg* }] -filter {DIRECTION == IN && IS_CLOCK == false}] -datapath_only 8.0

# Sq input ports (max delay)
set_max_delay -from [get_pins -of_object [get_cells -hier -filter {IS_SEQUENTIAL == true && NAME =~ *modsqr*/sq_in_stages_reg* }] -filter {IS_CLOCK == true }] -to [get_pins -of_object [get_cells -hier -filter {IS_SEQUENTIAL == true && NAME =~ *modsqr*/sq_in_d1_reg* }] -filter {DIRECTION == IN && IS_CLOCK == false}] -datapath_only 8.0


