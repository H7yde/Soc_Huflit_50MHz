set_property SRC_FILE_INFO {cfile:D:/LAB/SOC_HUFLIT_2026_parallel_50MHz/SOC_HUFLIT_2026.srcs/constrs_1/new/soc_top.xdc rfile:../../../SOC_HUFLIT_2026.srcs/constrs_1/new/soc_top.xdc id:1} [current_design]
set_property src_info {type:XDC file:1 line:22 export:INPUT save:INPUT read:READ} [current_design]
set_output_delay -clock ddr_clk_out -max 2.5 [get_ports {ddr_data[*]}]
set_property src_info {type:XDC file:1 line:23 export:INPUT save:INPUT read:READ} [current_design]
set_output_delay -clock ddr_clk_out -min -1.1 [get_ports {ddr_data[*]}]
set_property src_info {type:XDC file:1 line:24 export:INPUT save:INPUT read:READ} [current_design]
set_output_delay -clock ddr_clk_out -max 2.5 [get_ports {ddr_data[*]}] -clock_fall -add_delay
set_property src_info {type:XDC file:1 line:25 export:INPUT save:INPUT read:READ} [current_design]
set_output_delay -clock ddr_clk_out -min -1.1 [get_ports {ddr_data[*]}] -clock_fall -add_delay
set_property src_info {type:XDC file:1 line:27 export:INPUT save:INPUT read:READ} [current_design]
set_output_delay -clock ddr_clk_out -max 2.5 [get_ports {ddr_valid ddr_done}]
set_property src_info {type:XDC file:1 line:28 export:INPUT save:INPUT read:READ} [current_design]
set_output_delay -clock ddr_clk_out -min -1.1 [get_ports {ddr_valid ddr_done}]
