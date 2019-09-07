#multi-cycle paths for sq_in_d and sq_out to sq_out
set_multicycle_path -setup 4 -from [get_pins *modsqr*/sq_out_reg*/C]  to [get_pins *modsqr*/sq_out_reg*/C]
set_multicycle_path -hold  3 -from [get_pins *modsqr*/sq_out_reg*/C]  to [get_pins *modsqr*/sq_out_reg*/C]
set_multicycle_path -setup 4 -from [get_pins *modsqr*/sq_in_d_reg*/C] to [get_pins *modsqr*/sq_out_reg*/C]
set_multicycle_path -hold  3 -from [get_pins *modsqr*/sq_in_d_reg*/C] to [get_pins *modsqr*/sq_out_reg*/C]


