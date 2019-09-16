#multi-cycle paths for sq_in_d and sq_out to sq_out
set_multicycle_path -setup 4 -from [get_pins -of_object [get_cells -hier -filter {IS_SEQUENTIAL == true && NAME =~ *modsqr*/sq_out_reg* }]   -filter {IS_CLOCK == true }] -to [get_pins -of_object [get_cells -hier -filter {IS_SEQUENTIAL == true && NAME =~ *modsqr*/sq_out_reg* }] -filter {REF_PIN_NAME == D}]
set_multicycle_path -hold  3 -from [get_pins -of_object [get_cells -hier -filter {IS_SEQUENTIAL == true && NAME =~ *modsqr*/sq_out_reg* }]   -filter {IS_CLOCK == true }] -to [get_pins -of_object [get_cells -hier -filter {IS_SEQUENTIAL == true && NAME =~ *modsqr*/sq_out_reg* }] -filter {REF_PIN_NAME == D}]

set_multicycle_path -setup 2 -from [get_pins -of_object [get_cells -hier -filter {IS_SEQUENTIAL == true && NAME =~ *modsqr*/sq_out_reg* }]   -filter {IS_CLOCK == true }] -to [get_pins -of_object [get_cells -hier -filter {IS_SEQUENTIAL == true && NAME =~ *modsqr*/reduction_lut_/*b_addr_reg_reg* }] -filter {REF_PIN_NAME == D}]
set_multicycle_path -hold  1 -from [get_pins -of_object [get_cells -hier -filter {IS_SEQUENTIAL == true && NAME =~ *modsqr*/sq_out_reg* }]   -filter {IS_CLOCK == true }] -to [get_pins -of_object [get_cells -hier -filter {IS_SEQUENTIAL == true && NAME =~ *modsqr*/reduction_lut_/*b_addr_reg_reg* }] -filter {REF_PIN_NAME == D}]
set_multicycle_path -setup 2 -from [get_pins -of_object [get_cells -hier -filter {IS_SEQUENTIAL == true && NAME =~ *modsqr*/reduction_lut_/*b_addr_reg_reg* }]   -filter {IS_CLOCK == true }] -to [get_pins -of_object [get_cells -hier -filter {IS_SEQUENTIAL == true && NAME =~ *modsqr*/sq_out_reg* }] -filter {REF_PIN_NAME == D}]
set_multicycle_path -hold  1 -from [get_pins -of_object [get_cells -hier -filter {IS_SEQUENTIAL == true && NAME =~ *modsqr*/reduction_lut_/*b_addr_reg_reg* }]   -filter {IS_CLOCK == true }] -to [get_pins -of_object [get_cells -hier -filter {IS_SEQUENTIAL == true && NAME =~ *modsqr*/sq_out_reg* }] -filter {REF_PIN_NAME == D}]

set_multicycle_path -setup 6 -from [get_pins -of_object [get_cells -hier -filter {IS_SEQUENTIAL == true && NAME =~ *modsqr*/sq_in_d1_reg* }] -filter {IS_CLOCK == true }] -to [get_pins -of_object [get_cells -hier -filter {IS_SEQUENTIAL == true && NAME =~ *modsqr*/reduction_lut_/*b_addr_reg_reg* }] -filter {REF_PIN_NAME == D}]
set_multicycle_path -hold  5 -from [get_pins -of_object [get_cells -hier -filter {IS_SEQUENTIAL == true && NAME =~ *modsqr*/sq_in_d1_reg* }] -filter {IS_CLOCK == true }] -to [get_pins -of_object [get_cells -hier -filter {IS_SEQUENTIAL == true && NAME =~ *modsqr*/reduction_lut_/*b_addr_reg_reg* }] -filter {REF_PIN_NAME == D}]
set_multicycle_path -setup 6 -from [get_pins -of_object [get_cells -hier -filter {IS_SEQUENTIAL == true && NAME =~ *modsqr*/start_d1_reg* }] -filter {IS_CLOCK == true }] -to [get_pins -of_object [get_cells -hier -filter {IS_SEQUENTIAL == true && NAME =~ *modsqr*/reduction_lut_/*b_addr_reg_reg* }] -filter {REF_PIN_NAME == D}]
set_multicycle_path -hold  5 -from [get_pins -of_object [get_cells -hier -filter {IS_SEQUENTIAL == true && NAME =~ *modsqr*/start_d1_reg* }] -filter {IS_CLOCK == true }] -to [get_pins -of_object [get_cells -hier -filter {IS_SEQUENTIAL == true && NAME =~ *modsqr*/reduction_lut_/*b_addr_reg_reg* }] -filter {REF_PIN_NAME == D}]

set_multicycle_path -setup 8 -from [get_pins -of_object [get_cells -hier -filter {IS_SEQUENTIAL == true && NAME =~ *modsqr*/sq_in_d1_reg* }] -filter {IS_CLOCK == true }] -to [get_pins -of_object [get_cells -hier -filter {IS_SEQUENTIAL == true && NAME =~ *modsqr*/sq_out_reg* }] -filter {REF_PIN_NAME == D}]
set_multicycle_path -hold  7 -from [get_pins -of_object [get_cells -hier -filter {IS_SEQUENTIAL == true && NAME =~ *modsqr*/sq_in_d1_reg* }] -filter {IS_CLOCK == true }] -to [get_pins -of_object [get_cells -hier -filter {IS_SEQUENTIAL == true && NAME =~ *modsqr*/sq_out_reg* }] -filter {REF_PIN_NAME == D}]
set_multicycle_path -setup 8 -from [get_pins -of_object [get_cells -hier -filter {IS_SEQUENTIAL == true && NAME =~ *modsqr*/start_d1_reg* }] -filter {IS_CLOCK == true }] -to [get_pins -of_object [get_cells -hier -filter {IS_SEQUENTIAL == true && NAME =~ *modsqr*/sq_out_reg* }] -filter {REF_PIN_NAME == D}]
set_multicycle_path -hold  7 -from [get_pins -of_object [get_cells -hier -filter {IS_SEQUENTIAL == true && NAME =~ *modsqr*/start_d1_reg* }] -filter {IS_CLOCK == true }] -to [get_pins -of_object [get_cells -hier -filter {IS_SEQUENTIAL == true && NAME =~ *modsqr*/sq_out_reg* }] -filter {REF_PIN_NAME == D}]

