#add_cells_to_pblock [get_pblocks pblock_dynamic_SLR2] [get_cells [list {WRAPPER_INST/CL/vdf_1/inst/inst_wrapper/inst_kernel/msu/modsqr/modsqr}]]
set_property CLOCK_DEDICATED_ROUTE ANY_CMT_COLUMN [get_nets WRAPPER_INST/SH/kernel_clks_i/clkwiz_kernel_clk0/inst/CLK_CORE_DRP_I/clk_inst/clk_out1]

#create_pblock pb_slr2
#resize_pblock [get_pblocks pb_slr2] -add {CLOCKREGION_X0Y10:CLOCKREGION_X5Y14}
#set_property PARENT pblock_CL [get_pblocks pb_slr2]
#add product/Lut registers
#add_cells_to_pblock pb_slr2 [get_cells -hier -filter {NAME =~ */msu/modsqr/modsqr/reduced_grid_sum_reg_reg*}]
#add_cells_to_pblock pb_slr2 [get_cells -hier -filter {NAME =~ */msu/modsqr/modsqr/reduction_lut_/*b_addr_reg_reg*}]

#create_pblock pb_slr01
#resize_pblock [get_pblocks pb_slr01] -add {SLICE_X88Y0:SLICE_X107Y599}
#resize_pblock [get_pblocks pb_slr01] -add {DSP48E2_X11Y0:DSP48E2_X13Y239}
#resize_pblock [get_pblocks pb_slr01] -add {LAGUNA_X12Y0:LAGUNA_X15Y479}
#resize_pblock [get_pblocks pb_slr01] -add {RAMB18_X7Y0:RAMB18_X7Y239}
#resize_pblock [get_pblocks pb_slr01] -add {RAMB36_X7Y0:RAMB36_X7Y119}
#resize_pblock [get_pblocks pb_slr01] -add {URAM288_X2Y0:URAM288_X2Y159}
#resize_pblock [get_pblocks pb_slr01] -add {CLOCKREGION_X0Y0:CLOCKREGION_X2Y9}
#set_property PARENT pblock_CL [get_pblocks pb_slr01]
#add sq_out registers
#add_cells_to_pblock pb_slr01 [get_cells -hier -filter {NAME =~ */msu/modsqr/modsqr/sq_out_reg*}]

